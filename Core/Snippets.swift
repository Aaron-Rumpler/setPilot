import AppIntents
import SwiftUI

/// What Siri, Spotlight and Shortcuts show after Get Light State, power and brightness changes:
/// the light, with buttons to switch it and make it brighter or dimmer there and then.
struct LightSnippet: View {
    let state: LightState

    var body: some View {
        HStack(spacing: 12) {
            Circle()
                .fill(colour)
                .frame(width: 36, height: 36)
                .overlay(Circle().strokeBorder(.secondary.opacity(0.4), lineWidth: 1))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(state.bulb.name ?? "Bulb").font(.headline).lineLimit(1)
                Text(LightStateEntity(state).summary).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
            Spacer(minLength: 8)
            Button(intent: AdjustBrightnessIntent(direction: .dimmer, step: 10)) { Image(systemName: "sun.min") }
                .accessibilityLabel("Dimmer")
            Button(intent: AdjustBrightnessIntent(direction: .brighter, step: 10)) { Image(systemName: "sun.max.fill") }
                .accessibilityLabel("Brighter")
            Button(intent: PowerIntent(action: .toggle)) { Image(systemName: "power") }
                .accessibilityLabel(state.on == true ? "Switch off" : "Switch on")
        }
        .buttonStyle(.bordered)
        .padding()
    }

    /// Roughly the light's colour: off is dark, a temperature its white, a scene or colour as sent.
    private var colour: Color {
        guard state.on == true else { return .black }
        if let k = state.temp, state.mode == "temperature" { return ColourTemperature.color(kelvin: Double(k)) }
        if let ch = state.rgbcw, ch.count >= 3, state.mode == "rgbcw" {
            let white = Double(max(ch.count > 3 ? ch[3] : 0, ch.count > 4 ? ch[4] : 0)) / 255
            func mix(_ v: Int) -> Double { min(1, Double(v) / 255 + white) }
            return Color(red: mix(ch[0]), green: mix(ch[1]), blue: mix(ch[2]))
        }
        return .orange
    }
}

extension PowerIntent {
    init(action: PowerAction) {
        self.init()
        self.action = action
    }
}

extension AdjustBrightnessIntent {
    init(direction: BrightnessDirection, step: Int) {
        self.init()
        self.direction = direction
        self.step = step
    }
}
