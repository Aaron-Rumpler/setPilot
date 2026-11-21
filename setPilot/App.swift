import AppKit
import ServiceManagement
import SwiftUI

@main
struct SetPilotApp: App {
    @NSApplicationDelegateAdaptor private var delegate: AppDelegate
    /// One connection to the bulb, shared by the windows, the menu bar panel and Shortcuts.
    @State private var model = Shared.model

    init() {
        // Shortcuts and Siri learn the preset names from this, at launch and when they change.
        Shared.model.library.onChange = { ShortcutNames.update() }
        SetPilotShortcuts.updateAppShortcutParameters()
    }

    var body: some Scene {
        Window("setPilot", id: "main") { ContentView(model: model) }
            .windowResizability(.contentSize)
            .commands { LightCommands(model: model) }
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
        Window("Light Show", id: "lightshow") { LightShowView(model: model).frame(minWidth: 640, minHeight: 440) }
            .defaultSize(width: 960, height: 680)
            .keyboardShortcut("l", modifiers: [.command, .option])
        Settings { SettingsView(model: model) }
            .windowResizability(.contentSize)
    }
}

/// Tells Shortcuts the preset names once edits pause (renaming types a name a letter at a time).
@MainActor
enum ShortcutNames {
    private static var pending: Task<Void, Never>?

    static func update() {
        pending?.cancel()
        pending = Task {
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            SetPilotShortcuts.updateAppShortcutParameters()
        }
    }
}

/// The Light menu: power, and the first nine presets on ⌘1–⌘9.
struct LightCommands: Commands {
    let model: Model

    var body: some Commands {
        CommandMenu("Light") {
            Button(model.isOn == true ? "Switch Off" : "Switch On") { model.power(model.isOn != true) }
                .keyboardShortcut("p", modifiers: [.command, .shift])
                .disabled(!model.canControl)
            Button("Sync") { model.sync() }
                .disabled(model.link == .none)
            Divider()
            let presets = Array(model.library.presets.prefix(9).enumerated())
            if presets.isEmpty {
                Button("No Presets") {}.disabled(true)
            }
            ForEach(presets, id: \.element.id) { i, preset in
                Button(preset.name) { model.apply(preset) }
                    .keyboardShortcut(KeyEquivalent(Character(String(i + 1))), modifiers: .command)
                    .disabled(model.link != .connected)
            }
        }
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

    /// Our normal windows (the main window, Settings, the console, scenes, scales and the light show), not the menu
    /// bar panel.
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
    @AppStorage(Stepping.snapKey) private var snaps = true
    /// The height of all the settings, for the window's size limits.
    @State private var contentHeight: CGFloat?

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
                Toggle("Snap sliders to round numbers", isOn: $snaps)
            } header: {
                Text("Sliders")
            } footer: {
                Text("Steps of 5 for dimming, 50 K for temperatures, 32 for colour channels. To move in 1s anyway, hold Option while dragging (or with the arrow keys), or hold the knob still for a moment before dragging.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Section {
                FadeSetting(model: model)
            } header: {
                Text("Fade")
            } footer: {
                Text("The fade (setPilot's trans) that the controls' Fade and Compose offer as the default. Turning off always uses the bulb's own fade-out.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            CloudSyncSection()
            LibraryTransferSection(model: model)

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
        // A grouped Form scrolls by itself: its content's height sets the window's tallest.
        .scrollContentHeight { contentHeight = $0 }
        .frame(width: 520)
        .windowHeight(content: contentHeight, minimum: 320)
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
