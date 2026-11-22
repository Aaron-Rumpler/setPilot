import Foundation

/// Presets, custom scenes and CCT scales, kept on this device (as JSON in user defaults) and,
/// in builds with iCloud, synced item by item through it (CloudLibrary).
@MainActor @Observable
final class Library {
    static let presetsKey = "presets"
    static let customScenesKey = "customScenes"
    static let cctScalesKey = "cctScales"
    static let activeCCTScaleKey = "activeCCTScale"

    var presets: [Preset] { didSet { save(presets, Self.presetsKey); onChange?() } }
    var customScenes: [CustomScene] { didSet { save(customScenes, Self.customScenesKey); onChange?() } }
    /// Custom CCT scales per bulb (keyed by lower-case MAC), and the one in use for each.
    var cctScales: [String: [CCTScale]] { didSet { save(cctScales, Self.cctScalesKey); onChange?() } }
    var activeCCTScale: [String: UUID] { didSet { save(activeCCTScale, Self.activeCCTScaleKey) } }
    /// Called after any change (the iPhone app passes the lists on to the watch).
    @ObservationIgnored var onChange: (() -> Void)?

    init() {
        presets = Self.load(Self.presetsKey) ?? []
        customScenes = Self.load(Self.customScenesKey) ?? []
        cctScales = Self.load(Self.cctScalesKey) ?? [:]
        activeCCTScale = Self.load(Self.activeCCTScaleKey) ?? [:]
        syncWithCloud()
        // Which scale is in use syncs as a setting (CloudSync).
        NotificationCenter.default.addObserver(forName: CloudSync.settingsChanged, object: nil, queue: .main) { [weak self] note in
            guard (note.object as? [String])?.contains(Self.activeCCTScaleKey) == true else { return }
            MainActor.assumeIsolated {
                guard let self, let v: [String: UUID] = Self.load(Self.activeCCTScaleKey), v != self.activeCCTScale else { return }
                self.fromCloud = true
                self.activeCCTScale = v
                self.fromCloud = false
            }
        }
    }

    /// Set while taking a value from iCloud, so it isn't sent straight back.
    @ObservationIgnored private var fromCloud = false

    /// Builds before item-by-item sync kept each list whole in iCloud key-value storage: take
    /// anything there that isn't here yet, once, so it goes up with the first sync.
    private func syncWithCloud() {
        guard CloudSync.isEnabled, !UserDefaults.standard.bool(forKey: Self.migratedKey) else { return }
        UserDefaults.standard.set(true, forKey: Self.migratedKey)
        let decoder = JSONDecoder()
        if let d = CloudSync.legacyValue(Self.presetsKey), let v = try? decoder.decode([Preset].self, from: d) {
            let have = Set(presets.map(\.id))
            presets += v.filter { !have.contains($0.id) }
        }
        if let d = CloudSync.legacyValue(Self.customScenesKey), let v = try? decoder.decode([CustomScene].self, from: d) {
            let have = Set(customScenes.map(\.id))
            customScenes += v.filter { !have.contains($0.id) }
        }
        if let d = CloudSync.legacyValue(Self.cctScalesKey), let v = try? decoder.decode([String: [CCTScale]].self, from: d) {
            for (mac, list) in v {
                let have = Set((cctScales[mac] ?? []).map(\.id))
                let new = list.filter { !have.contains($0.id) }
                if !new.isEmpty { cctScales[mac, default: []] += new }
            }
        }
    }
    private static let migratedKey = "cloudKeyValueLibraryTaken"

    /// Applies a change from iCloud (CloudLibrary), which isn't sent back.
    func takeFromCloud(_ change: (Library) -> Void) {
        fromCloud = true
        change(self)
        fromCloud = false
    }

    func scales(for mac: String?) -> [CCTScale] {
        guard let mac else { return [] }
        return cctScales[mac.lowercased()] ?? []
    }

    /// The scale Custom CCT uses for this bulb: the chosen one, or its first.
    func activeScale(for mac: String?) -> CCTScale? {
        let list = scales(for: mac)
        if let mac, let id = activeCCTScale[mac.lowercased()], let s = list.first(where: { $0.id == id }) { return s }
        return list.first
    }

    func setActiveScale(_ id: UUID, for mac: String) { activeCCTScale[mac.lowercased()] = id }

    /// A scale on any bulb, with that bulb's MAC.
    func scale(_ id: UUID) -> (mac: String, scale: CCTScale)? {
        for (mac, list) in cctScales { if let s = list.first(where: { $0.id == id }) { return (mac, s) } }
        return nil
    }

    func updateScale(_ scale: CCTScale, for mac: String) {
        let m = mac.lowercased()
        var list = cctScales[m] ?? []
        if let i = list.firstIndex(where: { $0.id == scale.id }) { list[i] = scale } else { list.append(scale) }
        cctScales[m] = list
    }

    func removeScale(_ id: UUID, for mac: String) {
        cctScales[mac.lowercased()]?.removeAll { $0.id == id }
    }

    func customScene(_ id: UUID) -> CustomScene? { customScenes.first { $0.id == id } }

    /// The custom scene a colour plays, if it's one.
    func customSceneOf(_ colour: LightColour) -> CustomScene? {
        if case let .custom(id, _) = colour { return customScene(id) }
        return nil
    }

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
        case let .customCCT(id, k): "\(k) K on \(scale(id)?.scale.name ?? "a deleted scale")"
        }
    }

    /// The colour in words, for VoiceOver: "warm white, 2700 K", "pale blue", or a scene's name.
    func spokenName(of colour: LightColour) -> String {
        guard let words = colour.colourName else { return name(of: colour) }
        switch colour {
        case .temp, .customCCT: return "\(words), \(name(of: colour))"
        default: return words
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
        // Sorted, so the same content always encodes the same.
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        guard let data = try? encoder.encode(value) else { return }
        UserDefaults.standard.set(data, forKey: key)
        guard !fromCloud else { return }
        switch key {
        case Self.presetsKey: CloudLibrary.shared.localChanged(.preset)
        case Self.customScenesKey: CloudLibrary.shared.localChanged(.customScene)
        case Self.cctScalesKey: CloudLibrary.shared.localChanged(.cctScale)
        default: break // which scale is in use stays on each device
        }
    }

    private static func load<T: Decodable>(_ key: String) -> T? {
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }
}
