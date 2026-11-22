import AppIntents
import CoreSpotlight
import Foundation

// Presets and custom scenes in Spotlight (iOS 18 and macOS 15 on): find one by name. A preset
// opens setPilot; a custom scene opens its editor.

@available(iOS 18, macOS 15, *)
extension PresetEntity: IndexedEntity {}

@available(iOS 18, macOS 15, *)
extension CustomSceneEntity: IndexedEntity {}

/// Opening a custom scene from Spotlight (or Shortcuts' Open): its editor.
struct OpenCustomSceneIntent: OpenIntent {
    static let title: LocalizedStringResource = "Open Custom Scene"
    static let description = IntentDescription("Opens a custom scene's editor in setPilot.")

    @Parameter(title: "Custom Scene") var target: CustomSceneEntity

    init() {}

    @MainActor
    func perform() async throws -> some IntentResult {
        HandoffRouter.shared.open(.customScene(target.id))
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
        guard #available(iOS 18, macOS 15, *) else { return }
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
