import AppIntents
import SwiftUI

/// What Siri, Spotlight and Shortcuts show after Get Light State, power and brightness changes:
/// the light, with buttons to switch it and make it brighter or dimmer there and then. A snippet
/// intent, so the system shows it afresh after each button (iOS and macOS 26).
struct LightSnippetIntent: SnippetIntent {
    static let title: LocalizedStringResource = "Light"
    static let isDiscoverable = false

    init() {}

    @MainActor
    func perform() async throws -> some IntentResult & ShowsSnippetView {
        .result(view: LightSnippet(state: Scripting.state(of: Shared.model)))
    }
}

/// The snippet's buttons: quiet (no dialog of their own), for the snippet to show what happened.
struct SnippetPowerIntent: AppIntent {
    static let title: LocalizedStringResource = "Switch the Bulb On or Off"
    static let isDiscoverable = false
    init() {}

    @MainActor
    func perform() async throws -> some IntentResult {
        _ = try await script(.power(nil))
        return .result()
    }
}

struct SnippetBrightnessIntent: AppIntent {
    static let title: LocalizedStringResource = "Make Brighter or Dimmer"
    static let isDiscoverable = false
    @Parameter(title: "Step") var step: Int
    init() {}
    init(step: Int) { self.step = step }

    @MainActor
    func perform() async throws -> some IntentResult {
        _ = try await script(.adjustBrightness(step))
        return .result()
    }
}

struct LightSnippet: View {
    let state: LightState

    var body: some View {
        HStack(spacing: 12) {
            Circle()
                .fill(colour)
                .frame(width: 36, height: 36)
                .overlay(Circle().strokeBorder(.secondary.opacity(0.4), lineWidth: 1))
                // The colour in words (the summary says only "a colour"); hidden for a scene,
                // which the summary names, and when it's off.
                .accessibilityElement()
                .accessibilityLabel("Colour")
                .accessibilityValue(colourName ?? "")
                .accessibilityHidden(colourName == nil)
            VStack(alignment: .leading, spacing: 2) {
                Text(state.bulb.name ?? "Bulb").font(.headline).lineLimit(1)
                Text(LightStateEntity(state).summary).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
            Spacer(minLength: 8)
            Button(intent: SnippetBrightnessIntent(step: -10)) { Image(systemName: "sun.min") }
                .accessibilityLabel("Dimmer")
            Button(intent: SnippetBrightnessIntent(step: 10)) { Image(systemName: "sun.max.fill") }
                .accessibilityLabel("Brighter")
            Button(intent: SnippetPowerIntent()) { Image(systemName: "power") }
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

    /// The light's colour in words: "warm white", "deep blue"; nil for a scene or when it's off
    /// (the summary says so).
    private var colourName: String? {
        guard state.on == true else { return nil }
        if let k = state.temp, state.mode == "temperature" { return ColourNames.name(kelvin: Double(k)) }
        if let ch = state.rgbcw, ch.count >= 3, state.mode == "rgbcw" {
            func at(_ i: Int) -> Int { ch.count > i ? ch[i] : 0 }
            return LightColour.rgbcw(r: at(0), g: at(1), b: at(2), c: at(3), w: at(4)).colourName
        }
        return nil
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
