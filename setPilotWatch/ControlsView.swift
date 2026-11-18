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
                    Picker("Mode", selection: Binding(get: { v.mode }, set: { mode in
                        update { $0.mode = mode }
                        queue(.colour, now: true)
                    })) {
                        // Custom CCT only if the bulb has a scale (set up on the iPhone or Mac)
                        ForEach(Mode.allCases.filter { $0 != .custom || !(s.scales ?? []).isEmpty }) { Text($0.rawValue).tag($0) }
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
        case .temp:
            ValueRow(label: "Kelvin", value: binding(\.temp, .colour), range: s.tempMin...s.tempMax, step: 10, unit: " K",
                     tint: ColourTemperature.color(kelvin: v.temp))
        case .custom:
            if let scales = s.scales, !scales.isEmpty {
                Picker("Scale", selection: Binding(get: { s.activeScale ?? scales[0].id }, set: { link.send(.useScale($0)) })) {
                    ForEach(scales) { Text($0.name).tag($0.id) }
                }
                if s.customMin < s.customMax {
                    ValueRow(label: "Kelvin", value: binding(\.customKelvin, .colour), range: s.customMin...s.customMax,
                             step: 10, unit: " K", tint: ColourTemperature.color(kelvin: v.customKelvin))
                }
            } else {
                Text("Set up a CCT scale in setPilot on your iPhone or Mac.").foregroundStyle(.secondary)
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

    private enum Kind: String, CaseIterable, Identifiable {
        case rgbcw = "RGBCW", temp = "Temperature", custom = "Custom CCT", scene = "Scene"
        var id: Self { self }
    }

    private enum Power: String, CaseIterable, Identifiable {
        case leave = "Leave", on = "On", off = "Off"
        var id: Self { self }
    }

    @State private var includeColour = true
    @State private var kind = Kind.temp
    @State private var r = 255.0
    @State private var g = 0.0
    @State private var b = 0.0
    @State private var c = 0.0
    @State private var w = 0.0
    @State private var temp = 2700.0
    @State private var customKelvin = 2700.0
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
                        ForEach(Kind.allCases.filter { $0 != .custom || s.activeScale != nil }) { Text($0.rawValue).tag($0) }
                    }
                    switch kind {
                    case .rgbcw:
                        ValueRow(label: "Red", value: $r, range: 0...255, tint: .red)
                        ValueRow(label: "Green", value: $g, range: 0...255, tint: .green)
                        ValueRow(label: "Blue", value: $b, range: 0...255, tint: .blue)
                        ValueRow(label: "Cool white", value: $c, range: 0...255, tint: ColourTemperature.color(kelvin: 6500))
                        ValueRow(label: "Warm white", value: $w, range: 0...255, tint: ColourTemperature.color(kelvin: 2700))
                    case .temp:
                        ValueRow(label: "Kelvin", value: $temp, range: s.tempMin...s.tempMax, step: 10, unit: " K",
                                 tint: ColourTemperature.color(kelvin: temp))
                    case .custom:
                        if s.customMin < s.customMax {
                            ValueRow(label: s.scales?.first { $0.id == s.activeScale }?.name ?? "Kelvin", value: $customKelvin,
                                     range: s.customMin...s.customMax, step: 10, unit: " K",
                                     tint: ColourTemperature.color(kelvin: customKelvin))
                        }
                    case .scene:
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
            case .temp: ch.colour = .temp(Int(temp))
            case .custom: ch.colour = s?.activeScale.map { .customCCT(scale: $0, kelvin: Int(customKelvin)) }
            case .scene:
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
        temp = s.temp
        customKelvin = min(max(s.customKelvin, s.customMin), s.customMax)
        dimming = s.dimming
        if let id = s.customScene, link.scenes.contains(where: { $0.id == id }) {
            scene = .custom(id)
        } else if Scenes.isKnown(s.sceneId) {
            scene = .builtin(s.sceneId)
        }
        kind = switch s.mode {
        case .rgbcw: .rgbcw
        case .temp: .temp
        case .custom: s.activeScale == nil ? .temp : .custom
        case .scene: .scene
        }
    }
}
