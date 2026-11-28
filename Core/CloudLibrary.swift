import Foundation
import Observation
#if WIZ_ICLOUD
import CloudKit
import CryptoKit
#if os(macOS)
import AppKit
#endif
#endif

/// iCloud sync of the library (presets, custom scenes, CCT scales) and bulb names, item by item,
/// through CloudKit (the private database, in a zone of its own, or a household's shared with
/// it), between the account's Macs, iPhones and iPads.
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
        /// For a CCT scale, its bulb's MAC: a scale of a bulb whose stored scales this build can't
        /// read isn't taken for deleted when it's missing here (undecodedHere).
        var mac: String? = nil
    }

    /// An item's content as changed here, and when (Saved.changedHere).
    private struct ChangeStamp: Codable {
        var hash: Data
        var at: Date
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
        /// A household found that the question about joining it is waiting on (HouseholdQuestion),
        /// and since when.
        var pendingHousehold: SharedZone?
        var pendingAskedAt: Date?
        /// Back in the account's own library after leaving a household: it becomes what's here,
        /// everything else in it removed, once fetched (ReplacePlan).
        var replacing: ReplacePlan?
        /// When this device went into the household it's in, and last fetched it in full.
        var joinedAt: Date?
        var householdFetched: Date?
        /// This device's leave of a household, under way (resumed at launch until it's through).
        var leaving: HouseholdLeave?
        /// No longer in a household (its owner stopped sharing, or removed this account), and the
        /// question of keeping a copy or starting fresh is open (kept over a relaunch).
        var leftQuestion: Membership?
        /// What's here to go to the library this device is going to (by record name, with when it
        /// changed), when its meta isn't that library's: the rest here goes, and nothing is sent
        /// until it's decided (after leaving a household, or signing back in).
        var newHere: [String: Date]?
        /// Signed out: what was here as synced then (record name, content hash), and the household
        /// it was in, if any. Signing back in, only what's changed since is new.
        var signedOut: SignedOut?
        /// Signed back in: where this device was, while it's worked out where it goes (lookUpHousehold).
        var returning: SignedOut?
        /// Left elsewhere, starting fresh, and asked whether to keep what's only here (asked again
        /// at launch until it's answered).
        var askingFresh: Bool?
        /// The library's items deleted here while it was settling: deleted where it goes too.
        var deletedHere: Set<String>?
        /// The held items' content as held (a change to one stamps it afresh).
        var heldHashes: [String: Data]?
        /// A household joined here (accepted), still to be gone through (finished at launch).
        var joiningTo: JoinIntent?
        /// Households to leave still (joining another, the old one couldn't be left then).
        var toLeave: [SharedZone]?
        /// When each was noted: one the account has joined again since isn't left. (One noted by
        /// a build before this, with no date, is.)
        var toLeaveSince: [SharedZone: Date]?
        /// The join of each the join record had as known here when it was noted: another there
        /// now is a rejoin. (Not known, or noted by a build before this: by when it was noted.)
        var toLeaveJoins: [SharedZone: UUID]?
        /// Leave records written for joins that didn't go through, still to withdraw (kept until
        /// they are: a device in one of those households would follow it). Tried again by checkHousehold.
        var withdrawing: [LeaveWithdrawal]?
        /// Library items changed here while settling (nothing's sent then): to what, and when, so
        /// what goes up later is stamped when it was changed (unsentHere).
        var changedHere: [String: ChangeStamp]?
        /// The attempts of this device's leave records for its membership (HouseholdLeave.attempt),
        /// each kept from before it's saved: any found in the record later is this device's leave
        /// to finish (a retry's save can fail after an earlier one went through). Cleared only
        /// when the membership ends.
        var leaveAttempts: Set<UUID>?
        /// Builds that kept only the latest attempt: taken into `leaveAttempts` at launch.
        var leaveAttempt: UUID?
        /// This device's leave, finished: marked done in its record once the copy's gone up.
        var confirmLeave: HouseholdLeave?
        /// Put out of the household by this account itself (an administrator's Remove Me): asked as leaving.
        var leftSelf: Bool?
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
        /// This join's own (a rejoin of the same household is another). Nil in records from
        /// builds before it.
        var joinID: UUID? = nil
        /// When it was joined.
        var at: Date? = nil
        /// The household's been left: the record's kept, marked so, rather than deleted (read as
        /// no join record). Nil in records from builds before it.
        var left: Bool? = nil
    }

    /// A join under way (Saved.joiningTo): the household, how, and the ones to leave for it.
    struct JoinIntent: Codable, Equatable {
        var household: SharedZone
        var addMine: Bool
        var leaving: [SharedZone]
        /// The account's other devices have been told (the leave records and the join record
        /// written): only the leaving and switching are left.
        var told: Bool? = nil
        /// Joined from the account's own library (not from a household): what's here is its.
        var fromOwn: Bool? = nil
        /// Written into the leave records the telling writes (HouseholdLeave.attempt): if the join
        /// doesn't go through, only those are withdrawn, not another device's leave for the same
        /// household. Nil in joins noted by builds before it.
        var attempt: UUID? = nil
    }

    /// Leave records to withdraw (Saved.withdrawing): those for joining `household`, of the
    /// households in `zones`, that `attempt` wrote (nil: a join noted by a build before attempts,
    /// any for it).
    struct LeaveWithdrawal: Codable, Equatable {
        var household: SharedZone
        var attempt: UUID?
        var zones: [SharedZone]
    }

    /// A household membership of this device: which, the join it was (if known), and since when.
    struct Membership: Codable, Equatable {
        var zone: SharedZone
        var joinID: UUID?
        var joinedAt: Date?
        /// When this device last fetched it in full.
        var fetchedAt: Date? = nil
        /// Asked about where a chain of leaves ended (the account put out of a household it went
        /// on to from another device): this device was never in it, so has no copy of it.
        var joinedElsewhere: Bool? = nil
    }

    /// How a household was left, for the account's other devices (a record in its own library,
    /// written by the device it was left on before anything else happens): what became of it.
    /// The others follow: back to the own library keeping only what they hadn't sent (merged in
    /// after `keep`; asked about after `fresh`), or on to the household `joined` instead.
    struct HouseholdLeave: Codable, Equatable {
        enum Mode: Codable, Equatable { case keep, fresh, joined(SharedZone) }
        var zone: SharedZone
        var joinID: UUID?
        var mode: Mode
        var at: Date
        /// When the copy (`keep`) was last fetched in full: what the others changed after it
        /// may not be in it, so they bring that too.
        var copyAsOf: Date? = nil
        /// When the account joined it: the own library changed after that is the account's
        /// devices' that didn't follow (kept when it becomes the copy).
        var joinedAt: Date? = nil
        /// Left for another household (`joined`): whether it was joined adding.
        var addMine: Bool? = nil
        /// This attempt's own, kept on the device that writes it before the save: a save that
        /// looked failed but went through is that device's to finish, not another's to follow.
        /// Nil in records from builds before it.
        var attempt: UUID? = nil
        /// The copy (`keep`) has gone up to the own library. Until it has, the others bring
        /// everything they have (as if `copyAsOf` were nil): it may never be made.
        var done: Bool? = nil
        /// Written by a device that was never in it (Membership.joinedElsewhere): what it kept
        /// isn't a copy of it, so it's offered as oldest and what the others bring wins.
        var noCopy: Bool? = nil

        /// Own-library records last changed before this are from before the household (the
        /// leaving device removes them): a little after the join, which syncs what's here just
        /// before it; with no join time, a little before the leave, as the others send theirs after it.
        var cutoff: Date {
            joinedAt.map { min($0.addingTimeInterval(120), at.addingTimeInterval(-120)) } ?? at.addingTimeInterval(-120)
        }

        var isJoin: Bool {
            switch mode {
            case .joined: true
            default: false
            }
        }

        /// Whether it's the end of `membership` (the same join; with none known, since it began,
        /// allowing for clocks a little apart).
        func ends(_ membership: Membership) -> Bool {
            guard zone == membership.zone else { return false }
            if let a = joinID, let b = membership.joinID { return a == b }
            // Left for the same household (put out of it, and joined again): not the end of a
            // membership that began with that join, or after it.
            if case .joined(let target) = mode, target == zone, let began = membership.joinedAt, began >= at { return false }
            return at > (membership.joinedAt ?? .distantPast).addingTimeInterval(-300)
        }
    }

    /// The own library becoming what's here after leaving a household: records in it not named
    /// here are removed, and what's here wins over what's there.
    struct ReplacePlan: Codable {
        var keep: Set<String>
        /// Only records last changed before the leave: the account's other devices may already
        /// be sending theirs (following it), which stay.
        var before: Date?
        /// What the copy's stamped with: when each item last changed in the household (so the
        /// later change wins, whichever device made it); the leave's time for any without.
        var stamp: Date? = nil
        var stamps: [String: Date]? = nil
        /// Names the household had (the join record's): removed from the own library whatever
        /// their date, unless they're here.
        var householdHad: Set<String>? = nil
        /// Following another device's leave: what its plan removes is only left out here (not
        /// taken in the meantime, before that device has removed it), not removed from here.
        var skipOnly: Bool? = nil
    }

    /// What was here when signed out (Saved.signedOut).
    struct SignedOut: Codable {
        var membership: Membership?
        var hashes: [String: Data]
        /// Signed back in: what was here then and isn't now (deleted while signed out).
        var gone: Set<String>? = nil
        /// Asked (left fresh elsewhere) whether to keep these, and not answered yet (with their
        /// content then).
        var heldFresh: [String: Date]? = nil
        var heldHashes: [String: Data]? = nil
        /// The keep-or-remove question's been answered (asked again at launch until it is).
        var answered: Bool? = nil
        /// Put out of the household by this account itself (Saved.leftSelf): asked as leaving.
        var leftSelf: Bool? = nil
    }

    /// A join about to be accepted, noted first (a record in the account's own library): until the
    /// join record says it's been joined, another device with that household still to leave
    /// doesn't leave it meanwhile (checkHousehold).
    struct JoinMarker: Codable {
        var zone: SharedZone
        var at: Date
    }

    private static let joinRecordType = "HouseholdJoin"
    private static let joinRecordName = "householdJoin"
    private static let joiningRecordType = "HouseholdJoining"
    private static let joiningRecordName = "householdJoining"
    private static let leaveRecordType = "HouseholdLeave"
    /// What a leave record written for a join that didn't go through says it's of (withdrawLeaves):
    /// no household, so it's the end of no membership, to any build.
    private static let noHousehold = SharedZone(zoneName: "", ownerName: "")
    /// Each household's leave record has a name of its own (a later household's doesn't replace
    /// it, for a device still in this one); a hash, as record names aren't encrypted.
    private static func leaveRecordName(_ zone: SharedZone) -> String {
        let digest = SHA256.hash(data: Data("setPilot household \(zone.ownerName) \(zone.zoneName)".utf8))
        return "householdLeave." + digest.prefix(16).map { String(format: "%02x", $0) }.joined()
    }

    struct SharedZone: Codable, Hashable {
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
    /// Why a household step couldn't be done yet: shown instead of "Up to date" until Sync Now
    /// tries it again (or it's through).
    private var householdProblem: String?
    /// The CCT scales' record names in the library as last seen (at launch, each local change,
    /// and as iCloud's are put in): one gone since was deleted here, so not kept from deletion
    /// as a bulb's scales this build can't read are (undecodedHere).
    private var scalesSeen: Set<String> = []

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
        if let attempt = saved.leaveAttempt {
            saved.leaveAttempts = (saved.leaveAttempts ?? []).union([attempt])
            saved.leaveAttempt = nil
        }
        makeEngine()
        noteScalesSeen()
        if saved.switchPending == true {
            progress.accountSwitched = true
        } else if settling {
            // Where this device's library goes is still being worked out (below): nothing offered.
        } else if !saved.seeded {
            seed()
        } else {
            requeueUnsent()
        }
        retryUnreadable()
        if saved.askingFresh == true, let held = saved.newHere, saved.switchPending != true {
            if held.isEmpty {
                switchKeeping([:], to: nil, adding: false) // nothing left to ask about (deleted before the relaunch)
            } else {
                progress.householdQuestion = .leftFresh(held.count)
                Self.showQuestion()
            }
        }
        // (Not while a join that answers it is part way: resumeJoin finishes that, or asks again
        // if it isn't there.)
        if saved.leftQuestion != nil, saved.joiningTo == nil {
            progress.leftSelf = saved.leftSelf == true
            progress.leftElsewhere = saved.leftQuestion?.joinedElsewhere == true
            progress.leftHousehold = true // asked again (checkHousehold may find it answered elsewhere)
            Self.showQuestion()
        }
        updateProgress()
        if let note = saved.signedOut, note.answered != true { progress.signedOut = true }
        Task {
            await checkHousehold()
            await findHousehold()
        }
        #endif
    }

    /// The library or the bulb names changed here (not from iCloud).
    func localChanged(_ kind: Kind) {
        #if WIZ_ICLOUD
        // (After this change is worked out, which tells a deletion here by the last look.)
        defer { if kind == .cctScale { noteScalesSeen() } }
        guard let engine, !applying else { return }
        // Holding what's only here for where it goes: a change here is one of those too (a
        // deletion takes it out).
        if let held = saved.newHere {
            let now = current(kind)
            let prefix = kind.rawValue + "."
            let names = Set(now.keys.map { Self.recordName(kind, $0) })
            var updated = held
            for name in held.keys where name.hasPrefix(prefix) && !names.contains(name) { updated[name] = nil }
            for (id, item) in now {
                let name = Self.recordName(kind, id)
                let hash = Self.hash(item)
                // Already held: as of now if it's this one that changed, so it's the latest.
                if updated[name] != nil {
                    if saved.heldHashes?[name] != hash {
                        updated[name] = .now
                        saved.heldHashes = (saved.heldHashes ?? [:]).merging([name: hash]) { $1 }
                    }
                    continue
                }
                // The library's, as fetched (and not changed here since): not this device's.
                if let meta = saved.meta[name], meta.hash == hash { continue }
                // Signed back in, what's still as it was at signing out isn't new.
                if let back = saved.returning, back.hashes[name] == hash { continue }
                updated[name] = .now
                saved.heldHashes = (saved.heldHashes ?? [:]).merging([name: hash]) { $1 }
            }
            saved.newHere = updated
            // (Parked on the own library for a household: what's deleted here isn't the household's.)
            if !parked { noteDeletions(kind, now) }
            // Signed back in: what was here then and is deleted now goes too.
            if let back = saved.returning {
                let kept = undecodedHere(kind)
                let deleted = back.hashes.keys.filter { $0.hasPrefix(prefix) && !names.contains($0) && !kept.contains($0) }
                if !deleted.isEmpty { saved.returning?.gone = (back.gone ?? []).union(deleted) }
            }
            persist()
            return
        }
        guard !settling else {
            // Changes are worked out later (from their content), stamped as of now if their
            // content's new; deletions are noted now.
            // (Signed out, or back in and not yet settled: against what was synced at signing out,
            // as what was synced is forgotten then.)
            let note = saved.signedOut ?? saved.returning
            let now = current(kind)
            for (id, item) in now {
                let name = Self.recordName(kind, id)
                let hash = Self.hash(item)
                let synced = note != nil ? note?.hashes[name] : saved.meta[name]?.hash
                guard synced != hash, saved.changedHere?[name]?.hash != hash else { continue }
                saved.changedHere = (saved.changedHere ?? [:]).merging([name: ChangeStamp(hash: hash, at: .now)]) { $1 }
            }
            noteDeletions(kind, now)
            persist()
            return
        }
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
                if meta.mac != item.mac { meta.mac = item.mac; saved.meta[name] = meta }
                guard meta.hash != hash || meta.order != item.order else { continue }
                if meta.hash != hash { meta.hash = hash; meta.modified = .now }
                if meta.order != item.order { meta.order = item.order; meta.orderModified = .now }
                meta.unsent = true
                saved.meta[name] = meta
            } else {
                saved.meta[name] = Meta(id: id, hash: hash, order: item.order, modified: .now, orderModified: .now, mac: item.mac)
            }
            saved.deleting.remove(name)
            pending.append(.saveRecord(CKRecord.ID(recordName: name, zoneID: zoneID)))
        }
        let prefix = kind.rawValue + "."
        let kept = undecodedHere(kind)
        for (name, meta) in saved.meta where name.hasPrefix(prefix) && now[meta.id] == nil && unreadable[name] == nil && !kept.contains(name) {
            saved.meta.removeValue(forKey: name)
            saved.deleting.insert(name)
            pending.append(.deleteRecord(CKRecord.ID(recordName: name, zoneID: zoneID)))
        }
        guard !pending.isEmpty else { return }
        engine.state.add(pendingRecordZoneChanges: pending)
        persist()
        #endif
    }

    #if WIZ_ICLOUD
    /// Library items of `kind` deleted here while settling: deleted where it goes too.
    private func noteDeletions(_ kind: Kind, _ now: [String: Item]) {
        let prefix = kind.rawValue + "."
        let kept = undecodedHere(kind)
        for (name, meta) in saved.meta where name.hasPrefix(prefix) && now[meta.id] == nil && saved.unreadable?[name] == nil && !kept.contains(name) {
            saved.deletedHere = (saved.deletedHere ?? []).union([name])
        }
    }

    /// Record names of library items here this build can't decode (Library keeps them as they
    /// were): missing from `current`, but not deleted.
    private func undecodedHere(_ kind: Kind) -> Set<String> {
        guard let library = model?.library else { return [] }
        let ids: Set<String> = switch kind {
        case .preset: library.unreadableIDs(Library.presetsKey)
        case .customScene: library.unreadableIDs(Library.customScenesKey)
        case .cctScale: library.unreadableIDs(Library.cctScalesKey)
        case .bulbName, .signingKey, .knownBulb: []
        }
        var names = Set(ids.map { Self.recordName(kind, $0) })
        if kind == .cctScale {
            // Scales of a bulb whose stored scales this build can't read: what's here may not be
            // all, so one missing isn't deleted. Unless it was here at the last look: deleted here.
            let raw = library.rawScaleMACs
            if !raw.isEmpty {
                names.formUnion(saved.meta.filter { $0.key.hasPrefix(kind.rawValue + ".") && $0.value.mac.map { raw.contains($0.lowercased()) } == true }.keys)
            }
            if !names.isEmpty {
                names.subtract(scalesSeen.subtracting(current(.cctScale).keys.map { Self.recordName(.cctScale, $0) }))
            }
        }
        // Stored data of the kind this build can't read at all: none of its items is deleted.
        let key: String? = switch kind {
        case .preset: Library.presetsKey
        case .customScene: Library.customScenesKey
        case .cctScale: Library.cctScalesKey
        case .bulbName, .signingKey, .knownBulb: nil
        }
        if let key, library.isUnparsed(key) {
            let prefix = kind.rawValue + "."
            names.formUnion(saved.meta.keys.filter { $0.hasPrefix(prefix) })
            for hashes in [saved.returning?.hashes, saved.signedOut?.hashes] {
                names.formUnion((hashes ?? [:]).keys.filter { $0.hasPrefix(prefix) })
            }
        }
        return names
    }

    private func noteScalesSeen() {
        scalesSeen = Set(current(.cctScale).keys.map { Self.recordName(.cctScale, $0) })
    }

    /// Where this device's library goes is being worked out (signed out, signed back in, put out
    /// of a household, or holding what's only here for where it goes): nothing's sent meanwhile.
    private var settling: Bool {
        saved.signedOut != nil || saved.returning != nil || saved.leftQuestion != nil || saved.newHere != nil || saved.leaving != nil
    }

    /// This device's own leave's plan (what's here becoming the copy), not one it follows.
    private var ownPlan: ReplacePlan? {
        saved.replacing?.skipOnly == true ? nil : saved.replacing
    }

    /// Holding what's only here on the account's own library for a household it's asked about
    /// (following a join elsewhere): the own library's records aren't this device's to take meanwhile.
    private var parked: Bool {
        saved.newHere != nil && saved.pendingHousehold != nil && saved.shared == nil
    }
    #endif

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
                                                             orderModified: .distantPast, unsent: false, mac: item.mac)
            }
        }
        saved.seeded = true
        persist()
    }
    #endif

    /// Fetches and sends now (Settings' Sync Now).
    func syncNow() async {
        #if WIZ_ICLOUD
        householdProblem = nil // tried again now: said again below if it still can't be done
        await checkHousehold()
        await findHousehold()
        guard let engine else { return }
        status = householdProblem ?? "Syncing…"
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
        refetched = nil // (the last engine's)
        followPlanDone = false
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
        guard let engine, !settling else { return }
        ensureZone()
        var pending: [CKSyncEngine.PendingRecordZoneChange] = []
        for kind in Kind.allCases {
            for (id, item) in current(kind) {
                let name = Self.recordName(kind, id)
                // Offered as oldest (iCloud's copy wins); back from a household, as of the leave
                // (the own library becomes what's here; what the account's other devices bring
                // after it, stamped later, wins over it).
                // (No older than the cut-off: an own-library record from before the account joined
                // is older than anything of the household's.)
                var stamp: Date = ownPlan.map { plan in
                    max(plan.stamps?[name] ?? plan.stamp ?? .now, plan.before ?? .distantPast)
                } ?? .distantPast
                let hash = Self.hash(item)
                // Changed here while nothing was sent (signed out, say), and not since: as of then,
                // so it isn't lost to an older version there.
                if let noted = saved.changedHere?[name], noted.hash == hash { stamp = max(stamp, noted.at) }
                saved.meta[name] = Meta(id: id, hash: hash, order: item.order, modified: stamp,
                                        orderModified: stamp, systemFields: saved.meta[name]?.systemFields, mac: item.mac)
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
        saved.replacing = nil // another account's own library, or none: nothing to replace
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
        // Not while in a household (or sorting out whether it is): one household at a time.
        guard saved.shared == nil, !settling, saved.joiningTo == nil, saved.switchPending != true else { throw CKError(.operationCancelled) }
        let db = container.privateCloudDatabase
        _ = try? await db.save(CKRecordZone(zoneID: Self.ownZone))
        let shareID = CKRecord.ID(recordName: CKRecordNameZoneWideShare, zoneID: Self.ownZone)
        // Not read (offline, say): not made again, as there may be one.
        do {
            if let existing = try await db.record(for: shareID) as? CKShare { return existing }
        } catch let error as CKError where error.code == .unknownItem || error.code == .zoneNotFound {
            // None yet: made below.
        }
        let share = CKShare(recordZoneID: Self.ownZone)
        share[CKShare.SystemFieldKey.title] = "setPilot Library"
        share.publicPermission = .none
        let (results, _) = try await db.modifyRecords(saving: [share], deleting: [])
        guard let saved = try results[shareID]?.get() as? CKShare else { throw CKError(.internalError) }
        return saved
    }

    /// The share to manage (Manage Household): this account's own library's, or that of the
    /// household it's in (which an administrator may manage too). Nil if there's none; throws
    /// if it couldn't be read (offline, say).
    func shareToManage() async throws -> CKShare? {
        let db = saved.shared != nil ? container.sharedCloudDatabase : container.privateCloudDatabase
        let id = CKRecord.ID(recordName: CKRecordNameZoneWideShare, zoneID: saved.shared != nil ? zoneID : Self.ownZone)
        do {
            return try await db.record(for: id) as? CKShare
        } catch let error as CKError where error.code == .unknownItem || error.code == .zoneNotFound {
            return nil
        }
    }

    /// What this account is in its household (Settings' rows) and, as its owner, who else is.
    /// Not read (offline): as it was.
    func refreshHousehold() async {
        let share: CKShare?
        do {
            share = try await shareToManage()
        } catch {
            // Not read: as it was (in one, at least a member).
            if saved.shared != nil, progress.role == .none || progress.role == .owner { progress.role = .member }
            return
        }
        let others = (share?.participants ?? []).filter { $0.role != .owner }
        if saved.shared == nil {
            progress.role = others.isEmpty ? .none : .owner
            progress.members = others.map(HouseholdMember.init)
            progress.ownShare = share
        } else {
            progress.role = share?.currentUserParticipant?.role == .administrator ? .administrator : .member
            progress.members = []
            progress.ownShare = nil
        }
        progress.roleKnown = true
    }

    /// Signed out, or another Apple ID: what was known of the last one's household is nothing now.
    private func forgetRole() {
        progress.role = .none
        progress.members = []
        progress.ownShare = nil
        progress.roleKnown = false
    }

    /// The owner lets a member add and remove people (an administrator), or not.
    func setAdministrator(_ member: HouseholdMember, _ on: Bool) async {
        guard saved.shared == nil, let share = try? await shareToManage(),
              let participant = share.participants.first(where: { $0.participantID == member.id }) else { return }
        participant.role = on ? .administrator : .privateUser
        do {
            let (results, _) = try await container.privateCloudDatabase.modifyRecords(saving: [share], deleting: [])
            if case .failure(let error)? = results[share.recordID] { progress.notice = "Couldn't change that (\(Self.describe(error))): check you're online, then try again." }
        } catch {
            progress.notice = "Couldn't change that (\(Self.describe(error))): check you're online, then try again."
        }
        await refreshHousehold()
    }

    #if os(macOS)
    /// The Mac's own screen for the share: people, what they can do, stopping sharing.
    func manageOnMac() async {
        guard let share = try? await shareToManage() else {
            progress.notice = "Couldn't open the household's sharing settings: check you're online, then try again."
            return
        }
        let provider = NSItemProvider()
        provider.registerCloudKitShare(share, container: container)
        guard let service = NSSharingService(named: .cloudSharing), service.canPerform(withItems: [provider]) else {
            progress.notice = "This Mac couldn't open the household's sharing settings. Manage it from setPilot on your iPhone or iPad."
            return
        }
        service.delegate = SharingWatcher.shared
        service.perform(withItems: [provider])
    }
    #endif

    /// An invitation opened here (from Messages or Mail): asked about, unless it's this account's own.
    func offer(_ metadata: CKShare.Metadata) {
        guard metadata.participantRole != .owner else {
            progress.notice = "That's the invitation to your own library."
            return
        }
        let zone = metadata.share.recordID.zoneID
        let household = SharedZone(zoneName: zone.zoneName, ownerName: zone.ownerName)
        // A leave under way is finished first, as joining would refuse (unless it's for joining
        // this one, stopped part way: joining it finishes that).
        if saved.leaving != nil, saved.joiningTo?.household != household {
            progress.notice = "Leaving your current household isn't through yet. Check you're online, use Sync Now, then open the invitation again."
            return
        }
        // Put out of it (Keep a Copy or Start Fresh not answered yet): not in it any more, so it
        // can be joined again (joining answers the question). Asked, the one this device is on is
        // gone, whether it's the one asked about or the account went on from it elsewhere.
        let out = saved.leftQuestion != nil
        guard saved.shared != household || out else {
            progress.notice = "You're already in this household."
            return
        }
        progress.invitation = metadata
    }

    /// An invitation accepted: join that household's library,
    /// adding this device's library to it, or replacing this device's with it.
    func join(_ metadata: CKShare.Metadata, addMine: Bool) async {
        // Not while this device's library is still being decided on: that's answered first.
        if saved.switchPending == true {
            progress.notice = "First answer what to do with this device's library now that iCloud is another Apple ID, then open the invitation again."
            return
        }
        if saved.signedOut != nil {
            progress.notice = "Sign in to iCloud first, then open the invitation again."
            return
        }
        // Joined here already, and stopped part way: that's finished rather than started again
        // (before the refusal below: the household it's leaving for this is being left).
        if let intent = saved.joiningTo, intent.household == SharedZone(zoneName: metadata.share.recordID.zoneID.zoneName, ownerName: metadata.share.recordID.zoneID.ownerName) {
            return await resumeJoin(intent)
        }
        if saved.leaving != nil {
            progress.notice = "Leaving your current household isn't through yet. Check you're online, use Sync Now, then open the invitation again."
            return
        }
        // Signed back in: where this device goes is worked out first. Not when it was put out
        // (asked to keep a copy or start fresh): joining answers that, and the lookup waits for it.
        if saved.returning != nil, saved.leftQuestion == nil {
            await findHousehold()
            guard saved.returning == nil else {
                progress.notice = "Couldn't join the household yet: check you're online, then try again."
                return
            }
        }
        // Replacing: what's held here (only on this device, not sent anywhere yet) would be lost.
        if !addMine, saved.newHere?.isEmpty == false {
            progress.notice = "Some of this device's items haven't reached iCloud yet, so it can't join replacing them: they'd be lost. Join adding yours, or first answer the question about them."
            return
        }
        guard !joining else { return }
        joining = true
        defer { joining = false }
        let changes = accountChanges
        let zone = metadata.share.recordID.zoneID
        guard metadata.participantRole != .owner, zone.ownerName != CKCurrentUserDefaultName else { return } // our own share
        let household = SharedZone(zoneName: zone.zoneName, ownerName: zone.ownerName)
        // (Put out of it, not answered yet: not in it, so joined again; telling answers the question.)
        guard saved.shared != household || saved.leftQuestion != nil else {
            progress.notice = "You're already in this household."
            return
        }
        // One household at a time, and this account's own library shared with others is one
        // (people only invited too: once one accepts, it would be). Not known (offline): not joined.
        do {
            if let mine = try await container.privateCloudDatabase.record(for: CKRecord.ID(recordName: CKRecordNameZoneWideShare, zoneID: Self.ownZone)) as? CKShare,
               mine.participants.contains(where: { $0.role != .owner }) {
                progress.notice = "You share your library with a household. To join another, first stop sharing yours (Settings › Manage Household)."
                return
            }
        } catch let error as CKError where error.code == .unknownItem || error.code == .zoneNotFound {
            // Not shared.
        } catch {
            progress.notice = "Couldn't check whether you share your own library: check you're online, then try again."
            return
        }
        // One household at a time: any other the account's in (this device's, or one another
        // device joined that this one hasn't followed yet) is left first, so the account is never
        // in two for its devices to split between.
        let zones: [CKRecordZone.ID]
        do {
            zones = try await container.sharedCloudDatabase.allRecordZones().map(\.zoneID)
        } catch {
            progress.notice = "Couldn't check your current household before joining this one: check you're online, then try again."
            return
        }
        guard accountChanges == changes else { return }
        // The account's in it already (joined on another device, not being left): this device
        // follows that join, rather than starting another.
        if zones.contains(zone), !(saved.toLeave ?? []).contains(household) {
            if saved.shared == nil, saved.leftQuestion == nil {
                // As tapped, if there's no word of how it was joined. Not done (offline), and nothing
                // asked instead: said so, rather than nothing happening.
                if await joinFound(household, answer: addMine) == .skipped, progress.householdQuestion == nil, saved.shared != household {
                    progress.notice = "Couldn't join the household yet: check you're online, then try again."
                }
            } else {
                progress.notice = "You're already in this household on another of your devices. This device joins it once it's caught up: check you're online, then use Sync Now."
            }
            return
        }
        let others = zones.filter { $0.zoneName == Self.ownZone.zoneName && $0 != zone }
        // Replacing what's here from the own library: what's here must have gone up first (it
        // would be lost otherwise). Checked before accepting, which is for the whole account.
        let fromOwn = saved.shared == nil && saved.leftQuestion == nil
        if fromOwn, !addMine {
            let synced = await syncOwn()
            guard accountChanges == changes else { return }
            guard synced else {
                progress.notice = "This device's latest changes haven't reached iCloud yet, so it can't join replacing them: check you're online, then try again."
                return
            }
        }
        // Noted first: a device with this household still to leave doesn't leave it while this
        // goes through (the join record comes only after the telling). Not saved, it's joined all
        // the same: that's only a narrow window.
        await markJoining(household)
        guard accountChanges == changes else { return }
        do {
            _ = try await container.accept(metadata)
        } catch {
            progress.notice = "Couldn't join the household (\(Self.describe(error))): check you're online, then try again."
            return
        }
        guard accountChanges == changes else { return }
        let olds = others.map { SharedZone(zoneName: $0.zoneName, ownerName: $0.ownerName) }
        setToLeave((saved.toLeave ?? []).filter { $0 != household }) // joined again: not to leave
        // In it now: kept until it's through (a quit part way is finished at launch).
        let intent = JoinIntent(household: household, addMine: addMine, leaving: olds, fromOwn: fromOwn, attempt: UUID())
        // (A withdrawal of an earlier join of it with no attempt would take this one's leaves too.)
        saved.withdrawing = saved.withdrawing.map { list in list.filter { $0.household != household || $0.attempt != nil } }
        if saved.withdrawing?.isEmpty == true { saved.withdrawing = nil }
        saved.joiningTo = intent
        persist()
        guard let record = await tell(intent, changes: changes) else { return }
        guard accountChanges == changes else { return }
        await completeJoin(household, addMine: addMine, leaving: olds, record: record, changes: changes)
    }

    /// The account's other devices told of a join (`intent`): what's here sent to the own library
    /// first (replaced here, it would otherwise be lost), a leave record for each household left
    /// for it (so the devices in them follow here), the join record (how, and what this library
    /// had), and one for a household this device was asked about. The join record, or nil if it
    /// couldn't be done (the join's undone if the old ones couldn't be told).
    private func tell(_ intent: JoinIntent, changes: Int) async -> HouseholdJoin?? {
        let household = intent.household
        // What's here sent to the own library first (only if it's the own library's): replacing,
        // it must have gone, or it'd be lost (tried again later otherwise).
        if intent.fromOwn == true {
            let synced = await syncOwn()
            guard accountChanges == changes else { return nil }
            if !synced, !intent.addMine {
                progress.notice = "This device's latest changes haven't reached iCloud yet, so joining the household (replacing them) is waiting for them. It's finished once they've gone: check you're online, then use Sync Now."
                return nil
            }
        }
        // Noted again (that may have waited long, and this is resumed later too): a device with
        // this household to leave still doesn't leave it before the join record's there.
        await markJoining(household)
        guard accountChanges == changes else { return nil }
        for old in intent.leaving {
            let was = membership.flatMap { $0.zone == old ? $0 : nil } ?? Membership(zone: old, joinID: nil, joinedAt: nil)
            var leave = HouseholdLeave(zone: old, joinID: was.joinID, mode: .joined(household), at: .now)
            leave.addMine = intent.addMine
            leave.attempt = intent.attempt
            let read = await readRecord(Self.leaveRecordName(old))
            guard accountChanges == changes else { return nil }
            guard !read.failed, await saveRecord(Self.leaveRecordName(old), type: Self.leaveRecordType, leave, over: read.record) == .saved else {
                // The leave records written for it so far (a save that looked failed may have gone
                // through too) mustn't send the devices still in those households after it. Noted
                // before anything else, so it's done even if this stops part way.
                addWithdrawal(LeaveWithdrawal(household: household, attempt: intent.attempt,
                                              zones: intent.leaving + [saved.shared, saved.leftQuestion?.zone].compactMap { $0 }))
                // Not in two at once: the new one's left again (or noted to be, if it can't be
                // now), to be joined once this can go.
                await leaveZone(household, changes: changes)
                saved.joiningTo = nil
                if case .joined(household)? = saved.leaving?.mode { saved.leaving = nil }
                persist()
                sendChangedHere() // staying where it is
                progress.notice = "Couldn't leave your current household to join this one: check you're online, then try again."
                await withdrawPending(changes: changes)
                // Put out and asked, the join meant to answer it: asked again now (start() didn't,
                // while it was under way).
                if accountChanges == changes, saved.leftQuestion != nil {
                    askLeftAgain()
                    Self.showQuestion()
                }
                return nil
            }
            if saved.shared == old {
                saved.leaving = leave
                persist()
            }
        }
        let record = await leaveJoinRecord(household, addMine: intent.addMine)
        guard accountChanges == changes else { return nil }
        // Put out of one and asked about it: the account's other devices follow here instead
        // (once the join record's there for them). Not over an answer another device gave.
        // So too for the one this device is in, if it's gone (not among those being left) and it
        // hadn't noticed yet: the others may be asked about it already.
        let unnoticed = membership.flatMap { $0.zone != household && !intent.leaving.contains($0.zone) ? $0 : nil }
        if let put = saved.leftQuestion ?? unnoticed {
            let read = await readRecord(Self.leaveRecordName(put.zone))
            // (One a newer setPilot wrote, which this build can't read, is an answer too.)
            let answered = read.decoded(HouseholdLeave.self).map { $0.ends(put) && !$0.isJoin } ?? read.exists
            if !read.failed, !answered {
                var leave = HouseholdLeave(zone: put.zone, joinID: put.joinID, mode: .joined(household), at: .now)
                leave.addMine = intent.addMine
                leave.attempt = intent.attempt
                _ = await saveRecord(Self.leaveRecordName(put.zone), type: Self.leaveRecordType, leave, over: read.record)
            }
        }
        guard accountChanges == changes, saved.joiningTo?.household == household else { return nil }
        saved.joiningTo?.told = true
        persist()
        return record
    }

    /// A join stopped part way (relaunched): the telling redone if it hadn't got through, then
    /// the rest. Not while a lookup could take it over (`joining`).
    private func resumeJoin(_ intent: JoinIntent) async {
        guard !joining else { return }
        joining = true
        defer { joining = false }
        let changes = accountChanges
        guard let zones = try? await container.sharedCloudDatabase.allRecordZones(), accountChanges == changes,
              saved.joiningTo == intent else { return }
        func listed(_ zone: SharedZone) -> Bool {
            zones.contains(where: { $0.zoneID.zoneName == zone.zoneName && $0.zoneID.ownerName == zone.ownerName })
        }
        guard listed(intent.household) else {
            var staying = true
            var stayIn: SharedZone?
            if let leave = saved.leaving, case .joined(intent.household) = leave.mode {
                if listed(leave.zone) {
                    // Still in the one it was leaving for it: stays there (not taken as put out of it).
                    stayIn = leave.zone
                } else {
                    // That one's gone too: the leave's finished now (asked as put out), not left
                    // showing as under way until the next Sync Now. After this, as it waits
                    // while `joining`.
                    staying = false
                    Task { await finishLeaving(leave) }
                }
            }
            if staying {
                // The leave records the telling wrote for it mustn't send the account's other
                // devices after it (nor answer for this one the question it's asked again below):
                // noted before the join's forgotten. Only of households still there: told, those
                // left for it may be gone, and their records are where the other devices went
                // (the one asked about too).
                // (Not when finishLeaving's to run: it gives up while `joining`, which this would hold.)
                var withdrawn = (intent.leaving + [saved.shared].compactMap { $0 }).filter(listed)
                if intent.told != true, let put = saved.leftQuestion?.zone { withdrawn.append(put) }
                addWithdrawal(LeaveWithdrawal(household: intent.household, attempt: intent.attempt, zones: withdrawn))
            }
            saved.joiningTo = nil // not there after all
            if let stayIn { stay(in: stayIn) }
            persist()
            if staying {
                sendChangedHere()
                await withdrawPending(changes: changes)
                guard accountChanges == changes else { return }
            }
            // Put out and asked, the join meant to answer it: asked again (not at launch, while it was under way).
            if saved.leftQuestion != nil {
                askLeftAgain()
                Self.showQuestion()
            }
            return
        }
        if saved.shared == intent.household {
            saved.joiningTo = nil // through already
            persist()
            return
        }
        let record: HouseholdJoin?
        if intent.told == true {
            // Noted again while it's under way (the telling does so otherwise): its join record
            // may not have saved.
            await markJoining(intent.household)
            guard accountChanges == changes, saved.joiningTo == intent else { return }
            record = await readRecord(Self.joinRecordName).join(for: intent.household)
        } else {
            guard let told = await tell(intent, changes: changes) else { return }
            record = told
        }
        guard accountChanges == changes, saved.joiningTo?.household == intent.household else { return }
        await completeJoin(intent.household, addMine: intent.addMine, leaving: intent.leaving, record: record, changes: changes)
    }

    /// The rest of a join (and again at launch, if it didn't get through): the old households
    /// left (or kept to try again), then in.
    /// `changes`: the account changes when the join began (signed out meanwhile, it waits).
    private func completeJoin(_ household: SharedZone, addMine: Bool, leaving olds: [SharedZone], record: HouseholdJoin?, changes: Int) async {
        // (Not the one joined: it may have been left before, and joined again now.)
        setToLeave(Array(Set((saved.toLeave ?? []) + olds).subtracting([household]).sorted { $0.zoneName + $0.ownerName < $1.zoneName + $1.ownerName }), added: olds)
        persist()
        var stillIn: [SharedZone] = []
        for old in saved.toLeave ?? [] {
            do {
                _ = try await container.sharedCloudDatabase.deleteRecordZone(withID: CKRecordZone.ID(zoneName: old.zoneName, ownerName: old.ownerName))
            } catch let error as CKError where error.code == .zoneNotFound || error.code == .unknownItem {
                // Already gone: left all the same.
            } catch {
                // Tried again (checkHousehold) until it's gone: one household at a time.
                stillIn.append(old)
            }
        }
        // (Signed out meanwhile: finished on signing back in, which resumes it.)
        guard accountChanges == changes, saved.joiningTo?.household == household else { return }
        if !addMine { clearLibraryHere() }
        // Back into the one it was put out of (or was in when signed out), adding: what changed
        // here and hadn't gone up is newer than the household's, so it keeps its own stamp rather
        // than being offered as oldest. (Taken before the switch, which forgets what was synced.)
        // (Put out and asked, the household this device is on is gone, whichever is asked about.)
        let rejoining = (saved.leftQuestion.map { $0.zone == household || saved.shared == household } ?? false)
            || saved.returning?.membership?.zone == household
        let unsent = addMine && rejoining ? unsentHere() : Unsent()
        // So too what was deleted here meanwhile and hadn't gone (seeding only saves): deleted there.
        var deleted: Set<String> = []
        if addMine && rejoining {
            deleted = (saved.deletedHere ?? []).union(saved.deleting).union(saved.returning?.gone ?? [])
            for kind in Kind.allCases { deleted.subtract(current(kind).keys.map { Self.recordName(kind, $0) }) }
        }
        progress.leftHousehold = false
        switchLibrary(to: household, join: record) // (the question about a household gone goes with it)
        for (kind, list) in unsent.items {
            for (id, (_, at)) in list where at > .distantPast {
                let name = Self.recordName(kind, id)
                saved.meta[name]?.modified = at
                saved.meta[name]?.orderModified = unsent.orders[name] ?? at
            }
        }
        if !deleted.isEmpty {
            saved.deleting.formUnion(deleted)
            engine?.state.add(pendingRecordZoneChanges: deleted.map { .deleteRecord(CKRecord.ID(recordName: $0, zoneID: zoneID)) })
        }
        setToLeave(stillIn)
        persist()
    }

    private var joining = false

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
        let join = HouseholdJoin(zone: household, addMine: addMine, items: items, joinID: UUID(), at: .now)
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
            let existing: CKRecord?
            do {
                existing = try await db.record(for: id)
            } catch let error as CKError where error.code == .unknownItem {
                existing = nil
            } catch {
                try? await Task.sleep(for: .seconds(1)) // a blip: tried again
                continue
            }
            // Gone (the household's been left): not brought back by an update.
            if !replacing, existing == nil { return }
            var merged = join
            let oldData = existing.flatMap { r -> Data? in r.encryptedValues["join"] }
            let old = oldData.flatMap { try? JSONDecoder().decode(HouseholdJoin.self, from: $0) }
            var encoded = try? JSONEncoder().encode(merged)
            if !replacing, existing != nil {
                // Another household's or join's (one joined since on another device), one this
                // build can't read, or one marked left: left as it is, not overwritten with this one's.
                guard let old, old.left != true, old.zone == join.zone, join.joinID == nil || old.joinID == join.joinID else { return }
                merged.addMine = old.addMine
                merged.joinID = old.joinID
                merged.at = old.at
                merged.items = old.items.merging(join.items) { max($0, $1) }
                // Only the items change in what's there: fields a newer build added stay.
                guard let oldData, var top = (try? JSONSerialization.jsonObject(with: oldData)) as? [String: Any],
                      let items = (try? JSONEncoder().encode(merged.items)).flatMap({ try? JSONSerialization.jsonObject(with: $0) }) else { return }
                top["items"] = items
                encoded = JSONSerialization.isValidJSONObject(top) ? try? JSONSerialization.data(withJSONObject: top) : nil
            }
            guard let data = encoded else { return }
            let record = existing ?? CKRecord(recordType: Self.joinRecordType, recordID: id)
            record.encryptedValues["join"] = data
            do {
                // Only if unchanged since read (two devices following at once each add theirs).
                let (results, _) = try await db.modifyRecords(saving: [record], deleting: [], savePolicy: .ifServerRecordUnchanged)
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
        while let running = householdLookup {
            // One under way: its answer, if it was asked the same; otherwise this one after it.
            if runningChoice == choice { return await running.value }
            _ = await running.value
        }
        runningChoice = choice
        let task = Task {
            let result = await lookUpHousehold(after: choice)
            // Cleared as it ends (not by whoever awaited it first), so one waiting with another
            // choice starts its own rather than waiting on this one again.
            householdLookup = nil
            runningChoice = nil
            return result
        }
        householdLookup = task
        return await task.value
    }

    private var runningChoice: AccountChoice?

    private func lookUpHousehold(after choice: AccountChoice?) async -> HouseholdLookup {
        // Not while the question about another Apple ID is open: this device's library is
        // decided on first (answering it looks again).
        guard !joining, saved.joiningTo == nil, saved.shared == nil, saved.switchPending != true, saved.leftQuestion == nil, engine != nil else { return .skipped }
        guard let zones = try? await container.sharedCloudDatabase.allRecordZones() else { return .skipped }
        guard saved.shared == nil, saved.switchPending != true, saved.leftQuestion == nil else { return .skipped } // joined (or switched) meanwhile
        let households = zones.filter { $0.zoneID.zoneName == Self.ownZone.zoneName && $0.zoneID.ownerName != CKCurrentUserDefaultName }
            .map { SharedZone(zoneName: $0.zoneID.zoneName, ownerName: $0.zoneID.ownerName) }
            .filter { !(saved.toLeave ?? []).contains($0) } // being left
        let household = households.first(where: { $0 == saved.householdJoin?.zone }) ?? households.first
        // Signed back in: where this goes depends on where it was.
        if let back = saved.returning, choice == nil {
            return await returned(back, to: household)
        }
        guard let household else {
            // In none, with what's here held for where it goes (a household left for another that's
            // gone too, say): the account's own library, adding it.
            if saved.newHere != nil, saved.askingFresh != true { switchKeeping(newItems(nil), to: nil) }
            return .none
        }
        switch choice {
        case .merge?:
            // Added, as answered, but not what the household's had (it may have removed it since):
            // the account's own library synced first, for the join record.
            guard await syncOwn(), saved.shared == nil, saved.switchPending != true else { return .skipped }
            let record = knowledge(of: household)
            if record == nil {
                switchLibrary(to: household)
            } else {
                switchKeeping(newItems(record), to: household)
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

    /// Signed back in (`back`: where this device was, and what it had then), with the account
    /// in `household` (or none): what's changed here since goes where the account is now, as it
    /// would for another device of it (joining, or following a leave); the rest is the library's.
    private func returned(_ back: SignedOut, to household: SharedZone?) async -> HouseholdLookup {
        // The account's join record as it is now (a rejoin while signed out is another membership).
        guard await syncOwn(), saved.returning != nil, saved.shared == nil else { return .skipped }
        // Deleted here while signed out (noted on signing in, before anything was fetched):
        // deleted there too (the same library).
        let gone = saved.returning?.gone ?? back.gone ?? [] // (as it is now: deletions meanwhile too)
        if let household {
            // The same membership (not a later join of it): what's changed here goes in.
            if let was = back.membership, was.zone == household,
               saved.householdJoin.map({ $0.zone != household || was.joinID == nil || $0.joinID == nil || $0.joinID == was.joinID }) ?? true {
                // Unless this device was leaving it (a save that looked failed but went through):
                // that's finished, not undone by going back in.
                if saved.leaveAttempts?.isEmpty == false {
                    let read = await readRecord(Self.leaveRecordName(was.zone))
                    guard !read.failed, saved.returning != nil, saved.shared == nil else { return .skipped }
                    if let leave = read.decoded(HouseholdLeave.self), leave.ends(was), isOwn(leave) {
                        await resumeOwn(leave)
                        return .none
                    }
                }
                switchKeeping(newItems(nil), deleting: gone, to: household, keepingAttempts: true)
                return .joined
            }
            // Joined since (here or from the account's own library): as any device follows a join
            // (deletions here of what it brought go too).
            return await joinFound(household, deleting: gone)
        }
        guard let was = back.membership else {
            // The account's own library, as it was and is: what's changed here goes in.
            switchKeeping(newItems(nil), deleting: gone, to: nil)
            return .none
        }
        // In a household then, in none now: left meanwhile (on another device, which says how),
        // or this account was put out of it, with no device yet asked what to keep.
        let read = await readRecord(Self.leaveRecordName(was.zone))
        guard !read.failed, saved.returning != nil, saved.shared == nil else { return .skipped }
        if let leave = read.decoded(HouseholdLeave.self), leave.ends(was) {
            // This device's own (its save looked failed): finished here, not followed.
            if isOwn(leave) {
                await resumeOwn(leave)
            } else {
                follow(leave, chained: was.joinedElsewhere == true)
            }
        } else if read.undecodable(HouseholdLeave.self), !predates(read, was) {
            needsUpdate() // answered with a newer setPilot: not asked again over it
        } else {
            askLeft(was, selfLeft: back.leftSelf == true)
        }
        return .none
    }

    /// A household this account joined on another device: joined here too, keeping only what's
    /// new here since (HouseholdJoin).
    /// `answer`: from an invitation opened here, joined adding (or replacing) as tapped there.
    private func joinFound(_ household: SharedZone, deleting gone: Set<String> = [], answer: Bool? = nil) async -> HouseholdLookup {
        // The account's own library synced both ways first: what the device that joined left,
        // and what's here sent (so nothing's lost). Not now if that can't be done (offline): the
        // next launch or Sync Now tries again.
        guard await syncOwn() else { return .skipped }
        guard saved.shared == nil, saved.switchPending != true else { return .skipped }
        guard let record = knowledge(of: household) else {
            // No word of how it was joined (an older setPilot, or the record didn't save): as
            // tapped on the invitation here, or asked.
            guard let answer else {
                ask(.noRecord, household)
                return .skipped
            }
            // Adding: everything here, as on joining adding (the household's own versions win).
            var items = answer ? newItems(nil) : [:]
            if saved.newHere == nil { items = items.mapValues { list in list.mapValues { entry in (entry.0, Date.distantPast) } } }
            switchKeeping(items, to: household, adding: answer)
            return .joined
        }
        let new = newItems(record)
        // Joined adding: what's new goes in. Joined replacing, with something new here: asked
        // whether it goes in.
        if new.isEmpty || record.addMine {
            switchKeeping(new, deleting: record.addMine ? gone.filter { record.items[$0] != nil } : [], to: household, adding: record.addMine)
            return .joined
        }
        ask(.newItems(new.values.reduce(0) { $0 + $1.count }), household)
        return .skipped
    }

    /// The record the device that joined a household left, if it's for this one.
    private func knowledge(of household: SharedZone) -> HouseholdJoin? {
        saved.householdJoin.flatMap { $0.zone == household ? $0 : nil }
    }

    /// What's here that a household doesn't know of: not among what it had (record name, when last
    /// changed then), or changed since. Each with when it last changed (now, if never synced).
    /// Held (`newHere`: after leaving a household, or signing back in): those.
    private func newItems(_ record: HouseholdJoin?) -> [Kind: [String: (Item, Date)]] {
        var out: [Kind: [String: (Item, Date)]] = [:]
        let had = record?.items ?? [:]
        for kind in Kind.allCases {
            for (id, item) in current(kind) {
                let name = Self.recordName(kind, id)
                if let held = saved.newHere {
                    if let at = held[name] { out[kind, default: [:]][id] = (item, at) }
                    continue
                }
                let modified = saved.meta[name]?.modified
                let isNew = had[name].map { then in modified.map { $0 > then } ?? true } ?? true
                if isNew { out[kind, default: [:]][id] = (item, modified ?? .now) }
            }
        }
        return out
    }

    /// What unsentHere finds: each item with when its content changed, and (by record name) when
    /// its place did, apart from its content (a move alone isn't a newer version of it).
    /// With no place time, it's the content's.
    private struct Unsent {
        var items: [Kind: [String: (Item, Date)]] = [:]
        var orders: [String: Date] = [:]
    }

    /// What's here that the library it's synced with hasn't had: never sent, or changed and not
    /// sent, with when it changed. Held (`newHere`): those.
    /// `since`: synced items changed at or after it count too (the copy another device made was as
    /// of then; with `.distantPast`, all of them, those stamped as oldest too).
    private func unsentHere(since: Date? = nil) -> Unsent {
        if saved.newHere != nil {
            var out = newItems(nil)
            // Signed back in, and all of it wanted (a copy that may never be made): what's as it
            // was at signing out too, as oldest (whatever else has it wins).
            if since == Date.distantPast, saved.returning != nil {
                for kind in Kind.allCases {
                    for (id, item) in current(kind) where out[kind]?[id] == nil {
                        out[kind, default: [:]][id] = (item, .distantPast)
                    }
                }
            }
            return Unsent(items: out)
        }
        var out = Unsent()
        for kind in Kind.allCases {
            for (id, item) in current(kind) {
                let name = Self.recordName(kind, id)
                let hash = Self.hash(item)
                // Changed while settling: as of when (noted by localChanged), or now if not noted.
                var changedAt = Date.now
                if let noted = saved.changedHere?[name], noted.hash == hash { changedAt = noted.at }
                guard let meta = saved.meta[name] else {
                    out.items[kind, default: [:]][id] = (item, changedAt)
                    continue
                }
                // Changed while nothing was sent (settling): its content isn't what was synced.
                // Changed before and not sent: as of its change here.
                let changed = meta.unsent || meta.hash != hash
                if changed || since.map({ meta.modified >= $0 }) == true {
                    out.items[kind, default: [:]][id] = (item, meta.hash != hash ? changedAt : meta.modified)
                    // Its place: moved while nothing was sent (not noted), as of now; otherwise as
                    // last moved (only moved, its content keeps its own older time).
                    out.orders[name] = meta.order != item.order ? .now : meta.orderModified
                }
            }
        }
        return out
    }

    /// Switches to a library (a household's, or with nil the account's own), keeping here only
    /// `items`, which go up to it (stamped when they were changed, so the later change wins).
    /// `deleting`: deletions here that hadn't gone up (carried from the household left).
    /// `adding`: what's here is added or kept, not replaced (or started afresh): the library's data
    /// this build can't read stays too. `keepingAttempts`: see switchLibrary.
    /// `orders`: when items' places changed, by record name, where that's not their content's time.
    private func switchKeeping(_ items: [Kind: [String: (Item, Date)]], orders: [String: Date] = [:], deleting carried: Set<String> = [], to target: SharedZone?, adding: Bool = true, keepingAttempts: Bool = false) {
        let deleting = carried.union(saved.deletedHere ?? [])
        // The join record (if there is one) learns what this device brought: a device joining
        // later mustn't take those for new.
        var kept: HouseholdJoin?
        if let target, var record = knowledge(of: target) {
            for (kind, list) in items {
                for (id, (_, modified)) in list { record.items[Self.recordName(kind, id)] = modified }
            }
            kept = record
            Task { await saveJoinRecord(record) }
        }
        // (Back on the own library with it still becoming a copy: that goes on.)
        switchLibrary(to: target, offerMine: false, join: kept, replacing: target == nil ? saved.replacing : nil, keepingAttempts: keepingAttempts)
        clearLibraryHere(keepingUnreadable: adding)
        var pending: [CKSyncEngine.PendingRecordZoneChange] = deleting.map { .deleteRecord(CKRecord.ID(recordName: $0, zoneID: zoneID)) }
        saved.deleting.formUnion(deleting)
        for (kind, list) in items {
            for (id, (item, modified)) in list {
                let name = Self.recordName(kind, id)
                saved.meta[name] = Meta(id: id, hash: Self.hash(item), order: item.order, modified: modified, orderModified: orders[name] ?? modified, mac: item.mac)
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
        /// Left on another device, starting fresh, and this many items here hadn't gone up.
        case leftFresh(Int)
    }

    private func ask(_ question: HouseholdQuestion, _ household: SharedZone?) {
        saved.pendingHousehold = household
        saved.pendingAskedAt = .now
        persist()
        progress.householdQuestion = question
        Self.showQuestion()
    }

    /// The questions are asked in the main window: on the Mac, opened for them (the app may be
    /// in the menu bar only).
    static func showQuestion() {
        #if os(macOS)
        HandoffRouter.shared.open(.controls)
        #endif
    }

    /// The answer to HouseholdQuestion: add this device's (new) items, leave them out, or (nil)
    /// not now, to be asked again at the next launch.
    func answerHousehold(_ question: HouseholdQuestion?, addMine: Bool?) {
        progress.householdQuestion = nil
        // Left fresh elsewhere: what's only here kept in the (empty) own library, or not.
        if case .leftFresh? = question {
            guard let addMine, saved.switchPending != true, saved.askingFresh == true else { return }
            if addMine {
                switchKeeping(newItems(nil), to: nil)
            } else {
                switchKeeping([:], to: nil, adding: false)
            }
            return
        }
        guard let addMine, let household = saved.pendingHousehold else { return }
        guard saved.shared != household else { return } // joined meanwhile (the join record came)
        Task {
            let changes = accountChanges
            // Not done now (offline, say): kept, and asked again at the next launch or Sync Now.
            guard await syncOwn(), saved.shared == nil, saved.switchPending != true else {
                progress.notice = "Couldn't join the household yet: check you're online, then use Sync Now (it's asked again then)."
                return
            }
            // Still there (it may have been left, or stopped being shared, while the question was up).
            guard let zones = try? await container.sharedCloudDatabase.allRecordZones() else {
                progress.notice = "Couldn't join the household yet: check you're online, then use Sync Now (it's asked again then)."
                return
            }
            guard accountChanges == changes else { return } // signed out meanwhile: asked again later
            guard zones.contains(where: { $0.zoneID.zoneName == household.zoneName && $0.zoneID.ownerName == household.ownerName }),
                  saved.shared == nil else {
                saved.pendingHousehold = nil
                persist()
                // Where what's held here goes, then (it may have been waiting on this answer).
                if saved.shared == nil { await findHousehold() }
                return
            }
            let record = knowledge(of: household)
            // Left out: the join record learns them too, so the account's other devices (which
            // get them through its own library) aren't asked about them again.
            if !addMine, var record {
                for (kind, list) in newItems(record) {
                    for (id, (_, modified)) in list { record.items[Self.recordName(kind, id)] = modified }
                }
                Task { await saveJoinRecord(record) }
            }
            var items: [Kind: [String: (Item, Date)]] = [:]
            // Deleted here while signed out: what the household had of them goes too.
            let gone = (saved.returning?.gone ?? []).filter { record?.items[$0] != nil }
            if addMine {
                items = newItems(record)
                // No record (everything here, as on joining adding): the household's own versions win.
                if record == nil, saved.newHere == nil { items = items.mapValues { list in list.mapValues { entry in (entry.0, Date.distantPast) } } }
            }
            switchKeeping(items, deleting: Set(gone), to: household, adding: addMine)
        }
    }

    /// The account's own library fetched and this device's changes sent, offering it first if it
    /// never has been. Returns whether all of it went.
    private func syncOwn() async -> Bool {
        guard let engine, saved.shared == nil else { return false }
        let changes = accountChanges
        // (Not while it's settling, or the Apple ID question's open: what goes is decided after.)
        if !saved.seeded, saved.switchPending != true { seed() }
        do {
            try await engine.fetchChanges()
            try await engine.sendChanges()
        } catch {
            return false
        }
        // Only if nothing changed meanwhile: an account change (signing in or out) empties the
        // queue without sending it, which would look the same as all of it having gone.
        // (This device's own changes gone: a conflict re-sent, or another's, doesn't hold it up.)
        guard accountChanges == changes, engine === self.engine, saved.seeded || settling,
              !saved.meta.values.contains(where: \.unsent), saved.deleting.isEmpty else { return false }
        return true
    }

    // MARK: Leaving a household

    /// The membership this device has (its household, the join, since when).
    private var membership: Membership? {
        saved.shared.map { zone in
            Membership(zone: zone, joinID: knowledge(of: zone)?.joinID, joinedAt: saved.joinedAt, fetchedAt: saved.householdFetched)
        }
    }

    /// Leaves the household (Settings' Leave Household), or answers "you're no longer in it":
    /// the account's own library becomes a copy of it (`keep`) or empty (start fresh). Written
    /// first for the account's other devices, which follow (HouseholdLeave); then the household's
    /// left, and the own library made so. Not done (offline, say): nothing changes, and it says so.
    func leaveHousehold(keep: Bool) async {
        let changes = accountChanges
        var put = saved.leftQuestion
        guard var was = put ?? membership, saved.leaving == nil else { return }
        // Not while joining another household (that switches the library under it): finished first.
        if joining || saved.joiningTo != nil {
            progress.notice = "Joining the other household isn't through yet: check you're online, use Sync Now, then try again."
            return
        }
        progress.leftHousehold = false
        var fetched = false
        let fetchStarted = Date.now.addingTimeInterval(-120) // (clocks a little apart)
        // Signed back in: what's here isn't the household as last fetched (it may have been removed
        // on signing out, and misses what changed meanwhile), so the others bring all they have.
        let asFetched = saved.returning == nil
        if put == nil {
            // Up to date first: this copy is what it becomes.
            fetched = (try? await engine?.fetchChanges()) != nil
        }
        guard !leavingNow else { return } // tapped again while it's under way
        leavingNow = true
        defer { leavingNow = false }
        for _ in 0..<4 {
            let read = await readRecord(Self.leaveRecordName(was.zone))
            guard accountChanges == changes else { return }
            guard !read.failed else { break }
            // Followed meanwhile (the household found gone, as another device left it): done.
            guard saved.leaving == nil, put != nil ? saved.leftQuestion == put : saved.shared == was.zone else { return }
            // This device's own, from a save that looked failed but went through, while still in the
            // household (no other device follows it before the household's left): written over
            // below, as chosen now.
            let redo = read.decoded(HouseholdLeave.self).map { put == nil && $0.ends(was) && isOwn($0) } ?? false
            // Already left (or answered) on another device: as that one said. (Left for another
            // household that isn't there, it's no answer: this one is.)
            if !redo, let leave = read.decoded(HouseholdLeave.self), leave.ends(was) {
                // This device's own, put out of the household (the others may be following it
                // already): finished as it was written, and said so if that isn't what was tapped.
                if isOwn(leave) {
                    let chosen: HouseholdLeave.Mode = keep ? .keep : .fresh
                    await resumeOwn(leave)
                    if leave.mode != chosen {
                        progress.notice = "Your earlier answer on this device had already gone through, so that's what's done: \(leave.mode == .keep ? "keeping a copy" : "starting fresh")."
                    }
                    return
                }
                // Left for another household that's there: followed there. Gone too, and its own
                // leave says where the account went since: followed on (followJoin), as that's
                // the answer now.
                var standing = !leave.isJoin
                var answer = leave
                if case .joined = leave.mode {
                    guard let zones = try? await container.sharedCloudDatabase.allRecordZones() else { break } // not known: tried again
                    let end = await chainEnd(leave, zones: zones)
                    guard accountChanges == changes else { return }
                    guard saved.leaving == nil, put != nil ? saved.leftQuestion == put : saved.shared == was.zone else { return }
                    if case .failed = end { break } // not known: tried again
                    if case .newer = end { return needsUpdate() } // answered with a newer setPilot: not overwritten
                    if case .unanswered(let target, let since) = end {
                        // Put out of the one the account went on to, with no word yet: that's what
                        // this answers, in its record (so the first answer is the one for all).
                        // This device was never in it, so has no copy of it.
                        if put == nil {
                            await leaveZone(was.zone, changes: changes)
                            guard accountChanges == changes, saved.leaving == nil, saved.shared == was.zone else { return }
                        }
                        was = Membership(zone: target, joinID: nil, joinedAt: since, joinedElsewhere: true)
                        put = was
                        saved.leftQuestion = was
                        saved.leftSelf = nil
                        persist()
                        continue
                    }
                    if case .leave(let last) = end { answer = last }
                    if case .noWord = end { standing = false } else { standing = true }
                }
                guard accountChanges == changes else { return }
                if standing {
                    saved.leftQuestion = nil
                    // Leaving here as asked (the other device may not have left it yet).
                    if put == nil {
                        await leaveZone(was.zone, changes: changes)
                        guard accountChanges == changes, saved.shared == was.zone else { return }
                    }
                    follow(leave, chained: was.joinedElsewhere == true)
                    if progress.householdQuestion == nil { answeredElsewhere(answer) }
                    return
                }
            } else if read.undecodable(HouseholdLeave.self), !predates(read, was) {
                return needsUpdate() // answered with a newer setPilot: not overwritten (an earlier membership's is)
            }
            // (Never in it: what's here is no copy of it, so the others bring all they have.)
            let noCopy = was.joinedElsewhere == true
            var leave = HouseholdLeave(zone: was.zone, joinID: was.joinID, mode: keep ? .keep : .fresh, at: .now,
                                       copyAsOf: asFetched && !noCopy ? (fetched ? fetchStarted : was.fetchedAt ?? was.joinedAt) : nil,
                                       joinedAt: knowledge(of: was.zone)?.at ?? was.joinedAt)
            if noCopy { leave.noCopy = true }
            // Kept before the save: if its answer's lost but it went through, the record's known
            // later as this device's leave (resumed, not followed).
            // (Every attempt kept: an earlier one may be the one in the record.)
            let attempt = UUID()
            leave.attempt = attempt
            saved.leaveAttempts = (saved.leaveAttempts ?? []).union([attempt])
            persist()
            let result = await saveRecord(Self.leaveRecordName(was.zone), type: Self.leaveRecordType, leave, over: read.record)
            guard accountChanges == changes else { return } // another account now: not its leave
            switch result {
            case .saved:
                saved.leaving = leave
                saved.leftQuestion = nil
                persist()
                await finishLeaving(leave)
                return
            case .changed:
                continue // another device answered at the same moment: read again
            case .failed:
                break
            }
            break
        }
        // (Put out: asked again at launch, Sync Now or coming back to the app, and from Settings.)
        progress.notice = "Couldn't leave the household now: check you're online, then try again."
    }

    private var leavingNow = false
    private var followingJoin = false

    /// The rest of this device's leave, once its record's written (and again at launch, if it
    /// didn't get through): the household left, then the own library made what's here.
    private func finishLeaving(_ leave: HouseholdLeave) async {
        guard saved.switchPending != true else { return }
        let changes = accountChanges
        // Left for another household, and stopped part way (relaunched): the join's finished
        // here (it was accepted), or, not there after all, asked as if put out.
        if case .joined(let target) = leave.mode {
            // The join's noted: that's what's finished (all the households left for it).
            if let intent = saved.joiningTo, intent.household == target { return await resumeJoin(intent) }
            guard !joining, let zones = try? await container.sharedCloudDatabase.allRecordZones(), saved.leaving == leave,
                  accountChanges == changes else { return }
            let was = membership ?? Membership(zone: leave.zone, joinID: leave.joinID, joinedAt: nil)
            if zones.contains(where: { $0.zoneID.zoneName == target.zoneName && $0.zoneID.ownerName == target.ownerName }) {
                let read = await readRecord(Self.joinRecordName)
                // (How it was joined is known from the leave; the record only to keep.)
                guard !read.failed || leave.addMine != nil else { return } // tried again later
                let record = read.join(for: target)
                guard saved.leaving == leave, accountChanges == changes else { return }
                // The old one left (or left to try again), then in, as it was joined.
                let old = CKRecordZone.ID(zoneName: leave.zone.zoneName, ownerName: leave.zone.ownerName)
                var stillIn: [SharedZone] = []
                if zones.contains(where: { $0.zoneID == old }) {
                    if (try? await container.sharedCloudDatabase.deleteRecordZone(withID: old)) == nil { stillIn.append(leave.zone) }
                }
                guard saved.leaving == leave, accountChanges == changes else { return }
                let addMine = leave.addMine ?? record?.addMine ?? true
                // (Noted before the switch, while the join known here is still the old one's.)
                if !stillIn.isEmpty { setToLeave(Array(Set((saved.toLeave ?? []) + stillIn)), added: stillIn) }
                if !addMine { clearLibraryHere() }
                switchLibrary(to: target, join: record)
            } else if zones.contains(where: { $0.zoneID.zoneName == leave.zone.zoneName && $0.zoneID.ownerName == leave.zone.ownerName }) {
                // The one joined has gone, and the one it was leaving is still here: stays in it
                // (not taken as put out of it), going back into it if it was signed out part way.
                // Its leave record mustn't send the account's other devices in it after the join:
                // noted before the leave's forgotten.
                addWithdrawal(LeaveWithdrawal(household: target, attempt: leave.attempt, zones: [leave.zone]))
                stay(in: leave.zone)
                persist()
                sendChangedHere()
                householdFailed("Couldn't join the other household: its invitation is no longer there")
                await withdrawPending(changes: changes)
            } else {
                saved.leaving = nil
                askLeft(was)
            }
            return
        }
        do {
            // (Also when this device isn't on it any more: signed out and back in part way.)
            _ = try await container.sharedCloudDatabase.deleteRecordZone(withID: CKRecordZone.ID(zoneName: leave.zone.zoneName, ownerName: leave.zone.ownerName))
        } catch let error as CKError where error.code == .zoneNotFound || error.code == .unknownItem {
            // Already gone (put out of it): left all the same.
        } catch {
            // Still in it (offline, say): tried again at the next launch or Sync Now.
            householdFailed("Couldn't leave the household yet: check you're online, then use Sync Now")
            return
        }
        guard saved.leaving == leave else { return }
        // The join record as it is now (devices that followed late added what they brought).
        let joinRead = await readRecord(Self.joinRecordName)
        let joinRecord = joinRead.join(for: leave.zone)
        guard saved.leaving == leave, accountChanges == changes else { return }
        // This membership's join record goes with it: a later invitation to the same household
        // mustn't be taken for this join (its items, how it was joined). Marked left rather than
        // deleted, and only if it's as read: one another device saved meanwhile (joining another
        // household) stays.
        if let joinRecord, let record = joinRead.record,
           leave.joinID.map({ $0 == joinRecord.joinID }) ?? (joinRecord.at.map { $0 <= leave.at } ?? true) {
            var left = joinRecord
            left.left = true
            if let data = try? JSONEncoder().encode(left) {
                record.encryptedValues["join"] = data
                _ = try? await container.privateCloudDatabase.modifyRecords(saving: [record], deleting: [], savePolicy: .ifServerRecordUnchanged)
            }
            guard saved.leaving == leave, accountChanges == changes else { return }
        }
        // Never in it (asked where a chain of leaves ended): what's here is another household's,
        // no copy of this one. Only what hadn't gone up from here is kept (as of when it changed);
        // the rest goes, and the devices that were in it bring the copy.
        let mine: [String: Date]?
        if leave.noCopy == true, leave.mode == .keep {
            var names: [String: Date] = [:]
            for (kind, list) in unsentHere().items {
                for (id, entry) in list { names[Self.recordName(kind, id)] = entry.1 }
            }
            mine = names
            dropAllHere { names[$0] == nil }
            // So too what's here that this build can't read (none of it goes up as kept): left,
            // it would be taken for new here once setPilot's updated, bringing that household back.
            // (Saved at once, so it's gone from what's stored too.)
            if let model {
                applying = true
                model.library.takeFromCloud {
                    $0.forgetUnreadable()
                    $0.presets = $0.presets
                    $0.customScenes = $0.customScenes
                    $0.cctScales = $0.cctScales
                }
                applying = false
            }
        } else {
            mine = nil
        }
        if leave.mode == .fresh { clearLibraryHere() }
        // Everything here (a newer build's items too, left as they are): the rest of the own
        // library goes, once it's fetched.
        var keep = leave.mode == .fresh || mine != nil ? Set<String>() : Set((saved.unreadable ?? [:]).keys)
        for kind in Kind.allCases { for id in current(kind).keys { keep.insert(Self.recordName(kind, id)) } }
        // (Only what's older than the account's joining: anything since is its devices' that
        // didn't follow, kept.)
        let cutoff = leave.cutoff
        // Signed back in: what's here isn't the household as last fetched, so what wasn't changed
        // here is as old as can be (the others' versions win over it), and the copy isn't one to
        // rely on (the others bring everything they have). So too when this device was never in
        // it (asked where a chain of leaves ended): the copy's the others', and what's kept here
        // is only this device's own, as of when it changed.
        let partial = saved.returning != nil || leave.noCopy == true
        let unreadable = leave.mode == .fresh || mine != nil ? [:] : saved.unreadable ?? [:]
        let ids = saved.meta.mapValues(\.id)
        var stamps = saved.meta.mapValues(\.modified)
        // Changed here since it was synced (while leaving, or asked): as of the leave.
        for kind in Kind.allCases {
            for (id, item) in current(kind) {
                let name = Self.recordName(kind, id)
                if let meta = saved.meta[name], meta.unsent || meta.hash != Self.hash(item) { stamps[name] = leave.at }
                if partial { stamps[name] = mine?[name] ?? saved.newHere?[name] ?? .distantPast }
            }
        }
        let had: Set<String> = Set((joinRecord ?? knowledge(of: leave.zone))?.items.keys.map { $0 } ?? [])
        let household = knowledge(of: leave.zone)
        switchLibrary(to: nil, replacing: ReplacePlan(keep: keep, before: cutoff, stamp: leave.at, stamps: stamps, householdHad: had))
        if let household, household.joinID == leave.joinID || leave.joinID == nil { saved.householdJoin = nil } // left: moot
        // Marked done in its record once the copy's gone up (finishRound, or Sync Now).
        var done = leave
        if partial { done.copyAsOf = nil }
        saved.confirmLeave = done
        householdProblem = nil
        persist()
        // A newer build's items go to the own library as they are (as part of the copy).
        if !unreadable.isEmpty, let engine {
            saved.unreadable = unreadable
            for (name, item) in unreadable {
                guard let id = ids[name] else { continue }
                saved.meta[name] = Meta(id: id, hash: Self.hash(item), order: item.order, modified: leave.at, orderModified: leave.at, mac: item.mac)
            }
            engine.state.add(pendingRecordZoneChanges: unreadable.keys.map { .saveRecord(CKRecord.ID(recordName: $0, zoneID: zoneID)) })
            persist()
        }
    }

    /// The household this device is in has gone: left here or on another device, or its owner
    /// stopped sharing it or put this account out of it.
    private func householdGone() async {
        guard let was = membership, saved.leftQuestion == nil else { return }
        if let leave = saved.leaving, leave.zone == was.zone { return await finishLeaving(leave) } // this device's own
        let read = await readRecord(Self.leaveRecordName(was.zone))
        guard !read.failed, saved.shared == was.zone, saved.leaving == nil, saved.leftQuestion == nil else { return } // tried again later
        if let leave = read.decoded(HouseholdLeave.self), leave.ends(was) {
            if isOwn(leave) {
                await resumeOwn(leave) // this device's own (its save looked failed)
            } else {
                follow(leave)
            }
        } else if read.undecodable(HouseholdLeave.self), !predates(read, was) {
            needsUpdate() // answered with a newer setPilot: not asked again over it
        } else {
            askLeft(was)
        }
    }

    /// Put out of a household, with no device yet asked: asked here (any of the account's devices
    /// may answer; the first does for them all). Nothing here changes or is sent meanwhile.
    /// `selfLeft`: this account took itself out (an administrator's Remove Me): asked as leaving.
    private func askLeft(_ was: Membership, selfLeft: Bool = false) {
        saved.leftQuestion = was
        saved.leftSelf = selfLeft ? true : nil
        persist()
        progress.leftSelf = selfLeft
        progress.leftElsewhere = was.joinedElsewhere == true
        progress.leftHousehold = true
        Self.showQuestion()
    }

    /// Stopped sharing in the system's sharing screen. Not the owner, that's this account taking
    /// itself out of the household (an administrator's Remove Me): asked as leaving it.
    func stoppedSharing() async {
        if let was = membership, saved.leaving == nil, saved.leftQuestion == nil, !leavingNow {
            askLeft(was, selfLeft: true)
        } else if let asked = saved.leftQuestion, asked.zone == saved.shared, asked.joinedElsewhere != true, saved.leftSelf != true {
            // Already asked (the zone was seen gone first): it was this account, so asked as leaving.
            // (Not when what's asked about is where the account went on to elsewhere: that's
            // another household, which it wasn't taken out of here.)
            saved.leftSelf = true
            persist()
            progress.leftSelf = true
        }
        await refreshHousehold()
    }

    /// Back in the app: the question about a household this account's no longer in may have been
    /// answered on another device (followed here, and said so).
    func recheckLeft() async {
        guard saved.leftQuestion != nil, !leavingNow else { return }
        await checkHousehold()
    }

    /// Asked again (Settings' rows): keeping a copy of the household it's no longer in, or not.
    func askLeftAgain() {
        guard saved.leftQuestion != nil else { return }
        progress.leftSelf = saved.leftSelf == true
        progress.leftElsewhere = saved.leftQuestion?.joinedElsewhere == true
        progress.leftHousehold = true
    }

    /// Whether a leave record is this device's own (written here, though its save looked failed).
    private func isOwn(_ leave: HouseholdLeave) -> Bool {
        guard let attempt = leave.attempt else { return false }
        return saved.leaveAttempts?.contains(attempt) == true || attempt == saved.leaving?.attempt
    }

    /// This device's own leave found in its record: finished here, as it was written.
    private func resumeOwn(_ leave: HouseholdLeave) async {
        saved.leaving = leave
        saved.leftQuestion = nil
        progress.leftHousehold = false
        persist()
        await finishLeaving(leave)
    }

    /// A leave record a newer setPilot wrote (this build can't read it): the question's answered
    /// there, so it isn't answered again (overwriting it) here.
    private func needsUpdate() {
        progress.leftHousehold = false
        progress.notice = "This was answered on another of your devices, with a newer version of setPilot. Update setPilot on this device to follow it."
        // Said in the status too, until it's followed (nothing syncs meanwhile).
        householdFailed("Update setPilot to finish leaving the household")
    }

    /// Whether a record was last saved before `was` began: an earlier membership's of the same
    /// household (moot now), allowing for clocks a little apart.
    private func predates(_ read: RecordRead, _ was: Membership) -> Bool {
        guard let began = knowledge(of: was.zone)?.at ?? was.joinedAt, let date = read.record?.modificationDate else { return false }
        return date < began.addingTimeInterval(-300)
    }

    /// Following what another device answered, though this one was asked (or Leave was tapped): said so.
    private func answeredElsewhere(_ leave: HouseholdLeave) {
        let how: String = switch leave.mode {
        case .keep: "keeping a copy"
        case .fresh: "starting fresh"
        case .joined: "joining another household, which this device joins too"
        }
        progress.notice = "This was already answered on another of your devices: \(how)."
    }

    /// The leave's own-library records from before the household, for a device following it:
    /// left out here until the leaving device has removed them (ReplacePlan.skipOnly). None if the
    /// leave's done already (they've been removed).
    private func followPlan(_ leave: HouseholdLeave, keeping names: Set<String>) -> ReplacePlan? {
        guard leave.done != true else { return nil }
        let had = Set(knowledge(of: leave.zone)?.items.keys.map { $0 } ?? [])
        return ReplacePlan(keep: names, before: leave.cutoff, stamp: leave.at, householdHad: had, skipOnly: true)
    }

    /// A household left: what was known of how it was joined is moot (a later invitation to it
    /// is another join).
    private func forgetJoin(_ leave: HouseholdLeave) {
        guard let join = saved.householdJoin, join.zone == leave.zone, leave.joinID == nil || join.joinID == leave.joinID else { return }
        saved.householdJoin = nil
        persist()
    }

    /// This device's finished leave marked done in its record, once its copy's all gone up (so the
    /// others can rely on it). `sync`: synced first (Sync Now, launch); otherwise only if
    /// nothing's waiting to go.
    private func confirmLeft(sync: Bool) async {
        guard let leave = saved.confirmLeave, !confirmingLeave, saved.shared == nil, !settling, saved.switchPending != true else { return }
        confirmingLeave = true
        defer { confirmingLeave = false }
        let changes = accountChanges
        if sync {
            guard await syncOwn() else { return }
        } else {
            guard saved.seeded, !saved.meta.values.contains(where: \.unsent), saved.deleting.isEmpty else { return }
        }
        for _ in 0..<4 {
            let read = await readRecord(Self.leaveRecordName(leave.zone))
            guard accountChanges == changes, saved.confirmLeave == leave, !read.failed else { return }
            // Not this leave's any more (another's since), or not there: nothing to mark.
            guard var now = read.decoded(HouseholdLeave.self), leave.attempt != nil, now.attempt == leave.attempt else {
                saved.confirmLeave = nil
                persist()
                return
            }
            now.done = true
            now.copyAsOf = leave.copyAsOf
            switch await saveRecord(Self.leaveRecordName(leave.zone), type: Self.leaveRecordType, now, over: read.record) {
            case .saved:
                guard accountChanges == changes else { return }
                saved.confirmLeave = nil
                persist()
                return
            case .changed:
                continue
            case .failed:
                return // tried again later
            }
        }
    }

    private var confirmingLeave = false

    /// Another device left the household (`leave` says how): this one follows. Only what's here
    /// that hadn't gone up to the household is its own to bring: kept (merged into the copy the
    /// other device made), asked about (it started fresh), or taken on to the household it joined.
    /// `chained`: the leave of a household the account went on to from this one (or one this
    /// device was asked about without having been in it): nothing synced here is of it, so only
    /// what's unsent here is brought.
    private func follow(_ leave: HouseholdLeave, chained: Bool = false) {
        let was = membership ?? saved.leftQuestion ?? saved.returning?.membership
        let deletions = saved.newHere == nil ? saved.deleting : saved.returning?.gone ?? []
        switch leave.mode {
        case .keep:
            // Later than the copy (made then), so what's this device's wins over it; with what
            // changed after the copy was last fetched, which it may not have.
            // (Not known how up to date the copy was, or not known to have been made at all, as the
            // leave isn't marked done: everything synced here is brought too, as of when it last
            // changed, so the later change wins.)
            let after = leave.at.addingTimeInterval(1)
            let unsent = unsentHere()
            let new = chained ? unsent : unsentHere(since: leave.done == true ? leave.copyAsOf ?? .distantPast : .distantPast)
            var stamped = new.items
            var orders = new.orders
            var names = Set<String>()
            for (kind, list) in new.items {
                for (id, entry) in list {
                    let name = Self.recordName(kind, id)
                    names.insert(name)
                    if unsent.items[kind]?[id] != nil {
                        stamped[kind]?[id] = (entry.0, max(entry.1, after))
                        orders[name] = max(orders[name] ?? entry.1, after)
                    }
                }
            }
            // The own library's records from before the household aren't taken meanwhile.
            saved.replacing = followPlan(leave, keeping: names) // (switchKeeping carries it over)
            switchKeeping(stamped, orders: orders, deleting: deletions, to: nil)
            forgetJoin(leave)
        case .fresh:
            let new = unsentHere().items
            var names = Set<String>()
            for (kind, list) in new { for id in list.keys { names.insert(Self.recordName(kind, id)) } }
            let plan = followPlan(leave, keeping: names)
            if new.isEmpty {
                saved.replacing = plan // (switchKeeping carries it over)
                switchKeeping([:], to: nil, adding: false)
            } else {
                hold(new, replacing: plan)
                saved.askingFresh = true
                ask(.leftFresh(new.values.reduce(0) { $0 + $1.count }), nil)
            }
            forgetJoin(leave)
        case .joined:
            Task { await followJoin(leave, from: was, deletions: deletions) }
        }
    }

    /// Left for another household on another device (`leave`): joined too, as that device joined
    /// it (what's only here added, or asked about). Left since as well: followed on, as its own
    /// leave says. Gone with no word of it: the account was put out of it (the leave for it is
    /// only written once it's joined), so that's the household asked about, and its record is
    /// where the answer goes, for all the account's devices.
    private func followJoin(_ leave: HouseholdLeave, from was: Membership?, deletions: Set<String> = []) async {
        guard !followingJoin else { return } // once (the household's going can be heard twice)
        followingJoin = true
        defer { followingJoin = false }
        let changes = accountChanges
        guard let zones = try? await container.sharedCloudDatabase.allRecordZones(), accountChanges == changes else { return } // tried again later
        // Still where it was (not followed meanwhile).
        guard saved.leaving == nil, saved.shared == nil || saved.shared == was?.zone else { return }
        let end = await chainEnd(leave, zones: zones)
        guard accountChanges == changes, saved.leaving == nil, saved.shared == nil || saved.shared == was?.zone else { return }
        let other: SharedZone
        let joinedAdding: Bool?
        switch end {
        case .household(let zone, let addMine):
            other = zone
            joinedAdding = addMine
        case .leave(let last):
            // Left that one too, for the own library: followed as its leave says (not asked
            // about the first, whose answer could undo what's been done since). Only what's
            // unsent here: what's synced here is the first one's, older than its leave.
            return follow(last, chained: true)
        case .newer:
            return needsUpdate()
        case .failed:
            return // tried again later
        case .unanswered(let target, let since):
            // Never in it here: no copy of it (Membership.joinedElsewhere).
            askLeft(Membership(zone: target, joinID: nil, joinedAt: since, joinedElsewhere: true))
            return
        case .noWord:
            // (Asked as it was: by this account itself, as leaving.)
            if let was { askLeft(was, selfLeft: saved.leftSelf == true || saved.returning?.leftSelf == true) }
            return
        }
        let read = await readRecord(Self.joinRecordName)
        guard accountChanges == changes, saved.leaving == nil, saved.shared == nil || saved.shared == was?.zone else { return }
        let record = read.join(for: other)
        if let record { saved.householdJoin = record }
        let unsent = unsentHere()
        let new = unsent.items
        let adding = joinedAdding ?? record?.addMine
        // Deletions here not sent: only of what the other device brought there (joined adding).
        let deleting: Set<String> = adding == true ? Set(deletions.filter { record?.items[$0] != nil }) : []
        if new.isEmpty || adding == true {
            switchKeeping(new, orders: unsent.orders, deleting: deleting, to: other, adding: adding != false)
        } else {
            hold(new, deleting: deleting)
            ask(record == nil && adding == nil ? .noRecord : .newItems(new.values.reduce(0) { $0 + $1.count }), other)
        }
    }

    /// `unanswered`: gone, with no leave of it (the account was put out of it), since `since`.
    private enum ChainEnd { case household(SharedZone, addMine: Bool?), leave(HouseholdLeave), unanswered(SharedZone, since: Date), noWord, newer, failed }

    /// Where the account went after a leave for another household (`leave`): that household if
    /// it's there and hasn't been left; left or gone, on along its own leave record (to the own
    /// library, or a further household), as far as the records go.
    private func chainEnd(_ leave: HouseholdLeave, zones: [CKRecordZone]) async -> ChainEnd {
        var last = leave
        var visited = Set<SharedZone>()
        // The last household on the way that's still there, though its leave says the account went
        // on: where the account is if what's beyond it comes to nothing (a join from it that didn't
        // go through can leave such a leave behind).
        var lastListed: (zone: SharedZone, addMine: Bool?)?
        var joinRead: RecordRead? // (read only if it's needed below)
        func nothing(_ end: ChainEnd) -> ChainEnd {
            guard let lastListed else { return end }
            return .household(lastListed.zone, addMine: lastListed.addMine)
        }
        while case .joined(let target) = last.mode {
            // Still there, but maybe being left (its leave written, the zone's deletion still to
            // go through): where the account is only if its leave doesn't say it went on.
            let listed = zones.contains(where: { $0.zoneID.zoneName == target.zoneName && $0.zoneID.ownerName == target.ownerName })
            // (Back at one already passed, whose one record was read then: where the account is if
            // it's there, a loop if it's gone. Longer than any real chain: taken as no word.)
            guard visited.insert(target).inserted, visited.count <= 8 else { return listed ? .household(target, addMine: last.addMine) : nothing(.noWord) }
            let read = await readRecord(Self.leaveRecordName(target))
            if read.failed { return .failed }
            // Only the leave of the membership that join began, not an earlier one's of it.
            let began = Membership(zone: target, joinID: nil, joinedAt: last.at)
            guard let next = read.decoded(HouseholdLeave.self) else {
                if read.exists && !predates(read, began) { return .newer }
                return listed ? .household(target, addMine: last.addMine) : nothing(.unanswered(target, since: last.at))
            }
            guard next.ends(began) else {
                return listed ? .household(target, addMine: last.addMine) : nothing(.unanswered(target, since: last.at))
            }
            // Its leave is there, so the account got this far: one passed that's still there was
            // left for it all the same (its zone's deletion only pending).
            lastListed = nil
            if listed {
                // Joined again since that leave (from the account's own library, which writes no
                // leave record): the account's there, not where that leave went.
                if joinRead == nil { joinRead = await readRecord(Self.joinRecordName) }
                guard let joins = joinRead, !joins.failed else { return .failed }
                if let join = joins.join(for: target), let at = join.at, at > next.at { return .household(target, addMine: join.addMine) }
                // Only if the join it went on to isn't known to have gone through (the join record
                // says it did): then it's being left, its deletion still pending on another device.
                var wentOn = false
                if case .joined(let onward) = next.mode, let join = joins.join(for: onward), let at = join.at,
                   at >= next.at.addingTimeInterval(-300) {
                    wentOn = true
                }
                if !wentOn { lastListed = (target, last.addMine) }
            }
            last = next
        }
        return .leave(last)
    }

    /// Back on the account's own library with only `new` here, held (not sent) until it's decided
    /// where it goes; the library's own items arrive as it's fetched.
    /// `deleting`: deletions here not sent that go where it goes too.
    /// `replacing`: following a leave, the own library's records it removes, left out (skipOnly).
    private func hold(_ new: [Kind: [String: (Item, Date)]], deleting: Set<String> = [], replacing: ReplacePlan? = nil) {
        var names: [String: Date] = [:]
        var hashes: [String: Data] = [:]
        for (kind, list) in new {
            for (id, (item, at)) in list {
                names[Self.recordName(kind, id)] = at
                hashes[Self.recordName(kind, id)] = Self.hash(item)
            }
        }
        dropAllHere { names[$0] == nil }
        let deleted = deleting
        switchLibrary(to: nil, offerMine: false, replacing: replacing)
        saved.newHere = names
        saved.heldHashes = hashes
        if !deleted.isEmpty { saved.deletedHere = deleted }
        persist()
    }

    /// Resumed at launch (or Sync Now): a leave under way, a household gone while the app wasn't
    /// running, or a question of keeping a copy that another device may have answered since.
    private func checkHousehold() async {
        guard saved.switchPending != true, !joining else { return } // the account's library is decided first
        // Leave records of joins that didn't go through, not withdrawn yet (offline, say).
        if saved.withdrawing != nil { await withdrawPending(changes: accountChanges) }
        if let zones = saved.toLeave {
            let since = saved.toLeaveSince ?? [:]
            let seen = saved.toLeaveJoins ?? [:]
            var joinRead: RecordRead? // (read only if they're needed below)
            var markRead: RecordRead?
            if zones.contains(where: { since[$0] != nil }) {
                joinRead = await readRecord(Self.joinRecordName)
                markRead = await readRecord(Self.joiningRecordName)
            }
            var still: [SharedZone] = []
            for zone in zones {
                // Joined again since it was noted (here, or on another device, as the join record
                // says): not left, which would put the account out of where it is now. Not known
                // (offline): not left yet either.
                if let noted = since[zone] {
                    if saved.shared == zone, (saved.joinedAt ?? .distantPast) > noted { continue }
                    guard let joinRead, !joinRead.failed, let markRead, !markRead.failed else {
                        still.append(zone)
                        continue
                    }
                    // Another join of it than the one known when it was noted. (Either not known:
                    // one since then.)
                    if let join = joinRead.join(for: zone) {
                        if let id = join.joinID, let was = seen[zone] {
                            if id != was { continue }
                        } else if (join.at ?? .distantPast) > noted {
                            continue
                        }
                    }
                    // Being joined again on another device (accepted, or about to be), its join record
                    // not written yet: not left now, and looked at again later. (Only for a while: a
                    // join that didn't go through leaves its marker behind.)
                    // (Another device's clock: allowing for one a few minutes behind.)
                    let skewed = noted.addingTimeInterval(-300)
                    if let mark = markRead.decoded(JoinMarker.self), mark.zone == zone, mark.at > skewed,
                       mark.at > Date.now.addingTimeInterval(-20 * 60) {
                        still.append(zone)
                        continue
                    }
                }
                do {
                    _ = try await container.sharedCloudDatabase.deleteRecordZone(withID: CKRecordZone.ID(zoneName: zone.zoneName, ownerName: zone.ownerName))
                } catch let error as CKError where error.code == .zoneNotFound || error.code == .unknownItem {
                } catch {
                    still.append(zone)
                }
            }
            setToLeave(still)
            persist()
        }
        // A join stopped part way (accepted): finished, if the household's still there.
        if let intent = saved.joiningTo { return await resumeJoin(intent) }
        if let leave = saved.leaving { return await finishLeaving(leave) }
        if let put = saved.leftQuestion {
            let read = await readRecord(Self.leaveRecordName(put.zone))
            guard !read.failed, saved.leftQuestion == put else { return }
            if let leave = read.decoded(HouseholdLeave.self), leave.ends(put) {
                if isOwn(leave) { return await resumeOwn(leave) } // this device's answer, its save looked failed
                // Answered on another device: followed, and said so (it was asked here too). Left
                // for another household: as far as the account went from there (as followJoin
                // finds it), which is what's said, and may be no answer yet.
                var answer = leave
                if case .joined = leave.mode {
                    let changes = accountChanges
                    guard let zones = try? await container.sharedCloudDatabase.allRecordZones() else { return } // tried again later
                    let end = await chainEnd(leave, zones: zones)
                    guard accountChanges == changes, saved.leftQuestion == put, saved.leaving == nil, !leavingNow else { return }
                    switch end {
                    case .household:
                        break
                    case .leave(let last):
                        answer = last
                    case .newer:
                        return needsUpdate()
                    case .failed:
                        return // tried again later
                    case .noWord:
                        return askLeftAgain() // no answer: asked still, as it was
                    case .unanswered(let target, let since):
                        // Put out of the one the account went on to, with no answer yet: that's
                        // what's asked now (its record read and written), with no copy of it here.
                        saved.leftQuestion = Membership(zone: target, joinID: nil, joinedAt: since, joinedElsewhere: true)
                        saved.leftSelf = nil
                        persist()
                        return askLeftAgain()
                    }
                }
                saved.leftQuestion = nil
                progress.leftHousehold = false
                follow(leave, chained: put.joinedElsewhere == true)
                if progress.householdQuestion == nil { answeredElsewhere(answer) }
            } else if read.undecodable(HouseholdLeave.self), !predates(read, put) {
                needsUpdate()
            } else if !leavingNow {
                askLeftAgain()
            }
            return
        }
        // This device's leave, its save looked failed: if it went through after all, finished now
        // (its record says the household's left, which the others follow once it's gone).
        if saved.leaveAttempts?.isEmpty == false, saved.leaving == nil, !leavingNow, let was = membership {
            let changes = accountChanges
            let read = await readRecord(Self.leaveRecordName(was.zone))
            guard !read.failed, accountChanges == changes, saved.leaving == nil, saved.shared == was.zone, !leavingNow else { return }
            if let leave = read.decoded(HouseholdLeave.self), leave.ends(was), isOwn(leave) {
                await resumeOwn(leave)
                progress.notice = "Leaving the household, as answered earlier on this device, went through after all: \(leave.mode == .keep ? "keeping a copy" : "starting fresh")."
                return
            }
            // (Not there, or not this device's: the attempts are kept all the same, until the
            // membership ends.)
        }
        if saved.confirmLeave != nil { await confirmLeft(sync: true) }
        guard saved.shared != nil, let zones = try? await container.sharedCloudDatabase.allRecordZones() else { return }
        if saved.shared != nil, !zones.contains(where: { $0.zoneID == zoneID }) { await householdGone() }
    }

    /// A record of the account's own (the join or leave record): nil if there's none, `failed` if
    /// it couldn't be read (tried a few times).
    private func readRecord(_ name: String) async -> RecordRead {
        let id = CKRecord.ID(recordName: name, zoneID: Self.ownZone)
        for attempt in 0..<4 {
            do {
                return RecordRead(record: try await container.privateCloudDatabase.record(for: id), failed: false)
            } catch let error as CKError where error.code == .unknownItem || error.code == .zoneNotFound {
                return RecordRead(record: nil, failed: false)
            } catch {
                if attempt < 3 { try? await Task.sleep(for: .seconds(1)) }
            }
        }
        return RecordRead(record: nil, failed: true)
    }

    struct RecordRead {
        var record: CKRecord?
        var failed: Bool

        func decoded<T: Decodable>(_ type: T.Type, key: String = "value") -> T? {
            guard let data: Data = record?.encryptedValues[key] else { return nil }
            return try? JSONDecoder().decode(T.self, from: data)
        }

        var exists: Bool { record != nil }

        /// The join record, if it's for `zone` and not marked left.
        func join(for zone: SharedZone) -> HouseholdJoin? {
            decoded(HouseholdJoin.self, key: "join").flatMap { $0.zone == zone && $0.left != true ? $0 : nil }
        }

        /// There, but not readable by this build (a newer setPilot's, say).
        func undecodable<T: Decodable>(_ type: T.Type, key: String = "value") -> Bool {
            record != nil && decoded(type, key: key) == nil
        }
    }

    enum SaveResult { case saved, changed, failed }

    /// Saves a record of the account's own, only if it's as read (`over`; none: only if there
    /// still isn't one), so two devices can't both write it at once.
    private func saveRecord<T: Encodable>(_ name: String, type: String, _ value: T, over existing: CKRecord?) async -> SaveResult {
        let db = container.privateCloudDatabase
        let id = CKRecord.ID(recordName: name, zoneID: Self.ownZone)
        guard let data = try? JSONEncoder().encode(value) else { return .failed }
        _ = try? await db.save(CKRecordZone(zoneID: Self.ownZone))
        let record = existing ?? CKRecord(recordType: type, recordID: id)
        record.encryptedValues["value"] = data
        do {
            let (results, _) = try await db.modifyRecords(saving: [record], deleting: [], savePolicy: .ifServerRecordUnchanged)
            if case .failure(let error as CKError)? = results[id] { return error.code == .serverRecordChanged ? .changed : .failed }
            return .saved
        } catch let error as CKError where error.code == .serverRecordChanged {
            return .changed
        } catch {
            return .failed
        }
    }

    /// Takes out of the library here the items whose record names `drop` picks.
    private func dropAllHere(_ drop: (String) -> Bool) {
        for kind in Kind.allCases {
            var changes: [String: Item?] = [:]
            for id in current(kind).keys where drop(Self.recordName(kind, id)) {
                changes.updateValue(nil, forKey: id)
            }
            apply(kind, changes)
        }
    }

    /// Syncs another library from now on: a new engine on its database, with what's here offered
    /// to it (`offerMine`). `join`: the household's join record, kept while in it. `replacing`:
    /// back to the account's own library after leaving a household, which becomes what's here.
    /// `keepingAttempts`: back into the same membership (signed back in), its leave attempts
    /// still its. Any other switch ends the membership they were for, even into the same zone
    /// (a rejoin is another membership).
    private func switchLibrary(to shared: SharedZone?, offerMine: Bool = true, join: HouseholdJoin? = nil, replacing: ReplacePlan? = nil, keepingAttempts: Bool = false) {
        let householdJoin = saved.householdJoin
        let toLeave = saved.toLeave
        let toLeaveSince = saved.toLeaveSince
        let toLeaveJoins = saved.toLeaveJoins
        let withdrawing = saved.withdrawing
        let confirmLeave = saved.confirmLeave
        let leaveAttempts = saved.leaveAttempts
        saved = Saved(shared: shared)
        // The account's still, whichever library. (Not the one switched to: that's where it is.)
        saved.toLeave = toLeave
        saved.toLeaveSince = toLeaveSince
        saved.toLeaveJoins = toLeaveJoins
        saved.withdrawing = withdrawing
        if let shared, saved.toLeave?.contains(shared) == true { setToLeave((saved.toLeave ?? []).filter { $0 != shared }) }
        if shared == nil {
            // A leave still to be marked done in its record (in the own library): still to be.
            saved.confirmLeave = confirmLeave
        }
        if keepingAttempts, shared != nil { saved.leaveAttempts = leaveAttempts }
        saved.replacing = replacing
        // The account's join record stays known (it's in its own library, fetched again anyway).
        saved.householdJoin = join ?? householdJoin
        if shared != nil {
            saved.joinedAt = .now
        }
        if !offerMine { saved.seeded = true }
        progress.householdQuestion = nil // answered by this, or moot
        persist()
        makeEngine()
        if offerMine { seed() } else { ensureZone() }
    }

    /// The households still to leave: `added` noted as of now (with the join of it known here),
    /// the rest as they were.
    private func setToLeave(_ zones: [SharedZone], added: [SharedZone] = []) {
        let since = saved.toLeaveSince ?? [:]
        let joins = saved.toLeaveJoins ?? [:]
        var noted: [SharedZone: Date] = [:]
        var seen: [SharedZone: UUID] = [:]
        for zone in zones {
            noted[zone] = added.contains(zone) ? .now : since[zone]
            seen[zone] = added.contains(zone) ? knowledge(of: zone)?.joinID : joins[zone]
        }
        saved.toLeave = zones.isEmpty ? nil : zones
        saved.toLeaveSince = noted.isEmpty ? nil : noted
        saved.toLeaveJoins = seen.isEmpty ? nil : seen
    }

    /// Leaves a household's zone, or, if that can't be done now (offline, say), notes it to be
    /// left later (checkHousehold): one household at a time.
    private func leaveZone(_ zone: SharedZone, changes: Int) async {
        do {
            _ = try await container.sharedCloudDatabase.deleteRecordZone(withID: CKRecordZone.ID(zoneName: zone.zoneName, ownerName: zone.ownerName))
        } catch let error as CKError where error.code == .zoneNotFound || error.code == .unknownItem {
            // Already gone: left all the same.
        } catch {
            guard accountChanges == changes else { return } // another account's now
            setToLeave(Array(Set((saved.toLeave ?? []) + [zone])), added: [zone])
            persist()
        }
    }

    /// Notes a join about to be accepted (JoinMarker), if it can be.
    private func markJoining(_ household: SharedZone) async {
        for _ in 0..<3 {
            let read = await readRecord(Self.joiningRecordName)
            guard !read.failed else { return }
            switch await saveRecord(Self.joiningRecordName, type: Self.joiningRecordType, JoinMarker(zone: household, at: .now), over: read.record) {
            case .saved, .failed:
                return
            case .changed:
                continue // another device's at the same moment: read again
            }
        }
    }

    /// Notes leave records to withdraw (Saved.withdrawing), before the join they were for is forgotten.
    private func addWithdrawal(_ withdrawal: LeaveWithdrawal) {
        guard !withdrawal.zones.isEmpty else { return }
        saved.withdrawing = (saved.withdrawing ?? []) + [withdrawal]
        persist()
    }

    /// The leave records noted to withdraw, as far as can be done now; what can't be (offline,
    /// say) stays noted, tried again by checkHousehold.
    private func withdrawPending(changes: Int) async {
        for pending in saved.withdrawing ?? [] {
            let left = await withdrawLeaves(pending, changes: changes)
            guard accountChanges == changes else { return } // (another account's now)
            var list = saved.withdrawing ?? []
            guard let i = list.firstIndex(of: pending) else { continue }
            if left.isEmpty { list.remove(at: i) } else { list[i].zones = left }
            saved.withdrawing = list.isEmpty ? nil : list
            persist()
        }
    }

    /// A join that didn't go through (the household's gone, or the old ones couldn't all be told):
    /// the leave records the telling wrote for it, of the households in `zones`, written over so
    /// they read as none (a device still in one doesn't follow it there). Only those its attempt
    /// wrote (another device's leave for the same household stays), and only if they're as read
    /// (another device's answer meanwhile stays). Returns the households whose record couldn't
    /// be looked at or written now.
    private func withdrawLeaves(_ pending: LeaveWithdrawal, changes: Int) async -> [SharedZone] {
        var left: [SharedZone] = []
        for zone in Set(pending.zones) {
            var done = false
            for _ in 0..<3 {
                let read = await readRecord(Self.leaveRecordName(zone))
                guard accountChanges == changes else { return pending.zones }
                if read.failed { break }
                guard var leave = read.decoded(HouseholdLeave.self), leave.mode == .joined(pending.household),
                      pending.attempt == nil || leave.attempt == pending.attempt else {
                    done = true // not there, or not the attempt's (any more): nothing to withdraw
                    break
                }
                leave.zone = Self.noHousehold
                let result = await saveRecord(Self.leaveRecordName(zone), type: Self.leaveRecordType, leave, over: read.record)
                guard accountChanges == changes else { return pending.zones }
                if result == .saved {
                    done = true
                    break
                }
                if result == .failed { break }
                // Changed meanwhile: read again.
            }
            if !done { left.append(zone) }
        }
        return left
    }

    /// A join that didn't go through, with the household it was leaving for it still there: this
    /// device stays in it. Signed out and back in part way (off it now): back into it, what changed
    /// here meanwhile as of when it changed (the rest as oldest: the household's wins).
    private func stay(in zone: SharedZone) {
        saved.leaving = nil
        // Staying in it: not left later because an earlier step noted it to go.
        if let toLeave = saved.toLeave, toLeave.contains(zone) { setToLeave(toLeave.filter { $0 != zone }) }
        guard saved.shared == nil else { return }
        let unsent = unsentHere()
        switchLibrary(to: zone, join: knowledge(of: zone), keepingAttempts: true)
        for (kind, list) in unsent.items {
            for (id, (_, at)) in list where at > .distantPast {
                let name = Self.recordName(kind, id)
                saved.meta[name]?.modified = at
                saved.meta[name]?.orderModified = unsent.orders[name] ?? at
            }
        }
        persist()
    }

    /// Settling over with this device staying where it is (a leave or join that didn't go through):
    /// what changed here meanwhile, only noted then (changedHere), goes up now, as of when it
    /// changed, so the library's next change to it doesn't win over it.
    private func sendChangedHere() {
        guard !settling, engine != nil else { return }
        let noted = saved.changedHere ?? [:]
        for kind in Kind.allCases { localChanged(kind) }
        for (name, stamp) in noted {
            guard var meta = saved.meta[name], meta.unsent, meta.hash == stamp.hash else { continue }
            meta.modified = stamp.at
            saved.meta[name] = meta
        }
        saved.changedHere = nil
        saved.deletedHere = nil // (sent as deletions above)
        persist()
    }

    /// `keepingUnreadable`: the library's data this build can't read stays (it's never synced, so
    /// it's only here), as when what's here is added or kept.
    private func clearLibraryHere(keepingUnreadable: Bool = false) {
        guard let model else { return }
        applying = true
        model.library.takeFromCloud {
            if !keepingUnreadable { $0.forgetUnreadable() }
            $0.presets = []
            $0.customScenes = []
            $0.cctScales = [:]
        }
        model.setNamesFromCloud([:])
        model.setSigningKeysFromCloud([:])
        model.setKnownBulbsFromCloud([])
        applying = false
        noteScalesSeen()
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(saved) { try? data.write(to: Self.fileURL, options: .atomic) }
        updateProgress()
    }

    /// After fetching or sending: up to date, unless a save failed (its reason stays shown until
    /// the next round of sending).
    private func finishRound() {
        lastSync = .now
        guard !sendFailed else { return }
        status = householdProblem ?? waitingStatus ?? "Up to date"
        // This device's leave is through once its copy's gone up: marked so in its record.
        if saved.confirmLeave != nil { Task { await confirmLeft(sync: false) } }
    }

    /// A household step that couldn't be done yet (offline, say): said until it's tried again.
    private func householdFailed(_ text: String) {
        householdProblem = text
        status = text
    }

    /// Nothing's sent while this device's library is being sorted out: not "Up to date" then.
    private var waitingStatus: String? {
        if let note = saved.signedOut { return note.answered == true ? "Not signed in to iCloud" : "Waiting for your answer" }
        if saved.switchPending == true || saved.leftQuestion != nil || saved.askingFresh == true || saved.pendingHousehold != nil {
            return "Waiting for your answer"
        }
        if saved.leaving != nil { return "Leaving the household…" }
        if settling || saved.joiningTo != nil { return "Working out where this device's library goes…" }
        return nil
    }

    /// The household rows' state, as it is now.
    private func updateProgress() {
        let leaving = saved.leaving.map { !$0.isJoin } ?? false
        if progress.leavingPending != leaving { progress.leavingPending = leaving }
        let putOut = saved.leftQuestion != nil
        if progress.putOut != putOut { progress.putOut = putOut }
        let sorting = settling || saved.joiningTo != nil || saved.switchPending == true || saved.pendingHousehold != nil
        if progress.sortingOut != sorting { progress.sortingOut = sorting }
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
                if let d = try? Self.encoder.encode(p) { items[p.id.uuidString] = Item(data: library.withExtras(d), order: Double(i)) }
            }
        case .customScene:
            for (i, s) in library.customScenes.enumerated() {
                if let d = try? Self.encoder.encode(s) { items[s.id.uuidString] = Item(data: library.withExtras(d), order: Double(i)) }
            }
        case .cctScale:
            for (mac, list) in library.cctScales {
                for (i, s) in list.enumerated() {
                    if let d = try? Self.encoder.encode(s) { items[s.id.uuidString] = Item(data: library.withExtras(d), order: Double(i), mac: mac) }
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
        // Deleted in iCloud: an undecodable copy kept here goes too.
        if kind == .preset || kind == .customScene || kind == .cctScale {
            library.forgetUnreadable(Set(changes.filter { $0.value == nil }.map(\.key)))
        }
        func order(_ id: String, _ index: Int) -> Double {
            saved.meta[Self.recordName(kind, id)]?.order ?? Double(index)
        }
        func merged<T: Codable & Identifiable>(_ list: [T]) -> [T] where T.ID == UUID {
            var byID: [String: T] = [:]
            for item in list { byID[item.id.uuidString] = item }
            for (id, change) in changes {
                if let change, let v = try? JSONDecoder().decode(T.self, from: change.data) {
                    byID[id] = v
                    library.noteExtras(change.data, of: v) // a newer build's fields, kept
                } else {
                    byID[id] = nil
                }
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
                    library.noteExtras(change.data, of: v) // a newer build's fields, kept
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
            noteScalesSeen() // (iCloud's, not deleted here)
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
        // A newer build's (this one can't read it): nothing of this device's goes over it; back from
        // a household, it goes to the own library as it is.
        if let item = saved.unreadable?[id.recordName] {
            guard ownPlan != nil, let kind = Self.kind(of: id.recordName), let meta = saved.meta[id.recordName], meta.unsent else { return nil }
            // On top of what's there (its change tag), as the normal path does.
            let kept = meta.systemFields.flatMap(Self.record(fromSystemFields:)).flatMap { $0.recordID == id ? $0 : nil }
            let record = kept ?? CKRecord(recordType: kind.rawValue, recordID: id)
            record.encryptedValues["data"] = item.data
            record.encryptedValues["mac"] = item.mac
            record["order"] = item.order
            record["modified"] = meta.modified
            record["orderModified"] = meta.orderModified
            return record
        }
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
                                    orderModified: orderModified, systemFields: fields, unsent: false, mac: mac)
            return (kind, id, remote)
        }
        // A newer build's item carried here (back from a household), newer than iCloud's: kept,
        // and sent again on top.
        if saved.unreadable?[name] != nil, meta.unsent, meta.modified > modified {
            meta.systemFields = fields
            saved.meta[name] = meta
            engine?.state.add(pendingRecordZoneChanges: [.saveRecord(record.recordID)])
            return nil
        }
        // A newer build's, which this one can't read: set aside (readable), and nothing of this
        // device's goes over it (its place either: the save would carry this device's older content).
        guard Self.canRead(kind, remote) else {
            meta.systemFields = fields
            meta.hash = remoteHash
            meta.modified = modified
            meta.order = remote.order
            meta.orderModified = orderModified
            meta.unsent = false
            meta.mac = mac
            saved.meta[name] = meta
            return (kind, id, remote)
        }
        // Changed here while leaving (nothing's sent meanwhile): kept, for the copy.
        if saved.leaving != nil, let mine = current(kind)[id], Self.hash(mine) != meta.hash {
            meta.systemFields = fields
            saved.meta[name] = meta
            return nil
        }
        let keepContent = meta.modified > modified && meta.hash != remoteHash
        let keepOrder = meta.orderModified > orderModified && meta.order != remote.order
        meta.systemFields = fields
        if !keepContent { meta.hash = remoteHash; meta.modified = modified; meta.mac = mac }
        if !keepOrder { meta.order = remote.order; meta.orderModified = orderModified }
        meta.unsent = keepContent || keepOrder
        saved.meta[name] = meta
        if meta.unsent { engine?.state.add(pendingRecordZoneChanges: [.saveRecord(record.recordID)]) }
        if keepContent && keepOrder { return nil }
        let mine = current(kind)[id]
        let content = keepContent ? (mine ?? remote) : remote
        return (kind, id, Item(data: content.data, order: meta.order, mac: content.mac))
    }

    /// Back from a household, a kept item whose record in the own library is from before the
    /// cut-off (the pre-household one, the same content): saved again all the same, so it's newer
    /// than that (devices following the leave leave out what's older, ReplacePlan.skipOnly).
    private func resaveIfStale(_ server: CKRecord) {
        let name = server.recordID.recordName
        guard saved.shared == nil, let plan = ownPlan, let before = plan.before, plan.keep.contains(name),
              (server.modificationDate ?? .distantPast) < before, saved.meta[name] != nil, saved.unreadable?[name] == nil else { return }
        saved.meta[name]?.unsent = true
        engine?.state.add(pendingRecordZoneChanges: [.saveRecord(server.recordID)])
    }

    /// A leave this device followed is done (its copy's in the own library): what the plan left
    /// out is the copy's now, so nothing's left out, and what was is fetched afresh.
    private func dropFollowPlan() {
        saved.replacing = nil
        // Still settling: the switch it's waiting on fetches everything afresh anyway.
        guard !settling, saved.shared == nil else { return persist() }
        saved.state = nil
        persist()
        makeEngine()
        requeueUnsent()
        // A fetch from scratch reports no deletions: what was synced here and isn't in it has
        // been deleted since, and goes here too (only once it's all come).
        refetched = []
        guard let engine else { return }
        Task {
            guard (try? await engine.fetchChanges()) != nil, engine === self.engine, let names = refetched else { return }
            refetched = nil
            pruneMissing(names)
        }
    }

    /// The records a fetch from scratch (dropFollowPlan) has brought so far, by name.
    private var refetched: Set<String>?
    /// A leave this device followed was found done part way through a fetch: its plan's dropped
    /// once that fetch is over (not in the middle of it, which would lose the rest of it).
    private var followPlanDone = false

    /// After a fetch from scratch: what was synced here and isn't among `names` was deleted meanwhile.
    private func pruneMissing(_ names: Set<String>) {
        guard !settling, saved.shared == nil else { return }
        var changes: [Kind: [String: Item?]] = [:]
        // (Not what's still to go up, or was never in iCloud: only what was there.)
        for (name, meta) in saved.meta where !names.contains(name) && !meta.unsent && meta.systemFields != nil && !saved.deleting.contains(name) {
            guard let kind = Self.kind(of: name) else { continue }
            saved.meta.removeValue(forKey: name)
            saved.unreadable?.removeValue(forKey: name)
            changes[kind, default: [:]].updateValue(nil, forKey: meta.id)
        }
        for (kind, c) in changes { apply(kind, c) }
        persist()
    }

    private func handle(_ event: CKSyncEngine.Event) {
        switch event {
        case .stateUpdate(let e):
            saved.state = e.stateSerialization
            persist()

        case .accountChange(let e):
            // An engine just made (at launch, or for a library just switched to) reports the account
            // it starts with as signing in: that's not a change, and whoever made it has done what's due.
            let fresh = engineFresh
            engineFresh = false
            // A fresh engine's first report of signing in isn't a change; signing out always is.
            var isSignIn = false
            if case .signIn = e.changeType { isSignIn = true }
            if !fresh || !isSignIn { accountChanges += 1 }
            // Signed out, then in as someone else (reported as a sign-in): as another Apple ID.
            var otherUser = false
            switch e.changeType {
            case .signIn(let user):
                otherUser = Self.noteUser(user)
            case .switchAccounts(_, let user):
                _ = Self.noteUser(user)
            default:
                break
            }
            switch e.changeType {
            case .signOut:
                signedOut()
            case .signIn where otherUser:
                switchedAccounts()
            case .signIn:
                // (A fresh engine's sign-in is one too after signing out: what's here is noted.)
                guard !fresh || saved.signedOut != nil else { break }
                signedIn()
            // Another Apple ID: ask what to do with what's here (AccountSwitchPrompt).
            case .switchAccounts:
                switchedAccounts()
            @unknown default: break
            }

        case .fetchedDatabaseChanges(let e):
            engineFresh = false // working: a later sign-in is a real one
            // A household library this account left, or its owner stopped sharing: back to its
            // own, with what's here (offered to it as on signing in).
            if saved.shared != nil, e.deletions.contains(where: { $0.zoneID == zoneID }) {
                Task { await householdGone() }
                return
            }
            // The zone deleted (iCloud's data removed in Settings, say): forget what was synced.
            // The library here stays, and all of it goes up again with the next change here.
            if e.deletions.contains(where: { $0.zoneID == zoneID }) {
                saved.replacing = nil
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
            var followDone = false
            for m in e.modifications where m.record.recordID.zoneID == zoneID {
                let name = m.record.recordID.recordName
                refetched?.insert(name)
                // How another device of this account joined a household (HouseholdJoin).
                if m.record.recordType == Self.joinRecordType {
                    if saved.shared == nil, let data: Data = m.record.encryptedValues["join"],
                       let join = try? JSONDecoder().decode(HouseholdJoin.self, from: data) {
                        if join.left == true {
                            saved.householdJoin = nil // marked left (the household left): moot, as if deleted
                        } else {
                            saved.householdJoin = join
                            joined = true
                        }
                    }
                    continue
                }
                // A household left on another device: a question about following it is moot.
                if m.record.recordType == Self.leaveRecordType {
                    let leave = RecordRead(record: m.record, failed: false).decoded(HouseholdLeave.self)
                    if let leave, let pending = saved.pendingHousehold, pending == leave.zone,
                       leave.at > (knowledge(of: pending)?.at ?? saved.pendingAskedAt ?? .distantPast) { // (this join's, not an earlier one's)
                        saved.pendingHousehold = nil
                        progress.householdQuestion = nil
                        if let held = saved.newHere {
                            // Followed back to the own library (a copy kept, or a fresh start): its
                            // records from before the household aren't taken meanwhile, as on following it.
                            if !leave.isJoin { saved.replacing = followPlan(leave, keeping: Set(held.keys)) }
                            if leave.mode == .fresh, !held.isEmpty, saved.askingFresh != true {
                                // Left starting fresh: what's held here is asked about, as on following it.
                                saved.askingFresh = true
                                ask(.leftFresh(held.count), nil)
                            } else if leave.mode == .fresh, held.isEmpty {
                                // Nothing to ask about: started fresh, as on following it (the data
                                // this build can't read goes too). After this fetch's changes.
                                Task {
                                    guard saved.shared == nil, saved.newHere?.isEmpty == true, saved.askingFresh != true else { return }
                                    switchKeeping([:], to: nil, adding: false)
                                }
                            } else {
                                Task { await findHousehold() } // where what's held goes
                            }
                        }
                    }
                    // A leave this device followed, now done (its copy's up): nothing of the own
                    // library is left out any more.
                    if let leave, leave.done == true, let plan = saved.replacing, plan.skipOnly == true,
                       let stamp = plan.stamp, leave.at >= stamp {
                        followDone = true
                    }
                    continue
                }
                // Held here for where it goes (it's this device's): not replaced by the library's.
                // Deleted here while signed out: not brought back.
                // Signed back in, while where this goes is worked out: what's here isn't mixed with
                // the account's own library (fetched again once it's decided).
                // Part way through leaving or joining (off the household, signed back in): what's
                // here is the household's, not mixed with the own library (fetched again after).
                // Parked here for a household it's asked about: the own library isn't this device's
                // to take meanwhile (nor what's deleted here then the household's to lose).
                if saved.newHere?[name] != nil || saved.returning != nil || parked
                    || (saved.shared == nil && (saved.leaving != nil || (saved.joiningTo != nil && saved.joiningTo?.fromOwn != true))) { continue }
                // Back from a household, the own library becomes what's here: anything else goes.
                // (Following another device's leave: left out, for that device to remove.)
                if let plan = saved.replacing, Self.kind(of: name) != nil, !plan.keep.contains(name),
                   (m.record.modificationDate ?? .distantPast) < (plan.before ?? .distantFuture)
                   || (plan.householdHad?.contains(name) == true
                       && (m.record.modificationDate ?? .distantPast) < (plan.stamp ?? .distantFuture).addingTimeInterval(-120)) {
                    if plan.skipOnly == true { continue }
                    saved.deleting.insert(name)
                    engine?.state.add(pendingRecordZoneChanges: [.deleteRecord(m.record.recordID)])
                    continue
                }
                if let (kind, id, item) = take(m.record) { changes[kind, default: [:]].updateValue(item, forKey: id) }
            }
            // Joined on another device: this one follows (not while a lookup's syncing for it).
            if joined, saved.switchPending != true, householdLookup == nil, !joining { Task { await findHousehold() } }
            for d in e.deletions where d.recordID.zoneID == zoneID {
                let name = d.recordID.recordName
                // The join record removed (the household left): what it said is moot.
                if name == Self.joinRecordName, saved.shared == nil {
                    saved.householdJoin = nil
                    continue
                }
                if saved.newHere?[name] != nil || saved.returning != nil || parked
                    || (saved.shared == nil && (saved.leaving != nil || (saved.joiningTo != nil && saved.joiningTo?.fromOwn != true))) { continue } // held here, or still being worked out
                saved.deleting.remove(name)
                saved.unreadable?.removeValue(forKey: name)
                guard let kind = Self.kind(of: name), let id = itemID(name, kind) else { continue }
                saved.meta.removeValue(forKey: name)
                changes[kind, default: [:]].updateValue(nil, forKey: id)
            }
            for (kind, c) in changes { apply(kind, readable(kind, c)) }
            persist()
            if followDone { followPlanDone = true } // dropped once this fetch is over

        case .willSendChanges:
            sendFailed = false

        case .sentRecordZoneChanges(let e):
            for record in e.savedRecords where record.recordID.zoneID == zoneID {
                let name = record.recordID.recordName
                saved.meta[name]?.systemFields = Self.systemFields(of: record)
                // Changed again while that went (its save was already on its way): sent again. (Against
                // what would be sent now, as record(for:) builds it: not the bookkeeping.)
                if let meta = saved.meta[name], let kind = Self.kind(of: name), let now = current(kind)[meta.id],
                   let data: Data = record.encryptedValues["data"],
                   Self.hash(Item(data: data, order: 0, mac: record.encryptedValues["mac"])) != Self.hash(Item(data: now.data, order: 0, mac: now.mac))
                    || (record["order"] as? Double) != now.order {
                    engine?.state.add(pendingRecordZoneChanges: [.saveRecord(record.recordID)])
                    continue
                }
                saved.meta[name]?.unsent = false
            }
            for id in e.deletedRecordIDs where id.zoneID == zoneID { saved.deleting.remove(id.recordName) }
            for (id, error) in e.failedRecordDeletes where error.code == .unknownItem || error.code == .zoneNotFound {
                saved.deleting.remove(id.recordName) // already gone
            }
            var retry: [CKSyncEngine.PendingRecordZoneChange] = []
            var changes: [Kind: [String: Item?]] = [:]
            var householdMissing = false
            for failure in e.failedRecordSaves {
                let id = failure.record.recordID
                switch failure.error.code {
                case .serverRecordChanged:
                    // Changed elsewhere since we last saw it: the later change wins, part by part.
                    if let server = failure.error.serverRecord {
                        if let (kind, itemID, item) = take(server) { changes[kind, default: [:]].updateValue(item, forKey: itemID) }
                        resaveIfStale(server)
                    }
                case .zoneNotFound where saved.shared != nil:
                    // The household's gone (its owner stopped sharing, say): said once, after the rest.
                    householdMissing = true
                case .zoneNotFound:
                    // Made afresh: saved as new records (the old change tags would come back as
                    // "unknown item", taken for deletions elsewhere).
                    ensureZone()
                    saved.replacing = nil
                    for name in saved.meta.keys { saved.meta[name]?.systemFields = nil }
                    retry.append(.saveRecord(id))
                case .unknownItem:
                    let name = id.recordName
                    if saved.meta[name]?.systemFields != nil, let kind = Self.kind(of: name),
                       let key: String = kind.hashed ? failure.record.encryptedValues["mac"] : itemID(name, kind) {
                        // It was in iCloud, and another device has deleted it since: deleted here
                        // too, not brought back by a change made here meanwhile (a reorder, say).
                        saved.meta[name] = nil
                        changes[kind, default: [:]].updateValue(nil, forKey: key)
                    } else {
                        // Never in iCloud (or its record lost): saved afresh.
                        saved.meta[name]?.systemFields = nil
                        retry.append(.saveRecord(id))
                    }
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
            if householdMissing { Task { await householdGone() } }

        case .didFetchChanges, .didSendChanges:
            // (The replace plan stays: only records from before the leave are ever removed, and
            // a fetch cut short leaves some still to come.)
            if case .didFetchChanges = event, saved.shared != nil {
                saved.householdFetched = .now
                persist()
            }
            finishRound()
            // A followed leave found done in that fetch: its plan's dropped now that it's over.
            if case .didFetchChanges = event, followPlanDone {
                followPlanDone = false
                if saved.replacing?.skipOnly == true { dropFollowPlan() }
            }

        default:
            break
        }
    }

    private static let accountUserKey = "cloudLibrary.accountUser"

    /// Remembers the Apple ID signed in (its user record); whether it's another than the last one.
    private static func noteUser(_ user: CKRecord.ID) -> Bool {
        let last = UserDefaults.standard.string(forKey: accountUserKey)
        UserDefaults.standard.set(user.recordName, forKey: accountUserKey)
        return last != nil && last != user.recordName
    }

    /// Signed out of iCloud: what's here stays (asked whether to keep it), with a note of what of
    /// it was synced, and from where. Off the household (it's the account's), onto the private
    /// database, which waits for an account.
    private func signedOut() {
        guard saved.signedOut == nil else { return } // said once (a new engine may report it too)
        var hashes: [String: Data] = [:]
        // What changed here and hadn't gone up keeps when it changed (stamped so on signing back in).
        var changedHere = saved.changedHere ?? [:]
        for kind in Kind.allCases {
            for (id, item) in current(kind) {
                let name = Self.recordName(kind, id)
                let hash = Self.hash(item)
                guard let meta = saved.meta[name], meta.hash == hash else { continue }
                if !meta.unsent {
                    hashes[name] = hash
                } else if changedHere[name]?.hash != hash {
                    changedHere[name] = ChangeStamp(hash: hash, at: meta.modified)
                }
            }
        }
        // Signed back in and out again before it was worked out where this goes (nothing synced
        // since): as it was at the last signing out, less what's changed since.
        if let back = saved.returning {
            for kind in Kind.allCases {
                for (id, item) in current(kind) {
                    let name = Self.recordName(kind, id)
                    if let hash = back.hashes[name], hash == Self.hash(item) { hashes[name] = hash }
                }
            }
        }
        // Held for where it goes (left elsewhere, say): those aren't the library's. They keep when
        // they changed, as what changed here does (they have no meta for it).
        for (name, at) in saved.newHere ?? [:] {
            hashes[name] = nil
            if let hash = saved.heldHashes?[name] { changedHere[name] = ChangeStamp(hash: hash, at: at) }
        }
        var note = SignedOut(membership: membership ?? saved.leftQuestion ?? saved.returning?.membership, hashes: hashes)
        note.gone = saved.returning?.gone // deleted while signed out then: still to go
        // Put out by this account itself (Remove Me): asked as leaving on signing back in too.
        // (While it's asked, the household's still this device's: `membership` is set then too.)
        note.leftSelf = saved.leftQuestion != nil ? saved.leftSelf : (membership == nil ? saved.returning?.leftSelf : nil)
        let leaveAttempts = saved.leaveAttempts
        let confirmLeave = saved.confirmLeave
        let wasShared = saved.shared != nil
        let householdJoin = saved.householdJoin
        let leaving = saved.leaving
        let toLeave = saved.toLeave
        let toLeaveSince = saved.toLeaveSince
        let toLeaveJoins = saved.toLeaveJoins
        let withdrawing = saved.withdrawing
        let joiningTo = saved.joiningTo
        // Leaving with a copy: what's known of the household's items stays (for the copy).
        let leavingMeta = leaving != nil ? saved.meta : [:]
        let leavingUnreadable = leaving != nil ? saved.unreadable : nil
        let replacing = saved.shared == nil ? saved.replacing : nil
        // The question about what's only here (left fresh elsewhere): asked again on signing in.
        var heldNote: [String: Date]?
        var heldHashesNote: [String: Data]?
        if saved.askingFresh == true {
            heldNote = saved.newHere
            heldHashesNote = saved.heldHashes
        }
        saved = Saved()
        saved.householdJoin = householdJoin
        saved.leaving = leaving // finished on signing back in
        saved.toLeave = toLeave
        saved.toLeaveSince = toLeaveSince
        saved.toLeaveJoins = toLeaveJoins
        saved.withdrawing = withdrawing
        saved.joiningTo = joiningTo // likewise
        if leaving != nil {
            saved.meta = leavingMeta
            saved.unreadable = leavingUnreadable
        }
        saved.replacing = replacing // the own library's still to become the copy
        saved.leaveAttempts = leaveAttempts // the same account's, on signing back in
        saved.confirmLeave = confirmLeave
        saved.changedHere = changedHere.isEmpty ? nil : changedHere
        note.heldFresh = heldNote
        if heldNote != nil { note.heldHashes = heldHashesNote }
        saved.signedOut = note
        persist()
        if wasShared {
            makeEngine()
            engineFresh = false // made for this change
        }
        progress.leftHousehold = false
        progress.householdQuestion = nil
        forgetRole()
        status = "Not signed in to iCloud"
        // Keep what's here, or remove it (not while leaving with a copy: what's here is the copy).
        if leaving?.mode != .keep {
            progress.signedOut = true
            Self.showQuestion()
        } else {
            saved.signedOut?.answered = true
            persist()
        }
    }

    /// The answer to "signed out of iCloud": keep what's here, or remove it from this device.
    func answerSignedOut(keep: Bool) {
        progress.signedOut = false
        guard saved.signedOut != nil else { return }
        saved.signedOut?.answered = true
        if !keep {
            clearLibraryHere()
            saved.signedOut?.hashes = [:]
            saved.changedHere = nil
        }
        persist()
    }

    /// Signed back in (the same Apple ID): only what's changed here since signing out is new;
    /// where it goes is worked out against where the account is now (lookUpHousehold).
    private func signedIn() {
        progress.signedOut = false // moot: signed back in
        Task { await refreshHousehold() } // (forgotten on signing out)
        guard saved.switchPending != true else { return }
        // Signed out part way through leaving a household here: that's finished first (what's
        // here is the copy, with what was known of it).
        if let leave = saved.leaving {
            saved.signedOut = nil
            persist()
            Task { await self.finishLeaving(leave) }
            return
        }
        let replacing = saved.replacing
        reset(reseed: false)
        saved.replacing = replacing // (the same account's own library)
        // Part way through joining a household: that's finished first.
        if let intent = saved.joiningTo {
            saved.signedOut = nil
            persist()
            Task { await self.resumeJoin(intent) }
            return
        }
        guard let note = saved.signedOut else {
            // Nothing noted (an older build signed out): what's here goes to the account, which wins.
            Task {
                let found = await self.findHousehold()
                if found != .joined, self.saved.shared == nil, self.saved.switchPending != true { self.seed() }
            }
            return
        }
        // Asked whether to keep what's only here (left fresh elsewhere): asked again.
        if let held = note.heldFresh {
            var kept: [String: Date] = [:]
            var heldHashes: [String: Data] = [:]
            var here = Set<String>()
            for kind in Kind.allCases {
                for (id, item) in current(kind) {
                    let name = Self.recordName(kind, id)
                    here.insert(name)
                    // Still held (as of when it was, unless changed since), or changed or made while
                    // signed out (as of now).
                    let hash = Self.hash(item)
                    let changed = saved.changedHere?[name].flatMap { $0.hash == hash ? $0.at : nil }
                    if let at = held[name] {
                        kept[name] = note.heldHashes?[name] == hash ? at : changed ?? .now
                    } else if note.hashes[name] != hash {
                        kept[name] = changed ?? .now
                    }
                    heldHashes[name] = hash
                }
            }
            // (Before the note's gone: data this build can't read at all is checked against it.)
            for kind in Kind.allCases { here.formUnion(undecodedHere(kind)) }
            saved.signedOut = nil
            saved.changedHere = nil // (taken into what's held)
            saved.deletedHere = Set(note.hashes.keys).subtracting(here).union(note.gone ?? [])
            saved.newHere = kept
            saved.heldHashes = heldHashes.filter { kept[$0.key] != nil }
            saved.askingFresh = true
            persist()
            // Nothing left that's only here (removed on signing out, say): nothing to ask.
            if kept.isEmpty {
                switchKeeping([:], to: nil, adding: false)
            } else {
                ask(.leftFresh(kept.count), nil)
            }
            return
        }
        var new: [String: Date] = [:]
        var newHashes: [String: Data] = [:]
        var here = Set<String>()
        for kind in Kind.allCases {
            for (id, item) in current(kind) {
                let name = Self.recordName(kind, id)
                here.insert(name)
                let hash = Self.hash(item)
                if note.hashes[name] != hash {
                    // As of when it changed here (noted while signed out, or before and not sent);
                    // a copy's item not sent yet: as of its time in the copy.
                    let changed = saved.changedHere?[name].flatMap { $0.hash == hash ? $0.at : nil }
                    new[name] = changed ?? ownPlan.flatMap { $0.stamps?[name] ?? $0.stamp } ?? .now
                    newHashes[name] = hash
                }
            }
        }
        // What this build can't read isn't deleted, only unread.
        for kind in Kind.allCases { here.formUnion(undecodedHere(kind)) }
        var back = note
        back.gone = Set(note.hashes.keys).subtracting(here).union(note.gone ?? [])
        saved.signedOut = nil
        saved.changedHere = nil // (taken into what's held)
        saved.returning = back
        saved.newHere = new
        saved.heldHashes = newHashes
        persist()
        Task { await self.findHousehold() }
    }

    /// Another Apple ID: the question about what's here is asked (AccountSwitchPrompt), and the
    /// last one's household is nothing to this one.
    private func switchedAccounts() {
        if saved.shared != nil {
            // Back on the private database: a household belongs to the account that joined it.
            saved = Saved()
            makeEngine()
            engineFresh = false // made for this change
        }
        reset(reseed: false)
        saved.householdJoin = nil
        saved.pendingHousehold = nil
        saved.leftQuestion = nil
        saved.newHere = nil
        saved.signedOut = nil
        saved.returning = nil
        saved.askingFresh = nil
        saved.leaving = nil // the last account's
        saved.leaveAttempts = nil
        saved.confirmLeave = nil
        saved.leftSelf = nil
        saved.toLeave = nil
        saved.toLeaveSince = nil
        saved.toLeaveJoins = nil
        saved.withdrawing = nil
        saved.joiningTo = nil
        saved.deletedHere = nil
        saved.changedHere = nil
        forgetRole()
        progress.leftHousehold = false
        progress.householdQuestion = nil
        progress.signedOut = false
        saved.switchPending = true
        persist()
        progress.accountSwitched = true
        Task { await refreshHousehold() } // this account's own sharing, if any
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
        // (Leaving a household: no deletions to it either.)
        let leaving = await MainActor.run { self.saved.leaving != nil }
        let changes = syncEngine.state.pendingRecordZoneChanges.filter { change in
            guard scope.contains(change) else { return false }
            if leaving, case .deleteRecord = change { return false }
            return true
        }
        return await CKSyncEngine.RecordZoneChangeBatch(pendingChanges: changes) { id in
            await MainActor.run {
                // A library switched from meanwhile: nothing of the new one goes to the old one's zone.
                // Leaving: nothing more to the household (edits here are for the copy).
                // Held here (where it goes isn't decided): not sent.
                guard syncEngine === self.engine, id.zoneID == self.zoneID, self.saved.leaving == nil,
                      self.saved.newHere?[id.recordName] == nil else { return nil }
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
    /// What this account is in a household: not in one, its owner (sharing its own library), an
    /// administrator of the one it's in (may add and remove people), or a member.
    enum Role { case none, owner, administrator, member }
    var role = Role.none
    /// As the owner: the others in it.
    var members: [HouseholdMember] = []
    /// Put out of a household (its owner stopped sharing, or removed this account): keep a copy, or start fresh?
    var leftHousehold = false
    /// That was this account taking itself out (an administrator's Remove Me): asked as leaving.
    var leftSelf = false
    /// It's a household the account went on to from another device, which this one was never in.
    var leftElsewhere = false
    /// This device's leave of its household is still under way (offline, say).
    var leavingPending = false
    /// No longer in the household, and keeping a copy or starting fresh isn't answered yet.
    var putOut = false
    /// Where this device's library goes is being sorted out (a question open, signed back in…).
    var sortingOut = false
    /// The role's been read from iCloud since launch or the last account change (not just assumed).
    var roleKnown = false
    /// Signed out of iCloud: keep what's here, or remove it?
    var signedOut = false
    /// Something to say that isn't a question (why an invitation couldn't be accepted, say).
    var notice: String? {
        didSet {
            #if WIZ_ICLOUD
            if notice != nil { CloudLibrary.showQuestion() }
            #endif
        }
    }
    #if WIZ_ICLOUD
    /// An invitation to a household library, opened here and waiting for an answer.
    var invitation: CKShare.Metadata?
    /// This account's own library's share, if it has one (as last read): Share Library offers it
    /// rather than making another.
    var ownShare: CKShare?
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
    /// The library's share, if it has one already (as last read): offered as it is.
    var existing: CKShare? = nil

    static var transferRepresentation: some TransferRepresentation {
        CKShareTransferRepresentation { (item: HouseholdShare) -> CKShareTransferRepresentation<HouseholdShare>.ExportedShare in
            let container = CKContainer(identifier: CloudLibrary.containerID)
            if let share = item.existing { return .existing(share, container: container) }
            return .prepareShare(container: container) {
                try await CloudLibrary.shared.makeShare()
            }
        }
    }
}
#endif

/// Someone else in the household this account owns.
struct HouseholdMember: Identifiable, Equatable {
    let id: String
    let name: String
    let isAdministrator: Bool
    let accepted: Bool
}

#if WIZ_ICLOUD
extension HouseholdMember {
    init(_ p: CKShare.Participant) {
        let name = p.userIdentity.nameComponents.map { PersonNameComponentsFormatter.localizedString(from: $0, style: .default) }
        self.init(id: p.participantID,
                  name: name.flatMap { $0.isEmpty ? nil : $0 } ?? p.userIdentity.lookupInfo?.emailAddress ?? p.userIdentity.lookupInfo?.phoneNumber ?? "Someone",
                  isAdministrator: p.role == .administrator,
                  accepted: p.acceptanceStatus == .accepted)
    }
}
#endif

/// Settings' household rows: share this library (and, its owner, manage who's in it), or the one
/// joined: manage it (an administrator) and leave it.
struct HouseholdRows: View {
    #if WIZ_ICLOUD
    @State private var confirmLeave = false
    /// A member's administrator toggle as just set, until the share says so.
    @State private var settingAdmin: [String: Bool] = [:]
    @Environment(\.scenePhase) private var scenePhase
    #endif

    var body: some View {
        #if WIZ_ICLOUD
        let progress = CloudLibrary.shared.progress
        if progress.putOut {
            // No longer in it, and not answered yet (it couldn't be done then, say).
            LabeledContent("Library", value: "No longer shared with you")
                .modifier(Refreshing(scenePhase: scenePhase, household: progress.household))
            Button("Keep a Copy or Start Fresh…") { CloudLibrary.shared.askLeftAgain() }
        } else if progress.leavingPending {
            LabeledContent("Library", value: "Leaving the household (finished once you're online)")
                .modifier(Refreshing(scenePhase: scenePhase, household: progress.household))
        } else if progress.household != nil {
            LabeledContent("Library", value: progress.role == .administrator ? "Shared with you (you can add and remove people)" : "Shared with you")
                .modifier(Refreshing(scenePhase: scenePhase, household: progress.household))
            if progress.role == .administrator { manageButton }
            // (Not while joining another, say: that's finished first.)
            if !progress.sortingOut {
                Button("Leave Household…") { confirmLeave = true }
                    .confirmationDialog("Leave the household?", isPresented: $confirmLeave) {
                        Button("Keep a Copy") { Task { await CloudLibrary.shared.leaveHousehold(keep: true) } }
                        Button("Start Fresh", role: .destructive) { Task { await CloudLibrary.shared.leaveHousehold(keep: false) } }
                    } message: {
                        Text("Keep a copy of its presets, custom scenes, CCT scales, bulbs and signing keys as your own library, or start with an empty one? Your other devices do the same.")
                    }
            }
        } else if progress.role == .owner {
            let joined = progress.members.contains(where: \.accepted)
            LabeledContent("Library", value: joined ? "Shared with your household" : "Shared: waiting for people to join")
                .modifier(Refreshing(scenePhase: scenePhase, household: progress.household))
            manageButton
            ForEach(progress.members) { member in
                Toggle(isOn: Binding(get: { settingAdmin[member.id] ?? member.isAdministrator },
                                     set: { on in
                                         settingAdmin[member.id] = on
                                         Task {
                                             await CloudLibrary.shared.setAdministrator(member, on)
                                             settingAdmin[member.id] = nil
                                         }
                                     })) {
                    Text(member.name)
                    Text("Administrator (can add and remove people)")
                    if !member.accepted { Text("Invited, not joined yet") }
                }
            }
        } else if progress.sortingOut || !progress.roleKnown {
            // Not offered until it's known this account isn't in a household or sharing already.
            LabeledContent("Library", value: progress.sortingOut ? "Sorting out where this device's library goes" : "Checking iCloud…")
                .modifier(Refreshing(scenePhase: scenePhase, household: progress.household))
        } else {
            ShareLink(item: HouseholdShare(existing: progress.ownShare), preview: SharePreview("setPilot Library")) {
                Label("Share Library with Household…", systemImage: "person.2")
            }
            .modifier(Refreshing(scenePhase: scenePhase, household: progress.household))
        }
        #endif
    }

    #if WIZ_ICLOUD
    /// The system's own screen for the household: people, what they can do, stopping sharing.
    private var manageButton: some View {
        Button("Manage Household…") {
            Task {
                #if os(iOS)
                guard let share = try? await CloudLibrary.shared.shareToManage() else {
                    CloudLibrary.shared.progress.notice = "Couldn't open the household's sharing settings: check you're online, then try again."
                    return
                }
                CloudSharingPresenter.present(share)
                #else
                await CloudLibrary.shared.manageOnMac()
                #endif
            }
        }
    }
    #endif
}

#if WIZ_ICLOUD
/// Keeps the household rows up to date: on showing, when the household changes, and on coming
/// back to the app (sharing from the share sheet, say).
private struct Refreshing: ViewModifier {
    let scenePhase: ScenePhase
    let household: String?

    func body(content: Content) -> some View {
        content
            .task(id: household) { await CloudLibrary.shared.refreshHousehold() }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active { Task { await CloudLibrary.shared.refreshHousehold() } }
            }
    }
}
#endif

#if WIZ_ICLOUD && os(iOS)
import UIKit

/// UICloudSharingController, presented as UIKit expects (from the top view controller), for
/// Manage Household.
@MainActor
enum CloudSharingPresenter {
    private static let watcher = Watcher()

    static func present(_ share: CKShare) {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        guard var top = (scenes.first { $0.activationState == .foregroundActive } ?? scenes.first)?.keyWindow?.rootViewController else { return }
        while let next = top.presentedViewController { top = next }
        let controller = UICloudSharingController(share: share, container: CKContainer(identifier: CloudLibrary.containerID))
        // Everyone can change things: there's no read-only use of the library.
        controller.availablePermissions = [.allowPrivate, .allowReadWrite]
        controller.delegate = watcher
        top.present(controller, animated: true)
    }

    private final class Watcher: NSObject, UICloudSharingControllerDelegate {
        func itemTitle(for csc: UICloudSharingController) -> String? { "setPilot Library" }

        func cloudSharingController(_ csc: UICloudSharingController, failedToSaveShareWithError error: Error) {
            Task { @MainActor in
                CloudLibrary.shared.progress.notice = "Couldn't save the change: \(error.localizedDescription)"
                await CloudLibrary.shared.refreshHousehold()
            }
        }

        func cloudSharingControllerDidSaveShare(_ csc: UICloudSharingController) {
            Task { @MainActor in await CloudLibrary.shared.refreshHousehold() }
        }

        func cloudSharingControllerDidStopSharing(_ csc: UICloudSharingController) {
            // (A member's Remove Me: leaving the household.)
            Task { @MainActor in await CloudLibrary.shared.stoppedSharing() }
        }
    }
}
#endif

#if WIZ_ICLOUD && os(macOS)
/// Refreshes the household rows when the Mac's sharing screen saves or stops sharing.
final class SharingWatcher: NSObject, NSCloudSharingServiceDelegate {
    static let shared = SharingWatcher()

    func sharingService(_ sharingService: NSSharingService, didSave share: CKShare) { refresh() }
    // (A member's Remove Me: leaving the household.)
    func sharingService(_ sharingService: NSSharingService, didStopSharing share: CKShare) {
        Task { @MainActor in await CloudLibrary.shared.stoppedSharing() }
    }

    private func refresh() { Task { @MainActor in await CloudLibrary.shared.refreshHousehold() } }
}
#endif

extension View {
    /// Asks what to do when an invitation to a household library is opened here.
    func householdInvitationPrompt() -> some View { modifier(HouseholdInvitationPrompt()) }
}

private struct HouseholdInvitationPrompt: ViewModifier {
    @Environment(\.scenePhase) private var scenePhase

    func body(content: Content) -> some View {
        #if WIZ_ICLOUD
        let progress = CloudLibrary.shared.progress
        // What's asked, as it is when it's answered (the alert's dismissal may clear it first).
        let invitation = progress.invitation
        let question = progress.householdQuestion
        content.alert("Join this household's setPilot library?",
                      isPresented: Binding(get: { progress.invitation != nil }, set: { if !$0 { progress.invitation = nil } })) {
            Button("Join, Adding Mine") { answer(invitation, addMine: true) }
            Button("Join, Replacing Mine", role: .destructive) { answer(invitation, addMine: false) }
            Button("Not Now", role: .cancel) { progress.invitation = nil }
        } message: {
            Text("Presets, custom scenes, CCT scales, bulbs and signing keys are then shared with everyone in it, on all your devices."
                 + (progress.putOut ? " This also answers what to do about the household you're no longer in."
                    : progress.household != nil ? " You leave the household you're in now." : ""))
        }
        // Put out of the household (or this account took itself out): a copy, or a fresh start.
        .alert(progress.leftSelf ? "You've left the household" : progress.leftElsewhere ? "Your account is no longer in its household" : "You're no longer in the household",
               isPresented: Binding(get: { progress.leftHousehold }, set: { if !$0 { progress.leftHousehold = false } })) {
            Button("Keep a Copy") { Task { await CloudLibrary.shared.leaveHousehold(keep: true) } }
            Button("Start Fresh", role: .destructive) { Task { await CloudLibrary.shared.leaveHousehold(keep: false) } }
        } message: {
            if progress.leftElsewhere {
                Text("On another of your devices, your account joined another household, and has since been taken out of that one: its owner stopped sharing it or removed you, or you removed yourself. Keep a copy of that household's presets, custom scenes, CCT scales, bulbs and signing keys as your own library (your devices that were in it bring it, and this one keeps what it hadn't synced), or start with an empty one? Your other devices do the same.")
            } else {
                Text((progress.leftSelf ? "" : "Its owner stopped sharing it or removed you, or you removed yourself on another of your devices. ")
                     + "Keep a copy of its presets, custom scenes, CCT scales, bulbs and signing keys as your own library, or start with an empty one? Your other devices do the same.")
            }
        }
        // Signed out of iCloud: what's here stays, or goes.
        .alert("Signed out of iCloud", isPresented: Binding(get: { progress.signedOut }, set: { if !$0 { progress.signedOut = false } })) {
            Button("Keep Them") { CloudLibrary.shared.answerSignedOut(keep: true) }
            Button("Remove Them", role: .destructive) { CloudLibrary.shared.answerSignedOut(keep: false) }
        } message: {
            Text("Keep this device's presets, custom scenes, CCT scales, bulbs and signing keys, or remove them from it? Signing in again, what you've changed meanwhile is added to your library, or your household's.")
        }
        .alert(progress.notice ?? "", isPresented: Binding(get: { progress.notice != nil }, set: { if !$0 { progress.notice = nil } })) {
            Button("OK") { progress.notice = nil }
        }
        // Joined on another device of this account: what to do with what's only here.
        .alert(householdTitle(progress.householdQuestion),
               isPresented: Binding(get: { progress.householdQuestion != nil }, set: { if !$0 { progress.householdQuestion = nil } })) {
            if case .noRecord? = progress.householdQuestion {
                Button("Join, Adding Mine") { CloudLibrary.shared.answerHousehold(question, addMine: true) }
                Button("Join, Replacing Mine", role: .destructive) { CloudLibrary.shared.answerHousehold(question, addMine: false) }
            } else if case .leftFresh? = progress.householdQuestion {
                Button("Keep Them") { CloudLibrary.shared.answerHousehold(question, addMine: true) }
                Button("Remove Them", role: .destructive) { CloudLibrary.shared.answerHousehold(question, addMine: false) }
            } else {
                Button("Add Them") { CloudLibrary.shared.answerHousehold(question, addMine: true) }
                Button("Leave Them Out", role: .destructive) { CloudLibrary.shared.answerHousehold(question, addMine: false) }
            }
            if case .leftFresh? = progress.householdQuestion {} else {
                Button("Not Now", role: .cancel) { CloudLibrary.shared.answerHousehold(question, addMine: nil) }
            }
        } message: {
            Text(householdMessage(progress.householdQuestion))
        }
        // Coming back to the app: a question about the household left may have been answered on
        // another device meanwhile (those don't sync the own library, so they'd not hear of it).
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { await CloudLibrary.shared.recheckLeft() } }
        }
        #else
        content
        #endif
    }

    #if WIZ_ICLOUD
    private func householdTitle(_ question: CloudLibrary.HouseholdQuestion?) -> String {
        if case .newItems(let n)? = question { return n == 1 ? "1 item here isn't in the household" : "\(n) items here aren't in the household" }
        if case .leftFresh(let n)? = question { return n == 1 ? "1 item here is only on this device" : "\(n) items here are only on this device" }
        return "Your account is in a household library"
    }

    private func householdMessage(_ question: CloudLibrary.HouseholdQuestion?) -> String {
        if case .newItems? = question {
            return "The household was joined on another of your devices, replacing its library. These weren't on that device. Add them to the household, or leave them out?"
        }
        if case .leftFresh? = question {
            return "The household was left on another of your devices, starting fresh. These hadn't reached the household. Keep them in your library, or remove them?"
        }
        return "It was joined on another of your devices. Join it here too, adding this device's presets, custom scenes, CCT scales, bulbs and signing keys, or replacing them with the household's?"
    }

    private func answer(_ metadata: CKShare.Metadata?, addMine: Bool) {
        guard let metadata else { return }
        CloudLibrary.shared.progress.invitation = nil
        Task { await CloudLibrary.shared.join(metadata, addMine: addMine) }
    }
    #endif
}
