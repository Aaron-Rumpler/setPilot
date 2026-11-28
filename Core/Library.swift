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
    var cctScales: [String: [CCTScale]] { didSet { save(cctScales, Self.cctScalesKey); onChange?(); onScalesChanged?() } }
    /// Called after the scales change (the model checks the one in use still has a range).
    @ObservationIgnored var onScalesChanged: (() -> Void)?
    var activeCCTScale: [String: UUID] { didSet { save(activeCCTScale, Self.activeCCTScaleKey) } }
    /// Called after any change (the iPhone app passes the lists on to the watch).
    @ObservationIgnored var onChange: (() -> Void)?

    init() {
        var unread: [String: [Unread]] = [:]
        presets = Self.loadList(Self.presetsKey, &unread)
        customScenes = Self.loadList(Self.customScenesKey, &unread)
        cctScales = Self.loadScales(&unread)
        activeCCTScale = Self.load(Self.activeCCTScaleKey) ?? [:]
        unreadable = unread
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

    /// Elements of each list this build can't decode (from a newer build, say), by storage key:
    /// kept as raw JSON with their place, and written back as they were, so they're never lost
    /// here or taken for deletions (CloudLibrary skips them).
    @ObservationIgnored private var unreadable: [String: [Unread]] = [:]

    private struct Unread {
        var index: Int
        var json: Any
        var id: String?
        /// For CCT scales: the bulb whose list it's in.
        var mac: String?
    }

    /// The IDs of a list's elements this build couldn't decode.
    func unreadableIDs(_ key: String) -> Set<String> { Set((unreadable[key] ?? []).compactMap(\.id)) }

    /// Stops keeping undecodable elements with these IDs (deleted in iCloud), or all of them;
    /// they go from what's stored at the list's next save.
    func forgetUnreadable(_ ids: Set<String>? = nil) {
        guard let ids else { unreadable = [:]; return }
        for key in unreadable.keys { unreadable[key]?.removeAll { $0.id.map(ids.contains) == true } }
    }

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

    func unique(_ base: String, in names: [String]) -> String {
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
        UserDefaults.standard.set(withUnreadable(data, key), forKey: key)
        guard !fromCloud else { return }
        switch key {
        case Self.presetsKey: CloudLibrary.shared.localChanged(.preset)
        case Self.customScenesKey: CloudLibrary.shared.localChanged(.customScene)
        case Self.cctScalesKey: CloudLibrary.shared.localChanged(.cctScale)
        default: break // which scale is in use syncs as a setting (CloudSync)
        }
    }

    private static func load<T: Decodable>(_ key: String) -> T? {
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    /// A list, element by element: the ones that won't decode go into `unread`, not the list.
    private static func loadList<T: Decodable>(_ key: String, _ unread: inout [String: [Unread]]) -> [T] {
        guard let data = UserDefaults.standard.data(forKey: key) else { return [] }
        guard let array = (try? JSONSerialization.jsonObject(with: data)) as? [Any] else {
            keepUnparsed(data, key)
            return []
        }
        let (list, rest): ([T], [Unread]) = decode(array, mac: nil)
        if !rest.isEmpty { unread[key] = rest }
        return list
    }

    /// CCT scales by bulb, the same way.
    private static func loadScales(_ unread: inout [String: [Unread]]) -> [String: [CCTScale]] {
        let key = cctScalesKey
        guard let data = UserDefaults.standard.data(forKey: key) else { return [:] }
        guard let lists = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              lists.values.allSatisfy({ $0 is [Any] }) else {
            keepUnparsed(data, key)
            return [:]
        }
        var out: [String: [CCTScale]] = [:]
        var rest: [Unread] = []
        for (mac, value) in lists {
            let (list, r): ([CCTScale], [Unread]) = decode(value as? [Any] ?? [], mac: mac)
            if !list.isEmpty { out[mac] = list }
            rest += r
        }
        if !rest.isEmpty { unread[key] = rest }
        return out
    }

    private static func decode<T: Decodable>(_ array: [Any], mac: String?) -> ([T], [Unread]) {
        let decoder = JSONDecoder()
        var list: [T] = []
        var rest: [Unread] = []
        for (i, element) in array.enumerated() {
            if JSONSerialization.isValidJSONObject(element), let d = try? JSONSerialization.data(withJSONObject: element),
               let v = try? decoder.decode(T.self, from: d) {
                list.append(v)
            } else {
                rest.append(Unread(index: i, json: element, id: id(of: element), mac: mac))
            }
        }
        return (list, rest)
    }

    /// Stored data that isn't a list at all: copied aside (once), as nothing of it can be kept.
    private static func keepUnparsed(_ data: Data, _ key: String) {
        let aside = key + "Unreadable"
        if UserDefaults.standard.data(forKey: aside) == nil { UserDefaults.standard.set(data, forKey: aside) }
    }

    private static func id(of element: Any) -> String? {
        ((element as? [String: Any])?["id"] as? String).flatMap { UUID(uuidString: $0)?.uuidString }
    }

    /// `data` (a list, or for CCT scales lists by bulb) with the elements this build couldn't
    /// decode put back where they were. One that decodes now (taken from iCloud since) isn't kept.
    private func withUnreadable(_ data: Data, _ key: String) -> Data {
        guard var kept = unreadable[key], !kept.isEmpty,
              let top = try? JSONSerialization.jsonObject(with: data) else { return data }
        func ids(_ list: [Any]) -> [String] { list.compactMap { Self.id(of: $0) } }
        func merged(_ list: [Any], _ extra: [Unread]) -> [Any] {
            var out = list
            for u in extra.sorted(by: { $0.index < $1.index }) { out.insert(u.json, at: min(u.index, out.count)) }
            return out
        }
        let out: Any
        if let list = top as? [Any] {
            let have = Set(ids(list))
            kept.removeAll { $0.id.map(have.contains) == true }
            out = merged(list, kept)
        } else if var lists = top as? [String: Any] {
            let have = Set(lists.values.flatMap { ids($0 as? [Any] ?? []) })
            kept.removeAll { $0.id.map(have.contains) == true }
            for (mac, extra) in Dictionary(grouping: kept, by: { $0.mac ?? "" }) {
                lists[mac] = merged(lists[mac] as? [Any] ?? [], extra)
            }
            out = lists
        } else {
            return data
        }
        unreadable[key] = kept.isEmpty ? nil : kept
        guard JSONSerialization.isValidJSONObject(out),
              let joined = try? JSONSerialization.data(withJSONObject: out, options: .sortedKeys) else { return data }
        return joined
    }
}
