import AppIntents
import CoreSpotlight
import Foundation

// Presets and custom scenes in Spotlight: find one by name, and tapping it applies the preset or
// plays the scene. Tapping an item from an app always opens the app (the system's rule), so it
// opens as it was, without going to the scene's editor. The App Shortcuts (Apply Preset, Play
// Custom Scene) run from Spotlight without opening it.

extension PresetEntity: IndexedEntity {}

extension CustomSceneEntity: IndexedEntity {}

/// A custom scene from Spotlight (or Shortcuts' Open): plays it.
struct OpenCustomSceneIntent: OpenIntent {
    static let title: LocalizedStringResource = "Play Custom Scene"
    static let description = IntentDescription("Plays a custom scene on the bulb, switching it on.")
    static let isDiscoverable = false // Spotlight's; Shortcuts has the actions of these names

    @Parameter(title: "Custom Scene") var target: CustomSceneEntity

    init() {}

    @MainActor
    func perform() async throws -> some IntentResult {
        // Started by a person, so asked about first if it flashes (in the app, which this opens).
        let model = Shared.model
        // Judged once the light's been read: by a stale speed, one that flashes at the real one
        // would go unasked, and be refused.
        if let error = await Scripting.readyToJudge(model) { throw WizIntentError(localizedStringResource: "\(error.message)") }
        if let scene = model.library.customScene(target.id), model.flashes(scene), Flashing.asks {
            // Once confirmed, through the shared runner (it waits for a bulb the launch is still
            // connecting to, and the status says why if it doesn't go).
            let id = target.id.uuidString
            FlashingRequests.shared.ask(scene.name) {
                // As asked about: not if it's been edited or deleted meanwhile.
                guard model.library.customScene(target.id) == scene else {
                    model.status = "“\(scene.name)” was changed or deleted while being asked about; start it again"
                    return
                }
                Task { if let error = await Scripting.run(.customScene(id, power: true), confirmed: true, askedAbout: .customScene(scene), on: model).error { model.status = error.message } }
            }
            return .result()
        }
        _ = try await script(.customScene(target.id.uuidString, power: true))
        return .result()
    }
}

/// A preset from Spotlight (or Shortcuts' Open): applies it.
struct OpenPresetIntent: OpenIntent {
    static let title: LocalizedStringResource = "Apply Preset"
    static let description = IntentDescription("Sets the bulb to one of your setPilot presets, switching it on if it's off.")
    static let isDiscoverable = false // Spotlight's; Shortcuts has the actions of these names

    @Parameter(title: "Preset") var target: PresetEntity

    init() {}

    @MainActor
    func perform() async throws -> some IntentResult {
        let model = Shared.model
        // Started by a person in the app (which this opens): asked about if it flashes, and one
        // of a scene stored on the bulb plays as from the app's menus (scripting unconfirmed
        // never starts one). Judged once the light's been read, as for a custom scene.
        if let error = await Scripting.readyToJudge(model) { throw WizIntentError(localizedStringResource: "\(error.message)") }
        if let preset = model.library.presets.first(where: { $0.id == target.id }) {
            if model.asksFirst(preset) {
                model.applyAsking(preset)
                return .result()
            }
            // Not asked about: through the runner, which waits for a bulb the launch is still
            // connecting to. Confirmed, as from the menus, so a stored scene isn't refused; and
            // checked again before it goes, as it was here (not edited meanwhile, by a sync say).
            if preset.colour.isStoredScene {
                let result = await Scripting.run(.preset(preset.id.uuidString), confirmed: true,
                                                 askedAbout: .preset(preset, scene: model.library.customSceneOf(preset.colour)), on: model)
                if let error = result.error { throw WizIntentError(localizedStringResource: "\(error.message)") }
                return .result()
            }
        }
        _ = try await script(.preset(target.id.uuidString))
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
            // Kept as indexed until they're out of the index, so a failed removal is tried again.
            var stillIndexed: [UUID] = []
            if !gone.isEmpty {
                do {
                    try await index.deleteAppEntities(identifiedBy: gone, ofType: PresetEntity.self)
                    try await index.deleteAppEntities(identifiedBy: gone, ofType: CustomSceneEntity.self)
                } catch {
                    stillIndexed = gone
                }
            }
            try? await index.indexAppEntities(presets)
            try? await index.indexAppEntities(scenes)
            // Added to what's noted now, not replacing it: a newer run (this one cancelled
            // meanwhile, or not) may have noted its own, and what this one indexed must be noted
            // too, or a deleted item it added would stay in the index.
            let removed = Set(gone).subtracting(stillIndexed)
            let noted = Set((UserDefaults.standard.stringArray(forKey: indexedKey) ?? []).compactMap(UUID.init(uuidString:)))
            let indexed = noted.union(before).subtracting(removed).union(now)
            UserDefaults.standard.set(indexed.map(\.uuidString), forKey: indexedKey)
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
