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
    /// Kelvin on the active custom CCT scale (Custom CCT mode).
    var customKelvin = UserDefaults.standard.object(forKey: Model.customKelvinKey) as? Double ?? 2700 {
        didSet { UserDefaults.standard.set(customKelvin, forKey: Self.customKelvinKey) }
    }
    static let customKelvinKey = "customKelvin"
    var sceneId = 1
    var speed = 100.0
    var isOn: Bool?
    /// The custom scene playing, while the bulb reports setPilot's inline scene ID.
    var customSceneId: UUID? = UserDefaults.standard.string(forKey: Model.customSceneKey).flatMap(UUID.init) {
        didSet { UserDefaults.standard.set(customSceneId?.uuidString, forKey: Self.customSceneKey) }
    }
    static let customSceneKey = "customScene"
    /// Presets, custom scenes and CCT scales.
    let library = Library()

    /// The fade time setting, in ms (`trans`): the default the controls' Fade and Compose offer;
    /// nil (-1 stored) when there isn't one.
    static var fade: Int? {
        get { (UserDefaults.standard.object(forKey: fadeKey) as? Int).flatMap { $0 >= 0 ? $0 : nil } }
        set { UserDefaults.standard.set(newValue ?? -1, forKey: fadeKey) } // as FadeSetting stores it
    }
    static let fadeKey = "fadeMs"

    /// The fade for changes made with the main controls (sliders, presets, brighter or dimmer, the
    /// power switch): the setting above, none, or a value of their own, as in Compose. Remembered.
    var controlsFade = FadeChoice(rawValue: UserDefaults.standard.string(forKey: Model.controlsFadeKey) ?? "") ?? .setting {
        didSet {
            UserDefaults.standard.set(controlsFade.rawValue, forKey: Self.controlsFadeKey)
            library.onChange?() // widgets' ready-made preset requests carry it
        }
    }
    static let controlsFadeKey = "controlsFade"
    var controlsFadeMs = UserDefaults.standard.object(forKey: Model.controlsFadeMsKey) as? Int ?? 1000 {
        didSet {
            UserDefaults.standard.set(controlsFadeMs, forKey: Self.controlsFadeMsKey)
            library.onChange?()
        }
    }
    static let controlsFadeMsKey = "controlsFadeMs"
    /// The `trans` the main controls send, if any.
    var fadeForControls: Int? { controlsFade.trans(setting: Self.fade, custom: controlsFadeMs) }

    // From getModelConfig / getUserConfig
    var minDimming = 10.0
    var tempRange: ClosedRange<Double> = 2200...6500
    /// The bulb's own fades (getUserConfig), in ms: when turning on or changing, and turning off.
    var fadeIn: Int?
    var fadeOut: Int?
    /// getModelConfig's `cctRange` and `renderFactor`, for rebuilding the bulb's CCT table.
    var cctRange: [Int]?
    var renderFactor: [Int]?

    var mac: String?
    var module: String?
    var firmware: String?
    var rssi: Int?
    var info: [String: String] = [:] // method -> pretty-printed result (or why there isn't one)
    /// Device info reads that failed: method -> what went wrong, in a few words.
    var infoErrors: [String: String] = [:]
    /// Device info reads sent and not yet answered (or given up on): a re-read shows as reading.
    var infoReading: Set<String> = []
    /// Every message to and from the bulb (and pushes), oldest first, for the console.
    var log: [LogEntry] = []
    /// The console's last request: its method while waiting ("" for the next message of any
    /// method, after a raw message without one), then the reply as received, or what went wrong.
    var consoleWaiting: String? {
        didSet { consoleRequest += 1 }
    }
    @ObservationIgnored private var consoleRequest = 0
    /// Sent once without retry, nothing says if no reply comes: stop waiting after a while.
    private func endConsoleWait(after retry: Bool) {
        guard !retry else { return }
        let request = consoleRequest
        Task {
            try? await Task.sleep(for: .seconds(3))
            guard consoleRequest == request, consoleWaiting != nil else { return }
            consoleWaiting = nil
            consoleFailure = "No reply within 3 s (sent once: Retry was off, or the message has no method to retry by)"
        }
    }
    var consoleReply: String?
    var consoleFailure: String?
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
    /// The last command's params as JSON, and its method (setPilot; setState only from the console).
    var lastSent = ""
    var lastMethod = "setPilot"
    /// The last command as a whole request, for copying.
    var lastCommandJSON: String { #"{"method":"\#(lastMethod)","params":\#(lastSent)}"# }
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

    /// The Light controls show Compose (a change prepared, then sent in one go) instead of the
    /// live sliders. In the window and the menu bar panel alike.
    var composing = false {
        didSet { if composing, !draft.loaded { loadDraft() } }
    }
    let draft = ComposeDraft()
    private let push = PushListener()
    @ObservationIgnored private var sendScheduled = false
    /// What has changed since the last setPilot (coalesced slider moves).
    @ObservationIgnored private var unsent: Set<PilotField> = []
    /// A scene speed changed while the bulb was off, so not sent (on its own it would switch it
    /// on): it goes once the bulb is on, with the next change or after switching on.
    private var speedOwed = false // observed: Compose's preview shows it (owedSpeed)
    /// A scene's speed waiting to go after the scene: a newer speed replaces it, rather than this
    /// one landing after it.
    @ObservationIgnored private var delayedSpeed: Task<Void, Never>?
    /// The setPilot just sent switches the bulb on or off (the power switch, a preset): if it gets
    /// no answer, the power switch goes back to how it was.
    @ObservationIgnored private var pilotSwitches = false
    /// The latest change's setPilot was answered "success" (outcome() counts that as taken; the
    /// scripting runner also waits for the read-back after it).
    @ObservationIgnored private var pilotAnswered = false
    /// Why the last change (setPilot or setState) didn't take: the bulb's refusal, or no answer.
    /// Nil once another is sent. For Shortcuts, which otherwise only see that it was sent.
    @ObservationIgnored private(set) var refusal: String? {
        didSet { if refusal == nil { changeMark += 1 } }
    }
    /// Counts changes started (each clears `refusal`): a reason read later belongs to the change
    /// made at a mark only if the mark is still the same.
    @ObservationIgnored private(set) var changeMark = 0
    /// Starts an action whose refusal will be reported: one that sends nothing (already as asked)
    /// mustn't report an earlier change's reason.
    func forgetRefusal() { refusal = nil }
    /// Reads after refused setPilots, still to come: they put the controls right, leaving the
    /// error as the status (one per refusal: a slider drag can be refused several times over).
    @ObservationIgnored private var quietReads = 0
    @ObservationIgnored private var lastPilot: [String: Int] = [:]
    @ObservationIgnored private var lastState: Bool?
    @ObservationIgnored private var sendSeq = 0
    @ObservationIgnored private var verifyingSeq: Int?
    @ObservationIgnored private var verifyTask: Task<Void, Never>?
    @ObservationIgnored private var registerTask: Task<Void, Never>?
    /// The power state before the last switch (or the console's setState), restored if the bulb
    /// never answers it.
    @ObservationIgnored private var powerBefore: Bool?
    /// A different bulb (MAC) answered at the address: ignore everything from it until the next connect.
    @ObservationIgnored private var wrongBulb = false
    @ObservationIgnored private var discoveryTask: Task<[DiscoveredBulb], Never>?
    private let phoneMac = String((0..<12).map { _ in "0123456789abcdef".randomElement()! })

    init() {
        // Bulb names sync through iCloud too (in builds with it), keyed by MAC. Older builds kept
        // them whole in key-value storage: take any not here yet, once.
        if CloudSync.isEnabled, !UserDefaults.standard.bool(forKey: "cloudKeyValueNamesTaken") {
            UserDefaults.standard.set(true, forKey: "cloudKeyValueNamesTaken")
            if let d = CloudSync.legacyValue(Self.namesKey), let v = try? JSONDecoder().decode([String: String].self, from: d) {
                names.merge(v) { mine, _ in mine }
            }
        }
        bulb.onReply = { [weak self] in self?.handleReply($0) }
        bulb.onSent = { [weak self] method, text in self?.appendLog(.sent, method: method, text: text) }
        bulb.onReceived = { [weak self] text in
            guard let self else { return }
            let obj = Net.json(Data(text.utf8))
            let method = obj?["method"] as? String ?? ""
            appendLog(.received, method: method, text: text)
            // Waiting on "" (a raw message without a method): anything but the 20 s registration.
            if let waiting = consoleWaiting, waiting.isEmpty ? method != "registration" : method == waiting {
                consoleWaiting = nil
                consoleReply = text
            }
        }
        bulb.onError = { [weak self] method, message in
            guard let self else { return }
            appendLog(.failure, method: method ?? "", text: message)
            if let method, BulbAPI.deviceInfo.contains(method) {
                // A read again that got no answer: flagged, with what an earlier read showed kept.
                if info[method] == nil { info[method] = JSONText.pretty(["error": message]) }
                infoErrors[method] = "No reply"
                infoReading.remove(method)
            }
            // Waiting on "" (a raw message without a method): anything but the 20 s registration.
            if let waiting = consoleWaiting, waiting.isEmpty ? method != "registration" : method == waiting {
                consoleWaiting = nil
                consoleFailure = message
            }
            if method == "registration" { // live updates only; not worth the status line
                live = false
                liveStatus = "Live updates off — \(message)"
                return
            }
            // A device info read (flagged above) isn't worth the status line, as for its error
            // replies: connecting sends four at once, and the others failing would replace
            // getPilot's "isn't answering" (or Local Network access) message with theirs.
            if let method, method != "getPilot", BulbAPI.deviceInfo.contains(method) { return }
            status = message
            if method == nil { connectionLost() }
            switch method {
            case "getPilot"?:
                quietReads = 0 // the reads aren't coming
                // Connecting, or the bulb has gone away since: look for it at a new address.
                if link == .connecting || link == .connected {
                    link = .unreachable
                    live = false
                    if bulb.localNetworkDenied {
                        #if os(iOS)
                        status = "setPilot needs Local Network access: turn it on in Settings › Apps › setPilot, then try again"
                        #else
                        status = "setPilot needs Local Network access: turn it on in System Settings › Privacy & Security › Local Network"
                        #endif
                    } else {
                        status = "The bulb isn't answering"
                        relocate()
                    }
                }
                pending = false
                verifyingSeq = nil
            case "setPilot"?:
                // Couldn't confirm; stop showing the request as pending.
                pending = false
                verifyingSeq = nil
                refusal = message
                if pilotSwitches { // it was to switch the bulb: as far as we know, it didn't
                    isOn = powerBefore
                    lastState = powerBefore
                    pilotSwitches = false
                    status = "The bulb didn't answer the power switch"
                }
            case "setState"?:
                isOn = powerBefore
                lastState = powerBefore
                status = "The bulb didn't answer the power switch"
                refusal = status
            default:
                break
            }
        }
        push.onMessage = { [weak self] obj, text in
            self?.appendLog(.push, method: obj["method"] as? String ?? "", text: text)
            self?.handlePush(obj)
        }
        push.onFailure = { [weak self] reason in
            self?.registerTask?.cancel()
            self?.live = false
            self?.liveStatus = "Live updates off — \(reason)"
        }
        // iCloud sync (builds with WIZ_ICLOUD): settings through key-value storage, the library
        // and names item by item.
        NotificationCenter.default.addObserver(forName: CloudSync.settingsChanged, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.reloadSyncedSettings() }
        }
        CloudSync.shared.start()
        CloudLibrary.shared.start(model: self)
        CloudDocuments.shared.start()
    }

    /// Settings from another device (CloudSync) have been written to the defaults: take them.
    private func reloadSyncedSettings() {
        let defaults = UserDefaults.standard
        let fade = FadeChoice(rawValue: defaults.string(forKey: Self.controlsFadeKey) ?? "") ?? .setting
        if fade != controlsFade { controlsFade = fade }
        let ms = defaults.object(forKey: Self.controlsFadeMsKey) as? Int ?? 1000
        if ms != controlsFadeMs { controlsFadeMs = ms }
        library.onChange?() // the widgets' ready-made requests carry the fade setting too
    }

    // MARK: Connection

    /// The saved bulb address (IP or DNS name). Changed by `choose`, and by `relocate` when the
    /// same bulb (same MAC) turns up at a new IP; never by discovery alone.
    static let addressKey = "bulbIP"
    /// MAC of the chosen bulb: its identity, so a different bulb at the same address is never used.
    static let macKey = "bulbMAC"
    static let namesKey = "bulbNames"
    static let knownBulbsKey = "knownBulbs"

    /// Bulbs used with this app, most recent first (for choosing on iPhone and the watch).
    var knownBulbs: [KnownBulb] = {
        guard let d = UserDefaults.standard.data(forKey: Model.knownBulbsKey) else { return [] }
        return (try? JSONDecoder().decode([KnownBulb].self, from: d)) ?? []
    }() {
        didSet {
            if let d = try? JSONEncoder().encode(knownBulbs) { UserDefaults.standard.set(d, forKey: Self.knownBulbsKey) }
        }
    }

    /// Records a bulb's address (and MAC, once known), moving it to the top of `knownBulbs`.
    func rememberBulb(address: String, mac: String?) {
        let m = mac?.lowercased()
        var list = knownBulbs
        // The bulb by its MAC first: an entry with just the address may be another (or a typed one
        // not yet answered).
        let i = (m.flatMap { m in list.firstIndex { $0.mac == m } }) ?? list.firstIndex { $0.address == address }
        var entry = i.map { list.remove(at: $0) } ?? KnownBulb(address: address)
        entry.address = address
        if let m { entry.mac = m }
        // Any other entry with the same address was another bulb that had it before, or this one
        // typed before its MAC was known; one with the same MAC is this bulb at an old address.
        list.removeAll { $0.address == address || (entry.mac != nil && $0.mac == entry.mac) }
        list.insert(entry, at: 0)
        knownBulbs = Array(list.prefix(12))
    }

    func forgetBulb(_ bulb: KnownBulb) { knownBulbs.removeAll { $0.id == bulb.id } }

    /// Known bulbs with their names filled in.
    var namedBulbs: [KnownBulb] { knownBulbs.map { var b = $0; b.name = name(for: b.mac); return b } }

    /// Names the user has given bulbs, keyed by lower-case MAC.
    var names: [String: String] = UserDefaults.standard.dictionary(forKey: Model.namesKey) as? [String: String] ?? [:] {
        didSet {
            UserDefaults.standard.set(names, forKey: Self.namesKey)
            if !namesFromCloud { CloudLibrary.shared.localChanged(.bulbName) }
        }
    }
    @ObservationIgnored private var namesFromCloud = false

    /// Names from iCloud (CloudLibrary), which aren't sent back.
    func setNamesFromCloud(_ new: [String: String]) {
        namesFromCloud = true
        names = new
        namesFromCloud = false
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
        set {
            UserDefaults.standard.set(newValue, forKey: Self.macKey)
            refreshSigning()
        }
    }

    // MARK: Signing

    static let signingKeysKey = "signingKeys"

    /// Signing keys for bulbs whose firmware wants signed requests, keyed by lower-case MAC: the
    /// home's udp_signing_key, as 32 hex digits. Kept on this device only.
    var signingKeys: [String: String] = UserDefaults.standard.dictionary(forKey: Model.signingKeysKey) as? [String: String] ?? [:] {
        didSet {
            UserDefaults.standard.set(signingKeys, forKey: Self.signingKeysKey)
            refreshSigning()
        }
    }

    /// The bulb answers with signatures, so it may want its requests signed too.
    var bulbSigns = false

    func signingKey(for mac: String?) -> String? {
        guard let mac else { return nil }
        return signingKeys[mac.lowercased()]
    }

    /// Sets (or with nil or an empty string, removes) a bulb's key. Returns false, changing
    /// nothing, if the text isn't 32 hex digits.
    @discardableResult
    func setSigningKey(_ text: String?, for mac: String) -> Bool {
        let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if trimmed.isEmpty {
            signingKeys[mac.lowercased()] = nil
            return true
        }
        guard let key = RequestSigning.normalised(trimmed) else { return false }
        signingKeys[mac.lowercased()] = key
        return true
    }

    /// Whether requests to the chosen bulb are signed.
    var signing: Bool { signingKey(for: chosenMAC) != nil }

    private func refreshSigning() {
        let key = signingKey(for: chosenMAC)
        bulb.signingKey = key
        // For the widget extension's own requests (WidgetPublisher keeps it up to date too).
        SharedStore.defaults.set(key, forKey: SharedStore.signingKeyKey)
    }

    /// The chosen bulb's name, if it has one.
    var currentName: String? { name(for: savedMAC ?? mac) }

    /// The chosen bulb's MAC, once known.
    var chosenMAC: String? { savedMAC ?? mac?.lowercased() }

    @ObservationIgnored private var relocating = false
    /// The address relocate last reconnected to because the bulb answered a search there, so that
    /// a bulb that answers searches but not requests is tried once, not round and round.
    @ObservationIgnored private var retriedAt: String?

    /// The bulb the user picked or typed: saved, then connected to. `mac` is known for a bulb
    /// picked from discovery; for a typed address it's learnt from the bulb's first reply.
    func choose(_ address: String, mac: String? = nil) {
        let a = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !a.isEmpty else { return }
        retriedAt = nil // chosen by hand: worth another try if it doesn't answer
        // Picking the bulb that's already connected changes nothing.
        if a == UserDefaults.standard.string(forKey: Self.addressKey), link == .connected,
           mac == nil || mac?.lowercased() == chosenMAC { return }
        // The same bulb again (to retry it, say): by its MAC, or its address if no MAC is given.
        let sameBulb = mac.map { $0.lowercased() == chosenMAC } ?? (a == UserDefaults.standard.string(forKey: Self.addressKey))
        UserDefaults.standard.set(a, forKey: Self.addressKey)
        // The saved address again without a MAC (typed in to retry it) keeps its identity: what
        // finds it if it's moved, refuses another device at the address, and signs.
        if let mac { savedMAC = mac.lowercased() } else if !sameBulb { savedMAC = nil }
        rememberBulb(address: a, mac: mac)
        // A draft is for the bulb it was started on (its scales, its state). The same bulb again
        // keeps it, as reconnecting does (coming back from the background, a new IP).
        if !sameBulb {
            infoWanted = false // another bulb's: read when it's asked for
            composing = false
            draft.loaded = false
        }
        started = true
        connect(a)
    }

    @ObservationIgnored private var connectGeneration = 0

    @ObservationIgnored private var lastConnect = Date.distantPast

    func connect(_ ip: String) {
        lastConnect = .now
        connectGeneration += 1
        let generation = connectGeneration
        bulb.connect(to: ip)
        verifyTask?.cancel()
        verifyingSeq = nil
        pending = false
        mismatch = nil
        wrongBulb = false
        unsent = [] // a slider move still waiting was for the previous bulb
        quietReads = 0
        speedOwed = false
        pilotSwitches = false // a switch still unanswered was for the previous bulb
        if consoleWaiting != nil { // its answer would be the new connection's, or never come
            consoleWaiting = nil
            consoleFailure = "Reconnected (or another bulb chosen) before a reply came: send it again"
        }
        // Nothing carries over from the previous bulb.
        isOn = nil
        rssi = nil
        minDimming = 10
        tempRange = 2200...6500
        fadeIn = nil
        fadeOut = nil
        cctRange = nil
        renderFactor = nil
        mac = nil
        refreshSigning()
        bulbSigns = false
        module = nil
        firmware = nil
        // Device info read in full (or being read) is read again from the new connection: the old
        // one's replies, and its retries' giving up, won't come.
        let rereadInfo = infoWanted
        configTask?.cancel()
        infoReading = []
        info = [:]
        infoErrors = [:]
        live = false
        pushSeen = false
        link = ip.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? .none : .connecting
        status = ""
        bulb.send("getPilot", retry: true)
        bulb.send("getModelConfig", retry: true)
        bulb.send("getSystemConfig", retry: true)
        bulb.send("getUserConfig", retry: true)
        if rereadInfo { readConfig(skipping: ["getPilot", "getModelConfig", "getSystemConfig", "getUserConfig"]) }
        addressDetail = nil
        // The other form of the address (DNS name for an IP, IP for a name), and an IPv4 address
        // for live updates. Lookups block, so off the main thread.
        let host = ip.trimmingCharacters(in: .whitespacesAndNewlines)
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

    @ObservationIgnored private var lastAutoReconnect = Date.distantPast

    /// The connection to the bulb failed (it takes no more replies): say so, and make a new one,
    /// at most every 30 s; failing again within that, search for it (Mac). Otherwise the next
    /// foreground, Shortcut or watch command reconnects, as the link is unreachable.
    private func connectionLost() {
        link = .unreachable
        live = false
        // A change that never got its answer didn't take as far as we know (Shortcuts say so).
        if pending, !pilotAnswered, refusal == nil { refusal = "Lost the connection to the bulb before it answered." }
        pending = false
        verifyingSeq = nil
        guard let a = UserDefaults.standard.string(forKey: Self.addressKey), !a.isEmpty else { return }
        let since = Date.now.timeIntervalSince(lastAutoReconnect)
        guard since > 30 else {
            // Lost again straight after reconnecting: on the Mac, look for the bulb elsewhere (it
            // may have a new address, and another device its old one), and try again once the 30 s
            // are up (the lost connection hears nothing more, even if the bulb comes back).
            relocate()
            reconnect(a, after: 30 - since)
            return
        }
        lastAutoReconnect = .now
        let generation = connectGeneration
        status += "; reconnecting…"
        Task {
            try? await Task.sleep(for: .seconds(2))
            guard connectGeneration == generation, UserDefaults.standard.string(forKey: Self.addressKey) == a else { return }
            connect(a)
        }
    }

    @ObservationIgnored private var reconnectTask: Task<Void, Never>?

    /// A new connection to `address` after `seconds`, unless the bulb is back by then (or another
    /// was chosen). The latest call wins: one for a connection lost since replaces it.
    private func reconnect(_ address: String, after seconds: Double) {
        reconnectTask?.cancel()
        reconnectTask = Task {
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled, link == .unreachable,
                  UserDefaults.standard.string(forKey: Self.addressKey) == address else { return }
            lastAutoReconnect = .now
            connect(address)
        }
    }

    /// pywizlight's push method: tell the bulb our IP every 20 s; it sends syncPilot to port 38900.
    private func startLiveUpdates(_ ip: String) {
        liveHost = ip
        lastRegistration = .now
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
                self?.lastRegistration = .now
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
            if let a = UserDefaults.standard.string(forKey: Self.addressKey) { rememberBulb(address: a, mac: m) }
            return true
        }
        guard saved == m else {
            wrongBulb = true
            link = .unreachable
            live = false
            registerTask?.cancel() // not the other bulb's pushes
            registerTask = nil
            // Its replies are dropped from now on: a change waiting on a read-back isn't pending.
            verifyTask?.cancel()
            verifyingSeq = nil
            pending = false
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
                rememberBulb(address: bulb.ip, mac: saved)
                connect(bulb.ip)
                status = "\(label) moved to \(bulb.ip); reconnected" // after connect, which clears it
            } else if found.contains(where: { $0.mac.lowercased() == saved }), retriedAt != address {
                // It answered the search, so try once more, with a new connection in case the old
                // one is what failed (a further failure doesn't come back here).
                retriedAt = address
                connect(address)
                status = "\(label) is on the network; trying again" // after connect, which clears it
            } else if found.contains(where: { $0.mac.lowercased() == saved }) {
                status = "\(label) answers searches but not requests at \(address)"
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

    /// Reads the state again. `quiet`: without saying "Synced" (a read the user didn't ask for,
    /// which shouldn't replace what the status says).
    func sync(quiet: Bool = false) {
        verifyingSeq = nil
        pending = false
        if quiet { quietReads += 1 } else { quietReads = 0 } // asked for: this one says so
        bulb.send("getPilot", retry: true)
    }

    /// Switches the bulb on or off: a setPilot with "state" (and the controls' fade, which the
    /// bulb takes switching on and may one day switching off), rather than setState, so it goes
    /// the way every other change does (read back, refusals reported). A speed changed while it
    /// was off goes with switching on.
    func power(_ on: Bool) {
        var p: [String: Any] = [:]
        if let fade = fadeForControls { p["trans"] = fade }
        let owed = on && speedOwed && mode == .scene ? Int(speed) : nil
        transmit(p, speed: owed, power: on, retry: true)
    }

    /// Switches between the three controls. Temperature goes back to whichever scale it last used:
    /// the bulb's own, or a CCT scale (if this bulb still has one).
    func setModeChoice(_ choice: ModeChoice) {
        switch choice {
        case .rgbcw: setMode(Mode.rgbcw)
        case .scenes: setMode(Mode.scene)
        case .temperature:
            guard mode.choice != .temperature else { return }
            let scale = temperatureUsesScale && activeScale?.range != nil
            setMode(scale ? Mode.custom : Mode.temp)
        }
    }
    /// Temperature last used a CCT scale rather than the bulb's own.
    static let temperatureScaleKey = "temperatureUsesScale"
    /// Observed (the CCT scales' "in use" mark follows it), and kept in the defaults.
    var temperatureUsesScale = UserDefaults.standard.bool(forKey: Model.temperatureScaleKey) {
        didSet { UserDefaults.standard.set(temperatureUsesScale, forKey: Self.temperatureScaleKey) }
    }

    /// Temperature's scale: nil for the bulb's own (`temp`), otherwise one of this bulb's CCT scales
    /// (Custom CCT). The kelvin carries over, kept within the new scale's range.
    var temperatureScale: UUID? { mode == .custom ? activeScale?.id : nil }

    /// The scale Temperature uses (whether or not the light is on Temperature now).
    var scaleForTemperature: UUID? {
        temperatureUsesScale && activeScale?.range != nil ? activeScale?.id : nil
    }

    /// The CCT scales' "Use for Temperature": on Temperature now, it switches to it; otherwise it
    /// only becomes Temperature's scale for next time, without changing the light.
    func assignTemperatureScale(_ id: UUID) {
        guard mode.choice != .temperature else { return useTemperatureScale(id) }
        guard let mac = chosenMAC else { return }
        library.setActiveScale(id, for: mac)
        temperatureUsesScale = true
    }

    func useTemperatureScale(_ id: UUID?) {
        temperatureUsesScale = id != nil
        let kelvin = mode == .custom ? customKelvin : temp
        if let id, let mac = chosenMAC {
            library.setActiveScale(id, for: mac)
            customKelvin = kelvin
            setMode(Mode.custom) // clamps to the scale's range
        } else {
            // The bulb's own snaps to 50 K, like its slider.
            temp = min(max((kelvin / 50).rounded() * 50, tempRange.lowerBound), tempRange.upperBound)
            setMode(Mode.temp)
        }
    }

    func setMode(_ m: Mode) {
        // Custom CCT without a scale (deleted since) can't send anything: the bulb's own instead.
        let m = m == .custom && activeScale?.range == nil ? Mode.temp : m
        mode = m
        if m == .custom, let range = activeScale?.range {
            customKelvin = min(max(customKelvin, Double(range.lowerBound)), Double(range.upperBound))
        }
        if m == .scene { useSendableScene() }
        sendPilot([.colour], retry: true)
    }

    /// A scene that can't be sent (Rhythm, a newer ID, or a deleted custom scene): start with the
    /// first one instead, so switching to Scene mode always sends something.
    private func useSendableScene() {
        guard !Scenes.isKnown(sceneId),
              !(sceneId == Scenes.inlineCustom && customSceneId.flatMap(library.customScene) != nil) else { return }
        sceneId = Scenes.all[0].id
        customSceneId = nil
    }

    func setScene(_ id: Int) {
        customSceneId = nil
        sceneId = id
        sendPilot([.colour], retry: true)
    }

    /// Sends the console's raw text exactly as typed: nothing added, and no read-back comparison.
    /// The method, if the text is JSON with one, names it for the reply, the log and retries. After
    /// a setPilot or setState the bulb's state is read again so the controls follow.
    func sendRawText(_ text: String, retry: Bool) {
        let method = Net.json(Data(text.utf8))?["method"] as? String
        consoleWaiting = method ?? ""
        consoleReply = nil
        consoleFailure = nil
        bulb.sendRaw(text, method: method, retry: retry)
        endConsoleWait(after: retry && method != nil)
        if method == "setPilot" || method == "setState" {
            Task {
                try? await Task.sleep(for: .milliseconds(700))
                sync(quiet: true) // the console has the reply; a refusal stays in the status
            }
        }
    }

    /// Reads everything the bulb will tell over UDP (device info), a little apart so the bulb
    /// isn't sent 22 requests at once.
    /// `skipping`: reads just sent anyway (by connect), still shown as reading until answered.
    func readConfig(skipping sent: Set<String> = []) {
        configTask?.cancel()
        infoWanted = true
        infoReading = Set(BulbAPI.deviceInfo)
        configTask = Task {
            for m in BulbAPI.deviceInfo where !sent.contains(m) {
                guard !Task.isCancelled else { return }
                bulb.send(m, retry: true)
                try? await Task.sleep(for: .milliseconds(60))
            }
        }
    }
    @ObservationIgnored private var configTask: Task<Void, Never>?
    /// Device Info has been read for this bulb: read again after a reconnect.
    @ObservationIgnored private var infoWanted = false

    /// Sends any method from the console. A setPilot is tracked like the controls' own (read
    /// back, mismatches shown), with `"state": false` added while the bulb is off if
    /// `keepOff` (leaving it out switches the bulb on); a setState updates the power switch.
    /// `params` nil sends the request without a params key.
    func sendRaw(_ method: String, _ params: [String: Any]?, keepOff: Bool, retry: Bool) {
        var p = params ?? [:]
        // Without params, the key stays out (unless "state": false had to be added).
        func sent(_ p: [String: Any]) -> [String: Any]? { params != nil || !p.isEmpty ? p : nil }
        consoleWaiting = method
        consoleReply = nil
        consoleFailure = nil
        switch method {
        case "setPilot":
            // Any of these without state switches the bulb on (speed too: alongside "state": false
            // the bulb ignores it, which the read-back then shows).
            let lightKeys: Set<String> = ["r", "g", "b", "c", "w", "temp", "sceneId", "speed", "dimming", "dimDelta", "ratio"]
            let changesLight = p.keys.contains(where: lightKeys.contains)
            if keepOff, isOn == false, p["state"] == nil, changesLight { p["state"] = false }
            if let data = try? JSONSerialization.data(withJSONObject: p, options: .sortedKeys) {
                lastSent = String(decoding: data, as: UTF8.self)
            }
            lastMethod = "setPilot"
            // Read back only what getPilot reports (not trans, elm or dimDelta).
            let reported: Set<String> = ["r", "g", "b", "c", "w", "temp", "sceneId", "speed", "dimming"]
            // With dimDelta the resulting dimming depends on the bulb's level, so it isn't checked.
            lastPilot = p.filter { reported.contains($0.key) && !($0.key == "dimming" && p["dimDelta"] != nil) }
                .compactMapValues { ($0 as? NSNumber)?.intValue }
            // A change like the controls' own: an earlier one's reason and delayed speed no longer
            // apply, and a switch that goes unanswered puts the power back.
            refusal = nil
            pilotAnswered = false
            delayedSpeed?.cancel()
            delayedSpeed = nil
            let before = isOn
            if let s = p["state"] as? Bool { isOn = s } else if changesLight { isOn = true }
            if before != isOn { powerBefore = before }
            pilotSwitches = before != isOn
            lastState = isOn
            sendSeq += 1
            pending = true
            bulb.send(method, sent(p), retry: retry)
            endConsoleWait(after: retry)
            scheduleVerify()
        case "setState":
            refusal = nil // a new change, as for setPilot
            pilotAnswered = false
            powerBefore = isOn // what a refusal puts back, whatever this one carries
            if let s = p["state"] as? Bool {
                isOn = s
                lastState = s
            }
            lastMethod = "setState"
            lastSent = JSONText.compact(p)
            bulb.send(method, sent(p), retry: retry)
            endConsoleWait(after: retry)
        default:
            bulb.send(method, sent(p), retry: retry)
            endConsoleWait(after: retry)
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
    /// concurrent changes from other apps.
    private func sendPilot(_ fields: Set<PilotField>, retry: Bool) {
        let fields = unsent.union(fields)
        unsent = []
        var p: [String: Any] = [:]
        if fields.contains(.dimming) { p["dimming"] = Int(dimming) }
        if fields.contains(.colour) { p.merge(colourParams()) { $1 } }
        let speed = (fields.contains(.speed) || speedOwed) && mode == .scene ? Int(speed) : nil
        if !p.isEmpty, let fade = fadeForControls { p["trans"] = fade }
        transmit(p, speed: speed, power: nil, retry: retry)
    }

    /// The current colour as setPilot parameters (empty if it can't be sent).
    private func colourParams() -> [String: Any] {
        switch mode {
        case .rgbcw:
            // All five, zeros included: the colour is one setting.
            return ["r": r, "g": g, "b": b, "c": c, "w": w].mapValues { Int($0) }
        case .temp:
            return ["temp": Int(temp)]
        case .custom:
            // setPilot's own CCT: the scale's channels at this kelvin, sent as RGBCW. If the scale
            // has gone, the bulb's own temperature instead.
            guard let ch = activeScale?.channels(at: Int(customKelvin)) else {
                mode = .temp
                return ["temp": Int(temp)]
            }
            (r, g, b, c, w) = (Double(ch.r), Double(ch.g), Double(ch.b), Double(ch.c), Double(ch.w))
            return ["r": ch.r, "g": ch.g, "b": ch.b, "c": ch.c, "w": ch.w]
        case .scene:
            if sceneId == Scenes.inlineCustom {
                // One of ours: the definition goes with it, as the bulb can't keep it.
                guard let id = customSceneId, let scene = library.customScene(id) else { return [:] }
                return ["sceneId": sceneId, "elm": scene.elm]
            }
            // Rhythm and unknown IDs (as reported by the bulb) can't be set.
            return Scenes.isKnown(sceneId) ? ["sceneId": sceneId] : [:]
        }
    }

    /// Sends one setPilot (and `speed` after it, on its own: the firmware drops speed sent with
    /// anything else), then reads the bulb back. `power`: true sends `"state": true`, false
    /// `"state": false`; nil keeps it as it is (a bulb that's off gets `"state": false`, since
    /// leaving it out would switch it on).
    private func transmit(_ params: [String: Any], speed: Int?, power: Bool?, retry: Bool) {
        var p = params
        refusal = nil // a new change: an older one's reason no longer applies, sent or not
        guard !p.isEmpty || speed != nil || power != nil else { return }
        pilotAnswered = false
        if power != nil { powerBefore = isOn } // what an unanswered switch puts back
        switch power {
        case true?:
            p["state"] = true
            isOn = true
            pilotSwitches = powerBefore != true
        case false?:
            p["state"] = false
            isOn = false
            pilotSwitches = powerBefore != false
        case nil:
            if !p.isEmpty, isOn == false { p["state"] = false }
            pilotSwitches = false
        }
        // Not while it's (to be) off: a setPilot without "state" switches the bulb on, and speed
        // can't go with anything else. It's owed until the bulb is on (`speedOwed`).
        let speedParams: [String: Any]? = isOn == false ? nil : speed.map { ["speed": $0] }
        if speed != nil { speedOwed = speedParams == nil }
        guard !p.isEmpty || speedParams != nil || power != nil else { return }
        // What goes out first: the setPilot, else speed on its own.
        let shown: [String: Any] = p.isEmpty ? speedParams ?? [:] : p
        lastMethod = "setPilot"
        if let data = try? JSONSerialization.data(withJSONObject: shown, options: .sortedKeys) {
            lastSent = String(decoding: data, as: UTF8.self)
        }
        lastPilot = p.filter { $0.key != "state" && $0.key != "trans" }.compactMapValues { $0 as? Int }
        if let speed, speedParams != nil { lastPilot["speed"] = speed }
        lastState = isOn
        sendSeq += 1
        pending = true
        if !p.isEmpty { bulb.send("setPilot", p, retry: retry) }
        // A new colour replaces the scene a delayed speed was for.
        if p.keys.contains(where: { $0 != "state" && $0 != "trans" && $0 != "dimming" }) {
            delayedSpeed?.cancel()
            delayedSpeed = nil
        }
        if let speedParams {
            delayedSpeed?.cancel() // out of date: this one replaces it
            delayedSpeed = nil
            // On its own, or with only switching on (a speed owed from while it was off): at the
            // same moment. After a scene: once it's started (see below).
            if !p.keys.contains(where: { $0 != "state" && $0 != "trans" }) {
                bulb.send("setPilot", speedParams, retry: retry)
            } else {
                // After the scene has started (and so retries of the two don't overlap). Not if
                // another bulb has been chosen meanwhile.
                let generation = connectGeneration
                delayedSpeed = Task {
                    try? await Task.sleep(for: .milliseconds(400))
                    // Switched off meanwhile: on its own it would switch it back on. Owed instead.
                    guard !Task.isCancelled, connectGeneration == generation else { return }
                    guard isOn != false else {
                        speedOwed = true
                        lastPilot["speed"] = nil // not sent: the read-back mustn't expect it
                        return
                    }
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
    /// `speed`, if given, follows in a setPilot of its own (the scene editor's preview plays at 100).
    @discardableResult
    func playCustom(_ scene: CustomScene, switchOn: Bool = false, speed: Int? = nil) -> Bool {
        send(LightChange(colour: .custom(scene.id, speed: speed), power: switchOn ? true : nil, fade: fadeForControls))
    }

    /// Applies a preset, switching the bulb on if it's off.
    @discardableResult
    func apply(_ preset: Preset) -> Bool {
        let sent = send(LightChange(colour: preset.colour, dimming: preset.dimming, power: true, fade: fadeForControls))
        if sent { PresetUsage.record(preset.id, in: .standard) } // for the watch's Smart Stack
        return sent
    }

    /// Sends several changes as one setPilot, with their own fade time (`trans`).
    /// False if nothing could be sent (the status, and `refusal`, say why).
    @discardableResult
    func send(_ change: LightChange) -> Bool {
        guard !change.isEmpty else {
            status = "Nothing to send"
            refusal = status
            return false
        }
        var p: [String: Any] = [:]
        var speed: Int?
        if let colour = change.colour {
            // Not sent: say why (a Shortcut reports it).
            guard select(colour, speed: &speed) else {
                refusal = status
                return false
            }
            p = colourParams()
            if p.isEmpty {
                status = "That colour can't be sent"
                refusal = status
                return false
            }
        }
        if let d = change.dimming {
            dimming = min(max(Double(d), minDimming), 100)
            p["dimming"] = Int(dimming)
        }
        // A fade goes with a change or with switching (the bulb takes it switching on, and may
        // one day switching off).
        if let fade = change.fade, !p.isEmpty || change.power != nil { p["trans"] = fade }
        // A speed owed from while it was off goes too (transmit holds it again if it stays off).
        if speed == nil, change.colour == nil, speedOwed, mode == .scene { speed = Int(self.speed) }
        transmit(p, speed: speed, power: change.power, retry: true)
        return true
    }

    /// Makes `colour` the current one (mode and values). False, with a status, if it can't be used.
    private func select(_ colour: LightColour, speed: inout Int?) -> Bool {
        switch colour {
        case let .rgbcw(r, g, b, c, w):
            mode = .rgbcw
            (self.r, self.g, self.b, self.c, self.w) = (Double(r), Double(g), Double(b), Double(c), Double(w))
        case let .temp(k):
            mode = .temp
            temp = Double(k)
            // Temperature is on the bulb's own now: it goes back to that after another mode.
            temperatureUsesScale = false
        case let .scene(id, s):
            // One this app doesn't know (an imported preset from a newer version, say) can't be
            // sent: leave the controls as they are rather than show it.
            guard Scenes.isKnown(id) else {
                status = "\(Scenes.name(id)) can't be sent"
                return false
            }
            mode = .scene
            sceneId = id
            customSceneId = nil
            if let s { self.speed = Double(s); speed = s }
            speedOwed = false // was for the scene before; this one starts at its own
        case let .custom(id, s):
            guard library.customScene(id) != nil else {
                status = "That custom scene has been deleted"
                return false
            }
            mode = .scene
            sceneId = Scenes.inlineCustom
            customSceneId = id
            if let s { self.speed = Double(s); speed = s }
            speedOwed = false // was for the scene before; this one starts at its own
        case let .customCCT(id, k):
            guard let found = library.scale(id), let ch = found.scale.channels(at: k) else {
                status = "That CCT scale has been deleted"
                return false
            }
            if let mac = chosenMAC, found.mac == mac.lowercased() {
                library.setActiveScale(id, for: mac)
                // Temperature is on this scale now: it goes back to it after another mode.
                temperatureUsesScale = true
                mode = .custom
                customKelvin = Double(k)
            } else {
                // Another bulb's scale: its values, as plain RGBCW.
                mode = .rgbcw
                (r, g, b, c, w) = (Double(ch.r), Double(ch.g), Double(ch.b), Double(ch.c), Double(ch.w))
            }
        }
        return true
    }

    /// What the bulb is showing, as a preset colour (nil for Rhythm and scenes setPilot can't set).
    var currentColour: LightColour? {
        switch mode {
        case .rgbcw: .rgbcw(r: Int(r), g: Int(g), b: Int(b), c: Int(c), w: Int(w))
        case .temp: .temp(Int(temp))
        case .custom: activeScale.map { .customCCT(scale: $0.id, kelvin: Int(customKelvin)) }
        case .scene:
            // Not a custom scene that's been deleted meanwhile: that can't be sent (or saved).
            if sceneId == Scenes.inlineCustom, let id = customSceneId, library.customScene(id) != nil { .custom(id, speed: Int(speed)) }
            else if Scenes.isKnown(sceneId) { .scene(id: sceneId, speed: Int(speed)) }
            else { nil }
        }
    }

    /// A preset as a ready-made setPilot (for widgets and controls, which send it themselves if
    /// they can't use the app). Speed is left out; dimming (within the bulb's limits) and the
    /// controls' fade are in, as when the app applies it. Nil for one the app wouldn't send.
    func pilotParams(for preset: Preset) -> [String: Any]? {
        var p: [String: Any] = ["dimming": Int(min(max(Double(preset.dimming), minDimming, 1), 100))]
        switch preset.colour {
        case let .rgbcw(r, g, b, c, w): p.merge(["r": r, "g": g, "b": b, "c": c, "w": w]) { $1 }
        case let .temp(k): p["temp"] = k
        case let .scene(id, _):
            guard Scenes.isKnown(id) else { return nil }
            p["sceneId"] = id
        case let .custom(id, _):
            guard let scene = library.customScene(id) else { return nil }
            p["sceneId"] = Scenes.inlineCustom
            p["elm"] = scene.elm
        case let .customCCT(id, k):
            guard let ch = library.scale(id)?.scale.channels(at: k) else { return nil }
            p.merge(["r": ch.r, "g": ch.g, "b": ch.b, "c": ch.c, "w": ch.w]) { $1 }
        }
        if let fade = fadeForControls { p["trans"] = fade }
        return p
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

    // MARK: Custom CCT

    /// The scale Custom CCT uses for the chosen bulb.
    var activeScale: CCTScale? { library.activeScale(for: chosenMAC) }

    /// The bulb's own CCT table, from getModelConfig, as a starting point for a scale.
    var defaultScale: CCTScale? {
        guard let cctRange, let renderFactor else { return nil }
        return CCTScale.bulbDefault(cctRange: cctRange, renderFactor: renderFactor)
    }

    /// Relative brightness (`dimDelta`): the bulb adds it to its own level, so concurrent changes
    /// from elsewhere aren't overwritten.
    func adjustDimming(by delta: Int) {
        guard delta != 0 else { refusal = nil; return } // nothing to do: no earlier reason applies
        dimming = min(max(dimming + Double(delta), minDimming), 100)
        // The new level, not dimDelta: a retry (its reply lost or late) would add the step again.
        var p: [String: Any] = ["dimming": Int(dimming)]
        if let fade = fadeForControls { p["trans"] = fade }
        if isOn == false { p["state"] = false }
        if let data = try? JSONSerialization.data(withJSONObject: p, options: .sortedKeys) {
            lastSent = String(decoding: data, as: UTF8.self)
        }
        lastMethod = "setPilot"
        lastPilot = ["dimming": Int(dimming)]
        lastState = isOn
        sendSeq += 1
        pending = true
        refusal = nil
        pilotAnswered = false
        pilotSwitches = false
        bulb.send("setPilot", p, retry: true)
        scheduleVerify()
    }

    /// A light show cue: sent once as it is (a late resend would be out of time), and shown as the
    /// last command. The controls follow from the bulb's live updates.
    func sendLightCue(_ pilot: [String: Any]) {
        if let data = try? JSONSerialization.data(withJSONObject: pilot, options: .sortedKeys) {
            lastSent = String(decoding: data, as: UTF8.self)
        }
        lastMethod = "setPilot"
        // A scene's speed still to follow a change from before the show is out of date now.
        delayedSpeed?.cancel()
        delayedSpeed = nil
        if let s = pilot["state"] as? Bool { isOn = s } else if pilot.keys.contains(where: { $0 != "trans" }) { isOn = true }
        // A read-back still due from a change before the show would compare against that change
        // (a false "didn't apply") and hold back the live updates the controls follow.
        verifyTask?.cancel()
        verifyingSeq = nil
        pending = false
        mismatch = nil
        pilotSwitches = false
        bulb.send("setPilot", pilot, retry: false)
    }

    /// Sets the fields named from the given values, and sends them (from the watch). The rest
    /// stay as they are: the watch's copy of them may be out of date.
    func apply(_ v: LightValues, fields: [PilotField]) {
        if fields.contains(.colour) {
            if v.mode != .scene || v.sceneId != Scenes.inlineCustom { customSceneId = nil }
            mode = v.mode
            (r, g, b, c, w) = (v.r, v.g, v.b, v.c, v.w)
            temp = v.temp
            customKelvin = v.customKelvin
            sceneId = v.sceneId
        }
        if fields.contains(.speed) { speed = v.speed }
        if fields.contains(.dimming) { dimming = v.dimming }
        // The watch switching to Scene mode sends the last scene, which may be one that can't be set.
        if mode == .scene, fields.contains(.colour) { useSendableScene() }
        sendPilot(Set(fields), retry: true)
    }

    var values: LightValues {
        LightValues(mode: mode, r: r, g: g, b: b, c: c, w: w, temp: temp, customKelvin: customKelvin,
                    sceneId: sceneId, speed: speed, dimming: dimming)
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
        s.customKelvin = customKelvin
        if let range = activeScale?.range {
            s.customMin = Double(range.lowerBound)
            s.customMax = Double(range.upperBound)
        }
        s.status = mismatch ?? status
        s.pending = pending
        s.owedSpeed = owedSpeed
        s.mismatch = mismatch
        s.bulbs = namedBulbs
        s.address = UserDefaults.standard.string(forKey: Self.addressKey)
        s.scales = library.scales(for: chosenMAC).compactMap { scale in
            scale.range.map { ScaleSummary(id: scale.id, name: scale.name, min: Double($0.lowerBound), max: Double($0.upperBound)) }
        }
        s.activeScale = activeScale?.id
        s.fade = Self.fade
        s.snapSliders = Stepping.snaps
        s.controlsFade = controlsFade
        s.controlsFadeMs = controlsFadeMs
        s.live = live
        s.pushSeen = pushSeen
        s.mac = mac
        s.module = module
        s.firmware = firmware
        if !lastSent.isEmpty {
            s.lastMethod = lastMethod
            s.lastSent = lastSent
        }
        return s
    }

    /// Back in the foreground (iOS suspends sockets in the background): reconnect if live
    /// updates stopped or the bulb went quiet, otherwise just read its state again.
    func resume() {
        guard started, let a = UserDefaults.standard.string(forKey: Self.addressKey), !a.isEmpty else {
            startIfSaved()
            return
        }
        // Already on its way (just launched, say); a connect left hanging by a suspension is redone.
        if link == .connecting, Date.now.timeIntervalSince(lastConnect) < 5 { return }
        if !push.isRunning || link != .connected { connect(a) } else { sync() }
    }

    /// getPilot replies so far, so a refresh can wait for the next one.
    @ObservationIgnored private var pilotReads = 0

    /// Pull to refresh: `resume`, then wait (up to `timeout`) until the bulb's state has been read.
    func refresh(timeout: Double = 3) async {
        let before = pilotReads
        resume()
        let end = Date().addingTimeInterval(timeout)
        while pilotReads == before && Date() < end { try? await Task.sleep(for: .milliseconds(100)) }
    }

    @ObservationIgnored private var liveHost: String?
    @ObservationIgnored private var lastRegistration = Date.distantPast

    /// When something was last heard from the bulb (a reply or a push).
    @ObservationIgnored private var lastHeard = Date.distantPast
    /// When `ensureLive` last read the state because the bulb had gone quiet.
    @ObservationIgnored private var lastStaleRead = Date.distantPast

    /// Woken in the background (by the watch, Shortcuts or a widget): iOS suspends the app's
    /// sockets and timers in between, so make sure it's connected and registered for pushes again,
    /// so changes made elsewhere reach it (and the watch) while it's awake. Pushes sent while it was
    /// suspended are lost, so if nothing has been heard from the bulb for longer than the
    /// registration interval (it answers each one), the state is read again too. True if a read of
    /// the state is on its way.
    @discardableResult
    func ensureLive() -> Bool {
        guard started, let a = UserDefaults.standard.string(forKey: Self.addressKey), !a.isEmpty else {
            let was = started
            startIfSaved()
            return started && !was
        }
        // Not connected: connect, unless one is still under way (its reads retry for about 14 s,
        // so starting another on every watch poll only restarts them). One left stuck connecting
        // (the app suspended part way) is redone.
        if link != .connected {
            if link == .none || Date.now.timeIntervalSince(lastConnect) > 15 { connect(a) }
            return true
        }
        var reading = false
        if Date.now.timeIntervalSince(max(lastHeard, lastStaleRead)) > 25 {
            lastStaleRead = .now
            sync()
            reading = true
        }
        // Registering again also restarts the push listener if it stopped; the bulb link itself is
        // fine, so no need to reconnect for that.
        if let liveHost, !push.isRunning || Date.now.timeIntervalSince(lastRegistration) > 15 { startLiveUpdates(liveHost) }
        return reading
    }

    /// Updates a preset to the light as it is now.
    func updatePreset(_ id: UUID) {
        guard let colour = currentColour, let i = library.presets.firstIndex(where: { $0.id == id }) else { return }
        library.presets[i].colour = colour
        library.presets[i].dimming = Int(dimming)
    }

    /// Moves a preset up (-1) or down (1) in the list.
    func movePreset(_ id: UUID, by offset: Int) {
        guard let i = library.presets.firstIndex(where: { $0.id == id }) else { return }
        let j = i + offset
        guard library.presets.indices.contains(j) else { return }
        library.presets.swapAt(i, j)
    }

    /// The device info, in order, for the watch.
    var deviceInfoEntries: [DeviceInfoEntry] {
        BulbAPI.deviceInfo.compactMap { m in
            // One still being read again goes as that, not as the last read's answer.
            info[m].map { DeviceInfoEntry(method: m, text: $0, error: infoReading.contains(m) ? "No reply yet" : infoErrors[m]) }
        }
    }

    func renamePreset(_ id: UUID, to name: String) {
        let n = name.trimmingCharacters(in: .whitespaces)
        guard !n.isEmpty, let i = library.presets.firstIndex(where: { $0.id == id }) else { return }
        library.presets[i].name = n
    }

    /// Connects to the saved bulb if needed and waits until it can be controlled (or `timeout`).
    /// If the state is being read again (see `ensureLive`), waits for that too, so what's sent and
    /// reported starts from the bulb's real state.
    func waitUntilControllable(timeout: Double = 4) async -> Bool {
        let reads = pilotReads
        let reading = ensureLive()
        let end = Date().addingTimeInterval(timeout)
        while !canControl && Date() < end { try? await Task.sleep(for: .milliseconds(100)) }
        if reading {
            while pilotReads == reads && Date() < end { try? await Task.sleep(for: .milliseconds(100)) }
        }
        return canControl
    }

    /// Waits until the last change has been read back (or `timeout`).
    func waitUntilSettled(timeout: Double = 3) async {
        let end = Date().addingTimeInterval(timeout)
        while pending && Date() < end { try? await Task.sleep(for: .milliseconds(100)) }
    }

    /// A scene speed changed while the bulb was off, still to go when it's switched on.
    var owedSpeed: Int? { speedOwed && mode == .scene ? Int(speed) : nil }

    /// For Shortcuts, after a change: nil once the bulb has taken it (read back), or why not: its
    /// refusal, or no answer within `timeout`.
    func outcome(timeout: Double = 3) async -> String? {
        let end = Date().addingTimeInterval(timeout)
        while refusal == nil, pending, !pilotAnswered, Date() < end { try? await Task.sleep(for: .milliseconds(100)) }
        if let refusal { return refusal }
        return pending && !pilotAnswered ? "The bulb didn't answer." : nil
    }

    /// Once changes settle, read the state back to catch values the bulb ignored or adjusted
    /// (it replies "success" to some setPilots it doesn't fully apply).
    private func scheduleVerify() {
        verifyTask?.cancel()
        verifyTask = Task {
            try? await Task.sleep(for: .milliseconds(700))
            guard !Task.isCancelled else { return }
            verifyingSeq = sendSeq
            // This read settles the state; a quiet read still owed for an earlier refusal would
            // only keep a later Sync from saying so.
            quietReads = 0
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
        lastHeard = .now
        let method = reply["method"] as? String ?? "?"
        if reply["hmac"] != nil { bulbSigns = true }
        if let err = reply["error"] as? [String: Any] {
            // Back after not answering, as for a result below: what it showed may be out of date.
            if link == .unreachable && method != "getPilot" { bulb.send("getPilot", retry: true) }
            link = .connected
            // A refused change or read-back: nothing to read back (a read that works unsigned would
            // replace the error below with "didn't apply"), and nothing is pending any more.
            // A read-back already on its way (the refusal came after it went out) will do.
            let readOut = verifyingSeq != nil && verifyingSeq == sendSeq
            if method == "setPilot" || method == "setState" || method == "getPilot" {
                verifyTask?.cancel()
                pending = false
                verifyingSeq = nil
            }
            // The controls already show the refused change: read the bulb's actual state, without
            // letting that read's status replace the error below.
            if method == "setPilot" {
                pilotSwitches = false // the read that follows says how it is
                // A scene's speed still to follow would be answered "ok", hiding this refusal.
                delayedSpeed?.cancel()
                delayedSpeed = nil
                lastPilot["speed"] = nil
                quietReads += 1
                if !readOut { bulb.send("getPilot", retry: true) }
            } else if method == "getPilot" {
                quietReads = 0 // refused too: nothing to keep quiet
            }
            if method == "setState" { // as when it doesn't answer: the switch didn't happen
                isOn = powerBefore
                lastState = powerBefore
            }
            let code = err["code"] as? Int
            var text = code == -32601 ? "not supported by this firmware" : "\(err["message"] ?? err)"
            if code == -32605 {
                text += signing
                    ? " (check the bulb's signing key, and that this device's clock is right)"
                    : " (the bulb wants signed requests: add its signing key)"
            } else if code == -32602, bulbSigns, !signing, !method.hasPrefix("get") {
                text += " (if the bulb wants signed requests, add its signing key)"
            }
            if BulbAPI.deviceInfo.contains(method) {
                // Device info shows the error as the bulb sent it (code and message), flagged; a
                // failed read isn't worth the status line.
                info[method] = JSONText.pretty(["error": err])
                infoErrors[method] = err["message"] as? String ?? (err["code"] as? Int).map { "Error \($0)" } ?? "Error"
                infoReading.remove(method)
                // Except getPilot, which the controls wait for, and a signing refusal, which every
                // request will get: those need saying.
                if method != "getPilot", code != -32605 { return }
            }
            if method == "registration" { // live updates only, as when it gets no answer
                live = false
                liveStatus = "Live updates off — \(text)"
                return
            }
            if method == "setPilot" || method == "setState" { refusal = "\(method): \(text)" }
            status = "\(method): \(text)"
            return
        }
        let anyResult = reply["result"]
        if let r = anyResult as? [String: Any], let replyMAC = r["mac"] as? String, !isChosenBulb(replyMAC) { return }
        // Device info: every read's reply, as it came.
        if BulbAPI.deviceInfo.contains(method), let anyResult {
            info[method] = JSONText.pretty(anyResult)
            infoErrors[method] = nil
            infoReading.remove(method)
        }
        guard let result = anyResult as? [String: Any] else { return }
        // Back after not answering (e.g. the 20 s registration got through): re-read its state.
        if link == .unreachable && method != "getPilot" { bulb.send("getPilot", retry: true) }
        link = .connected
        retriedAt = nil
        switch method {
        case "getPilot":
            pilotReads += 1
            if let seq = verifyingSeq {
                // A newer setPilot went out after this check started; its own check will follow.
                guard seq == sendSeq else { return }
                verifyingSeq = nil
                pending = false
                // The read-back says how the power is: a switch's lost replies mustn't undo it.
                if result["state"] != nil { pilotSwitches = false }
                applyPilot(result)
                verify(result)
            } else if quietReads > 0 {
                quietReads -= 1
                // From before a newer change still on its way: that change's own read-back
                // settles the state (as for a push while pending).
                if !pending { applyPilot(result) }
            } else {
                applyPilot(result)
                status = "Synced"
            }
        case "getModelConfig", "getUserConfig":
            applyLimits(result)
        case "getSystemConfig", "getPower":
            if let m = result["mac"] as? String { mac = m }
            if let m = result["moduleName"] as? String { module = m }
            if let f = result["fwVersion"] as? String { firmware = f }
        case "setPilot":
            pilotSwitches = false // answered
            pilotAnswered = true
            status = "setPilot ok" // as before; a read-back that follows says more
        case "setState":
            status = isOn == false ? "Switched off" : "Switched on"
        case "registration":
            if result["success"] as? Bool == true, push.isRunning, !live {
                live = true
                if !pushSeen {
                    liveStatus = "Registered for live updates; the bulb sends one when its state changes"
                }
            }
        default:
            // Reads (device info) aren't worth the status line.
            if !method.hasPrefix("get") { status = "\(method) ok" }
        }
    }

    private func handlePush(_ msg: [String: Any]) {
        guard msg["method"] as? String == "syncPilot",
              let params = msg["params"] as? [String: Any],
              let from = params["mac"] as? String, let mac, from.lowercased() == mac.lowercased()
        else { return }
        lastHeard = .now
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
        if let s = p["state"] as? Bool {
            isOn = s
            // On (switched on elsewhere, say, into a scene of its own): a speed owed from while
            // it was off is out of date.
            if s { speedOwed = false }
        }
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
        } else if ["r", "g", "b", "c", "w"].contains(where: { num($0) != nil }) {
            r = num("r") ?? 0; g = num("g") ?? 0; b = num("b") ?? 0
            c = num("c") ?? 0; w = num("w") ?? 0
            // The bulb only knows RGBCW. In Custom CCT, stay there if the scale gives exactly
            // these values at some kelvin (the nearest to where it was); otherwise it's RGBCW.
            let ch = CCTScale.Channels(r: Int(r), g: Int(g), b: Int(b), c: Int(c), w: Int(w))
            if mode == .custom, let k = activeScale?.kelvin(matching: ch, near: Int(customKelvin)) {
                customKelvin = Double(k)
            } else {
                mode = .rgbcw
            }
        }
        if mode != .scene || sceneId != Scenes.inlineCustom { customSceneId = nil }
    }

    private func applyLimits(_ result: [String: Any]) {
        if let v = result["fadeIn"] as? NSNumber { fadeIn = v.intValue }
        if let v = result["fadeOut"] as? NSNumber { fadeOut = v.intValue }
        if let v = result["cctRange"] as? [NSNumber] { cctRange = v.map(\.intValue) }
        if let v = result["renderFactor"] as? [NSNumber] { renderFactor = v.map(\.intValue) }
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
}

extension Model {
    /// The chosen bulb's signing, for the device details.
    var signingStatus: String {
        if signing { return "On" }
        return bulbSigns ? "Off (the bulb signs its replies)" : "Off"
    }
}

/// What a signing key is, for the places that set one.
enum SigningHelp {
    static let text = "Newer firmware can refuse unsigned changes. Its key is the home's udp_signing_key, from the WiZ app's export of the home for local integration. With a key, setPilot signs every request to this bulb (but not the console's raw messages). It's kept on this device only."
}
