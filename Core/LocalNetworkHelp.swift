import SwiftUI
#if os(iOS)
import UIKit
#else
import AppKit
#endif

/// Shown when the system won't let setPilot reach the local network (the permission was turned
/// down or off): what's wrong, and a button to the setting.
struct LocalNetworkHelp: View {
    let model: Model

    var body: some View {
        if model.localNetworkDenied {
            VStack(alignment: .leading, spacing: 6) {
                Label("Local Network access is off", systemImage: "wifi.exclamationmark")
                    .font(.headline)
                Text(explanation)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Open Settings", action: openSettings)
            }
            .padding(.vertical, 4)
        }
    }

    private var explanation: String {
        #if os(iOS)
        "setPilot talks to your bulb over your Wi-Fi, which needs Local Network access. Turn it on for setPilot in Settings › Apps › setPilot (or Privacy & Security › Local Network), then come back."
        #else
        "setPilot talks to your bulb over your network, which needs Local Network access. Turn it on for setPilot in System Settings › Privacy & Security › Local Network."
        #endif
    }

    private func openSettings() {
        #if os(iOS)
        if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
        #else
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_LocalNetwork") {
            NSWorkspace.shared.open(url)
        }
        #endif
    }
}
