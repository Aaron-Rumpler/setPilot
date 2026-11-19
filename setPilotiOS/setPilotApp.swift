import SwiftUI

@main
struct SetPilotMobileApp: App {
    @State private var model = Shared.model
    @Environment(\.scenePhase) private var phase

    init() {
        // Here rather than in a view: the watch can wake the app in the background, with no UI.
        PhoneRelay.shared.start(model: Shared.model)
        Shared.model.library.onChange = { PhoneRelay.shared.libraryChanged() }
        Shared.model.startIfSaved()
        // Widgets and Control Center controls run their actions here, on the app's connection.
        WidgetPerformer.handler = { command in
            let model = Shared.model
            guard await model.waitUntilControllable(timeout: 5) else {
                throw WidgetError(localizedStringResource: "The bulb isn't answering.")
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
            await model.waitUntilSettled()
        }
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
