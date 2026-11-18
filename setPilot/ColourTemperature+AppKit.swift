import AppKit

extension ColourTemperature {
    static func colour(kelvin: Double) -> NSColor {
        let c = rgb(kelvin: kelvin)
        return NSColor(srgbRed: c.r, green: c.g, blue: c.b, alpha: 1)
    }
}
