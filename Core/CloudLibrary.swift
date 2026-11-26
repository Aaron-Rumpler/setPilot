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
        case signingKey = "SigningKey", knownBulb = "KnownBulb"

        /// Kinds keyed by a MAC or an address: their record names are a hash of it (record names
        /// aren't encrypted), the key itself kept in the record's encrypted fields.
        var hashed: Bool { self == .bulbName || self == .signingKey || self == .knownBulb }
    }

    /// One synced thing as it is here: its encoded value, its place in its list, and for CCT
    /// scales the bulb (MAC) it belongs to.
    struct Item: Codable, Equatable, Sendable {
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
        /// A household library shared with this account (iCloud sharing), synced instead of its own.
        var shared: SharedZone?
        /// iCloud is now another Apple ID and the question about this device's library is still
        /// open: nothing is offered to the account until it's answered (kept over a relaunch).
        var switchPending: Bool?
        /// iCloud's versions this build can't read (from a newer build), by record name: neither
        /// taken nor overwritten nor deleted here, and tried again at launch (after an update).
        var unreadable: [String: Item]?
        /// How the account joined a household, as the device that joined left it in the account's
        /// own library (HouseholdJoin): for this device to join it too, without losing what it has
        /// that the other didn't, or bringing back what's been removed since.
        var householdJoin: HouseholdJoin?
        /// The household this device was in when an account change (signing out, say) took it out,
        /// and what it had of it: rejoining that one, those items are the household's, not new.
        var householdSeen: SeenHousehold?
        /// A household found that the question about joining it is waiting on (HouseholdQuestion).
        var pendingHousehold: SharedZone?
        /// Back in the account's own library after a household (MirrorPlan), until the first fetch.
        var mirroring: MirrorPlan?
    }

    /// Left in the account's own library by the device that joined a household: which, how, and
    /// the library as it was then (record name, when last changed). The account's other devices
    /// join it too, adding only what they have that's new since (not on that list, or changed
    /// after): automatically if it was joined adding, asking if it was joined replacing. What's on
    /// the list is never added again, so what's been removed from the household since stays so.
    struct HouseholdJoin: Codable, Equatable {
        var zone: SharedZone
        var addMine: Bool
        var items: [String: Date]
    }
    /// A household this device had, as it was when it was taken out (householdSeen): its items
    /// (record name, when last changed in the household), and changes made here to it that
    /// hadn't gone up yet, which go up on rejoining.
    struct SeenHousehold: Codable {
        var zone: SharedZone
        var items: [String: Date]
        /// Changes made here that hadn't gone up: as they were (the account's own library, synced
        /// before rejoining, may hold an older copy), with when they were made.
        var changed: [String: SeenChange] = [:]
        var deleted: Set<String> = []
    }

    /// Going back to the account's own library from a household: what's here is offered with the
    /// times its items were last changed in the household (so a newer edit, made in the own library
    /// by a device that hadn't followed, still wins), and what the own library has from before
    /// the join, unchanged since and no longer here (removed in the household), is deleted.
    struct MirrorPlan: Codable {
        var stamps: [String: Date]
        /// The library as it was at the join (the join record's): only those may be deleted.
        var joinItems: [String: Date]
    }

    struct SeenChange: Codable {
        var kind: String
        var id: String
        var item: Item
        var modified: Date
        /// The item's hash then: changed again since (here, signed out), the item as it is now goes.
        var hash: Data?
    }
    private static let joinRecordType = "HouseholdJoin"
    private static let joinRecordName = "householdJoin"

    struct SharedZone: Codable, Equatable {
        var zoneName: String
        var ownerName: String
    }

    private static let ownZone = CKRecordZone.ID(zoneName: "Library", ownerName: CKCurrentUserDefaultName)
    /// This account's library, or the household's it has joined.
    private var zoneID: CKRecordZone.ID {
        saved.shared.map { CKRecordZone.ID(zoneName: $0.zoneName, ownerName: $0.ownerName) } ?? Self.ownZone
    }
    private var container: CKContainer { CKContainer(identifier: Self.containerID) }
    private var engine: CKSyncEngine?
    /// The engine was made without saved state, and hasn't reported an account change yet.
    private var engineFresh = false
    private var householdLookup: Task<HouseholdLookup, Never>?
    /// Account changes so far (sign in, out, another Apple ID), to tell one happened during a wait.
    private var accountChanges = 0
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
        makeEngine()
        if saved.switchPending == true {
            progress.accountSwitched = true
        } else if !saved.seeded {
            seed()
        } else {
            requeueUnsent()
        }
        retryUnreadable()
        Task { await findHousehold() }
        #endif
    }

    /// The library or the bulb names changed here (not from iCloud).
    func localChanged(_ kind: Kind) {
        #if WIZ_ICLOUD
        guard let engine, !applying else { return }
        // Not offered to iCloud since its data was deleted: everything goes, not just this kind.
        guard saved.seeded else {
            if saved.switchPending != true { seed() } // not before the question's answered
            return
        }
        var pending: [CKSyncEngine.PendingRecordZoneChange] = []
        let now = current(kind)
        let unreadable = saved.unreadable ?? [:]
        for (id, item) in now {
            let name = Self.recordName(kind, id)
            guard unreadable[name] == nil else { continue } // iCloud's is newer than this build
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
        for (name, meta) in saved.meta where name.hasPrefix(prefix) && now[meta.id] == nil && unreadable[name] == nil {
            saved.meta.removeValue(forKey: name)
            saved.deleting.insert(name)
            pending.append(.deleteRecord(CKRecord.ID(recordName: name, zoneID: zoneID)))
        }
        guard !pending.isEmpty else { return }
        engine.state.add(pendingRecordZoneChanges: pending)
        persist()
        #endif
    }

    enum AccountChoice { case merge, keepHereOnly, replace }

    /// The answer to "iCloud is now another Apple ID": add what's here to it, keep it on this
    /// device only (until an item is changed), or replace it with that account's.
    func resolveAccountSwitch(_ choice: AccountChoice) {
        progress.accountSwitched = false
        #if WIZ_ICLOUD
        guard let model else { return }
        saved.switchPending = nil
        // A household this account joined elsewhere, now it's answered: joined as answered.
        defer { Task { await findHousehold(after: choice) } }
        switch choice {
        case .merge:
            seed()
        case .keepHereOnly:
            markAllKnown()
        case .replace:
            _ = model
            clearLibraryHere()
            // Everything fetched afresh: what the account sent while the question was open is
            // already marked as taken, and would otherwise never come back (or, missing here, be
            // deleted from iCloud by the next change).
            saved.meta = [:]
            saved.deleting = []
            saved.unreadable = nil
            saved.state = nil
            saved.seeded = true
            persist()
            makeEngine()
            Task { try? await engine?.fetchChanges() }
        }
        #endif
    }

    #if WIZ_ICLOUD
    /// Everything here taken as already in iCloud, so nothing goes up unless it's changed here.
    private func markAllKnown() {
        for kind in Kind.allCases {
            for (id, item) in current(kind) {
                saved.meta[Self.recordName(kind, id)] = Meta(id: id, hash: Self.hash(item), order: item.order, modified: .distantPast,
                                                             orderModified: .distantPast, unsent: false)
            }
        }
        saved.seeded = true
        persist()
    }
    #endif

    /// Fetches and sends now (Settings' Sync Now).
    func syncNow() async {
        #if WIZ_ICLOUD
        await findHousehold()
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

    /// For this account's own library (the private database) or a household's (the shared one).
    private func makeEngine() {
        let database = saved.shared == nil ? container.privateCloudDatabase : container.sharedCloudDatabase
        var config = CKSyncEngine.Configuration(database: database, stateSerialization: saved.state, delegate: self)
        config.automaticallySync = true
        engine = CKSyncEngine(config)
        engineFresh = saved.state == nil
        progress.household = saved.shared?.ownerName
        status = "Waiting for iCloud"
    }

    /// Its own zone is made if need be; a household's belongs to its owner.
    private func ensureZone() {
        guard saved.shared == nil else { return }
        engine?.state.add(pendingDatabaseChanges: [.saveZone(CKRecordZone(zoneID: zoneID))])
    }

    /// Offers everything here to iCloud, stamped as old so that anything iCloud already has wins.
    private func seed() {
        guard let engine else { return }
        ensureZone()
        var pending: [CKSyncEngine.PendingRecordZoneChange] = []
        for kind in Kind.allCases {
            for (id, item) in current(kind) {
                let name = Self.recordName(kind, id)
                // Offered as oldest (iCloud's copy wins); back from a household, as last changed there.
                let stamp: Date = saved.mirroring.map { $0.stamps[name] ?? .now } ?? .distantPast
                saved.meta[name] = Meta(id: id, hash: Self.hash(item), order: item.order, modified: stamp,
                                        orderModified: stamp, systemFields: saved.meta[name]?.systemFields)
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
        ensureZone()
        engine.state.add(pendingRecordZoneChanges: pending)
    }

    /// Signed out, or another account: forget what was synced (keeping the library here), and on
    /// signing in offer it to the account. The engine keeps going: it resets its own state.
    private func reset(reseed: Bool) {
        saved.mirroring = nil // another account's own library, or none: nothing to mirror into
        saved.meta = [:]
        saved.unreadable = nil // nothing taken from iCloud any more: all of it's this device's
        saved.deleting = []
        saved.seeded = false
        persist()
        if reseed { seed() }
    }

    // MARK: Household sharing

    /// The share of this account's library (made if there isn't one), for Share Library.
    func makeShare() async throws -> CKShare {
        let db = container.privateCloudDatabase
        _ = try? await db.save(CKRecordZone(zoneID: Self.ownZone))
        let shareID = CKRecord.ID(recordName: CKRecordNameZoneWideShare, zoneID: Self.ownZone)
        if let existing = try? await db.record(for: shareID) as? CKShare { return existing }
        let share = CKShare(recordZoneID: Self.ownZone)
        share[CKShare.SystemFieldKey.title] = "setPilot Library"
        share.publicPermission = .none
        let (results, _) = try await db.modifyRecords(saving: [share], deleting: [])
        guard let saved = try results[shareID]?.get() as? CKShare else { throw CKError(.internalError) }
        return saved
    }

    /// An invitation opened here (from Messages or Mail): asked about, unless it's this account's own.
    func offer(_ metadata: CKShare.Metadata) {
        guard metadata.participantRole != .owner else {
            status = "That's the invitation to your own library"
            return
        }
        progress.invitation = metadata
    }

    /// An invitation accepted: join that household's library,
    /// adding this device's library to it, or replacing this device's with it.
    func join(_ metadata: CKShare.Metadata, addMine: Bool) async {
        let zone = metadata.share.recordID.zoneID
        guard metadata.participantRole != .owner, zone.ownerName != CKCurrentUserDefaultName else { return } // our own share
        // One household at a time: any other the account's in (this device's, or one another
        // device joined that this one hasn't followed yet) is left first, so the account is never
        // in two for its devices to split between.
        let others: [CKRecordZone.ID]
        do {
            others = try await container.sharedCloudDatabase.allRecordZones().map(\.zoneID)
                .filter { $0.zoneName == Self.ownZone.zoneName && $0 != zone }
        } catch {
            status = "Couldn't check your current household before joining this one: " + Self.describe(error)
            return
        }
        for other in others {
            do {
                _ = try await container.sharedCloudDatabase.deleteRecordZone(withID: other)
            } catch let error as CKError where error.code == .zoneNotFound || error.code == .unknownItem {
                // Already gone: left all the same.
            } catch {
                status = "Couldn't leave your current household to join this one: " + Self.describe(error)
                return
            }
        }
        do {
            _ = try await container.accept(metadata)
        } catch {
            status = Self.describe(error)
            return
        }
        let household = SharedZone(zoneName: zone.zoneName, ownerName: zone.ownerName)
        // For the account's other devices: how, and what this library had (before replacing it).
        let record = await leaveJoinRecord(household, addMine: addMine)
        if !addMine { clearLibraryHere() }
        switchLibrary(to: household, join: record)
    }

    /// Saves the HouseholdJoin record to the account's own library. Not saved (offline, say), the
    /// other devices ask instead.
    @discardableResult
    private func leaveJoinRecord(_ household: SharedZone, addMine: Bool) async -> HouseholdJoin {
        var items: [String: Date] = [:]
        for kind in Kind.allCases {
            for id in current(kind).keys {
                let name = Self.recordName(kind, id)
                items[name] = saved.meta[name]?.modified ?? .now
            }
        }
        let join = HouseholdJoin(zone: household, addMine: addMine, items: items)
        await saveJoinRecord(join, replacing: true)
        return join
    }

    /// Saves (or replaces) the HouseholdJoin record. Each device that joins adds what it brought,
    /// so a later one doesn't take those for new (and bring back what's been removed since).
    /// `replacing`: a new join (this device joining), not an update to the current one. Otherwise
    /// merged with what's there (two devices following at once each add theirs), saved only if
    /// it hasn't changed meanwhile, and tried again if it has.
    private func saveJoinRecord(_ join: HouseholdJoin, replacing: Bool = false) async {
        let db = container.privateCloudDatabase
        let id = CKRecord.ID(recordName: Self.joinRecordName, zoneID: Self.ownZone)
        _ = try? await db.save(CKRecordZone(zoneID: Self.ownZone))
        for _ in 0..<4 {
            let existing = try? await db.record(for: id)
            // Gone (the household's been left): not brought back by an update.
            if !replacing, existing == nil { return }
            var merged = join
            if !replacing, let existing, let data: Data = existing.encryptedValues["join"],
               let old = try? JSONDecoder().decode(HouseholdJoin.self, from: data), old.zone == join.zone {
                merged.addMine = old.addMine
                merged.items = old.items.merging(join.items) { max($0, $1) }
            }
            guard let data = try? JSONEncoder().encode(merged) else { return }
            let record = existing ?? CKRecord(recordType: Self.joinRecordType, recordID: id)
            record.encryptedValues["join"] = data
            do {
                let (results, _) = try await db.modifyRecords(saving: [record], deleting: [], savePolicy: replacing ? .allKeys : .ifServerRecordUnchanged)
                if case .failure(let error as CKError)? = results[id], error.code == .serverRecordChanged { continue }
                return
            } catch let error as CKError where error.code == .serverRecordChanged {
                continue
            } catch {
                return // offline, say: the other devices ask instead
            }
        }
    }

    /// A household this account joined on another of its devices: an invitation is accepted for
    /// the whole account, but only the device that accepted it switches there. The others find
    /// the household's zone in the shared database and join it too (joinFound: keeping only what's
    /// new here since it was joined, as the HouseholdJoin record that device left says).
    ///
    /// `choice`: none (found at launch, Sync Now, signing in, or the join record arriving) is
    /// joinFound's; after the Apple ID question, as answered (added, kept here without being
    /// added, or already replaced). Returns whether one was joined.
    enum HouseholdLookup { case none, joined, skipped }

    /// One look at a time: two at once (launch and signing in, say) would race to decide how
    /// this device's library goes.
    @discardableResult
    private func findHousehold(after choice: AccountChoice? = nil) async -> HouseholdLookup {
        if let running = householdLookup {
            // One under way: its answer, if it was asked the same; otherwise this one after it.
            if runningChoice == choice { return await running.value }
            _ = await running.value
            return await findHousehold(after: choice)
        }
        runningChoice = choice
        let task = Task { await lookUpHousehold(after: choice) }
        householdLookup = task
        let result = await task.value
        householdLookup = nil
        return result
    }

    private var runningChoice: AccountChoice?

    private func lookUpHousehold(after choice: AccountChoice?) async -> HouseholdLookup {
        // Not while the question about another Apple ID is open: this device's library is
        // decided on first (answering it looks again).
        guard saved.shared == nil, saved.switchPending != true, engine != nil else { return .skipped }
        guard let zones = try? await container.sharedCloudDatabase.allRecordZones() else { return .skipped }
        guard saved.shared == nil, saved.switchPending != true else { return .skipped } // joined (or switched) meanwhile
        let households = zones.filter { $0.zoneID.zoneName == Self.ownZone.zoneName && $0.zoneID.ownerName != CKCurrentUserDefaultName }
            .map { SharedZone(zoneName: $0.zoneID.zoneName, ownerName: $0.zoneID.ownerName) }
        guard let household = households.first(where: { $0 == saved.householdJoin?.zone }) ?? households.first else {
            // In none: what this device had of one is nothing to a later one.
            saved.householdSeen = nil
            persist()
            return .none
        }
        if let seen = saved.householdSeen, seen.zone != household {
            saved.householdSeen = nil
            persist()
        }
        switch choice {
        case .merge?:
            // Added, as answered, but not what the household's had (it may have removed it since):
            // the account's own library synced first, for the join record.
            guard await syncOwn(), saved.shared == nil, saved.switchPending != true else { return .skipped }
            let known = knowledge(of: household)
            if known.record == nil, known.seen == nil {
                switchLibrary(to: household)
            } else {
                switchKeeping(newItems(known), deleting: deletionsSince(known.seen), to: household)
            }
        case .keepHereOnly?:
            switchLibrary(to: household, offerMine: false)
            markAllKnown()
        case .replace?:
            clearLibraryHere() // already, as answered
            switchLibrary(to: household, offerMine: false)
        case nil:
            return await joinFound(household)
        }
        return .joined
    }

    /// A household this account joined on another device (or this one had, before an account
    /// change took it out): joined here too, keeping only what's new here since (HouseholdJoin).
    private func joinFound(_ household: SharedZone) async -> HouseholdLookup {
        // The account's own library synced both ways first: what the device that joined left,
        // and what's here sent (so nothing's lost). Not now if that can't be done (offline): the
        // next launch or Sync Now tries again.
        guard await syncOwn() else { return .skipped }
        guard saved.shared == nil, saved.switchPending != true else { return .skipped }
        let known = knowledge(of: household)
        guard known.record != nil || known.seen != nil else {
            // No word of how it was joined (an older setPilot, or the record didn't save): asked.
            ask(.noRecord, household)
            return .skipped
        }
        let new = newItems(known)
        // Joined adding (or this device's own household, rejoined): what's new goes in. Joined
        // replacing, with something new here: asked whether it goes in.
        if new.isEmpty || known.record?.addMine != false || known.seen != nil {
            switchKeeping(new, deleting: deletionsSince(known.seen), to: household)
            return .joined
        }
        ask(.newItems(new.values.reduce(0) { $0 + $1.count }), household)
        return .skipped
    }

    /// Deletions to send on rejoining a household this device had: ones it hadn't sent before
    /// leaving it, and its items deleted here since (signed out, say).
    private func deletionsSince(_ seen: SeenHousehold?) -> Set<String> {
        guard let seen else { return [] }
        var here = Set<String>()
        for kind in Kind.allCases { for id in current(kind).keys { here.insert(Self.recordName(kind, id)) } }
        return seen.deleted.union(Set(seen.items.keys).union(seen.changed.keys).subtracting(here))
    }

    /// What's known here of how a household was joined: the record the device that joined left
    /// (if it's for this household), and what this device had of it before an account change.
    private func knowledge(of household: SharedZone) -> (record: HouseholdJoin?, seen: SeenHousehold?) {
        (saved.householdJoin.flatMap { $0.zone == household ? $0 : nil },
         saved.householdSeen.flatMap { $0.zone == household ? $0 : nil })
    }

    /// What's here that a household doesn't know of: not among what it had (record name, when last
    /// changed then), or changed since (or changed here and not sent before leaving it). Each with
    /// when it last changed (now, if never synced or changed unsent).
    private func newItems(_ known: (record: HouseholdJoin?, seen: SeenHousehold?)) -> [Kind: [String: (Item, Date)]] {
        let had = (known.record?.items ?? [:]).merging(known.seen?.items ?? [:]) { max($0, $1) }
        let changed = known.seen?.changed ?? [:]
        var out: [Kind: [String: (Item, Date)]] = [:]
        // Changes made here before leaving it: as they were then (the later change wins as usual),
        // unless changed again since (then as it is now); deleted since, not at all.
        for change in changed.values {
            guard let kind = Kind(rawValue: change.kind), let now = current(kind)[change.id] else { continue }
            out[kind, default: [:]][change.id] = Self.hash(now) == change.hash ? (change.item, change.modified) : (now, .now)
        }
        for kind in Kind.allCases {
            for (id, item) in current(kind) {
                let name = Self.recordName(kind, id)
                let modified = saved.meta[name]?.modified
                if changed[name] != nil { continue }
                let isNew = had[name].map { then in modified.map { $0 > then } ?? true } ?? true
                if isNew { out[kind, default: [:]][id] = (item, modified ?? .now) }
            }
        }
        return out
    }

    /// Switches to a household's library, keeping here only `items`, which go up to it (changes
    /// stamped when they were made, so the later one wins as usual).
    /// `deleting`: deletions made here that hadn't gone up before an account change took it out.
    private func switchKeeping(_ items: [Kind: [String: (Item, Date)]], deleting: Set<String> = [], to household: SharedZone) {
        // The join record (if there is one) learns what this device brought, and what it had of
        // the household before: a device joining later mustn't take those for new.
        let known = knowledge(of: household)
        var kept = known.record
        if var record = known.record {
            for (kind, list) in items {
                for (id, (_, modified)) in list { record.items[Self.recordName(kind, id)] = modified }
            }
            for (name, date) in known.seen?.items ?? [:] { record.items[name] = max(record.items[name] ?? date, date) }
            kept = record
            Task { await saveJoinRecord(record) }
        }
        switchLibrary(to: household, offerMine: false, join: kept)
        clearLibraryHere()
        var pending: [CKSyncEngine.PendingRecordZoneChange] = deleting.map { .deleteRecord(CKRecord.ID(recordName: $0, zoneID: zoneID)) }
        saved.deleting.formUnion(deleting)
        for (kind, list) in items {
            for (id, (item, modified)) in list {
                let name = Self.recordName(kind, id)
                saved.meta[name] = Meta(id: id, hash: Self.hash(item), order: item.order, modified: modified, orderModified: modified)
                pending.append(.saveRecord(CKRecord.ID(recordName: name, zoneID: zoneID)))
            }
        }
        for (kind, list) in items { apply(kind, list.mapValues { Optional($0.0) }) }
        if !pending.isEmpty { engine?.state.add(pendingRecordZoneChanges: pending) }
        persist()
    }

    enum HouseholdQuestion: Equatable {
        /// Joined replacing on another device, and this many items here weren't on it.
        case newItems(Int)
        /// No word of how it was joined.
        case noRecord
    }

    private func ask(_ question: HouseholdQuestion, _ household: SharedZone) {
        saved.pendingHousehold = household
        persist()
        progress.householdQuestion = question
    }

    /// The answer to HouseholdQuestion: add this device's (new) items, leave them out, or (nil)
    /// not now, to be asked again at the next launch.
    func answerHousehold(addMine: Bool?) {
        progress.householdQuestion = nil
        guard let addMine, let household = saved.pendingHousehold else { return }
        guard saved.shared != household else { return } // joined meanwhile (the join record came)
        Task {
            // Not done now (offline, say): kept, and asked again at the next launch or Sync Now.
            guard await syncOwn(), saved.shared == nil, saved.switchPending != true else {
                status = "Couldn't join the household yet: it'll be asked again (Sync Now, or next time)"
                return
            }
            // Still there (it may have been left, or stopped being shared, while the question was up).
            guard let zones = try? await container.sharedCloudDatabase.allRecordZones() else {
                status = "Couldn't join the household yet: it'll be asked again (Sync Now, or next time)"
                return
            }
            guard zones.contains(where: { $0.zoneID.zoneName == household.zoneName && $0.zoneID.ownerName == household.ownerName }),
                  saved.shared == nil else {
                saved.pendingHousehold = nil
                persist()
                return
            }
            let known = knowledge(of: household)
            var items: [Kind: [String: (Item, Date)]] = [:]
            // Left out: the join record learns them too, so the account's other devices (which
            // get them through its own library) aren't asked about them again.
            if !addMine, var record = known.record {
                for (kind, list) in newItems(known) {
                    for (id, (_, modified)) in list { record.items[Self.recordName(kind, id)] = modified }
                }
                Task { await saveJoinRecord(record) }
            }
            if addMine {
                if known.record == nil, known.seen == nil {
                    // Everything here, as on joining adding: the household's own versions win.
                    items = newItems(known).mapValues { list in list.mapValues { entry in (entry.0, Date.distantPast) } }
                } else {
                    items = newItems(known)
                }
            }
            switchKeeping(items, deleting: deletionsSince(known.seen), to: household)
        }
    }

    /// The account's own library fetched and this device's changes sent, offering it first if it
    /// never has been. Returns whether all of it went.
    private func syncOwn() async -> Bool {
        guard let engine, saved.shared == nil else { return false }
        let changes = accountChanges
        if !saved.seeded { seed() }
        do {
            try await engine.fetchChanges()
            try await engine.sendChanges()
        } catch {
            return false
        }
        // Only if nothing changed meanwhile: an account change (signing in or out) empties the
        // queue without sending it, which would look the same as all of it having gone.
        guard accountChanges == changes, engine === self.engine, saved.seeded,
              engine.state.pendingRecordZoneChanges.isEmpty else { return false }
        return true
    }

    /// Leaves the household library (this device keeps a copy of it, which goes to the account's own).
    func leaveHousehold() async {
        guard saved.shared != nil else { return }
        do {
            _ = try await container.sharedCloudDatabase.deleteRecordZone(withID: zoneID)
        } catch let error as CKError where error.code == .zoneNotFound || error.code == .unknownItem {
            // Already gone (the owner stopped sharing): left all the same.
        } catch {
            // Still a member (offline, say): staying, or the next launch would join again.
            status = "Couldn't leave the household: " + Self.describe(error)
            return
        }
        // The account's other devices mustn't act on how it was joined any more.
        _ = try? await container.privateCloudDatabase.deleteRecord(withID: CKRecord.ID(recordName: Self.joinRecordName, zoneID: Self.ownZone))
        switchLibrary(to: nil, mirror: true)
    }

    /// Syncs another library from now on: a new engine on its database, with what's here offered to it.
    /// Back to the account's own library from a household (`mirror`): it becomes what's here.
    /// `join`: the household's join record, kept while in it (for leaving it: MirrorPlan).
    private func switchLibrary(to shared: SharedZone?, offerMine: Bool = true, mirror: Bool = false, join: HouseholdJoin? = nil) {
        let plan: MirrorPlan? = mirror && saved.shared != nil
            ? MirrorPlan(stamps: saved.meta.mapValues(\.modified), joinItems: saved.householdJoin?.items ?? [:]) : nil
        saved = Saved(shared: shared)
        saved.mirroring = plan
        if shared != nil { saved.householdJoin = join }
        if !offerMine { saved.seeded = true }
        progress.householdQuestion = nil // answered by this, or moot
        persist()
        makeEngine()
        if offerMine { seed() } else { ensureZone() }
    }

    private func clearLibraryHere() {
        guard let model else { return }
        applying = true
        model.library.takeFromCloud {
            $0.presets = []
            $0.customScenes = []
            $0.cctScales = [:]
        }
        model.setNamesFromCloud([:])
        model.setSigningKeysFromCloud([:])
        model.setKnownBulbsFromCloud([])
        applying = false
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
        guard kind.hashed else { return "\(kind.rawValue).\(id)" }
        let digest = SHA256.hash(data: Data("setPilot \(kind.rawValue) \(id.lowercased())".utf8))
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
        case .signingKey:
            for (mac, key) in model.signingKeys { items[mac] = Item(data: Data(key.utf8), order: 0, mac: mac) }
        case .knownBulb:
            for (i, b) in model.knownBulbs.enumerated() {
                if let d = try? Self.encoder.encode(b) { items[b.id] = Item(data: d, order: Double(i), mac: b.id) }
            }
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
        case .signingKey:
            var keys = model.signingKeys
            for (mac, change) in changes { keys[mac] = change.map { String(decoding: $0.data, as: UTF8.self) } }
            model.setSigningKeysFromCloud(keys)
        case .knownBulb:
            var byID: [String: (KnownBulb, Double)] = [:]
            for (i, b) in model.knownBulbs.enumerated() { byID[b.id] = (b, order(b.id, i)) }
            for (id, change) in changes {
                if let change, let b = try? JSONDecoder().decode(KnownBulb.self, from: change.data) {
                    byID[id] = (b, order(id, Int.max))
                } else {
                    byID[id] = nil
                }
            }
            model.setKnownBulbsFromCloud(byID.values.sorted { $0.1 == $1.1 ? $0.0.id < $1.0.id : $0.1 < $1.1 }.map(\.0))
        }
    }

    // MARK: Records

    private func record(for id: CKRecord.ID) -> CKRecord? {
        guard let kind = Self.kind(of: id.recordName), let meta = saved.meta[id.recordName],
              let item = current(kind)[meta.id] else { return nil }
        // System fields from another zone (kept from before a switch of library) would save there.
        let kept = meta.systemFields.flatMap(Self.record(fromSystemFields:)).flatMap { $0.recordID == id ? $0 : nil }
        let record = kept ?? CKRecord(recordType: kind.rawValue, recordID: id)
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
        return kind.hashed ? nil : String(name.dropFirst(kind.rawValue.count + 1))
    }

    /// iCloud's version of a record. Its content and its place are each taken unless this
    /// device's own change to that part is newer (then ours is sent again on top). A deletion here
    /// still to go up wins over an edit from elsewhere. Returns the change to apply, if any.
    private func take(_ record: CKRecord) -> (Kind, String, Item)? {
        let name = record.recordID.recordName
        guard let kind = Self.kind(of: name), let data: Data = record.encryptedValues["data"] else { return nil }
        let mac: String? = record.encryptedValues["mac"]
        guard let id = kind.hashed ? mac : itemID(name, kind), !id.isEmpty else { return nil }
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
            // A household belongs to the account that joined it: another account (or none) goes
            // back to its own library, on the private database. Not on signing in: a new engine
            // (a household just joined, say) reports the account it starts with as one.
            var signingIn = false
            if case .signIn = e.changeType { signingIn = true }
            // An engine just made (at launch, or for a library just switched to) reports the account
            // it starts with as signing in: that's not a change, and whoever made it has done what's due.
            accountChanges += 1
            let fresh = engineFresh
            engineFresh = false
            if saved.shared != nil, !signingIn {
                // What this device had of the household: rejoining, that's the household's, not new.
                // Changes here that hadn't gone up are kept apart, to go up on rejoining.
                var changed: [String: SeenChange] = [:]
                for kind in Kind.allCases {
                    for (id, item) in current(kind) {
                        let name = Self.recordName(kind, id)
                        guard let meta = saved.meta[name], meta.unsent else { continue }
                        changed[name] = SeenChange(kind: kind.rawValue, id: id, item: item, modified: meta.modified, hash: Self.hash(item))
                    }
                }
                let seen = saved.shared.map { zone in
                    SeenHousehold(zone: zone, items: saved.meta.filter { !$0.value.unsent && saved.unreadable?[$0.key] == nil }.mapValues(\.modified),
                                  changed: changed, deleted: saved.deleting)
                }
                saved = Saved()
                saved.householdSeen = seen
                persist()
                makeEngine()
                engineFresh = false // made for this change, which is handled below
            }
            switch e.changeType {
            case .signIn:
                guard saved.shared == nil, !fresh else { break }
                reset(reseed: false)
                // Not while the question about another Apple ID is open. An account in a household
                // joins it, with what's new here (joinFound); with none, what's here goes to its
                // own library.
                guard saved.switchPending != true else { break }
                Task {
                    // Not joined (none, or couldn't look, or asking): what's here goes to the account's own.
                    let found = await self.findHousehold()
                    if found != .joined, self.saved.shared == nil, self.saved.switchPending != true { self.seed() }
                }
            // Another Apple ID: ask what to do with what's here (AccountSwitchPrompt).
            case .switchAccounts:
                reset(reseed: false)
                // Another Apple ID: the last one's household is nothing to this one.
                saved.householdJoin = nil
                saved.householdSeen = nil
                saved.pendingHousehold = nil
                saved.switchPending = true
                persist()
                progress.accountSwitched = true
            case .signOut: reset(reseed: false); status = "Not signed in to iCloud"
            @unknown default: break
            }

        case .fetchedDatabaseChanges(let e):
            engineFresh = false // working: a later sign-in is a real one
            // A household library this account left, or its owner stopped sharing: back to its
            // own, with what's here (offered to it as on signing in).
            if saved.shared != nil, e.deletions.contains(where: { $0.zoneID == zoneID }) {
                switchLibrary(to: nil, mirror: true)
                return
            }
            // The zone deleted (iCloud's data removed in Settings, say): forget what was synced.
            // The library here stays, and all of it goes up again with the next change here.
            if e.deletions.contains(where: { $0.zoneID == zoneID }) {
                saved.meta = [:]
                saved.unreadable = nil
                saved.deleting = []
                saved.seeded = false
                persist()
            }

        case .fetchedRecordZoneChanges(let e):
            var changes: [Kind: [String: Item?]] = [:]
            // Only this library's zone (a shared database can hold others' shares too).
            var joined = false
            for m in e.modifications where m.record.recordID.zoneID == zoneID {
                // How another device of this account joined a household (HouseholdJoin).
                if m.record.recordType == Self.joinRecordType {
                    if saved.shared == nil, let data: Data = m.record.encryptedValues["join"],
                       let join = try? JSONDecoder().decode(HouseholdJoin.self, from: data) {
                        saved.householdJoin = join
                        joined = true
                    }
                    continue
                }
                // Mirroring: what the own library has that isn't here (removed in the household
                // meanwhile) goes, rather than coming back.
                if let plan = saved.mirroring, let kind = Self.kind(of: m.record.recordID.recordName) {
                    let name = m.record.recordID.recordName
                    let id: String? = kind.hashed ? m.record.encryptedValues["mac"] : itemID(name, kind)
                    // Only what was there at the join and hasn't changed since: anything added or
                    // edited in the own library meanwhile (a device that hadn't followed) stays.
                    let modified = m.record["modified"] as? Date ?? .distantPast
                    if let id, current(kind)[id] == nil, saved.meta[name] == nil,
                       let then = plan.joinItems[name], modified <= then {
                        saved.deleting.insert(name)
                        engine?.state.add(pendingRecordZoneChanges: [.deleteRecord(m.record.recordID)])
                        continue
                    }
                }
                if let (kind, id, item) = take(m.record) { changes[kind, default: [:]].updateValue(item, forKey: id) }
            }
            // Joined on another device: this one follows (not while a lookup's syncing for it).
            if joined, saved.switchPending != true, householdLookup == nil { Task { await findHousehold() } }
            for d in e.deletions where d.recordID.zoneID == zoneID {
                let name = d.recordID.recordName
                saved.deleting.remove(name)
                saved.unreadable?.removeValue(forKey: name)
                guard let kind = Self.kind(of: name), let id = itemID(name, kind) else { continue }
                saved.meta.removeValue(forKey: name)
                changes[kind, default: [:]].updateValue(nil, forKey: id)
            }
            for (kind, c) in changes { apply(kind, readable(kind, c)) }
            persist()

        case .willSendChanges:
            sendFailed = false

        case .sentRecordZoneChanges(let e):
            for record in e.savedRecords where record.recordID.zoneID == zoneID {
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
                case .zoneNotFound where saved.shared != nil:
                    // The household's gone (its owner stopped sharing): back to this account's own.
                    switchLibrary(to: nil, mirror: true)
                    return
                case .zoneNotFound:
                    ensureZone()
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
            for (kind, c) in changes { apply(kind, readable(kind, c)) }
            persist()

        case .didFetchChanges, .didSendChanges:
            if case .didFetchChanges = event, saved.mirroring != nil {
                saved.mirroring = nil // the own library's been gone through
                persist()
            }
            finishRound()

        default:
            break
        }
    }

    /// Whether this build can read an item of iCloud's (a newer build's may have more in it).
    private static func canRead(_ kind: Kind, _ item: Item) -> Bool {
        let d = JSONDecoder()
        switch kind {
        case .preset: return (try? d.decode(Preset.self, from: item.data)) != nil
        case .customScene: return (try? d.decode(CustomScene.self, from: item.data)) != nil
        case .cctScale: return (try? d.decode(CCTScale.self, from: item.data)) != nil
        case .knownBulb: return (try? d.decode(KnownBulb.self, from: item.data)) != nil
        case .bulbName, .signingKey: return true
        }
    }

    /// The changes this build can read; the others are set aside (`unreadable`), so they aren't
    /// taken for deletions here, and nothing here overwrites or deletes them in iCloud.
    private func readable(_ kind: Kind, _ changes: [String: Item?]) -> [String: Item?] {
        var out: [String: Item?] = [:]
        for (id, change) in changes {
            let name = Self.recordName(kind, id)
            if let item = change, !Self.canRead(kind, item) {
                saved.unreadable = (saved.unreadable ?? [:]).merging([name: item]) { $1 }
                continue
            }
            saved.unreadable?.removeValue(forKey: name)
            out[id] = change
        }
        return out
    }

    /// Items set aside as unreadable that this build can read (it's been updated): taken now.
    private func retryUnreadable() {
        guard let unreadable = saved.unreadable, !unreadable.isEmpty else { return }
        var changes: [Kind: [String: Item?]] = [:]
        for (name, item) in unreadable {
            guard let kind = Self.kind(of: name), let id = saved.meta[name]?.id, Self.canRead(kind, item) else { continue }
            saved.unreadable?.removeValue(forKey: name)
            changes[kind, default: [:]].updateValue(item, forKey: id)
        }
        for (kind, c) in changes { apply(kind, c) }
        persist()
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
        await MainActor.run {
            // A library switched from (household joined or left) may still be finishing a round.
            guard syncEngine === self.engine else { return }
            self.handle(event)
        }
    }

    nonisolated func nextRecordZoneChangeBatch(_ context: CKSyncEngine.SendChangesContext,
                                               syncEngine: CKSyncEngine) async -> CKSyncEngine.RecordZoneChangeBatch? {
        guard await MainActor.run(body: { syncEngine === self.engine }) else { return nil }
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
    /// iCloud is now another Apple ID, and what to do with this device's library hasn't been chosen.
    var accountSwitched = false
    /// The owner of the household library this account has joined, if any (their user record name).
    var household: String?
    #if WIZ_ICLOUD
    /// An invitation to a household library, opened here and waiting for an answer.
    var invitation: CKShare.Metadata?
    /// A household this account joined elsewhere, and what to ask before joining it here.
    var householdQuestion: CloudLibrary.HouseholdQuestion?
    #endif
}

import SwiftUI

extension View {
    /// Asks what to do with this device's library when iCloud is now another Apple ID.
    func accountSwitchPrompt() -> some View { modifier(AccountSwitchPrompt()) }
}

private struct AccountSwitchPrompt: ViewModifier {
    func body(content: Content) -> some View {
        content.alert("iCloud is now another Apple ID",
                      isPresented: Binding(get: { CloudLibrary.shared.progress.accountSwitched },
                                           set: { if !$0 { CloudLibrary.shared.progress.accountSwitched = false } })) {
            Button("Add Them to This Account") { CloudLibrary.shared.resolveAccountSwitch(.merge) }
            Button("Keep Them on This Device Only") { CloudLibrary.shared.resolveAccountSwitch(.keepHereOnly) }
            Button("Replace Them with This Account's", role: .destructive) { CloudLibrary.shared.resolveAccountSwitch(.replace) }
        } message: {
            Text("This device has presets, custom scenes, CCT scales, bulbs and signing keys from the account it used before. Add them to this account, keep them here without adding them (anything you change is added), or replace them with this account's?")
        }
    }
}

#if WIZ_ICLOUD
import CoreTransferable

/// Share Library: an invitation to this account's library (iCloud sharing), for the share sheet.
struct HouseholdShare: Transferable {
    static var transferRepresentation: some TransferRepresentation {
        CKShareTransferRepresentation { (_: HouseholdShare) in
            .prepareShare(container: CKContainer(identifier: CloudLibrary.containerID)) {
                try await CloudLibrary.shared.makeShare()
            }
        }
    }
}
#endif

/// Settings' household rows: share this library, or the one joined and leaving it.
struct HouseholdRows: View {
    var body: some View {
        #if WIZ_ICLOUD
        if let owner = CloudLibrary.shared.progress.household {
            LabeledContent("Library", value: "Shared with you")
                .help("Owner: \(owner)")
            Button("Leave Household Library") { Task { await CloudLibrary.shared.leaveHousehold() } }
        } else {
            ShareLink(item: HouseholdShare(), preview: SharePreview("setPilot Library")) {
                Label("Share Library with Household…", systemImage: "person.2")
            }
        }
        #endif
    }
}

extension View {
    /// Asks what to do when an invitation to a household library is opened here.
    func householdInvitationPrompt() -> some View { modifier(HouseholdInvitationPrompt()) }
}

private struct HouseholdInvitationPrompt: ViewModifier {
    func body(content: Content) -> some View {
        #if WIZ_ICLOUD
        let progress = CloudLibrary.shared.progress
        content.alert("Join this household's setPilot library?",
                      isPresented: Binding(get: { progress.invitation != nil }, set: { if !$0 { progress.invitation = nil } })) {
            Button("Join, Adding Mine") { answer(addMine: true) }
            Button("Join, Replacing Mine", role: .destructive) { answer(addMine: false) }
            Button("Not Now", role: .cancel) { progress.invitation = nil }
        } message: {
            Text("Presets, custom scenes, CCT scales, bulbs and signing keys are then shared with everyone in it, on all your devices.")
        }
        // Joined on another device of this account: what to do with what's only here.
        .alert(householdTitle(progress.householdQuestion),
               isPresented: Binding(get: { progress.householdQuestion != nil }, set: { if !$0 { progress.householdQuestion = nil } })) {
            if case .noRecord? = progress.householdQuestion {
                Button("Join, Adding Mine") { CloudLibrary.shared.answerHousehold(addMine: true) }
                Button("Join, Replacing Mine", role: .destructive) { CloudLibrary.shared.answerHousehold(addMine: false) }
            } else {
                Button("Add Them") { CloudLibrary.shared.answerHousehold(addMine: true) }
                Button("Leave Them Out", role: .destructive) { CloudLibrary.shared.answerHousehold(addMine: false) }
            }
            Button("Not Now", role: .cancel) { CloudLibrary.shared.answerHousehold(addMine: nil) }
        } message: {
            Text(householdMessage(progress.householdQuestion))
        }
        #else
        content
        #endif
    }

    #if WIZ_ICLOUD
    private func householdTitle(_ question: CloudLibrary.HouseholdQuestion?) -> String {
        if case .newItems(let n)? = question { return n == 1 ? "1 item here isn't in the household" : "\(n) items here aren't in the household" }
        return "Your Apple ID is in a household library"
    }

    private func householdMessage(_ question: CloudLibrary.HouseholdQuestion?) -> String {
        if case .newItems? = question {
            return "The household was joined on another of your devices, replacing its library. These weren't on that device. Add them to the household, or leave them out?"
        }
        return "It was joined on another of your devices. Join it here too, adding this device's presets, custom scenes, CCT scales, bulbs and signing keys, or replacing them with the household's?"
    }

    private func answer(addMine: Bool) {
        guard let metadata = CloudLibrary.shared.progress.invitation else { return }
        CloudLibrary.shared.progress.invitation = nil
        Task { await CloudLibrary.shared.join(metadata, addMine: addMine) }
    }
    #endif
}
