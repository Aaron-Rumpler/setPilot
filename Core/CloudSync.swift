import Foundation

/// iCloud sync of small settings (presets, custom scenes, CCT scales, bulb names) through iCloud
/// key-value storage, between the Mac and iPhone apps. Only in builds with `WIZ_ICLOUD` set
/// (Account.xcconfig), since it needs a paid developer account; otherwise everything here does
/// nothing.
///
/// Each key syncs as a whole, last change wins. When a key first syncs, what's in iCloud is
/// used if there is anything; otherwise this device's copy is uploaded.
@MainActor
final class CloudSync {
    static let shared = CloudSync()

    #if WIZ_ICLOUD
    static let isEnabled = true
    #else
    static let isEnabled = false
    #endif

    private var handlers: [String: (Data) -> Void] = [:]
    private var observing = false

    /// Starts syncing `key`. `apply` takes a value from iCloud (now, if iCloud has one that
    /// differs, and whenever another device changes it).
    func register(_ key: String, local: Data?, apply: @escaping (Data) -> Void) {
        #if WIZ_ICLOUD
        handlers[key] = apply
        startObserving()
        let store = NSUbiquitousKeyValueStore.default
        if let remote = store.data(forKey: key) {
            if remote != local { apply(remote) }
        } else if let local {
            store.set(local, forKey: key)
        }
        #endif
    }

    /// Uploads a new value for `key`.
    func put(_ key: String, _ data: Data) {
        #if WIZ_ICLOUD
        NSUbiquitousKeyValueStore.default.set(data, forKey: key)
        #endif
    }

    #if WIZ_ICLOUD
    private func startObserving() {
        guard !observing else { return }
        observing = true
        let store = NSUbiquitousKeyValueStore.default
        NotificationCenter.default.addObserver(
            forName: NSUbiquitousKeyValueStore.didChangeExternallyNotification, object: store, queue: .main
        ) { note in
            let keys = note.userInfo?[NSUbiquitousKeyValueStoreChangedKeysKey] as? [String] ?? []
            MainActor.assumeIsolated {
                // The shared store, not the captured one: it isn't Sendable.
                for key in keys {
                    if let data = NSUbiquitousKeyValueStore.default.data(forKey: key) { CloudSync.shared.handlers[key]?(data) }
                }
            }
        }
        store.synchronize()
    }
    #endif
}

import SwiftUI

/// Settings section showing whether this build syncs through iCloud.
struct CloudSyncSection: View {
    var body: some View {
        Section {
            LabeledContent("iCloud sync", value: CloudSync.isEnabled ? "On" : "Off in this build")
        } header: {
            Text("Sync")
        } footer: {
            Text(CloudSync.isEnabled
                 ? "Presets, custom scenes, CCT scales and bulb names sync between your Mac and iPhone through iCloud."
                 : "iCloud needs a paid Apple developer account. To build with it, set WIZ_ICLOUD = YES in Account.xcconfig.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }
}
