import SwiftUI

/// When this device's bulb isn't answering: offers the bulb your other devices last used (synced
/// through iCloud as "MAC address device", CloudSync). With no bulb chosen, the model just uses it.
/// Not one this device wrote itself, and not in builds without iCloud (nothing else writes it).
struct BulbNudge: View {
    static let key = "bulbInUse"
    let model: Model
    @AppStorage(BulbNudge.key) private var inUse = ""

    /// This device, in what it writes (kept here: not synced).
    static let deviceID: String = {
        let key = "nudgeDeviceID"
        if let id = UserDefaults.standard.string(forKey: key), !id.isEmpty { return id }
        let id = UUID().uuidString
        UserDefaults.standard.set(id, forKey: key)
        return id
    }()

    static func value(mac: String, address: String) -> String { "\(mac) \(address) \(deviceID)" }

    /// The bulb in `value`, if another device wrote it.
    static func offered(_ value: String) -> (mac: String, address: String)? {
        let parts = value.split(separator: " ").map(String.init)
        guard parts.count >= 2, !parts[1].isEmpty else { return nil }
        if parts.count >= 3, parts[2] == deviceID { return nil } // this device's own
        return (parts[0], parts[1])
    }

    private var offered: (mac: String, address: String)? { CloudSync.isEnabled ? Self.offered(inUse) : nil }

    var body: some View {
        if let offered, model.link == .none || model.link == .unreachable, offered.mac != model.chosenMAC {
            let name = model.name(for: offered.mac) ?? offered.address
            HStack {
                Label("Your other devices use \(name)", systemImage: "lightbulb")
                    .font(.callout)
                Spacer(minLength: 8)
                Button("Use It") { model.choose(offered.address, mac: offered.mac) }
            }
            .padding(.vertical, 2)
        }
    }
}
