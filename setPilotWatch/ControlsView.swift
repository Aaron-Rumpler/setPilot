import SwiftUI

/// A scene in the watch's picker: one of the bulb's or one of setPilot's.
enum WatchScene: Hashable {
    case builtin(Int)
    case custom(UUID)
}

/// Everything the iPhone app can set: mode, channels, temperatures, scales, scenes and speed,
/// brightness. Each value opens an editor (Digital Crown, − and +, or the keypad); changes go to
/// the iPhone as you go (see `PhoneLink.sendLive`).
struct ControlsView: View {
    let link: PhoneLink
    /// What's being edited; follows the bulb when nothing's waiting to be sent.
    @State private var values: LightValues?

    var body: some View {
        let s = link.snapshot
        List {
            ErrorRow(link: link)
            if let s, s.canControl, let v = values {
                if !link.reachable {
                    Text("Can't reach your iPhone: this is the last state it sent.")
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
                    .overlay {
                        if link.pending.contains("brightness") {
                            ProgressView().accessibilityLabel("Changing brightness")
                                .allowsHitTesting(false) // taps on the buttons' inner edges still land
                        }
                    }
                    .listRowBackground(Color.clear)
                    ValueRow(label: "Brightness", value: binding(\.dimming, .dimming), range: s.minDimming...100, unit: "%")
                }
                Section {
                    Picker("Mode", selection: Binding(get: { v.mode.choice }, set: { choice in
                        guard choice != v.mode.choice else { return }
                        // The iPhone decides Temperature's scale (as last used); its reply updates the controls.
                        link.send(.modeChoice(choice))
                    })) {
                        ForEach(ModeChoice.allCases) { Text($0.rawValue).tag($0) }
                    }
                    modeControls(s, v)
                }
                Section {
                    ControlsFadePicker(link: link, s: s)
                }
                Section {
                    Button { link.send(.sync) } label: { Label("Sync", systemImage: "arrow.clockwise") }
                }
                LastCommandSection(s: s)
            } else {
                Text(link.reachable ? (s?.link == .connected ? "The bulb's state isn't known yet." : "The bulb isn't connected on your iPhone.")
                                    : "Can't reach your iPhone.")
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Controls")
        .onAppear { follow(s) }
        .onChange(of: link.snapshot) { _, new in follow(new) }
        // Once the last live change has been answered, show the bulb's values again.
        .onChange(of: link.liveSettled) { follow(link.snapshot) }
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
            Picker("CCT Scale", selection: Binding(get: { v.mode == .custom ? s.activeScale : nil }, set: { id in
                link.send(.temperatureScale(id))
            })) {
                Text("Bulb's own").tag(UUID?.none)
                ForEach(scales) { Text($0.name).tag(Optional($0.id)) }
            }
            if v.mode == .custom, s.customMin < s.customMax {
                ValueRow(label: "Temperature", value: binding(\.customKelvin, .colour), range: s.customMin...s.customMax,
                         unit: " K", tint: ColourTemperature.color(kelvin: v.customKelvin))
            } else {
                ValueRow(label: "Temperature", value: binding(\.temp, .colour), range: s.tempMin...s.tempMax, unit: " K",
                         tint: ColourTemperature.color(kelvin: v.temp))
            }
        case .scene:
            Picker("Scene", selection: Binding(get: { currentScene(s, v) }, set: { choice in
                // The one playing again (a stored scene, listed only to show it): nothing to send.
                guard choice != currentScene(s, v) else { return }
                switch choice {
                case .builtin(let id):
                    update { $0.sceneId = id }
                    queue(.colour)
                case .custom(let id):
                    link.send(.playCustom(id, switchOn: false))
                }
            })) {
                // Not the bulb's stored scenes: they can't be judged for flashing, so not offered here.
                ForEach(Scenes.all.filter { !Scenes.isStoredSlot($0.id) }) { Text($0.name).tag(WatchScene.builtin($0.id)) }
                ForEach(link.scenes) { Text($0.name).tag(WatchScene.custom($0.id)) }
                // The light's own scene when it isn't listed above, so the picker still shows it.
                if (!Scenes.isKnown(v.sceneId) || Scenes.isStoredSlot(v.sceneId)) && currentScene(s, v) == .builtin(v.sceneId) {
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

    /// Takes the bulb's values, unless a live change is still on its way.
    private func follow(_ s: LightSnapshot?) {
        guard values == nil || !link.liveBusy, let s else { return }
        values = s.values
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

    /// Sends straight away, or once the change before it has been answered (see `sendLive`).
    private func queue(_ field: PilotField) {
        guard let v = values else { return }
        link.sendLive(v, fields: [field])
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
    @State private var includeSpeed = false
    @State private var speed = 100.0
    @State private var includeDimming = true
    @State private var dimming = 100.0
    @State private var power = Power.leave
    @State private var fadeChoice = FadeChoice.none
    @State private var fade = 10_000.0
    @State private var loaded = false

    var body: some View {
        let s = link.snapshot
        List {
            ErrorRow(link: link)
            Section {
                Toggle("Change Colour", isOn: $includeColour)
                if includeColour, let s {
                    Picker("Mode", selection: $kind) {
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
                        Picker("CCT Scale", selection: Binding(get: { scale(s)?.id }, set: { id in
                            scaleID = id
                            let r = kelvinRange(s)
                            kelvin = min(max(kelvin, r.lowerBound), r.upperBound)
                        })) {
                            Text("Bulb's own").tag(UUID?.none)
                            ForEach(s.scales ?? []) { Text($0.name).tag(Optional($0.id)) }
                        }
                        ValueRow(label: "Temperature", value: $kelvin, range: range, unit: " K",
                                 tint: ColourTemperature.color(kelvin: kelvin))
                    case .scenes:
                        Picker("Scene", selection: $scene) {
                            ForEach(Scenes.all.filter { !Scenes.isStoredSlot($0.id) }) { Text($0.name).tag(WatchScene.builtin($0.id)) }
                            ForEach(link.scenes) { Text($0.name).tag(WatchScene.custom($0.id)) }
                        }
                        Toggle("Change Speed", isOn: $includeSpeed)
                        if includeSpeed { ValueRow(label: "Speed", value: $speed, range: 10...200) }
                    }
                }
            }
            Section {
                Toggle("Change Brightness", isOn: $includeDimming)
                if includeDimming {
                    ValueRow(label: "Brightness", value: $dimming, range: (s?.minDimming ?? 10)...100, unit: "%")
                }
            }
            Section {
                Picker("Power", selection: $power) {
                    ForEach(Power.allCases) { Text($0.rawValue).tag($0) }
                }
            }
            Section {
                // The iPhone's fade time setting is the default, if it has one.
                // The setting gone meanwhile (turned off on the iPhone) shows as None, which is what's sent.
                Picker("Fade", selection: Binding(get: { fadeChoice == .setting && s?.fade == nil ? .none : fadeChoice },
                                                  set: { fadeChoice = $0 })) {
                    ForEach(FadeChoice.options(setting: s?.fade), id: \.self) { Text($0.title(setting: s?.fade)).tag($0) }
                }
                if fadeChoice == .custom {
                    ValueRow(label: "Fade time", value: $fade, range: 0...Double(Fade.maximum), unit: " ms")
                }
            }
            Section {
                Button {
                    // Closed once it's done: on an error the change stays to try again (as on iPhone).
                    link.send(.compose(change(s))) { ok in if ok { dismiss() } }
                } label: {
                    Label("Send", systemImage: "paperplane.fill")
                }
                .disabled(s?.canControl != true || change(s).isEmpty || change(s).allChannelsZero) // the bulb refuses all zeros
                Button { load() } label: { Label("From Bulb", systemImage: "arrow.uturn.backward") }
            } footer: {
                let ch = change(s)
                VStack(alignment: .leading, spacing: 4) {
                    // The scale's channels are worked out on the iPhone.
                    Text(ch.preview(isOn: s?.isOn, owedSpeed: s?.owedSpeed) { _, _ in nil })
                        .font(.system(.caption2, design: .monospaced))
                    if let note = ch.note(isOn: s?.isOn) { Text(note) }
                }
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
                // Within the range as it is now: the scale may have gone since it was chosen.
                let k = s.map { r in Int(min(max(kelvin, kelvinRange(r).lowerBound), kelvinRange(r).upperBound)) } ?? Int(kelvin)
                if let s, let chosen = scale(s) {
                    ch.colour = LightColour.customCCT(scale: chosen.id, kelvin: k)
                } else {
                    ch.colour = .temp(k)
                }
            case .scenes:
                switch scene {
                case .builtin(let id): ch.colour = .scene(id: id, speed: includeSpeed ? Int(speed) : nil)
                case .custom(let id): ch.colour = .custom(id, speed: includeSpeed ? Int(speed) : nil)
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
        speed = min(max(s.speed, 10), 200)
        includeSpeed = false
        power = .leave
        if let id = s.customScene, link.scenes.contains(where: { $0.id == id }) {
            scene = .custom(id)
        } else if Scenes.isKnown(s.sceneId), !Scenes.isStoredSlot(s.sceneId) {
            scene = .builtin(s.sceneId)
        }
        // A scene that can't be sent (Rhythm, a deleted custom scene, a stored one, which isn't
        // offered): Colour starts off, so a brightness change leaves it playing (as on the iPhone).
        let sendable = s.mode != .scene || (Scenes.isKnown(s.sceneId) && !Scenes.isStoredSlot(s.sceneId))
            || (s.customScene.map { id in link.scenes.contains { $0.id == id } } ?? false)
        includeColour = sendable
        kind = s.mode.choice
    }

    /// The chosen scale, while the bulb still has it; nil for the bulb's own.
    private func scale(_ s: LightSnapshot) -> ScaleSummary? { s.scales?.first { $0.id == scaleID } }

    private func kelvinRange(_ s: LightSnapshot) -> ClosedRange<Double> {
        if let chosen = scale(s), chosen.min < chosen.max { return chosen.min...chosen.max }
        return s.tempMin...s.tempMax
    }
}

/// The live controls' fade (the iPhone's setting for them): the fade time setting, none, or a
/// time of its own.
struct ControlsFadePicker: View {
    let link: PhoneLink
    let s: LightSnapshot
    @State private var ms: Double?
    @State private var sendTask: Task<Void, Never>?
    /// A turn of the Crown hasn't been sent yet.
    @State private var unsent = false

    var body: some View {
        let options = FadeChoice.options(setting: s.fade)
        let stored: FadeChoice = s.controlsFade ?? .setting
        // "The setting" isn't offered while there's no fade time setting; it then means none.
        let current: FadeChoice = stored == .setting && s.fade == nil ? FadeChoice.none : stored
        let time = ms ?? Double(s.controlsFadeMs ?? 1000)
        Picker("Fade", selection: Binding(get: { current }, set: { link.send(.controlsFade($0, ms: Int(time))) })) {
            ForEach(options, id: \.self) { Text($0.title(setting: s.fade)).tag($0) }
        }
        // Once the iPhone has it (or it changed there), show its value; not while a newer turn is
        // still to be sent, or the value would jump back to an older one. On the picker, so it's
        // followed whatever's chosen (or the next choice would send an old time back).
        .onChange(of: s.controlsFadeMs) { if !unsent { ms = nil } }
        if current == .custom {
            // Read when asked, not captured with this body: the pushed editor may keep the binding.
            ValueRow(label: "Fade time", value: Binding(get: {
                ms ?? Double(link.snapshot?.controlsFadeMs ?? s.controlsFadeMs ?? 1000)
            }, set: { new in
                ms = new
                unsent = true
                // Sent once the Crown pauses.
                sendTask?.cancel()
                sendTask = Task {
                    try? await Task.sleep(for: .milliseconds(350))
                    guard !Task.isCancelled else { return }
                    unsent = false
                    // Out of reach, it won't get there: show the iPhone's value again, not this one.
                    if !link.reachable { ms = nil }
                    link.send(.controlsFade(.custom, ms: Int(new)))
                }
            }), range: 0...Double(Fade.maximum), unit: " ms")
        }
    }
}

/// The last request the iPhone sent the bulb, and its status.
struct LastCommandSection: View {
    let s: LightSnapshot

    var body: some View {
        if let sent = s.lastSent {
            Section("Last Command") {
                VStack(alignment: .leading, spacing: 4) {
                    Text("\(s.lastMethod ?? "setPilot") \(sent)")
                        .font(.system(.caption2, design: .monospaced))
                    if s.mismatch == nil, !s.status.isEmpty {
                        Text(s.status).font(.caption2).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }
}
