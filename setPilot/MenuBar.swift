import AppKit
import SwiftUI

/// The menu bar item's panel: status, power, and the same light controls as the window.
struct MenuBarPanel: View {
    let model: Model
    @AppStorage("bulbIP") private var ip = ""
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Circle()
                    .fill(model.linkColour)
                    .frame(width: 8, height: 8)
                VStack(alignment: .leading, spacing: 1) {
                    Text(ip.isEmpty ? "WiZ" : ip).font(.headline)
                    Text(model.linkText).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                ProgressView()
                    .controlSize(.small)
                    .opacity(model.pending ? 1 : 0)
                Toggle("Power", isOn: model.powerBinding)
                    .toggleStyle(.switch)
                    .labelsHidden()
                    .disabled(model.link != .connected)
            }

            if model.link == .connected {
                LightControls(model: model, compact: true)
            } else {
                Text(ip.isEmpty ? "Open setPilot to find your bulb." : "Waiting for the bulb to answer.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Divider()

            HStack(spacing: 14) {
                Button("Open setPilot") {
                    openWindow(id: "main")
                    NSApp.activate()
                }
                Button("Settings…") {
                    openSettings()
                    NSApp.activate()
                }
                Spacer()
                Button("Quit setPilot") {
                    AppDelegate.reallyQuit = true
                    NSApp.terminate(nil)
                }
            }
            .buttonStyle(.borderless)
        }
        .padding(14)
        .frame(width: 400)
        .onAppear { model.startIfSaved() }
    }
}
