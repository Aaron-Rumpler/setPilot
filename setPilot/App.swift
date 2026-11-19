import AppKit
import ServiceManagement
import SwiftUI

@main
struct SetPilotApp: App {
    @NSApplicationDelegateAdaptor private var delegate: AppDelegate
    /// One connection to the bulb, shared by the window and the menu bar panel.
    @State private var model = Model()

    var body: some Scene {
        Window("setPilot", id: "main") { ContentView(model: model) }
            .windowResizability(.contentSize)
        MenuBarExtra {
            MenuBarPanel(model: model)
        } label: {
            MenuBarIcon(isOn: model.isOn == true)
                // The label exists from launch, even when no window opens (launched at login).
                .onAppear { model.startIfSaved() }
        }
        .menuBarExtraStyle(.window)
        Window("Custom Scenes", id: "scenes") { CustomScenesWindow(model: model) }
            .defaultSize(width: 720, height: 640)
        Window("CCT Scales", id: "scales") { CCTScalesWindow(model: model) }
            .defaultSize(width: 720, height: 680)
        Window("Console", id: "console") { ConsoleWindow(model: model) }
            .defaultSize(width: 760, height: 760)
            .keyboardShortcut("k", modifiers: [.command, .option])
        Settings { SettingsView(model: model) }
    }
}

/// The menu bar bulb, lit when the bulb is on: its inside is the light colour (white in a dark
/// menu bar, clear in a light one) when on and the dark colour when off. The symbol is a template
/// drawn in the menu bar's foreground colour, so which symbol that takes depends on the appearance.
private struct MenuBarIcon: View {
    let isOn: Bool
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Image(systemName: isOn == (colorScheme == .dark) ? "lightbulb.fill" : "lightbulb")
            .accessibilityLabel(isOn ? "setPilot, bulb on" : "setPilot, bulb off")
    }
}

/// The app lives in the menu bar. It has a Dock icon only while one of its windows is open, and
/// quitting from the app menu (⌘Q) just closes the windows; the menu bar panel's Quit really quits.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var launchedAtLogin = false
    /// Set by the menu bar panel's Quit button.
    static var reallyQuit = false

    func applicationWillFinishLaunching(_ notification: Notification) {
        // macOS marks a login-item launch in the "open application" event's properties.
        let event = NSAppleEventManager.shared().currentAppleEvent
        launchedAtLogin = event?.eventID == AEEventID(kAEOpenApplication)
            && event?.paramDescriptor(forKeyword: AEKeyword(keyAEPropData))?.enumCodeValue == OSType(keyAELaunchedAsLogInItem)
        NSApp.setActivationPolicy(launchedAtLogin ? .accessory : .regular)

        let centre = NotificationCenter.default
        for name in [NSWindow.didBecomeKeyNotification, NSWindow.didChangeOcclusionStateNotification,
                     NSWindow.didMiniaturizeNotification, NSWindow.willCloseNotification] {
            centre.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                // After the close/show has taken effect.
                DispatchQueue.main.async { MainActor.assumeIsolated { self?.updateDockIcon() } }
            }
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard launchedAtLogin else { return }
        // Launched at login: just the menu bar item, no window. Close it now, before it's drawn if
        // possible, and again shortly after in case SwiftUI opens it late.
        closeWindows()
        for delay in [0.0, 0.3] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { MainActor.assumeIsolated { self.closeWindows() } }
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // Really quit from the panel's Quit button, and when macOS quits apps for logout, restart or
        // shut down (its quit event carries a reason, kAEQuitReason 'why?'). Any other quit, such as
        // ⌘Q or the Dock icon's Quit, just closes the windows and leaves the menu bar item.
        let quitReason: AEKeyword = 0x7768_793F // 'why?'
        let systemQuit = NSAppleEventManager.shared().currentAppleEvent?.attributeDescriptor(forKeyword: quitReason) != nil
        if Self.reallyQuit || systemQuit { return .terminateNow }
        closeWindows()
        return .terminateCancel
    }

    /// Keep running in the menu bar when the window is closed.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    /// Our normal windows (the main window and Settings), not the menu bar panel.
    private var appWindows: [NSWindow] {
        NSApp.windows.filter { $0.styleMask.contains(.titled) && ($0.isVisible || $0.isMiniaturized) }
    }

    private func closeWindows() {
        appWindows.forEach { $0.close() }
        updateDockIcon()
    }

    private func updateDockIcon() {
        let want: NSApplication.ActivationPolicy = appWindows.isEmpty ? .accessory : .regular
        guard NSApp.activationPolicy() != want else { return }
        NSApp.setActivationPolicy(want)
        if want == .regular { NSApp.activate() } // bring the window that just opened to the front
    }
}

struct SettingsView: View {
    let model: Model
    @State private var openAtLogin = SMAppService.mainApp.status == .enabled
    @State private var loginItemNote: String?
    @AppStorage(ColourTemperature.adaptingWhiteKey) private var adaptingWhite = ColourTemperature.defaultAdaptingWhite

    var body: some View {
        Form {
            Section("General") {
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

            Section {
                FadeSetting(model: model)
            } header: {
                Text("Fade")
            } footer: {
                Text("How long each change takes to fade in (setPilot's trans). Turning off always uses the bulb's own fade-out.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            CloudSyncSection()

            // Testing aid: the white the colour-temperature colours are adapted to.
            Section("Colour temperature (testing)") {
                LabeledContent("Adapted to") {
                    HStack {
                        // Snaps to 50 K in the binding: `step:` would draw a tick per step.
                        Slider(value: Binding(get: { adaptingWhite },
                                              set: { adaptingWhite = ($0 / 50).rounded() * 50 }),
                               in: 3000...7000)
                        Text(verbatim: "\(Int(adaptingWhite)) K").monospacedDigit().frame(width: 64, alignment: .trailing)
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
                                Text(verbatim: "\(Int(k))").font(.caption2).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                HStack {
                    Spacer()
                    Button("Reset to \(String(Int(ColourTemperature.defaultAdaptingWhite))) K") {
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
