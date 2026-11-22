import AppIntents

// Shortcuts actions on the watch itself: Siri on the watch, the Action button (Ultra), and the
// Smart Stack. Like everything on the watch they go through the iPhone, which talks to the bulb,
// and report what it says (not answering, refused) as an error.

struct WatchIntentError: Error, CustomLocalizedStringResourceConvertible {
    let localizedStringResource: LocalizedStringResource
}

/// Sends a command to the iPhone and waits for its answer.
@MainActor
private func relay(_ command: WatchCommand) async throws -> LightSnapshot {
    let link = PhoneLink.shared
    // Launched just for this (Siri, the Action button): the link to the iPhone is still coming up.
    let until = Date.now.addingTimeInterval(5)
    while !link.ready, Date.now < until { try? await Task.sleep(for: .milliseconds(100)) }
    let ok = await withCheckedContinuation { (done: CheckedContinuation<Bool, Never>) in
        MainActor.assumeIsolated { link.send(command) { done.resume(returning: $0) } } // called right away, here
    }
    guard ok, let snapshot = link.snapshot else {
        throw WatchIntentError(localizedStringResource: "\(link.error ?? "Your iPhone didn't answer.")")
    }
    return snapshot
}

@MainActor
private func summary(_ s: LightSnapshot) -> String {
    let name = s.bulbName ?? "The bulb"
    guard s.link == .connected else { return "\(name) isn't answering." }
    switch s.isOn {
    case false?: return "\(name) is off."
    case nil: return "\(name): its state isn't known yet."
    case true?:
        let colour = switch s.mode {
        case .temp: "\(Int(s.temp)) K"
        case .custom: "\(Int(s.customKelvin)) K"
        case .scene: s.customScene.flatMap { id in PhoneLink.shared.scenes.first { $0.id == id }?.name } ?? Scenes.name(s.sceneId)
        case .rgbcw: "a colour"
        }
        return "\(name) is on, \(colour), at \(Int(s.dimming))%."
    }
}

struct WatchPresetEntity: AppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Preset"
    static let defaultQuery = WatchPresetQuery()
    var id: UUID
    var name: String
    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(name)") }
}

struct WatchPresetQuery: EntityQuery {
    @MainActor
    func entities(for identifiers: [UUID]) async throws -> [WatchPresetEntity] {
        let all = try await suggestedEntities() // in the order asked
        return identifiers.compactMap { id in all.first { $0.id == id } }
    }

    @MainActor
    func suggestedEntities() async throws -> [WatchPresetEntity] {
        PhoneLink.shared.presets.map { WatchPresetEntity(id: $0.id, name: $0.name) }
    }
}

struct WatchApplyPresetIntent: AppIntent {
    static let title: LocalizedStringResource = "Apply Preset"
    static let description = IntentDescription("Sets the bulb to one of your setPilot presets, switching it on if it's off.")

    @Parameter(title: "Preset") var preset: WatchPresetEntity

    static var parameterSummary: some ParameterSummary { Summary("Apply \(\.$preset)") }

    init() {}

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        _ = try await relay(.applyPreset(preset.id))
        return .result(dialog: "Applied \(preset.name).")
    }
}

enum WatchPowerAction: String, AppEnum {
    case on, off, toggle

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Power"
    static let caseDisplayRepresentations: [WatchPowerAction: DisplayRepresentation] = [
        .on: "on", .off: "off", .toggle: "on or off",
    ]
}

struct WatchPowerIntent: AppIntent {
    static let title: LocalizedStringResource = "Switch the Bulb On or Off"
    static let description = IntentDescription("Switches the bulb on, off, or the other way to how it is.")

    @Parameter(title: "Power", default: .toggle) var action: WatchPowerAction

    static var parameterSummary: some ParameterSummary { Summary("Switch the bulb \(\.$action)") }

    init() {}

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let command: WatchCommand = switch action {
        case .on: .power(true)
        case .off: .power(false)
        case .toggle: .togglePower
        }
        let s = try await relay(command)
        return .result(dialog: "\(s.isOn == false ? "Switched off." : "Switched on.")")
    }
}

enum WatchBrightnessDirection: String, AppEnum {
    case brighter, dimmer

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Direction"
    static let caseDisplayRepresentations: [WatchBrightnessDirection: DisplayRepresentation] = [
        .brighter: "brighter", .dimmer: "dimmer",
    ]
}

struct WatchAdjustBrightnessIntent: AppIntent {
    static let title: LocalizedStringResource = "Make Brighter or Dimmer"
    static let description = IntentDescription("Changes the brightness by a step, relative to wherever it is now.")

    @Parameter(title: "Direction", default: .brighter) var direction: WatchBrightnessDirection
    @Parameter(title: "Step", default: 10, inclusiveRange: (1, 90)) var step: Int

    static var parameterSummary: some ParameterSummary { Summary("Make the bulb \(\.$direction) by \(\.$step)%") }

    init() {}

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let s = try await relay(.dimDelta(direction == .brighter ? step : -step))
        return .result(dialog: "Brightness \(Int(s.dimming))%.")
    }
}

struct WatchGetLightStateIntent: AppIntent {
    static let title: LocalizedStringResource = "Get Light State"
    static let description = IntentDescription("Whether the bulb is on, its colour or scene, and its brightness.")

    init() {}

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        let text = summary(try await relay(.state))
        return .result(value: text, dialog: "\(text)")
    }
}

struct WatchShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: WatchApplyPresetIntent(),
            phrases: ["Apply \(\.$preset) in \(.applicationName)", "Apply a preset in \(.applicationName)"],
            shortTitle: "Apply Preset",
            systemImageName: "square.grid.2x2"
        )
        AppShortcut(
            intent: WatchPowerIntent(),
            phrases: ["Switch the light \(\.$action) with \(.applicationName)", "Turn the light \(\.$action) with \(.applicationName)"],
            shortTitle: "Power",
            systemImageName: "lightbulb"
        )
        AppShortcut(
            intent: WatchAdjustBrightnessIntent(),
            phrases: ["Make the light \(\.$direction) with \(.applicationName)"],
            shortTitle: "Brighter or Dimmer",
            systemImageName: "sun.max"
        )
        AppShortcut(
            intent: WatchGetLightStateIntent(),
            phrases: ["What's the light doing in \(.applicationName)"],
            shortTitle: "Light State",
            systemImageName: "lightbulb.circle"
        )
    }
}
