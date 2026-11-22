import Foundation

/// iCloud sync of settings (how fades work, the adapting white, snapping, the light show's
/// options) through iCloud key-value storage, between the Mac and iPhone apps. The library and
/// bulb names sync item by item through CloudKit instead (CloudLibrary). Only in builds with
/// `WIZ_ICLOUD` set (Account.xcconfig), since it needs a paid developer account; otherwise
/// everything here does nothing.
///
/// Settings that belong to the device stay on it: the chosen bulb, signing keys, the light show's
/// delay (it depends on the device's audio), the log and console settings, open at login.
@MainActor
final class CloudSync {
    static let shared = CloudSync()

    #if WIZ_ICLOUD
    static let isEnabled = true
    #else
    static let isEnabled = false
    #endif

    /// Posted (with the changed keys as `object`) after settings arrive from another device and
    /// have been written to the user defaults, for anything holding a copy of them.
    static let settingsChanged = Notification.Name("CloudSync.settingsChanged")

    /// The user-defaults keys that sync.
    static let settingKeys = [
        Model.fadeKey, Model.controlsFadeKey, Model.controlsFadeMsKey, ColourTemperature.adaptingWhiteKey,
        Stepping.snapKey, LightShowPlayer.sendKey, LightShowPlayer.restoreKey, Flashing.warnKey, Flashing.askKey,
        LastShow.mediaKey, LastShow.showKey, BulbNudge.key,
        // Which CCT scale Temperature uses (per bulb), and whether it uses one.
        Library.activeCCTScaleKey, Model.temperatureScaleKey,
        // The log's and console's options (not what's being typed in the console).
        Model.logLimitKey, "logShowPushes", "logShowRegistration", "logPretty",
        "consoleDontSwitchOn", "consoleRetry", "consoleFullReply",
        // When presets are applied and the light switched (merged, not replaced: PresetUsage).
        PresetUsage.key,
    ]
    private static let prefix = "setting."

    /// What each key last was in iCloud as far as this device knows, so a change from iCloud
    /// isn't sent straight back, and unchanged keys aren't sent at all.
    private var known: [String: NSObject] = [:]
    private var started = false

    /// What builds before item-by-item sync kept in key-value storage under `key`, if anything.
    static func legacyValue(_ key: String) -> Data? {
        #if WIZ_ICLOUD
        NSUbiquitousKeyValueStore.default.data(forKey: key)
        #else
        nil
        #endif
    }

    func start() {
        #if WIZ_ICLOUD
        guard !started else { return }
        started = true
        let store = NSUbiquitousKeyValueStore.default
        store.synchronize()
        let defaults = UserDefaults.standard
        // iCloud's settings, if it has them; otherwise this device's go up.
        var changed: [String] = []
        for key in Self.settingKeys {
            if key == PresetUsage.key {
                mergeUsage(store.object(forKey: Self.prefix + key))
                continue
            }
            if let remote = store.object(forKey: Self.prefix + key) as? NSObject {
                known[key] = remote
                if !remote.isEqual(defaults.object(forKey: key)) {
                    defaults.set(remote, forKey: key)
                    changed.append(key)
                }
            } else if let local = defaults.object(forKey: key) as? NSObject {
                known[key] = local
                store.set(local, forKey: Self.prefix + key)
            }
        }
        if !changed.isEmpty { NotificationCenter.default.post(name: Self.settingsChanged, object: changed) }

        NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: defaults, queue: .main) { _ in
            MainActor.assumeIsolated { CloudSync.shared.sendLocalChanges() }
        }
        NotificationCenter.default.addObserver(
            forName: NSUbiquitousKeyValueStore.didChangeExternallyNotification, object: store, queue: .main
        ) { note in
            let keys = note.userInfo?[NSUbiquitousKeyValueStoreChangedKeysKey] as? [String] ?? []
            MainActor.assumeIsolated { CloudSync.shared.takeRemote(keys) }
        }
        #endif
    }

    #if WIZ_ICLOUD
    private func sendLocalChanges() {
        let defaults = UserDefaults.standard
        let store = NSUbiquitousKeyValueStore.default
        for key in Self.settingKeys {
            guard let value = defaults.object(forKey: key) as? NSObject, !value.isEqual(known[key]) else { continue }
            known[key] = value
            store.set(value, forKey: Self.prefix + key)
        }
    }

    /// The usage record: another device's uses are added to this one's, and the union goes up.
    private func mergeUsage(_ remote: Any?) {
        let defaults = UserDefaults.standard
        if let data = remote as? Data, let uses = try? JSONDecoder().decode([PresetUsage.Use].self, from: data),
           PresetUsage.merge(uses, into: defaults) {
            NotificationCenter.default.post(name: PresetUsage.recorded, object: nil) // quick actions, the watch
        }
        guard let mine = defaults.data(forKey: PresetUsage.key) as NSData?, !mine.isEqual(remote) else { return }
        known[PresetUsage.key] = mine // the merge's own write isn't sent again
        NSUbiquitousKeyValueStore.default.set(mine, forKey: Self.prefix + PresetUsage.key)
    }

    private func takeRemote(_ keys: [String]) {
        let defaults = UserDefaults.standard
        let store = NSUbiquitousKeyValueStore.default
        var changed: [String] = []
        for cloudKey in keys where cloudKey.hasPrefix(Self.prefix) {
            let key = String(cloudKey.dropFirst(Self.prefix.count))
            if key == PresetUsage.key {
                mergeUsage(store.object(forKey: cloudKey))
                continue
            }
            guard Self.settingKeys.contains(key), let value = store.object(forKey: cloudKey) as? NSObject else { continue }
            known[key] = value // before writing, so the write isn't sent back
            if !value.isEqual(defaults.object(forKey: key)) {
                defaults.set(value, forKey: key)
                changed.append(key)
            }
        }
        if !changed.isEmpty { NotificationCenter.default.post(name: Self.settingsChanged, object: changed) }
    }
    #endif
}

import SwiftUI

/// Settings section showing whether this build syncs through iCloud, and how it's going.
struct CloudSyncSection: View {
    @State private var syncing = false

    var body: some View {
        Section {
            if CloudSync.isEnabled {
                let progress = CloudLibrary.shared.progress
                LabeledContent("iCloud sync", value: progress.status)
                if let last = progress.lastSync {
                    LabeledContent("Last synced", value: last.formatted(date: .abbreviated, time: .shortened))
                }
                HouseholdRows()
                Button(syncing ? "Syncing…" : "Sync Now") {
                    syncing = true
                    Task {
                        await CloudLibrary.shared.syncNow()
                        syncing = false
                    }
                }
                .disabled(syncing)
            } else {
                LabeledContent("iCloud sync", value: "Off in this build")
            }
        } header: {
            Text("Sync")
        } footer: {
            Text(CloudSync.isEnabled
                 ? "Presets, custom scenes, CCT scales, bulb names and settings sync between your Mac and iPhone through iCloud, item by item: changes to different presets on each both survive. Signing keys, the chosen bulb and the light show delay stay on each device."
                 : "iCloud needs a paid Apple developer account. To build with it, set WIZ_ICLOUD\u{00A0}=\u{00A0}YES in Account.xcconfig.") // no-break spaces keep the setting in one piece
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }
}
