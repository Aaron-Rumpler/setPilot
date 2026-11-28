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

/// Why an action failed: the shared runner's reasons (Core/Commands.swift), or a missing choice.
struct WizIntentError: Error, CustomLocalizedStringResourceConvertible {
    let localizedStringResource: LocalizedStringResource
}

struct ApplyPresetIntent: AppIntent {
    static let title: LocalizedStringResource = "Apply Preset"
    static let description = IntentDescription("Sets the bulb to one of your setPilot presets, switching it on if it's off.")

    @Parameter(title: "Preset")
    var preset: PresetEntity
    @Parameter(title: "Fade (ms)", description: "This change's fade; empty for the controls' fade.") var fade: Int?

    static var parameterSummary: some ParameterSummary { Summary("Apply \(\.$preset)") { \.$fade } }

    init() {}
    init(preset: PresetEntity) { self.preset = preset }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        _ = try await script(.preset(preset.id.uuidString), fade: fade)
        return .result(dialog: "Applied \(preset.name).")
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
    @Parameter(title: "Fade (ms)", description: "This change's fade; empty for the controls' fade.") var fade: Int?

    static var parameterSummary: some ParameterSummary { Summary("Switch the bulb \(\.$action)") { \.$fade } }

    init() {}

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog & ShowsSnippetIntent {
        let on: Bool? = switch action {
        case .on: true
        case .off: false
        case .toggle: nil
        }
        let state = try await script(.power(on), fade: fade)
        return .result(dialog: state.on == false ? "Switched off." : state.on == true ? "Switched on." : "Done; the bulb's state isn't known yet.",
                       snippetIntent: LightSnippetIntent())
    }
}

struct SetBrightnessIntent: AppIntent {
    static let title: LocalizedStringResource = "Set Brightness"
    static let description = IntentDescription("Sets the bulb's brightness (1–100%, within the bulb's own minimum), leaving its colour as it is.")

    @Parameter(title: "Brightness", default: 100, inclusiveRange: (1, 100))
    var level: Int
    @Parameter(title: "Fade (ms)", description: "This change's fade; empty for the controls' fade.") var fade: Int?

    static var parameterSummary: some ParameterSummary { Summary("Set the brightness to \(\.$level)%") { \.$fade } }

    init() {}

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let state = try await script(.brightness(level), fade: fade)
        return .result(dialog: state.on == false
                       ? "Brightness \(state.dimming)%, for when the bulb's switched on (it's off)."
                       : "Brightness \(state.dimming)%.")
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
    @Parameter(title: "Fade (ms)", description: "This change's fade; empty for the controls' fade.") var fade: Int?

    static var parameterSummary: some ParameterSummary { Summary("Make the bulb \(\.$direction) by \(\.$step)%") { \.$fade } }

    init() {}

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog & ShowsSnippetIntent {
        let state = try await script(.adjustBrightness(direction == .brighter ? step : -step), fade: fade)
        return .result(dialog: state.on == false
                       ? "Brightness \(state.dimming)%, for when the bulb's switched on (it's off)."
                       : "Brightness \(state.dimming)%.", snippetIntent: LightSnippetIntent())
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
                "Switch it \(\.$action) with \(.applicationName)",
            ],
            shortTitle: "Power",
            systemImageName: "lightbulb"
        )
        AppShortcut(
            intent: GetLightStateIntent(),
            phrases: [
                "What's the light doing in \(.applicationName)",
                "Get the light state from \(.applicationName)",
            ],
            shortTitle: "Light State",
            systemImageName: "lightbulb.circle"
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
        AppShortcut(
            intent: PlayCustomSceneIntent(),
            phrases: [
                "Play \(\.$scene) in \(.applicationName)",
                "Play a custom scene in \(.applicationName)",
            ],
            shortTitle: "Play Custom Scene",
            systemImageName: "sparkles"
        )
    }
}

#if os(macOS)
// On iPhone, presets as Shortcuts parameters come from WidgetShared (shared with the widgets,
// which read them from the App Group). The Mac app doesn't build WidgetShared (only its widget
// extension does), so here they come from the app itself.

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
        let presets = Shared.model.library.presets // in the order asked
        return identifiers.compactMap { id in presets.first { $0.id == id } }.map(PresetEntity.init)
    }

    @MainActor
    func suggestedEntities() async throws -> [PresetEntity] {
        Shared.model.library.presets.map(PresetEntity.init)
    }
}
#endif
