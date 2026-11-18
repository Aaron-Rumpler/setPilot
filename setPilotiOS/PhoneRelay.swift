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

    func start(model: Model) {
        guard self.model == nil, WCSession.isSupported() else { return }
        self.model = model
        WCSession.default.delegate = self
        WCSession.default.activate()
        observeState()
    }

    // MARK: Commands

    private func run(_ command: WatchCommand) async -> LightSnapshot {
        guard let model else { return LightSnapshot() }
        switch command {
        case .state:
            _ = await model.waitUntilControllable(timeout: 3)
            return model.snapshot
        case .savePreset(let name):
            _ = await model.waitUntilControllable(timeout: 3)
            model.savePreset(named: name)
            return model.snapshot
        case .deletePreset(let id):
            model.library.presets.removeAll { $0.id == id }
            return model.snapshot
        default:
            break
        }
        guard await model.waitUntilControllable() else { return model.snapshot }
        switch command {
        case .sync:
            model.sync()
            try? await Task.sleep(for: .milliseconds(500))
        case .power(let on):
            model.power(on)
            try? await Task.sleep(for: .milliseconds(400))
        case .applyPreset(let id):
            if let preset = model.library.presets.first(where: { $0.id == id }) { model.apply(preset) }
        case .set(let values, let fields):
            model.apply(values, fields: fields)
        case .dimDelta(let delta):
            model.adjustDimming(by: delta)
        case .playCustom(let id):
            if let scene = model.library.customScene(id) { model.playCustom(scene, switchOn: true) }
        case .state, .savePreset, .deletePreset:
            break
        }
        await model.waitUntilSettled()
        return model.snapshot
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
            let session = WCSession.default
            guard session.activationState == .activated, session.isPaired, session.isWatchAppInstalled else { return }
            if session.isReachable, let data = try? JSONEncoder().encode(snapshot) {
                session.sendMessage([WatchKey.snapshot: data], replyHandler: nil, errorHandler: nil)
            }
        }
    }

    private var contextScheduled = false

    /// Presets or custom scenes changed: pass them on.
    func libraryChanged() {
        guard !contextScheduled else { return }
        contextScheduled = true
        Task {
            try? await Task.sleep(for: .milliseconds(500))
            contextScheduled = false
            updateContext()
        }
    }

    /// The application context holds what the watch should show even when the iPhone isn't
    /// reachable: the presets, custom scene names and the last known state.
    private func updateContext() {
        guard let model else { return }
        let session = WCSession.default
        guard session.activationState == .activated, session.isPaired, session.isWatchAppInstalled else { return }
        let encoder = JSONEncoder()
        var context: [String: Any] = [:]
        if let data = try? encoder.encode(model.library.presets) { context[WatchKey.presets] = data }
        if let data = try? encoder.encode(model.library.summaries) { context[WatchKey.customScenes] = data }
        if let data = try? encoder.encode(model.snapshot) { context[WatchKey.snapshot] = data }
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
        let reply = UncheckedSendable(replyHandler)
        Task { @MainActor in
            let snapshot = await self.run(command)
            if case .savePreset = command { self.updateContext() }
            if case .deletePreset = command { self.updateContext() }
            var response: [String: Any] = [:]
            if let data = try? JSONEncoder().encode(snapshot) { response[WatchKey.snapshot] = data }
            reply.value(response)
        }
    }
}

/// WatchConnectivity's reply handler isn't marked Sendable, but may be called from any thread.
struct UncheckedSendable<T>: @unchecked Sendable {
    let value: T
    init(_ value: T) { self.value = value }
}
