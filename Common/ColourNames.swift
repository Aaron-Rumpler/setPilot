import Foundation

/// Colours in plain words ("warm white", "pale blue", "deep red"), for VoiceOver: a swatch on its
/// own says nothing to someone who can't see it. Rough on purpose: a handful of hue families with
/// a qualifier, not a colour dictionary.
enum ColourNames {
    /// A name for an sRGB colour (components 0–1, gamma-encoded, as swatches are).
    static func name(_ rgb: RGB) -> String {
        let r = clamp(rgb.r), g = clamp(rgb.g), b = clamp(rgb.b)
        let value = max(r, g, b)
        let chroma = value - min(r, g, b)
        guard value >= 0.08 else { return "dark" }
        let saturation = chroma / value
        let hue = hueDegrees(r, g, b, value: value, chroma: chroma)

        // Whites and greys. The warm and cool whites are the tints of white light: an orange or
        // blue faint enough to read as white (2700 K's swatch is about 50% saturated orange).
        if saturation < 0.12 { return value < 0.5 ? "grey" : "white" }
        if value >= 0.6 {
            if (15..<55).contains(hue), saturation < 0.2 { return "white" }
            if (15..<55).contains(hue), saturation < 0.55 { return "warm white" }
            if (185..<250).contains(hue), saturation < 0.35 { return "cool white" }
        }

        var hueName = family(hue)
        if hueName == "red", saturation < 0.5, value >= 0.6 { return saturation < 0.25 ? "pale pink" : "pink" }
        if hueName == "orange", value < 0.6, saturation >= 0.5 { hueName = "brown" }
        if saturation < 0.4, value < 0.7 { return "greyish " + hueName }
        if saturation < 0.45 { return "pale " + hueName }
        if value < 0.55, hueName != "brown" { return "deep " + hueName }
        return hueName
    }

    /// A name for a colour temperature, by the bulb's own names for its whites (Warm White is
    /// 2700 K, Daylight 4200 K and Cool White 6500 K).
    static func name(kelvin: Double) -> String {
        switch kelvin {
        case ..<2400: "warm orange"
        case ..<3600: "warm white"
        case ..<5200: "daylight"
        default: "cool white"
        }
    }

    /// The hue family for a hue in degrees (0–360).
    static func family(_ hue: Double) -> String {
        switch hue {
        case ..<15: "red"
        case ..<40: "orange"
        case ..<70: "yellow"
        case ..<165: "green"
        case ..<195: "cyan"
        case ..<255: "blue"
        case ..<290: "purple"
        case ..<345: "pink"
        default: "red"
        }
    }

    private static func clamp(_ v: Double) -> Double { v.isFinite ? min(max(v, 0), 1) : 0 }

    private static func hueDegrees(_ r: Double, _ g: Double, _ b: Double, value: Double, chroma: Double) -> Double {
        guard chroma > 0 else { return 0 }
        let h: Double
        if value == r {
            h = (g - b) / chroma
        } else if value == g {
            h = (b - r) / chroma + 2
        } else {
            h = (r - g) / chroma + 4
        }
        let degrees = h * 60
        return degrees < 0 ? degrees + 360 : degrees
    }
}

extension LightColour {
    /// The colour in words, or nil for a scene (its name says more than a swatch would).
    var colourName: String? {
        switch self {
        case let .rgbcw(r, g, b, c, w):
            if r == 0, g == 0, b == 0 {
                // Only the whites: named as a temperature, between the two whites' (as the swatch).
                guard c + w > 0 else { return "dark" }
                return ColourNames.name(kelvin: 2700 + 3800 * Double(c) / Double(c + w))
            }
            return swatch.map { ColourNames.name($0) } ?? "dark"
        case let .temp(k), let .customCCT(_, k):
            return ColourNames.name(kelvin: Double(k))
        case .scene, .custom:
            return nil
        }
    }
}
