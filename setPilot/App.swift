import AppKit
import SwiftUI

@main
struct SetPilotApp: App {
    @NSApplicationDelegateAdaptor private var delegate: AppDelegate

    var body: some Scene {
        Window("WiZ", id: "main") { ContentView() }
            .windowResizability(.contentSize)
        Settings { AdaptationSettings() }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

/// Testing aid: the white the colour-temperature colours are adapted to (see ColourTemperature).
struct AdaptationSettings: View {
    @AppStorage(ColourTemperature.adaptingWhiteKey) private var adaptingWhite = ColourTemperature.defaultAdaptingWhite

    var body: some View {
        Form {
            LabeledContent("Adapted to") {
                HStack {
                    Slider(value: $adaptingWhite, in: 3000...7000, step: 50)
                    Text("\(Int(adaptingWhite)) K").monospacedDigit().frame(width: 64, alignment: .trailing)
                    Stepper("", value: $adaptingWhite, in: 3000...7000, step: 50).labelsHidden()
                }
            }
            LabeledContent("Preview") {
                HStack(spacing: 4) {
                    ForEach([2200.0, 2700, 3000, 3500, 4200, 5000, 6500], id: \.self) { k in
                        VStack(spacing: 2) {
                            RoundedRectangle(cornerRadius: 4)
                                .fill(Color(nsColor: ColourTemperature.colour(kelvin: k)))
                                .frame(width: 44, height: 28)
                                .id(adaptingWhite) // redraw when the setting changes
                            Text("\(Int(k))").font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            HStack {
                Spacer()
                Button("Reset to \(Int(ColourTemperature.defaultAdaptingWhite)) K") {
                    adaptingWhite = ColourTemperature.defaultAdaptingWhite
                }
            }
        }
        .padding(20)
        .frame(width: 480)
    }
}
