import Foundation
import WatchConnectivity

/// The watch end of the link: sends commands to setPilot on the iPhone, which talks to the bulb,
/// and keeps the iPhone's presets, custom scene names and state (cached for when it's out of reach).
@MainActor @Observable
final class PhoneLink: NSObject {
    static let shared = PhoneLink()

    private(set) var snapshot: LightSnapshot?
    private(set) var presets: [Preset] = []
    private(set) var scenes: [CustomSceneSummary] = []
    private(set) var reachable = false
    /// A command is waiting for the iPhone's reply.
    private(set) var busy = false
    var error: String?

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

    /// Sends a command; the reply updates `snapshot`. Errors show in `error`.
    func send(_ command: WatchCommand) {
        let session = WCSession.default
        guard session.activationState == .activated, session.isReachable else {
            error = "Can't reach your iPhone. Keep it nearby, with Bluetooth or Wi-Fi on."
            return
        }
        guard let data = try? JSONEncoder().encode(command) else { return }
        busy = true
        error = nil
        session.sendMessage([WatchKey.command: data], replyHandler: { reply in
            let snapshot = (reply[WatchKey.snapshot] as? Data).flatMap { try? JSONDecoder().decode(LightSnapshot.self, from: $0) }
            let message = reply[WatchKey.error] as? String
            Task { @MainActor in
                self.busy = false
                if let snapshot { self.apply(snapshot) }
                if let message { self.error = message }
            }
        }, errorHandler: { error in
            let text = error.localizedDescription
            Task { @MainActor in
                self.busy = false
                self.error = "Your iPhone didn't answer: \(text)"
            }
        })
    }

    /// Asks for the bulb's state, quietly: no error if the iPhone is out of reach.
    func refresh() {
        guard WCSession.default.activationState == .activated, WCSession.default.isReachable else { return }
        send(.state)
    }

    private func apply(_ s: LightSnapshot) {
        snapshot = s
        if let data = try? JSONEncoder().encode(s) { defaults.set(data, forKey: WatchKey.snapshot) }
    }

    private func applyContext(_ context: [String: Any]) {
        let decoder = JSONDecoder()
        if let d = context[WatchKey.presets] as? Data, let p = try? decoder.decode([Preset].self, from: d) {
            presets = p
            defaults.set(d, forKey: WatchKey.presets)
        }
        if let d = context[WatchKey.customScenes] as? Data, let s = try? decoder.decode([CustomSceneSummary].self, from: d) {
            scenes = s
            defaults.set(d, forKey: WatchKey.customScenes)
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
            if reachable { self.refresh() }
        }
    }

    nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
        let reachable = session.isReachable
        Task { @MainActor in
            self.reachable = reachable
            if reachable {
                self.error = nil
                self.refresh()
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
