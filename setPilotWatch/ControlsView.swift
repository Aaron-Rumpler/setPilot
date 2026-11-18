import SwiftUI

/// Everything the iPhone app can set: mode, channels or temperature, scene and speed, brightness.
/// Sliders take the Digital Crown; changes go to the iPhone once you pause.
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
                Section {
                    HStack {
                        Button { link.send(.dimDelta(-10)) } label: { Image(systemName: "sun.min") }
                            .accessibilityLabel("Dimmer")
                        Button { link.send(.dimDelta(10)) } label: { Image(systemName: "sun.max.fill") }
                            .accessibilityLabel("Brighter")
                    }
                    WatchSlider(label: "Brightness", value: binding(\.dimming, .dimming),
                                range: s.minDimming...100, step: 5, unit: "%")
                }
                Section {
                    Picker("Mode", selection: Binding(get: { v.mode }, set: { mode in
                        update { $0.mode = mode }
                        queue(.colour, now: true)
                    })) {
                        ForEach(Mode.allCases) { Text($0.rawValue).tag($0) }
                    }
                    switch v.mode {
                    case .rgbcw:
                        WatchSlider(label: "Red", value: binding(\.r, .colour), range: 0...255, step: 5, tint: .red)
                        WatchSlider(label: "Green", value: binding(\.g, .colour), range: 0...255, step: 5, tint: .green)
                        WatchSlider(label: "Blue", value: binding(\.b, .colour), range: 0...255, step: 5, tint: .blue)
                        WatchSlider(label: "Cool white", value: binding(\.c, .colour), range: 0...255, step: 5,
                                    tint: ColourTemperature.color(kelvin: 6500))
                        WatchSlider(label: "Warm white", value: binding(\.w, .colour), range: 0...255, step: 5,
                                    tint: ColourTemperature.color(kelvin: 2700))
                    case .temp:
                        WatchSlider(label: "Kelvin", value: binding(\.temp, .colour), range: s.tempMin...s.tempMax,
                                    step: 100, tint: ColourTemperature.color(kelvin: v.temp), unit: " K")
                    case .scene:
                        Picker("Scene", selection: Binding(get: { v.sceneId }, set: { id in
                            update { $0.sceneId = id }
                            queue(.colour, now: true)
                        })) {
                            ForEach(Scenes.all) { Text($0.name).tag($0.id) }
                            if !Scenes.isKnown(v.sceneId) {
                                Text(sceneName(v.sceneId, s)).tag(v.sceneId)
                            }
                        }
                        WatchSlider(label: "Speed", value: binding(\.speed, .speed), range: 10...200, step: 10)
                    }
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

    private func sceneName(_ id: Int, _ s: LightSnapshot) -> String {
        if id == Scenes.inlineCustom, let c = s.customScene, let scene = link.scenes.first(where: { $0.id == c }) {
            return scene.name
        }
        return Scenes.name(id)
    }

    /// Takes the bulb's values, unless an edit is waiting to go.
    private func follow(_ s: LightSnapshot?) {
        guard unsent.isEmpty, let s else { return }
        values = LightValues(mode: s.mode, r: s.r, g: s.g, b: s.b, c: s.c, w: s.w, temp: s.temp,
                             sceneId: s.sceneId, speed: s.speed, dimming: s.dimming)
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

/// A Crown-driven slider with its label and value.
struct WatchSlider: View {
    let label: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    var step: Double = 1
    var tint: Color? = nil
    var unit = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(label).font(.footnote)
                Spacer()
                Text(verbatim: "\(Int(value))\(unit)").font(.footnote.monospacedDigit()).foregroundStyle(.secondary)
            }
            Slider(value: $value, in: range, step: step) { Text(label) }
                .tint(tint)
        }
    }
}
