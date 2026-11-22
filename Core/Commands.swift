import Foundation

// Runs what scripting asks for (the types are in Scripting/ScriptProtocol.swift, shared with the
// command-line tool): Shortcuts (App Intents), the setpilot:// URL scheme and, on the Mac, the
// command-line tool. Only what the app's own controls do (no raw methods), on the chosen bulb, with
// a bulb's answer (a refusal, no answer, or a change it didn't apply) reported as an error.

@MainActor
enum Scripting {
    static func run(_ command: ScriptCommand, on model: Model) async -> ScriptResult {
        do {
            return try await perform(command, model)
        } catch let error as ScriptError {
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

    private static func perform(_ command: ScriptCommand, _ model: Model) async throws -> ScriptResult {
        switch command {
        case .list(let kind):
            return ScriptResult(items: items(kind, model))
        case .switchBulb(let query):
            guard let bulb = find(query, in: model.namedBulbs, name: { $0.name }, id: { $0.mac ?? $0.address },
                                  also: { b in [b.address] + (b.mac.map { [$0] } ?? []) }) else {
                throw ScriptError(code: .notFound, message: "No bulb called “\(query)” (or with that MAC or address) in your bulbs.")
            }
            model.choose(bulb.address, mac: bulb.mac)
            try await ready(model)
            return ScriptResult(state: state(of: model))
        case .get:
            try await ready(model)
            return ScriptResult(state: state(of: model))
        default:
            break
        }
        try await ready(model)
        switch command {
        case .power(let on):
            model.power(on ?? !(model.isOn ?? false))
        case .brightness(let level):
            guard (1...100).contains(level) else { throw bad("Brightness is 1–100.") }
            model.setDimming(Double(level))
        case .adjustBrightness(let step):
            guard step != 0, abs(step) <= 100 else { throw bad("The step is −100 to 100, and not 0.") }
            model.adjustDimming(by: step)
        case let .colour(r, g, b, c, w, power):
            let channels = [r, g, b, c, w]
            guard channels.allSatisfy({ (0...255).contains($0) }) else { throw bad("Each channel is 0–255.") }
            guard channels.contains(where: { $0 > 0 }) else { throw bad("At least one channel has to be above 0 (the bulb refuses all zeros).") }
            try send(LightChange(colour: .rgbcw(r: r, g: g, b: b, c: c, w: w), power: power), model)
        case let .temperature(kelvin, scaleQuery, power):
            try send(LightChange(colour: try temperature(kelvin, scaleQuery, model), power: power), model)
        case let .scene(query, speed, power):
            let scenes = Scenes.all.filter { !(256...265).contains($0.id) } // the bulb's stored slots: not settable here
            guard let scene = find(query, in: scenes, name: { $0.name }, id: { String($0.id) }) else {
                throw ScriptError(code: .notFound, message: "No built-in scene called “\(query)”.")
            }
            if let speed, !(10...200).contains(speed) { throw bad("Speed is 10–200.") }
            try send(LightChange(colour: .scene(id: scene.id, speed: speed), power: power), model)
        case let .customScene(query, power):
            guard let scene = find(query, in: model.library.customScenes, name: { $0.name }, id: { $0.id.uuidString }) else {
                throw ScriptError(code: .notFound, message: "No custom scene called “\(query)”.")
            }
            try send(LightChange(colour: .custom(scene.id, speed: nil), power: power), model)
        case .speed(let speed):
            guard (10...200).contains(speed) else { throw bad("Speed is 10–200.") }
            guard model.mode == .scene else { throw bad("The bulb isn't on a scene.") }
            var v = model.values
            v.speed = Double(speed)
            model.apply(v, fields: [.speed])
        case .preset(let query):
            guard let preset = find(query, in: model.library.presets, name: { $0.name }, id: { $0.id.uuidString }) else {
                throw ScriptError(code: .notFound, message: "No preset called “\(query)”.")
            }
            guard model.apply(preset) else { throw ScriptError(code: .refused, message: model.refusal ?? model.status) }
        case .get, .list, .switchBulb:
            break
        }
        try await answered(model)
        return ScriptResult(state: state(of: model))
    }

    private static func bad(_ message: String) -> ScriptError { ScriptError(code: .badArguments, message: message) }

    /// As the controls send: with their fade.
    private static func send(_ change: LightChange, _ model: Model) throws {
        var change = change
        change.fade = model.fadeForControls
        guard model.send(change) else { throw ScriptError(code: .refused, message: model.refusal ?? model.status) }
    }

    private static func temperature(_ kelvin: Int, _ scaleQuery: String?, _ model: Model) throws -> LightColour {
        let scales = model.library.scales(for: model.chosenMAC).filter { $0.range != nil }
        let scale: CCTScale?
        switch scaleQuery?.lowercased() {
        case "bulb", "own", "bulb's own": scale = nil
        case nil: scale = model.scaleForTemperature.flatMap { id in scales.first { $0.id == id } }
        default:
            guard let found = find(scaleQuery!, in: scales, name: { $0.name }, id: { $0.id.uuidString }) else {
                throw ScriptError(code: .notFound, message: "No CCT scale called “\(scaleQuery!)” for this bulb.")
            }
            scale = found
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
            throw ScriptError(code: .noBulb, message: "No bulb chosen in setPilot.")
        }
        guard await model.waitUntilControllable(timeout: 5) else {
            // Answering but refusing to say how it is (a wrong signing key, say): that reason.
            if model.link == .connected, !model.status.isEmpty { throw ScriptError(code: .refused, message: model.status) }
            throw ScriptError(code: .notAnswering, message: "The bulb isn't answering.")
        }
    }

    /// Taken, read back and as asked: or the bulb's refusal, no answer, or what it didn't apply.
    private static func answered(_ model: Model) async throws {
        if let problem = await model.outcome() {
            throw ScriptError(code: model.pending ? .notAnswering : .refused, message: problem)
        }
        await model.waitUntilSettled()
        if let mismatch = model.mismatch { throw ScriptError(code: .notApplied, message: mismatch) }
    }

    // MARK: Finding by name

    /// By ID, then exact name (ignoring case), then the only name that starts with it.
    static func find<T>(_ query: String, in list: [T], name: (T) -> String?, id: (T) -> String,
                        also: (T) -> [String] = { _ in [] }) -> T? {
        let q = query.trimmingCharacters(in: .whitespaces)
        func norm(_ s: String) -> String { s.lowercased().filter { !":-. ".contains($0) } }
        if let hit = list.first(where: { id($0).caseInsensitiveCompare(q) == .orderedSame || also($0).contains { norm($0) == norm(q) } }) {
            return hit
        }
        if let hit = list.first(where: { name($0)?.caseInsensitiveCompare(q) == .orderedSame }) { return hit }
        let starts = list.filter { name($0)?.lowercased().hasPrefix(q.lowercased()) == true }
        return starts.count == 1 ? starts[0] : nil
    }

    private static func items(_ kind: ScriptList, _ model: Model) -> [ScriptItem] {
        switch kind {
        case .presets: model.library.presets.map { ScriptItem(name: $0.name, id: $0.id.uuidString) }
        case .scenes: Scenes.all.filter { !(256...265).contains($0.id) }.map { ScriptItem(name: $0.name, id: String($0.id)) }
        case .customScenes: model.library.customScenes.map { ScriptItem(name: $0.name, id: $0.id.uuidString) }
        case .scales: model.library.scales(for: model.chosenMAC).map { ScriptItem(name: $0.name, id: $0.id.uuidString) }
        case .bulbs: model.namedBulbs.map { ScriptItem(name: $0.name ?? $0.address, id: $0.mac ?? $0.address) }
        }
    }
}
