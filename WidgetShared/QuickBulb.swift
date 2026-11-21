import Foundation
import Network

/// Sends one request to the bulb and waits for its reply, for widget actions that run outside
/// the app. Uses the address and ready-made preset requests the app left in the App Group.
enum QuickBulb {
    static func perform(_ command: WidgetCommand) async throws {
        guard let host = SharedStore.defaults.string(forKey: SharedStore.addressKey), !host.isEmpty else {
            throw WidgetError(localizedStringResource: "Choose a bulb in setPilot first.")
        }
        var isOn = SharedStore.snapshot?.isOn
        // Not known (the app was left connecting): read it, rather than guess at a toggle, or switch
        // the bulb on with a dimDelta that has no "state".
        let needsPower = switch command {
        case .power(.none), .dimDelta: true
        default: false
        }
        if isOn == nil, needsPower {
            let reply = try await send(host, "getPilot", [:])
            isOn = (reply["result"] as? [String: Any])?["state"] as? Bool
            guard isOn != nil else { throw WidgetError(localizedStringResource: "Couldn't read whether the bulb is on.") }
        }
        switch command {
        case .applyPreset(let id):
            let all = SharedStore.defaults.dictionary(forKey: SharedStore.presetParamsKey) as? [String: Data] ?? [:]
            guard let data = all[id.uuidString],
                  let params = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw WidgetError(localizedStringResource: "Open setPilot once to update its presets.")
            }
            _ = try await send(host, "setPilot", params) // no "state": switches the bulb on
            remember { s in
                s.isOn = true
                if let d = (params["dimming"] as? NSNumber)?.doubleValue { s.dimming = d }
            }
        case .power(let on):
            let on = on ?? !(isOn ?? false)
            // As the app: setPilot with the controls' fade (setState has none).
            var params: [String: Any] = ["state": on]
            if let trans = SharedStore.defaults.object(forKey: SharedStore.controlsTransKey) as? Int { params["trans"] = trans }
            _ = try await send(host, "setPilot", params)
            remember { $0.isOn = on }
        case .dimDelta(let delta):
            var params: [String: Any] = ["dimDelta": delta]
            // As the app: the controls' fade, and the bulb kept off if it's off.
            if let trans = SharedStore.defaults.object(forKey: SharedStore.controlsTransKey) as? Int { params["trans"] = trans }
            if isOn == false { params["state"] = false }
            _ = try await send(host, "setPilot", params)
            remember { $0.dimming = min(max($0.dimming + Double(delta), $0.minDimming), 100) }
        }
    }

    /// What was just sent, in the state the widgets and controls show (the app isn't running to
    /// update it), so they don't snap back when reloaded and the next tap starts from it.
    private static func remember(_ change: (inout LightSnapshot) -> Void) {
        guard var s = SharedStore.snapshot else { return }
        change(&s)
        SharedStore.save(s, SharedStore.snapshotKey)
    }

    /// Up to three tries, a second each.
    static func send(_ host: String, _ method: String, _ params: [String: Any]) async throws -> [String: Any] {
        let key = SharedStore.defaults.string(forKey: SharedStore.signingKeyKey)
        for _ in 0..<3 {
            // Signed afresh for each try: its own sigTs, in case the bulb refuses a repeat.
            guard let data = RequestSigning.message(method, params: params, key: key) else {
                throw WidgetError(localizedStringResource: "Couldn't make the request.")
            }
            guard let reply = await attempt(host, data) else { continue }
            // An answer, but a refusal (a parameter this firmware doesn't take, say): no use retrying.
            if let error = reply["error"] as? [String: Any] {
                let message = error["message"] as? String ?? (error["code"] as? Int).map { "error \($0)" } ?? "an error"
                throw WidgetError(localizedStringResource: "The bulb refused \(method): \(message)")
            }
            return reply
        }
        throw WidgetError(localizedStringResource: "The bulb didn't answer.")
    }

    private static func attempt(_ host: String, _ data: Data) async -> [String: Any]? {
        let conn = NWConnection(host: NWEndpoint.Host(host), port: 38899, using: .udp)
        let box = ReplyBox()
        return await withCheckedContinuation { (cont: CheckedContinuation<[String: Any]?, Never>) in
            box.set(cont)
            conn.start(queue: .global())
            conn.send(content: data, completion: .idempotent)
            conn.receiveMessage { reply, _, _, _ in
                let obj = reply.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
                box.finish(obj)
                conn.cancel()
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + 1) {
                box.finish(nil)
                conn.cancel()
            }
        }
    }
}

/// Resumes a continuation once, from whichever of the reply and the timeout comes first.
private final class ReplyBox: @unchecked Sendable {
    private let lock = NSLock()
    private var cont: CheckedContinuation<[String: Any]?, Never>?

    func set(_ c: CheckedContinuation<[String: Any]?, Never>) {
        lock.lock(); cont = c; lock.unlock()
    }

    func finish(_ value: [String: Any]?) {
        lock.lock()
        let c = cont
        cont = nil
        lock.unlock()
        c?.resume(returning: value)
    }
}
