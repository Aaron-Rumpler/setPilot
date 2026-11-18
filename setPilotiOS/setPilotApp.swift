import SwiftUI

/// The one connection to the bulb, shared by the app's screens, its App Intents and the watch.
@MainActor
enum Shared {
    static let model = Model()
}

@main
struct SetPilotMobileApp: App {
    @State private var model = Shared.model
    @Environment(\.scenePhase) private var phase

    init() {
        // Here rather than in a view: the watch can wake the app in the background, with no UI.
        PhoneRelay.shared.start(model: Shared.model)
        Shared.model.library.onChange = { PhoneRelay.shared.libraryChanged() }
        Shared.model.startIfSaved()
        // Siri learns the preset names from this (also refreshed whenever the presets change).
        SetPilotShortcuts.updateAppShortcutParameters()
    }

    var body: some Scene {
        WindowGroup {
            RootView(model: model)
        }
        .onChange(of: phase) { _, new in
            if new == .active { model.resume() }
        }
    }
}
