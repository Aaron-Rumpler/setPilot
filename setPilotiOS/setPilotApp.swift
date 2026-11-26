import SwiftUI

@main
struct SetPilotMobileApp: App {
    @UIApplicationDelegateAdaptor private var delegate: PhoneAppDelegate
    @State private var model = Shared.model
    @Environment(\.scenePhase) private var phase

    init() {
        // Here rather than in a view: the watch can wake the app in the background, with no UI.
        PhoneRelay.shared.start(model: Shared.model)
        Shared.model.library.onChange = {
            PhoneRelay.shared.libraryChanged()
            SpotlightIndex.update(Shared.model.library)
            QuickActions.update(Shared.model.library)
        }
        SpotlightIndex.update(Shared.model.library)
        LightShowLiveActivity.endLeftovers()
        Shared.model.startIfSaved()
        // Widgets and Control Center controls run their actions here, on the app's connection.
        WidgetPerformer.handler = { command in
            let model = Shared.model
            // No bulb to wait for: say so straight away, as Shortcuts do.
            guard let a = UserDefaults.standard.string(forKey: Model.addressKey), !a.isEmpty else {
                throw WidgetError(localizedStringResource: "Choose a bulb in setPilot first.")
            }
            guard await model.waitUntilControllable() else {
                // Answering but refusing to say how it is (a wrong signing key, say): that reason.
                if model.link == .connected, !model.status.isEmpty { throw WidgetError(localizedStringResource: "\(model.status)") }
                throw WidgetError(localizedStringResource: "The bulb isn't answering. Check it's powered and on the same network as your iPhone.")
            }
            switch command {
            case .applyPreset(let id):
                guard let preset = model.library.presets.first(where: { $0.id == id }) else {
                    throw WidgetError(localizedStringResource: "That preset no longer exists.")
                }
                model.apply(preset)
            case .power(let on):
                model.power(on ?? !(model.isOn ?? false))
                try? await Task.sleep(for: .milliseconds(400))
            case .dimDelta(let delta):
                model.adjustDimming(by: delta)
            }
            // Refused, unanswered or not sent (a deleted scene in a preset): say so, as Shortcuts do.
            if let problem = await model.outcome() { throw WidgetError(localizedStringResource: "\(problem)") }
        }
        // Siri learns the preset names from this (also refreshed whenever the presets change).
        SetPilotShortcuts.updateAppShortcutParameters()
    }

    var body: some Scene {
        WindowGroup {
            RootView(model: model)
                // setpilot:// links (Core/URLCommands.swift).
                .onOpenURL { url in Task { await URLCommands.handle(url, model: model) } }
        }
        .commands { LightCommands(model: model) } // an iPad's keyboard: ⇧⌘P, ⌘1–⌘9
        .onChange(of: phase) { _, new in
            if new == .active { model.resume() }
        }
    }
}

final class PhoneAppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        MainActor.assumeIsolated { QuickActions.update(Shared.model.library) }
        #if WIZ_ICLOUD
        application.registerForRemoteNotifications() // iCloud tells the sync engine about changes this way
        #endif
        return true
    }

    /// The scene's delegate takes the Home Screen quick actions (QuickActions.swift).
    func application(_ application: UIApplication, configurationForConnecting connectingSceneSession: UISceneSession,
                     options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        let config = UISceneConfiguration(name: nil, sessionRole: connectingSceneSession.role)
        config.delegateClass = PhoneSceneDelegate.self
        return config
    }
}
