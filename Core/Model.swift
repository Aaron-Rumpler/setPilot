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
            try? await Task.sleep(for: .seconds(BulbTiming.answerTimeout)) // as long as anything waits
            guard consoleRequest == request, consoleWaiting != nil else { return }
            consoleWaiting = nil
            consoleFailure = "No reply within \(Int(BulbTiming.answerTimeout.rounded())) s (sent once: Retry was off, or the message has no method to retry by)"
        }
    }
    var consoleReply: String?
    var consoleFailure: String?
    enum Link { case none, connecting, connected, unreachable }
    /// Whether the bulb has answered since the last Connect.
    var link: Link = .none {
        didSet {
            // Answering: the bulb your other devices are offered (BulbNudge), through iCloud.
            if link == .connected, oldValue != .connected, let mac = chosenMAC,
               let address = UserDefaults.standard.string(forKey: Self.addressKey) {
                UserDefaults.standard.set(BulbNudge.value(mac: mac, address: address), forKey: BulbNudge.key)
            }
        }
    }
    /// Controls are usable: the bulb answers and its on/off state is known (a setPilot to a bulb
    /// that's off has to say so, or it switches on).
    var canControl: Bool { link == .connected && isOn != nil }
    /// Registered for syncPilot pushes.
    var live = false {
        didSet {
            guard !live else { return }
            pushSeen = false
            // Gone off without a reason given: not still saying they're on (or on the way).
            if !liveStatus.hasPrefix("Live updates off") { liveStatus = "Live updates off" }
        }
    }
    /// A push has arrived since connecting: registration alone doesn't show they get through
    /// (a firewall can block port 38900).
    var pushSeen = false
    var status = ""
    /// The system refused to let setPilot reach the local network (the permission is off): the
    /// apps show how to turn it on (LocalNetworkHelp).
    var localNetworkDenied = false
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
    /// The latest change's setPilot was answered "success" (the read-back that follows says
    /// whether it was applied).
    @ObservationIgnored private var pilotAnswered = false
    /// Why the last change (setPilot or setState) didn't take, or wasn't sent: the bulb's
    /// refusal, no answer, or the app's reason (Model.apply). Nil once another is started.
    @ObservationIgnored private(set) var refusal: String?
    /// Starts an action whose reason will be reported: one that sends nothing (already as asked)
    /// mustn't report an earlier change's.
    func forgetRefusal() { refusal = nil }

    // MARK: What became of a change

    /// What became of a change, for whoever's waiting on it (Shortcuts, links, the CLI,
    /// AppleScript, widgets, the watch). WiZ replies carry no request ID, so a change's answer
    /// is the one that comes while it's the latest: one that another change goes before, still
    /// unanswered, isn't known to be done.
    enum ChangeResult: Equatable {
        case done
        case notApplied(String)
        case refused(String)
        case notAnswered(String)
        case notKnown(String)
    }

    /// The latest change's number (0 before any); a waiter takes it once its change is sent.
    @ObservationIgnored private(set) var ticket = 0
    /// What became of recent changes, by number.
    @ObservationIgnored private var results: [Int: ChangeResult] = [:]
    /// Results this old have been let go (only so many are kept).
    @ObservationIgnored private var forgottenUpTo = 0

    /// A change is going out: the one before, if still unsettled, is settled now (done if it was
    /// answered, its read-back being this one's now; otherwise not known to be done).
    private func startChange() {
        if ticket > 0, results[ticket] == nil {
            settle(ticket, pilotAnswered ? .done : .notKnown("Another change went before this one was answered, so it isn't known to be done."))
        }
        ticket += 1
        refusal = nil
        pilotAnswered = false
        // The last change's retries stop: one landing after this would undo it.
        bulb.cancelRetries("setPilot")
        bulb.cancelRetries("setState")
    }

    /// Records what became of a change (the first word on it counts). No answer at all starts the
    /// fail-at-once hold (recentlyNotAnswering).
    private func settle(_ t: Int, _ result: ChangeResult) {
        guard t > 0, results[t] == nil else { return }
        results[t] = result
        if results.count > 64, let oldest = results.keys.min() {
            results.removeValue(forKey: oldest)
            forgottenUpTo = max(forgottenUpTo, oldest)
        }
        if case .notAnswered = result { markNotAnswering() }
    }

    /// The latest change, unanswered so far (or its read-back unanswered): as no answer.
    private var unanswered: ChangeResult {
        pilotAnswered ? .notAnswered("The bulb took the change but didn't answer the read-back.") : .notAnswered("The bulb didn't answer.")
    }

    /// Waits for what became of change `t`: answered and read back as asked (done), not applied,
    /// refused, not answered, or not known (another change went before it was answered). Settled
    /// by the bulb's own retries giving up, so the wait is a backstop.
    func result(of t: Int, timeout: Double = Model.answerTimeout * 2) async -> ChangeResult {
        // Let go of already (many changes since): long settled, but what as isn't kept.
        if t <= forgottenUpTo, results[t] == nil { return .notKnown("Many changes followed, so what became of this one isn't known.") }
        let end = Date().addingTimeInterval(timeout)
        while results[t] == nil, t > forgottenUpTo, Date() < end { try? await Task.sleep(for: .milliseconds(100)) }
        if t <= forgottenUpTo, results[t] == nil { return .notKnown("Many changes followed, so what became of this one isn't known.") }
        if results[t] == nil { settle(t, t == ticket ? unanswered : .notAnswered("The bulb didn't answer.")) }
        return results[t] ?? .notAnswered("The bulb didn't answer.")
    }

    /// A change still waiting (for its answer or its read-back) is dropped (another bulb, a light
    /// show taking over): done if it was answered, otherwise not known to be done. Not taken for
    /// the bulb not answering.
    private func dropPending(_ why: String) {
        if pending || verifyingSeq != nil { settle(ticket, pilotAnswered ? .done : .notKnown(why)) }
        verifyTask?.cancel()
        verifyingSeq = nil
        pending = false
    }
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
    /// A different bulb (MAC) answered at the address: ignore everything from it, until the next
    /// connect or the chosen bulb (by its MAC) answers there again.
    @ObservationIgnored private var wrongBulb = false
    /// Trying to reach the bulb again after it stopped answering (recover).
    @ObservationIgnored private var recoveryTask: Task<Void, Never>?
    @ObservationIgnored private var recoveryRound = 0
    private let network = NetworkWatcher()
    @ObservationIgnored private var discoveryTask: Task<[DiscoveredBulb], Never>?
    /// This device's id in live-update registrations: kept, so each launch registers as the same
    /// device rather than as yet another one.
    private let phoneMac: String = {
        let key = "registrationID"
        if let id = UserDefaults.standard.string(forKey: key), id.count == 12 { return id }
        let id = String((0..<12).map { _ in "0123456789abcdef".randomElement()! })
        UserDefaults.standard.set(id, forKey: key)
        return id
    }()

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
        bulb.onError = { [weak self] method, message, tag in
            guard let self else { return }
            appendLog(.failure, method: method ?? "", text: message)
            Log.bulb.error("\(message, privacy: .public)")
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
            // About a change since replaced (a superseded one's request): it's been settled already.
            if let tag, tag != ticket { return }
            // A retry's read (recover) going unanswered: still not answering, as already said.
            if method == "getPilot", link == .unreachable {
                if tag == ticket, verifyingSeq != nil { settle(ticket, unanswered) }
                quietReads = 0
                pending = false
                verifyingSeq = nil
                if status == "Trying again…" { status = "The bulb isn't answering; trying again…" } // Try Again's
                return
            }
            // The connection itself: connectionLost says it (once, not at every retry).
            if method == nil {
                connectionLost()
                return
            }
            status = message
            switch method {
            case "getPilot"?:
                quietReads = 0 // the reads aren't coming
                // Connecting, or the bulb has gone away since: look for it at a new address.
                if link == .connecting || link == .connected {
                    link = .unreachable
                    live = false
                    if bulb.localNetworkDenied {
                        localNetworkDenied = true
                        status = Self.localNetworkStatus
                    } else {
                        status = "The bulb isn't answering; trying again…"
                    }
                    recover()
                }
                if tag == ticket, verifyingSeq != nil { settle(ticket, unanswered) } // its read-back
                pending = false
                verifyingSeq = nil
            case "setPilot"?:
                // Couldn't confirm; stop showing the request as pending.
                pending = false
                verifyingSeq = nil
                refusal = message
                // Not answered (every retry, or it couldn't be sent); otherwise the reason.
                settle(ticket, message.contains("no reply") || message.contains("couldn't send") ? .notAnswered(message) : .refused(message))
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
                settle(ticket, .notAnswered(status))
            default:
                break
            }
        }
        push.onMessage = { [weak self] obj, text in
            self?.appendLog(.push, method: obj["method"] as? String ?? "", text: text)
            self?.handlePush(obj)
        }
        push.onFailure = { [weak self] reason in
            // The listener's started again with the next registration (registerOnce), in 20 s.
            self?.live = false
            self?.liveStatus = "Live updates off — \(reason)"
        }
        // Another network, a VPN, back from sleep: the connection's made afresh.
        network.onChange = { [weak self] in self?.networkChanged() }
        // Ready after waiting (Local Network access just allowed, say): not left until the next retry.
        bulb.onReady = { [weak self] in
            guard let self, self.link == .unreachable else { return }
            self.quietReads = 0
            self.bulb.send("getPilot", retry: true)
            if !self.wrongBulb { self.registerOnce() } // not with another device at the address
        }
        network.start()
        // iCloud sync (builds with WIZ_ICLOUD): settings through key-value storage, the library
        // and names item by item.
        NotificationCenter.default.addObserver(forName: CloudSync.settingsChanged, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.reloadSyncedSettings() }
        }
        Log.app.info("setPilot \(BuildInfo.summary, privacy: .public) started")
        library.onScalesChanged = { [weak self] in self?.checkScaleInUse() }
        CloudSync.shared.start()
        adoptBulbInUse()
        CloudLibrary.shared.start(model: self)
        CloudDocuments.shared.start()
        MetricReports.shared.start() // crash and hang reports, for Export Diagnostics
    }

    /// No bulb chosen here: use the one your other devices use (BulbNudge), if there is one.
    private func adoptBulbInUse() {
        let defaults = UserDefaults.standard
        guard (defaults.string(forKey: Self.addressKey) ?? "").isEmpty,
              let value = defaults.string(forKey: BulbNudge.key) else { return }
        guard let bulb = BulbNudge.offered(value) else { return }
        choose(bulb.address, mac: bulb.mac)
    }

    /// Settings from another device (CloudSync) have been written to the defaults: take them.
    private func reloadSyncedSettings() {
        adoptBulbInUse()
        let defaults = UserDefaults.standard
        let fade = FadeChoice(rawValue: defaults.string(forKey: Self.controlsFadeKey) ?? "") ?? .setting
        if fade != controlsFade { controlsFade = fade }
        let ms = defaults.object(forKey: Self.controlsFadeMsKey) as? Int ?? 1000
        if ms != controlsFadeMs { controlsFadeMs = ms }
        let usesScale = defaults.bool(forKey: Self.temperatureScaleKey)
        if usesScale != temperatureUsesScale { temperatureUsesScale = usesScale }
        library.onChange?() // the widgets' ready-made requests carry the fade setting too
    }

    // MARK: Undo and redo

    /// How the light was before each of the last changes made here (a drag or a burst of
    /// changes counts once), newest last.
    private(set) var undoHistory: [SavedLight] = []
    /// How it was before each undo, for redo; emptied by a new change.
    private(set) var redoHistory: [SavedLight] = []
    @ObservationIgnored private var lastUndoPoint = Date.distantPast
    @ObservationIgnored private var undoing = false
    /// The window's undo manager (set by the main view), so Edit › Undo and Redo, ⌘Z and ⇧⌘Z,
    /// and shaking the iPhone undo and redo light changes too.
    @ObservationIgnored weak var undoManager: UndoManager?
    static let undoActionName = "Light Change"

    var canUndo: Bool { !undoHistory.isEmpty && canControl }
    var canRedo: Bool { !redoHistory.isEmpty && canControl }

    /// Called before a change: keeps how the light is now, unless a change was made in the last
    /// moment and a half (then it's part of the same one).
    /// `before`: the light as it was, if it's been changed here already (taken before the change,
    /// kept only once the change is sure to go).
    func noteUndoPoint(before: SavedLight? = nil) {
        guard !undoing, canControl else { return }
        let now = Date.now
        defer { lastUndoPoint = now }
        guard now.timeIntervalSince(lastUndoPoint) > 1.5 else { return }
        undoHistory.append(before ?? savedLight)
        if undoHistory.count > 20 { undoHistory.removeFirst() }
        redoHistory = []
        registerWithManager(redo: false)
    }

    /// An undo (or, registered while undoing, a redo) on the window's undo manager.
    private func registerWithManager(redo: Bool) {
        undoManager?.registerUndo(withTarget: self) { model in
            MainActor.assumeIsolated { redo ? model.redoNow() : model.undoNow() }
        }
        undoManager?.setActionName(Self.undoActionName)
    }

    private func clearUndo() {
        undoHistory = []
        redoHistory = []
        undoManager?.removeAllActions(withTarget: self) // so Edit › Undo doesn't offer what's gone
    }

    /// The Undo button: through the undo manager when the change is the last thing on it, so the
    /// two stay in step.
    func undo() {
        if let m = undoManager, m.canUndo, m.undoActionName == Self.undoActionName {
            m.undo()
        } else {
            undoNow()
        }
    }

    /// The Redo button, likewise.
    func redo() {
        if let m = undoManager, m.canRedo, m.redoActionName == Self.undoActionName {
            m.redo()
        } else {
            redoNow()
        }
    }

    private func undoNow() {
        // Edit › Undo, ⌘Z and shaking come here whatever canUndo says: with the bulb away, the
        // history is kept (the Undo button still has it) rather than spent on a change that can't go.
        guard canControl else {
            status = "The bulb isn't answering, so nothing was undone"
            if undoManager?.isUndoing == true {
                DispatchQueue.main.async { MainActor.assumeIsolated { self.registerWithManager(redo: false) } } // back on Edit › Undo
            }
            return
        }
        guard let last = undoHistory.popLast() else { return }
        redoHistory.append(savedLight)
        restoreForUndo(last)
        // Registered while the manager is undoing, it's the manager's redo (not when the button
        // went round the manager).
        if undoManager?.isUndoing == true { registerWithManager(redo: true) }
    }

    private func redoNow() {
        guard canControl else {
            status = "The bulb isn't answering, so nothing was redone"
            return
        }
        guard let next = redoHistory.popLast() else { return }
        undoHistory.append(savedLight)
        restoreForUndo(next)
        registerWithManager(redo: false) // registered during a redo: undo again
    }

    private func restoreForUndo(_ saved: SavedLight) {
        undoing = true
        defer { undoing = false; lastUndoPoint = .distantPast }
        if let note = restore(saved) { status = note }
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
            if !fromCloud { CloudLibrary.shared.localChanged(.knownBulb) }
        }
    }
    /// Set while taking bulbs or signing keys from iCloud (CloudLibrary), so they aren't sent back.
    @ObservationIgnored private var fromCloud = false

    func setKnownBulbsFromCloud(_ new: [KnownBulb]) {
        fromCloud = true
        knownBulbs = new
        fromCloud = false
    }

    func setSigningKeysFromCloud(_ new: [String: String]) {
        fromCloud = true
        signingKeys = new
        fromCloud = false
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
        knownBulbs = list // all of them, until you forget one
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

    /// From the Keychain; builds before kept them in the user defaults, which are moved over once.
    private static func loadSigningKeys() -> [String: String] {
        var keys = SigningKeyStore.all()
        if let old = UserDefaults.standard.dictionary(forKey: signingKeysKey) as? [String: String] {
            var kept = true
            for (mac, key) in old where keys[mac] == nil {
                kept = SigningKeyStore.set(key, for: mac) && kept
                keys[mac] = key
            }
            // Only once they're all in the Keychain: otherwise they'd be lost at the next launch.
            if kept { UserDefaults.standard.removeObject(forKey: signingKeysKey) }
        }
        SharedStore.defaults.removeObject(forKey: SharedStore.signingKeyKey) // the widgets' old copy
        return keys
    }

    /// Signing keys for bulbs whose firmware wants signed requests, keyed by lower-case MAC: the
    /// home's udp_signing_key, as 32 hex digits. Synced through iCloud, in records' encrypted fields
    /// (CloudLibrary), in builds with it.
    var signingKeys: [String: String] = Model.loadSigningKeys() {
        didSet {
            // In the Keychain: each one that changed or went.
            for (mac, key) in signingKeys where oldValue[mac] != key { SigningKeyStore.set(key, for: mac) }
            for mac in oldValue.keys where signingKeys[mac] == nil { SigningKeyStore.set(nil, for: mac) }
            if !fromCloud { CloudLibrary.shared.localChanged(.signingKey) }
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
        SigningKeyStore.set(key, for: SigningKeyStore.current)
    }

    /// The chosen bulb's name, if it has one.
    var currentName: String? { name(for: savedMAC ?? mac) }

    /// The chosen bulb's MAC, once known.
    var chosenMAC: String? { savedMAC ?? mac?.lowercased() }

    @ObservationIgnored private var relocating = false

    /// The bulb the user picked or typed: saved, then connected to. `mac` is known for a bulb
    /// picked from discovery; for a typed address it's learnt from the bulb's first reply.
    func choose(_ address: String, mac: String? = nil) {
        let a = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !a.isEmpty else { return }
        notAnsweringSince = nil // chosen (again): worth waiting for
        // Picking the bulb that's already connected changes nothing.
        if a == UserDefaults.standard.string(forKey: Self.addressKey), link == .connected,
           mac == nil || mac?.lowercased() == chosenMAC { return }
        // The same bulb again (to retry it, say): by its MAC, or its address if no MAC is given.
        let sameBulb = mac.map { $0.lowercased() == chosenMAC } ?? (a == UserDefaults.standard.string(forKey: Self.addressKey))
        if !sameBulb { clearUndo() } // undoing is for this bulb's changes
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
        recoveryTask?.cancel() // this connection gets its own, if it comes to that
        recoveryTask = nil
        let generation = connectGeneration
        bulb.connect(to: ip)
        dropPending("Another bulb was chosen (or reconnected) before it answered.")
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

    /// The connection to the bulb failed or was left waiting (the network changed or went away,
    /// sleep, Local Network access off): say so, and keep trying (recover).
    private func connectionLost() {
        guard link != .none else { return }
        // A change that never got its answer didn't take as far as we know (Shortcuts say so).
        if pending, !pilotAnswered, refusal == nil { refusal = "Lost the connection to the bulb before it answered." }
        if pending || verifyingSeq != nil {
            settle(ticket, pilotAnswered ? unanswered : .notAnswered("Lost the connection to the bulb before it answered."))
        }
        pending = false
        verifyingSeq = nil
        let was = link
        link = .unreachable
        live = false
        if bulb.localNetworkDenied {
            localNetworkDenied = true
            status = Self.localNetworkStatus
        } else if was == .connecting {
            status = "Can't reach the bulb from this network; trying again…"
        } else if was == .connected {
            status = "Lost the connection to the bulb; trying again…"
        }
        recover()
    }

    #if os(iOS)
    static let localNetworkStatus = "setPilot needs Local Network access: turn it on in Settings › Apps › setPilot, then try again"
    #else
    static let localNetworkStatus = "setPilot needs Local Network access: turn it on in System Settings › Privacy & Security › Local Network"
    #endif

    /// The bulb stopped answering: keep trying until it does, each time on a fresh connection (one
    /// left waiting by a network change doesn't come back by itself), after 2, 5, 10 and 20 s, then
    /// every 30 s; on the Mac also looking for it at a new address, at first and every 2 minutes.
    /// Stops once it answers, or another bulb (or the same one, by hand) is connected.
    private func recover() {
        guard recoveryTask == nil, let a = UserDefaults.standard.string(forKey: Self.addressKey), !a.isEmpty else { return }
        recoveryRound += 1
        let round = recoveryRound
        let waits: [Double] = [2, 5, 10, 20]
        recoveryTask = Task { [weak self] in
            var attempt = 0
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(attempt < waits.count ? waits[attempt] : 30))
                guard let self, !Task.isCancelled, self.link == .unreachable,
                      UserDefaults.standard.string(forKey: Self.addressKey) == a else { break }
                attempt += 1
                self.retryConnection(a)
                #if os(macOS)
                if attempt == 1 || attempt % 4 == 0 { self.relocate() }
                #endif
            }
            if let self, self.recoveryRound == round { self.recoveryTask = nil }
        }
    }

    /// A fresh connection to the same bulb, keeping what's known of it, with its state read and
    /// live updates registered on it.
    /// `quiet`: the read's answer doesn't need the status line (the bulb was answering anyway).
    private func retryConnection(_ a: String, quiet: Bool = false) {
        lastConnect = .now
        bulb.connect(to: a) // the old connection's retries stop, unanswered: asked again below
        if consoleWaiting != nil {
            consoleWaiting = nil
            consoleFailure = "The connection was made afresh before a reply came: send it again"
        }
        let unread = BulbAPI.deviceInfo.filter { infoReading.contains($0) && $0 != "getPilot" }
        if !unread.isEmpty {
            configTask?.cancel()
            configTask = Task {
                for m in unread {
                    guard !Task.isCancelled else { return }
                    bulb.send(m, retry: true)
                    try? await Task.sleep(for: .milliseconds(60))
                }
            }
        }
        if quiet { quietReads += 1 } else { quietReads = 0 }
        bulb.send("getPilot", retry: true)
        if !wrongBulb { registerOnce() } // not with another device at the address
    }

    /// Answering again after not: no more retrying; live updates registered again straight away
    /// (the bulb may have restarted, or this device have another address), and what was never
    /// read (it wasn't answering from the start) read now.
    private func regained() {
        recoveryTask?.cancel()
        recoveryTask = nil
        if registerTask == nil, let liveHost { startLiveUpdates(liveHost) } else { registerOnce() }
        if firmware == nil {
            for method in ["getModelConfig", "getSystemConfig", "getUserConfig"] { bulb.send(method, retry: true) }
        }
    }

    /// The network changed (another network, a VPN, back from sleep): a fresh connection, since the
    /// old one may be left waiting, registered from this device's address now.
    func networkChanged() {
        guard started, let a = UserDefaults.standard.string(forKey: Self.addressKey), !a.isEmpty else { return }
        switch link {
        case .connected:
            retryConnection(a, quiet: true)
        case .unreachable:
            retryNow(a)
        default:
            break // connecting already, or no bulb
        }
    }

    /// Not answering, but worth trying now (the network's changed, a watch or Shortcut wants it),
    /// and from the start of the waits again.
    private func retryNow(_ a: String) {
        recoveryTask?.cancel()
        recoveryTask = nil
        retryConnection(a)
        recover()
    }

    /// Live updates, and keeping an eye on the bulb: registers now and every 20 s (the bulb answers
    /// each one), and if nothing's been heard from it for 45 s, reads its state quietly. No answer
    /// to that is how a bulb that's gone away is noticed: otherwise it would show as connected
    /// until it was next used.
    private func startLiveUpdates(_ ip: String) {
        liveHost = ip
        registerTask?.cancel()
        registerTask = Task { [weak self] in
            while !Task.isCancelled {
                self?.registerOnce()
                try? await Task.sleep(for: .seconds(20))
                guard !Task.isCancelled, let self else { return }
                self.checkStillThere()
            }
        }
    }

    /// pywizlight's push method: tells the bulb this device's address (worked out each time, so a
    /// new one after a network change is used), and it sends syncPilot to port 38900. Starts the
    /// push listener again if it stopped.
    private func registerOnce() {
        guard let ip = liveHost else { return }
        lastRegistration = .now
        push.startIfNeeded()
        guard push.isRunning else { return } // its failure says why
        guard let phoneIp = Net.sourceIP(toward: ip.trimmingCharacters(in: .whitespaces)) else {
            liveStatus = "Live updates off — couldn't find an IPv4 address for the bulb"
            return
        }
        if !live { liveStatus = "Registering for live updates…" }
        bulb.send("registration", ["phoneIp": phoneIp, "register": true, "phoneMac": phoneMac])
    }

    private func checkStillThere() {
        guard link == .connected, !pending, Date.now.timeIntervalSince(lastHeard) > 45 else { return }
        quietReads += 1 // its answer doesn't need the status line
        bulb.send("getPilot", retry: true)
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
            // Its replies are dropped from now on: a change waiting on a read-back isn't known to be done.
            dropPending("A different bulb answered at this address.")
            status = "A different bulb answered at this address"
            recover()
            return false
        }
        return true
    }

    /// A bulb's address, by its MAC: on the Mac by searching the network (and remembering it); on
    /// iPhone only if it's been used before (no searching there).
    func locate(mac: String) async -> String? {
        let mac = mac.lowercased()
        if let known = knownBulbs.first(where: { $0.mac?.lowercased() == mac && !$0.address.isEmpty }) { return known.address }
        #if os(macOS)
        guard let found = await discover().first(where: { $0.mac.lowercased() == mac }) else { return nil }
        rememberBulb(address: found.ip, mac: mac)
        return found.ip
        #else
        return nil
        #endif
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
            // Local Network access off: that's what needs saying, not the search.
            if !localNetworkDenied { status = "Looking for \(label) on the network…" }
            let found = await discover()
            guard UserDefaults.standard.string(forKey: Self.addressKey) == address else { return } // user chose another
            if let bulb = found.first(where: { $0.mac.lowercased() == saved }), bulb.ip != address {
                UserDefaults.standard.set(bulb.ip, forKey: Self.addressKey)
                rememberBulb(address: bulb.ip, mac: saved)
                connect(bulb.ip)
                status = "\(label) moved to \(bulb.ip); reconnected" // after connect, which clears it
            } else if link == .connected || localNetworkDenied {
                return // answered meanwhile, or the search couldn't have found it
            } else if found.contains(where: { $0.mac.lowercased() == saved }) {
                status = "\(label) answers searches but not requests at \(address); trying again…"
            } else {
                status = "Couldn't find \(label) on the network; trying again…"
            }
        }
        #else
        // No discovery on iOS (no broadcasts without the multicast entitlement): a bulb chosen by
        // DNS name is found again by name (each retry looks it up), and one chosen by IP is tried
        // there until it answers, or is chosen again at another.
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
            localNetworkDenied = true // the help, with its Open Settings button
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
            localNetworkDenied = true
            discoveryNote = Self.localNetworkHelp
            return []
        }
        localNetworkDenied = false // it got through
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
        // Not answering: Sync tries again now, on a fresh connection.
        if link == .unreachable, let a = UserDefaults.standard.string(forKey: Self.addressKey), !a.isEmpty {
            if !quiet { status = "Trying again…" } // asked for: something to show it's trying
            retryNow(a)
            return
        }
        // A change still waiting for its answer keeps waiting (and its read-back): this read is
        // extra, not the end of it, or the change would be taken as done unanswered.
        if pending {
            quietReads += 1
            bulb.send("getPilot", retry: true)
            return
        }
        verifyingSeq = nil
        if quiet { quietReads += 1 } else { quietReads = 0 } // asked for: this one says so
        bulb.send("getPilot", retry: true)
    }

    /// Switches the bulb on or off: a setPilot with "state" (and the controls' fade, which the
    /// bulb takes switching on and may one day switching off), rather than setState, so it goes
    /// the way every other change does (read back, refusals reported). A speed changed while it
    /// was off goes with switching on.
    func power(_ on: Bool) {
        noteUndoPoint()
        PresetUsage.record(on ? PresetUsage.powerOn : PresetUsage.powerOff, in: .standard)
        var p: [String: Any] = [:]
        if let fade = fadeForControls { p["trans"] = fade }
        let owed = on && speedOwed && mode == .scene ? Int(speed) : nil
        transmit(p, speed: owed, power: on, retry: true)
    }

    /// Switches between the three controls. Temperature goes back to whichever scale it last used:
    /// the bulb's own, or a CCT scale (if this bulb still has one).
    func setModeChoice(_ choice: ModeChoice) {
        noteUndoPoint()
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

    /// The scale in use lost its range (edited down to one point, or deleted, here or elsewhere):
    /// Temperature goes to the bulb's own, at about the same kelvin, and says why, rather than
    /// showing the bulb's own slider for a light that's still on the scale.
    private func checkScaleInUse() {
        guard mode == .custom, activeScale?.range == nil, link == .connected else { return }
        let kelvin = customKelvin
        temp = min(max((kelvin / 50).rounded() * 50, tempRange.lowerBound), tempRange.upperBound)
        setMode(Mode.temp)
        status = "The CCT scale in use needs at least two points, so Temperature is on the bulb's own"
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
        noteUndoPoint()
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
        noteUndoPoint()
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
        // A change of its own: whatever was waiting on the last one isn't told this one's answer.
        if method == "setPilot" || method == "setState" { startChange() }
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
            startChange()
            delayedSpeed?.cancel()
            delayedSpeed = nil
            let before = isOn
            if let s = p["state"] as? Bool { isOn = s } else if changesLight { isOn = true }
            if before != isOn { powerBefore = before }
            pilotSwitches = before != isOn
            lastState = isOn
            sendSeq += 1
            pending = true
            bulb.send(method, sent(p), retry: retry, tag: ticket)
            endConsoleWait(after: retry)
            scheduleVerify()
        case "setState":
            startChange() // a new change, as for setPilot
            powerBefore = isOn // what a refusal puts back, whatever this one carries
            if let s = p["state"] as? Bool {
                isOn = s
                lastState = s
            }
            lastMethod = "setState"
            lastSent = JSONText.compact(p)
            bulb.send(method, sent(p), retry: retry, tag: ticket)
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
        startChange()
        sendSeq += 1
        pending = true
        if !p.isEmpty { bulb.send("setPilot", p, retry: retry, tag: ticket) }
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
                bulb.send("setPilot", speedParams, retry: retry, tag: ticket)
            } else {
                // After the scene has started (and so retries of the two don't overlap). Not if
                // another bulb has been chosen meanwhile.
                let generation = connectGeneration
                let change = ticket
                delayedSpeed = Task {
                    try? await Task.sleep(for: .milliseconds(400))
                    // Switched off meanwhile: on its own it would switch it back on. Owed instead.
                    guard !Task.isCancelled, connectGeneration == generation else { return }
                    guard isOn != false else {
                        speedOwed = true
                        lastPilot["speed"] = nil // not sent: the read-back mustn't expect it
                        delayedSpeed = nil
                        return
                    }
                    speedSentAt = .now
                    bulb.send("setPilot", speedParams, retry: retry, tag: change)
                    delayedSpeed = nil // sent: the read-back can go once it's had a moment
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
        if sent {
            PresetUsage.record(preset.id.uuidString, in: .standard) // habits: the Smart Stack, quick actions
            SiriDonation.applied(preset) // and Siri Suggestions
        }
        return sent
    }

    /// Sends several changes as one setPilot, with their own fade time (`trans`).
    /// False if nothing could be sent (the status, and `refusal`, say why).
    @discardableResult
    func send(_ change: LightChange) -> Bool {
        // The undo point only once it's sure to go: a change that can't be sent leaves undo and
        // redo as they were.
        let before = savedLight
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
        noteUndoPoint(before: before)
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

    /// Brighter or dimmer by a step, from the level as setPilot last knew it (sent as the new
    /// level, so a change from elsewhere it hasn't heard of yet is overwritten).
    func adjustDimming(by delta: Int) {
        guard delta != 0 else { forgetRefusal(); return } // nothing to do: no earlier reason applies
        noteUndoPoint()
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
        startChange()
        sendSeq += 1
        pending = true
        pilotSwitches = false
        bulb.send("setPilot", p, retry: true, tag: ticket)
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
        dropPending("A light show took over the bulb before it answered.")
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
        guard link == .connected else { connect(a); return }
        sync()
        // Registered again now (pushes sent while suspended are lost), the listener restarted if
        // it stopped.
        if registerTask == nil, let liveHost { startLiveUpdates(liveHost) } else { registerOnce() }
    }

    /// getPilot replies so far, so a refresh can wait for the next one.
    @ObservationIgnored private var pilotReads = 0

    /// Pull to refresh: `resume`, then wait (up to `timeout`) until the bulb's state has been read.
    func refresh(timeout: Double = Model.answerTimeout) async {
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
        // Not connected: connect, unless one is still under way (its reads retry for as long as
        // anything waits, answerTimeout, so starting another on every watch poll only restarts them). One left stuck connecting
        // (the app suspended part way) is redone.
        if link != .connected {
            // Not answering: tried again now on a fresh connection, keeping what's known of it.
            if link == .unreachable, Date.now.timeIntervalSince(lastConnect) > 3 {
                retryNow(a)
            } else if link == .none || Date.now.timeIntervalSince(lastConnect) > Self.answerTimeout {
                connect(a)
            }
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
        if let liveHost {
            if registerTask == nil { startLiveUpdates(liveHost) }
            else if !push.isRunning || Date.now.timeIntervalSince(lastRegistration) > 15 { registerOnce() }
        }
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
        BulbAPI.deviceInfo.erroredLast(infoErrors).compactMap { m in
            // One still being read again goes as that, not as the last read's answer.
            info[m].map { DeviceInfoEntry(method: m, text: $0, error: infoReading.contains(m) ? "No reply yet" : infoErrors[m]) }
        }
    }

    func setFavourite(_ id: UUID, _ on: Bool) {
        guard let i = library.presets.firstIndex(where: { $0.id == id }) else { return }
        library.presets[i].favourite = on ? true : nil
    }

    func renamePreset(_ id: UUID, to name: String) {
        let n = name.trimmingCharacters(in: .whitespaces)
        guard !n.isEmpty, let i = library.presets.firstIndex(where: { $0.id == id }) else { return }
        library.presets[i].name = n
    }

    /// How long anything waits for the bulb (a widget, Shortcut, link, the CLI, AppleScript, the
    /// watch): as long as a request is retried before it's given up on, and a moment more.
    static let answerTimeout = BulbTiming.answerTimeout

    /// When waiting for the bulb last came to nothing, and at which address. For 10 s after, waits
    /// for it fail at once rather than waiting their turn to find out again: a burst of taps (or
    /// a Shortcut run again) during an outage would otherwise queue up and land long after they
    /// were meant, or time out. Trying to reach it carries on meanwhile.
    @ObservationIgnored private var notAnsweringSince: Date?
    @ObservationIgnored private var notAnsweringAddress: String?

    /// Just found not answering, and still the same bulb (another one is worth waiting for).
    var recentlyNotAnswering: Bool {
        guard let since = notAnsweringSince, Date.now.timeIntervalSince(since) < BulbTiming.notAnsweringHold,
              notAnsweringAddress == UserDefaults.standard.string(forKey: Self.addressKey) else { return false }
        return true
    }

    /// Connects to the saved bulb if needed and waits until it can be controlled (or `timeout`).
    /// If the state is being read again (see `ensureLive`), waits for that too, so what's sent and
    /// reported starts from the bulb's real state. Just found not answering: false at once.
    func waitUntilControllable(timeout: Double = Model.answerTimeout) async -> Bool {
        // No bulb chosen: nothing to wait for (and nothing to remember as not answering).
        guard !(UserDefaults.standard.string(forKey: Self.addressKey) ?? "").isEmpty else { return false }
        // Just found not answering (even if it still shows as connected, a read-back just went
        // unanswered, say): at once. An answer from the bulb clears it (handleReply).
        if recentlyNotAnswering {
            _ = ensureLive() // tried again meanwhile, for the next one
            return false
        }
        let reads = pilotReads
        let reading = ensureLive()
        let end = Date().addingTimeInterval(timeout)
        while !canControl && Date() < end { try? await Task.sleep(for: .milliseconds(100)) }
        if reading {
            while pilotReads == reads && Date() < end { try? await Task.sleep(for: .milliseconds(100)) }
        }
        // Ready only with the state read afresh if it was being read: a change mustn't go by a
        // state from before (a toggle the wrong way).
        let ready = canControl && (!reading || pilotReads != reads)
        // Not answering, after a whole wait: the hold starts. Not for a short wait (what was left
        // of a change's time) or a bulb that's answering but refusing.
        if !ready, timeout >= Self.answerTimeout - 0.01, link != .connected { markNotAnswering() }
        return ready
    }

    /// Whether anything's been heard from the bulb since `date`.
    func heardSince(_ date: Date) -> Bool { lastHeard > date }

    /// A wait for the bulb (or for its answer to a change) came to nothing: for a while, waits
    /// for it fail at once (recentlyNotAnswering).
    func markNotAnswering() {
        notAnsweringSince = .now
        notAnsweringAddress = UserDefaults.standard.string(forKey: Self.addressKey)
    }

    /// Waits until the last change has been read back (or `timeout`).
    func waitUntilSettled(timeout: Double = Model.answerTimeout) async {
        let end = Date().addingTimeInterval(timeout)
        while pending && Date() < end { try? await Task.sleep(for: .milliseconds(100)) }
    }

    /// A scene speed changed while the bulb was off, still to go when it's switched on.
    var owedSpeed: Int? { speedOwed && mode == .scene ? Int(speed) : nil }

    /// Once changes settle, read the state back to catch values the bulb ignored or adjusted
    /// (it replies "success" to some setPilots it doesn't fully apply).
    private func scheduleVerify() {
        verifyTask?.cancel()
        verifyTask = Task {
            try? await Task.sleep(for: .milliseconds(700))
            // Not before the change is answered (a retry still to go would land after the read,
            // and be taken as not applied), nor before a scene's speed has gone and had a moment.
            let end = Date().addingTimeInterval(BulbTiming.replyWindow)
            while !Task.isCancelled, pending, !pilotAnswered || delayedSpeed != nil, Date() < end {
                try? await Task.sleep(for: .milliseconds(100))
            }
            if let sent = speedSentAt, Date.now.timeIntervalSince(sent) < 0.3 {
                try? await Task.sleep(for: .seconds(0.3 - Date.now.timeIntervalSince(sent)))
            }
            guard !Task.isCancelled, pending else { return } // settled meanwhile (refused, or no answer)
            verifyingSeq = sendSeq
            // This read settles the state; a quiet read still owed for an earlier refusal would
            // only keep a later Sync from saying so.
            quietReads = 0
            bulb.send("getPilot", retry: true, tag: ticket)
        }
    }

    /// When a scene's delayed speed went (scheduleVerify gives it a moment before reading back).
    @ObservationIgnored private var speedSentAt: Date?

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
        settle(ticket, mismatch.map { .notApplied($0) } ?? .done)
    }

    // MARK: Incoming

    private func handleReply(_ reply: [String: Any]) {
        if wrongBulb {
            // Only the chosen bulb, back at the address, by its MAC.
            guard let m = (reply["result"] as? [String: Any])?["mac"] as? String, m.lowercased() == savedMAC else { return }
            wrongBulb = false
        }
        lastHeard = .now
        let method = reply["method"] as? String ?? "?"
        if reply["hmac"] != nil { bulbSigns = true }
        if let err = reply["error"] as? [String: Any] {
            // Back after not answering, as for a result below: what it showed may be out of date.
            if link == .unreachable {
                if method != "getPilot" { bulb.send("getPilot", retry: true) }
                regained()
            }
            link = .connected
            localNetworkDenied = false
            notAnsweringSince = nil // answering, if refusing
            // A refused change or read-back: nothing to read back (a read that works unsigned would
            // replace the error below with "didn't apply"), and nothing is pending any more.
            // A read-back already on its way (the refusal came after it went out) will do.
            let readOut = verifyingSeq != nil && verifyingSeq == sendSeq
            let wasReadBack = method == "getPilot" && readOut
            // (A refused getPilot only ends the wait if it's the current change's read-back.)
            if method == "setPilot" || method == "setState" || (method == "getPilot" && readOut) {
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
            if method == "setPilot" || method == "setState" {
                refusal = "\(method): \(text)"
                settle(ticket, .refused("\(method): \(text)"))
            } else if wasReadBack {
                // The read-back refused (a signing key, say): taken if the change was answered.
                settle(ticket, pilotAnswered ? .done : .refused("getPilot: \(text)"))
            }
            status = "\(method): \(text)"
            return
        }
        let anyResult = reply["result"]
        if let r = anyResult as? [String: Any], let replyMAC = r["mac"] as? String, !isChosenBulb(replyMAC) { return }
        notAnsweringSince = nil // the chosen bulb's answering
        // Device info: every read's reply, as it came.
        if BulbAPI.deviceInfo.contains(method), let anyResult {
            info[method] = JSONText.pretty(anyResult)
            infoErrors[method] = nil
            infoReading.remove(method)
        }
        guard let result = anyResult as? [String: Any] else { return }
        // Back after not answering (e.g. the 20 s registration got through): re-read its state.
        if link == .unreachable {
            if method != "getPilot" { bulb.send("getPilot", retry: true) }
            regained()
        }
        link = .connected
        localNetworkDenied = false
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
            settle(ticket, .done) // nothing to read back for setState
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
    #if WIZ_ICLOUD
    private static let kept = "It syncs to your other devices through iCloud, encrypted."
    #else
    private static let kept = "It's kept on this device only."
    #endif
    static let text = "Newer firmware can refuse unsigned changes. Its key is the home's udp_signing_key, from the WiZ app's export of the home for local integration. With a key, setPilot signs every request to this bulb (but not the console's raw messages). " + kept
}
