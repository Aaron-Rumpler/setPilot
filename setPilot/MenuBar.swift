import AppKit
import SwiftUI

/// The menu bar item's panel: status, power, and the same light controls as the window.
struct MenuBarPanel: View {
    let model: Model
    @AppStorage(Model.addressKey) private var ip = ""
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            BulbPicker(model: model)

            HStack(spacing: 8) {
                Circle()
                    .fill(model.linkColour)
                    .frame(width: 8, height: 8)
                Text(model.linkText).font(.callout).foregroundStyle(.secondary)
                Spacer()
                ProgressView()
                    .controlSize(.small)
                    .opacity(model.pending ? 1 : 0)
                ComposeToggle(model: model)
                    .disabled(!model.canControl)
                Toggle("Power", isOn: model.powerBinding)
                    .toggleStyle(.switch)
                    .labelsHidden()
                    .disabled(!model.canControl)
            }

            if model.canControl {
                if !model.library.presets.isEmpty {
                    PresetGrid(model: model, columns: 4, featuredOnly: true)
                    Divider()
                }
                LightControls(model: model, compact: true)
            } else {
                Text(ip.isEmpty ? "Choose a bulb above."
                     : model.link == .unreachable ? (model.status.isEmpty ? "The bulb isn't answering." : model.status)
                     : "Waiting for the bulb to answer.")
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
