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

    func start(model: Model) {
        guard self.model == nil else { return }
        self.model = model
        observeState()
        publishLibrary()
        guard WCSession.isSupported() else { return }
        WCSession.default.delegate = self
        WCSession.default.activate()
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
        case let .renamePreset(id, name):
            model.renamePreset(id, to: name)
            return model.snapshot
        case let .movePreset(id, offset):
            model.movePreset(id, by: offset)
            return model.snapshot
        case let .controlsFade(choice, ms):
            model.controlsFade = choice
            model.controlsFadeMs = min(max(ms, 0), 60_000)
            return model.snapshot
        case let .renameBulb(mac, name):
            model.rename(mac: mac, to: name)
            return model.snapshot
        case let .chooseBulb(address, mac):
            model.choose(address, mac: mac)
            _ = await model.waitUntilControllable(timeout: 4)
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
            // Answered once sent, not after the read-back: the watch sends the next live change
            // when this answers. Later state reaches it as the iPhone's usual updates.
            return model.snapshot
        case .dimDelta(let delta):
            model.adjustDimming(by: delta)
        case .playCustom(let id):
            if let scene = model.library.customScene(id) { model.playCustom(scene, switchOn: true) }
        case .compose(let change):
            model.send(change)
        case .useScale(let id):
            model.useScale(id)
        case .modeChoice(let choice):
            model.setModeChoice(choice)
        case .temperatureScale(let id):
            model.useTemperatureScale(id)
        case .updatePreset(let id):
            model.updatePreset(id)
        case .deviceInfo:
            model.readConfig()
            // The reads go out 60 ms apart; give the replies time to come in.
            try? await Task.sleep(for: .milliseconds(2500))
        case .state, .savePreset, .deletePreset, .chooseBulb, .renamePreset, .movePreset, .controlsFade, .renameBulb:
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
            publishState(snapshot)
            guard WCSession.isSupported() else { return }
            let session = WCSession.default
            guard session.activationState == .activated, session.isPaired, session.isWatchAppInstalled else { return }
            if session.isReachable, let data = try? JSONEncoder().encode(snapshot) {
                session.sendMessage([WatchKey.snapshot: data], replyHandler: nil, errorHandler: nil)
            }
        }
    }

    private var contextScheduled = false

    /// Presets or custom scenes changed: pass them on to the watch (and Siri), at most twice a second.
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
            // Woken for this, perhaps from the background: commands for the bulb get live updates
            // going again (and the state read again if the app was suspended) through
            // waitUntilControllable, so changes from elsewhere reach the watch while it's awake.
            let snapshot = await self.run(command)
            // The presets changed: the watch's copy for when the iPhone is out of reach.
            switch command {
            case .savePreset, .deletePreset, .renamePreset, .updatePreset, .movePreset: self.updateContext()
            default: break
            }
            var response: [String: Any] = [:]
            if let data = try? JSONEncoder().encode(snapshot) { response[WatchKey.snapshot] = data }
            if case .deviceInfo = command, let model = self.model,
               let data = try? JSONEncoder().encode(model.deviceInfoEntries) {
                response[WatchKey.deviceInfo] = data
            }
            reply.value(response)
        }
    }
}

/// WatchConnectivity's reply handler isn't marked Sendable, but may be called from any thread.
struct UncheckedSendable<T>: @unchecked Sendable {
    let value: T
    init(_ value: T) { self.value = value }
}
