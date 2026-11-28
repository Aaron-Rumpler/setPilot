import Foundation
import Observation
import Darwin

#if WIZ_APP_GROUPS
/// The command-line tool's way in: a Unix socket in the App Group container it shares with the app.
/// Each connection sends one line (a ScriptRequest as JSON) and gets one line back (a
/// ScriptResult); a watch request instead gets the state, one line each time it changes, until it
/// closes. Only someone signed into this Mac as you can reach it (the container is yours alone).
@MainActor
final class CLIServer {
    static let shared = CLIServer()
    private var listener: Int32 = -1

    /// Starts listening, if this build has an App Group container to listen in.
    func start(model: Model) {
        guard listener < 0, let path = ScriptSocket.path else { return }
        // Another copy of the app (a Debug build beside the installed one) already answering:
        // leave it be, rather than take its socket away.
        if Self.answering(path) { return }
        unlink(path) // left by an earlier run
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return }
        let bound = ScriptSocket.withAddress(path) { bind(fd, $0, $1) }
        guard bound == 0, listen(fd, 8) == 0 else { close(fd); return }
        chmod(path, 0o600)
        listener = fd
        // Accepting blocks: on a thread of its own.
        let thread = Thread {
            while true {
                let client = accept(fd, nil, nil)
                guard client >= 0 else {
                    // Out of descriptors, say: not a busy loop.
                    if errno != EINTR && errno != ECONNABORTED { Thread.sleep(forTimeInterval: 0.2) }
                    continue
                }
                var on: Int32 = 1
                setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
                // A tool that connects and never sends its request doesn't hold a thread for ever.
                var wait = timeval(tv_sec: 10, tv_usec: 0)
                setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &wait, socklen_t(MemoryLayout<timeval>.size))
                Thread { Self.serve(client, model: model) }.start()
            }
        }
        thread.start()
    }

    /// One connection: read its request line, answer it (or keep writing, for watch).
    nonisolated private static func serve(_ fd: Int32, model: Model) {
        defer { close(fd) }
        // read(2), not FileHandle: its availableData raises (crashing the app) on a read error.
        var buffer = Data()
        var chunk = [UInt8](repeating: 0, count: 4096)
        while buffer.firstIndex(of: 0x0A) == nil {
            let n = read(fd, &chunk, chunk.count)
            if n <= 0 { return }
            buffer.append(contentsOf: chunk[0..<n])
            if buffer.count > 64_000 { return } // not a request
        }
        let line = buffer.prefix { $0 != 0x0A }
        guard let request = try? JSONDecoder().decode(ScriptRequest.self, from: line) else {
            write(ScriptResult(error: ScriptError(code: .badArguments, message: "Not a request the app understands (are the app and the tool from the same build?).")), to: fd)
            return
        }
        if request.watch == true {
            watch(fd, model: model)
            return
        }
        guard let command = request.command else {
            // Answered, so the tool says what's wrong rather than that the app hung up.
            write(ScriptResult(error: ScriptError(code: .badArguments, message: "No command given (are the app and the tool from the same build?).")), to: fd)
            return
        }
        let done = DispatchSemaphore(value: 0)
        let box = ResultBox()
        Task { @MainActor in
            // From when the command was given (launching the app counts; the same clock, so one
            // long ago, the Mac asleep in between say, is refused as late, not sent now).
            let asked = min(request.asked.map(Date.init(timeIntervalSince1970:)) ?? .now, .now)
            box.result = await Scripting.run(command, fade: request.fade, asked: asked, on: model)
            done.signal()
        }
        done.wait()
        if let result = box.result { write(result, to: fd) }
    }

    /// Writes the state now and whenever it changes (at most every 0.2 s), until the tool goes away.
    nonisolated private static func watch(_ fd: Int32, model: Model) {
        let changed = DispatchSemaphore(value: 0)
        let box = WatchBox()
        // Observes until the tool has gone (then stops re-registering).
        @MainActor func observe() {
            guard !box.stopped else { return }
            withObservationTracking {
                _ = Scripting.state(of: model)
            } onChange: {
                changed.signal()
                Task { @MainActor in observe() }
            }
        }
        Task { @MainActor in
            observe()
            changed.signal() // the state as it is now, first
        }
        var last: LightState?
        while true {
            // Every second without a change, check the tool's still there (it reads nothing, so
            // anything readable, or the end, means it's gone).
            guard changed.wait(timeout: .now() + 1) == .success else {
                var p = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
                if poll(&p, 1, 0) > 0 {
                    box.stopped = true
                    return
                }
                continue
            }
            Thread.sleep(forTimeInterval: 0.2) // let a burst settle
            while changed.wait(timeout: .now()) == .success {} // and take it as one
            let state = DispatchQueue.main.sync { MainActor.assumeIsolated { Scripting.state(of: model) } }
            guard state != last else { continue }
            last = state
            guard write(state, to: fd) else {
                box.stopped = true
                return
            }
        }
    }

    /// Whether something's listening at `path` already.
    nonisolated private static func answering(_ path: String) -> Bool {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        return ScriptSocket.withAddress(path) { Darwin.connect(fd, $0, $1) } == 0
    }

    /// False once the other end has gone.
    @discardableResult
    nonisolated private static func write<T: Encodable>(_ value: T, to fd: Int32) -> Bool {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        guard var data = try? encoder.encode(value) else { return false }
        data.append(0x0A)
        return data.withUnsafeBytes { raw in
            var sent = 0
            while sent < raw.count {
                let n = Darwin.write(fd, raw.baseAddress! + sent, raw.count - sent)
                if n <= 0 { return false }
                sent += n
            }
            return true
        }
    }
}

private final class ResultBox: @unchecked Sendable { var result: ScriptResult? }
private final class WatchBox: @unchecked Sendable { var stopped = false }
#endif
