import Foundation

/// The ways of setting colour. Custom CCT is setPilot's: a kelvin value turned into RGBCW through
/// one of your scales (the bulb only takes custom CCT tables from the cloud). The controls show it
/// as a scale under Temperature (`ModeChoice`). The raw values are stored, so they mustn't change.
enum Mode: String, CaseIterable, Identifiable, Codable, Sendable {
    case rgbcw = "RGBCW", temp = "Temperature", custom = "Custom CCT", scene = "Scene"
    var id: Self { self }

    var choice: ModeChoice {
        switch self {
        case .rgbcw: .rgbcw
        case .temp, .custom: .temperature
        case .scene: .scenes
        }
    }
}

/// The modes as every control shows them, by these names: Temperature covers both the bulb's
/// own colour temperature and your CCT scales (picked with its Scale control).
enum ModeChoice: String, CaseIterable, Identifiable, Codable, Sendable {
    case rgbcw = "RGBCW", temperature = "Temperature", scenes = "Scenes"
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
    /// A kelvin value on one of your CCT scales.
    case customCCT(scale: UUID, kelvin: Int)

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
        case let .customCCT(_, k):
            return ColourTemperature.rgb(kelvin: Double(k))
        }
    }
}

/// A change to send in one setPilot: any of colour, brightness and power, with a fade time
/// (`trans`, ms; nil for the bulb's own). Turning off always uses the bulb's own fade-out.
struct LightChange: Codable, Hashable, Sendable {
    var colour: LightColour? = nil
    var dimming: Int? = nil
    /// true switches on, false off, nil leaves it.
    var power: Bool? = nil
    var fade: Int? = nil
}

/// How a composed change fades: the fade time setting (only offered when one is set), none
/// (no `trans`: the bulb's own fade), or a value just for this change.
enum FadeChoice: String, Codable, Hashable, Sendable {
    case setting, none, custom

    /// The choices that mean different things: without a fade setting, "the setting" and "none"
    /// would both send no `trans`, so only "none" is offered.
    static func options(setting: Int?) -> [FadeChoice] { setting == nil ? [.none, .custom] : [.setting, .none, .custom] }

    func title(setting: Int?) -> String {
        switch self {
        case .setting: "Default (\(setting ?? 0) ms)"
        case .none: "None"
        case .custom: "Custom"
        }
    }

    /// The `trans` to send, if any.
    func trans(setting: Int?, custom: Int) -> Int? {
        switch self {
        case .setting: setting
        case .none: nil
        case .custom: custom
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
    /// The step the bulb starts on (elm's initStep), from 0.
    var startStep = 0
    var timing = Timing.steps

    static let maxSteps = 12

    /// elm's `modifier`: on firmware 1.38.0 only 4 and 5 differ from 1, replacing every step's
    /// hold and fade.
    enum Timing: Int, Codable, CaseIterable, Sendable {
        case steps = 1
        case slow = 4
        case quick = 5

        var name: String {
            switch self {
            case .steps: "Each Step's Own"
            case .slow: "Slow: Hold 1.5 s, Fade 1.5 s"
            case .quick: "Quick: Hold 0.4 s, Fade 0.5 s"
            }
        }
    }

    struct Step: Codable, Hashable, Identifiable, Sendable {
        var id = UUID()
        var useTemp = false
        /// No light: all five channels at 0. The colour settings are kept for switching back.
        var dark = false
        var r = 255
        var g = 0
        var b = 0
        var c = 0
        var w = 0
        var temp = 2700
        /// Brightness of this step, 0–100, on top of the bulb's dimming.
        var level = 100
        /// How long the step holds, in ms.
        var hold = 1000
        /// How long the fade into the next step takes, in ms.
        var fade = 1000
        /// Random variation of the hold and the fade, at most this many percent either way, on
        /// this percentage of the times the step plays. The bulb takes only the values in the lists.
        var holdJitter = 0
        var fadeJitter = 0
        var jitterChance = 100

        static let holdJitters = [0, 10, 25, 75, 100]
        static let fadeJitters = [0, 10, 25, 50, 75, 100]
        static let jitterChances = [100, 90, 50, 10]

        var jitters: Bool { holdJitter > 0 || fadeJitter > 0 }

        /// elm's per-step jitter byte: bits 0–1 the chance, 2–4 the hold's, 5–7 the fade's (as
        /// indexes into the firmware's tables, which these lists are reordered from).
        var jitterByte: Int {
            guard jitters else { return 0 }
            let chance = [100: 0, 10: 1, 50: 2, 90: 3][jitterChance] ?? 0
            let hold = Self.holdJitters.firstIndex(of: holdJitter) ?? 0
            let fade = Self.fadeJitters.firstIndex(of: fadeJitter) ?? 0
            return fade << 5 | hold << 2 | chance
        }

        enum Kind: CaseIterable, Sendable { case rgbcw, temperature, dark }

        var kind: Kind {
            get { dark ? .dark : useTemp ? .temperature : .rgbcw }
            set {
                dark = newValue == .dark
                if newValue != .dark { useTemp = newValue == .temperature }
            }
        }

        var colour: LightColour {
            if dark { return .rgbcw(r: 0, g: 0, b: 0, c: 0, w: 0) }
            return useTemp ? .temp(temp) : .rgbcw(r: r, g: g, b: b, c: c, w: w)
        }

        /// Firmware 1.38.0's 13-number step: mode, R, G, B, warm, cool, kelvin, level, hold, fade,
        /// jitter, then two with no known effect.
        /// The fields the step doesn't use are sent as 0: the channels for a temperature step, the
        /// kelvin for an RGBCW one. A dark step is a colour step with every channel at 0.
        var elm: [Int] {
            let temperature = useTemp && !dark
            let channels = temperature || dark ? [0, 0, 0, 0, 0] : [r, g, b, w, c]
            let level = dark ? 100 : min(max(self.level, 0), 100)
            return [temperature ? 1 : 0] + channels + [temperature ? temp : 0, level, max(hold, 0), max(fade, 0), jitterByte, 0, 0]
        }

        init(useTemp: Bool = false, r: Int = 255, g: Int = 0, b: Int = 0, c: Int = 0, w: Int = 0, temp: Int = 2700,
             level: Int = 100, hold: Int = 1000, fade: Int = 1000) {
            (self.useTemp, self.r, self.g, self.b, self.c, self.w, self.temp) = (useTemp, r, g, b, c, w, temp)
            (self.level, self.hold, self.fade) = (level, hold, fade)
        }

        // Steps saved before jitter existed have no jitter keys.
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            id = try c.decode(UUID.self, forKey: .id)
            useTemp = try c.decode(Bool.self, forKey: .useTemp)
            dark = try c.decodeIfPresent(Bool.self, forKey: .dark) ?? false
            r = try c.decode(Int.self, forKey: .r)
            g = try c.decode(Int.self, forKey: .g)
            b = try c.decode(Int.self, forKey: .b)
            self.c = try c.decode(Int.self, forKey: .c)
            w = try c.decode(Int.self, forKey: .w)
            temp = try c.decode(Int.self, forKey: .temp)
            level = try c.decode(Int.self, forKey: .level)
            hold = try c.decode(Int.self, forKey: .hold)
            fade = try c.decode(Int.self, forKey: .fade)
            holdJitter = try c.decodeIfPresent(Int.self, forKey: .holdJitter) ?? 0
            fadeJitter = try c.decodeIfPresent(Int.self, forKey: .fadeJitter) ?? 0
            jitterChance = try c.decodeIfPresent(Int.self, forKey: .jitterChance) ?? 100
        }
    }

    init(id: UUID = UUID(), name: String, steps: [Step], startStep: Int = 0, timing: Timing = .steps) {
        (self.id, self.name, self.steps, self.startStep, self.timing) = (id, name, steps, startStep, timing)
    }

    // Scenes saved before these existed have no startStep or timing.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        steps = try c.decode([Step].self, forKey: .steps)
        startStep = try c.decodeIfPresent(Int.self, forKey: .startStep) ?? 0
        timing = try c.decodeIfPresent(Timing.self, forKey: .timing) ?? .steps
    }

    static func new(name: String) -> CustomScene {
        CustomScene(name: name, steps: [
            Step(r: 255, g: 60, b: 0, hold: 2000, fade: 2000),
            Step(r: 0, g: 40, b: 255, hold: 2000, fade: 2000),
        ])
    }

    /// The `elm` object for `setPilot`. `modifier` is the timing; `support` 17 enables the scene
    /// on this light type (bit 0 must be set, or it never plays); `initStep` must be one of the steps.
    var elm: [String: Any] {
        let sent = steps.prefix(Self.maxSteps).map(\.elm)
        var elm: [String: Any] = ["modifier": timing.rawValue, "support": 17, "steps": sent]
        let start = min(max(startStep, 0), max(sent.count - 1, 0))
        if start > 0 { elm["initStep"] = start }
        return elm
    }

    var swatch: RGB? { (steps.first { !$0.dark } ?? steps.first)?.colour.swatch }
}

/// A colour-temperature scale: RGBCW values at some kelvin points, interpolated between them the
/// way the firmware interpolates its own table (linear in kelvin, each channel truncated), so a
/// scale made from the bulb's default gives exactly what `temp` gives. Kept per bulb.
struct CCTScale: Codable, Hashable, Identifiable, Sendable {
    var id = UUID()
    var name: String
    var points: [Point]

    struct Point: Codable, Hashable, Identifiable, Sendable {
        var id = UUID()
        var kelvin: Int
        var r = 0
        var g = 0
        var b = 0
        var c = 0
        var w = 0

        var channels: Channels { Channels(r: r, g: g, b: b, c: c, w: w) }
    }

    struct Channels: Hashable, Sendable {
        var r: Int
        var g: Int
        var b: Int
        var c: Int
        var w: Int
    }

    /// Sorted by kelvin (the firmware expects ascending points; equal ones are allowed).
    var sorted: [Point] {
        points.enumerated().sorted { ($0.element.kelvin, $0.offset) < ($1.element.kelvin, $1.offset) }.map(\.element)
    }

    var range: ClosedRange<Int>? {
        let k = points.map(\.kelvin)
        guard let lo = k.min(), let hi = k.max(), lo < hi else { return nil }
        return lo...hi
    }

    /// The firmware's interpolation: clamp to the table, take the first point at or
    /// above `kelvin`, and step each channel from the one before with C integer division.
    func channels(at kelvin: Int) -> Channels? { Self.channels(at: kelvin, sorted: sorted) }

    private static func channels(at kelvin: Int, sorted pts: [Point]) -> Channels? {
        guard let first = pts.first, let last = pts.last else { return nil }
        let t = min(max(kelvin, first.kelvin), last.kelvin)
        guard pts.count > 1, let i = pts.indices.dropFirst().first(where: { pts[$0].kelvin >= t }) else {
            return first.channels
        }
        let a = pts[i - 1], b = pts[i]
        if a.kelvin == b.kelvin { return a.channels }
        func lerp(_ x: Int, _ y: Int) -> Int { x + (y - x) * (t - a.kelvin) / (b.kelvin - a.kelvin) }
        return Channels(r: lerp(a.r, b.r), g: lerp(a.g, b.g), b: lerp(a.b, b.b), c: lerp(a.c, b.c), w: lerp(a.w, b.w))
    }

    /// The kelvin value that gives exactly these channels, nearest to `near`; nil if none does.
    func kelvin(matching ch: Channels, near: Int) -> Int? {
        guard let range else { return nil }
        let pts = sorted // once, not for each of the thousands of kelvin values tried
        if range.contains(near), Self.channels(at: near, sorted: pts) == ch { return near }
        var best: Int?
        for k in range where Self.channels(at: k, sorted: pts) == ch {
            if best == nil || abs(k - near) < abs(best! - near) { best = k }
        }
        return best
    }

    /// The bulb's own table, rebuilt from getModelConfig (`cctRange` and `renderFactor`) as
    /// firmware 1.38.0 builds it. Nil if they're missing or out of range.
    static func bulbDefault(cctRange: [Int], renderFactor: [Int]) -> CCTScale? {
        guard cctRange.count >= 4, renderFactor.count >= 10 else { return nil }
        // renderFactor index → the firmware's colour-calibration byte X[n]
        var X = [Int](repeating: 0, count: 12)
        for (k, n) in [0, 1, 5, 4, 9, 10, 6, 7, 8, 11].enumerated() { X[n] = renderFactor[k] & 0xFF }
        let extLo = cctRange[0], lo = cctRange[1], hi = cctRange[2], extHi = cctRange[3]
        guard lo > 999, hi <= 12000 else { return nil }
        var s1: Int, s4: Int
        if X[4] & X[5] == 255 {
            s1 = 4200
            s4 = 4200
        } else {
            s1 = (X[6] * 100) & 0xFFFF
            if s1 == 0 || s1 > hi || s1 < lo { s1 = ((2 * lo * hi) / (lo + hi) + ((lo + hi) >> 1)) >> 1 }
            var a5 = 4200
            if s1 > 4200 { (a5, s1) = (s1, 4200) }
            s4 = min(a5, hi)
        }
        // Firmware order is r, g, b, warm, cool.
        let rows: [(Int, Int, Int, Int, Int, Int)] = [
            (extLo, X[1], 0, 0, X[0], 0),
            (lo, 0, 0, 0, 255, 0),
            (s1, 0, 0, 0, 255, X[4]),
            (s4, 0, 0, 0, X[5], 255),
            (hi, 0, 0, 0, 0, 255),
            (extHi, 0, X[9], X[10], 0, 255),
        ]
        return CCTScale(name: "Bulb default", points: rows.map {
            Point(kelvin: $0.0, r: $0.1, g: $0.2, b: $0.3, c: $0.5, w: $0.4)
        })
    }

    /// WiZ's table continued below its lowest point: red rises along the same line as between
    /// the two lowest points until it reaches 255 (about 1540 K on the ESP25_SHRGB_01).
    func extendedDownwards() -> CCTScale? {
        let pts = sorted
        guard pts.count >= 2, pts[0].kelvin < pts[1].kelvin, pts[0].r > pts[1].r, pts[0].r < 255 else { return nil }
        let a = pts[1], b = pts[0]
        // Kelvin where red reaches 255 on the line through a and b.
        let k = a.kelvin - (255 - a.r) * (a.kelvin - b.kelvin) / (b.r - a.r)
        guard k > 0, k < b.kelvin else { return nil }
        var copy = self
        copy.points.insert(Point(kelvin: k, r: 255, g: b.g, b: b.b, c: b.c, w: b.w), at: 0)
        copy.points = copy.sorted
        return copy
    }
}

/// The round steps sliders snap to, and − and + (and the Mac's steppers) step by, the same in every
/// app, so values land on round numbers. Snapping can be turned off in Settings; − and + always
/// step. Finer control: Option on the Mac, touch and hold before dragging on iPhone, and the value
/// popup's − and + (and the Crown there) in 1s.
enum Stepping {
    /// 100 ms for times, 50 K for colour temperatures, 32 for 0–255 channels (eight steps, the last
    /// one short), 5 for percentages (anything up to 100), 10 for the rest (speed).
    static func coarse(for range: ClosedRange<Double>) -> Double {
        if range.upperBound > 20_000 { return 100 }
        if range.upperBound > 1000 { return 50 }
        if range.upperBound == 255 { return 32 }
        if range.upperBound <= 100 { return 5 }
        return 10
    }

    /// In-between buttons for the value popup where 1 is too fine and the round step too coarse
    /// (temperatures and times): 10. Nil elsewhere.
    static func medium(for range: ClosedRange<Double>) -> Double? {
        coarse(for: range) >= 50 ? 10 : nil
    }

    /// The next multiple of `step` above or below `value` (37 → 40 → 50), within `range`.
    static func next(_ value: Double, up: Bool, by step: Double, in range: ClosedRange<Double>) -> Double {
        let v = up ? ((value / step).rounded(.down) + 1) * step : ((value / step).rounded(.up) - 1) * step
        return min(max(v, range.lowerBound), range.upperBound)
    }

    /// The nearest multiple of `step`, within `range` (both ends stay reachable).
    static func snap(_ value: Double, to step: Double, in range: ClosedRange<Double>) -> Double {
        min(max((value / step).rounded() * step, range.lowerBound), range.upperBound)
    }

    /// Settings: sliders (and the Digital Crown) snap to the round steps. On by default.
    static let snapKey = "snapSliders"
    static var snaps: Bool { UserDefaults.standard.object(forKey: snapKey) as? Bool ?? true }

    /// What a slider snaps to: the round step, or 1 with snapping off (or a fine drag).
    static func snapStep(for range: ClosedRange<Double>, snapping: Bool) -> Double {
        snapping ? coarse(for: range) : 1
    }
}
