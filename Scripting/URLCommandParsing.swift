import Foundation

// The setpilot:// URL scheme, for launchers and automation tools:
//
//   setpilot://power?on=toggle
//   setpilot://x-callback-url/scene?name=Ocean&speed=150&x-success=…&x-error=…
//
// The same commands as Shortcuts and the command-line tool (Core/Commands.swift): only what the
// app's controls do. Web pages can open these links too (after the browser asks), which is one
// reason there are no raw bulb methods here.
//
// With x-callback-url, x-success gets `state` (the light as JSON, as `setpilot get --json`
// prints it); x-error gets `errorCode` and `errorMessage`.

enum URLCommands {
    /// The command a URL asks for, or why it isn't one.
    static func command(from url: URL) -> Result<ScriptCommand, ScriptError> {
        guard url.scheme?.lowercased() == "setpilot" else { return .failure(bad("Not a setpilot:// link.")) }
        // setpilot://power?… or setpilot://x-callback-url/power?…
        var action = url.host()?.lowercased() ?? ""
        if action == "x-callback-url" { action = url.pathComponents.dropFirst().first?.lowercased() ?? "" }
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        // "+" as a space too, as many launchers encode one.
        func value(_ name: String) -> String? {
            items.first { $0.name.lowercased() == name }?.value?.replacingOccurrences(of: "+", with: " ")
        }
        func int(_ name: String) -> Int? { value(name).flatMap { Int($0) } }
        func flag(_ name: String) -> Bool? {
            switch value(name)?.lowercased() {
            case "1", "true", "yes", "on": true
            case "0", "false", "no", "off": false
            default: nil
            }
        }
        // "switch on" for colour, temperature and scenes: only true means anything.
        let switchOn: Bool? = flag("on") == true ? true : nil

        switch action {
        case "get", "state":
            return .success(.get)
        case "power":
            switch value("on")?.lowercased() {
            case nil, "toggle": return .success(.power(nil))
            default:
                guard let on = flag("on") else { return .failure(bad("on is true, false or toggle.")) }
                return .success(.power(on))
            }
        case "brightness", "dimming":
            guard let level = int("level") ?? int("value") else { return .failure(bad("Give level=1–100.")) }
            return .success(.brightness(level))
        case "brighter", "dimmer":
            let step = int("step") ?? 10
            return .success(.adjustBrightness(action == "brighter" ? step : -step))
        case "colour", "color", "rgbcw":
            let r = int("r") ?? 0, g = int("g") ?? 0, b = int("b") ?? 0, c = int("c") ?? 0, w = int("w") ?? 0
            return .success(.colour(r: r, g: g, b: b, c: c, w: w, power: switchOn))
        case "temperature", "temp", "kelvin":
            guard let k = int("kelvin") ?? int("k") ?? int("value") else { return .failure(bad("Give kelvin=….")) }
            return .success(.temperature(k, scale: value("scale"), power: switchOn))
        case "scene":
            guard let name = value("name") ?? value("id") else { return .failure(bad("Give name=… (or id=…).")) }
            return .success(.scene(name, speed: int("speed"), power: switchOn))
        case "custom-scene", "customscene":
            guard let name = value("name") ?? value("id") else { return .failure(bad("Give name=… (or id=…).")) }
            return .success(.customScene(name, power: switchOn))
        case "speed":
            guard let s = int("value") ?? int("speed") else { return .failure(bad("Give value=10–200.")) }
            return .success(.speed(s))
        case "preset":
            guard let name = value("name") ?? value("id") else { return .failure(bad("Give name=… (or id=…).")) }
            return .success(.preset(name))
        case "switch", "bulb":
            guard let bulb = value("bulb") ?? value("name") else { return .failure(bad("Give bulb=… (a name, MAC or address).")) }
            return .success(.switchBulb(bulb))
        default:
            return .failure(bad("Unknown action “\(action)”."))
        }
    }

    private static func bad(_ message: String) -> ScriptError { ScriptError(code: .badArguments, message: message) }

    /// Schemes a callback may not open: a link (from a web page, say) mustn't use setPilot to open
    /// files or connect to servers without the prompt the browser would give.
    static let refusedCallbackSchemes: Set<String> = [
        "file", "ftp", "sftp", "smb", "afp", "nfs", "vnc", "ssh", "telnet", "x-man-page",
        "facetime", "facetime-audio", "tel", "sms", "mailto", "javascript", "data",
    ]

    /// The x-success or x-error URL with the result added, if the link gave one (and it may be
    /// opened). The state goes without the bulb's MAC and address: a web page needn't learn them.
    static func callback(for url: URL, result: ScriptResult) -> URL? {
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let key = result.error == nil ? "x-success" : "x-error"
        guard let target = items.first(where: { $0.name == key })?.value,
              var callback = URLComponents(string: target),
              let scheme = callback.scheme?.lowercased(), !refusedCallbackSchemes.contains(scheme) else { return nil }
        var extra: [URLQueryItem] = []
        if let error = result.error {
            extra = [URLQueryItem(name: "errorCode", value: error.code.rawValue),
                     URLQueryItem(name: "errorMessage", value: error.message)]
        } else if var state = result.state {
            state.bulb.mac = nil
            state.bulb.address = nil
            let encoder = JSONEncoder()
            encoder.outputFormatting = .sortedKeys
            if let data = try? encoder.encode(state) {
                extra = [URLQueryItem(name: "state", value: String(decoding: data, as: UTF8.self))]
            }
        }
        callback.queryItems = (callback.queryItems ?? []) + extra
        return callback.url
    }
}
