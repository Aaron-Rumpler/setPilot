import Foundation
import Observation
import WatchConnectivity

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
        /// When it was asked for: sent from the watch (as the watch's clock says, if that's
        /// sensible), else when it arrived. Waits are counted from then.
        let asked: Date
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
        WidgetPublisher.shared.start(model: model) // the widgets and controls (Core/WidgetPublisher.swift)
        // A preset applied here: the watch's Smart Stack learns when (Common/PresetUsage.swift).
        NotificationCenter.default.addObserver(forName: PresetUsage.recorded, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated {
                PhoneRelay.shared.libraryChanged()
                QuickActions.update(Shared.model.library) // most used first
            }
        }
        guard WCSession.isSupported() else { return }
        WCSession.default.delegate = self
        WCSession.default.activate()
    }

    // MARK: Commands

    /// What's left once a command has run: reply now, or after a pause and the bulb's read-back.
    private enum Outcome {
        case now(LightSnapshot)
        case settle(after: Duration)
        /// Not done, and why (the reply says so).
        case failed(LightSnapshot, String)
        /// Run by the shared runner (Core/Commands.swift): done, or its error (with its kind).
        case scripted(ScriptResult)
    }

    /// The watch's light commands as the shared runner's, so they're done only once the bulb has
    /// read them back, and fail with the same reasons as Shortcuts, links and the CLI. The rest
    /// (the state, presets' editing, live slider changes, Compose, device info) have no runner
    /// command: the state is answered with what's known, not an error, when the bulb's away.
    private static func scripted(_ command: WatchCommand) -> (ScriptCommand, Int?)? {
        switch command {
        case .power(let on): (.power(on), nil)
        case .togglePower: (.power(nil), nil)
        case .applyPreset(let id): (.preset(id.uuidString), nil)
        case .dimDelta(let delta): (.adjustBrightness(delta), nil)
        case let .playCustom(id, switchOn): (.customScene(id.uuidString, power: switchOn ? true : nil), nil)
        case let .script(data, fade): (try? JSONDecoder().decode(ScriptCommand.self, from: data)).map { ($0, fade) }
        default: nil
        }
    }

    /// Whether a command plays a custom scene that flashes quickly (at the speed it would play):
    /// from the app, its Siri and Shortcuts actions, and Compose alike.
    private static func flashes(_ command: WatchCommand, _ model: Model) -> Bool {
        switch command {
        case .compose(let change):
            return model.flashes(change.colour)
        case .script(let data, _):
            guard let scripted = try? JSONDecoder().decode(ScriptCommand.self, from: data) else { return false }
            return Scripting.flashingScene(scripted, model) != nil
        default:
            guard let (runnerCommand, _) = Self.scripted(command) else { return false }
            return Scripting.flashingScene(runnerCommand, model) != nil
        }
    }

    /// The change number before the command in hand sent its change (set once the bulb's ready).
    private var sentFrom: Int?
    private static let notAnswering = "The bulb isn't answering. Check it's powered and on the same network as your iPhone."

    /// The bulb can take a command now. As everywhere (Model.waitUntilControllable): waits as long
    /// as the bulb's own retries, and not at all if it's just been found not answering (a burst of
    /// taps during an outage is answered at once, not queued to land late). Woken from a
    /// suspension, it re-registers for pushes and reads the state again if it's gone quiet, so a
    /// toggle doesn't go by a state from before.
    /// `asked`: a change's, whose wait is what's left of the one timeout from then.
    private func bulbReady(_ model: Model, asked: Date? = nil) async -> Bool {
        let left = asked.map { Model.answerTimeout - Date.now.timeIntervalSince($0) } ?? Model.answerTimeout
        return await model.waitUntilControllable(timeout: max(left, 0))
    }

    /// Runs a command as far as sending it. Waiting for the bulb to settle is left to the caller,
    /// apart from the queue: only the sending needs to keep the order, and the next command
    /// shouldn't wait out this one's read-back.
    private func run(_ command: WatchCommand, asked: Date) async -> Outcome {
        guard let model else { return .now(LightSnapshot()) }
        // A scene that flashes quickly is asked about before it plays, which the watch can't do:
        // started on the iPhone instead (not queued there to start later, unasked-for).
        if Flashing.asks, Self.flashes(command, model) {
            return .failed(model.snapshot, "This flashes quickly. Start it on your iPhone, which asks first.")
        }
        if let (scripted, fade) = Self.scripted(command) {
            // The runner waits for the bulb as everything does (failing at once just after it's
            // been found not answering; not for switching bulbs or listing, which don't need it).
            return .scripted(await Scripting.run(scripted, fade: fade, asked: asked, on: model))
        }
        if case .script = command {
            return .failed(model.snapshot, "setPilot on your iPhone didn't understand that; update both apps")
        }
        switch command {
        case .state:
            _ = await bulbReady(model)
            return .now(model.snapshot)
        case .savePreset(let name):
            // The light as it is: not saved from a state that may be out of date.
            guard await bulbReady(model) else { return .failed(model.snapshot, Self.notAnswering) }
            // Not every light can be a preset (Rhythm, say): the status says why.
            guard model.savePreset(named: name) != nil else { return .failed(model.snapshot, model.status) }
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
        case let .favourite(id, on):
            model.setFavourite(id, on)
            return .now(model.snapshot)
        case let .controlsFade(choice, ms):
            model.controlsFade = choice
            // The time only with Custom: another choice mustn't send back an old one.
            if choice == .custom { model.controlsFadeMs = min(max(ms, 0), Fade.maximum) }
            return .now(model.snapshot)
        case let .renameBulb(mac, name):
            model.rename(mac: mac, to: name)
            return .now(model.snapshot)
        case let .chooseBulb(address, mac):
            model.choose(address, mac: mac)
            _ = await bulbReady(model)
            return .now(model.snapshot)
        default:
            break
        }
        let left = Model.answerTimeout - Date.now.timeIntervalSince(asked)
        let waitStarted = Date.now
        guard await bulbReady(model, asked: asked) else {
            // Why, as Shortcuts say it (a refusal, too late, or not answering), with its kind.
            return .scripted(ScriptResult(state: Scripting.state(of: model), error: Scripting.notReady(model, left: left, waitStarted: waitStarted)))
        }
        sentFrom = model.ticket // after the wait: a change made meanwhile (a Shortcut) isn't this one's
        var pause = Duration.zero
        switch command {
        case .sync:
            model.sync()
            pause = .milliseconds(500)
        case .set(let values, let fields):
            model.apply(values, fields: fields)
            // Answered once sent, not after the read-back: the watch sends the next live change
            // when this answers. Later state reaches it as the iPhone's usual updates.
            return .now(model.snapshot)
        case .compose(let change):
            guard model.send(change) else { return .failed(model.snapshot, model.refusal ?? model.status) }
        case .modeChoice(let choice):
            model.setModeChoice(choice)
        case .temperatureScale(let id):
            model.useTemperatureScale(id)
        case .updatePreset(let id):
            guard model.library.presets.contains(where: { $0.id == id }) else {
                return .failed(model.snapshot, "That preset no longer exists.")
            }
            guard model.currentColour != nil else {
                return .failed(model.snapshot, "This light can't be saved in a preset (a Rhythm scene, say).")
            }
            model.updatePreset(id)
        case .deviceInfo:
            model.readConfig()
            // The reads go out 60 ms apart; give the replies time to come in.
            pause = .milliseconds(2500)
        case .state, .savePreset, .deletePreset, .chooseBulb, .renamePreset, .movePreset, .favourite, .controlsFade, .renameBulb, .script,
             .power, .togglePower, .applyPreset, .dimDelta, .playCustom:
            break // the runner's (above), or answered without waiting
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
            WidgetPublisher.shared.publishLibrary() // already at most twice a second, here
            updateContext()
            // A setting the state carries (snapping, the fades; not observed) to a watch that's here now.
            lastSnapshot = nil
            schedulePush()
            SetPilotShortcuts.updateAppShortcutParameters() // so Siri knows the preset names
        }
    }

    /// The application context holds what the watch should show even when the iPhone isn't
    /// reachable: the presets, custom scene names and the last known state.
    private func updateContext() {
        guard let model, WCSession.isSupported() else { return }
        let session = WCSession.default
        guard session.activationState == .activated, session.isPaired, session.isWatchAppInstalled else { return }
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys // the watch compares the bytes: unchanged must match
        var context: [String: Any] = [:]
        if let data = try? encoder.encode(model.library.presets) { context[WatchKey.presets] = data }
        if let data = try? encoder.encode(model.library.summaries) { context[WatchKey.customScenes] = data }
        if let data = UserDefaults.standard.data(forKey: PresetUsage.key) { context[WatchKey.presetUsage] = data }
        // Only a state worth keeping: "connecting" or "no bulb" would replace the watch's last good one.
        if model.snapshot.link == .connected, let data = try? encoder.encode(Self.stamped(model.snapshot)) {
            context[WatchKey.snapshot] = data
        } else if let kept = session.applicationContext[WatchKey.snapshot] as? Data,
                  var s = try? JSONDecoder().decode(LightSnapshot.self, from: kept) {
            // The last good state, with the settings it carries as they are now (snapping, the
            // fades), so a change to them reaches the watch while the bulb's away too.
            let now = model.snapshot
            (s.fade, s.controlsFade, s.controlsFadeMs, s.snapSliders) = (now.fade, now.controlsFade, now.controlsFadeMs, now.snapSliders)
            context[WatchKey.snapshot] = (try? encoder.encode(s)) ?? kept
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
        let arrived = Date.now
        // The watch's time (a tap that's waited is counted from the tap, and refused if that's too
        // long ago), unless its clock looks off: ahead (allowing a moment), or implausibly far behind
        // (the watch drops a waiting tap once its time is up, by its own clock, so one that old
        // means the clocks differ).
        let sent = (message[WatchKey.sentAt] as? Double).map(Date.init(timeIntervalSince1970:))
        let asked = sent.flatMap { $0 <= arrived.addingTimeInterval(1) && arrived.timeIntervalSince($0) < 60 ? min($0, arrived) : nil } ?? arrived
        incomingQueue.yield(Incoming(command: command, reply: replyHandler, asked: asked))
    }

    private func handle(_ message: Incoming) async {
        // Woken for this, perhaps from the background: commands for the bulb get live updates
        // going again (and the state read again if the app was suspended) through
        // waitUntilControllable, so changes from elsewhere reach the watch while it's awake.
        let sends = switch message.command {
        case .applyPreset, .playCustom, .compose, .power, .togglePower, .dimDelta, .modeChoice, .temperatureScale: true
        // A script's own say: reading the state and switching bulbs aren't changes to this bulb.
        case .script: Self.scripted(message.command)?.0.changes ?? false // not understood: not sent
        default: false
        }
        // A change asked for longer ago than anything waits for the bulb (it waited its turn
        // here behind others, or the message was slow): not sent, as it would land late.
        let changes: Bool = { if case .set = message.command { return true }; return sends }()
        if changes, Date.now.timeIntervalSince(message.asked) > Model.answerTimeout {
            finish(message, model?.snapshot ?? LightSnapshot(), error: "That came too late to send (the bulb was busy or not answering); try again.",
                   code: ScriptError.Code.notAnswering.rawValue)
            return
        }
        // Not the runner's (it keeps its own): a reason from before isn't this one's.
        if sends, Self.scripted(message.command) == nil { model?.forgetRefusal() }
        sentFrom = nil
        let outcome = await run(message.command, asked: message.asked)
        // The change this sent, if it sent one (its result is its own, whatever follows).
        let ticket = model.flatMap { m in sentFrom.flatMap { m.ticket != $0 ? m.ticket : nil } }
        switch outcome {
        case .now(let snapshot):
            finish(message, snapshot)
        case let .failed(snapshot, why):
            finish(message, snapshot, error: why)
        case .scripted(let result):
            finish(message, model?.snapshot ?? LightSnapshot(), error: result.error?.message, code: result.error?.code.rawValue)
        case .settle(let pause):
            Task {
                try? await Task.sleep(for: pause)
                // A change waits on its own result below; anything else, for things to settle.
                if ticket == nil, !sends { await model?.waitUntilSettled() } // a change that sent nothing: done now
                // What became of the change it sent, as Shortcuts say it: refused, not answered,
                // not applied, or not known (another change went before it was answered).
                var why: String?
                if sends, let model, let ticket {
                    switch await model.result(of: ticket) {
                    case .done: break
                    case .notApplied(let m), .refused(let m), .notAnswered(let m), .notKnown(let m): why = m
                    }
                }
                finish(message, model?.snapshot ?? LightSnapshot(), error: why)
            }
        }
    }

    private func finish(_ message: Incoming, _ snapshot: LightSnapshot, error: String? = nil, code: String? = nil) {
        let command = message.command
        // The presets changed: the watch's copy for when the iPhone is out of reach.
        switch command {
        case .savePreset, .deletePreset, .renamePreset, .updatePreset, .movePreset, .favourite: updateContext()
        default: break
        }
        var response: [String: Any] = [:]
        if let data = try? JSONEncoder().encode(Self.stamped(snapshot)) { response[WatchKey.snapshot] = data }
        if case .deviceInfo = command, let model,
           let data = try? JSONEncoder().encode(model.deviceInfoEntries) {
            response[WatchKey.deviceInfo] = data
        }
        if let error { response[WatchKey.error] = error }
        if let code { response[WatchKey.errorCode] = code }
        message.reply(response)
    }
}
