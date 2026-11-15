import AppKit
import ServiceManagement
import SwiftUI

@main
struct SetPilotApp: App {
    @NSApplicationDelegateAdaptor private var delegate: AppDelegate
    /// One connection to the bulb, shared by the window and the menu bar panel.
    @State private var model = Model()

    var body: some Scene {
        Window("WiZ", id: "main") { ContentView(model: model) }
            .windowResizability(.contentSize)
        MenuBarExtra {
            MenuBarPanel(model: model)
        } label: {
            Image(systemName: model.isOn == true ? "lightbulb.fill" : "lightbulb")
                // The label exists from launch, even when no window opens (launched at login).
                .onAppear { model.startIfSaved() }
        }
        .menuBarExtraStyle(.window)
        Settings { SettingsView() }
    }
}

enum DockIcon {
    static let key = "showInDock"

    static var shown: Bool { UserDefaults.standard.object(forKey: key) as? Bool ?? true }

    @MainActor static func apply(_ show: Bool) {
        NSApp.setActivationPolicy(show ? .regular : .accessory)
        if !show { NSApp.activate() } // keep any open window in front after losing the Dock icon
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var launchedAtLogin = false

    func applicationWillFinishLaunching(_ notification: Notification) {
        // macOS marks a login-item launch in the "open application" event's properties.
        let event = NSAppleEventManager.shared().currentAppleEvent
        launchedAtLogin = event?.eventID == AEEventID(kAEOpenApplication)
            && event?.paramDescriptor(forKeyword: AEKeyword(keyAEPropData))?.enumCodeValue == OSType(keyAELaunchedAsLogInItem)
        NSApp.setActivationPolicy(DockIcon.shown ? .regular : .accessory)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard launchedAtLogin else { return }
        // Launched at login: just the menu bar item, no window.
        for delay in [0.0, 0.3] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                for window in NSApp.windows where window.canBecomeMain && window.isVisible { window.close() }
            }
        }
    }

    /// Keep running in the menu bar when the window is closed.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}

struct SettingsView: View {
    @AppStorage(DockIcon.key) private var showInDock = true
    @State private var openAtLogin = SMAppService.mainApp.status == .enabled
    @State private var loginItemNote: String?
    @AppStorage(ColourTemperature.adaptingWhiteKey) private var adaptingWhite = ColourTemperature.defaultAdaptingWhite

    var body: some View {
        Form {
            Section("General") {
                Toggle("Show in Dock", isOn: $showInDock)
                    .onChange(of: showInDock) { _, show in DockIcon.apply(show) }
                // A binding rather than onChange, so refreshing the status never re-registers.
                Toggle("Open at login (menu bar only)",
                       isOn: Binding(get: { openAtLogin }, set: { setOpenAtLogin($0) }))
                if let loginItemNote {
                    HStack {
                        Text(loginItemNote).font(.callout).foregroundStyle(.secondary)
                        Spacer()
                        Button("Login Items…") { SMAppService.openSystemSettingsLoginItems() }
                    }
                }
            }

            // Testing aid: the white the colour-temperature colours are adapted to.
            Section("Colour temperature (testing)") {
                LabeledContent("Adapted to") {
                    HStack {
                        Slider(value: $adaptingWhite, in: 3000...7000, step: 50)
                        Text("\(Int(adaptingWhite)) K").monospacedDigit().frame(width: 64, alignment: .trailing)
                        Stepper("", value: $adaptingWhite, in: 3000...7000, step: 50).labelsHidden()
                    }
                }
                LabeledContent("Preview") {
                    HStack(spacing: 4) {
                        ForEach([2200.0, 2700, 3000, 3500, 4200, 5000, 6500], id: \.self) { k in
                            VStack(spacing: 2) {
                                RoundedRectangle(cornerRadius: 4)
                                    .fill(Color(nsColor: ColourTemperature.colour(kelvin: k)))
                                    .frame(width: 44, height: 28)
                                    .id(adaptingWhite) // redraw when the setting changes
                                Text("\(Int(k))").font(.caption2).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                HStack {
                    Spacer()
                    Button("Reset to \(Int(ColourTemperature.defaultAdaptingWhite)) K") {
                        adaptingWhite = ColourTemperature.defaultAdaptingWhite
                    }
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 520)
        .fixedSize(horizontal: false, vertical: true)
        .onAppear { refreshLoginItem() }
    }

    private func setOpenAtLogin(_ on: Bool) {
        let service = SMAppService.mainApp
        do {
            if on, service.status != .enabled { try service.register() }
            if !on, service.status == .enabled { try service.unregister() }
        } catch {
            loginItemNote = "Couldn't change the login item: \(error.localizedDescription)"
        }
        refreshLoginItem()
    }

    private func refreshLoginItem() {
        let status = SMAppService.mainApp.status
        openAtLogin = status == .enabled || status == .requiresApproval
        if status == .requiresApproval {
            loginItemNote = "Needs approval in System Settings › General › Login Items."
        } else if loginItemNote?.hasPrefix("Couldn't") != true {
            loginItemNote = nil
        }
    }
}
