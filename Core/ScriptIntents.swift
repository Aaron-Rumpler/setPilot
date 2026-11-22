import AppIntents

// Shortcuts actions beyond the basic ones in Intents.swift, all run through Scripting (the same as
// the URL scheme and the command-line tool), with the bulb's answer reported as an error.

@MainActor
private func script(_ command: ScriptCommand) async throws -> LightState {
    let result = await Scripting.run(command, on: Shared.model)
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
        try await suggestedEntities().filter { identifiers.contains($0.id) }
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
    func perform() async throws -> some IntentResult & ReturnsValue<LightStateEntity> & ProvidesDialog {
        let state = LightStateEntity(try await script(.get))
        return .result(value: state, dialog: "\(state.summary)")
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

    static var parameterSummary: some ParameterSummary {
        Summary("Set the colour to \(\.$r), \(\.$g), \(\.$b), \(\.$c), \(\.$w)") { \.$switchOn }
    }

    init() {}

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<LightStateEntity> {
        .result(value: LightStateEntity(try await script(.colour(r: r, g: g, b: b, c: c, w: w, power: switchOn ? true : nil))))
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

    static var parameterSummary: some ParameterSummary {
        Summary("Set the temperature to \(\.$kelvin) K") { \.$scale; \.$bulbOwn; \.$switchOn }
    }

    init() {}

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<LightStateEntity> {
        let scaleQuery = bulbOwn ? "bulb" : scale?.id.uuidString
        return .result(value: LightStateEntity(try await script(.temperature(kelvin, scale: scaleQuery, power: switchOn ? true : nil))))
    }
}

struct SetSceneIntent: AppIntent {
    static let title: LocalizedStringResource = "Set Scene"
    static let description = IntentDescription("Plays one of the bulb's built-in scenes.")

    @Parameter(title: "Scene") var scene: SceneEntity
    @Parameter(title: "Speed", description: "10–200; empty leaves it as it is.") var speed: Int?
    @Parameter(title: "Switch On", default: false) var switchOn: Bool

    static var parameterSummary: some ParameterSummary {
        Summary("Play \(\.$scene)") { \.$speed; \.$switchOn }
    }

    init() {}

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<LightStateEntity> {
        .result(value: LightStateEntity(try await script(.scene(String(scene.id), speed: speed, power: switchOn ? true : nil))))
    }
}

struct PlayCustomSceneIntent: AppIntent {
    static let title: LocalizedStringResource = "Play Custom Scene"
    static let description = IntentDescription("Plays one of your setPilot custom scenes.")

    @Parameter(title: "Custom Scene") var scene: CustomSceneEntity
    @Parameter(title: "Switch On", default: false) var switchOn: Bool

    static var parameterSummary: some ParameterSummary { Summary("Play \(\.$scene)") { \.$switchOn } }

    init() {}

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<LightStateEntity> {
        .result(value: LightStateEntity(try await script(.customScene(scene.id.uuidString, power: switchOn ? true : nil))))
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
