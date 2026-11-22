import Foundation

/// What an app shares with its widgets and controls, in the App Group's user defaults: the
/// bulb's last state, the presets, and (on iPhone) the bulb's address and each preset's
/// ready-made setPilot parameters. Without the App Group (it needs the entitlement) this falls
/// back to the process's own defaults, and widgets just show nothing useful.
enum SharedStore {
    #if os(macOS)
    /// On the Mac, Team-ID prefixed (no provisioning profile needed), from the Info.plist key the
    /// build fills in; nil in an ad-hoc build, which has no team.
    static let group: String? = {
        guard let id = Bundle.main.object(forInfoDictionaryKey: "SetPilotAppGroup") as? String else { return nil }
        let team = id.prefix { $0 != "." }
        return team.count == 10 && team.allSatisfy({ $0.isASCII && ($0.isUppercase || $0.isNumber) }) ? id : nil
    }()
    #else
    static let group: String? = "group.nz.aaronrumpler.setPilot"
    #endif
    #if WIZ_APP_GROUPS
    static let defaults = group.flatMap { UserDefaults(suiteName: $0) } ?? .standard
    #else
    // Built without App Groups (Account.xcconfig): nothing is shared, widgets show placeholders.
    static let defaults = UserDefaults.standard
    #endif

    /// Whether the App Group is there to share through (not in a Mac build without a team).
    #if WIZ_APP_GROUPS
    static let isShared = group != nil
    #else
    static let isShared = false
    #endif

    static let snapshotKey = "shared.snapshot"
    static let presetsKey = "shared.presets"
    static let presetParamsKey = "shared.presetParams"
    static let addressKey = "shared.address"
    /// The chosen bulb's signing key, if it has one.
    static let signingKeyKey = "shared.signingKey"
    static let customScenesKey = "shared.customScenes"
    /// The controls' fade (trans, ms), if any, for widget actions that send themselves.
    static let controlsTransKey = "shared.controlsTrans"

    static func save<T: Encodable>(_ value: T, _ key: String) {
        if let data = try? JSONEncoder().encode(value) { defaults.set(data, forKey: key) }
    }

    static func load<T: Decodable>(_ key: String) -> T? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    static var snapshot: LightSnapshot? { load(snapshotKey) }
    static var presets: [Preset] { load(presetsKey) ?? [] }
    static var customScenes: [CustomSceneSummary] { load(customScenesKey) ?? [] }

    /// A preset's swatch, with custom scenes looked up in the shared summaries.
    static func swatch(_ colour: LightColour) -> RGB? {
        if case let .custom(id, _) = colour { return customScenes.first { $0.id == id }?.swatch }
        return colour.swatch
    }
}
