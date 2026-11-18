import SwiftUI

/// Prepares a change (any of colour, brightness and power, with its own fade time) and sends it
/// as one setPilot. Starts from the bulb's current state.
struct ComposeView: View {
    let model: Model
    /// Called after sending (to close a sheet).
    var onSend: () -> Void = {}

    private enum ColourKind: String, CaseIterable, Identifiable {
        case rgbcw = "RGBCW", temp = "Temperature", custom = "Custom CCT", scene = "Scene"
        var id: Self { self }
    }

    private enum Power: String, CaseIterable, Identifiable {
        case leave = "Leave", on = "On", off = "Off"
        var id: Self { self }
    }

    @State private var includeColour = true
    @State private var kind = ColourKind.temp
    @State private var r = 255
    @State private var g = 0
    @State private var b = 0
    @State private var c = 0
    @State private var w = 0
    @State private var temp = 2700
    @State private var customKelvin = 2700
    @State private var scene = SceneChoice.builtin(1)
    @State private var includeDimming = true
    @State private var dimming = 100
    @State private var power = Power.leave
    @State private var useFade = true
    @State private var fade = 10_000
    @State private var loaded = false

    var body: some View {
        Form {
            Section {
                Toggle("Colour", isOn: $includeColour)
                if includeColour {
                    Picker("Kind", selection: $kind) {
                        ForEach(ColourKind.allCases) { Text($0.rawValue).tag($0) }
                    }
                    colourControls
                }
            }
            Section {
                Toggle("Brightness", isOn: $includeDimming)
                if includeDimming {
                    IntSliderRow(label: "Dimming", value: $dimming, range: Int(model.minDimming)...100, unit: "%")
                }
            }
            Section {
                Picker("Power", selection: $power) {
                    ForEach(Power.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
            } footer: {
                if model.isOn == false && power == .leave && (includeColour || includeDimming) {
                    Text("The bulb is off and stays off; the change shows when it's switched on.")
                }
            }
            Section {
                Toggle("Fade", isOn: $useFade)
                if useFade { MillisecondsRow(label: "Fade time", value: $fade) }
            } footer: {
                Text(power == .off
                     ? "Turning off always uses the bulb's own fade-out. To fade out slowly, fade the brightness down instead."
                     : useFade ? "The bulb fades to the new state over this time (trans)." : "The bulb's own fade.")
            }
            Section {
                Text(preview)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                Button {
                    model.send(change)
                    onSend()
                } label: {
                    Label("Send", systemImage: "paperplane.fill")
                }
                .disabled(!model.canControl || !hasChange)
                .keyboardShortcut(.defaultAction)
                Button("Start from the Bulb's Current State") { load() }
            } footer: {
                if case .scene(let id, _)? = change.colour, case .builtin = scene, Scenes.isKnown(id) {
                    Text("A scene's speed can't go in the same request (a firmware bug), so it's left as it is.")
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Compose a Change")
        .onAppear { if !loaded { load() } }
    }

    @ViewBuilder private var colourControls: some View {
        switch kind {
        case .rgbcw:
            IntSliderRow(label: "Red", value: $r, range: 0...255, tint: .red)
            IntSliderRow(label: "Green", value: $g, range: 0...255, tint: .green)
            IntSliderRow(label: "Blue", value: $b, range: 0...255, tint: .blue)
            IntSliderRow(label: "Cool white", value: $c, range: 0...255, tint: ColourTemperature.color(kelvin: 6500))
            IntSliderRow(label: "Warm white", value: $w, range: 0...255, tint: ColourTemperature.color(kelvin: 2700))
        case .temp:
            IntSliderRow(label: "Kelvin", value: $temp,
                         range: Int(model.tempRange.lowerBound)...Int(model.tempRange.upperBound), step: 50,
                         tint: ColourTemperature.color(kelvin: Double(temp)))
        case .custom:
            if let scale = model.activeScale, let range = scale.range {
                Picker("Scale", selection: model.scaleChoice) {
                    ForEach(model.library.scales(for: model.chosenMAC)) { Text($0.name).tag(Optional($0.id)) }
                }
                IntSliderRow(label: "Kelvin", value: $customKelvin, range: range, step: 10,
                             tint: ColourTemperature.color(kelvin: Double(customKelvin)))
            } else {
                Text("This bulb has no custom CCT scale yet.").foregroundStyle(.secondary)
            }
        case .scene:
            Picker("Scene", selection: $scene) {
                ForEach(Scenes.all) { Text($0.name).tag(SceneChoice.builtin($0.id)) }
                if !model.library.customScenes.isEmpty {
                    Divider()
                    ForEach(model.library.customScenes) { Text($0.name).tag(SceneChoice.custom($0.id)) }
                }
            }
        }
    }

    private var change: LightChange {
        var ch = LightChange()
        if includeColour {
            switch kind {
            case .rgbcw: ch.colour = .rgbcw(r: r, g: g, b: b, c: c, w: w)
            case .temp: ch.colour = .temp(temp)
            case .custom: ch.colour = model.activeScale.map { .customCCT(scale: $0.id, kelvin: customKelvin) }
            case .scene:
                switch scene {
                case .builtin(let id): ch.colour = .scene(id: id, speed: nil)
                case .custom(let id): ch.colour = .custom(id, speed: nil)
                }
            }
        }
        if includeDimming { ch.dimming = dimming }
        ch.power = switch power {
        case .leave: nil
        case .on: true
        case .off: false
        }
        if useFade { ch.fade = fade }
        return ch
    }

    private var hasChange: Bool { change.colour != nil || change.dimming != nil || change.power != nil }

    /// Roughly what will be sent (custom scenes' definitions shortened).
    private var preview: String {
        let ch = change
        var parts: [String] = []
        switch ch.colour {
        case let .rgbcw(r, g, b, c, w)?: parts.append("\"r\":\(r),\"g\":\(g),\"b\":\(b),\"c\":\(c),\"w\":\(w)")
        case let .temp(k)?: parts.append("\"temp\":\(k)")
        case let .scene(id, _)?: parts.append("\"sceneId\":\(id)")
        case .custom?: parts.append("\"sceneId\":\(Scenes.inlineCustom),\"elm\":{…}")
        case let .customCCT(id, k)?:
            if let v = model.library.scale(id)?.scale.channels(at: k) {
                parts.append("\"r\":\(v.r),\"g\":\(v.g),\"b\":\(v.b),\"c\":\(v.c),\"w\":\(v.w)")
            }
        case nil: break
        }
        if let d = ch.dimming { parts.append("\"dimming\":\(d)") }
        if ch.power == false || (ch.power == nil && model.isOn == false) { parts.append("\"state\":false") }
        if let f = ch.fade, !parts.isEmpty || ch.power == true { parts.append("\"trans\":\(f)") }
        return "setPilot {" + parts.joined(separator: ",") + "}"
    }

    private func load() {
        loaded = true
        r = Int(model.r); g = Int(model.g); b = Int(model.b); c = Int(model.c); w = Int(model.w)
        temp = Int(model.temp)
        customKelvin = Int(model.customKelvin)
        if let range = model.activeScale?.range { customKelvin = min(max(customKelvin, range.lowerBound), range.upperBound) }
        dimming = Int(model.dimming)
        scene = model.sceneChoice.wrappedValue
        if case .builtin(let id) = scene, !Scenes.isKnown(id) { scene = .builtin(1) }
        if case .custom(let id) = scene, model.library.customScene(id) == nil { scene = .builtin(1) }
        kind = switch model.mode {
        case .rgbcw: .rgbcw
        case .temp: .temp
        case .custom: .custom
        case .scene: .scene
        }
        power = .leave
    }
}
