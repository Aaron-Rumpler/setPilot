import AppKit

/// Display colour of a black-body (Planckian) radiator, for drawing colour-temperature scales.
enum ColourTemperature {
    /// sRGB colour of the Planckian locus at `kelvin`, scaled so the brightest channel is full.
    ///
    /// Chromaticity uses the Kim et al. (2002) cubic-spline fit of the CIE 1931 2° Planckian
    /// locus, valid for 1667–25000 K. Against direct integration of Planck's law with the CIE 1931
    /// colour-matching functions it is within Δxy 0.0006 over 2000–7000 K, far below what's
    /// visible. xyY → XYZ → linear sRGB (IEC 61966-2-1, D65) → sRGB transfer curve. No chromatic
    /// adaptation, so colours are relative to the display's D65 white (6500 K is faintly pink,
    /// as the locus passes just below D65). Everything above ~1900 K is inside the sRGB gamut;
    /// below that, negative channels are clipped.
    static func colour(kelvin: Double) -> NSColor {
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

        // xyY (Y = 1) → XYZ → linear sRGB
        let (X, Y, Z) = (x / y, 1.0, (1 - x - y) / y)
        var r = 3.2404542 * X - 1.5371385 * Y - 0.4985314 * Z
        var g = -0.9692660 * X + 1.8760108 * Y + 0.0415560 * Z
        var b = 0.0556434 * X - 0.2040259 * Y + 1.0572252 * Z
        (r, g, b) = (max(r, 0), max(g, 0), max(b, 0))
        let peak = max(r, g, b)
        func encode(_ c: Double) -> CGFloat {
            let v = c / peak
            return CGFloat(v <= 0.0031308 ? 12.92 * v : 1.055 * pow(v, 1 / 2.4) - 0.055)
        }
        return NSColor(srgbRed: encode(r), green: encode(g), blue: encode(b), alpha: 1)
    }
}
