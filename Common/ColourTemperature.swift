import Foundation

/// An sRGB colour, each component 0–1 (gamma-encoded).
struct RGB: Hashable, Sendable, Codable {
    var r: Double
    var g: Double
    var b: Double
}

/// Display colour of a black-body (Planckian) light, for colour-temperature scales and the
/// cool/warm white channels.
enum ColourTemperature {
    /// The white the viewer is taken to be adapted to. Rendering a light exactly as measured
    /// against the display's D65 white makes 4200 K look clearly orange, which isn't how it looks
    /// in a room: your eyes adapt. Adapting to 4500 K matches observation of a WiZ bulb in
    /// daylight: the orange is just gone by 4200 K ("Daylight"), and 6500 K ("Cool White") looks
    /// clearly cooler. Adjustable for testing in Settings (stored in user defaults).
    static let defaultAdaptingWhite = 4500.0
    static let adaptingWhiteKey = "adaptingWhite"

    static var adaptingWhite: Double {
        let v = UserDefaults.standard.double(forKey: adaptingWhiteKey)
        return v > 0 ? v : defaultAdaptingWhite
    }

    /// sRGB colour of a light at `kelvin` as seen by a viewer adapted to `adaptingWhite`, scaled so
    /// the brightest channel is full.
    ///
    /// - Chromaticity: Kim et al. (2002) fit of the CIE 1931 2° Planckian locus, valid
    ///   1667–25000 K; within Δxy 0.0006 of direct integration of Planck's law over 2000–7000 K.
    /// - Adaptation: von Kries in CAT02 cone space (as in CIECAM02), mapping the adapting white to
    ///   the display's D65 white.
    /// - Output: linear sRGB (IEC 61966-2-1), negatives clipped, normalised, sRGB transfer curve.
    static func rgb(kelvin: Double) -> RGB {
        let source = cat02(xyz(kelvin))
        let from = cat02(xyz(adaptingWhite))
        let to = cat02(d65)
        let adapted = cat02Inverse((source.0 * to.0 / from.0, source.1 * to.1 / from.1, source.2 * to.2 / from.2))

        let (X, Y, Z) = adapted
        let r = max(3.2404542 * X - 1.5371385 * Y - 0.4985314 * Z, 0)
        let g = max(-0.9692660 * X + 1.8760108 * Y + 0.0415560 * Z, 0)
        let b = max(0.0556434 * X - 0.2040259 * Y + 1.0572252 * Z, 0)
        let peak = max(r, g, b)
        func encode(_ c: Double) -> Double {
            let v = c / peak
            return v <= 0.0031308 ? 12.92 * v : 1.055 * pow(v, 1 / 2.4) - 0.055
        }
        return RGB(r: encode(r), g: encode(g), b: encode(b))
    }

    private typealias Triple = (Double, Double, Double)

    /// D65 white point (x 0.3127, y 0.3290) at Y = 1.
    private static let d65: Triple = (0.3127 / 0.3290, 1, (1 - 0.3127 - 0.3290) / 0.3290)

    /// XYZ (Y = 1) of the Planckian locus at `kelvin`.
    private static func xyz(_ kelvin: Double) -> Triple {
        let t = min(max(kelvin, 1667), 25000)
        let x: Double
        if t <= 4000 {
            x = -0.2661239e9 / (t * t * t) - 0.2343589e6 / (t * t) + 0.8776956e3 / t + 0.179910
        } else {
            x = -3.0258469e9 / (t * t * t) + 2.1070379e6 / (t * t) + 0.2226347e3 / t + 0.240390
        }
        let y: Double
        if t <= 2222 {
            y = -1.1063814 * x * x * x - 1.34811020 * x * x + 2.18555832 * x - 0.20219683
        } else if t <= 4000 {
            y = -0.9549476 * x * x * x - 1.37418593 * x * x + 2.09137015 * x - 0.16748867
        } else {
            y = 3.0817580 * x * x * x - 5.87338670 * x * x + 3.75112997 * x - 0.37001483
        }
        return (x / y, 1, (1 - x - y) / y)
    }

    private static func cat02(_ v: Triple) -> Triple {
        (0.7328 * v.0 + 0.4296 * v.1 - 0.1624 * v.2,
         -0.7036 * v.0 + 1.6975 * v.1 + 0.0061 * v.2,
         0.0030 * v.0 + 0.0136 * v.1 + 0.9834 * v.2)
    }

    private static func cat02Inverse(_ v: Triple) -> Triple {
        (1.096124 * v.0 - 0.278869 * v.1 + 0.182745 * v.2,
         0.454369 * v.0 + 0.473533 * v.1 + 0.072098 * v.2,
         -0.009628 * v.0 - 0.005698 * v.1 + 1.015326 * v.2)
    }
}
