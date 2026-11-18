import Foundation

/// Presets and custom scenes, kept on this device (as JSON in user defaults).
@MainActor @Observable
final class Library {
    static let presetsKey = "presets"
    static let customScenesKey = "customScenes"

    var presets: [Preset] { didSet { save(presets, Self.presetsKey); onChange?() } }
    var customScenes: [CustomScene] { didSet { save(customScenes, Self.customScenesKey); onChange?() } }
    /// Called after any change (the iPhone app passes the lists on to the watch).
    @ObservationIgnored var onChange: (() -> Void)?

    init() {
        presets = Self.load(Self.presetsKey) ?? []
        customScenes = Self.load(Self.customScenesKey) ?? []
    }

    func customScene(_ id: UUID) -> CustomScene? { customScenes.first { $0.id == id } }

    /// A name not already taken by a preset: "Preset 3", or "Name 2" if `base` is.
    func uniquePresetName(_ base: String) -> String { unique(base, in: presets.map(\.name)) }
    func uniqueSceneName(_ base: String) -> String { unique(base, in: customScenes.map(\.name)) }

    /// The swatch to show for a preset (custom scenes are looked up here).
    func swatch(_ colour: LightColour) -> RGB? {
        if case let .custom(id, _) = colour { return customScene(id)?.swatch }
        return colour.swatch
    }

    func name(of colour: LightColour) -> String {
        switch colour {
        case let .rgbcw(r, g, b, c, w): "R \(r) G \(g) B \(b) C \(c) W \(w)"
        case let .temp(k): "\(k) K"
        case let .scene(id, _): Scenes.name(id)
        case let .custom(id, _): customScene(id)?.name ?? "Deleted custom scene"
        }
    }

    var summaries: [CustomSceneSummary] {
        customScenes.map { CustomSceneSummary(id: $0.id, name: $0.name, swatch: $0.swatch) }
    }

    private func unique(_ base: String, in names: [String]) -> String {
        let taken = Set(names)
        if !taken.contains(base) { return base }
        var i = 2
        while taken.contains("\(base) \(i)") { i += 1 }
        return "\(base) \(i)"
    }

    private func save<T: Encodable>(_ value: T, _ key: String) {
        if let data = try? JSONEncoder().encode(value) { UserDefaults.standard.set(data, forKey: key) }
    }

    private static func load<T: Decodable>(_ key: String) -> T? {
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }
}
