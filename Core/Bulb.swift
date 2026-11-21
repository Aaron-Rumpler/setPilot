import Foundation
import Network

/// Control channel: JSON over UDP to the bulb's port 38899.
@MainActor
final class Bulb {
    private var conn: NWConnection?
    /// Replies seen per method; retry loops stop once this changes.
    private var replyCount: [String: Int] = [:]
    var onReply: (([String: Any]) -> Void)?
    /// Every request as sent (once, not each retry) and every message received, as text, for the log.
    var onSent: ((String, String) -> Void)?
    var onReceived: ((String) -> Void)?
    /// The failed request's method (nil for the connection itself) and a message to show.
    var onError: ((String?, String) -> Void)?
    /// The bulb's signing key (32 hex digits), for firmware that wants signed requests: when set,
    /// every request but raw ones is signed.
    var signingKey: String?

    /// The system refused the connection because Local Network access was denied.
    var localNetworkDenied: Bool {
        if #available(macOS 15.0, iOS 18.0, *) {
            return conn?.currentPath?.unsatisfiedReason == .localNetworkDenied
        }
        return false
    }

    func connect(to host: String) {
        conn?.cancel()
        conn = nil
        replyCount = [:]
        let host = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !host.isEmpty else { return }
        let c = NWConnection(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: Net.port)!, using: .udp)
        conn = c
        Bulb.receive(c) { [weak self] data, error in
            let text = data.map { String(decoding: $0, as: UTF8.self) }
            Task { @MainActor in
                guard let self, c === self.conn else { return }
                if let text { self.onReceived?(text) }
                if let obj = text.flatMap({ Net.json(Data($0.utf8)) }) {
                    if let method = obj["method"] as? String { self.replyCount[method, default: 0] += 1 }
                    self.onReply?(obj)
                }
                if let error { self.onError?(nil, "Lost the connection to the bulb (\(error))") }
            }
        }
        c.start(queue: DispatchQueue(label: "wiz.udp"))
    }

    /// `retry` mirrors pywizlight: resend up to 6 times (0.75 s doubling, capped at 3 s)
    /// until a reply with the same method arrives. Use it for one-off commands, not slider drags.
    /// `params` nil leaves the key out of the request altogether.
    func send(_ method: String, _ params: [String: Any]? = [:], retry: Bool = false) {
        guard let data = RequestSigning.message(method, params: params, key: signingKey) else { return }
        transmit(data, method: method, retry: retry)
    }

    /// Sends `text` exactly as given (the console's raw mode: it needn't even be valid JSON, and
    /// isn't signed).
    /// `method` names it for the log and errors; retrying needs one, as it stops on a reply with
    /// that method.
    func sendRaw(_ text: String, method: String?, retry: Bool) {
        transmit(Data(text.utf8), method: method, retry: retry && method != nil)
    }

    private func transmit(_ data: Data, method: String?, retry: Bool) {
        guard let conn else { return }
        let name = method ?? "Raw message"
        onSent?(method ?? "", String(decoding: data, as: UTF8.self))

        guard retry, let method else {
            conn.send(content: data, completion: .contentProcessed { [weak self] error in
                guard let error else { return }
                // "" for a raw message without a method: nil is the connection itself failing.
                Task { @MainActor in self?.onError?(method ?? "", "\(name): couldn't send (\(error))") }
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
        _ c: NWConnection, _ handler: @escaping @Sendable (Data?, NWError?) -> Void
    ) {
        c.receiveMessage { data, _, _, error in
            handler(data, error)
            if error == nil { Bulb.receive(c, handler) }
        }
    }
}

/// Listens on UDP 38900 for `syncPilot` pushes from bulbs we've registered with.
@MainActor
final class PushListener {
    enum Event { case message([String: Any], String), failed(String) }

    private var listener: NWListener?
    /// A push, parsed and as text.
    var onMessage: (([String: Any], String) -> Void)?
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
                    case let .message(obj, text): self.onMessage?(obj, text)
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
            if let data, let obj = Net.json(data) { handler(.message(obj, String(decoding: data, as: UTF8.self))) }
            if error == nil { PushListener.receive(c, handler) } else { c.cancel() }
        }
    }
}
