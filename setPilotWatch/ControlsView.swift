import SwiftUI

/// A scene in the watch's picker: one of the bulb's or one of setPilot's.
enum WatchScene: Hashable {
    case builtin(Int)
    case custom(UUID)
}

/// Everything the iPhone app can set: mode, channels, temperatures, scales, scenes and speed,
/// brightness. Each value opens an editor (Digital Crown, − and +, or the keypad); changes go to
/// the iPhone once you pause.
struct ControlsView: View {
    let link: PhoneLink
    /// What's being edited; follows the bulb when nothing's waiting to be sent.
    @State private var values: LightValues?
    @State private var unsent: Set<PilotField> = []
    @State private var sendTask: Task<Void, Never>?

    var body: some View {
        let s = link.snapshot
        List {
            if let s, s.canControl, let v = values {
                if !link.reachable {
                    Text("iPhone not reachable: this is the last state it sent.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .listRowBackground(Color.clear)
                }
                if let mismatch = s.mismatch { MismatchText(text: mismatch) }
                Section {
                    // Separate bordered buttons, so each takes its own taps in the row.
                    HStack {
                        Button { link.send(.dimDelta(-10)) } label: {
                            Image(systemName: "sun.min").frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                        .accessibilityLabel("Dimmer")
                        Button { link.send(.dimDelta(10)) } label: {
                            Image(systemName: "sun.max.fill").frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                        .accessibilityLabel("Brighter")
                    }
                    .listRowBackground(Color.clear)
                    ValueRow(label: "Brightness", value: binding(\.dimming, .dimming), range: s.minDimming...100, unit: "%")
                }
                Section {
                    Picker("Mode", selection: Binding(get: { v.mode.choice }, set: { choice in
                        guard choice != v.mode.choice else { return }
                        flush()
                        // The iPhone decides Temperature's scale (as last used); its reply updates the controls.
                        link.send(.modeChoice(choice))
                    })) {
                        ForEach(ModeChoice.allCases) { Text($0.rawValue).tag($0) }
                    }
                    modeControls(s, v)
                }
                Section {
                    Button { link.send(.sync) } label: { Label("Read from Bulb", systemImage: "arrow.clockwise") }
                }
            } else {
                Text(link.reachable ? (s?.link == .connected ? "The bulb's state isn't known yet." : "The bulb isn't connected on your iPhone.")
                                    : "Can't reach your iPhone.")
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Controls")
        .onAppear { follow(s) }
        .onChange(of: link.snapshot) { _, new in follow(new) }
        .onDisappear { flush() }
    }

    @ViewBuilder private func modeControls(_ s: LightSnapshot, _ v: LightValues) -> some View {
        switch v.mode {
        case .rgbcw:
            ValueRow(label: "Red", value: binding(\.r, .colour), range: 0...255, tint: .red)
            ValueRow(label: "Green", value: binding(\.g, .colour), range: 0...255, tint: .green)
            ValueRow(label: "Blue", value: binding(\.b, .colour), range: 0...255, tint: .blue)
            ValueRow(label: "Cool white", value: binding(\.c, .colour), range: 0...255,
                     tint: ColourTemperature.color(kelvin: 6500))
            ValueRow(label: "Warm white", value: binding(\.w, .colour), range: 0...255,
                     tint: ColourTemperature.color(kelvin: 2700))
        case .temp, .custom:
            let scales = s.scales ?? []
            Picker("Scale", selection: Binding(get: { v.mode == .custom ? s.activeScale : nil }, set: { id in
                flush()
                link.send(.temperatureScale(id))
            })) {
                Text("Bulb's own").tag(UUID?.none)
                ForEach(scales) { Text($0.name).tag(Optional($0.id)) }
            }
            if v.mode == .custom, s.customMin < s.customMax {
                ValueRow(label: "Kelvin", value: binding(\.customKelvin, .colour), range: s.customMin...s.customMax,
                         step: 10, unit: " K", tint: ColourTemperature.color(kelvin: v.customKelvin))
            } else {
                ValueRow(label: "Kelvin", value: binding(\.temp, .colour), range: s.tempMin...s.tempMax, step: 10, unit: " K",
                         tint: ColourTemperature.color(kelvin: v.temp))
            }
        case .scene:
            Picker("Scene", selection: Binding(get: { currentScene(s, v) }, set: { choice in
                switch choice {
                case .builtin(let id):
                    update { $0.sceneId = id }
                    queue(.colour, now: true)
                case .custom(let id):
                    link.send(.playCustom(id))
                }
            })) {
                ForEach(Scenes.all) { Text($0.name).tag(WatchScene.builtin($0.id)) }
                ForEach(link.scenes) { Text($0.name).tag(WatchScene.custom($0.id)) }
                if !Scenes.isKnown(v.sceneId) && currentScene(s, v) == .builtin(v.sceneId) {
                    Text(Scenes.name(v.sceneId)).tag(WatchScene.builtin(v.sceneId))
                }
            }
            ValueRow(label: "Speed", value: binding(\.speed, .speed), range: 10...200)
        }
    }

    private func currentScene(_ s: LightSnapshot, _ v: LightValues) -> WatchScene {
        if v.sceneId == Scenes.inlineCustom, let c = s.customScene, link.scenes.contains(where: { $0.id == c }) { return .custom(c) }
        return .builtin(v.sceneId)
    }

    /// Takes the bulb's values, unless an edit is waiting to go.
    private func follow(_ s: LightSnapshot?) {
        guard unsent.isEmpty, let s else { return }
        values = LightValues(mode: s.mode, r: s.r, g: s.g, b: s.b, c: s.c, w: s.w, temp: s.temp,
                             customKelvin: s.customKelvin, sceneId: s.sceneId, speed: s.speed, dimming: s.dimming)
    }

    private func update(_ change: (inout LightValues) -> Void) {
        guard var v = values else { return }
        change(&v)
        values = v
    }

    private func binding(_ kp: WritableKeyPath<LightValues, Double>, _ field: PilotField) -> Binding<Double> {
        Binding(
            get: { values?[keyPath: kp] ?? 0 },
            set: { new in
                update { $0[keyPath: kp] = new }
                queue(field)
            }
        )
    }

    /// Sends after a short pause, so turning the Crown doesn't send every step.
    private func queue(_ field: PilotField, now: Bool = false) {
        unsent.insert(field)
        sendTask?.cancel()
        sendTask = Task {
            if !now { try? await Task.sleep(for: .milliseconds(350)) }
            guard !Task.isCancelled else { return }
            flush()
        }
    }

    private func flush() {
        guard !unsent.isEmpty, let v = values else { return }
        link.send(.set(v, fields: Array(unsent)))
        unsent = []
    }
}

/// Prepares a change (any of colour, brightness and power, with its own fade time) and sends it
/// in one go.
struct WatchComposeView: View {
    let link: PhoneLink
    @Environment(\.dismiss) private var dismiss

    private enum Power: String, CaseIterable, Identifiable {
        case leave = "Leave", on = "On", off = "Off"
        var id: Self { self }
    }

    @State private var includeColour = true
    @State private var kind = ModeChoice.temperature
    @State private var r = 255.0
    @State private var g = 0.0
    @State private var b = 0.0
    @State private var c = 0.0
    @State private var w = 0.0
    @State private var kelvin = 2700.0
    /// Temperature's scale (nil: the bulb's own).
    @State private var scaleID: UUID?
    @State private var scene = WatchScene.builtin(1)
    @State private var includeDimming = true
    @State private var dimming = 100.0
    @State private var power = Power.leave
    @State private var fadeChoice = FadeChoice.none
    @State private var fade = 10_000.0
    @State private var loaded = false

    var body: some View {
        let s = link.snapshot
        List {
            Section {
                Toggle("Colour", isOn: $includeColour)
                if includeColour, let s {
                    Picker("Kind", selection: $kind) {
                        ForEach(ModeChoice.allCases) { Text($0.rawValue).tag($0) }
                    }
                    switch kind {
                    case .rgbcw:
                        ValueRow(label: "Red", value: $r, range: 0...255, tint: .red)
                        ValueRow(label: "Green", value: $g, range: 0...255, tint: .green)
                        ValueRow(label: "Blue", value: $b, range: 0...255, tint: .blue)
                        ValueRow(label: "Cool white", value: $c, range: 0...255, tint: ColourTemperature.color(kelvin: 6500))
                        ValueRow(label: "Warm white", value: $w, range: 0...255, tint: ColourTemperature.color(kelvin: 2700))
                    case .temperature:
                        let range = kelvinRange(s)
                        Picker("Scale", selection: Binding(get: { scale(s)?.id }, set: { id in
                            scaleID = id
                            let r = kelvinRange(s)
                            kelvin = min(max(kelvin, r.lowerBound), r.upperBound)
                        })) {
                            Text("Bulb's own").tag(UUID?.none)
                            ForEach(s.scales ?? []) { Text($0.name).tag(Optional($0.id)) }
                        }
                        ValueRow(label: "Kelvin", value: $kelvin, range: range, step: 10, unit: " K",
                                 tint: ColourTemperature.color(kelvin: kelvin))
                    case .scenes:
                        Picker("Scene", selection: $scene) {
                            ForEach(Scenes.all) { Text($0.name).tag(WatchScene.builtin($0.id)) }
                            ForEach(link.scenes) { Text($0.name).tag(WatchScene.custom($0.id)) }
                        }
                    }
                }
            }
            Section {
                Toggle("Brightness", isOn: $includeDimming)
                if includeDimming {
                    ValueRow(label: "Dimming", value: $dimming, range: (s?.minDimming ?? 10)...100, unit: "%")
                }
            }
            Section {
                Picker("Power", selection: $power) {
                    ForEach(Power.allCases) { Text($0.rawValue).tag($0) }
                }
            }
            Section {
                // The iPhone's fade time setting is the default, if it has one.
                Picker("Fade", selection: $fadeChoice) {
                    ForEach(FadeChoice.options(setting: s?.fade), id: \.self) { Text($0.title(setting: s?.fade)).tag($0) }
                }
                if fadeChoice == .custom {
                    ValueRow(label: "Fade time", value: $fade, range: 0...60_000, step: 100, unit: " ms")
                }
            } footer: {
                if power == .off { Text("Turning off uses the bulb's own fade-out.") }
            }
            Section {
                Button {
                    link.send(.compose(change(s)))
                    dismiss()
                } label: {
                    Label("Send", systemImage: "paperplane.fill")
                }
                .disabled(s?.canControl != true)
            }
        }
        .navigationTitle("Compose")
        .onAppear { if !loaded { load() } }
    }

    private func change(_ s: LightSnapshot?) -> LightChange {
        var ch = LightChange()
        if includeColour {
            switch kind {
            case .rgbcw: ch.colour = .rgbcw(r: Int(r), g: Int(g), b: Int(b), c: Int(c), w: Int(w))
            case .temperature:
                if let s, let chosen = scale(s) {
                    ch.colour = LightColour.customCCT(scale: chosen.id, kelvin: Int(kelvin))
                } else {
                    ch.colour = .temp(Int(kelvin))
                }
            case .scenes:
                switch scene {
                case .builtin(let id): ch.colour = .scene(id: id, speed: nil)
                case .custom(let id): ch.colour = .custom(id, speed: nil)
                }
            }
        }
        if includeDimming { ch.dimming = Int(dimming) }
        ch.power = switch power {
        case .leave: nil
        case .on: true
        case .off: false
        }
        ch.fade = fadeChoice.trans(setting: s?.fade, custom: Int(fade))
        return ch
    }

    private func load() {
        loaded = true
        guard let s = link.snapshot else { return }
        fadeChoice = s.fade == nil ? .none : .setting
        (r, g, b, c, w) = (s.r, s.g, s.b, s.c, s.w)
        if s.mode == .custom, let id = s.activeScale {
            scaleID = id
            kelvin = s.customKelvin
        } else {
            scaleID = nil
            kelvin = s.temp
        }
        let range = kelvinRange(s)
        kelvin = min(max(kelvin, range.lowerBound), range.upperBound)
        dimming = s.dimming
        if let id = s.customScene, link.scenes.contains(where: { $0.id == id }) {
            scene = .custom(id)
        } else if Scenes.isKnown(s.sceneId) {
            scene = .builtin(s.sceneId)
        }
        kind = s.mode.choice
    }

    /// The chosen scale, while the bulb still has it; nil for the bulb's own.
    private func scale(_ s: LightSnapshot) -> ScaleSummary? { s.scales?.first { $0.id == scaleID } }

    private func kelvinRange(_ s: LightSnapshot) -> ClosedRange<Double> {
        if let chosen = scale(s), chosen.min < chosen.max { return chosen.min...chosen.max }
        return s.tempMin...s.tempMax
    }
}
