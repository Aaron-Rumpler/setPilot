import SwiftUI

/// Edits one custom scene: its name and steps (1–12), with a Play button.
struct CustomSceneEditor: View {
    let model: Model
    let sceneID: UUID

    var body: some View {
        if let binding = sceneBinding {
            Form {
                Section {
                    TextField("Name", text: binding.name)
                    HStack {
                        Button {
                            // At speed 100, so the preview shows the steps as timed.
                            if let scene = model.library.customScene(sceneID) { model.playCustom(scene, speed: 100) }
                        } label: {
                            Label(isPlaying ? "Play Again" : "Play on Bulb", systemImage: "play.fill")
                        }
                        .disabled(!model.canControl)
                        if isPlaying {
                            Label("Playing", systemImage: "waveform")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }
                    }
                } footer: {
                    Text("The bulb steps through these in order and repeats. Changes take effect the next time it's played. The bulb can't store or read back setPilot's scenes, so they're kept on this device.")
                }
                // Live, while previewing: the two settings that apply to a playing scene.
                Section {
                    LiveSlider(label: "Speed", range: 10...200, value: model.binding(\.speed))
                    LiveSlider(label: "Dimming", range: model.minDimming...100, unit: "%", value: model.binding(\.dimming))
                } header: {
                    Text("Preview")
                } footer: {
                    Text("Sent straight away, as with the main controls. Speed only applies while a scene is playing.")
                }
                .disabled(!model.canControl)
                ForEach(binding.steps) { $step in
                    let i = binding.wrappedValue.steps.firstIndex { $0.id == step.id } ?? 0
                    Section {
                        StepEditor(step: $step, kelvinRange: Int(model.tempRange.lowerBound)...Int(model.tempRange.upperBound),
                                   levelRange: Int(model.minDimming)...100)
                    } header: {
                        HStack {
                            Text("Step \(i + 1)")
                            Spacer()
                            stepMenu(binding, index: i)
                        }
                    }
                }
                Section {
                    Button {
                        var copy = binding.wrappedValue.steps.last ?? CustomScene.Step()
                        copy.id = UUID()
                        binding.wrappedValue.steps.append(copy)
                    } label: {
                        Label("Add Step", systemImage: "plus")
                    }
                    .disabled(binding.wrappedValue.steps.count >= CustomScene.maxSteps)
                } footer: {
                    Text("Up to \(CustomScene.maxSteps) steps.")
                }
            }
            .formStyle(.grouped)
            .navigationTitle(binding.wrappedValue.name)
        } else {
            Text("No scene selected").foregroundStyle(.secondary)
        }
    }

    private var isPlaying: Bool {
        model.mode == .scene && model.sceneId == Scenes.inlineCustom && model.customSceneId == sceneID
    }

    private var sceneBinding: Binding<CustomScene>? {
        let lib = model.library
        guard let scene = lib.customScene(sceneID) else { return nil }
        return Binding(
            get: { lib.customScene(sceneID) ?? scene },
            set: { new in
                if let i = lib.customScenes.firstIndex(where: { $0.id == sceneID }) { lib.customScenes[i] = new }
            }
        )
    }

    private func stepMenu(_ scene: Binding<CustomScene>, index i: Int) -> some View {
        Menu {
            Button("Duplicate") {
                var copy = scene.wrappedValue.steps[i]
                copy.id = UUID()
                scene.wrappedValue.steps.insert(copy, at: i + 1)
            }
            .disabled(scene.wrappedValue.steps.count >= CustomScene.maxSteps)
            Button("Move Up") { scene.wrappedValue.steps.swapAt(i, i - 1) }.disabled(i == 0)
            Button("Move Down") { scene.wrappedValue.steps.swapAt(i, i + 1) }
                .disabled(i >= scene.wrappedValue.steps.count - 1)
            Button("Delete", role: .destructive) { scene.wrappedValue.steps.remove(at: i) }
                .disabled(scene.wrappedValue.steps.count <= 1)
        } label: {
            Image(systemName: "ellipsis.circle")
        }
        .menuStyle(.button)
        .buttonStyle(.borderless)
        .fixedSize()
        .accessibilityLabel("Step \(i + 1) actions")
    }
}

/// One keyframe: colour (RGBCW or a temperature), level, hold and fade.
struct StepEditor: View {
    @Binding var step: CustomScene.Step
    /// The bulb's colour-temperature range (from getModelConfig; 2200–6500 K until it's known).
    var kelvinRange = 2200...6500
    /// The bulb's minimum dimming to 100 (10–100 until it's known).
    var levelRange = 10...100

    var body: some View {
        HStack {
            Picker("Colour", selection: $step.useTemp) {
                Text("RGBCW").tag(false)
                Text("Temperature").tag(true)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            RoundedRectangle(cornerRadius: 5)
                .fill((step.colour.swatch?.color ?? .black).opacity(Double(max(step.level, 15)) / 100))
                .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(.separator))
                .frame(width: 36, height: 22)
                .accessibilityHidden(true)
        }
        if step.useTemp {
            IntSliderRow(label: "Kelvin", value: $step.temp, range: kelvinRange, kelvin: true,
                         tint: ColourTemperature.color(kelvin: Double(step.temp)))
        } else {
            IntSliderRow(label: "Red", value: $step.r, range: 0...255, tint: .red)
            IntSliderRow(label: "Green", value: $step.g, range: 0...255, tint: .green)
            IntSliderRow(label: "Blue", value: $step.b, range: 0...255, tint: .blue)
            IntSliderRow(label: "Cool white", value: $step.c, range: 0...255, tint: ColourTemperature.color(kelvin: 6500))
            IntSliderRow(label: "Warm white", value: $step.w, range: 0...255, tint: ColourTemperature.color(kelvin: 2700))
        }
        IntSliderRow(label: "Level", value: $step.level, range: levelRange, unit: "%")
        MillisecondsRow(label: "Hold", value: $step.hold)
        MillisecondsRow(label: "Fade", value: $step.fade)
    }
}

/// A labelled slider row, the same as the main controls' (Mac: `ChannelSlider`, with a number field
/// and stepper; iPhone: `MobileSlider`, with − and + and the value popover): round-step snapping,
/// fine drags, typing a value. `kelvin` gives it the mired scale and colour-temperature track.
struct LiveSlider: View {
    let label: String
    var tint: Color? = nil
    let range: ClosedRange<Double>
    var unit = ""
    var kelvin = false
    @Binding var value: Double

    var body: some View {
        #if os(macOS)
        ChannelSlider(label: label, tint: kelvin ? nil : tint, range: range,
                      marks: kelvin ? [2200, 2700, 4200, 6500] : [], scale: kelvin ? .mired : .linear,
                      colourTemperatureStrip: kelvin, value: $value)
        #else
        MobileSlider(label: label, tint: tint, range: range, mired: kelvin, unit: unit, value: $value)
        #endif
    }
}

/// `LiveSlider` for a whole number.
struct IntSliderRow: View {
    let label: String
    @Binding var value: Int
    let range: ClosedRange<Int>
    var unit = ""
    var kelvin = false
    var tint: Color? = nil

    var body: some View {
        LiveSlider(label: label, tint: tint, range: Double(range.lowerBound)...Double(range.upperBound), unit: unit,
                   kelvin: kelvin, value: Binding(get: { Double(value) }, set: { value = Int($0.rounded()) }))
    }
}

/// A time in milliseconds, typed.
struct MillisecondsRow: View {
    let label: String
    @Binding var value: Int

    var body: some View {
        HStack {
            Text(label).frame(width: 100, alignment: .leading)
            TextField(label, value: Binding(get: { value }, set: { value = max(0, $0) }), format: .number.grouping(.never))
                .labelsHidden()
                .multilineTextAlignment(.trailing)
                #if os(iOS)
                .keyboardType(.numberPad)
                #endif
            Text("ms").foregroundStyle(.secondary)
        }
    }
}

/// The list of custom scenes with add, duplicate, play and delete.
struct CustomSceneRow: View {
    let scene: CustomScene

    var body: some View {
        HStack(spacing: 10) {
            RoundedRectangle(cornerRadius: 4)
                .fill((scene.swatch?.color ?? .gray).gradient)
                .frame(width: 22, height: 22)
            VStack(alignment: .leading, spacing: 1) {
                Text(scene.name)
                Text("\(scene.steps.count) step\(scene.steps.count == 1 ? "" : "s")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

extension Library {
    @discardableResult
    func addCustomScene() -> CustomScene {
        let scene = CustomScene.new(name: uniqueSceneName("New Scene"))
        customScenes.append(scene)
        return scene
    }

    @discardableResult
    func duplicate(_ scene: CustomScene) -> CustomScene {
        var copy = scene
        copy.id = UUID()
        copy.name = uniqueSceneName(scene.name)
        copy.steps = scene.steps.map { var s = $0; s.id = UUID(); return s }
        let i = customScenes.firstIndex { $0.id == scene.id }.map { $0 + 1 } ?? customScenes.endIndex
        customScenes.insert(copy, at: i)
        return copy
    }
}
