import AppIntents
import Foundation
import WidgetKit

// Shared by the iPhone app and its widget extension (widgets and Control Center controls).
//
// The intents are LiveActivityIntents so the system runs them in the app's process, in the
// background, where the app's connection to the bulb lives (`WidgetPerformer.handler`, set at
// launch). If they ever run in the extension instead, they send the request themselves with
// what the app left in the App Group (`QuickBulb`).

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
    func entities(for identifiers: [UUID]) async throws -> [PresetEntity] {
        // In the order asked (a widget's chosen presets keep theirs).
        let presets = SharedStore.presets
        return identifiers.compactMap { id in presets.first { $0.id == id } }.map(PresetEntity.init)
    }

    func suggestedEntities() async throws -> [PresetEntity] {
        SharedStore.presets.map(PresetEntity.init)
    }
}

/// On iPhone the widgets' actions run in the app (a Live Activity intent), on its connection; the
/// Mac has no such thing, and runs them in the widget extension, which sends them itself.
#if os(iOS)
typealias WidgetActionIntent = LiveActivityIntent
#else
typealias WidgetActionIntent = AppIntent
#endif

enum WidgetCommand: Sendable {
    case applyPreset(UUID)
    case power(Bool?) // nil toggles
    case dimDelta(Int)
}

enum WidgetPerformer {
    /// Set by the app; nil in the extension.
    @MainActor static var handler: (@MainActor (WidgetCommand) async throws -> Void)?

    @MainActor
    static func perform(_ command: WidgetCommand) async throws {
        if let handler {
            try await handler(command)
        } else {
            try await QuickBulb.perform(command)
        }
        WidgetCenter.shared.reloadAllTimelines()
        ControlCenter.shared.reloadAllControls()
    }
}

struct WidgetError: Error, CustomLocalizedStringResourceConvertible {
    let localizedStringResource: LocalizedStringResource
}

struct ApplyPresetWidgetIntent: WidgetActionIntent {
    static let title: LocalizedStringResource = "Apply Preset"
    static let isDiscoverable = false

    @Parameter(title: "Preset")
    var preset: PresetEntity?

    init() {}
    init(preset: PresetEntity?) { self.preset = preset }

    @MainActor
    func perform() async throws -> some IntentResult {
        guard let preset else { throw WidgetError(localizedStringResource: "Choose a preset for this control.") }
        try await WidgetPerformer.perform(.applyPreset(preset.id))
        return .result()
    }
}

struct PowerToggleIntent: SetValueIntent, WidgetActionIntent {
    static let title: LocalizedStringResource = "Switch the Bulb On or Off"
    static let isDiscoverable = false

    @Parameter(title: "On")
    var value: Bool

    init() {}

    @MainActor
    func perform() async throws -> some IntentResult {
        try await WidgetPerformer.perform(.power(value))
        return .result()
    }
}

struct DimStepIntent: WidgetActionIntent {
    static let title: LocalizedStringResource = "Make Brighter or Dimmer"
    static let isDiscoverable = false

    @Parameter(title: "Step")
    var step: Int

    init() {}
    init(step: Int) { self.step = step }

    @MainActor
    func perform() async throws -> some IntentResult {
        try await WidgetPerformer.perform(.dimDelta(step))
        return .result()
    }
}

/// Configuration for the preset control in Control Center.
struct PresetControlConfiguration: ControlConfigurationIntent {
    static let title: LocalizedStringResource = "Preset"

    @Parameter(title: "Preset")
    var preset: PresetEntity?

    init() {}
}
