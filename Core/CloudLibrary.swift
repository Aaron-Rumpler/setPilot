import Foundation
import Observation
#if WIZ_ICLOUD
import CloudKit
import CryptoKit
#endif

/// iCloud sync of the library (presets, custom scenes, CCT scales) and bulb names, item by item,
/// through CloudKit (the private database, in a zone of its own), between the Mac and iPhone apps.
/// The watch gets them from the iPhone as before. Only in builds with `WIZ_ICLOUD`; otherwise
/// `start` does nothing.
///
/// Each preset, scene, scale or name is a record of its own, so edits to different items on two
/// devices both survive, and a deletion deletes just that item. When the same item changes on both,
/// the later change wins: its content and its place in the list separately, so moving or deleting
/// one item (which shifts the ones after it) doesn't override an edit to them made elsewhere. The first sync (or the first after signing in to iCloud) uploads what's
/// here without overwriting what's already in iCloud: items in both keep iCloud's version.
///
/// It notices local changes by comparing each item with what was last synced (a hash), so the
/// library itself needs only to say that something changed.
@MainActor
final class CloudLibrary {
    static let shared = CloudLibrary()
    static let containerID = "iCloud.nz.aaronrumpler.setPilot"

    /// What the Settings section shows.
    let progress = CloudProgress()
    private var status: String {
        get { progress.status }
        set {
            if newValue != progress.status { Log.sync.info("iCloud: \(newValue, privacy: .public)") }
            progress.status = newValue
        }
    }
    private var lastSync: Date? {
        get { progress.lastSync }
        set { progress.lastSync = newValue }
    }

    enum Kind: String, CaseIterable, Sendable {
        case preset = "Preset", customScene = "CustomScene", cctScale = "CCTScale", bulbName = "BulbName"
    }

    /// One synced thing as it is here: its encoded value, its place in its list, and for CCT
    /// scales the bulb (MAC) it belongs to.
    struct Item: Equatable, Sendable {
        var data: Data
        var order: Double
        var mac: String?
    }

    #if WIZ_ICLOUD
    /// Kept between launches for each record.
    private struct Meta: Codable {
        /// The item's key here: a preset's, scene's or scale's UUID, or a bulb's MAC (which, unlike
        /// the others, isn't in the record's name: that's a hash, since record names aren't encrypted).
        var id: String
        var hash: Data
        var order: Double
        /// When the item's content last changed here, or iCloud's stamp for the version taken from it.
        var modified: Date
        /// The same for its place in its list, apart from its content: a delete or move shifts
        /// every item after it, which mustn't make their content look newer than another device's
        /// edit of it.
        var orderModified: Date
        /// CloudKit's record bookkeeping (encodeSystemFields), so saves update rather than conflict.
        var systemFields: Data?
        /// Not yet confirmed saved: queued again at launch, in case the app quit before the sync
        /// engine kept its own record of the change.
        var unsent = true
    }

    private struct Saved: Codable {
        var state: CKSyncEngine.State.Serialization?
        var meta: [String: Meta] = [:]
        /// Deletions not yet confirmed (as `unsent`).
        var deleting: Set<String> = []
        /// The library has been offered to iCloud since the last account change.
        var seeded = false
    }

    private let zoneID = CKRecordZone.ID(zoneName: "Library", ownerName: CKCurrentUserDefaultName)
    private var engine: CKSyncEngine?
    private var saved = Saved()
    private weak var model: Model?
    /// Set while applying iCloud's changes, so they aren't taken for local ones.
    private var applying = false
    /// A save failed in the current round of sending (so it isn't called up to date).
    private var sendFailed = false

    private static var fileURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("CloudLibrary.json")
    }
    #endif

    func start(model: Model) {
        #if WIZ_ICLOUD
        guard engine == nil else { return }
        self.model = model
        if let data = try? Data(contentsOf: Self.fileURL), let s = try? JSONDecoder().decode(Saved.self, from: data) {
            saved = s
        }
        let container = CKContainer(identifier: Self.containerID)
        var config = CKSyncEngine.Configuration(database: container.privateCloudDatabase,
                                                stateSerialization: saved.state, delegate: self)
        config.automaticallySync = true
        engine = CKSyncEngine(config)
        status = "Waiting for iCloud"
        if !saved.seeded {
            seed()
        } else {
            requeueUnsent()
        }
        #endif
    }

    /// The library or the bulb names changed here (not from iCloud).
    func localChanged(_ kind: Kind) {
        #if WIZ_ICLOUD
        guard let engine, !applying else { return }
        // Not offered to iCloud since its data was deleted: everything goes, not just this kind.
        guard saved.seeded else { seed(); return }
        var pending: [CKSyncEngine.PendingRecordZoneChange] = []
        let now = current(kind)
        for (id, item) in now {
            let name = Self.recordName(kind, id)
            let hash = Self.hash(item)
            if var meta = saved.meta[name] {
                guard meta.hash != hash || meta.order != item.order else { continue }
                if meta.hash != hash { meta.hash = hash; meta.modified = .now }
                if meta.order != item.order { meta.order = item.order; meta.orderModified = .now }
                meta.unsent = true
                saved.meta[name] = meta
            } else {
                saved.meta[name] = Meta(id: id, hash: hash, order: item.order, modified: .now, orderModified: .now)
            }
            saved.deleting.remove(name)
            pending.append(.saveRecord(CKRecord.ID(recordName: name, zoneID: zoneID)))
        }
        let prefix = kind.rawValue + "."
        for (name, meta) in saved.meta where name.hasPrefix(prefix) && now[meta.id] == nil {
            saved.meta.removeValue(forKey: name)
            saved.deleting.insert(name)
            pending.append(.deleteRecord(CKRecord.ID(recordName: name, zoneID: zoneID)))
        }
        guard !pending.isEmpty else { return }
        engine.state.add(pendingRecordZoneChanges: pending)
        persist()
        #endif
    }

    /// Fetches and sends now (Settings' Sync Now).
    func syncNow() async {
        #if WIZ_ICLOUD
        guard let engine else { return }
        status = "Syncing…"
        do {
            try await engine.fetchChanges()
            try await engine.sendChanges()
            finishRound()
        } catch {
            status = Self.describe(error)
        }
        #endif
    }

    #if WIZ_ICLOUD
    // MARK: Engine

    /// Offers everything here to iCloud, stamped as old so that anything iCloud already has wins.
    private func seed() {
        guard let engine else { return }
        engine.state.add(pendingDatabaseChanges: [.saveZone(CKRecordZone(zoneID: zoneID))])
        var pending: [CKSyncEngine.PendingRecordZoneChange] = []
        for kind in Kind.allCases {
            for (id, item) in current(kind) {
                let name = Self.recordName(kind, id)
                saved.meta[name] = Meta(id: id, hash: Self.hash(item), order: item.order, modified: .distantPast,
                                        orderModified: .distantPast, systemFields: saved.meta[name]?.systemFields)
                pending.append(.saveRecord(CKRecord.ID(recordName: name, zoneID: zoneID)))
            }
        }
        engine.state.add(pendingRecordZoneChanges: pending)
        saved.seeded = true
        persist()
    }

    /// Changes this device made that the engine may not have kept (the app quit straight after).
    private func requeueUnsent() {
        guard let engine else { return }
        var pending: [CKSyncEngine.PendingRecordZoneChange] = saved.meta.filter(\.value.unsent).keys.map {
            .saveRecord(CKRecord.ID(recordName: $0, zoneID: zoneID))
        }
        pending += saved.deleting.map { .deleteRecord(CKRecord.ID(recordName: $0, zoneID: zoneID)) }
        guard !pending.isEmpty else { return }
        engine.state.add(pendingDatabaseChanges: [.saveZone(CKRecordZone(zoneID: zoneID))])
        engine.state.add(pendingRecordZoneChanges: pending)
    }

    /// Signed out, or another account: forget what was synced (keeping the library here), and on
    /// signing in offer it to the account. The engine keeps going: it resets its own state.
    private func reset(reseed: Bool) {
        saved.meta = [:]
        saved.deleting = []
        saved.seeded = false
        persist()
        if reseed { seed() }
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(saved) { try? data.write(to: Self.fileURL, options: .atomic) }
    }

    /// After fetching or sending: up to date, unless a save failed (its reason stays shown until
    /// the next round of sending).
    private func finishRound() {
        lastSync = .now
        if !sendFailed { status = "Up to date" }
    }

    // MARK: Items here

    /// A record's name. Bulb names are filed under a hash of the MAC: record names are visible to
    /// Apple (not end-to-end encrypted), unlike the MAC kept in the record's encrypted fields.
    private static func recordName(_ kind: Kind, _ id: String) -> String {
        guard kind == .bulbName else { return "\(kind.rawValue).\(id)" }
        let digest = SHA256.hash(data: Data("setPilot bulb name \(id.lowercased())".utf8))
        return "\(kind.rawValue)." + digest.prefix(16).map { String(format: "%02x", $0) }.joined()
    }

    private static func kind(of name: String) -> Kind? {
        guard let dot = name.firstIndex(of: ".") else { return nil }
        return Kind(rawValue: String(name[..<dot]))
    }

    private static func hash(_ item: Item) -> Data {
        var data = item.data
        data.append(Data((item.mac ?? "").utf8))
        return Data(SHA256.hash(data: data))
    }

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = .sortedKeys // the same content always hashes the same
        return e
    }()

    private func current(_ kind: Kind) -> [String: Item] {
        guard let model else { return [:] }
        let library = model.library
        var items: [String: Item] = [:]
        switch kind {
        case .preset:
            for (i, p) in library.presets.enumerated() {
                if let d = try? Self.encoder.encode(p) { items[p.id.uuidString] = Item(data: d, order: Double(i)) }
            }
        case .customScene:
            for (i, s) in library.customScenes.enumerated() {
                if let d = try? Self.encoder.encode(s) { items[s.id.uuidString] = Item(data: d, order: Double(i)) }
            }
        case .cctScale:
            for (mac, list) in library.cctScales {
                for (i, s) in list.enumerated() {
                    if let d = try? Self.encoder.encode(s) { items[s.id.uuidString] = Item(data: d, order: Double(i), mac: mac) }
                }
            }
        case .bulbName:
            for (mac, name) in model.names { items[mac] = Item(data: Data(name.utf8), order: 0, mac: mac) }
        }
        return items
    }

    /// Puts iCloud's changes into the library: a value to add or replace, or nil to delete.
    private func apply(_ kind: Kind, _ changes: [String: Item?]) {
        guard let model, !changes.isEmpty else { return }
        let library = model.library
        applying = true
        defer { applying = false }
        func order(_ id: String, _ index: Int) -> Double {
            saved.meta[Self.recordName(kind, id)]?.order ?? Double(index)
        }
        func merged<T: Codable & Identifiable>(_ list: [T]) -> [T] where T.ID == UUID {
            var byID: [String: T] = [:]
            for item in list { byID[item.id.uuidString] = item }
            for (id, change) in changes {
                if let change, let v = try? JSONDecoder().decode(T.self, from: change.data) { byID[id] = v } else { byID[id] = nil }
            }
            let index = Dictionary(list.enumerated().map { ($1.id.uuidString, $0) }, uniquingKeysWith: { a, _ in a })
            return byID.values.sorted {
                let a = $0.id.uuidString, b = $1.id.uuidString
                let oa = order(a, index[a] ?? Int.max), ob = order(b, index[b] ?? Int.max)
                return oa == ob ? a < b : oa < ob
            }
        }
        switch kind {
        case .preset:
            library.takeFromCloud { $0.presets = merged($0.presets) }
        case .customScene:
            library.takeFromCloud { $0.customScenes = merged($0.customScenes) }
        case .cctScale:
            // Scales can move between bulbs only by being deleted and re-added, but take the MAC as given.
            var scales = library.cctScales
            for (id, change) in changes {
                for mac in scales.keys { scales[mac]?.removeAll { $0.id.uuidString == id } }
                if let change, let mac = change.mac, let v = try? JSONDecoder().decode(CCTScale.self, from: change.data) {
                    scales[mac, default: []].append(v)
                }
            }
            for mac in scales.keys {
                scales[mac]?.sort {
                    let a = $0.id.uuidString, b = $1.id.uuidString
                    let oa = order(a, 0), ob = order(b, 0)
                    return oa == ob ? a < b : oa < ob
                }
                if scales[mac]?.isEmpty == true { scales[mac] = nil }
            }
            library.takeFromCloud { $0.cctScales = scales }
        case .bulbName:
            var names = model.names
            for (mac, change) in changes { names[mac] = change.map { String(decoding: $0.data, as: UTF8.self) } }
            model.setNamesFromCloud(names)
        }
    }

    // MARK: Records

    private func record(for id: CKRecord.ID) -> CKRecord? {
        guard let kind = Self.kind(of: id.recordName), let meta = saved.meta[id.recordName],
              let item = current(kind)[meta.id] else { return nil }
        let record = meta.systemFields.flatMap(Self.record(fromSystemFields:)) ?? CKRecord(recordType: kind.rawValue, recordID: id)
        record.encryptedValues["data"] = item.data
        record.encryptedValues["mac"] = item.mac
        record["order"] = item.order
        record["modified"] = meta.modified
        record["orderModified"] = meta.orderModified
        return record
    }

    private static func systemFields(of record: CKRecord) -> Data {
        let coder = NSKeyedArchiver(requiringSecureCoding: true)
        record.encodeSystemFields(with: coder)
        coder.finishEncoding()
        return coder.encodedData
    }

    private static func record(fromSystemFields data: Data) -> CKRecord? {
        guard let coder = try? NSKeyedUnarchiver(forReadingFrom: data) else { return nil }
        coder.requiresSecureCoding = true
        defer { coder.finishDecoding() }
        return CKRecord(coder: coder)
    }

    /// The item key a record's name stands for (for a bulb name, from what's known here).
    private func itemID(_ name: String, _ kind: Kind) -> String? {
        if let meta = saved.meta[name] { return meta.id }
        return kind == .bulbName ? nil : String(name.dropFirst(kind.rawValue.count + 1))
    }

    /// iCloud's version of a record. Its content and its place are each taken unless this
    /// device's own change to that part is newer (then ours is sent again on top). A deletion here
    /// still to go up wins over an edit from elsewhere. Returns the change to apply, if any.
    private func take(_ record: CKRecord) -> (Kind, String, Item)? {
        let name = record.recordID.recordName
        guard let kind = Self.kind(of: name), let data: Data = record.encryptedValues["data"] else { return nil }
        let mac: String? = record.encryptedValues["mac"]
        guard let id = kind == .bulbName ? mac : itemID(name, kind), !id.isEmpty else { return nil }
        if saved.deleting.contains(name) { return nil }
        let remote = Item(data: data, order: record["order"] as? Double ?? 0, mac: mac)
        let modified = record["modified"] as? Date ?? .distantPast
        let orderModified = record["orderModified"] as? Date ?? modified
        let remoteHash = Self.hash(remote)
        let fields = Self.systemFields(of: record)
        guard var meta = saved.meta[name] else {
            saved.meta[name] = Meta(id: id, hash: remoteHash, order: remote.order, modified: modified,
                                    orderModified: orderModified, systemFields: fields, unsent: false)
            return (kind, id, remote)
        }
        let keepContent = meta.modified > modified && meta.hash != remoteHash
        let keepOrder = meta.orderModified > orderModified && meta.order != remote.order
        meta.systemFields = fields
        if !keepContent { meta.hash = remoteHash; meta.modified = modified }
        if !keepOrder { meta.order = remote.order; meta.orderModified = orderModified }
        meta.unsent = keepContent || keepOrder
        saved.meta[name] = meta
        if meta.unsent { engine?.state.add(pendingRecordZoneChanges: [.saveRecord(record.recordID)]) }
        if keepContent && keepOrder { return nil }
        let mine = current(kind)[id]
        let content = keepContent ? (mine ?? remote) : remote
        return (kind, id, Item(data: content.data, order: meta.order, mac: content.mac))
    }

    private func handle(_ event: CKSyncEngine.Event) {
        switch event {
        case .stateUpdate(let e):
            saved.state = e.stateSerialization
            persist()

        case .accountChange(let e):
            switch e.changeType {
            case .signIn: reset(reseed: true)
            // Another Apple ID: what's here is offered to it as on signing in (see needs-you).
            case .switchAccounts: reset(reseed: true)
            case .signOut: reset(reseed: false); status = "Not signed in to iCloud"
            @unknown default: break
            }

        case .fetchedDatabaseChanges(let e):
            // The zone deleted (iCloud's data removed in Settings, say): forget what was synced.
            // The library here stays, and all of it goes up again with the next change here.
            if e.deletions.contains(where: { $0.zoneID == zoneID }) {
                saved.meta = [:]
                saved.deleting = []
                saved.seeded = false
                persist()
            }

        case .fetchedRecordZoneChanges(let e):
            var changes: [Kind: [String: Item?]] = [:]
            for m in e.modifications {
                if let (kind, id, item) = take(m.record) { changes[kind, default: [:]].updateValue(item, forKey: id) }
            }
            for d in e.deletions {
                let name = d.recordID.recordName
                saved.deleting.remove(name)
                guard let kind = Self.kind(of: name), let id = itemID(name, kind) else { continue }
                saved.meta.removeValue(forKey: name)
                changes[kind, default: [:]].updateValue(nil, forKey: id)
            }
            for (kind, c) in changes { apply(kind, c) }
            persist()

        case .willSendChanges:
            sendFailed = false

        case .sentRecordZoneChanges(let e):
            for record in e.savedRecords {
                saved.meta[record.recordID.recordName]?.systemFields = Self.systemFields(of: record)
                saved.meta[record.recordID.recordName]?.unsent = false
            }
            for id in e.deletedRecordIDs { saved.deleting.remove(id.recordName) }
            for (id, error) in e.failedRecordDeletes where error.code == .unknownItem || error.code == .zoneNotFound {
                saved.deleting.remove(id.recordName) // already gone
            }
            var retry: [CKSyncEngine.PendingRecordZoneChange] = []
            var changes: [Kind: [String: Item?]] = [:]
            for failure in e.failedRecordSaves {
                let id = failure.record.recordID
                switch failure.error.code {
                case .serverRecordChanged:
                    // Changed elsewhere since we last saw it: the later change wins, part by part.
                    if let server = failure.error.serverRecord, let (kind, itemID, item) = take(server) {
                        changes[kind, default: [:]].updateValue(item, forKey: itemID)
                    }
                case .zoneNotFound:
                    engine?.state.add(pendingDatabaseChanges: [.saveZone(CKRecordZone(zoneID: zoneID))])
                    retry.append(.saveRecord(id))
                case .unknownItem:
                    // Gone from iCloud: save it afresh.
                    saved.meta[id.recordName]?.systemFields = nil
                    retry.append(.saveRecord(id))
                case .networkFailure, .networkUnavailable, .zoneBusy, .serviceUnavailable, .notAuthenticated,
                     .operationCancelled, .requestRateLimited:
                    break // the engine tries again by itself
                default:
                    sendFailed = true
                    status = Self.describe(failure.error)
                }
            }
            if !retry.isEmpty { engine?.state.add(pendingRecordZoneChanges: retry) }
            for (kind, c) in changes { apply(kind, c) }
            persist()

        case .didFetchChanges, .didSendChanges:
            finishRound()

        default:
            break
        }
    }

    private static func describe(_ error: Error) -> String {
        if let ck = error as? CKError {
            switch ck.code {
            case .notAuthenticated: return "Not signed in to iCloud"
            case .quotaExceeded: return "iCloud storage is full"
            case .networkFailure, .networkUnavailable: return "Waiting for the network"
            default: break
            }
        }
        return "iCloud: \(error.localizedDescription)"
    }
    #endif
}

#if WIZ_ICLOUD
extension CloudLibrary: CKSyncEngineDelegate {
    nonisolated func handleEvent(_ event: CKSyncEngine.Event, syncEngine: CKSyncEngine) async {
        await MainActor.run { self.handle(event) }
    }

    nonisolated func nextRecordZoneChangeBatch(_ context: CKSyncEngine.SendChangesContext,
                                               syncEngine: CKSyncEngine) async -> CKSyncEngine.RecordZoneChangeBatch? {
        let scope = context.options.scope
        let changes = syncEngine.state.pendingRecordZoneChanges.filter { scope.contains($0) }
        return await CKSyncEngine.RecordZoneChangeBatch(pendingChanges: changes) { id in
            await MainActor.run {
                let record = self.record(for: id)
                // Gone since it was queued (deleted here or elsewhere): drop it rather than offer it again.
                if record == nil { syncEngine.state.remove(pendingRecordZoneChanges: [.saveRecord(id)]) }
                return record
            }
        }
    }
}
#endif

/// How iCloud sync is going, for Settings.
@MainActor @Observable
final class CloudProgress {
    var status = "Not started"
    var lastSync: Date?
}
