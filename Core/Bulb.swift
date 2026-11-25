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
    /// The connection is ready again after waiting (Local Network access allowed, the network
    /// back): what was sent meanwhile may not have gone.
    var onReady: (() -> Void)?
    /// The bulb's signing key (32 hex digits), for firmware that wants signed requests: when set,
    /// every request but raw ones is signed.
    var signingKey: String?

    /// The system refused the connection because Local Network access was denied.
    var localNetworkDenied: Bool {
        conn?.currentPath?.unsatisfiedReason == .localNetworkDenied
    }

    /// The current connection has been left waiting (so becoming ready is news).
    private var waited = false

    func connect(to host: String) {
        conn?.cancel()
        conn = nil
        replyCount = [:]
        waited = false
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
        // Failed, or left waiting (no route: the network changed or went away, Local Network
        // access off): this connection won't come back by itself, so the model makes another.
        c.stateUpdateHandler = { [weak self] state in
            let lost: String? = switch state {
            case .failed(let error): "Lost the connection to the bulb (\(error))"
            case .waiting(let error): "No way to reach the bulb right now (\(error))"
            default: nil
            }
            let ready: Bool = { if case .ready = state { return true }; return false }()
            let waiting: Bool = { if case .waiting = state { return true }; return false }()
            Task { @MainActor in
                guard let self, c === self.conn else { return }
                if let lost {
                    if waiting { self.waited = true }
                    self.onError?(nil, lost)
                } else if ready, self.waited {
                    self.waited = false
                    self.onReady?()
                }
            }
        }
        c.start(queue: DispatchQueue(label: "wiz.udp"))
    }

    /// `retry` sends up to 5 times (0.4 s apart, doubling, capped at 1.5 s; the last at about 4 s)
    /// until a reply with the same method arrives. Use it for one-off commands, not slider drags.
    /// `params` nil leaves the key out of the request altogether.
    func send(_ method: String, _ params: [String: Any]? = [:], retry: Bool = false) {
        let key = signingKey
        // Signed afresh for each try: a retry gets its own sigTs, in case the bulb refuses a repeat.
        transmit(method: method, retry: retry) { RequestSigning.message(method, params: params, key: key) }
    }

    /// Sends `text` exactly as given (the console's raw mode: it needn't even be valid JSON, and
    /// isn't signed).
    /// `method` names it for the log and errors; retrying needs one, as it stops on a reply with
    /// that method.
    func sendRaw(_ text: String, method: String?, retry: Bool) {
        let data = Data(text.utf8)
        transmit(method: method, retry: retry && method != nil) { data }
    }

    /// `message` makes the bytes to send, for each try (the log shows the first).
    private func transmit(method: String?, retry: Bool, message: @escaping () -> Data?) {
        guard let conn, let data = message() else { return }
        let name = method ?? "Raw message"
        onSent?(method ?? "", String(decoding: data, as: UTF8.self))

        guard retry, let method else {
            conn.send(content: data, completion: .contentProcessed { [weak self] error in
                guard let error else { return }
                // "" for a raw message without a method: nil is the connection itself failing.
                // Not for a connection since replaced (its queued sends are cancelled with it).
                Task { @MainActor in
                    guard let self, self.conn === conn else { return }
                    self.onError?(method ?? "", "\(name): couldn't send (\(error))")
                }
            })
            return
        }

        let before = replyCount[method, default: 0]
        Task { [weak self] in
            var wait = 0.4
            for attempt in 0..<5 {
                guard let self, self.conn === conn, self.replyCount[method, default: 0] == before else { return }
                guard let bytes = attempt == 0 ? data : message() else { return }
                conn.send(content: bytes, completion: .idempotent)
                try? await Task.sleep(for: .seconds(wait))
                wait = min(wait * 2, 1.5)
            }
            guard let self, self.conn === conn, self.replyCount[method, default: 0] == before else { return }
            self.onError?(method, "\(method): no reply after 5 tries")
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

/// Says when the network changes (another network, a VPN coming or going, back from sleep), so
/// the bulb's connection can be made afresh.
@MainActor
final class NetworkWatcher {
    private let monitor = NWPathMonitor()
    private var last: String?
    var onChange: (() -> Void)?

    func start() {
        monitor.pathUpdateHandler = { [weak self] path in
            let usable = path.status == .satisfied
            let key = "\(usable) " + path.availableInterfaces.map(\.name).joined(separator: ",")
            Task { @MainActor in
                guard let self else { return }
                let changed = self.last != nil && self.last != key
                self.last = key // the first is how it is at launch: nothing to redo
                if changed, usable { self.onChange?() }
            }
        }
        monitor.start(queue: DispatchQueue(label: "wiz.path"))
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
