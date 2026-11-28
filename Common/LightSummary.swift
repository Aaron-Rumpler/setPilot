import Foundation

/// How Siri and Shortcuts describe the light, the same on the iPhone, the Mac and the watch:
/// "Lounge: on, 2700 K (Warm), 60%", or "Lounge: off".
enum LightSummary {
    /// `colour`: a temperature (as `temperature(_:scale:)` words it) or a scene's name; nil for
    /// a colour (RGBCW).
    static func text(bulb: String, on: Bool, colour: String?, brightness: Int) -> String {
        guard on else { return "\(bulb): off" }
        return "\(bulb): on, \(colour ?? "a colour"), \(brightness)%"
    }

    /// A colour temperature, with the CCT scale it's on (nil for the bulb's own).
    static func temperature(_ kelvin: Int, scale: String?) -> String {
        "\(kelvin) K" + (scale.map { " (\($0))" } ?? "")
    }
}
