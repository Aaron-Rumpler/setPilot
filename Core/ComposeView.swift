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
    /// The scale for Custom CCT, chosen here: picking one mustn't change the bulb until Send.
    @State private var scaleID: UUID?
    @State private var scene = SceneChoice.builtin(1)
    @State private var includeSpeed = false
    @State private var speed = 100
    @State private var includeDimming = true
    @State private var dimming = 100
    @State private var power = Power.leave
    @State private var fadeChoice = FadeChoice.none
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
            } header: {
                Text("Power")
            } footer: {
                if model.isOn == false && power == .leave && (includeColour || includeDimming) {
                    Text("The bulb is off and stays off; the change shows when it's switched on.")
                }
            }
            Section {
                Picker("Fade", selection: $fadeChoice) {
                    ForEach(FadeChoice.options(setting: Model.fade), id: \.self) {
                        Text($0.title(setting: Model.fade)).tag($0)
                    }
                }
                if fadeChoice == .custom { MillisecondsRow(label: "Fade time", value: $fade) }
            } footer: {
                Text(power == .off
                     ? "Turning off always uses the bulb's own fade-out. To fade out slowly, fade the brightness down instead."
                     : fadeChoice.trans(setting: Model.fade, custom: fade) != nil
                        ? "The bulb fades to the new state over this time (trans)."
                        : "No trans: the bulb uses its own fade" + ownFade + ".")
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
                if change.colour?.isScene == true, includeSpeed {
                    Text("The speed goes in a setPilot of its own just after: the firmware ignores it alongside anything else.")
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Compose a Change")
        // Start from the bulb's state, once it's known (it may arrive after this opens).
        .onAppear { if !loaded, model.canControl { load() } }
        .onChange(of: model.canControl) { _, can in if can, !loaded { load() } }
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
            if let scale, let range = scale.range {
                let scales = model.library.scales(for: model.chosenMAC).filter { $0.range != nil }
                Picker("Scale", selection: Binding(get: { scale.id }, set: { id in
                    scaleID = id
                    if let r = scales.first(where: { $0.id == id })?.range {
                        customKelvin = min(max(customKelvin, r.lowerBound), r.upperBound)
                    }
                })) {
                    ForEach(scales) { Text($0.name).tag($0.id) }
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
            Toggle("Speed", isOn: $includeSpeed)
            if includeSpeed { IntSliderRow(label: "Speed", value: $speed, range: 10...200) }
        }
    }

    private var change: LightChange {
        var ch = LightChange()
        if includeColour {
            switch kind {
            case .rgbcw: ch.colour = .rgbcw(r: r, g: g, b: b, c: c, w: w)
            case .temp: ch.colour = .temp(temp)
            case .custom: ch.colour = scale.map { .customCCT(scale: $0.id, kelvin: customKelvin) }
            case .scene:
                switch scene {
                case .builtin(let id): ch.colour = .scene(id: id, speed: includeSpeed ? speed : nil)
                case .custom(let id): ch.colour = .custom(id, speed: includeSpeed ? speed : nil)
                }
            }
        }
        if includeDimming { ch.dimming = dimming }
        ch.power = switch power {
        case .leave: nil
        case .on: true
        case .off: false
        }
        ch.fade = fadeChoice.trans(setting: Model.fade, custom: fade)
        return ch
    }

    /// The chosen scale (while it still exists), else the one Custom CCT uses.
    private var scale: CCTScale? {
        let scales = model.library.scales(for: model.chosenMAC)
        return scales.first { $0.id == scaleID } ?? model.activeScale
    }

    /// The bulb's own fade-in, for the footer.
    private var ownFade: String {
        switch model.fadeIn {
        case 0?: ", which is off"
        case let ms?: " (\(ms) ms)"
        case nil: ""
        }
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
        // As Model.send: a fade only goes with a change or with switching on, never alone when
        // switching off.
        if let f = ch.fade, !parts.isEmpty || ch.power == true { parts.append("\"trans\":\(f)") }
        if parts.isEmpty && ch.power == true { return "setState {\"state\":true}" }
        if ch.power == false || (ch.power == nil && model.isOn == false && !parts.isEmpty) { parts.append("\"state\":false") }
        if parts.isEmpty { return "Nothing to send" }
        var text = "setPilot {" + parts.joined(separator: ",") + "}"
        switch ch.colour {
        case let .scene(_, s?)?, let .custom(_, s?)?: text += "\nthen setPilot {\"speed\":\(s)}"
        default: break
        }
        return text
    }

    private func load() {
        loaded = true
        r = Int(model.r); g = Int(model.g); b = Int(model.b); c = Int(model.c); w = Int(model.w)
        temp = Int(model.temp)
        customKelvin = Int(model.customKelvin)
        scaleID = model.activeScale?.id
        if let range = model.activeScale?.range { customKelvin = min(max(customKelvin, range.lowerBound), range.upperBound) }
        dimming = Int(model.dimming)
        scene = model.sceneChoice.wrappedValue
        speed = min(max(Int(model.speed), 10), 200)
        includeSpeed = false
        if case .builtin(let id) = scene, !Scenes.isKnown(id) { scene = .builtin(1) }
        if case .custom(let id) = scene, model.library.customScene(id) == nil { scene = .builtin(1) }
        kind = switch model.mode {
        case .rgbcw: .rgbcw
        case .temp: .temp
        case .custom: .custom
        case .scene: .scene
        }
        power = .leave
        // Start from the fade time setting, if there is one.
        fadeChoice = Model.fade == nil ? .none : .setting
    }
}
