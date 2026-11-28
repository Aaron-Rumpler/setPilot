import Foundation

/// What the watch shows: the bulb's state as the iPhone knows it.
struct LightSnapshot: Codable, Equatable, Sendable {
    enum Link: String, Codable, Sendable { case none, connecting, connected, unreachable }

    var link: Link = .none
    /// When the iPhone sent it (its clock), so the watch can tell which of a message, a reply and
    /// the application context is newest: they can arrive in any order.
    var sentAt: Date?
    /// When the app last heard from the bulb (a reply or a push), while it's answering. Widgets
    /// and complications show the state as only the last known once that's `trustedFor` ago: the
    /// app may have been suspended or quit since, and nothing rewrites it then.
    var heardAt: Date?
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
    /// The range of the CCT scale Temperature uses, if any.
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
    /// A scene speed changed while the bulb was off, sent with the next change that leaves it on.
    var owedSpeed: Int?
    /// Sliders snap to round numbers (the iPhone's setting; the watch's Crown follows it).
    var snapSliders: Bool?
    /// The live controls' fade: the fade time setting, none, or `controlsFadeMs`.
    var controlsFade: FadeChoice?
    var controlsFadeMs: Int?
    /// Live updates: registered, and whether a push has arrived yet.
    var live: Bool?
    var pushSeen: Bool?
    var mac: String?
    var module: String?
    var firmware: String?
    /// The last request: its method and params, as sent.
    var lastMethod: String?
    var lastSent: String?

    var canControl: Bool { link == .connected && isOn != nil }

    /// How long a state is shown as the bulb's own after it was last heard. The Mac app keeps
    /// running, and marks the state not known as it quits or the Mac sleeps, so its widgets need
    /// re-stamping less often (they have a reload budget). Not for longer, though: a crash or a
    /// Force Quit skips that marking.
    #if os(macOS)
    static let trustedFor: TimeInterval = 2 * 60 * 60
    #else
    static let trustedFor: TimeInterval = 15 * 60
    #endif

    /// When it becomes only the last known state, if it's one that does.
    var staleAt: Date? { heardAt.map { $0.addingTimeInterval(Self.trustedFor) } }

    func isStale(at date: Date) -> Bool { staleAt.map { date >= $0 } ?? false }

    var values: LightValues {
        LightValues(mode: mode, r: r, g: g, b: b, c: c, w: w, temp: temp, customKelvin: customKelvin,
                    sceneId: sceneId, speed: speed, dimming: dimming)
    }
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
    /// Switches the bulb the other way from how it is on the iPhone (the watch's copy may be old:
    /// a complication tap that launched the app).
    case togglePower
    case applyPreset(UUID)
    case set(LightValues, fields: [PilotField])
    case dimDelta(Int)
    /// Plays a custom scene: switching the bulb on (the Custom Scenes list, like a preset) or
    /// leaving the power as it is (the Controls' scene picker, like a built-in scene there).
    case playCustom(UUID, switchOn: Bool)
    case savePreset(name: String)
    case compose(LightChange)
    case renamePreset(UUID, name: String)
    case updatePreset(UUID)
    /// Switches between RGBCW, Temperature and Scenes (Temperature as last used).
    case modeChoice(ModeChoice)
    /// Temperature's scale: nil for the bulb's own.
    case temperatureScale(UUID?)
    case chooseBulb(address: String, mac: String?)
    case deletePreset(UUID)
    /// Moves a preset up (-1) or down (1).
    case movePreset(UUID, by: Int)
    /// Stars a preset, or not.
    case favourite(UUID, Bool)
    case controlsFade(FadeChoice, ms: Int)
    case renameBulb(mac: String, name: String)
    /// Reads the device info; the reply carries it.
    case deviceInfo
    /// A scripting command (Scripting/ScriptProtocol.swift's ScriptCommand, as JSON), run by the
    /// iPhone's shared runner, as Shortcuts and links are: done once the bulb has read it back.
    /// The watch's Shortcuts actions send these.
    case script(Data, fade: Int?)
}

/// One read for the watch's device info: the bulb's reply as text, or its error.
struct DeviceInfoEntry: Codable, Hashable, Identifiable, Sendable {
    var method: String
    var text: String
    var error: String?
    var id: String { method }
}

/// The keys of WatchConnectivity messages and application contexts. Values are JSON `Data`.
enum WatchKey {
    static let command = "command"
    static let snapshot = "snapshot"
    static let presets = "presets"
    static let customScenes = "customScenes"
    static let error = "error"
    static let deviceInfo = "deviceInfo"
    /// A failed command's kind (ScriptError.Code's raw value), with `error`.
    static let errorCode = "errorCode"
    /// When presets were applied on the iPhone (PresetUsage).
    static let presetUsage = "presetUsage"
    /// When the watch sent a command (seconds since 1970): a change that reaches the bulb later
    /// than anything waits for it (BulbTiming.answerTimeout) isn't sent.
    static let sentAt = "sentAt"
    /// In the context, true while the iPhone's presets are a newer build's it can't read
    /// (Library.newerNote): the watch saves and edits none, as the iPhone refuses them.
    static let presetsLocked = "presetsLocked"
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
