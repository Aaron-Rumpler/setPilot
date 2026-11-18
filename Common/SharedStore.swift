import Foundation

/// What an app shares with its widgets and controls, in the App Group's user defaults: the
/// bulb's last state, the presets, and (on iPhone) the bulb's address and each preset's
/// ready-made setPilot parameters. Without the App Group (it needs the entitlement) this falls
/// back to the process's own defaults, and widgets just show nothing useful.
enum SharedStore {
    static let group = "group.nz.aaronrumpler.setPilot"
    #if WIZ_APP_GROUPS
    static let defaults = UserDefaults(suiteName: group) ?? .standard
    #else
    // Built without App Groups (Account.xcconfig): nothing is shared, widgets show placeholders.
    static let defaults = UserDefaults.standard
    #endif

    static let snapshotKey = "shared.snapshot"
    static let presetsKey = "shared.presets"
    static let presetParamsKey = "shared.presetParams"
    static let addressKey = "shared.address"

    static func save<T: Encodable>(_ value: T, _ key: String) {
        if let data = try? JSONEncoder().encode(value) { defaults.set(data, forKey: key) }
    }

    static func load<T: Decodable>(_ key: String) -> T? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    static var snapshot: LightSnapshot? { load(snapshotKey) }
    static var presets: [Preset] { load(presetsKey) ?? [] }
}
