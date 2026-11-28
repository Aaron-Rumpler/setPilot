import AppIntents
import WatchConnectivity

// Shortcuts actions on the watch itself: Siri on the watch, the Action button (Ultra), and the
// Smart Stack. The same actions as the iPhone's, sent to the iPhone, whose shared runner
// (Core/Commands.swift) carries them out as it does Shortcuts there: done once the bulb has read
// them back, and failing with the same reasons (not answering, refused, not applied).

struct WatchIntentError: Error, CustomLocalizedStringResourceConvertible {
    let localizedStringResource: LocalizedStringResource
}

/// Runs a scripting command on the iPhone and waits for its answer.
@MainActor
private func relay(_ command: ScriptCommand, fade: Int? = nil) async throws -> LightSnapshot {
    guard let data = try? JSONEncoder().encode(command) else {
        throw WatchIntentError(localizedStringResource: "Couldn't send that.")
    }
    let link = PhoneLink.shared
    // Launched just for this (Siri, the Action button): the session is still coming up, and the
    // iPhone may read as out of reach for a moment. Waited for as anything waits (BulbTiming),
    // counted from now, which goes with it: the iPhone counts its own waits from then too.
    let asked = Date.now
    let until = asked.addingTimeInterval(BulbTiming.answerTimeout)
    while !link.ready, Date.now < until { try await Task.sleep(for: .milliseconds(100)) } // throws once the action's cancelled
    guard link.ready else {
        throw WatchIntentError(localizedStringResource: "Can't reach your iPhone. Keep it nearby, with Bluetooth or Wi-Fi on.")
    }
    try Task.checkCancellation() // dismissed meanwhile: nothing goes
    // The reason taken with the answer (the shared error may be cleared by another send before
    // this resumes).
    let (ok, reason) = await withCheckedContinuation { (done: CheckedContinuation<(Bool, String?), Never>) in
        MainActor.assumeIsolated { link.send(.script(data, fade: fade), asked: asked) { done.resume(returning: ($0, link.error)) } } // called right away, here
    }
    guard ok, let snapshot = link.snapshot else {
        throw WatchIntentError(localizedStringResource: "\(reason ?? "Your iPhone didn't answer.")")
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

// MARK: Entities (from what the iPhone has sent)

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

struct WatchSceneEntity: AppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Scene"
    static let defaultQuery = WatchSceneQuery()
    var id: Int
    var name: String
    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(name)") }
}

struct WatchSceneQuery: EntityQuery {
    func entities(for identifiers: [Int]) async throws -> [WatchSceneEntity] {
        identifiers.compactMap { id in Scenes.all.first { $0.id == id }.map { WatchSceneEntity(id: $0.id, name: $0.name) } }
    }

    func suggestedEntities() async throws -> [WatchSceneEntity] {
        Scenes.all.map { WatchSceneEntity(id: $0.id, name: $0.name) }
    }
}

struct WatchCustomSceneEntity: AppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Custom Scene"
    static let defaultQuery = WatchCustomSceneQuery()
    var id: UUID
    var name: String
    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(name)") }
}

struct WatchCustomSceneQuery: EntityQuery {
    @MainActor
    func entities(for identifiers: [UUID]) async throws -> [WatchCustomSceneEntity] {
        let all = try await suggestedEntities()
        return identifiers.compactMap { id in all.first { $0.id == id } }
    }

    @MainActor
    func suggestedEntities() async throws -> [WatchCustomSceneEntity] {
        PhoneLink.shared.scenes.map { WatchCustomSceneEntity(id: $0.id, name: $0.name) }
    }
}

struct WatchScaleEntity: AppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "CCT Scale"
    static let defaultQuery = WatchScaleQuery()
    var id: UUID
    var name: String
    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(name)") }
}

struct WatchScaleQuery: EntityQuery {
    @MainActor
    func entities(for identifiers: [UUID]) async throws -> [WatchScaleEntity] {
        let all = try await suggestedEntities()
        return identifiers.compactMap { id in all.first { $0.id == id } }
    }

    @MainActor
    func suggestedEntities() async throws -> [WatchScaleEntity] {
        (PhoneLink.shared.snapshot?.scales ?? []).map { WatchScaleEntity(id: $0.id, name: $0.name) }
    }
}

struct WatchBulbEntity: AppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Bulb"
    static let defaultQuery = WatchBulbQuery()
    /// Its MAC, or its address if that isn't known.
    var id: String
    var name: String
    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(name)") }
}

struct WatchBulbQuery: EntityQuery {
    @MainActor
    func entities(for identifiers: [String]) async throws -> [WatchBulbEntity] {
        let all = try await suggestedEntities()
        return identifiers.compactMap { id in all.first { $0.id == id } }
    }

    @MainActor
    func suggestedEntities() async throws -> [WatchBulbEntity] {
        (PhoneLink.shared.snapshot?.bulbs ?? []).map { WatchBulbEntity(id: $0.id, name: $0.name ?? $0.address) }
    }
}

// MARK: Actions

struct WatchApplyPresetIntent: AppIntent {
    static let title: LocalizedStringResource = "Apply Preset"
    static let description = IntentDescription("Sets the bulb to one of your setPilot presets, switching it on if it's off.")

    @Parameter(title: "Preset") var preset: WatchPresetEntity
    @Parameter(title: "Fade (ms)", description: "This change's fade; empty for the controls' fade.") var fade: Int?

    static var parameterSummary: some ParameterSummary { Summary("Apply \(\.$preset)") { \.$fade } }

    init() {}

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        _ = try await relay(.preset(preset.id.uuidString), fade: fade)
        return .result(dialog: "Applied \(preset.name).")
    }
}

enum WatchPowerAction: String, AppEnum {
    case on, off, toggle

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Power"
    static let caseDisplayRepresentations: [WatchPowerAction: DisplayRepresentation] = [
        .on: "on", .off: "off", .toggle: "on or off",
    ]

    var bool: Bool? {
        switch self {
        case .on: true
        case .off: false
        case .toggle: nil
        }
    }
}

struct WatchPowerIntent: AppIntent {
    static let title: LocalizedStringResource = "Switch the Bulb On or Off"
    static let description = IntentDescription("Switches the bulb on, off, or the other way to how it is.")

    @Parameter(title: "Power", default: .toggle) var action: WatchPowerAction
    @Parameter(title: "Fade (ms)", description: "This change's fade; empty for the controls' fade.") var fade: Int?

    static var parameterSummary: some ParameterSummary { Summary("Switch the bulb \(\.$action)") { \.$fade } }

    init() {}

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let s = try await relay(.power(action.bool), fade: fade)
        return .result(dialog: "\(s.isOn == false ? "Switched off." : s.isOn == true ? "Switched on." : "Done; the bulb's state isn't known yet.")")
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
    @Parameter(title: "Fade (ms)", description: "This change's fade; empty for the controls' fade.") var fade: Int?

    static var parameterSummary: some ParameterSummary { Summary("Make the bulb \(\.$direction) by \(\.$step)%") { \.$fade } }

    init() {}

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let s = try await relay(.adjustBrightness(direction == .brighter ? step : -step), fade: fade)
        return .result(dialog: "Brightness \(Int(s.dimming))%.")
    }
}

struct WatchSetBrightnessIntent: AppIntent {
    static let title: LocalizedStringResource = "Set Brightness"
    static let description = IntentDescription("Sets the bulb's brightness (1–100%, within the bulb's own minimum), leaving its colour as it is.")

    @Parameter(title: "Brightness", default: 100, inclusiveRange: (1, 100)) var level: Int
    @Parameter(title: "Fade (ms)", description: "This change's fade; empty for the controls' fade.") var fade: Int?

    static var parameterSummary: some ParameterSummary { Summary("Set the brightness to \(\.$level)%") { \.$fade } }

    init() {}

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let s = try await relay(.brightness(level), fade: fade)
        return .result(dialog: "Brightness \(Int(s.dimming))%.")
    }
}

struct WatchSetColourIntent: AppIntent {
    static let title: LocalizedStringResource = "Set Colour"
    static let description = IntentDescription("Sets the bulb's red, green, blue, cool white and warm white channels (0–255).")

    @Parameter(title: "Red", default: 255, inclusiveRange: (0, 255)) var r: Int
    @Parameter(title: "Green", default: 0, inclusiveRange: (0, 255)) var g: Int
    @Parameter(title: "Blue", default: 0, inclusiveRange: (0, 255)) var b: Int
    @Parameter(title: "Cool White", default: 0, inclusiveRange: (0, 255)) var c: Int
    @Parameter(title: "Warm White", default: 0, inclusiveRange: (0, 255)) var w: Int
    @Parameter(title: "Switch On", description: "Off leaves the power as it is, as the controls do.", default: false)
    var switchOn: Bool
    @Parameter(title: "Fade (ms)", description: "This change's fade; empty for the controls' fade.") var fade: Int?

    static var parameterSummary: some ParameterSummary {
        Summary("Set the colour to \(\.$r), \(\.$g), \(\.$b)") { \.$c; \.$w; \.$switchOn; \.$fade }
    }

    init() {}

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        _ = try await relay(.colour(r: r, g: g, b: b, c: c, w: w, power: switchOn ? true : nil), fade: fade)
        return .result(dialog: "Colour set.")
    }
}

struct WatchSetTemperatureIntent: AppIntent {
    static let title: LocalizedStringResource = "Set Colour Temperature"
    static let description = IntentDescription("Sets the bulb to a colour temperature, on its own scale or one of your CCT scales.")

    @Parameter(title: "Temperature", default: 2700, inclusiveRange: (1000, 20000)) var kelvin: Int
    @Parameter(title: "CCT Scale", description: "Empty for the bulb's own.") var scale: WatchScaleEntity?
    @Parameter(title: "Switch On", description: "Off leaves the power as it is, as the controls do.", default: false)
    var switchOn: Bool
    @Parameter(title: "Fade (ms)", description: "This change's fade; empty for the controls' fade.") var fade: Int?

    static var parameterSummary: some ParameterSummary {
        Summary("Set the temperature to \(\.$kelvin) K") { \.$scale; \.$switchOn; \.$fade }
    }

    init() {}

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let s = try await relay(.temperature(kelvin, scale: scale?.id.uuidString ?? "bulb", power: switchOn ? true : nil), fade: fade)
        return .result(dialog: "\(Int(s.mode == .custom ? s.customKelvin : s.temp)) K.")
    }
}

struct WatchSetSceneIntent: AppIntent {
    static let title: LocalizedStringResource = "Set Scene"
    static let description = IntentDescription("Plays one of the bulb's built-in scenes.")

    @Parameter(title: "Scene") var scene: WatchSceneEntity
    @Parameter(title: "Speed", inclusiveRange: (10, 200)) var speed: Int?
    @Parameter(title: "Switch On", description: "Off leaves the power as it is, as the controls do.", default: false)
    var switchOn: Bool
    @Parameter(title: "Fade (ms)", description: "This change's fade; empty for the controls' fade.") var fade: Int?

    static var parameterSummary: some ParameterSummary { Summary("Play \(\.$scene)") { \.$speed; \.$switchOn; \.$fade } }

    init() {}

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        _ = try await relay(.scene(String(scene.id), speed: speed, power: switchOn ? true : nil), fade: fade)
        return .result(dialog: "Playing \(scene.name).")
    }
}

struct WatchPlayCustomSceneIntent: AppIntent {
    static let title: LocalizedStringResource = "Play Custom Scene"
    static let description = IntentDescription("Plays one of your setPilot custom scenes.")

    @Parameter(title: "Custom Scene") var scene: WatchCustomSceneEntity
    @Parameter(title: "Switch On", description: "Off leaves the power as it is, as the controls do.", default: false)
    var switchOn: Bool
    @Parameter(title: "Fade (ms)", description: "This change's fade; empty for the controls' fade.") var fade: Int?

    static var parameterSummary: some ParameterSummary { Summary("Play \(\.$scene)") { \.$switchOn; \.$fade } }

    init() {}

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        _ = try await relay(.customScene(scene.id.uuidString, power: switchOn ? true : nil), fade: fade)
        return .result(dialog: "Playing \(scene.name).")
    }
}

enum WatchLightPower: String, AppEnum {
    case leave, on, off

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Power"
    static let caseDisplayRepresentations: [WatchLightPower: DisplayRepresentation] = [
        .leave: "leave as it is", .on: "on", .off: "off",
    ]
}

enum WatchLightColourKind: String, AppEnum {
    case leave, colour, temperature, scene, customScene

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Colour"
    static let caseDisplayRepresentations: [WatchLightColourKind: DisplayRepresentation] = [
        .leave: "leave as it is", .colour: "a colour (RGBCW)", .temperature: "a colour temperature",
        .scene: "a scene", .customScene: "a custom scene",
    ]
}

/// As the iPhone's Set Light: any of a colour (or temperature, or scene), the brightness and the
/// power, in one change.
struct WatchSetLightIntent: AppIntent {
    static let title: LocalizedStringResource = "Set Light"
    static let description = IntentDescription("Changes any of the colour (or temperature, or scene), brightness and power at once, in one change, with an optional fade.")

    @Parameter(title: "Colour", default: .leave) var kind: WatchLightColourKind
    @Parameter(title: "Red", default: 255, inclusiveRange: (0, 255)) var r: Int
    @Parameter(title: "Green", default: 0, inclusiveRange: (0, 255)) var g: Int
    @Parameter(title: "Blue", default: 0, inclusiveRange: (0, 255)) var b: Int
    @Parameter(title: "Cool White", default: 0, inclusiveRange: (0, 255)) var c: Int
    @Parameter(title: "Warm White", default: 0, inclusiveRange: (0, 255)) var w: Int
    @Parameter(title: "Temperature", default: 2700, inclusiveRange: (1000, 20000)) var kelvin: Int
    @Parameter(title: "CCT Scale", description: "Empty: as Temperature was last used.") var scale: WatchScaleEntity?
    @Parameter(title: "Scene") var scene: WatchSceneEntity?
    @Parameter(title: "Custom Scene") var customScene: WatchCustomSceneEntity?
    @Parameter(title: "Speed", description: "10–200, for a scene; empty leaves it.") var speed: Int?
    @Parameter(title: "Brightness", description: "1–100; empty leaves it.") var brightness: Int?
    @Parameter(title: "Power", default: .leave) var power: WatchLightPower
    @Parameter(title: "Fade (ms)", description: "This change's fade; empty for the controls' fade.") var fade: Int?

    static var parameterSummary: some ParameterSummary {
        Switch(\.$kind) {
            Case(.colour) {
                Summary("Set the light to \(\.$r), \(\.$g), \(\.$b), \(\.$c), \(\.$w)") { \.$brightness; \.$power; \.$fade }
            }
            Case(.temperature) {
                Summary("Set the light to \(\.$kelvin) K") { \.$scale; \.$brightness; \.$power; \.$fade }
            }
            Case(.scene) {
                Summary("Set the light to \(\.$scene)") { \.$speed; \.$brightness; \.$power; \.$fade }
            }
            Case(.customScene) {
                Summary("Set the light to \(\.$customScene)") { \.$speed; \.$brightness; \.$power; \.$fade }
            }
            DefaultCase {
                Summary("Set the light: \(\.$kind)") { \.$brightness; \.$power; \.$fade }
            }
        }
    }

    init() {}

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        var change = ScriptChange(speed: kind == .scene || kind == .customScene ? speed : nil, brightness: brightness,
                                  power: power == .leave ? nil : power == .on)
        switch kind {
        case .leave: break
        case .colour: change.rgbcw = [r, g, b, c, w]
        case .temperature:
            change.temp = kelvin
            change.scale = scale?.id.uuidString
        case .scene:
            guard let scene else { throw WatchIntentError(localizedStringResource: "Choose a scene.") }
            change.scene = String(scene.id)
        case .customScene:
            guard let customScene else { throw WatchIntentError(localizedStringResource: "Choose a custom scene.") }
            change.customScene = customScene.id.uuidString
        }
        let s = try await relay(.set(change), fade: fade)
        return .result(dialog: "\(summary(s))")
    }
}

struct WatchSwitchBulbIntent: AppIntent {
    static let title: LocalizedStringResource = "Switch Bulb"
    static let description = IntentDescription("Makes another of your bulbs the one setPilot controls.")

    @Parameter(title: "Bulb") var bulb: WatchBulbEntity

    static var parameterSummary: some ParameterSummary { Summary("Switch to \(\.$bulb)") }

    init() {}

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        _ = try await relay(.switchBulb(bulb.id))
        return .result(dialog: "Switched to \(bulb.name).")
    }
}

struct WatchGetLightStateIntent: AppIntent {
    static let title: LocalizedStringResource = "Get Light State"
    static let description = IntentDescription("The bulb's power, colour or scene and brightness, read from the bulb.")

    init() {}

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        let text = summary(try await relay(.get))
        return .result(value: text, dialog: "\(text)")
    }
}

struct WatchShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: WatchApplyPresetIntent(),
            phrases: ["Apply \(\.$preset) in \(.applicationName)", "Set the light to \(\.$preset) with \(.applicationName)", "Apply a preset in \(.applicationName)"],
            shortTitle: "Apply Preset",
            systemImageName: "square.grid.2x2"
        )
        AppShortcut(
            intent: WatchPowerIntent(),
            phrases: ["Switch the light \(\.$action) with \(.applicationName)", "Switch it \(\.$action) with \(.applicationName)"],
            shortTitle: "Power",
            systemImageName: "lightbulb"
        )
        AppShortcut(
            intent: WatchAdjustBrightnessIntent(),
            phrases: ["Make the light \(\.$direction) with \(.applicationName)", "Make it \(\.$direction) with \(.applicationName)"],
            shortTitle: "Brighter or Dimmer",
            systemImageName: "sun.max"
        )
        AppShortcut(
            intent: WatchPlayCustomSceneIntent(),
            phrases: ["Play \(\.$scene) in \(.applicationName)"],
            shortTitle: "Play Custom Scene",
            systemImageName: "sparkles"
        )
        AppShortcut(
            intent: WatchGetLightStateIntent(),
            phrases: ["What's the light doing in \(.applicationName)", "Get the light state from \(.applicationName)"],
            shortTitle: "Light State",
            systemImageName: "lightbulb.circle"
        )
    }
}
