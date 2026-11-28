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
        var loaded = Loaded()
        presets = Self.loadList(Self.presetsKey, &loaded)
        customScenes = Self.loadList(Self.customScenesKey, &loaded)
        cctScales = Self.loadScales(&loaded)
        activeCCTScale = Self.load(Self.activeCCTScaleKey) ?? [:]
        unreadable = loaded.unread
        extras = loaded.extras
        unparsed = loaded.unparsed
        rawScales = loaded.rawScales
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

    /// Fields of decoded elements this build doesn't know (a newer build's), by ID: put back
    /// when they're saved or sent to iCloud, so they aren't lost here or on other devices.
    @ObservationIgnored private var extras: [String: [String: Any]] = [:]

    /// Storage keys whose data is JSON but not a list (a newer build's format, say), with the IDs
    /// found in it: left as stored, with nothing saved over it (or sent to iCloud) until a build
    /// that can read it.
    @ObservationIgnored private var unparsed: [String: Set<String>] = [:]

    /// Bulbs whose CCT scales are stored as something other than a list: kept as they were, by
    /// MAC (written back over any made here meanwhile, which would mean losing the newer build's).
    @ObservationIgnored private var rawScales: [String: Any] = [:]

    /// What loading found, besides the lists.
    private struct Loaded {
        var unread: [String: [Unread]] = [:]
        var extras: [String: [String: Any]] = [:]
        var unparsed: [String: Set<String>] = [:]
        var rawScales: [String: Any] = [:]
    }

    /// The IDs of a list's elements this build couldn't decode (or found in data it can't read).
    func unreadableIDs(_ key: String) -> Set<String> {
        var ids = Set((unreadable[key] ?? []).compactMap(\.id))
        ids.formUnion(unparsed[key] ?? [])
        if key == Self.cctScalesKey { for raw in rawScales.values { ids.formUnion(Self.ids(in: raw)) } }
        return ids
    }

    /// Whether a list's stored data can't be read at all (CloudLibrary deletes none of its items).
    func isUnparsed(_ key: String) -> Bool { unparsed[key] != nil }

    /// Stops keeping undecodable elements with these IDs (deleted in iCloud), or all of them;
    /// they go from what's stored at the list's next save.
    func forgetUnreadable(_ ids: Set<String>? = nil) {
        guard let ids else {
            unreadable = [:]
            unparsed = [:]
            rawScales = [:]
            return
        }
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
        // Stored data this build can't read at all stays as it is: nothing's written over it, or
        // sent to iCloud from it.
        guard unparsed[key] == nil else { return }
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
    private static func loadList<T: Codable>(_ key: String, _ loaded: inout Loaded) -> [T] {
        guard let data = UserDefaults.standard.data(forKey: key) else { return [] }
        guard let top = try? JSONSerialization.jsonObject(with: data) else {
            keepUnparsed(data, key)
            return []
        }
        guard let array = top as? [Any] else {
            loaded.unparsed[key] = ids(in: top)
            return []
        }
        let (list, rest): ([T], [Unread]) = decode(array, mac: nil, &loaded)
        if !rest.isEmpty { loaded.unread[key] = rest }
        return list
    }

    /// CCT scales by bulb, the same way; a bulb's that aren't a list are kept raw (`rawScales`).
    private static func loadScales(_ loaded: inout Loaded) -> [String: [CCTScale]] {
        let key = cctScalesKey
        guard let data = UserDefaults.standard.data(forKey: key) else { return [:] }
        guard let top = try? JSONSerialization.jsonObject(with: data) else {
            keepUnparsed(data, key)
            return [:]
        }
        guard let lists = top as? [String: Any] else {
            loaded.unparsed[key] = ids(in: top)
            return [:]
        }
        var out: [String: [CCTScale]] = [:]
        var rest: [Unread] = []
        for (mac, value) in lists {
            guard let array = value as? [Any] else {
                loaded.rawScales[mac] = value
                continue
            }
            let (list, r): ([CCTScale], [Unread]) = decode(array, mac: mac, &loaded)
            if !list.isEmpty { out[mac] = list }
            rest += r
        }
        if !rest.isEmpty { loaded.unread[key] = rest }
        return out
    }

    private static func decode<T: Codable>(_ array: [Any], mac: String?, _ loaded: inout Loaded) -> ([T], [Unread]) {
        let decoder = JSONDecoder()
        var list: [T] = []
        var rest: [Unread] = []
        for (i, element) in array.enumerated() {
            if JSONSerialization.isValidJSONObject(element), let d = try? JSONSerialization.data(withJSONObject: element),
               let v = try? decoder.decode(T.self, from: d) {
                list.append(v)
                if let id = id(of: element), let more = unknownFields(element, of: v) { loaded.extras[id] = more }
            } else {
                rest.append(Unread(index: i, json: element, id: id(of: element), mac: mac))
            }
        }
        return (list, rest)
    }

    /// Stored data that isn't JSON at all (damaged): copied aside, each different copy found, as
    /// nothing of it can be kept; the list starts again.
    private static func keepUnparsed(_ data: Data, _ key: String) {
        let aside = key + "Unreadable"
        let defaults = UserDefaults.standard
        // (Earlier builds kept one copy, as data.)
        var copies = defaults.array(forKey: aside) as? [Data] ?? defaults.data(forKey: aside).map { [$0] } ?? []
        guard !copies.contains(data) else { return }
        copies.append(data)
        defaults.set(copies, forKey: aside)
    }

    /// The fields of `element` that `value`, decoded from it, doesn't encode: a newer build's.
    private static func unknownFields<T: Encodable>(_ element: Any, of value: T) -> [String: Any]? {
        guard let dict = element as? [String: Any],
              let mine = (try? JSONSerialization.jsonObject(with: JSONEncoder().encode(value))) as? [String: Any] else { return nil }
        let unknown = dict.filter { mine[$0.key] == nil }
        return unknown.isEmpty ? nil : unknown
    }

    private static func id(of element: Any) -> String? {
        ((element as? [String: Any])?["id"] as? String).flatMap { UUID(uuidString: $0)?.uuidString }
    }

    /// Every element ID anywhere in data this build can't read, so none is taken for deleted.
    private static func ids(in value: Any?) -> Set<String> {
        if let dict = value as? [String: Any] {
            return dict.values.reduce(Set(id(of: dict).map { [$0] } ?? [])) { $0.union(ids(in: $1)) }
        }
        if let list = value as? [Any] { return list.reduce(Set<String>()) { $0.union(ids(in: $1)) } }
        return []
    }

    /// Notes the fields of `data` (an item as synced) that `value`, decoded from it, doesn't keep.
    func noteExtras<T: Encodable>(_ data: Data, of value: T) {
        guard let element = try? JSONSerialization.jsonObject(with: data), let id = Self.id(of: element) else { return }
        extras[id] = Self.unknownFields(element, of: value)
    }

    /// An item's data as encoded here (to send to iCloud), with any fields a newer build added
    /// put back.
    func withExtras(_ data: Data) -> Data {
        guard !extras.isEmpty, let element = try? JSONSerialization.jsonObject(with: data),
              let id = Self.id(of: element), extras[id] != nil,
              let out = try? JSONSerialization.data(withJSONObject: addingExtras(element), options: .sortedKeys) else { return data }
        return out
    }

    /// An element with the fields a newer build added put back (none it has now replaced).
    private func addingExtras(_ element: Any) -> Any {
        guard var dict = element as? [String: Any], let id = Self.id(of: dict), let more = extras[id] else { return element }
        for (k, v) in more where dict[k] == nil { dict[k] = v }
        return dict
    }

    /// `data` (a list, or for CCT scales lists by bulb) with the elements this build couldn't
    /// decode put back where they were. One that decodes now (taken from iCloud since) isn't kept.
    /// The fields a newer build added to the others go back too, and a bulb's scales kept raw.
    private func withUnreadable(_ data: Data, _ key: String) -> Data {
        // The lists only (not which scale is in use).
        guard [Self.presetsKey, Self.customScenesKey, Self.cctScalesKey].contains(key) else { return data }
        var kept = unreadable[key] ?? []
        let raw = key == Self.cctScalesKey ? rawScales : [:]
        guard !kept.isEmpty || !extras.isEmpty || !raw.isEmpty,
              let top = try? JSONSerialization.jsonObject(with: data) else { return data }
        func ids(_ list: [Any]) -> [String] { list.compactMap { Self.id(of: $0) } }
        func merged(_ list: [Any], _ extra: [Unread]) -> [Any] {
            var out = list.map(addingExtras)
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
            let byMAC = Dictionary(grouping: kept, by: { $0.mac ?? "" })
            for mac in Set(lists.keys).union(byMAC.keys) {
                lists[mac] = merged(lists[mac] as? [Any] ?? [], byMAC[mac] ?? [])
            }
            for (mac, value) in raw { lists[mac] = value }
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
