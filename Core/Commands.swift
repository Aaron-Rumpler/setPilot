import Foundation

// Runs what scripting asks for (the types are in Scripting/ScriptProtocol.swift, shared with the
// command-line tool): Shortcuts (App Intents), the setpilot:// URL scheme and, on the Mac, the
// command-line tool. Only what the app's own controls do (no raw methods), on the chosen bulb, with
// a bulb's answer (a refusal, no answer, or a change it didn't apply) reported as an error.

@MainActor
enum Scripting {
    /// One at a time, in the order they came: each change's outcome (its answer, its read-back) is
    /// only its own if no other change goes out meanwhile.
    /// `fade`: in ms, for this change (setPilot's trans); nil for the controls' fade, as the app's
    /// own controls send.
    /// A change that has waited its turn longer than anything waits for the bulb (answerTimeout)
    /// isn't sent: it would land long after it was asked for. It fails as not answering (the one
    /// before it is still waiting for the bulb).
    /// `asked`: when it was asked for, if before now (a watch tap that's waited its turn on the
    /// iPhone): the wait is counted from then.
    static func run(_ command: ScriptCommand, fade: Int? = nil, asked: Date = .now, on model: Model) async -> ScriptResult {
        let previous = queue
        let task = Task { @MainActor () -> ScriptResult in
            let queued = Date.now
            _ = await previous?.value
            if command.changes, Date.now.timeIntervalSince(asked) > Model.answerTimeout {
                // Why it's late: waiting behind another, or before it got here (launching the app, say).
                let behindAnother = Date.now.timeIntervalSince(queued) > 0.1
                return ScriptResult(state: Scripting.state(of: model), error: ScriptError(code: .notAnswering,
                    message: behindAnother
                        ? "The bulb was still answering an earlier change, so this one wasn't sent (it would have been late)."
                        : "That took too long to reach setPilot (it may have been starting up), so it wasn't sent; try again."))
            }
            // Waits from here are what's left of the one timeout, counted from when it was asked
            // for (switching bulbs, which lands elsewhere, gets the whole of it).
            deadline = command.changes ? asked.addingTimeInterval(Model.answerTimeout) : nil
            defer { deadline = nil }
            return await runNow(command, fade: fade, on: model)
        }
        queue = Task { @MainActor in _ = await task.value }
        return await task.value
    }
    private static var queue: Task<Void, Never>?
    /// When the command being run has to have gone out by (see run).
    private static var deadline: Date?

    private static func runNow(_ command: ScriptCommand, fade: Int?, on model: Model) async -> ScriptResult {
        if let fade, !(0...Fade.maximum).contains(fade) {
            return ScriptResult(state: state(of: model), error: bad("The fade is 0–\(Fade.maximum) ms (a day)."))
        }
        do {
            Log.scripting.info("\(String(describing: command), privacy: .public)")
            return try await perform(command, fade, model)
        } catch let error as ScriptError {
            Log.scripting.error("\(error.code.rawValue, privacy: .public): \(error.message, privacy: .public)")
            return ScriptResult(state: state(of: model), error: error)
        } catch {
            return ScriptResult(state: state(of: model), error: ScriptError(code: .refused, message: error.localizedDescription))
        }
    }

    // MARK: Reading

    static func state(of model: Model) -> LightState {
        let link = switch model.link {
        case .none: "none"
        case .connecting: "connecting"
        case .connected: "connected"
        case .unreachable: "unreachable"
        }
        var s = LightState(bulb: .init(name: model.currentName, mac: model.chosenMAC,
                                       address: UserDefaults.standard.string(forKey: Model.addressKey)),
                           link: link, on: model.isOn, mode: "rgbcw", dimming: Int(model.dimming))
        switch model.mode {
        case .rgbcw:
            s.rgbcw = [model.r, model.g, model.b, model.c, model.w].map { Int($0) }
        case .temp:
            s.mode = "temperature"
            s.temp = Int(model.temp)
        case .custom:
            s.mode = "temperature"
            s.temp = Int(model.customKelvin)
            s.scale = model.activeScale?.name
        case .scene:
            s.mode = "scene"
            s.speed = Int(model.speed)
            if model.sceneId == Scenes.inlineCustom, let id = model.customSceneId, let scene = model.library.customScene(id) {
                s.scene = scene.name
            } else {
                s.scene = Scenes.name(model.sceneId)
                s.sceneId = model.sceneId
            }
        }
        return s
    }

    // MARK: Running

    private static func perform(_ command: ScriptCommand, _ fade: Int?, _ model: Model) async throws -> ScriptResult {
        switch command {
        case .list(let kind):
            return ScriptResult(items: items(kind, model))
        case .switchBulb(let query):
            guard let bulb = find(query, in: model.namedBulbs, name: { $0.name }, id: { $0.mac ?? $0.address },
                                  also: { b in [b.address] + (b.mac.map { [$0] } ?? []) }) else {
                throw ScriptError(code: .notFound, message: "No bulb called “\(query)” (or with that MAC or address) in your bulbs.")
            }
            if bulb.address.isEmpty {
                // Known only by its MAC (from the WiZ import): find it first.
                guard let mac = bulb.mac, let address = await model.locate(mac: mac) else {
                    throw ScriptError(code: .notFound, message: "\(bulb.name ?? "That bulb") hasn't been found on the network yet.")
                }
                model.choose(address, mac: mac)
            } else {
                model.choose(bulb.address, mac: bulb.mac)
            }
            try await ready(model)
            return ScriptResult(state: state(of: model))
        case .get:
            try await ready(model)
            return ScriptResult(state: state(of: model))
        default:
            break
        }
        try await ready(model)
        model.mismatch = nil // an earlier change's: this one's own read-back says
        let before = model.ticket
        switch command {
        case .power(let on):
            let on = on ?? !(model.isOn ?? false)
            // With a fade of its own: as Compose sends a switch; otherwise as the power switch does.
            if fade != nil { try send(LightChange(power: on), fade, model) } else { model.power(on) }
        case .brightness(let level):
            guard (1...100).contains(level) else { throw bad("Brightness is 1–100.") }
            if fade != nil { try send(LightChange(dimming: level), fade, model) } else { model.setDimming(Double(level)) }
        case .adjustBrightness(let step):
            guard step != 0, abs(step) <= 100 else { throw bad("The step is −100 to 100, and not 0.") }
            if fade != nil {
                let level = Int(min(max(model.dimming + Double(step), model.minDimming), 100))
                try send(LightChange(dimming: level), fade, model)
            } else {
                model.adjustDimming(by: step)
            }
        case let .colour(r, g, b, c, w, power):
            try send(LightChange(colour: try rgbcw([r, g, b, c, w]), power: power), fade, model)
        case let .temperature(kelvin, scaleQuery, power):
            try send(LightChange(colour: try temperature(kelvin, scaleQuery, model), power: power), fade, model)
        case let .scene(query, speed, power):
            try send(LightChange(colour: try scene(query, speed: speed), power: power), fade, model)
        case let .customScene(query, power):
            try send(LightChange(colour: try customScene(query, speed: nil, model), power: power), fade, model)
        case .speed(let speed):
            guard (10...200).contains(speed) else { throw bad("Speed is 10–200.") }
            guard model.mode == .scene else { throw bad("The bulb isn't on a scene.") }
            var v = model.values
            v.speed = Double(speed)
            model.apply(v, fields: [.speed])
            // Off, it's kept for when the bulb's switched on (a speed alone would switch it on):
            // nothing to wait for.
            if model.isOn == false { return ScriptResult(state: state(of: model)) }
        case .preset(let query):
            guard let preset = find(query, in: model.library.presets, name: { $0.name }, id: { $0.id.uuidString }) else {
                throw ScriptError(code: .notFound, message: "No preset called “\(query)”.")
            }
            if fade != nil {
                try send(LightChange(colour: preset.colour, dimming: preset.dimming, power: true), fade, model)
            } else {
                guard model.apply(preset) else { throw ScriptError(code: .refused, message: model.refusal ?? model.status) }
            }
        case .set(let change):
            try send(try lightChange(change, model), fade, model)
        case .get, .list, .switchBulb:
            break
        }
        try await answered(model, since: before)
        return ScriptResult(state: state(of: model))
    }

    private static func bad(_ message: String) -> ScriptError { ScriptError(code: .badArguments, message: message) }

    /// With `fade`, or the controls' fade as they send.
    private static func send(_ change: LightChange, _ fade: Int?, _ model: Model) throws {
        var change = change
        change.fade = fade ?? model.fadeForControls
        guard model.send(change) else { throw ScriptError(code: .refused, message: model.refusal ?? model.status) }
    }

    private static func rgbcw(_ values: [Int]) throws -> LightColour {
        guard (3...5).contains(values.count) else { throw bad("A colour is r, g, b, and optionally c and w.") }
        let v = values + Array(repeating: 0, count: 5 - values.count)
        guard v.allSatisfy({ (0...255).contains($0) }) else { throw bad("Each channel is 0–255.") }
        guard v.contains(where: { $0 > 0 }) else { throw bad("At least one channel has to be above 0 (the bulb refuses all zeros).") }
        return .rgbcw(r: v[0], g: v[1], b: v[2], c: v[3], w: v[4])
    }

    private static func scene(_ query: String, speed: Int?) throws -> LightColour {
        let scenes = Scenes.all.filter { !(256...265).contains($0.id) } // the bulb's stored slots: not settable here
        guard let scene = find(query, in: scenes, name: { $0.name }, id: { String($0.id) }) else {
            throw ScriptError(code: .notFound, message: "No built-in scene called “\(query)”.")
        }
        if let speed, !(10...200).contains(speed) { throw bad("Speed is 10–200.") }
        return .scene(id: scene.id, speed: speed)
    }

    private static func customScene(_ query: String, speed: Int?, _ model: Model) throws -> LightColour {
        guard let scene = find(query, in: model.library.customScenes, name: { $0.name }, id: { $0.id.uuidString }) else {
            throw ScriptError(code: .notFound, message: "No custom scene called “\(query)”.")
        }
        if let speed, !(10...200).contains(speed) { throw bad("Speed is 10–200.") }
        return .custom(scene.id, speed: speed)
    }

    /// A combined change, checked: one kind of colour at most, and something to change.
    private static func lightChange(_ c: ScriptChange, _ model: Model) throws -> LightChange {
        let kinds = [c.rgbcw != nil, c.temp != nil, c.scene != nil, c.customScene != nil].filter { $0 }.count
        guard kinds <= 1 else { throw bad("Set one of a colour, a temperature, a scene or a custom scene.") }
        if c.scale != nil, c.temp == nil { throw bad("A scale goes with a temperature.") }
        if c.speed != nil, c.rgbcw != nil || c.temp != nil { throw bad("A speed goes with a scene.") }
        var colour: LightColour?
        if let v = c.rgbcw { colour = try rgbcw(v) }
        if let k = c.temp { colour = try temperature(k, c.scale, model) }
        if let q = c.scene { colour = try scene(q, speed: c.speed) }
        if let q = c.customScene { colour = try customScene(q, speed: c.speed, model) }
        if colour == nil, let speed = c.speed {
            // The scene it's on, at that speed.
            guard (10...200).contains(speed) else { throw bad("Speed is 10–200.") }
            guard model.mode == .scene else { throw bad("The bulb isn't on a scene.") }
            if model.sceneId == Scenes.inlineCustom, let id = model.customSceneId, model.library.customScene(id) != nil {
                colour = .custom(id, speed: speed)
            } else if Scenes.isKnown(model.sceneId) {
                colour = .scene(id: model.sceneId, speed: speed)
            } else {
                throw bad("This scene can't be sent (Rhythm, say), so neither can its speed.")
            }
        }
        if let b = c.brightness, !(1...100).contains(b) { throw bad("Brightness is 1–100.") }
        guard colour != nil || c.brightness != nil || c.power != nil else { throw bad("Nothing to set.") }
        return LightChange(colour: colour, dimming: c.brightness, power: c.power)
    }

    private static func temperature(_ kelvin: Int, _ scaleQuery: String?, _ model: Model) throws -> LightColour {
        let scales = model.library.scales(for: model.chosenMAC).filter { $0.range != nil }
        let scale: CCTScale?
        if let q = scaleQuery {
            // A scale of that name (or ID) first, so one called "Bulb" can be chosen; then the
            // bulb's own.
            // A scale with exactly that name (or ID) first, so one called "Bulb" can be chosen; then
            // the bulb's own; then a scale by the start of its name ("bulb" isn't "Bulb default").
            let exact = scales.first { $0.id.uuidString.caseInsensitiveCompare(q) == .orderedSame || $0.name.caseInsensitiveCompare(q) == .orderedSame }
            if let exact {
                scale = exact
            } else if ["bulb", "own", "bulb's own"].contains(q.lowercased()) {
                scale = nil
            } else if let found = find(q, in: scales, name: { $0.name }, id: { $0.id.uuidString }) {
                scale = found
            } else {
                throw ScriptError(code: .notFound, message: "That CCT scale isn't one of this bulb's (with two or more points).")
            }
        } else {
            scale = model.scaleForTemperature.flatMap { id in scales.first { $0.id == id } }
        }
        if let scale, let range = scale.range {
            return .customCCT(scale: scale.id, kelvin: min(max(kelvin, range.lowerBound), range.upperBound))
        }
        let k = min(max(Double(kelvin), model.tempRange.lowerBound), model.tempRange.upperBound)
        return .temp(Int(k))
    }

    /// The bulb chosen and controllable, or why not.
    private static func ready(_ model: Model) async throws {
        guard let a = UserDefaults.standard.string(forKey: Model.addressKey), !a.isEmpty else {
            throw ScriptError(code: .noBulb, message: "Choose a bulb in setPilot first.")
        }
        let left = deadline.map { $0.timeIntervalSinceNow } ?? Model.answerTimeout
        let started = Date.now
        guard await model.waitUntilControllable(timeout: max(left, 0)) else {
            throw notReady(model, left: left, waitStarted: started)
        }
    }

    /// Why a wait for the bulb (of `left` seconds, from `waitStarted`) came to nothing, the same
    /// for everything that waits (the runner, the watch relay).
    static func notReady(_ model: Model, left: Double, waitStarted started: Date) -> ScriptError {
        // Answering but refusing to say how it is (a wrong signing key, say): that reason.
        // Not if it's just been found not answering (it may still show as connected).
        if !model.recentlyNotAnswering, model.link == .connected, model.isOn == nil, !model.status.isEmpty {
            return ScriptError(code: .refused, message: model.status)
        }
        // Its time ran out waiting its turn or travelling while the bulb was answering: not the
        // bulb's fault.
        if left < Model.answerTimeout - 0.01, model.heardSince(started), model.link == .connected {
            return ScriptError(code: .notAnswering, message: "That came too late to send (it waited too long before the bulb could take it); try again.")
        }
        #if os(iOS)
        return ScriptError(code: .notAnswering, message: "The bulb isn't answering. Check it's powered and on the same network as your iPhone.")
        #else
        return ScriptError(code: .notAnswering, message: "The bulb isn't answering. Check it's powered and on the same network as your Mac.")
        #endif
    }

    /// Taken, read back and as asked: or the bulb's refusal, no answer, what it didn't apply, or
    /// not known (another change went before it was answered). Nothing sent (already as asked): done.
    private static func answered(_ model: Model, since before: Int) async throws {
        let t = model.ticket
        guard t != before else { return }
        switch await model.result(of: t) {
        case .done: return
        case .notApplied(let why): throw ScriptError(code: .notApplied, message: why)
        case .refused(let why): throw ScriptError(code: .refused, message: why)
        case .notAnswered(let why), .notKnown(let why): throw ScriptError(code: .notAnswering, message: why)
        }
    }

    // MARK: Finding by name

    /// By ID, then exact name (ignoring case), then the only name that starts with it.
    static func find<T>(_ query: String, in list: [T], name: (T) -> String?, id: (T) -> String,
                        also: (T) -> [String] = { _ in [] }) -> T? {
        let q = query.trimmingCharacters(in: .whitespaces)
        // A MAC in any notation (aa:bb:…, AA-BB-…); anything else (an address) exactly, ignoring case.
        func norm(_ s: String) -> String {
            let hex = s.lowercased().filter { !":-. ".contains($0) }
            return hex.count == 12 && hex.allSatisfy(\.isHexDigit) ? hex : s.lowercased()
        }
        if let hit = list.first(where: { id($0).caseInsensitiveCompare(q) == .orderedSame || also($0).contains { norm($0) == norm(q) } }) {
            return hit
        }
        if let hit = list.first(where: { name($0)?.caseInsensitiveCompare(q) == .orderedSame }) { return hit }
        let starts = list.filter { name($0)?.lowercased().hasPrefix(q.lowercased()) == true }
        return starts.count == 1 ? starts[0] : nil
    }

    static func items(_ kind: ScriptList, _ model: Model) -> [ScriptItem] {
        switch kind {
        case .presets: model.library.presets.map { ScriptItem(name: $0.name, id: $0.id.uuidString) }
        case .scenes: Scenes.all.filter { !(256...265).contains($0.id) }.map { ScriptItem(name: $0.name, id: String($0.id)) }
        case .customScenes: model.library.customScenes.map { ScriptItem(name: $0.name, id: $0.id.uuidString) }
        case .scales: model.library.scales(for: model.chosenMAC).map { ScriptItem(name: $0.name, id: $0.id.uuidString) }
        case .bulbs: model.namedBulbs.map { ScriptItem(name: $0.name ?? "Unnamed bulb", id: $0.mac ?? $0.address) }
        }
    }
}

extension ScriptCommand {
    /// Whether it changes the light (or which bulb), rather than only reading.
    var changes: Bool {
        switch self {
        // Switching bulbs is the way out of one that isn't answering, and lands on another.
    // (Used by PhoneRelay too.)
        case .get, .list, .switchBulb: false
        default: true
        }
    }
}
