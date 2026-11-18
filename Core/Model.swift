import Foundation

@MainActor @Observable
final class Model {
    /// Remembered, so the window opens with the controls the bulb was last in and doesn't
    /// change size when it first reports its state.
    var mode: Mode = Mode(rawValue: UserDefaults.standard.string(forKey: Model.modeKey) ?? "") ?? .rgbcw {
        didSet { if mode != oldValue { UserDefaults.standard.set(mode.rawValue, forKey: Self.modeKey) } }
    }
    static let modeKey = "mode"
    // One per line: @Observable can't expand multi-variable declarations.
    var r = 255.0
    var g = 0.0
    var b = 0.0
    var c = 0.0
    var w = 0.0
    var dimming = 100.0
    var temp = 2700.0
    var sceneId = 1
    var speed = 100.0
    var isOn: Bool?
    /// The custom scene playing, while the bulb reports setPilot's inline scene ID.
    var customSceneId: UUID? = UserDefaults.standard.string(forKey: Model.customSceneKey).flatMap(UUID.init) {
        didSet { UserDefaults.standard.set(customSceneId?.uuidString, forKey: Self.customSceneKey) }
    }
    static let customSceneKey = "customScene"
    /// Presets and custom scenes.
    let library = Library()

    /// Fade time for every change, in ms (the `trans` parameter); nil (or -1 stored) leaves it to
    /// the bulb.
    static var fade: Int? {
        get { (UserDefaults.standard.object(forKey: fadeKey) as? Int).flatMap { $0 >= 0 ? $0 : nil } }
        set { UserDefaults.standard.set(newValue, forKey: fadeKey) }
    }
    static let fadeKey = "fadeMs"

    // From getModelConfig / getUserConfig
    var minDimming = 10.0
    var tempRange: ClosedRange<Double> = 2200...6500
    /// The bulb's own fades (getUserConfig), in ms: when turning on or changing, and turning off.
    var fadeIn: Int?
    var fadeOut: Int?

    var mac: String?
    var module: String?
    var firmware: String?
    var rssi: Int?
    var info: [String: String] = [:] // method -> pretty-printed result
    enum Link { case none, connecting, connected, unreachable }
    /// Whether the bulb has answered since the last Connect.
    var link: Link = .none
    /// Controls are usable: the bulb answers and its on/off state is known (a setPilot to a bulb
    /// that's off has to say so, or it switches on).
    var canControl: Bool { link == .connected && isOn != nil }
    /// Registered for syncPilot pushes.
    var live = false { didSet { if !live { pushSeen = false } } }
    /// A push has arrived since connecting: registration alone doesn't show they get through
    /// (a firewall can block port 38900).
    var pushSeen = false
    var status = ""
    var liveStatus = "Live updates off"
    var lastSent = ""
    /// A setPilot hasn't been read back yet; the UI shows what was requested meanwhile.
    var pending = false
    /// What the bulb reported differently from the last setPilot, if anything.
    var mismatch: String?
    var discovered: [DiscoveredBulb] = []
    var discovering = false
    /// Why the last search found nothing (or is waiting for permission).
    var discoveryNote: String?
    /// The other form of the chosen bulb's address: its DNS name if an IP was chosen, or its IP if
    /// a name was.
    var addressDetail: String?

    /// Set once connecting (or the first-launch search) has started this launch.
    @ObservationIgnored var started = false

    /// Connects to the saved bulb, once per launch. With no saved bulb this does nothing; the window
    /// runs the first-launch search instead.
    func startIfSaved() {
        guard !started, let ip = UserDefaults.standard.string(forKey: Self.addressKey), !ip.isEmpty else { return }
        started = true
        connect(ip)
    }

    private let bulb = Bulb()
    private let push = PushListener()
    @ObservationIgnored private var sendScheduled = false
    /// What has changed since the last setPilot (coalesced slider moves).
    @ObservationIgnored private var unsent: Set<PilotField> = []
    @ObservationIgnored private var lastPilot: [String: Int] = [:]
    @ObservationIgnored private var lastState: Bool?
    @ObservationIgnored private var sendSeq = 0
    @ObservationIgnored private var verifyingSeq: Int?
    @ObservationIgnored private var verifyTask: Task<Void, Never>?
    @ObservationIgnored private var registerTask: Task<Void, Never>?
    @ObservationIgnored private var rebootTask: Task<Void, Never>?
    /// The power state before the last setState, restored if the bulb never answers it.
    @ObservationIgnored private var powerBefore: Bool?
    /// A different bulb (MAC) answered at the address: ignore everything from it until the next connect.
    @ObservationIgnored private var wrongBulb = false
    @ObservationIgnored private var discoveryTask: Task<[DiscoveredBulb], Never>?
    private let phoneMac = String((0..<12).map { _ in "0123456789abcdef".randomElement()! })

    init() {
        bulb.onReply = { [weak self] in self?.handleReply($0) }
        bulb.onError = { [weak self] method, message in
            guard let self else { return }
            if method == "registration" { // live updates only; not worth the status line
                live = false
                liveStatus = "Live updates off — \(message)"
                return
            }
            status = message
            switch method {
            case "getPilot"?:
                // Connecting, or the bulb has gone away since: look for it at a new address.
                if link == .connecting || link == .connected {
                    link = .unreachable
                    live = false
                    status = "The bulb isn't answering"
                    relocate()
                }
                pending = false
                verifyingSeq = nil
            case "setPilot"?:
                // Couldn't confirm; stop showing the request as pending.
                pending = false
                verifyingSeq = nil
            case "setState"?:
                isOn = powerBefore
                status = "The bulb didn't answer the power switch"
            default:
                break
            }
        }
        push.onMessage = { [weak self] in self?.handlePush($0) }
        push.onFailure = { [weak self] reason in
            self?.registerTask?.cancel()
            self?.live = false
            self?.liveStatus = "Live updates off — \(reason)"
        }
    }

    // MARK: Connection

    /// The saved bulb address (IP or DNS name). Changed by `choose`, and by `relocate` when the
    /// same bulb (same MAC) turns up at a new IP; never by discovery alone.
    static let addressKey = "bulbIP"
    /// MAC of the chosen bulb: its identity, so a different bulb at the same address is never used.
    static let macKey = "bulbMAC"
    static let namesKey = "bulbNames"

    /// Names the user has given bulbs, keyed by lower-case MAC.
    var names: [String: String] = UserDefaults.standard.dictionary(forKey: Model.namesKey) as? [String: String] ?? [:] {
        didSet { UserDefaults.standard.set(names, forKey: Self.namesKey) }
    }

    func name(for mac: String?) -> String? {
        guard let mac else { return nil }
        return names[mac.lowercased()]
    }

    func rename(mac: String, to name: String) {
        let n = name.trimmingCharacters(in: .whitespaces)
        names[mac.lowercased()] = n.isEmpty ? nil : n
    }

    private var savedMAC: String? {
        get { UserDefaults.standard.string(forKey: Self.macKey) }
        set { UserDefaults.standard.set(newValue, forKey: Self.macKey) }
    }

    /// The chosen bulb's name, if it has one.
    var currentName: String? { name(for: savedMAC ?? mac) }

    /// The chosen bulb's MAC, once known.
    var chosenMAC: String? { savedMAC ?? mac?.lowercased() }

    @ObservationIgnored private var relocating = false

    /// The bulb the user picked or typed: saved, then connected to. `mac` is known for a bulb
    /// picked from discovery; for a typed address it's learnt from the bulb's first reply.
    func choose(_ address: String, mac: String? = nil) {
        let a = address.trimmingCharacters(in: .whitespaces)
        guard !a.isEmpty else { return }
        // Picking the bulb that's already connected changes nothing.
        if a == UserDefaults.standard.string(forKey: Self.addressKey), link == .connected,
           mac == nil || mac?.lowercased() == chosenMAC { return }
        UserDefaults.standard.set(a, forKey: Self.addressKey)
        savedMAC = mac?.lowercased()
        started = true
        connect(a)
    }

    @ObservationIgnored private var connectGeneration = 0

    func connect(_ ip: String) {
        connectGeneration += 1
        let generation = connectGeneration
        bulb.connect(to: ip)
        verifyTask?.cancel()
        rebootTask?.cancel()
        verifyingSeq = nil
        pending = false
        mismatch = nil
        wrongBulb = false
        // Nothing carries over from the previous bulb.
        isOn = nil
        rssi = nil
        minDimming = 10
        tempRange = 2200...6500
        fadeIn = nil
        fadeOut = nil
        mac = nil
        module = nil
        firmware = nil
        info = [:]
        live = false
        pushSeen = false
        link = ip.trimmingCharacters(in: .whitespaces).isEmpty ? .none : .connecting
        status = ""
        bulb.send("getPilot", retry: true)
        bulb.send("getModelConfig", retry: true)
        bulb.send("getSystemConfig", retry: true)
        bulb.send("getUserConfig", retry: true)
        addressDetail = nil
        // The other form of the address (DNS name for an IP, IP for a name), and an IPv4 address
        // for live updates. Lookups block, so off the main thread.
        let host = ip.trimmingCharacters(in: .whitespaces)
        // Live updates start as soon as there's an address; the reverse lookup can take a long time
        // (e.g. no PTR record), so it doesn't hold them up.
        Task { [weak self] in
            let v4 = await Task.detached { Net.resolveIPv4(host) }.value
            guard let self, self.connectGeneration == generation else { return } // a newer connect won
            if let v4, v4 != host { self.addressDetail = v4 }
            self.startLiveUpdates(v4 ?? host)
            guard let v4, v4 == host else { return } // a DNS name was given: its IP is the detail
            let name = await Task.detached { Net.reverseName(v4) }.value
            guard self.connectGeneration == generation, let name, name != host else { return }
            self.addressDetail = name
        }
    }

    /// pywizlight's push method: tell the bulb our IP every 20 s; it sends syncPilot to port 38900.
    private func startLiveUpdates(_ ip: String) {
        registerTask?.cancel()
        push.startIfNeeded()
        guard push.isRunning else { return }
        guard let phoneIp = Net.sourceIP(toward: ip.trimmingCharacters(in: .whitespaces)) else {
            liveStatus = "Live updates off — couldn't find an IPv4 address for the bulb"
            return
        }
        liveStatus = "Registering for live updates…"
        let params: [String: Any] = ["phoneIp": phoneIp, "register": true, "phoneMac": phoneMac]
        registerTask = Task { [weak self] in
            while !Task.isCancelled {
                self?.bulb.send("registration", params)
                try? await Task.sleep(for: .seconds(20))
            }
        }
    }

    /// Whether a reply comes from the chosen bulb. Learns the MAC the first time (for a typed
    /// address); a different MAC means another bulb now has the saved address, so its replies are
    /// ignored and the chosen bulb is looked for elsewhere.
    private func isChosenBulb(_ replyMAC: String) -> Bool {
        let m = replyMAC.lowercased()
        guard let saved = savedMAC else {
            savedMAC = m
            return true
        }
        guard saved == m else {
            wrongBulb = true
            link = .unreachable
            live = false
            status = "A different bulb answered at this address"
            relocate()
            return false
        }
        return true
    }

    /// If the chosen bulb (known by MAC) isn't at its saved IP, search for it and reconnect at its
    /// new address. Never switches to another bulb, and leaves DNS names alone.
    private func relocate() {
        #if os(macOS)
        guard !relocating, let saved = savedMAC,
              let address = UserDefaults.standard.string(forKey: Self.addressKey),
              Net.isIPv4(address) else { return }
        relocating = true
        Task {
            defer { relocating = false }
            let label = name(for: saved) ?? saved
            status = "Looking for \(label) on the network…"
            let found = await discover()
            guard UserDefaults.standard.string(forKey: Self.addressKey) == address else { return } // user chose another
            if let bulb = found.first(where: { $0.mac.lowercased() == saved }), bulb.ip != address {
                UserDefaults.standard.set(bulb.ip, forKey: Self.addressKey)
                connect(bulb.ip)
                status = "\(label) moved to \(bulb.ip); reconnected" // after connect, which clears it
            } else if found.contains(where: { $0.mac.lowercased() == saved }) {
                // It answered the search, so try once more (a further failure doesn't search again).
                status = "\(label) is on the network; trying again"
                bulb.send("getPilot", retry: true)
            } else {
                status = "Couldn't find \(label) on the network"
            }
        }
        #else
        // No discovery on iOS (no broadcasts without the multicast entitlement): a bulb chosen by
        // DNS name is found again by name, and one chosen by IP has to be chosen again.
        #endif
    }

    #if os(macOS)
    /// Searches for bulbs, filling `discovered` as they answer and adding DNS names as lookups
    /// finish. Never changes the chosen bulb. Returns what it found; a call while a search is
    /// running waits for that search.
    @discardableResult
    func discover() async -> [DiscoveredBulb] {
        if let discoveryTask { return await discoveryTask.value }
        let task = Task { await runDiscovery() }
        discoveryTask = task
        let found = await task.value
        discoveryTask = nil
        return found
    }

    private func runDiscovery() async -> [DiscoveredBulb] {
        discovering = true
        defer { discovering = false }
        discovered = []
        discoveryNote = nil
        if await Net.requestLocalNetworkAccess() == .denied {
            discoveryNote = Self.localNetworkHelp
            return []
        }
        let onFound: @Sendable (DiscoveredBulb) -> Void = { bulb in
            Task { @MainActor [weak self] in self?.addDiscovered(bulb) }
        }
        var result = await Task.detached { Net.discover(onFound: onFound) }.value
        // While the permission prompt is up (or unanswered), every broadcast is refused: wait for
        // an answer, retrying for up to a minute.
        var waited = 0
        while result.blocked && waited < 30 {
            discoveryNote = "Waiting for Local Network access: allow setPilot in the prompt"
            try? await Task.sleep(for: .seconds(2))
            waited += 1
            if waited % 5 == 0, await Net.requestLocalNetworkAccess() == .denied { break }
            result = await Task.detached { Net.discover(onFound: onFound) }.value
        }
        if result.blocked {
            discoveryNote = Self.localNetworkHelp
            return []
        }
        discoveryNote = result.bulbs.isEmpty ? "No bulbs found" : nil
        for bulb in result.bulbs where !discovered.contains(where: { $0.mac == bulb.mac }) { addDiscovered(bulb) }
        return discovered
    }

    private func addDiscovered(_ bulb: DiscoveredBulb) {
        guard !discovered.contains(where: { $0.mac == bulb.mac }) else { return }
        discovered.append(bulb)
        discovered.sort { $0.ip.compare($1.ip, options: .numeric) == .orderedAscending }
        let ip = bulb.ip
        Task { [weak self] in
            guard let name = await Task.detached(operation: { Net.reverseName(ip) }).value,
                  let self, let i = self.discovered.firstIndex(where: { $0.mac == bulb.mac }) else { return }
            self.discovered[i].name = name
        }
    }

    private static let localNetworkHelp =
        "setPilot needs Local Network access to find bulbs: turn it on in System Settings › Privacy & Security › Local Network"

    #endif

    // MARK: Commands

    func sync() {
        verifyingSeq = nil
        pending = false
        bulb.send("getPilot", retry: true)
    }

    func power(_ on: Bool) {
        powerBefore = isOn
        isOn = on
        bulb.send("setState", ["state": on], retry: true)
    }

    func setMode(_ m: Mode) {
        mode = m
        // A scene that can't be sent (Rhythm, or a deleted custom scene): start with the first one.
        if m == .scene, !Scenes.isKnown(sceneId), !(sceneId == Scenes.inlineCustom && customSceneId.flatMap(library.customScene) != nil) {
            sceneId = Scenes.all[0].id
            customSceneId = nil
        }
        sendPilot([.colour], retry: true)
    }
    func setScene(_ id: Int) {
        customSceneId = nil
        sceneId = id
        sendPilot([.colour], retry: true)
    }

    func readConfig() {
        for m in ["getSystemConfig", "getModelConfig", "getUserConfig", "getPower"] {
            bulb.send(m, retry: true)
        }
    }

    /// Not retried: the bulb may go away before it answers.
    func reboot() {
        bulb.send("reboot")
        status = "Rebooting…"
        // Read it back once it's had time to restart (retried for ~15 s more).
        rebootTask?.cancel()
        rebootTask = Task {
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled else { return }
            bulb.send("getPilot", retry: true)
        }
    }

    /// Coalesces slider drags into at most one setPilot per ~40 ms.
    func changed(_ field: PilotField) {
        unsent.insert(field)
        guard !sendScheduled else { return }
        sendScheduled = true
        Task {
            try? await Task.sleep(for: .milliseconds(40))
            sendScheduled = false
            sendPilot([], retry: false)
        }
    }

    /// Sends only what changed (a whole colour, dimming or speed): the firmware ignores some valid
    /// parameters when they're combined with others, and leaving the rest out doesn't undo
    /// concurrent changes from other apps. `switchOn` is for deliberate actions (a preset): it
    /// leaves `state` out, which turns the bulb on.
    private func sendPilot(_ fields: Set<PilotField>, retry: Bool, switchOn: Bool = false) {
        let fields = unsent.union(fields)
        unsent = []
        var p: [String: Any] = [:]
        if fields.contains(.dimming) { p["dimming"] = Int(dimming) }
        if fields.contains(.colour) {
            switch mode {
            case .rgbcw:
                // All five, zeros included: the colour is one setting.
                p.merge(["r": r, "g": g, "b": b, "c": c, "w": w].mapValues { Int($0) }) { $1 }
            case .temp:
                p["temp"] = Int(temp)
            case .scene:
                if sceneId == Scenes.inlineCustom {
                    // One of ours: the definition goes with it, as the bulb can't keep it.
                    if let id = customSceneId, let scene = library.customScene(id) {
                        p["sceneId"] = sceneId
                        p["elm"] = scene.elm
                    }
                } else if Scenes.isKnown(sceneId) {
                    // Rhythm and unknown IDs (as reported by the bulb) can't be set.
                    p["sceneId"] = sceneId
                }
            }
        }
        // Speed only takes when it's sent on its own (a firmware bug), so it's a separate request.
        let speedParams: [String: Any]? = fields.contains(.speed) && mode == .scene ? ["speed": Int(speed)] : nil
        guard !p.isEmpty || speedParams != nil else { return }
        if !p.isEmpty {
            if let fade = Self.fade { p["trans"] = fade }
            if switchOn {
                isOn = true
            } else if isOn == false {
                // A setPilot without "state" switches the bulb on: say so only when it's off.
                p["state"] = false
            }
        }
        let shown = p.isEmpty ? speedParams! : p
        if let data = try? JSONSerialization.data(withJSONObject: shown, options: .sortedKeys) {
            lastSent = String(decoding: data, as: UTF8.self)
        }
        lastPilot = p.filter { $0.key != "state" && $0.key != "trans" }.compactMapValues { $0 as? Int }
        if let speedParams { lastPilot["speed"] = speedParams["speed"] as? Int }
        lastState = isOn
        sendSeq += 1
        pending = true
        if !p.isEmpty { bulb.send("setPilot", p, retry: retry) }
        if let speedParams {
            if p.isEmpty {
                bulb.send("setPilot", speedParams, retry: retry)
            } else {
                // After the scene has started (and so retries of the two don't overlap).
                Task {
                    try? await Task.sleep(for: .milliseconds(400))
                    bulb.send("setPilot", speedParams, retry: retry)
                }
            }
        }
        scheduleVerify()
    }

    /// Sets the brightness straight away, with retries (Shortcuts; sliders go through `changed`).
    func setDimming(_ level: Double) {
        dimming = min(max(level.rounded(), minDimming), 100)
        sendPilot([.dimming], retry: true)
    }

    /// Plays one of setPilot's custom scenes (sent inline: nothing is stored on the bulb).
    func playCustom(_ scene: CustomScene, switchOn: Bool = false) {
        customSceneId = scene.id
        mode = .scene
        sceneId = Scenes.inlineCustom
        sendPilot([.colour], retry: true, switchOn: switchOn)
    }

    /// Applies a preset, switching the bulb on if it's off.
    func apply(_ preset: Preset) {
        var fields: Set<PilotField> = [.colour, .dimming]
        switch preset.colour {
        case let .rgbcw(r, g, b, c, w):
            mode = .rgbcw
            (self.r, self.g, self.b, self.c, self.w) = (Double(r), Double(g), Double(b), Double(c), Double(w))
        case let .temp(k):
            mode = .temp
            temp = Double(k)
        case let .scene(id, speed):
            mode = .scene
            sceneId = id
            if let speed { self.speed = Double(speed); fields.insert(.speed) }
        case let .custom(id, speed):
            guard library.customScene(id) != nil else {
                status = "That preset's custom scene has been deleted"
                return
            }
            mode = .scene
            sceneId = Scenes.inlineCustom
            customSceneId = id
            if let speed { self.speed = Double(speed); fields.insert(.speed) }
        }
        if case .scene = preset.colour { customSceneId = nil }
        dimming = min(max(Double(preset.dimming), minDimming), 100)
        sendPilot(fields, retry: true, switchOn: true)
    }

    /// What the bulb is showing, as a preset colour (nil for Rhythm and scenes setPilot can't set).
    var currentColour: LightColour? {
        switch mode {
        case .rgbcw: .rgbcw(r: Int(r), g: Int(g), b: Int(b), c: Int(c), w: Int(w))
        case .temp: .temp(Int(temp))
        case .scene:
            if sceneId == Scenes.inlineCustom, let id = customSceneId { .custom(id, speed: Int(speed)) }
            else if Scenes.isKnown(sceneId) { .scene(id: sceneId, speed: Int(speed)) }
            else { nil }
        }
    }

    /// Saves the current light as a new preset.
    @discardableResult
    func savePreset(named name: String) -> Preset? {
        guard let colour = currentColour else {
            status = "This scene can't be saved as a preset"
            return nil
        }
        let n = name.trimmingCharacters(in: .whitespaces)
        let preset = Preset(name: library.uniquePresetName(n.isEmpty ? "Preset" : n), colour: colour, dimming: Int(dimming))
        library.presets.append(preset)
        return preset
    }

    /// Relative brightness (`dimDelta`): the bulb adds it to its own level, so concurrent changes
    /// from elsewhere aren't overwritten.
    func adjustDimming(by delta: Int) {
        guard delta != 0 else { return }
        var p: [String: Any] = ["dimDelta": delta]
        if let fade = Self.fade { p["trans"] = fade }
        if isOn == false { p["state"] = false }
        dimming = min(max(dimming + Double(delta), minDimming), 100)
        if let data = try? JSONSerialization.data(withJSONObject: p, options: .sortedKeys) {
            lastSent = String(decoding: data, as: UTF8.self)
        }
        lastPilot = [:] // the result depends on the bulb's level; just read it back
        lastState = isOn
        sendSeq += 1
        pending = true
        bulb.send("setPilot", p, retry: true)
        scheduleVerify()
    }

    /// Sets the given values and sends the fields named (from the watch).
    func apply(_ v: LightValues, fields: [PilotField]) {
        if v.mode != .scene || v.sceneId != Scenes.inlineCustom { customSceneId = nil }
        mode = v.mode
        (r, g, b, c, w) = (v.r, v.g, v.b, v.c, v.w)
        temp = v.temp
        sceneId = v.sceneId
        speed = v.speed
        dimming = v.dimming
        sendPilot(Set(fields), retry: true)
    }

    var values: LightValues {
        LightValues(mode: mode, r: r, g: g, b: b, c: c, w: w, temp: temp, sceneId: sceneId, speed: speed, dimming: dimming)
    }

    var snapshot: LightSnapshot {
        var s = LightSnapshot()
        s.link = switch link {
        case .none: .none
        case .connecting: .connecting
        case .connected: .connected
        case .unreachable: .unreachable
        }
        s.bulbName = currentName ?? UserDefaults.standard.string(forKey: Self.addressKey)
        s.isOn = isOn
        s.mode = mode
        (s.r, s.g, s.b, s.c, s.w) = (r, g, b, c, w)
        s.temp = temp
        s.sceneId = sceneId
        s.speed = speed
        s.dimming = dimming
        s.minDimming = minDimming
        s.tempMin = tempRange.lowerBound
        s.tempMax = tempRange.upperBound
        s.customScene = mode == .scene && sceneId == Scenes.inlineCustom ? customSceneId : nil
        s.status = mismatch ?? status
        s.pending = pending
        return s
    }

    /// Back in the foreground (iOS suspends sockets in the background): reconnect if live
    /// updates stopped or the bulb went quiet, otherwise just read its state again.
    func resume() {
        guard started, let a = UserDefaults.standard.string(forKey: Self.addressKey), !a.isEmpty else {
            startIfSaved()
            return
        }
        if !push.isRunning || link != .connected { connect(a) } else { sync() }
    }

    /// Connects to the saved bulb if needed and waits until it can be controlled (or `timeout`).
    func waitUntilControllable(timeout: Double = 4) async -> Bool {
        startIfSaved()
        if link == .unreachable { sync() }
        let end = Date().addingTimeInterval(timeout)
        while !canControl && Date() < end { try? await Task.sleep(for: .milliseconds(100)) }
        return canControl
    }

    /// Waits until the last change has been read back (or `timeout`).
    func waitUntilSettled(timeout: Double = 3) async {
        let end = Date().addingTimeInterval(timeout)
        while pending && Date() < end { try? await Task.sleep(for: .milliseconds(100)) }
    }

    /// Once changes settle, read the state back to catch values the bulb ignored or adjusted
    /// (it replies "success" to some setPilots it doesn't fully apply).
    private func scheduleVerify() {
        verifyTask?.cancel()
        verifyTask = Task {
            try? await Task.sleep(for: .milliseconds(700))
            guard !Task.isCancelled else { return }
            verifyingSeq = sendSeq
            bulb.send("getPilot", retry: true)
        }
    }

    private func verify(_ result: [String: Any]) {
        var diffs: [String] = []
        for key in lastPilot.keys.sorted() {
            let want = lastPilot[key]!
            let got = (result[key] as? NSNumber)?.intValue
            // Absent zero channels and speed (static scenes) aren't meaningful differences.
            if got == want || (got == nil && (want == 0 || key == "speed")) { continue }
            diffs.append("\(key) \(want)→\(got.map(String.init) ?? "absent")")
        }
        if let want = lastState, let got = result["state"] as? Bool, got != want {
            diffs.append("state \(want ? "on" : "off")→\(got ? "on" : "off")")
        }
        mismatch = diffs.isEmpty ? nil : "Bulb didn't apply: " + diffs.joined(separator: ", ")
        status = diffs.isEmpty ? "Bulb confirmed" : "Showing the bulb's actual state"
    }

    // MARK: Incoming

    private func handleReply(_ reply: [String: Any]) {
        guard !wrongBulb else { return }
        let method = reply["method"] as? String ?? "?"
        if let err = reply["error"] as? [String: Any] {
            link = .connected
            let text = (err["code"] as? Int) == -32601 ? "not supported by this firmware" : "\(err["message"] ?? err)"
            if method.hasPrefix("get") && method != "getPilot" { info[method] = text }
            status = "\(method): \(text)"
            return
        }
        guard let result = reply["result"] as? [String: Any] else { return }
        if let replyMAC = result["mac"] as? String, !isChosenBulb(replyMAC) { return }
        // Back after not answering (e.g. the 20 s registration got through): re-read its state.
        if link == .unreachable && method != "getPilot" { bulb.send("getPilot", retry: true) }
        link = .connected
        switch method {
        case "getPilot":
            if let seq = verifyingSeq {
                // A newer setPilot went out after this check started; its own check will follow.
                guard seq == sendSeq else { return }
                verifyingSeq = nil
                pending = false
                applyPilot(result)
                verify(result)
            } else {
                applyPilot(result)
                status = "Synced"
            }
        case "getModelConfig", "getUserConfig":
            applyLimits(result)
            info[method] = pretty(result)
        case "getSystemConfig", "getPower":
            if let m = result["mac"] as? String { mac = m }
            if let m = result["moduleName"] as? String { module = m }
            if let f = result["fwVersion"] as? String { firmware = f }
            info[method] = pretty(result)
        case "registration":
            if result["success"] as? Bool == true, push.isRunning, !live {
                live = true
                if !pushSeen {
                    liveStatus = "Registered for live updates; the bulb sends one when its state changes"
                }
            }
        default:
            status = "\(method) ok"
        }
    }

    private func handlePush(_ msg: [String: Any]) {
        guard msg["method"] as? String == "syncPilot",
              let params = msg["params"] as? [String: Any],
              let from = params["mac"] as? String, let mac, from.lowercased() == mac.lowercased()
        else { return }
        let time = Date().formatted(date: .omitted, time: .standard)
        liveStatus = "Live updates on — last push \(time)"
        live = true
        pushSeen = true
        // While a change is unconfirmed, pushes may describe the old state; the read-back settles it.
        if !pending { applyPilot(params) }
    }

    private func applyPilot(_ p: [String: Any]) {
        func num(_ k: String) -> Double? { (p[k] as? NSNumber)?.doubleValue }
        if let m = p["mac"] as? String { mac = m }
        if let s = p["state"] as? Bool { isOn = s }
        if let v = num("rssi") { rssi = Int(v) }
        if let d = num("dimming") { dimming = d }
        let scene = p["schdPsetId"] != nil ? Scenes.rhythm : Int(num("sceneId") ?? 0)
        if scene != 0 {
            mode = .scene
            sceneId = scene
            if let s = num("speed") { speed = s }
        } else if let t = num("temp") {
            mode = .temp
            temp = t
        } else if num("r") != nil || num("c") != nil || num("w") != nil {
            mode = .rgbcw
            r = num("r") ?? 0; g = num("g") ?? 0; b = num("b") ?? 0
            c = num("c") ?? 0; w = num("w") ?? 0
        }
        if mode != .scene || sceneId != Scenes.inlineCustom { customSceneId = nil }
    }

    private func applyLimits(_ result: [String: Any]) {
        if let v = result["fadeIn"] as? NSNumber { fadeIn = v.intValue }
        if let v = result["fadeOut"] as? NSNumber { fadeOut = v.intValue }
        // Only the slider's range: changing `dimming` here would show a level the bulb isn't at.
        if let d = (result["minDimLevel"] as? NSNumber)?.doubleValue, d >= 1, d < 100 {
            minDimming = d
        }
        // pywizlight: extRange (older firmware), else cctRange [min, …, max]
        if let range = (result["extRange"] ?? result["cctRange"]) as? [NSNumber],
           let lo = range.first?.doubleValue, let hi = range.last?.doubleValue, lo < hi {
            tempRange = lo...hi
        }
    }

    private func pretty(_ obj: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys])
        else { return "\(obj)" }
        return String(decoding: data, as: UTF8.self)
    }
}
