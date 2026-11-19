import AppIntents

// Actions for Shortcuts and Siri: on iPhone also the Action button, and Control Center or the Lock
// Screen (through a Shortcuts control); on the Mac also Spotlight and keyboard shortcuts set in
// Shortcuts. They run in the app's own process, so they use the same connection to the bulb as
// the app.

/// The one connection to the bulb, shared by the app's windows or screens, its App Intents and
/// (on iPhone) the watch.
@MainActor
enum Shared {
    static let model = Model()
}

struct WizIntentError: Error, CustomLocalizedStringResourceConvertible {
    let localizedStringResource: LocalizedStringResource

    #if os(iOS)
    static let unreachable = WizIntentError(localizedStringResource: "The bulb isn't answering. Check it's powered and on the same network as your iPhone.")
    #else
    static let unreachable = WizIntentError(localizedStringResource: "The bulb isn't answering. Check it's powered and on the same network as your Mac.")
    #endif
    static let noBulb = WizIntentError(localizedStringResource: "Choose a bulb in setPilot first.")
}

@MainActor
private func controllableModel() async throws -> Model {
    let model = Shared.model
    guard let a = UserDefaults.standard.string(forKey: Model.addressKey), !a.isEmpty else { throw WizIntentError.noBulb }
    guard await model.waitUntilControllable(timeout: 5) else { throw WizIntentError.unreachable }
    return model
}

struct ApplyPresetIntent: AppIntent {
    static let title: LocalizedStringResource = "Apply Preset"
    static let description = IntentDescription("Sets the bulb to one of your setPilot presets, switching it on if it's off.")

    @Parameter(title: "Preset")
    var preset: PresetEntity

    static var parameterSummary: some ParameterSummary { Summary("Apply \(\.$preset)") }

    init() {}
    init(preset: PresetEntity) { self.preset = preset }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let model = try await controllableModel()
        guard let p = model.library.presets.first(where: { $0.id == preset.id }) else {
            throw WizIntentError(localizedStringResource: "That preset no longer exists.")
        }
        model.apply(p)
        await model.waitUntilSettled()
        return .result(dialog: "Applied \(p.name).")
    }
}

enum PowerAction: String, AppEnum {
    case on, off, toggle

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Power"
    static let caseDisplayRepresentations: [PowerAction: DisplayRepresentation] = [
        .on: "on", .off: "off", .toggle: "on or off",
    ]
}

struct PowerIntent: AppIntent {
    static let title: LocalizedStringResource = "Switch the Bulb On or Off"
    static let description = IntentDescription("Switches the bulb on, off, or the other way to how it is.")

    @Parameter(title: "Power", default: .toggle)
    var action: PowerAction

    static var parameterSummary: some ParameterSummary { Summary("Switch the bulb \(\.$action)") }

    init() {}

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let model = try await controllableModel()
        let on = switch action {
        case .on: true
        case .off: false
        case .toggle: !(model.isOn ?? false)
        }
        model.power(on)
        try? await Task.sleep(for: .milliseconds(400))
        return .result(dialog: on ? "Switched on." : "Switched off.")
    }
}

struct SetBrightnessIntent: AppIntent {
    static let title: LocalizedStringResource = "Set Brightness"
    static let description = IntentDescription("Sets the bulb's brightness (10–100%), leaving its colour as it is.")

    @Parameter(title: "Brightness", default: 100, inclusiveRange: (10, 100))
    var level: Int

    static var parameterSummary: some ParameterSummary { Summary("Set the brightness to \(\.$level)%") }

    init() {}

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let model = try await controllableModel()
        model.setDimming(Double(level))
        await model.waitUntilSettled()
        return .result(dialog: "Brightness \(Int(model.dimming))%.")
    }
}

enum BrightnessDirection: String, AppEnum {
    case brighter, dimmer

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Direction"
    static let caseDisplayRepresentations: [BrightnessDirection: DisplayRepresentation] = [
        .brighter: "brighter", .dimmer: "dimmer",
    ]
}

struct AdjustBrightnessIntent: AppIntent {
    static let title: LocalizedStringResource = "Make Brighter or Dimmer"
    static let description = IntentDescription("Changes the brightness by a step, relative to wherever it is now.")

    @Parameter(title: "Direction", default: .brighter)
    var direction: BrightnessDirection

    @Parameter(title: "Step", default: 10, inclusiveRange: (1, 90))
    var step: Int

    static var parameterSummary: some ParameterSummary { Summary("Make the bulb \(\.$direction) by \(\.$step)%") }

    init() {}

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let model = try await controllableModel()
        model.adjustDimming(by: direction == .brighter ? step : -step)
        await model.waitUntilSettled()
        return .result(dialog: "Brightness \(Int(model.dimming))%.")
    }
}

struct SetPilotShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: ApplyPresetIntent(),
            phrases: [
                "Apply \(\.$preset) in \(.applicationName)",
                "Set the light to \(\.$preset) with \(.applicationName)",
                "Apply a preset in \(.applicationName)",
            ],
            shortTitle: "Apply Preset",
            systemImageName: "square.grid.2x2"
        )
        AppShortcut(
            intent: PowerIntent(),
            phrases: [
                "Switch the light \(\.$action) with \(.applicationName)",
                "Turn the light \(\.$action) with \(.applicationName)",
            ],
            shortTitle: "Power",
            systemImageName: "lightbulb"
        )
        AppShortcut(
            intent: AdjustBrightnessIntent(),
            phrases: [
                "Make the light \(\.$direction) with \(.applicationName)",
                "Make it \(\.$direction) with \(.applicationName)",
            ],
            shortTitle: "Brighter or Dimmer",
            systemImageName: "sun.max"
        )
    }
}

#if os(macOS)
// On iPhone, presets as Shortcuts parameters come from WidgetShared (shared with the widgets,
// which read them from the App Group). The Mac has no widgets: they come from the app itself.

struct PresetEntity: AppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Preset"
    static let defaultQuery = PresetQuery()

    var id: UUID
    var name: String

    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(name)") }

    init(_ preset: Preset) {
        id = preset.id
        name = preset.name
    }
}

struct PresetQuery: EntityQuery {
    @MainActor
    func entities(for identifiers: [UUID]) async throws -> [PresetEntity] {
        Shared.model.library.presets.filter { identifiers.contains($0.id) }.map(PresetEntity.init)
    }

    @MainActor
    func suggestedEntities() async throws -> [PresetEntity] {
        Shared.model.library.presets.map(PresetEntity.init)
    }
}
#endif
