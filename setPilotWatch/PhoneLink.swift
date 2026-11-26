import Foundation
import WatchConnectivity
import WidgetKit

/// The watch end of the link: sends commands to setPilot on the iPhone, which talks to the bulb,
/// and keeps the iPhone's presets, custom scene names and state (cached for when it's out of reach).
@MainActor @Observable
final class PhoneLink: NSObject {
    static let shared = PhoneLink()

    private(set) var snapshot: LightSnapshot?
    private(set) var presets: [Preset] = []
    private(set) var scenes: [CustomSceneSummary] = []
    private(set) var reachable = false
    /// Activated, and the iPhone in reach: a command can go now.
    var ready: Bool { WCSession.default.activationState == .activated && WCSession.default.isReachable }
    /// A command is waiting for the iPhone's reply (of however many are).
    var busy: Bool { waiting > 0 }
    private var waiting = 0
    var error: String?
    /// The bulb's reads, from the last device info request.
    private(set) var deviceInfo: [DeviceInfoEntry] = []

    private let defaults = UserDefaults.standard

    override init() {
        super.init()
        let decoder = JSONDecoder()
        if let d = defaults.data(forKey: WatchKey.presets) { presets = (try? decoder.decode([Preset].self, from: d)) ?? [] }
        if let d = defaults.data(forKey: WatchKey.customScenes) { scenes = (try? decoder.decode([CustomSceneSummary].self, from: d)) ?? [] }
        if let d = defaults.data(forKey: WatchKey.snapshot) { snapshot = try? decoder.decode(LightSnapshot.self, from: d) }
    }

    func start() {
        guard WCSession.isSupported() else { return }
        WCSession.default.delegate = self
        WCSession.default.activate()
    }

    // MARK: Live changes

    /// A live change (the Crown) is on its way, or waiting for the one before it.
    private(set) var liveBusy = false
    /// Counts live changes finishing (answered or not), for views to go back to the bulb's values:
    /// `liveBusy` can go on and off before a view sees it change.
    private(set) var liveSettled = 0
    /// Live changes sent and not yet answered: normally at most one, but a command sent meanwhile
    /// sends the waiting one alongside.
    private var liveInFlight = 0
    /// The latest live change waiting for the one before to be answered, with when it was made.
    private var livePending: (values: LightValues, fields: Set<PilotField>, at: Date)?

    /// For values changed continuously: the first change goes at once, and while one is on its
    /// way only the latest is kept, going as soon as the iPhone answers. So the bulb follows as
    /// fast as the link allows, without a backlog of old values arriving after you've stopped.
    func sendLive(_ values: LightValues, fields: Set<PilotField>) {
        liveBusy = true
        if liveInFlight > 0 {
            livePending = (values, fields.union(livePending?.fields ?? []), .now)
            return
        }
        transmitLive(values, fields: fields, at: .now)
    }

    private func transmitLive(_ values: LightValues, fields: Set<PilotField>, at: Date) {
        liveInFlight += 1
        transmit(.set(values, fields: Array(fields)), quiet: false, asked: at) { [weak self] _ in
            guard let self else { return }
            self.liveInFlight -= 1
            guard self.liveInFlight == 0 else { return } // the latest is still on its way
            if let next = self.livePending, Date.now.timeIntervalSince(next.at) < BulbTiming.answerTimeout {
                self.livePending = nil
                self.transmitLive(next.values, fields: next.fields, at: next.at)
            } else {
                // Nothing waiting, or too old to send now (it would land late): the state that
                // comes back shows where the light is.
                self.livePending = nil
                self.liveBusy = false
                self.liveSettled += 1
            }
        }
    }

    /// Sends a command; the reply updates `snapshot`. Errors show in `error`, unless `quiet`
    /// (background refreshes). A live change still waiting goes first, so it isn't lost or
    /// applied after this.
    /// `done`: true once the iPhone has answered without an error.
    /// `asked`: when it was asked for (a tap that waited for the session), sent with it so the
    /// iPhone counts its waits from then.
    func send(_ command: WatchCommand, quiet: Bool = false, asked: Date = .now, done: (@MainActor (Bool) -> Void)? = nil) {
        if !quiet, let next = livePending {
            livePending = nil
            if Date.now.timeIntervalSince(next.at) < BulbTiming.answerTimeout { transmitLive(next.values, fields: next.fields, at: next.at) }
        }
        // What's waiting for the iPhone and bulb to confirm, for its spinner.
        let key = Self.pendingKey(command)
        if let key { pendingCounts[key, default: 0] += 1 }
        transmit(command, quiet: quiet, asked: asked) { [weak self] ok in
            if let key, let self {
                // Counted: the same one tapped twice spins until the last has answered.
                let left = (self.pendingCounts[key] ?? 1) - 1
                self.pendingCounts[key] = left > 0 ? left : nil
            }
            done?(ok)
        }
    }

    /// What's being confirmed: a preset's or custom scene's ID, "power" or "brightness".
    var pending: Set<String> { Set(pendingCounts.keys) }
    private var pendingCounts: [String: Int] = [:]

    private static func pendingKey(_ command: WatchCommand) -> String? {
        switch command {
        case .applyPreset(let id), .playCustom(let id, _): id.uuidString
        case .power, .togglePower: "power"
        case .dimDelta: "brightness"
        default: nil
        }
    }

    private func transmit(_ command: WatchCommand, quiet: Bool, asked: Date = .now, done: (@MainActor (Bool) -> Void)? = nil) {
        let session = WCSession.default
        // Not answered: `done` still comes afterwards, as a reply would.
        guard session.activationState == .activated, session.isReachable else {
            if !quiet { error = "Can't reach your iPhone. Keep it nearby, with Bluetooth or Wi-Fi on." }
            Task { @MainActor in done?(false) }
            return
        }
        guard let data = try? JSONEncoder().encode(command) else {
            Task { @MainActor in done?(false) }
            return
        }
        if !quiet {
            waiting += 1
            error = nil
        }
        session.sendMessage([WatchKey.command: data, WatchKey.sentAt: asked.timeIntervalSince1970], replyHandler: { reply in
            let snapshot = (reply[WatchKey.snapshot] as? Data).flatMap { try? JSONDecoder().decode(LightSnapshot.self, from: $0) }
            let message = reply[WatchKey.error] as? String
            let info = (reply[WatchKey.deviceInfo] as? Data).flatMap { try? JSONDecoder().decode([DeviceInfoEntry].self, from: $0) }
            Task { @MainActor in
                if !quiet { self.waiting -= 1 }
                if let snapshot { self.apply(snapshot) }
                if let info { self.deviceInfo = info }
                done?(message == nil)
                if let message, !quiet { self.error = message }
            }
        }, errorHandler: { error in
            let text = error.localizedDescription
            Task { @MainActor in
                done?(false)
                guard !quiet else { return }
                self.waiting -= 1
                self.error = "Your iPhone didn't answer: \(text)"
            }
        })
    }

    /// Reads the bulb's device info afresh: what an earlier read showed (perhaps of another bulb)
    /// goes until the new one arrives.
    func readDeviceInfo() {
        deviceInfo = []
        send(.deviceInfo)
    }

    /// Asks for the bulb's state, quietly: no error if the iPhone is out of reach.
    func refresh() {
        guard WCSession.default.activationState == .activated, WCSession.default.isReachable else { return }
        send(.state, quiet: true)
    }

    private func apply(_ s: LightSnapshot) {
        // Older than the one we have (a late context or message): keep ours. Unless ours is
        // stamped well ahead of now (the iPhone's clock was set back since): then it can't be
        // trusted to be newer, and would hold every update off.
        if let new = s.sentAt, let old = snapshot?.sentAt, new < old, old < Date.now.addingTimeInterval(60) { return }
        snapshot = s
        if let data = try? JSONEncoder().encode(s) { defaults.set(data, forKey: WatchKey.snapshot) }
        // For the complications: reloaded only when something they show changes.
        SharedStore.save(s, SharedStore.snapshotKey)
        let key = "\(s.link) \(String(describing: s.isOn)) \(Int(s.dimming / 5)) \(s.bulbName ?? "")"
        trailingReload?.cancel()
        if key != widgetKey {
            widgetKey = key
            reloadedDimming = Int(s.dimming)
            reloadWidgets()
        } else if Int(s.dimming) != reloadedDimming {
            // The same step of 5, but they show the exact level: once it's settled (one more
            // reload per Crown turn, not one per step).
            trailingReload = Task {
                try? await Task.sleep(for: .seconds(1.5))
                guard !Task.isCancelled else { return }
                reloadedDimming = Int(s.dimming)
                reloadWidgets()
            }
        }
    }
    @ObservationIgnored private var reloadedDimming: Int?
    @ObservationIgnored private var trailingReload: Task<Void, Never>?

    private var widgetKey: String?

    /// While the app is on screen: ask for the state every few seconds, for changes made
    /// elsewhere (the iPhone also sends changes as they happen while it's running).
    func poll() async {
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(4))
            if isActive, !busy { refresh() }
        }
    }

    /// The app is in the foreground (screen on, app showing). Only then does it poll the iPhone.
    var isActive = true

    /// Complication or control taps that arrived before the link to the iPhone was up (the app
    /// launched by one), in order: acted on once it's up, if that's soon (BulbTiming.answerTimeout
    /// from each tap, as any wait). Never once it's been said that the iPhone can't be reached: a
    /// change mustn't land late. Each shows as waiting meanwhile (its spinner).
    private var waitingURLs: [(url: URL, at: Date)] = []

    /// Links from the complications and controls; `at` is when it was tapped.
    func open(_ url: URL, at: Date = .now) {
        guard url.scheme == "setpilot" else { return }
        let session = WCSession.default
        guard Date.now.timeIntervalSince(at) < BulbTiming.answerTimeout else {
            error = "That tap waited too long to be sent, so it wasn't. Tap again."
            return
        }
        // The launch race (the session's on its way), or the iPhone out of reach, often only for a
        // moment: kept until the tap's time is up, then said and dropped, never sent after that.
        guard session.activationState == .activated, session.isReachable else {
            waitingURLs.append((url, at))
            if let key = Self.pendingKey(url) { pendingCounts[key, default: 0] += 1 }
            dropWhenDue(url, at: at)
            return
        }
        perform(url, at: at)
    }

    /// The waiting tap, if it's still waiting once its time is up: dropped, saying why.
    private func dropWhenDue(_ url: URL, at: Date) {
        let left = BulbTiming.answerTimeout - Date.now.timeIntervalSince(at)
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(max(left, 0)))
            guard let self, let i = self.waitingURLs.firstIndex(where: { $0.url == url && $0.at == at }) else { return }
            self.waitingURLs.remove(at: i)
            self.stopWaiting(url)
            self.error = "Can't reach your iPhone, so that wasn't sent. Keep it nearby, with Bluetooth or Wi-Fi on."
        }
    }

    /// Acts on the taps that were waiting for the session, in the order they came.
    private func openWaitingURL() {
        let waiting = waitingURLs
        waitingURLs = []
        for tap in waiting {
            stopWaiting(tap.url)
            open(tap.url, at: tap.at)
        }
    }

    private func stopWaiting(_ url: URL) {
        guard let key = Self.pendingKey(url) else { return }
        let left = (pendingCounts[key] ?? 1) - 1
        pendingCounts[key] = left > 0 ? left : nil
    }

    /// A tap's spinner key (as its command's).
    private static func pendingKey(_ url: URL) -> String? {
        switch url.host() {
        case "preset": UUID(uuidString: url.lastPathComponent)?.uuidString
        case "power": "power"
        case "brighter", "dimmer": "brightness"
        default: nil
        }
    }

    private func perform(_ url: URL, at: Date) {
        switch url.host() {
        case "preset":
            if let id = UUID(uuidString: url.lastPathComponent) { send(.applyPreset(id), asked: at) }
        case "power":
            send(.togglePower, asked: at) // the iPhone knows how it is now; our copy may be from last time
        case "brighter":
            send(.dimDelta(10), asked: at) // from the controls
        case "dimmer":
            send(.dimDelta(-10), asked: at)
        default:
            refresh()
        }
    }

    private func applyContext(_ context: [String: Any]) {
        let decoder = JSONDecoder()
        // Only what changed: the context also carries the state, and comes again with each change.
        if let d = context[WatchKey.presets] as? Data, d != defaults.data(forKey: WatchKey.presets),
           let p = try? decoder.decode([Preset].self, from: d) {
            presets = p
            defaults.set(d, forKey: WatchKey.presets)
            SharedStore.save(p, SharedStore.presetsKey)
            reloadWidgets()
            // The preset complication's choices are one suggestion per preset.
            WidgetCenter.shared.invalidateConfigurationRecommendations()
            // And Siri learns the preset names (Apply … in setPilot).
            WatchShortcuts.updateAppShortcutParameters()
        }
        if let d = context[WatchKey.customScenes] as? Data, d != defaults.data(forKey: WatchKey.customScenes),
           let s = try? decoder.decode([CustomSceneSummary].self, from: d) {
            scenes = s
            defaults.set(d, forKey: WatchKey.customScenes)
            SharedStore.save(s, SharedStore.customScenesKey) // for custom scene swatches
            reloadWidgets()
        }
        // Only when it's changed: the context comes with every state change too, and reloads have a budget.
        if let d = context[WatchKey.presetUsage] as? Data, d != defaults.data(forKey: WatchKey.presetUsage),
           let uses = try? decoder.decode([PresetUsage.Use].self, from: d) {
            defaults.set(d, forKey: WatchKey.presetUsage)
            PresetUsage.merge(uses, into: SharedStore.defaults)
            reloadWidgets() // the preset complications' relevance in the Smart Stack
        }
        if let d = context[WatchKey.snapshot] as? Data, let s = try? decoder.decode(LightSnapshot.self, from: d) {
            apply(s)
        }
    }
}

extension PhoneLink: WCSessionDelegate {
    nonisolated func session(_ session: WCSession, activationDidCompleteWith state: WCSessionActivationState, error: Error?) {
        let context = session.receivedApplicationContext
        let reachable = session.isReachable
        let box = UncheckedContext(context)
        Task { @MainActor in
            self.applyContext(box.value)
            self.reachable = reachable
            if reachable {
                self.refresh()
                self.openWaitingURL()
            }
            // Otherwise taps waiting stay so until their time's up (dropWhenDue, set as they came).
        }
    }

    nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
        let reachable = session.isReachable
        Task { @MainActor in
            self.reachable = reachable
            if reachable {
                self.error = nil
                self.refresh()
                self.openWaitingURL()
            }
        }
    }

    nonisolated func session(_ session: WCSession, didReceiveApplicationContext context: [String: Any]) {
        let box = UncheckedContext(context)
        Task { @MainActor in self.applyContext(box.value) }
    }

    nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        guard let d = message[WatchKey.snapshot] as? Data,
              let s = try? JSONDecoder().decode(LightSnapshot.self, from: d) else { return }
        Task { @MainActor in self.apply(s) }
    }
}

/// WatchConnectivity's dictionaries hold only property-list values, which are safe to pass on.
private struct UncheckedContext: @unchecked Sendable {
    let value: [String: Any]
    init(_ value: [String: Any]) { self.value = value }
}

/// The complications and the controls (Control Center, the Smart Stack, the Action button).
@MainActor
private func reloadWidgets() {
    WidgetCenter.shared.reloadAllTimelines()
    ControlCenter.shared.reloadAllControls()
}
