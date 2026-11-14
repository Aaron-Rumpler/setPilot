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
    // One per line: @Observable can't expand multi-variable declarations.
    var r = 255.0
    var g = 0.0
    var b = 0.0
    var c = 0.0
    var w = 0.0
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
    /// A setPilot hasn't been read back yet; the UI shows what was requested meanwhile.
    var pending = false
    /// What the bulb reported differently from the last setPilot, if anything.
    var mismatch: String?
    var discovered: [DiscoveredBulb] = []
    var discovering = false

    private let bulb = Bulb()
    private let push = PushListener()
    @ObservationIgnored private var sendScheduled = false
    @ObservationIgnored private var lastPilot: [String: Int] = [:]
    @ObservationIgnored private var sendSeq = 0
    @ObservationIgnored private var verifyingSeq: Int?
    @ObservationIgnored private var verifyTask: Task<Void, Never>?
    @ObservationIgnored private var registerTask: Task<Void, Never>?
    private let phoneMac = String((0..<12).map { _ in "0123456789abcdef".randomElement()! })

    init() {
        bulb.onReply = { [weak self] in self?.handleReply($0) }
        bulb.onError = { [weak self] message in
            guard let self else { return }
            status = message
            if message.hasPrefix("getPilot") || message.hasPrefix("setPilot") {
                // Couldn't confirm; stop showing the request as pending.
                pending = false
                verifyingSeq = nil
            }
        }
        push.onMessage = { [weak self] in self?.handlePush($0) }
        push.onFailure = { [weak self] reason in
            self?.registerTask?.cancel()
            self?.liveStatus = "Live updates off — \(reason)"
        }
    }

    // MARK: Connection

    func connect(_ ip: String) {
        bulb.connect(to: ip)
        verifyTask?.cancel()
        verifyingSeq = nil
        pending = false
        mismatch = nil
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

    func sync() {
        verifyingSeq = nil
        pending = false
        bulb.send("getPilot", retry: true)
    }

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
        lastPilot = p.compactMapValues { $0 as? Int }
        sendSeq += 1
        pending = true
        bulb.send("setPilot", p, retry: retry)
        scheduleVerify()
    }

    /// Once changes settle, read the state back to catch values the bulb ignored or adjusted
    /// (it replies "success" to some setPilots it doesn't fully apply).
    private func scheduleVerify() {
        verifyTask?.cancel()
        verifyTask = Task {
            try? await Task.sleep(for: .milliseconds(700))
            guard !Task.isCancelled else { return }
            verifyingSeq = sendSeq
            bulb.send("getPilot", retry: true)
        }
    }

    private func verify(_ result: [String: Any]) {
        var diffs: [String] = []
        for key in lastPilot.keys.sorted() {
            let want = lastPilot[key]!
            let got = (result[key] as? NSNumber)?.intValue
            // Absent zero channels and speed (static scenes) aren't meaningful differences.
            if got == want || (got == nil && (want == 0 || key == "speed")) { continue }
            diffs.append("\(key) \(want)→\(got.map(String.init) ?? "absent")")
        }
        if result["state"] as? Bool == false { diffs.append("bulb is off") }
        mismatch = diffs.isEmpty ? nil : "Bulb didn't apply: " + diffs.joined(separator: ", ")
        status = diffs.isEmpty ? "Bulb confirmed" : "Showing the bulb's actual state"
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
            if let seq = verifyingSeq {
                // A newer setPilot went out after this check started; its own check will follow.
                guard seq == sendSeq else { return }
                verifyingSeq = nil
                pending = false
                applyPilot(result)
                verify(result)
            } else {
                applyPilot(result)
                status = "Synced"
            }
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
        // While a change is unconfirmed, pushes may describe the old state; the read-back settles it.
        if !pending { applyPilot(params) }
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
