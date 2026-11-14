import Foundation

enum Mode: String, CaseIterable, Identifiable {
    case rgbcw = "RGBCW", temp = "Temperature", scene = "Scene"
    var id: Self { self }
}

enum Maintenance: String, Identifiable {
    case reboot, reset
    var id: Self { self }
    var title: String { self == .reboot ? "Reboot" : "Factory reset" }
    var message: String {
        self == .reboot
            ? "The bulb will restart."
            : "The bulb forgets its Wi-Fi settings and must be paired again in the WiZ app."
    }
}

/// Scene IDs from pywizlight (RGB bulb set: excludes Rhythm and the sync-box scenes).
struct WizScene: Identifiable {
    let id: Int
    let name: String
}

enum Scenes {
    static let all: [WizScene] = {
        var s: [Int: String] = [
            1: "Ocean", 2: "Romance", 3: "Sunset", 4: "Party", 5: "Fireplace", 6: "Cozy",
            7: "Forest", 8: "Pastel colors", 9: "Wake-up", 10: "Bedtime", 11: "Warm white",
            12: "Daylight", 13: "Cool white", 14: "Night light", 15: "Focus", 16: "Relax",
            17: "True colors", 18: "TV time", 19: "Plantgrowth", 20: "Spring", 21: "Summer",
            22: "Fall", 23: "Deep dive", 24: "Jungle", 25: "Mojito", 26: "Club",
            27: "Christmas", 28: "Halloween", 29: "Candlelight", 30: "Golden white",
            31: "Pulse", 32: "Steampunk", 33: "Diwali", 34: "White", 35: "Alarm",
            36: "Snowy sky", 40: "Dim-to-warm",
        ]
        for i in 1...10 { s[255 + i] = "Custom Mode \(i)" }
        return s.map { WizScene(id: $0.key, name: $0.value) }.sorted { $0.id < $1.id }
    }()
}

@MainActor @Observable
final class Model {
    var mode: Mode = .rgbcw
    var r = 255.0, g = 0.0, b = 0.0, c = 0.0, w = 0.0
    var dimming = 100.0
    var temp = 2700.0
    var sceneId = 1
    var speed = 100.0
    var isOn: Bool?

    // From getModelConfig / getUserConfig
    var minDimming = 10.0
    var tempRange: ClosedRange<Double> = 2200...6500

    var mac: String?
    var rssi: Int?
    var info: [String: String] = [:] // method -> pretty-printed result
    var status = "Not connected"
    var liveStatus = "Live updates off"
    var lastSent = ""
    var discovered: [DiscoveredBulb] = []
    var discovering = false

    private let bulb = Bulb()
    private let push = PushListener()
    @ObservationIgnored private var sendScheduled = false
    @ObservationIgnored private var ignorePushUntil = Date.distantPast
    @ObservationIgnored private var registerTask: Task<Void, Never>?
    private let phoneMac = String((0..<12).map { _ in "0123456789abcdef".randomElement()! })

    init() {
        bulb.onReply = { [weak self] in self?.handleReply($0) }
        bulb.onError = { [weak self] in self?.status = $0 }
        push.onMessage = { [weak self] in self?.handlePush($0) }
        push.onFailure = { [weak self] reason in
            self?.registerTask?.cancel()
            self?.liveStatus = "Live updates off — \(reason)"
        }
    }

    // MARK: Connection

    func connect(_ ip: String) {
        bulb.connect(to: ip)
        mac = nil
        rssi = nil
        info = [:]
        status = "Querying \(ip)…"
        bulb.send("getPilot", retry: true)
        bulb.send("getModelConfig", retry: true)
        startLiveUpdates(ip)
    }

    /// pywizlight's push method: tell the bulb our IP every 20 s; it sends syncPilot to port 38900.
    private func startLiveUpdates(_ ip: String) {
        registerTask?.cancel()
        push.startIfNeeded()
        guard push.isRunning else { return }
        guard let phoneIp = Net.sourceIP(toward: ip.trimmingCharacters(in: .whitespaces)) else {
            liveStatus = "Live updates off — needs an IPv4 address to work out our local IP"
            return
        }
        liveStatus = "Registering for live updates…"
        let params: [String: Any] = ["phoneIp": phoneIp, "register": true, "phoneMac": phoneMac]
        registerTask = Task { [weak self] in
            while !Task.isCancelled {
                self?.bulb.send("registration", params)
                try? await Task.sleep(for: .seconds(20))
            }
        }
    }

    func find() async -> String? {
        discovering = true
        status = "Searching all interfaces…"
        let found = await Task.detached { Net.discover() }.value
        discovering = false
        discovered = found
        switch found.count {
        case 0: status = "No bulbs found"; return nil
        case 1: return found[0].ip
        default: status = "\(found.count) bulbs found — pick one"; return nil
        }
    }

    // MARK: Commands

    func sync() { bulb.send("getPilot", retry: true) }

    func power(_ on: Bool) {
        isOn = on
        bulb.send("setState", ["state": on], retry: true)
    }

    func setMode(_ m: Mode) { mode = m; sendPilot(retry: true) }
    func setScene(_ id: Int) { sceneId = id; sendPilot(retry: true) }

    func readConfig() {
        for m in ["getSystemConfig", "getModelConfig", "getUserConfig", "getPower"] {
            bulb.send(m, retry: true)
        }
    }

    /// Not retried: the bulb may go away before it answers.
    func run(_ m: Maintenance) {
        bulb.send(m.rawValue)
        status = "Sent \(m.rawValue)"
    }

    /// Coalesces slider drags into at most one setPilot per ~40 ms.
    func changed() {
        guard !sendScheduled else { return }
        sendScheduled = true
        Task {
            try? await Task.sleep(for: .milliseconds(40))
            sendScheduled = false
            sendPilot(retry: false)
        }
    }

    private func sendPilot(retry: Bool) {
        var p: [String: Any] = ["dimming": Int(dimming)]
        switch mode {
        case .rgbcw:
            p["r"] = Int(r); p["g"] = Int(g); p["b"] = Int(b); p["c"] = Int(c); p["w"] = Int(w)
        case .temp:
            p["temp"] = Int(temp)
        case .scene:
            p["sceneId"] = sceneId; p["speed"] = Int(speed)
        }
        if let data = try? JSONSerialization.data(withJSONObject: p, options: .sortedKeys) {
            lastSent = String(decoding: data, as: UTF8.self)
        }
        // Our own changes come back as pushes; don't let them yank the sliders mid-drag.
        ignorePushUntil = Date().addingTimeInterval(0.6)
        bulb.send("setPilot", p, retry: retry)
    }

    // MARK: Incoming

    private func handleReply(_ reply: [String: Any]) {
        let method = reply["method"] as? String ?? "?"
        if let err = reply["error"] as? [String: Any] {
            let text = (err["code"] as? Int) == -32601 ? "not supported by this firmware" : "\(err["message"] ?? err)"
            if method.hasPrefix("get") && method != "getPilot" { info[method] = text }
            status = "\(method): \(text)"
            return
        }
        guard let result = reply["result"] as? [String: Any] else { return }
        switch method {
        case "getPilot":
            applyPilot(result)
            status = "Synced"
        case "getModelConfig", "getUserConfig":
            applyLimits(result)
            info[method] = pretty(result)
        case "getSystemConfig", "getPower":
            if let m = result["mac"] as? String { mac = m }
            info[method] = pretty(result)
        case "registration":
            if result["success"] as? Bool == true, push.isRunning, !liveStatus.hasPrefix("Live updates on") {
                liveStatus = "Live updates on"
            }
        default:
            status = "\(method) ok"
        }
    }

    private func handlePush(_ msg: [String: Any]) {
        guard msg["method"] as? String == "syncPilot",
              let params = msg["params"] as? [String: Any],
              let from = params["mac"] as? String, let mac, from.lowercased() == mac.lowercased()
        else { return }
        let time = Date().formatted(date: .omitted, time: .standard)
        liveStatus = "Live updates on — last push \(time)"
        if Date() >= ignorePushUntil { applyPilot(params) }
    }

    private func applyPilot(_ p: [String: Any]) {
        func num(_ k: String) -> Double? { (p[k] as? NSNumber)?.doubleValue }
        if let m = p["mac"] as? String { mac = m }
        if let s = p["state"] as? Bool { isOn = s }
        if let v = num("rssi") { rssi = Int(v) }
        if let d = num("dimming") { dimming = d }
        let scene = p["schdPsetId"] != nil ? 1000 : Int(num("sceneId") ?? 0)
        if scene != 0 {
            mode = .scene
            sceneId = scene
            if let s = num("speed") { speed = s }
        } else if let t = num("temp") {
            mode = .temp
            temp = t
        } else if num("r") != nil || num("c") != nil || num("w") != nil {
            mode = .rgbcw
            r = num("r") ?? 0; g = num("g") ?? 0; b = num("b") ?? 0
            c = num("c") ?? 0; w = num("w") ?? 0
        }
    }

    private func applyLimits(_ result: [String: Any]) {
        if let d = (result["minDimLevel"] as? NSNumber)?.doubleValue, d >= 1, d < 100 {
            minDimming = d
            dimming = max(dimming, d)
        }
        // pywizlight: extRange (older firmware), else cctRange [min, …, max]
        if let range = (result["extRange"] ?? result["cctRange"]) as? [NSNumber],
           let lo = range.first?.doubleValue, let hi = range.last?.doubleValue, lo < hi {
            tempRange = lo...hi
        }
    }

    private func pretty(_ obj: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys])
        else { return "\(obj)" }
        return String(decoding: data, as: UTF8.self)
    }
}
