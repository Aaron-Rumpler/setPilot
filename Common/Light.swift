import Foundation

/// The bulb's three ways of setting colour, as the controls show them.
enum Mode: String, CaseIterable, Identifiable, Codable, Sendable {
    case rgbcw = "RGBCW", temp = "Temperature", scene = "Scene"
    var id: Self { self }
}

/// What a setPilot can change, as the controls see it.
enum PilotField: String, Codable, Sendable { case colour, dimming, speed }

struct WizScene: Identifiable, Sendable {
    let id: Int
    let name: String
}

enum Scenes {
    static let all: [WizScene] = {
        var s: [Int: String] = [
            1: "Ocean", 2: "Romance", 3: "Sunset", 4: "Party", 5: "Fireplace", 6: "Cozy",
            7: "Forest", 8: "Pastel colors", 9: "Wake-up", 10: "Bedtime", 11: "Warm white",
            12: "Daylight", 13: "Cool white", 14: "Night light", 15: "Focus", 16: "Relax",
            17: "True colors", 18: "TV time", 19: "Plantgrowth", 20: "Spring", 21: "Summer",
            22: "Fall", 23: "Deep dive", 24: "Jungle", 25: "Mojito", 26: "Club",
            27: "Christmas", 28: "Halloween", 29: "Candlelight", 30: "Golden white",
            31: "Pulse", 32: "Steampunk", 33: "Diwali", 34: "White", 35: "Alarm",
            36: "Snowy sky", 40: "Dim-to-warm",
        ]
        for i in 1...10 { s[255 + i] = "Custom Mode \(i)" }
        return s.map { WizScene(id: $0.key, name: $0.value) }.sorted { $0.id < $1.id }
    }()

    static func isKnown(_ id: Int) -> Bool { all.contains { $0.id == id } }

    /// What the bulb may report that isn't a scene you can set: pywizlight's 1000 for Rhythm
    /// (schdPsetId), or an ID newer than this list.
    static func name(_ id: Int) -> String {
        if id == inlineCustom { return "Custom scene" }
        return all.first { $0.id == id }?.name ?? (id == rhythm ? "Rhythm" : "Scene \(id)")
    }

    static let rhythm = 1000

    /// The scene ID setPilot's own custom scenes play as. They're sent inline with `setPilot`
    /// (`sceneId` + `elm`), which uses the bulb's scratch slot, so nothing stored on the bulb is
    /// touched. It has to be above 255 and not one of the stored customs (256–265), which would
    /// win over the inline definition.
    static let inlineCustom = 300

    /// The first keyframe of each baked scene (decoded from firmware 1.38.0), for swatches.
    static func swatch(_ id: Int) -> RGB? {
        if let k = sceneKelvin[id] { return ColourTemperature.rgb(kelvin: k) }
        guard let c = sceneColour[id] else { return nil }
        return LightColour.rgbcw(r: c[0], g: c[1], b: c[2], c: c[4], w: c[3]).swatch
    }

    private static let sceneKelvin: [Int: Double] = [11: 2700, 12: 4200, 13: 6500, 34: 4200, 40: 4200]
    /// R, G, B, warm, cool.
    private static let sceneColour: [Int: [Int]] = [
        1: [8, 255, 107, 0, 0], 2: [255, 20, 60, 0, 0], 3: [200, 0, 0, 20, 0], 4: [255, 0, 0, 0, 0],
        5: [255, 135, 0, 1, 0], 6: [255, 0, 0, 200, 0], 7: [0, 100, 0, 100, 0], 8: [255, 0, 0, 80, 0],
        9: [30, 0, 0, 0, 5], 10: [255, 60, 0, 125, 0], 14: [2, 0, 0, 5, 0], 15: [230, 230, 0, 0, 240],
        16: [90, 0, 90, 150, 0], 17: [255, 64, 0, 255, 0], 18: [0, 0, 55, 5, 0], 19: [255, 0, 255, 120, 0],
        20: [255, 202, 253, 0, 0], 21: [255, 215, 0, 120, 0], 22: [255, 15, 0, 60, 0], 23: [8, 3, 255, 0, 0],
        24: [50, 255, 0, 0, 0], 25: [0, 255, 0, 0, 100], 26: [255, 80, 0, 5, 0], 27: [0, 205, 0, 0, 0],
        28: [255, 200, 0, 8, 0], 29: [155, 60, 0, 42, 0], 30: [0, 0, 0, 255, 0], 31: [0, 0, 0, 255, 0],
        32: [80, 0, 0, 165, 0], 33: [255, 90, 0, 120, 0], 35: [0, 0, 0, 255, 255], 36: [0, 190, 225, 0, 130],
    ]
}

/// A colour as the bulb takes it: raw channels, a colour temperature, a baked scene, or one of
/// setPilot's custom scenes.
enum LightColour: Codable, Hashable, Sendable {
    case rgbcw(r: Int, g: Int, b: Int, c: Int, w: Int)
    case temp(Int)
    case scene(id: Int, speed: Int?)
    case custom(UUID, speed: Int?)

    var isScene: Bool {
        switch self {
        case .scene, .custom: true
        default: false
        }
    }

    /// A rough idea of the colour, for swatches: the LEDs as sRGB primaries plus the whites'
    /// colour temperatures, with red, green and blue boosted ×4 when a white is lit, as the
    /// firmware does. Not a measurement.
    var swatch: RGB? {
        switch self {
        case let .rgbcw(r, g, b, c, w):
            func lin(_ v: Double) -> Double { v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
            let boost = c + w > 0 ? 4.0 : 1.0
            let cool = ColourTemperature.rgb(kelvin: 6500), warm = ColourTemperature.rgb(kelvin: 2700)
            let cw = Double(c), ww = Double(w)
            var mix = [Double(r) * boost, Double(g) * boost, Double(b) * boost]
            for (i, k) in [\RGB.r, \RGB.g, \RGB.b].enumerated() {
                mix[i] += cw * lin(cool[keyPath: k]) + ww * lin(warm[keyPath: k])
            }
            guard let peak = mix.max(), peak > 0 else { return nil }
            func enc(_ v: Double) -> Double { v <= 0.0031308 ? 12.92 * v : 1.055 * pow(v, 1 / 2.4) - 0.055 }
            return RGB(r: enc(mix[0] / peak), g: enc(mix[1] / peak), b: enc(mix[2] / peak))
        case let .temp(k):
            return ColourTemperature.rgb(kelvin: Double(k))
        case let .scene(id, _):
            return Scenes.swatch(id)
        case .custom:
            return nil
        }
    }
}

/// A saved light setting: colour plus brightness.
struct Preset: Codable, Hashable, Identifiable, Sendable {
    var id = UUID()
    var name: String
    var colour: LightColour
    var dimming: Int
}

/// One of setPilot's own scenes: 1–12 keyframes the bulb steps through, holding and fading as
/// set. Stored here (the bulb can't read definitions back) and played inline, so the bulb's
/// stored scenes are never overwritten.
struct CustomScene: Codable, Hashable, Identifiable, Sendable {
    var id = UUID()
    var name: String
    var steps: [Step]

    static let maxSteps = 12

    struct Step: Codable, Hashable, Identifiable, Sendable {
        var id = UUID()
        var useTemp = false
        var r = 255
        var g = 0
        var b = 0
        var c = 0
        var w = 0
        var temp = 2700
        /// Brightness of this step, 1–100, on top of the bulb's dimming.
        var level = 100
        /// How long the step holds, in ms.
        var hold = 1000
        /// How long the fade into the next step takes, in ms.
        var fade = 1000

        var colour: LightColour { useTemp ? .temp(temp) : .rgbcw(r: r, g: g, b: b, c: c, w: w) }

        /// Firmware 1.38.0's 13-number step: mode, R, G, B, warm, cool, kelvin, level, hold, fade,
        /// then three the firmware manages or ignores.
        var elm: [Int] {
            [useTemp ? 1 : 0, r, g, b, w, c, temp, min(max(level, 1), 100), max(hold, 0), max(fade, 0), 0, 0, 0]
        }
    }

    static func new(name: String) -> CustomScene {
        CustomScene(name: name, steps: [
            Step(r: 255, g: 60, b: 0, hold: 2000, fade: 2000),
            Step(r: 0, g: 40, b: 255, hold: 2000, fade: 2000),
        ])
    }

    /// The `elm` object for `setPilot`. `modifier` 1 keeps each step's own hold and fade
    /// (other values substitute fixed timings); `support` 17 enables the scene on this light
    /// type (bit 0 must be set, or it never plays).
    var elm: [String: Any] {
        ["modifier": 1, "support": 17, "steps": steps.prefix(Self.maxSteps).map(\.elm)]
    }

    var swatch: RGB? { steps.first?.colour.swatch }
}
