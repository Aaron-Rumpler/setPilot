import Foundation

/// The methods the bulb takes over local UDP (firmware 1.38.0, ESP25_SHRGB_01), from its method table: 35 of its 70. The rest are refused over UDP, so they
/// aren't listed (the console still sends any name typed). For the console's method menu and
/// templates, and the device info list.
enum BulbAPI {
    enum Kind: String, CaseIterable {
        case read = "Reads"
        case action = "Actions"
        case write = "Writes"

        /// For one method.
        var badge: String {
            switch self {
            case .read: "Read"
            case .action: "Action"
            case .write: "Write"
            }
        }
    }

    struct Method: Identifiable {
        let name: String
        let kind: Kind
        let summary: String
        /// Params to start from, as JSON.
        var template = "{}"
        /// Set for anything that changes what the bulb stores or how it's set up: the console asks
        /// before sending.
        var caution: String? = nil
        var id: String { name }
    }

    static func method(_ name: String) -> Method? { all.first { $0.name == name } }

    /// The reads, in the order the device info shows them: the light and the bulb's identity, its
    /// configuration, status, then features this bulb may not have.
    static var deviceInfo: [String] { all.filter { $0.kind == .read }.map(\.name) }

    /// The device info shown open to begin with.
    static let deviceInfoExpanded: Set<String> = ["getPilot", "getDevInfo", "getSystemConfig"]

    static let all: [Method] = [
        // Reads: the light and identity
        Method(name: "getPilot", kind: .read, summary: "The current light: state, colour or temperature or scene, dimming, speed, effect."),
        Method(name: "getDevInfo", kind: .read, summary: "Device MACs, module and flash."),
        Method(name: "getSystemConfig", kind: .read, summary: "Identity: MAC, module, firmware, home and room IDs, region."),
        // Configuration
        Method(name: "getModelConfig", kind: .read, summary: "Hardware and colour configuration: CCT range, renderFactor, channel currents, PWM resolution."),
        Method(name: "getUserConfig", kind: .read, summary: "User settings: fadeIn and fadeOut, default dimming, power-on behaviour, dim-to-warm points."),
        Method(name: "getCctTable", kind: .read, summary: "A custom CCT table, if one is set (only the cloud can set one)."),
        Method(name: "getColorProfile", kind: .read, summary: "A colour profile, if one is set (only the cloud can set one)."),
        Method(name: "getPowerProfile", kind: .read, summary: "Power-profile configuration."),
        // Status
        Method(name: "getPower", kind: .read, summary: "Power metering."),
        Method(name: "getTime", kind: .read, summary: "The bulb's clock."),
        Method(name: "getEffect", kind: .read, summary: "The current effect (pulse, sync modes)."),
        Method(name: "getTelemetry", kind: .read, summary: "Runtime and telemetry counters."),
        Method(name: "getIotpOTAStatus", kind: .read, summary: "Firmware update status."),
        // Features
        Method(name: "getFavs", kind: .read, summary: "Favourites."),
        Method(name: "getScenario", kind: .read, summary: "Scenario configuration."),
        // Sensors and accessories (other WiZ products)
        Method(name: "getSensor", kind: .read, summary: "Sensor state."),
        Method(name: "getSensorConfig", kind: .read, summary: "Sensor configuration."),
        Method(name: "getLuxSensing", kind: .read, summary: "Lux-sensing state."),
        Method(name: "getAcc", kind: .read, summary: "Accessory state."),
        // SpaceSense (Wi-Fi motion sensing)
        Method(name: "getWifiBeaconing", kind: .read, summary: "SpaceSense Wi-Fi beaconing state."),
        Method(name: "getWifiProcessing", kind: .read, summary: "SpaceSense Wi-Fi processing state."),
        Method(name: "getWifiProcessingData", kind: .read, summary: "SpaceSense data."),

        // Actions
        Method(name: "registration", kind: .action,
               summary: "Registers a controller for syncPilot pushes to its port 38900 (register: true), or just asks for the MAC (register: false). setPilot registers every 20 s.",
               template: #"{"phoneIp": "1.2.3.4", "phoneMac": "AAAAAAAAAAAA", "register": false}"#),
        Method(name: "pulse", kind: .action,
               summary: "Identify blink: a brightness change (delta) for duration ms, then back. Keys medium confidence: delta, duration, cct, state.",
               template: #"{"delta": -50, "duration": 600}"#),
        Method(name: "syncBroadcastPilot", kind: .action, summary: "Applies a broadcast pilot (group sync)."),
        Method(name: "syncAmbience", kind: .action, summary: "Ambience or music sync frame: orig, type, music, syncAreaId, transition. Needs a stream to do anything."),
        Method(name: "syncAccEvt", kind: .action, summary: "Accessory event sync."),
        Method(name: "syncScnrEvt", kind: .action, summary: "Scenario event sync."),
        Method(name: "camSelfTest", kind: .action, summary: "Diagnostic self-test.",
               caution: "Runs the bulb's diagnostic self-test."),
        Method(name: "setTest", kind: .action,
               summary: "Test harness: self_test, test_config, timeout, url, major_ver, minor_ver, build_ver.",
               caution: "A factory test harness; it takes a URL and version numbers."),

        // Writes
        Method(name: "setPilot", kind: .write,
               summary: "Sets the light: r g b c w (0–255), temp (1000–12000, clamped to the CCT range), sceneId, speed (only takes when sent alone), dimming, dimDelta, state, trans (fade ms), ratio, and elm with a sceneId ≥ 266. Without state it switches the bulb on.",
               template: #"{"temp": 2700, "dimming": 50}"#),
        Method(name: "setState", kind: .write, summary: "Switches on or off (optionally with dimming).",
               template: #"{"state": true}"#),
        Method(name: "setEffect", kind: .write,
               summary: "Effects and sync modes: pulse (pulse, duration, pulseCount, stepOff, preview), autobrightness (no sensor on this bulb), ambienceSync, musicSync, sportsSync. Shared keys: devices, type, state."),
        Method(name: "setExtendedLightMode", kind: .write,
               summary: "Stores a scene in a permanent slot: id 1–20 (slot), elmId (the sceneId it plays as, ≥ 256), elm {modifier, support 17, steps of 13 numbers}, or delete: true.",
               template: #"{"id": 20, "elmId": 266, "elm": {"modifier": 1, "support": 17, "steps": [[0, 255, 60, 0, 0, 0, 2700, 100, 2000, 2000, 0, 0, 0], [0, 0, 40, 255, 0, 0, 2700, 100, 2000, 2000, 0, 0, 0]]}}"#,
               caution: "Writes one of the bulb's stored scene slots, which may hold one of the WiZ app's custom scenes."),
        Method(name: "setSystemConfig", kind: .write,
               summary: "homeId, env and rgn (region), plus section version stamps.",
               caution: "Changes the bulb's home, environment or region, which the WiZ app and cloud rely on."),
    ]
}
