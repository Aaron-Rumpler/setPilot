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
            // A preset deleted since the widget last updated: said as the widget would.
            if case .applyPreset(let id) = command, !Shared.model.library.presets.contains(where: { $0.id == id }) {
                throw WidgetError(localizedStringResource: "\(BulbReasons.presetGone)")
            }
            let script: ScriptCommand = switch command {
            case .applyPreset(let id): .preset(id.uuidString)
            case .power(let on): .power(on)
            case .dimDelta(let delta): .adjustBrightness(delta)
            }
            // A tap by a person, which can't be asked about first: the runner refuses a scene that
            // flashes (started in the app instead), judged once it knows the bulb's speed (an app
            // the tap woke hasn't read the light yet).
            let result = await Scripting.run(script, on: Shared.model)
            if let error = result.error { throw WidgetError(localizedStringResource: "\(error.message)") }
        }
        // Shortcuts' and Siri's presets, from the library itself (there may be no App Group).
        WidgetPerformer.library = { Shared.model.library.presets }
        // Siri learns the preset and custom scene names from this (also refreshed whenever the
        // library changes).
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
            // The widgets with when the bulb was last heard, once, before the app's suspended.
            // At .inactive, just before .background: still in the foreground, so the reload
            // doesn't count against their budget.
            if new == .inactive { WidgetPublisher.shared.enteringBackground() }
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
