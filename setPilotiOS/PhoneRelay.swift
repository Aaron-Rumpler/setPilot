import Foundation
import Observation
import WatchConnectivity
import WidgetKit

/// The iPhone end of the watch link. The watch can't talk to the bulb itself (watchOS only allows
/// low-level networking while streaming audio), so it sends commands here; this runs them on the
/// shared model and replies with the bulb's state. It also keeps the watch's copy of the presets,
/// custom scene names and state up to date.
@MainActor
final class PhoneRelay: NSObject {
    static let shared = PhoneRelay()

    private var model: Model?
    private var pushScheduled = false
    private var lastSnapshot: LightSnapshot?

    /// The watch's commands, run one at a time in the order they came: a Crown change sent just
    /// before a preset mustn't land after it (each can wait for the bulb, and wake in any order).
    /// (WatchConnectivity's reply handler isn't marked Sendable, but may be called from any thread.)
    private struct Incoming: @unchecked Sendable {
        let command: WatchCommand
        let reply: ([String: Any]) -> Void
    }
    private let incoming: AsyncStream<Incoming>
    nonisolated private let incomingQueue: AsyncStream<Incoming>.Continuation

    override init() {
        (incoming, incomingQueue) = AsyncStream.makeStream(of: Incoming.self)
        super.init()
    }

    func start(model: Model) {
        guard self.model == nil else { return }
        self.model = model
        Task { [incoming] in
            for await message in incoming { await self.handle(message) }
        }
        observeState()
        publishLibrary()
        guard WCSession.isSupported() else { return }
        WCSession.default.delegate = self
        WCSession.default.activate()
    }

    // MARK: Commands

    /// What's left once a command has run: reply now, or after a pause and the bulb's read-back.
    private enum Outcome {
        case now(LightSnapshot)
        case settle(after: Duration)
        /// Not done: the bulb isn't answering (the reply says so).
        case failed(LightSnapshot)
    }

    /// When waiting for the bulb last came to nothing. For a while after, commands don't wait
    /// their turn to find out again: a burst of taps during an outage would queue up, then either
    /// time out on the watch or land late, long after they were meant. They're answered "not
    /// answering" at once instead (a connect keeps being tried meanwhile).
    private var notAnsweringSince: Date?

    /// The bulb can take a command now, waiting (up to `timeout`) only if it hasn't just been
    /// found not answering.
    private func bulbReady(_ model: Model, timeout: Double = 5) async -> Bool {
        if model.canControl {
            notAnsweringSince = nil
            return true
        }
        if let since = notAnsweringSince, Date.now.timeIntervalSince(since) < 10 {
            _ = model.ensureLive()
            return false
        }
        let ready = await model.waitUntilControllable(timeout: timeout)
        notAnsweringSince = ready ? nil : .now
        return ready
    }

    /// Runs a command as far as sending it. Waiting for the bulb to settle is left to the caller,
    /// apart from the queue: only the sending needs to keep the order, and the next command
    /// shouldn't wait out this one's read-back.
    private func run(_ command: WatchCommand) async -> Outcome {
        guard let model else { return .now(LightSnapshot()) }
        switch command {
        case .state:
            _ = await bulbReady(model, timeout: 3)
            return .now(model.snapshot)
        case .savePreset(let name):
            // The light as it is: not saved from a state that may be out of date.
            guard await bulbReady(model, timeout: 3) else { return .failed(model.snapshot) }
            model.savePreset(named: name)
            return .now(model.snapshot)
        case .deletePreset(let id):
            model.library.presets.removeAll { $0.id == id }
            return .now(model.snapshot)
        case let .renamePreset(id, name):
            model.renamePreset(id, to: name)
            return .now(model.snapshot)
        case let .movePreset(id, offset):
            model.movePreset(id, by: offset)
            return .now(model.snapshot)
        case let .controlsFade(choice, ms):
            model.controlsFade = choice
            model.controlsFadeMs = min(max(ms, 0), 60_000)
            return .now(model.snapshot)
        case let .renameBulb(mac, name):
            model.rename(mac: mac, to: name)
            return .now(model.snapshot)
        case let .chooseBulb(address, mac):
            model.choose(address, mac: mac)
            notAnsweringSince = nil // another bulb: worth waiting for
            _ = await bulbReady(model, timeout: 4)
            return .now(model.snapshot)
        default:
            break
        }
        guard await bulbReady(model) else { return .failed(model.snapshot) }
        var pause = Duration.zero
        switch command {
        case .sync:
            model.sync()
            pause = .milliseconds(500)
        case .power(let on):
            model.power(on)
            pause = .milliseconds(400)
        case .togglePower:
            model.power(!(model.isOn ?? false))
            pause = .milliseconds(400)
        case .applyPreset(let id):
            if let preset = model.library.presets.first(where: { $0.id == id }) { model.apply(preset) }
        case .set(let values, let fields):
            model.apply(values, fields: fields)
            // Answered once sent, not after the read-back: the watch sends the next live change
            // when this answers. Later state reaches it as the iPhone's usual updates.
            return .now(model.snapshot)
        case .dimDelta(let delta):
            model.adjustDimming(by: delta)
        case .playCustom(let id):
            if let scene = model.library.customScene(id) { model.playCustom(scene, switchOn: true) }
        case .compose(let change):
            model.send(change)
        case .modeChoice(let choice):
            model.setModeChoice(choice)
        case .temperatureScale(let id):
            model.useTemperatureScale(id)
        case .updatePreset(let id):
            model.updatePreset(id)
        case .deviceInfo:
            model.readConfig()
            // The reads go out 60 ms apart; give the replies time to come in.
            pause = .milliseconds(2500)
        case .state, .savePreset, .deletePreset, .chooseBulb, .renamePreset, .movePreset, .controlsFade, .renameBulb:
            break
        }
        return .settle(after: pause)
    }

    // MARK: Keeping the watch up to date

    /// Sends the state to the watch whenever it changes (at most every 0.3 s), while it's reachable.
    private func observeState() {
        guard let model else { return }
        withObservationTracking {
            _ = model.snapshot
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.schedulePush()
                self?.observeState()
            }
        }
    }

    private func schedulePush() {
        guard !pushScheduled else { return }
        pushScheduled = true
        Task {
            try? await Task.sleep(for: .milliseconds(300))
            pushScheduled = false
            guard let snapshot = model?.snapshot, snapshot != lastSnapshot else { return }
            lastSnapshot = snapshot
            publishState(snapshot)
            guard WCSession.isSupported() else { return }
            let session = WCSession.default
            guard session.activationState == .activated, session.isPaired, session.isWatchAppInstalled else { return }
            if session.isReachable {
                if let data = try? JSONEncoder().encode(Self.stamped(snapshot)) {
                    session.sendMessage([WatchKey.snapshot: data], replyHandler: nil, errorHandler: nil)
                }
            } else if snapshot.link == .connected {
                // Out of reach (the watch app isn't open, say): the copy it starts from next time.
                // Otherwise the context keeps the state from when it was last written (often
                // "connecting", at launch). Not while reachable: the watch has the messages, and a
                // context, which comes when it comes, would only arrive later with older news.
                scheduleStateContext()
            }
        }
    }

    /// The state as it goes to the watch, marked with when.
    private static func stamped(_ snapshot: LightSnapshot) -> LightSnapshot {
        var s = snapshot
        s.sentAt = .now
        return s
    }

    private var stateContextScheduled = false

    /// The state in the application context, at most every 3 s (each one the watch gets can
    /// reload its complications, which have a budget).
    private func scheduleStateContext() {
        guard !stateContextScheduled else { return }
        stateContextScheduled = true
        Task {
            try? await Task.sleep(for: .seconds(3))
            stateContextScheduled = false
            updateContext()
        }
    }

    private var contextScheduled = false

    /// The library changed, or a setting the watch and widgets carry (the fades, snapping): pass
    /// it on to them (and Siri), at most twice a second.
    func libraryChanged() {
        guard !contextScheduled else { return }
        contextScheduled = true
        Task {
            try? await Task.sleep(for: .milliseconds(500))
            contextScheduled = false
            publishLibrary()
            updateContext()
            SetPilotShortcuts.updateAppShortcutParameters() // so Siri knows the preset names
        }
    }

    // MARK: Widgets and controls

    private var widgetKey: String?

    /// Keeps the state widgets show, reloading them when something they show changes (they have
    /// a reload budget, so not on every slider step).
    private func publishState(_ s: LightSnapshot) {
        SharedStore.save(s, SharedStore.snapshotKey)
        SharedStore.defaults.set(s.address, forKey: SharedStore.addressKey)
        let key = "\(s.link) \(String(describing: s.isOn)) \(Int(s.dimming / 5)) \(s.mode) \(s.bulbName ?? "")"
        guard key != widgetKey else { return }
        widgetKey = key
        reloadWidgets()
    }

    /// The presets for widgets and controls, each with its setPilot ready to send.
    private func publishLibrary() {
        guard let model else { return }
        SharedStore.save(model.library.presets, SharedStore.presetsKey)
        SharedStore.save(model.library.summaries, SharedStore.customScenesKey) // for custom scene swatches
        var params: [String: Data] = [:]
        for preset in model.library.presets {
            if let p = model.pilotParams(for: preset), let d = try? JSONSerialization.data(withJSONObject: p) {
                params[preset.id.uuidString] = d
            }
        }
        SharedStore.defaults.set(params, forKey: SharedStore.presetParamsKey)
        SharedStore.defaults.set(model.fadeForControls, forKey: SharedStore.controlsTransKey)
        reloadWidgets()
    }

    private func reloadWidgets() {
        WidgetCenter.shared.reloadAllTimelines()
        ControlCenter.shared.reloadAllControls()
    }

    /// The application context holds what the watch should show even when the iPhone isn't
    /// reachable: the presets, custom scene names and the last known state.
    private func updateContext() {
        guard let model, WCSession.isSupported() else { return }
        let session = WCSession.default
        guard session.activationState == .activated, session.isPaired, session.isWatchAppInstalled else { return }
        let encoder = JSONEncoder()
        var context: [String: Any] = [:]
        if let data = try? encoder.encode(model.library.presets) { context[WatchKey.presets] = data }
        if let data = try? encoder.encode(model.library.summaries) { context[WatchKey.customScenes] = data }
        // Only a state worth keeping: "connecting" or "no bulb" would replace the watch's last good one.
        if model.snapshot.link == .connected, let data = try? encoder.encode(Self.stamped(model.snapshot)) {
            context[WatchKey.snapshot] = data
        } else if let kept = session.applicationContext[WatchKey.snapshot] {
            context[WatchKey.snapshot] = kept
        }
        try? session.updateApplicationContext(context)
    }
}

extension PhoneRelay: WCSessionDelegate {
    nonisolated func session(_ session: WCSession, activationDidCompleteWith state: WCSessionActivationState, error: Error?) {
        Task { @MainActor in self.updateContext() }
    }

    nonisolated func sessionDidBecomeInactive(_ session: WCSession) {}

    nonisolated func sessionDidDeactivate(_ session: WCSession) {
        // A different watch was chosen: start again with it.
        session.activate()
    }

    nonisolated func sessionWatchStateDidChange(_ session: WCSession) {
        Task { @MainActor in self.updateContext() }
    }

    nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any],
                             replyHandler: @escaping ([String: Any]) -> Void) {
        guard let data = message[WatchKey.command] as? Data,
              let command = try? JSONDecoder().decode(WatchCommand.self, from: data) else {
            replyHandler([WatchKey.error: "setPilot on your iPhone didn't understand that; update both apps"])
            return
        }
        incomingQueue.yield(Incoming(command: command, reply: replyHandler))
    }

    private func handle(_ message: Incoming) async {
        // Woken for this, perhaps from the background: commands for the bulb get live updates
        // going again (and the state read again if the app was suspended) through
        // waitUntilControllable, so changes from elsewhere reach the watch while it's awake.
        switch await run(message.command) {
        case .now(let snapshot):
            finish(message, snapshot)
        case .failed(let snapshot):
            finish(message, snapshot, error: "Your bulb isn't answering. It may be off at the wall or out of Wi-Fi range.")
        case .settle(let pause):
            Task {
                try? await Task.sleep(for: pause)
                await model?.waitUntilSettled()
                finish(message, model?.snapshot ?? LightSnapshot())
            }
        }
    }

    private func finish(_ message: Incoming, _ snapshot: LightSnapshot, error: String? = nil) {
        let command = message.command
        // The presets changed: the watch's copy for when the iPhone is out of reach.
        switch command {
        case .savePreset, .deletePreset, .renamePreset, .updatePreset, .movePreset: updateContext()
        default: break
        }
        var response: [String: Any] = [:]
        if let data = try? JSONEncoder().encode(Self.stamped(snapshot)) { response[WatchKey.snapshot] = data }
        if case .deviceInfo = command, let model,
           let data = try? JSONEncoder().encode(model.deviceInfoEntries) {
            response[WatchKey.deviceInfo] = data
        }
        if let error { response[WatchKey.error] = error }
        message.reply(response)
    }
}
