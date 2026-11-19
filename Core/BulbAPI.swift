import Foundation

/// The bulb's methods (firmware 1.38.0, ESP25_SHRGB_01), from its method table: 70 methods, of which 35 are reachable over local UDP. The rest are refused
/// over UDP in normal operation. For the console's
/// method menu and templates, and the device info list.
enum BulbAPI {
    enum Kind: String, CaseIterable {
        case read = "Reads"
        case action = "Actions"
        case write = "Writes"
        case cloudOnly = "Cloud only"

        /// For one method.
        var badge: String {
            switch self {
            case .read: "Read"
            case .action: "Action"
            case .write: "Write"
            case .cloudOnly: "Cloud only"
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

    /// The reads, in the order the device info shows them: identity, capabilities and settings,
    /// then the rest.
    static var deviceInfo: [String] { all.filter { $0.kind == .read }.map(\.name) }

    static let all: [Method] = [
        // Reads
        Method(name: "getPilot", kind: .read, summary: "The current light: state, colour or temperature or scene, dimming, speed, effect."),
        Method(name: "getSystemConfig", kind: .read, summary: "Identity: MAC, module, firmware, home and room IDs, region."),
        Method(name: "getModelConfig", kind: .read, summary: "Hardware and colour configuration: CCT range, renderFactor, channel currents, PWM resolution."),
        Method(name: "getUserConfig", kind: .read, summary: "User settings: fadeIn and fadeOut, default dimming, power-on behaviour, dim-to-warm points."),
        Method(name: "getDevInfo", kind: .read, summary: "Device MACs, module and flash."),
        Method(name: "getPower", kind: .read, summary: "Power metering."),
        Method(name: "getTelemetry", kind: .read, summary: "Runtime and telemetry counters."),
        Method(name: "getTime", kind: .read, summary: "The bulb's clock."),
        Method(name: "getEffect", kind: .read, summary: "The current effect (pulse, sync modes)."),
        Method(name: "getFavs", kind: .read, summary: "Favourites."),
        Method(name: "getCctTable", kind: .read, summary: "A custom CCT table, if one is set (cloud-set only)."),
        Method(name: "getColorProfile", kind: .read, summary: "A colour profile, if one is set (cloud-set only)."),
        Method(name: "getPowerProfile", kind: .read, summary: "Power-profile configuration."),
        Method(name: "getScenario", kind: .read, summary: "Scenario configuration."),
        Method(name: "getSensor", kind: .read, summary: "Sensor state."),
        Method(name: "getSensorConfig", kind: .read, summary: "Sensor configuration."),
        Method(name: "getLuxSensing", kind: .read, summary: "Lux-sensing state."),
        Method(name: "getAcc", kind: .read, summary: "Accessory state."),
        Method(name: "getWifiBeaconing", kind: .read, summary: "SpaceSense Wi-Fi beaconing state."),
        Method(name: "getWifiProcessing", kind: .read, summary: "SpaceSense Wi-Fi processing state."),
        Method(name: "getWifiProcessingData", kind: .read, summary: "SpaceSense data."),
        Method(name: "getIotpOTAStatus", kind: .read, summary: "Firmware update status (UDP only)."),

        // Actions
        Method(name: "registration", kind: .action,
               summary: "Registers a controller for syncPilot pushes to its port 38900 (register: true), or just asks for the MAC (register: false). setPilot registers every 20 s.",
               template: #"{"phoneIp": "1.2.3.4", "phoneMac": "AAAAAAAAAAAA", "register": false}"#),
        Method(name: "pulse", kind: .action,
               summary: "Identify blink: a brightness change (delta) for duration ms, then back. Keys medium confidence: delta, duration, cct, state.",
               template: #"{"delta": -50, "duration": 600}"#),
        Method(name: "syncBroadcastPilot", kind: .action, summary: "Applies a broadcast pilot (group sync)."),
        Method(name: "syncAmbience", kind: .action, summary: "Ambience or music sync frame (UDP only): orig, type, music, syncAreaId, transition. Needs a stream to do anything."),
        Method(name: "syncAccEvt", kind: .action, summary: "Accessory event sync."),
        Method(name: "syncScnrEvt", kind: .action, summary: "Scenario event sync."),
        Method(name: "camSelfTest", kind: .action, summary: "Diagnostic self-test.",
               caution: "Runs the bulb's diagnostic self-test."),
        Method(name: "setTest", kind: .action,
               summary: "Test harness: self_test, test_config, timeout, url, major_ver, minor_ver, build_ver.",
               caution: "A factory test harness; it takes a URL and version numbers."),

        // Writes over UDP
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
               summary: "Over UDP: homeId, env and rgn (region), plus section version stamps. The rest of system config is cloud only.",
               caution: "Changes the bulb's home, environment or region, which the WiZ app and cloud rely on."),

        // Cloud only (refused over UDP in normal operation)
        Method(name: "reboot", kind: .cloudOnly, summary: "Restarts the bulb."),
        Method(name: "reset", kind: .cloudOnly, summary: "Factory reset.", caution: "Factory reset: the bulb forgets its Wi-Fi and setup."),
        Method(name: "setUserConfig", kind: .cloudOnly, summary: "fadeIn, fadeOut, default dimming, power-on behaviour, dim2WarmPoints."),
        Method(name: "setModelConfig", kind: .cloudOnly, summary: "Hardware and colour configuration.", caution: "Hardware configuration: a wrong value can stop the light working."),
        Method(name: "setCctTable", kind: .cloudOnly, summary: "Custom CCT table: numCctPoints, cctPoints."),
        Method(name: "setColorProfile", kind: .cloudOnly, summary: "Colour profile."),
        Method(name: "setPowerProfile", kind: .cloudOnly, summary: "Power profile."),
        Method(name: "setDevInfo", kind: .cloudOnly, summary: "Device info.", caution: "Changes the device's identity information."),
        Method(name: "setWifi", kind: .cloudOnly, summary: "Wi-Fi credentials.", caution: "Changes the bulb's Wi-Fi network."),
        Method(name: "setSecurity", kind: .cloudOnly, summary: "Local security.", caution: "Turns on request signing, after which setPilot can't control the bulb."),
        Method(name: "setFavs", kind: .cloudOnly, summary: "Favourites."),
        Method(name: "setWiZClick", kind: .cloudOnly, summary: "WiZ Click button configuration."),
        Method(name: "setSchd", kind: .cloudOnly, summary: "Schedules."),
        Method(name: "setSchdPset", kind: .cloudOnly, summary: "Schedule presets (Rhythm)."),
        Method(name: "setScenario", kind: .cloudOnly, summary: "Scenario configuration."),
        Method(name: "setSensor", kind: .cloudOnly, summary: "Sensor state."),
        Method(name: "setSensorConfig", kind: .cloudOnly, summary: "Sensor configuration."),
        Method(name: "setLuxSensing", kind: .cloudOnly, summary: "Lux sensing."),
        Method(name: "setAcc", kind: .cloudOnly, summary: "Accessory."),
        Method(name: "setAccDisc", kind: .cloudOnly, summary: "Accessory discovery."),
        Method(name: "setPairingAssist", kind: .cloudOnly, summary: "Pairing assist."),
        Method(name: "setCommissioning", kind: .cloudOnly, summary: "Commissioning.", caution: "Commissioning changes how the bulb is set up."),
        Method(name: "matterUpdate", kind: .cloudOnly, summary: "Matter update.", caution: "Matter configuration."),
        Method(name: "updateOta", kind: .cloudOnly, summary: "Starts a firmware update.", caution: "Starts a firmware update."),
        Method(name: "applyUpdate", kind: .cloudOnly, summary: "Applies a downloaded firmware update.", caution: "Applies a firmware update."),
        Method(name: "setWifiBeaconing", kind: .cloudOnly, summary: "SpaceSense beaconing."),
        Method(name: "setWifiProcessing", kind: .cloudOnly, summary: "SpaceSense processing."),
        Method(name: "spaceSenseChecking", kind: .cloudOnly, summary: "SpaceSense check."),
        Method(name: "spaceSenseTelemetry", kind: .cloudOnly, summary: "SpaceSense telemetry."),
        Method(name: "setSyncboxListener", kind: .cloudOnly, summary: "Sync box listener."),
        Method(name: "setSportsSync", kind: .cloudOnly, summary: "SportsSync."),
        Method(name: "setSportsSyncGame", kind: .cloudOnly, summary: "SportsSync game."),
        Method(name: "sportsSyncGameInfo", kind: .cloudOnly, summary: "SportsSync game info."),
        Method(name: "ping", kind: .cloudOnly, summary: "The cloud heartbeat (not a local liveness check)."),
    ]
}
