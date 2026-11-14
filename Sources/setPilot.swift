import AppKit
import Network
import SwiftUI

// MARK: - App

@main
struct SetPilotApp: App {
    @NSApplicationDelegateAdaptor private var delegate: AppDelegate

    var body: some Scene {
        Window("WiZ", id: "main") { ContentView() }
            .windowResizability(.contentSize)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Needed when launched via `swift run` (no bundle) so we get a Dock icon and focus.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

// MARK: - Bulb (UDP JSON on port 38899)

@MainActor
final class Bulb {
    private var conn: NWConnection?
    private let queue = DispatchQueue(label: "wiz.udp")
    var onReply: (([String: Any]) -> Void)?
    var onError: ((String) -> Void)?

    func connect(to ip: String) {
        conn?.cancel()
        conn = nil
        let ip = ip.trimmingCharacters(in: .whitespaces)
        guard !ip.isEmpty else { return }
        let c = NWConnection(host: NWEndpoint.Host(ip), port: 38899, using: .udp)
        conn = c
        c.start(queue: queue)
        receive(on: c)
    }

    func send(_ method: String, _ params: [String: Any] = [:]) {
        guard let conn,
              let data = try? JSONSerialization.data(withJSONObject: ["method": method, "params": params])
        else { return }
        conn.send(content: data, completion: .contentProcessed { [weak self] error in
            guard let error else { return }
            Task { @MainActor in self?.onError?("Send failed: \(error)") }
        })
    }

    private func receive(on c: NWConnection) {
        c.receiveMessage { [weak self] data, _, _, error in
            let obj = data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
            Task { @MainActor in
                guard let self, c === self.conn else { return }
                if let obj { self.onReply?(obj) }
                if let error {
                    self.onError?("Receive failed: \(error) — press Connect to retry")
                } else {
                    self.receive(on: c)
                }
            }
        }
    }
}

// MARK: - Model

@MainActor @Observable
final class Model {
    var r = 255.0, g = 0.0, b = 0.0, c = 0.0, w = 0.0
    var dimming = 100.0
    var status = "Not connected"
    var lastSent = ""

    @ObservationIgnored private let bulb = Bulb()
    @ObservationIgnored private var sendScheduled = false

    init() {
        bulb.onReply = { [weak self] in self?.handle($0) }
        bulb.onError = { [weak self] in self?.status = $0 }
    }

    func connect(_ ip: String) {
        bulb.connect(to: ip)
        status = "Querying \(ip)…"
        bulb.send("getPilot")
    }

    func sync() { bulb.send("getPilot") }
    func power(_ on: Bool) { bulb.send("setState", ["state": on]) }

    /// Coalesces slider drags into at most one setPilot per ~40 ms.
    func changed() {
        guard !sendScheduled else { return }
        sendScheduled = true
        Task {
            try? await Task.sleep(for: .milliseconds(40))
            sendScheduled = false
            sendPilot()
        }
    }

    private func sendPilot() {
        let params: [String: Any] = [
            "r": Int(r), "g": Int(g), "b": Int(b), "c": Int(c), "w": Int(w),
            "dimming": Int(dimming),
        ]
        lastSent = #"{"r":\#(Int(r)),"g":\#(Int(g)),"b":\#(Int(b)),"c":\#(Int(c)),"w":\#(Int(w)),"dimming":\#(Int(dimming))}"#
        bulb.send("setPilot", params)
    }

    private func handle(_ reply: [String: Any]) {
        let method = reply["method"] as? String ?? "?"
        if let err = reply["error"] as? [String: Any] {
            status = "\(method) error: \(err["message"] ?? err)"
            return
        }
        guard let result = reply["result"] as? [String: Any] else { return }
        if method == "getPilot" {
            func v(_ k: String) -> Double { (result[k] as? NSNumber)?.doubleValue ?? 0 }
            r = v("r"); g = v("g"); b = v("b"); c = v("c"); w = v("w")
            dimming = max(10, v("dimming"))
            let on = result["state"] as? Bool ?? false
            var s = "Synced — \(on ? "on" : "off")"
            if let temp = result["temp"] { s += ", bulb was in \(temp)K mode" }
            if let scene = result["sceneId"] as? Int, scene != 0 { s += ", scene \(scene)" }
            status = s
        } else {
            status = "\(method) ok"
        }
    }
}

// MARK: - UI

struct ContentView: View {
    @AppStorage("bulbIP") private var ip = ""
    @State private var model = Model()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                TextField("Bulb IP", text: $ip)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { model.connect(ip) }
                Button("Connect") { model.connect(ip) }
                Button("Sync") { model.sync() }
                    .help("Read current values from the bulb (getPilot)")
            }

            HStack {
                Button("On") { model.power(true) }
                Button("Off") { model.power(false) }
                Spacer()
                Button("Zero RGBCW") {
                    model.r = 0; model.g = 0; model.b = 0; model.c = 0; model.w = 0
                    model.changed()
                }
            }

            Divider()

            ChannelSlider(label: "Red", tint: .red, range: 0...255, value: bind(\.r))
            ChannelSlider(label: "Green", tint: .green, range: 0...255, value: bind(\.g))
            ChannelSlider(label: "Blue", tint: .blue, range: 0...255, value: bind(\.b))
            ChannelSlider(label: "Cool W", tint: .cyan, range: 0...255, value: bind(\.c))
            ChannelSlider(label: "Warm W", tint: .orange, range: 0...255, value: bind(\.w))
            ChannelSlider(label: "Dimming", tint: .gray, range: 10...100, value: bind(\.dimming))

            Divider()

            Text(model.lastSent.isEmpty ? " " : "setPilot \(model.lastSent)")
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
            Text(model.status)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding()
        .frame(width: 460)
        .onAppear { if !ip.isEmpty { model.connect(ip) } }
    }

    /// Binding that clamps to the slider range's integer values and triggers a send only on user edits.
    private func bind(_ kp: ReferenceWritableKeyPath<Model, Double>) -> Binding<Double> {
        Binding(
            get: { model[keyPath: kp] },
            set: { model[keyPath: kp] = $0.rounded(); model.changed() }
        )
    }
}

struct ChannelSlider: View {
    let label: String
    let tint: Color
    let range: ClosedRange<Double>
    @Binding var value: Double

    var body: some View {
        HStack {
            Text(label).frame(width: 60, alignment: .leading)
            Slider(value: $value, in: range, step: 1).tint(tint)
            TextField("", value: clamped, format: .number)
                .textFieldStyle(.roundedBorder)
                .multilineTextAlignment(.trailing)
                .frame(width: 48)
        }
    }

    private var clamped: Binding<Double> {
        Binding(get: { value }, set: { value = min(max($0, range.lowerBound), range.upperBound) })
    }
}
