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
        // Through the shared runner, as Shortcuts are: one at a time with them, waiting for the
        // bulb as everything does, and done only once read back as asked (or why not).
        WidgetPerformer.handler = { command in
            let script: ScriptCommand = switch command {
            case .applyPreset(let id): .preset(id.uuidString)
            case .power(let on): .power(on)
            case .dimDelta(let delta): .adjustBrightness(delta)
            }
            let result = await Scripting.run(script, on: Shared.model)
            if let error = result.error { throw WidgetError(localizedStringResource: "\(error.message)") }
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
