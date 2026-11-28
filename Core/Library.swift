import Foundation

/// Presets, custom scenes and CCT scales, kept on this device (as JSON in user defaults) and,
/// in builds with iCloud, synced item by item through it (CloudLibrary).
@MainActor @Observable
final class Library {
    static let presetsKey = "presets"
    static let customScenesKey = "customScenes"
    static let cctScalesKey = "cctScales"
    static let activeCCTScaleKey = "activeCCTScale"

    var presets: [Preset] {
        didSet { dropExtras(of: oldValue.map(\.id), keeping: presets.map(\.id)); save(presets, Self.presetsKey); onChange?() }
    }
    var customScenes: [CustomScene] {
        didSet { dropExtras(of: oldValue.map(\.id), keeping: customScenes.map(\.id)); save(customScenes, Self.customScenesKey); onChange?() }
    }
    /// Custom CCT scales per bulb (keyed by lower-case MAC), and the one in use for each.
    var cctScales: [String: [CCTScale]] {
        didSet {
            // Across bulbs, so a scale moved to another bulb in one change keeps them.
            dropExtras(of: oldValue.values.flatMap { $0.map(\.id) }, keeping: cctScales.values.flatMap { $0.map(\.id) })
            save(cctScales, Self.cctScalesKey); onChange?(); onScalesChanged?()
        }
    }
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
    @ObservationIgnored private var extras: [String: [String: Extra]] = [:]

    /// A field a newer build added, at any depth: a step's or a point's as well as an item's.
    private enum Extra {
        /// A field this build doesn't have: put back as it was.
        case value(Any)
        /// One it has, which is an object: its own fields' extras.
        case fields([String: Extra])
        /// One it has, which is a list: its elements' extras, by their ID (by place, "#0", for
        /// elements without one).
        case elements([String: [String: Extra]])
    }

    /// Storage keys whose data is JSON but not a list (a newer build's format, say), with the IDs
    /// found in it: left as stored, with nothing saved over it (or sent to iCloud) until a build
    /// that can read it. Observed: the list's views say so, and don't add or edit meanwhile.
    private var unparsed: [String: Set<String>] = [:]

    /// Bulbs whose CCT scales are stored as something other than a list: kept as they were, by
    /// MAC. Scales made or taken for them meanwhile are kept aside (`heldKey`), not over them.
    @ObservationIgnored private var rawScales: [String: Any] = [:]

    /// What loading found, besides the lists.
    private struct Loaded {
        var unread: [String: [Unread]] = [:]
        var extras: [String: [String: Extra]] = [:]
        var unparsed: [String: Set<String>] = [:]
        var rawScales: [String: Any] = [:]
    }

    /// Where a list's items are kept aside while its stored data can't take them: all of them
    /// while it can't be read (`unparsed`), or for CCT scales those of bulbs kept raw. Shown
    /// meanwhile, and put back in the list once it can be read.
    private static func heldKey(_ key: String) -> String { key + "Held" }

    /// The IDs of a list's elements this build couldn't decode (or found in data it can't read).
    func unreadableIDs(_ key: String) -> Set<String> {
        var ids = Set((unreadable[key] ?? []).compactMap(\.id))
        ids.formUnion(unparsed[key] ?? [])
        if key == Self.cctScalesKey { for raw in rawScales.values { ids.formUnion(Self.ids(in: raw)) } }
        return ids
    }

    /// Whether a list's stored data can't be read at all (CloudLibrary deletes none of its items).
    func isUnparsed(_ key: String) -> Bool { unparsed[key] != nil }

    /// Bulbs (lower-case MACs) whose stored CCT scales aren't a list: CloudLibrary deletes none
    /// of their scales, as what's here for them may not be all there is.
    var rawScaleMACs: Set<String> { Set(rawScales.keys.map { $0.lowercased() }) }

    /// Whether a list can be added to and edited here: not while its stored data is a newer
    /// build's that this one can't read (nothing made meanwhile would reach that data, or iCloud).
    func canEdit(_ key: String) -> Bool { unparsed[key] == nil }

    /// For a list this build can't read: why it looks empty, to show in its place.
    func newerNote(_ key: String) -> String? {
        guard unparsed[key] != nil else { return nil }
        let what = switch key {
        case Self.presetsKey: "presets"
        case Self.customScenesKey: "custom scenes"
        default: "CCT scales"
        }
        return "Your \(what) were saved by a newer version of setPilot. Update setPilot on this device to see and edit them."
    }

    /// Stops keeping undecodable elements with these IDs (deleted in iCloud), or all of them;
    /// they go from what's stored at the list's next save.
    func forgetUnreadable(_ ids: Set<String>? = nil) {
        guard let ids else {
            unreadable = [:]
            unparsed = [:]
            rawScales = [:]
            extras = [:]
            return
        }
        for key in unreadable.keys { unreadable[key]?.removeAll { $0.id.map(ids.contains) == true } }
        for id in ids { extras[id] = nil }
    }

    /// For a bulb whose stored CCT scales aren't a list (a newer build's): why some may be
    /// missing, and that what's made meanwhile is stored apart (it syncs: the list is saved, and
    /// in iCloud's `current`). The whole list's note first.
    func newerNote(forScalesOf mac: String?) -> String? {
        if let note = newerNote(Self.cctScalesKey) { return note }
        guard let mac, rawScaleMACs.contains(mac.lowercased()) else { return nil }
        // Synced only in a build with iCloud (one without may still have them, after a downgrade).
        let kept = CloudSync.isEnabled ? "are kept apart from the ones the newer version saved, and still sync," : "are kept apart from the ones the newer version saved"
        return "Some of this bulb's CCT scales were saved by a newer version of setPilot, so they aren't shown. Scales made or changed here \(kept) until setPilot is updated on this device."
    }

    /// Stops keeping a newer build's fields for items no longer in a list (deleted here), so a
    /// copy with the same ID added later doesn't pick them up.
    private func dropExtras(of old: [UUID], keeping new: [UUID]) {
        guard !extras.isEmpty else { return }
        for id in Set(old).subtracting(new) { extras[id.uuidString] = nil }
    }

    /// Takes an incoming item's newer-build fields from `data` (the item as it came in a file or
    /// link) in place of any kept for its ID: the copy that replaces another brings its own, or
    /// none. Under `value`'s ID, which may be new (a copy's).
    func takeExtras<T: Encodable & Identifiable>(_ data: Data?, of value: T) where T.ID == UUID {
        let element = data.flatMap { try? JSONSerialization.jsonObject(with: $0) }
        extras[value.id.uuidString] = element.flatMap { Self.unknownFields($0, of: value) }
    }

    /// Gives a duplicate the original's newer-build fields, as import's Keep Both does, so the
    /// copy syncs with them. `ids` maps the original's step or point IDs to the copy's.
    func copyExtras(from original: UUID, to copy: UUID, remapping ids: [UUID: UUID]) {
        guard let more = extras[original.uuidString] else { return }
        let keys = Dictionary(ids.map { ($0.key.uuidString, $0.value.uuidString) }, uniquingKeysWith: { a, _ in a })
        extras[copy.uuidString] = Self.remapped(more, keys)
    }

    /// Extras with their elements' ID keys changed by `keys`, at any depth.
    private static func remapped(_ more: [String: Extra], _ keys: [String: String]) -> [String: Extra] {
        more.mapValues { extra -> Extra in
            switch extra {
            case .value: return extra
            case .fields(let fields): return .fields(remapped(fields, keys))
            case .elements(let byKey):
                return .elements(Dictionary(byKey.map { (keys[$0.key] ?? $0.key, remapped($0.value, keys)) },
                                            uniquingKeysWith: { a, _ in a }))
            }
        }
    }

    /// A library file as JSON, with the fields a newer build added to its items put back, so the
    /// device that takes it (and iCloud, if it replaces its copies with these) keeps them.
    func encoded(_ file: LibraryFile, pretty: Bool = false) -> Data? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = pretty ? [.prettyPrinted, .sortedKeys] : .sortedKeys
        guard let data = try? encoder.encode(file) else { return nil }
        guard !extras.isEmpty, var top = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return data }
        for key in ["presets", "customScenes"] {
            if let list = top[key] as? [Any] { top[key] = list.map(addingExtras) }
        }
        if let lists = top["cctScales"] as? [String: Any] {
            top["cctScales"] = lists.mapValues { value -> Any in
                guard let list = value as? [Any] else { return value }
                return list.map(addingExtras)
            }
        }
        let options: JSONSerialization.WritingOptions = pretty ? [.prettyPrinted, .sortedKeys] : .sortedKeys
        guard JSONSerialization.isValidJSONObject(top),
              let out = try? JSONSerialization.data(withJSONObject: top, options: options) else { return data }
        return out
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
        let defaults = UserDefaults.standard
        var held: [String: Any] = [:]
        let out = withUnreadable(data, key, held: &held)
        // Stored data this build can't read at all stays as it is: nothing's written over it, or
        // sent to iCloud from it. What's taken meanwhile (from iCloud, say) is kept aside.
        guard unparsed[key] == nil else {
            defaults.set(out, forKey: Self.heldKey(key))
            return
        }
        defaults.set(out, forKey: key)
        if key == Self.cctScalesKey, !held.isEmpty, JSONSerialization.isValidJSONObject(held),
           let d = try? JSONSerialization.data(withJSONObject: held, options: .sortedKeys) {
            defaults.set(d, forKey: Self.heldKey(key))
        } else if Self.listKeys.contains(key) {
            defaults.removeObject(forKey: Self.heldKey(key)) // in the list now, or deleted
        }
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

    private static let listKeys = [presetsKey, customScenesKey, cctScalesKey]

    /// A list, element by element: the ones that won't decode go into `unread`, not the list.
    /// Any kept aside (`heldKey`) are added.
    private static func loadList<T: Codable & Identifiable>(_ key: String, _ loaded: inout Loaded) -> [T] where T.ID == UUID {
        var list: [T] = []
        if let data = UserDefaults.standard.data(forKey: key) {
            if let top = try? JSONSerialization.jsonObject(with: data) {
                if let array = top as? [Any] {
                    let (l, rest): ([T], [Unread]) = decode(array, mac: nil, &loaded)
                    list = l
                    if !rest.isEmpty { loaded.unread[key] = rest }
                } else {
                    loaded.unparsed[key] = ids(in: top)
                }
            } else {
                keepUnparsed(data, key)
            }
        }
        if let array = held(key) as? [Any] {
            let (more, rest): ([T], [Unread]) = decode(array, mac: nil, &loaded)
            let have = Set(list.map(\.id))
            list += more.filter { !have.contains($0.id) }
            if !rest.isEmpty { loaded.unread[key, default: []] += rest }
        }
        return list
    }

    /// CCT scales by bulb, the same way; a bulb's that aren't a list are kept raw (`rawScales`).
    private static func loadScales(_ loaded: inout Loaded) -> [String: [CCTScale]] {
        let key = cctScalesKey
        var out: [String: [CCTScale]] = [:]
        var rest: [Unread] = []
        if let data = UserDefaults.standard.data(forKey: key) {
            if let top = try? JSONSerialization.jsonObject(with: data) {
                if let lists = top as? [String: Any] {
                    for (mac, value) in lists {
                        guard let array = value as? [Any] else {
                            loaded.rawScales[mac] = value
                            continue
                        }
                        let (list, r): ([CCTScale], [Unread]) = decode(array, mac: mac, &loaded)
                        if !list.isEmpty { out[mac] = list }
                        rest += r
                    }
                } else {
                    loaded.unparsed[key] = ids(in: top)
                }
            } else {
                keepUnparsed(data, key)
            }
        }
        // Kept aside: with the bulb's own again if they can be read now, or shown as before.
        if let lists = held(key) as? [String: Any] {
            for (mac, value) in lists {
                guard let array = value as? [Any] else { continue }
                let (more, r): ([CCTScale], [Unread]) = decode(array, mac: mac, &loaded)
                let have = Set((out[mac] ?? []).map(\.id))
                let new = more.filter { !have.contains($0.id) }
                if !new.isEmpty { out[mac, default: []] += new }
                rest += r
            }
        }
        if !rest.isEmpty { loaded.unread[key] = rest }
        return out
    }

    /// What's kept aside for a list (`heldKey`), as JSON.
    private static func held(_ key: String) -> Any? {
        UserDefaults.standard.data(forKey: heldKey(key)).flatMap { try? JSONSerialization.jsonObject(with: $0) }
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
    private static func unknownFields<T: Encodable>(_ element: Any, of value: T) -> [String: Extra]? {
        guard let mine = try? JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) else { return nil }
        return unknownFields(element, mine: mine)
    }

    /// The fields of an object that `mine` (the same, as encoded here) hasn't, at any depth.
    private static func unknownFields(_ element: Any, mine: Any) -> [String: Extra]? {
        guard let dict = element as? [String: Any], let known = mine as? [String: Any] else { return nil }
        var out: [String: Extra] = [:]
        for (k, v) in dict {
            guard let m = known[k] else {
                out[k] = .value(v)
                continue
            }
            if let more = unknownFields(v, mine: m) {
                out[k] = .fields(more)
            } else if let list = v as? [Any], let mineList = m as? [Any] {
                // Elements by ID (steps, points), so a step moved or deleted here keeps its own.
                let byID = Dictionary(mineList.enumerated().map { (elementKey($1, $0), $1) }, uniquingKeysWith: { a, _ in a })
                var elements: [String: [String: Extra]] = [:]
                for (i, e) in list.enumerated() {
                    let key = elementKey(e, i)
                    if let m = byID[key], let more = unknownFields(e, mine: m) { elements[key] = more }
                }
                if !elements.isEmpty { out[k] = .elements(elements) }
            }
        }
        return out.isEmpty ? nil : out
    }

    /// A list element's ID, or for one without, its place.
    private static func elementKey(_ element: Any, _ index: Int) -> String { id(of: element) ?? "#\(index)" }

    /// `element` with these fields put back, where it still has what they were in (none it has now).
    private static func adding(_ more: [String: Extra], to element: Any) -> Any {
        guard var dict = element as? [String: Any] else { return element }
        for (k, extra) in more {
            switch extra {
            case .value(let v):
                if dict[k] == nil { dict[k] = v }
            case .fields(let fields):
                if let v = dict[k] { dict[k] = adding(fields, to: v) }
            case .elements(let byKey):
                if let list = dict[k] as? [Any] {
                    dict[k] = list.enumerated().map { i, e in byKey[elementKey(e, i)].map { adding($0, to: e) } ?? e }
                }
            }
        }
        return dict
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
        guard let id = Self.id(of: element), let more = extras[id] else { return element }
        return Self.adding(more, to: element)
    }

    /// `data` (a list, or for CCT scales lists by bulb) with the elements this build couldn't
    /// decode put back where they were. One that decodes now (taken from iCloud since) isn't kept.
    /// The fields a newer build added to the others go back too, and a bulb's scales kept raw;
    /// the scales here for that bulb go in `held`, to keep aside.
    private func withUnreadable(_ data: Data, _ key: String, held: inout [String: Any]) -> Data {
        // The lists only (not which scale is in use).
        guard Self.listKeys.contains(key) else { return data }
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
            for (mac, value) in raw {
                if let mine = lists[mac] as? [Any], !mine.isEmpty { held[mac] = mine }
                lists[mac] = value
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
