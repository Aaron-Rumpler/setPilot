import Foundation

/// What the watch shows: the bulb's state as the iPhone knows it.
struct LightSnapshot: Codable, Equatable, Sendable {
    enum Link: String, Codable, Sendable { case none, connecting, connected, unreachable }

    var link: Link = .none
    var bulbName: String?
    var isOn: Bool?
    var mode: Mode = .temp
    var r = 0.0
    var g = 0.0
    var b = 0.0
    var c = 0.0
    var w = 0.0
    var temp = 2700.0
    var customKelvin = 2700.0
    /// The bulb's custom CCT scale, if it has one, and its range.
    var cctScaleName: String?
    var customMin = 2200.0
    var customMax = 6500.0
    var sceneId = 0
    var speed = 100.0
    var dimming = 100.0
    var minDimming = 10.0
    var tempMin = 2200.0
    var tempMax = 6500.0
    /// The custom scene playing, if it's one of setPilot's.
    var customScene: UUID?
    var status = ""
    var pending = false
    /// What the bulb didn't apply from the last change ("Bulb didn't apply: …"), if anything.
    var mismatch: String?
    /// The bulbs the iPhone knows, and the address of the one in use.
    var bulbs: [KnownBulb]?
    var address: String?
    /// The bulb's custom CCT scales and the one in use.
    var scales: [ScaleSummary]?
    var activeScale: UUID?
    /// The fade time setting on the iPhone (ms), if set.
    var fade: Int?

    var canControl: Bool { link == .connected && isOn != nil }
}

/// The values a control sets; which of them are sent is given separately.
struct LightValues: Codable, Equatable, Sendable {
    var mode: Mode
    var r: Double
    var g: Double
    var b: Double
    var c: Double
    var w: Double
    var temp: Double
    var customKelvin: Double
    var sceneId: Int
    var speed: Double
    var dimming: Double
}

/// Requests from the watch to the iPhone, which does the talking to the bulb.
enum WatchCommand: Codable, Sendable {
    case state
    case sync
    case power(Bool)
    case applyPreset(UUID)
    case set(LightValues, fields: [PilotField])
    case dimDelta(Int)
    case playCustom(UUID)
    case savePreset(name: String)
    case compose(LightChange)
    case renamePreset(UUID, name: String)
    case updatePreset(UUID)
    case useScale(UUID)
    /// Switches between RGBCW, Temperature and Scenes (Temperature as last used).
    case modeChoice(ModeChoice)
    /// Temperature's scale: nil for the bulb's own.
    case temperatureScale(UUID?)
    case chooseBulb(address: String, mac: String?)
    case deletePreset(UUID)
}

/// The keys of WatchConnectivity messages and application contexts. Values are JSON `Data`.
enum WatchKey {
    static let command = "command"
    static let snapshot = "snapshot"
    static let presets = "presets"
    static let customScenes = "customScenes"
    static let error = "error"
}

/// A custom scene's name and swatch, which is all the watch needs.
struct CustomSceneSummary: Codable, Hashable, Identifiable, Sendable {
    var id: UUID
    var name: String
    var swatch: RGB?
}


/// A bulb the app has been used with.
struct KnownBulb: Codable, Hashable, Identifiable, Sendable {
    var address: String
    var mac: String?
    var name: String?
    var id: String { mac ?? address }
}

/// A custom CCT scale's name and range, for the watch.
struct ScaleSummary: Codable, Hashable, Identifiable, Sendable {
    var id: UUID
    var name: String
    var min: Double
    var max: Double
}
