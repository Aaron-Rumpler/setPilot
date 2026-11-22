import AppIntents

// Shortcuts actions beyond the basic ones in Intents.swift, all run through Scripting (the same as
// the URL scheme and the command-line tool), with the bulb's answer reported as an error.

@MainActor
func script(_ command: ScriptCommand, fade: Int? = nil) async throws -> LightState {
    let result = await Scripting.run(command, fade: fade, on: Shared.model)
    if let error = result.error { throw WizIntentError(localizedStringResource: "\(error.message)") }
    return result.state ?? Scripting.state(of: Shared.model)
}

// MARK: Entities

struct BulbEntity: AppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Bulb"
    static let defaultQuery = BulbQuery()
    /// The MAC, or the address of one that hasn't answered yet.
    var id: String
    var name: String
    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(name)") }

    init(_ bulb: KnownBulb) {
        id = bulb.mac ?? bulb.address
        name = bulb.name ?? bulb.address
    }
}

struct BulbQuery: EntityQuery {
    @MainActor
    func entities(for identifiers: [String]) async throws -> [BulbEntity] {
        Shared.model.namedBulbs.map(BulbEntity.init).filter { identifiers.contains($0.id) }
    }

    @MainActor
    func suggestedEntities() async throws -> [BulbEntity] { Shared.model.namedBulbs.map(BulbEntity.init) }
}

struct SceneEntity: AppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Scene"
    static let defaultQuery = SceneQuery()
    var id: Int
    var name: String
    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(name)") }

    /// The bulb's built-in scenes (not its stored slots, 256–265).
    static var all: [SceneEntity] {
        Scenes.all.filter { !(256...265).contains($0.id) }.map { SceneEntity(id: $0.id, name: $0.name) }
    }
}

struct SceneQuery: EntityQuery {
    func entities(for identifiers: [Int]) async throws -> [SceneEntity] {
        SceneEntity.all.filter { identifiers.contains($0.id) }
    }

    func suggestedEntities() async throws -> [SceneEntity] { SceneEntity.all }
}

struct CustomSceneEntity: AppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Custom Scene"
    static let defaultQuery = CustomSceneQuery()
    var id: UUID
    var name: String
    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(name)") }
}

struct CustomSceneQuery: EntityQuery {
    @MainActor
    func entities(for identifiers: [UUID]) async throws -> [CustomSceneEntity] {
        let all = try await suggestedEntities() // in the order asked
        return identifiers.compactMap { id in all.first { $0.id == id } }
    }

    @MainActor
    func suggestedEntities() async throws -> [CustomSceneEntity] {
        Shared.model.library.customScenes.map { CustomSceneEntity(id: $0.id, name: $0.name) }
    }
}

struct CCTScaleEntity: AppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "CCT Scale"
    static let defaultQuery = CCTScaleQuery()
    var id: UUID
    var name: String
    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(name)") }
}

struct CCTScaleQuery: EntityQuery {
    @MainActor
    func entities(for identifiers: [UUID]) async throws -> [CCTScaleEntity] {
        try await suggestedEntities().filter { identifiers.contains($0.id) }
    }

    /// The chosen bulb's scales (they're per bulb).
    @MainActor
    func suggestedEntities() async throws -> [CCTScaleEntity] {
        Shared.model.library.scales(for: Shared.model.chosenMAC).map { CCTScaleEntity(id: $0.id, name: $0.name) }
    }
}

/// The light's state, as Get Light State returns it: each part usable in later actions.
struct LightStateEntity: AppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Light State"
    static let defaultQuery = LightStateQuery()
    /// Each result its own (two Get Light States in one shortcut are different values).
    var id = UUID().uuidString

    @Property(title: "Bulb") var bulb: String
    @Property(title: "On") var on: Bool
    @Property(title: "Mode") var mode: String
    @Property(title: "Brightness") var brightness: Int
    @Property(title: "Kelvin") var kelvin: Int?
    @Property(title: "CCT Scale") var scale: String?
    @Property(title: "Scene") var scene: String?
    @Property(title: "Speed") var speed: Int?
    @Property(title: "JSON") var json: String

    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(summary)") }

    var summary: String {
        guard on else { return "\(bulb): off" }
        let colour = switch mode {
        case "temperature": "\(kelvin ?? 0) K" + (scale.map { " (\($0))" } ?? "")
        case "scene": scene ?? "a scene"
        default: "a colour"
        }
        return "\(bulb): on, \(colour), \(brightness)%"
    }

    init(_ s: LightState) {
        bulb = s.bulb.name ?? s.bulb.address ?? "Bulb"
        on = s.on ?? false
        mode = s.mode
        brightness = s.dimming
        kelvin = s.temp
        scale = s.scale
        scene = s.scene
        speed = s.speed
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        json = (try? encoder.encode(s)).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
    }
}

struct LightStateQuery: EntityQuery {
    func entities(for identifiers: [String]) async throws -> [LightStateEntity] { [] }
}

// MARK: Actions

struct GetLightStateIntent: AppIntent {
    static let title: LocalizedStringResource = "Get Light State"
    static let description = IntentDescription("The bulb's power, mode, colour or scene and brightness, read from the bulb.")

    init() {}

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<LightStateEntity> & ProvidesDialog & ShowsSnippetView {
        let raw = try await script(.get)
        let state = LightStateEntity(raw)
        return .result(value: state, dialog: "\(state.summary)", view: LightSnippet(state: raw))
    }
}

struct SetColourIntent: AppIntent {
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
        Summary("Set the colour to \(\.$r), \(\.$g), \(\.$b), \(\.$c), \(\.$w)") { \.$switchOn; \.$fade }
    }

    init() {}

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<LightStateEntity> {
        .result(value: LightStateEntity(try await script(.colour(r: r, g: g, b: b, c: c, w: w, power: switchOn ? true : nil), fade: fade)))
    }
}

struct SetTemperatureIntent: AppIntent {
    static let title: LocalizedStringResource = "Set Colour Temperature"
    static let description = IntentDescription("Sets the bulb to a colour temperature, on its own scale or one of your CCT scales.")

    @Parameter(title: "Kelvin", default: 2700, inclusiveRange: (1000, 20000)) var kelvin: Int
    @Parameter(title: "CCT Scale", description: "Empty: as Temperature was last used.") var scale: CCTScaleEntity?
    @Parameter(title: "Bulb's Own Scale", description: "Use the bulb's own temperatures, not a CCT scale.", default: false)
    var bulbOwn: Bool
    @Parameter(title: "Switch On", default: false) var switchOn: Bool

    @Parameter(title: "Fade (ms)", description: "This change's fade; empty for the controls' fade.") var fade: Int?

    static var parameterSummary: some ParameterSummary {
        Summary("Set the temperature to \(\.$kelvin) K") { \.$scale; \.$bulbOwn; \.$switchOn; \.$fade }
    }

    init() {}

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<LightStateEntity> {
        let scaleQuery = bulbOwn ? "bulb" : scale?.id.uuidString
        return .result(value: LightStateEntity(try await script(.temperature(kelvin, scale: scaleQuery, power: switchOn ? true : nil), fade: fade)))
    }
}

struct SetSceneIntent: AppIntent {
    static let title: LocalizedStringResource = "Set Scene"
    static let description = IntentDescription("Plays one of the bulb's built-in scenes.")

    @Parameter(title: "Scene") var scene: SceneEntity
    @Parameter(title: "Speed", description: "10–200; empty leaves it as it is.") var speed: Int?
    @Parameter(title: "Switch On", default: false) var switchOn: Bool

    @Parameter(title: "Fade (ms)", description: "This change's fade; empty for the controls' fade.") var fade: Int?

    static var parameterSummary: some ParameterSummary {
        Summary("Play \(\.$scene)") { \.$speed; \.$switchOn; \.$fade }
    }

    init() {}

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<LightStateEntity> {
        .result(value: LightStateEntity(try await script(.scene(String(scene.id), speed: speed, power: switchOn ? true : nil), fade: fade)))
    }
}

struct PlayCustomSceneIntent: AppIntent {
    static let title: LocalizedStringResource = "Play Custom Scene"
    static let description = IntentDescription("Plays one of your setPilot custom scenes.")

    @Parameter(title: "Custom Scene") var scene: CustomSceneEntity
    @Parameter(title: "Switch On", default: false) var switchOn: Bool

    @Parameter(title: "Fade (ms)", description: "This change's fade; empty for the controls' fade.") var fade: Int?

    static var parameterSummary: some ParameterSummary { Summary("Play \(\.$scene)") { \.$switchOn; \.$fade } }

    init() {}

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<LightStateEntity> {
        .result(value: LightStateEntity(try await script(.customScene(scene.id.uuidString, power: switchOn ? true : nil), fade: fade)))
    }
}

struct SwitchBulbIntent: AppIntent {
    static let title: LocalizedStringResource = "Switch Bulb"
    static let description = IntentDescription("Makes another of your bulbs the one setPilot controls.")

    @Parameter(title: "Bulb") var bulb: BulbEntity

    static var parameterSummary: some ParameterSummary { Summary("Switch to \(\.$bulb)") }

    init() {}

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<LightStateEntity> & ProvidesDialog {
        let state = LightStateEntity(try await script(.switchBulb(bulb.id)))
        return .result(value: state, dialog: "Now on \(state.bulb).")
    }
}

enum LightPower: String, AppEnum {
    case leave, on, off

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Power"
    static let caseDisplayRepresentations: [LightPower: DisplayRepresentation] = [
        .leave: "leave as it is", .on: "on", .off: "off",
    ]
}

enum LightColourKind: String, AppEnum {
    case leave, colour, temperature, scene, customScene

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Colour"
    static let caseDisplayRepresentations: [LightColourKind: DisplayRepresentation] = [
        .leave: "leave as it is", .colour: "a colour (RGBCW)", .temperature: "a colour temperature",
        .scene: "a scene", .customScene: "a custom scene",
    ]
}

/// Several things at once, in one setPilot, as Compose sends them.
struct SetLightIntent: AppIntent {
    static let title: LocalizedStringResource = "Set Light"
    static let description = IntentDescription("Changes any of the colour (or temperature, or scene), brightness and power at once, in one change, with an optional fade.")

    @Parameter(title: "Colour", default: .leave) var kind: LightColourKind
    @Parameter(title: "Red", default: 255, inclusiveRange: (0, 255)) var r: Int
    @Parameter(title: "Green", default: 0, inclusiveRange: (0, 255)) var g: Int
    @Parameter(title: "Blue", default: 0, inclusiveRange: (0, 255)) var b: Int
    @Parameter(title: "Cool White", default: 0, inclusiveRange: (0, 255)) var c: Int
    @Parameter(title: "Warm White", default: 0, inclusiveRange: (0, 255)) var w: Int
    @Parameter(title: "Kelvin", default: 2700, inclusiveRange: (1000, 20000)) var kelvin: Int
    @Parameter(title: "CCT Scale", description: "Empty: as Temperature was last used.") var scale: CCTScaleEntity?
    @Parameter(title: "Scene") var scene: SceneEntity?
    @Parameter(title: "Custom Scene") var customScene: CustomSceneEntity?
    @Parameter(title: "Speed", description: "10–200, for a scene; empty leaves it.") var speed: Int?
    @Parameter(title: "Brightness", description: "1–100; empty leaves it.") var brightness: Int?
    @Parameter(title: "Power", default: .leave) var power: LightPower
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
    func perform() async throws -> some IntentResult & ReturnsValue<LightStateEntity> {
        // The speed only with a scene (it isn't shown for the other kinds).
        var change = ScriptChange(speed: kind == .scene || kind == .customScene ? speed : nil, brightness: brightness,
                                  power: power == .on ? true : power == .off ? false : nil)
        switch kind {
        case .leave: break
        case .colour: change.rgbcw = [r, g, b, c, w]
        case .temperature:
            change.temp = kelvin
            change.scale = scale?.id.uuidString
        case .scene:
            guard let scene else { throw WizIntentError(localizedStringResource: "Choose a scene.") }
            change.scene = String(scene.id)
        case .customScene:
            guard let customScene else { throw WizIntentError(localizedStringResource: "Choose a custom scene.") }
            change.customScene = customScene.id.uuidString
        }
        return .result(value: LightStateEntity(try await script(.set(change), fade: fade)))
    }
}
