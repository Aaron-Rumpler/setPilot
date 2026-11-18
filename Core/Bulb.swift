import Foundation
import Network

/// Control channel: JSON over UDP to the bulb's port 38899.
@MainActor
final class Bulb {
    private var conn: NWConnection?
    /// Replies seen per method; retry loops stop once this changes.
    private var replyCount: [String: Int] = [:]
    var onReply: (([String: Any]) -> Void)?
    /// The failed request's method (nil for the connection itself) and a message to show.
    var onError: ((String?, String) -> Void)?

    func connect(to host: String) {
        conn?.cancel()
        conn = nil
        replyCount = [:]
        let host = host.trimmingCharacters(in: .whitespaces)
        guard !host.isEmpty else { return }
        let c = NWConnection(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: Net.port)!, using: .udp)
        conn = c
        Bulb.receive(c) { [weak self] obj, error in
            Task { @MainActor in
                guard let self, c === self.conn else { return }
                if let obj {
                    if let method = obj["method"] as? String { self.replyCount[method, default: 0] += 1 }
                    self.onReply?(obj)
                }
                if let error { self.onError?(nil, "Lost the connection (\(error)): choose the bulb again to reconnect") }
            }
        }
        c.start(queue: DispatchQueue(label: "wiz.udp"))
    }

    /// `retry` mirrors pywizlight: resend up to 6 times (0.75 s doubling, capped at 3 s)
    /// until a reply with the same method arrives. Use it for one-off commands, not slider drags.
    func send(_ method: String, _ params: [String: Any] = [:], retry: Bool = false) {
        guard let conn,
              let data = try? JSONSerialization.data(withJSONObject: ["method": method, "params": params])
        else { return }

        guard retry else {
            conn.send(content: data, completion: .contentProcessed { [weak self] error in
                guard let error else { return }
                Task { @MainActor in self?.onError?(method, "\(method): couldn't send (\(error))") }
            })
            return
        }

        let before = replyCount[method, default: 0]
        Task { [weak self] in
            var wait = 0.75
            for _ in 0..<6 {
                guard let self, self.conn === conn, self.replyCount[method, default: 0] == before else { return }
                conn.send(content: data, completion: .idempotent)
                try? await Task.sleep(for: .seconds(wait))
                wait = min(wait * 2, 3)
            }
            guard let self, self.conn === conn, self.replyCount[method, default: 0] == before else { return }
            self.onError?(method, "\(method): no reply after 6 tries")
        }
    }

    nonisolated private static func receive(
        _ c: NWConnection, _ handler: @escaping @Sendable ([String: Any]?, NWError?) -> Void
    ) {
        c.receiveMessage { data, _, _, error in
            handler(data.flatMap(Net.json), error)
            if error == nil { Bulb.receive(c, handler) }
        }
    }
}

/// Listens on UDP 38900 for `syncPilot` pushes from bulbs we've registered with.
@MainActor
final class PushListener {
    enum Event { case message([String: Any]), failed(String) }

    private var listener: NWListener?
    var onMessage: (([String: Any]) -> Void)?
    var onFailure: ((String) -> Void)?

    var isRunning: Bool { listener != nil }

    func startIfNeeded() {
        guard listener == nil else { return }
        do {
            let l = try NWListener(using: .udp, on: NWEndpoint.Port(rawValue: Net.pushPort)!)
            listener = l
            PushListener.run(l) { [weak self] event in
                Task { @MainActor in
                    guard let self else { return }
                    switch event {
                    case .message(let obj): self.onMessage?(obj)
                    case .failed(let reason):
                        self.listener = nil
                        self.onFailure?(reason)
                    }
                }
            }
        } catch {
            onFailure?("Can't listen on port \(Net.pushPort): \(error)")
        }
    }

    nonisolated private static func run(_ l: NWListener, _ handler: @escaping @Sendable (Event) -> Void) {
        let queue = DispatchQueue(label: "wiz.push")
        l.stateUpdateHandler = { state in
            if case .failed(let error) = state {
                handler(.failed("Can't listen on port \(Net.pushPort): \(error)"))
                l.cancel()
            }
        }
        l.newConnectionHandler = { conn in
            conn.start(queue: queue)
            PushListener.receive(conn, handler)
        }
        l.start(queue: queue)
    }

    nonisolated private static func receive(_ c: NWConnection, _ handler: @escaping @Sendable (Event) -> Void) {
        c.receiveMessage { data, _, _, error in
            if let data, let obj = Net.json(data) { handler(.message(obj)) }
            if error == nil { PushListener.receive(c, handler) } else { c.cancel() }
        }
    }
}
