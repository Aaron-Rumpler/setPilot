import SwiftUI

extension RGB {
    var color: Color { Color(.sRGB, red: r, green: g, blue: b) }
}

extension ColourTemperature {
    static func color(kelvin: Double) -> Color { rgb(kelvin: kelvin).color }
}
