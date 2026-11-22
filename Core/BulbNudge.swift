import SwiftUI

/// When this device has no bulb, or its bulb isn't answering: offers the bulb your other devices
/// last used (synced through iCloud as "MAC address", CloudSync).
struct BulbNudge: View {
    static let key = "bulbInUse"
    let model: Model
    @AppStorage(BulbNudge.key) private var inUse = ""

    private var offered: (mac: String, address: String)? {
        let parts = inUse.split(separator: " ", maxSplits: 1).map(String.init)
        guard parts.count == 2, !parts[1].isEmpty else { return nil }
        return (parts[0], parts[1])
    }

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
