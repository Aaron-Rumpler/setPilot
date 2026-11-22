import AppIntents
import CoreSpotlight
import Foundation

// Presets and custom scenes in Spotlight: find one by name, and tapping it applies the preset or
// plays the scene (opening setPilot, on the scene's editor for a custom scene).

extension PresetEntity: IndexedEntity {}

extension CustomSceneEntity: IndexedEntity {}

/// A custom scene from Spotlight (or Shortcuts' Open): plays it, and opens its editor.
struct OpenCustomSceneIntent: OpenIntent {
    static let title: LocalizedStringResource = "Play Custom Scene and Open It"
    static let description = IntentDescription("Plays a custom scene on the bulb (switching it on) and opens its editor in setPilot.")

    @Parameter(title: "Custom Scene") var target: CustomSceneEntity

    init() {}

    @MainActor
    func perform() async throws -> some IntentResult {
        HandoffRouter.shared.open(.customScene(target.id))
        _ = try? await script(.customScene(target.id.uuidString, power: true))
        return .result()
    }
}

/// A preset from Spotlight (or Shortcuts' Open): applies it, and opens setPilot.
struct OpenPresetIntent: OpenIntent {
    static let title: LocalizedStringResource = "Apply Preset and Open setPilot"
    static let description = IntentDescription("Applies one of your presets and opens setPilot.")

    @Parameter(title: "Preset") var target: PresetEntity

    init() {}

    @MainActor
    func perform() async throws -> some IntentResult {
        HandoffRouter.shared.open(.controls)
        _ = try? await script(.preset(target.id.uuidString))
        return .result()
    }
}

@MainActor
enum SpotlightIndex {
    private static let indexedKey = "spotlightIndexed"
    private static var pending: Task<Void, Never>?

    /// Indexes the presets and custom scenes as they are now, and takes out ones since deleted.
    /// Waits for edits to pause (a rename types a letter at a time).
    static func update(_ library: Library) {
        pending?.cancel()
        pending = Task {
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            let presets = library.presets.map(PresetEntity.init)
            let scenes = library.customScenes.map { CustomSceneEntity(id: $0.id, name: $0.name) }
            let index = CSSearchableIndex.default()
            let before = Set((UserDefaults.standard.stringArray(forKey: indexedKey) ?? []).compactMap(UUID.init(uuidString:)))
            let now = Set(presets.map(\.id) + scenes.map(\.id))
            let gone = Array(before.subtracting(now))
            if !gone.isEmpty {
                try? await index.deleteAppEntities(identifiedBy: gone, ofType: PresetEntity.self)
                try? await index.deleteAppEntities(identifiedBy: gone, ofType: CustomSceneEntity.self)
            }
            try? await index.indexAppEntities(presets)
            try? await index.indexAppEntities(scenes)
            UserDefaults.standard.set(now.map(\.uuidString), forKey: indexedKey)
        }
    }
}

/// Tells Siri when presets are applied, so Siri Suggestions, the Lock Screen and the Smart Stack
/// can offer them at the times you use them.
@MainActor
enum SiriDonation {
    static func applied(_ preset: Preset) {
        let intent = ApplyPresetIntent(preset: PresetEntity(preset))
        Task { _ = try? await IntentDonationManager.shared.donate(intent: intent) }
    }
}
