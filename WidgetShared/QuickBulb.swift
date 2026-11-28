import Foundation
import Network

/// Sends one request to the bulb and waits for its reply, for widget actions that run outside
/// the app. Uses the address and ready-made preset requests the app left in the App Group.
enum QuickBulb {
    static func perform(_ command: WidgetCommand) async throws {
        guard let host = SharedStore.defaults.string(forKey: SharedStore.addressKey), !host.isEmpty else {
            throw WidgetError(localizedStringResource: "Choose a bulb in setPilot first.")
        }
        // One timeout for the whole tap, reading included (as anything waits): a change that went
        // out later would land late.
        let deadline = Date.now.addingTimeInterval(BulbTiming.answerTimeout)
        var isOn = SharedStore.snapshot?.isOn
        var level = SharedStore.snapshot?.dimming
        // Read it, rather than trust the app's last state (it may have been switched since, from
        // the WiZ app say, while this app was suspended) or guess at a toggle: a dimDelta with the
        // wrong "state" switches the bulb.
        let needsPower = switch command {
        case .power(.none), .dimDelta: true
        default: false
        }
        if needsPower {
            let reply = try await send(host, "getPilot", [:], by: deadline)
            let result = reply["result"] as? [String: Any]
            isOn = result?["state"] as? Bool
            if let d = (result?["dimming"] as? NSNumber)?.doubleValue { level = d }
            guard isOn != nil else { throw WidgetError(localizedStringResource: "Couldn't read whether the bulb is on.") }
        }
        switch command {
        case .applyPreset(let id):
            if (SharedStore.defaults.stringArray(forKey: SharedStore.flashingPresetsKey) ?? []).contains(id.uuidString) {
                let name = SharedStore.presets.first { $0.id == id }?.name ?? "That preset"
                throw WidgetError(localizedStringResource: "\(BulbReasons.flashes(name))")
            }
            let all = SharedStore.defaults.dictionary(forKey: SharedStore.presetParamsKey) as? [String: Data] ?? [:]
            guard let data = all[id.uuidString],
                  let params = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                // Known, but with nothing to send: its custom scene or CCT scale has gone.
                if SharedStore.presets.contains(where: { $0.id == id }) {
                    throw WidgetError(localizedStringResource: "\(BulbReasons.presetPartGone)")
                }
                throw WidgetError(localizedStringResource: "\(BulbReasons.presetGone)")
            }
            _ = try await send(host, "setPilot", params, by: deadline) // no "state": switches the bulb on
            remember { s in
                s.isOn = true
                if let d = (params["dimming"] as? NSNumber)?.doubleValue { s.dimming = d }
            }
        case .power(let on):
            let on = on ?? !(isOn ?? false)
            // As the app: setPilot with the controls' fade (setState has none).
            var params: [String: Any] = ["state": on]
            if let trans = SharedStore.defaults.object(forKey: SharedStore.controlsTransKey) as? Int { params["trans"] = trans }
            _ = try await send(host, "setPilot", params, by: deadline)
            remember { $0.isOn = on }
        case .dimDelta(let delta):
            // The new level, worked out from the one just read, not dimDelta: a retry would add the
            // step again. As the app: the controls' fade, and the bulb kept off if it's off.
            let floor = SharedStore.snapshot?.minDimming ?? 10
            let target = min(max((level ?? 100) + Double(delta), floor), 100)
            var params: [String: Any] = ["dimming": Int(target)]
            if let trans = SharedStore.defaults.object(forKey: SharedStore.controlsTransKey) as? Int { params["trans"] = trans }
            if isOn == false { params["state"] = false }
            _ = try await send(host, "setPilot", params, by: deadline)
            remember { s in
                s.dimming = target
                s.isOn = isOn // just read (the app may have left it unknown, quitting)
            }
        }
    }

    /// What was just sent, in the state the widgets and controls show (the app isn't running to
    /// update it), so they don't snap back when reloaded and the next tap starts from it.
    private static func remember(_ change: (inout LightSnapshot) -> Void) {
        guard var s = SharedStore.snapshot else { return }
        s.link = .connected // it's just answered
        s.heardAt = .now
        change(&s)
        SharedStore.save(s, SharedStore.snapshotKey)
    }

    /// Tried as the app tries (BulbTiming), up to `deadline`: nothing goes out after it. One
    /// connection for all the tries, so a reply to any of them counts, until the deadline.
    static func send(_ host: String, _ method: String, _ params: [String: Any], by deadline: Date) async throws -> [String: Any] {
        let key = SigningKeyStore.get(SigningKeyStore.current)
        let conn = NWConnection(host: NWEndpoint.Host(host), port: 38899, using: .udp)
        let inbox = ReplyInbox()
        conn.start(queue: .global())
        receive(conn, into: inbox)
        defer { conn.cancel() }
        func answered() throws -> [String: Any]? {
            guard let reply = inbox.reply else { return nil }
            // An answer, but a refusal (a parameter this firmware doesn't take, say): no use retrying.
            if let error = reply["error"] as? [String: Any] {
                let message = error["message"] as? String ?? (error["code"] as? Int).map { "error \($0)" } ?? "an error"
                throw WidgetError(localizedStringResource: "The bulb refused \(method): \(message)")
            }
            return reply
        }
        var sent = false
        for planned in BulbTiming.tryWaits {
            try Task.checkCancellation() // the action's ended: nothing more goes
            let left = deadline.timeIntervalSinceNow
            // The first try only with time for its answer too (what the last try is given): one
            // applied with its reply just too late would be reported as not answered.
            guard left > (sent ? 0.05 : BulbTiming.answerTimeout - BulbTiming.replyWindow) else { break }
            // Signed afresh for each try: its own sigTs, in case the bulb refuses a repeat.
            guard let data = RequestSigning.message(method, params: params, key: key) else {
                throw WidgetError(localizedStringResource: "Couldn't make the request.")
            }
            conn.send(content: data, completion: .idempotent)
            sent = true
            let until = Date.now.addingTimeInterval(min(planned, left))
            while Date.now < until {
                if let reply = try answered() { return reply }
                try await Task.sleep(for: .milliseconds(50)) // throws if the action's cancelled
            }
        }
        // Nothing went: the read before it took all the time there was.
        guard sent else { throw WidgetError(localizedStringResource: "That came too late to send (reading the bulb took all the time there was); try again.") }
        // The last try's answer, if it comes before the deadline.
        while Date.now < deadline {
            if let reply = try answered() { return reply }
            try await Task.sleep(for: .milliseconds(50))
        }
        if let reply = try answered() { return reply }
        throw WidgetError(localizedStringResource: "\(BulbReasons.notAnswering)")
    }

    private static func receive(_ conn: NWConnection, into inbox: ReplyInbox) {
        conn.receiveMessage { data, _, _, error in
            if let obj = data.flatMap({ try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }) { inbox.take(obj) }
            if error == nil { receive(conn, into: inbox) }
        }
    }
}

/// The first reply on a request's connection, from whichever try it answers.
private final class ReplyInbox: @unchecked Sendable {
    private let lock = NSLock()
    private var first: [String: Any]?

    var reply: [String: Any]? {
        lock.lock(); defer { lock.unlock() }
        return first
    }

    func take(_ value: [String: Any]) {
        lock.lock()
        if first == nil { first = value }
        lock.unlock()
    }
}
