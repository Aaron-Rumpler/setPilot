import SwiftUI
#if os(macOS)
import AppKit
#endif

/// Edits one custom scene: its name and steps (1–12), with a Play button.
struct CustomSceneEditor: View {
    @Environment(\.confirmFlashing) private var confirmFlashing
    let model: Model
    let sceneID: UUID
    /// The step being edited (the first, until one is chosen).
    @State private var selected: UUID?
    /// The step inspector: open from the start beside the scene on the Mac; on iPhone (a sheet)
    /// when a step is tapped.
    #if os(macOS)
    @State private var showsStep = true
    #else
    @State private var showsStep = false
    #endif
    @AppStorage(Flashing.warnKey) private var warnsFlashing = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        if let binding = sceneBinding {
            Form {
                Section {
                    NameField(name: binding.name, untitled: "Untitled Scene")
                    HStack {
                        Button {
                            // At speed 100, so the preview shows the steps as timed. On the Mac, a
                            // number being typed reaches the step only once its field ends editing.
                            #if os(macOS)
                            NSApp.keyWindow?.makeFirstResponder(nil)
                            #endif
                            DispatchQueue.main.async {
                                if let scene = model.library.customScene(sceneID) {
                                    confirmFlashing(scene.name, flashes: scene.flashes) { model.playCustom(scene, speed: 100) }
                                }
                            }
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
                    VStack(alignment: .leading, spacing: 6) {
                        if warnsFlashing, Flashing.flashes(binding.wrappedValue) {
                            Label(Flashing.warning, systemImage: "exclamationmark.triangle.fill")
                                .foregroundStyle(.orange)
                        } else if warnsFlashing, Flashing.flashes(binding.wrappedValue, speed: 200) {
                            // As timed it doesn't; played faster (a speed over 100) it can.
                            Label(Flashing.fasterWarning, systemImage: "exclamationmark.triangle")
                                .foregroundStyle(.orange)
                        }
                        Text("The bulb steps through these in order and repeats. Changes take effect the next time it's played. The bulb can't store or read back setPilot's scenes, so they're kept on this device.")
                    }
                }
                Section {
                    Picker("Timing", selection: binding.timing) {
                        ForEach(CustomScene.Timing.allCases, id: \.self) { Text($0.name).tag($0) }
                    }
                    Picker("Start At", selection: startStep(binding)) {
                        ForEach(binding.wrappedValue.steps.indices, id: \.self) { Text("Step \($0 + 1)").tag($0) }
                    }
                } header: {
                    Text("Playback")
                } footer: {
                    Text(binding.wrappedValue.timing == .steps
                         ? "Each step holds and fades for as long as it says."
                         : "The bulb uses these times for every step instead of their own.")
                }
                // Live, while previewing: the two settings that apply to a playing scene.
                Section {
                    LiveSlider(label: "Speed", range: 10...200, value: model.binding(\.speed))
                    LiveSlider(label: "Brightness", range: model.minDimming...100, unit: "%", value: model.binding(\.dimming))
                } header: {
                    Text("Preview")
                } footer: {
                    Text("Sent straight away, as with the main controls. Speed only applies while a scene is playing.")
                }
                .disabled(!model.canControl)
                // The steps as a strip of chips; only the chosen one's settings below, so moving
                // between steps doesn't mean scrolling past every other step's.
                Section {
                    stepStrip(binding)
                } header: {
                    Text("Steps")
                } footer: {
                    Text("Up to \(CustomScene.maxSteps) steps. Level dims steps of only warm or cool white; most colours look much the same until it's very low. To dim the whole scene, use Brightness above.")
                }
            }
            .formStyle(.grouped)
            .navigationTitle(binding.wrappedValue.name)
            // The chosen step's settings, beside the scene (on iPhone, a sheet).
            .inspector(isPresented: $showsStep) {
                Form { stepSection(binding) }
                    .formStyle(.grouped)
                    .inspectorColumnWidth(min: 300, ideal: 360, max: 520)
            }
            .toolbar {
                ToolbarItem {
                    Button { showsStep.toggle() } label: { Label("Step", systemImage: "sidebar.trailing") }
                        .help("Show or hide the chosen step's settings")
                }
            }
        } else {
            Text("No scene selected").foregroundStyle(.secondary)
        }
    }

    /// The chosen step: its place, previous and next, its actions, and its settings.
    @ViewBuilder private func stepSection(_ binding: Binding<CustomScene>) -> some View {
        if let i = selectedIndex(binding.wrappedValue) {
            let id = binding.wrappedValue.steps[i].id
            Section {
                StepEditor(step: stepBinding(binding, id),
                           kelvinRange: Int(model.tempRange.lowerBound)...Int(model.tempRange.upperBound),
                           levelRange: 0...100,
                           ownTiming: binding.wrappedValue.timing == .steps)
                    .id(id)
            } header: {
                HStack(spacing: 10) {
                    Text("Step \(i + 1) of \(binding.wrappedValue.steps.count)")
                    Spacer()
                    Button {
                        selectStep(binding, from: id, by: -1)
                    } label: {
                        Image(systemName: "chevron.left")
                    }
                    .disabled(i == 0)
                    .keyboardShortcut("[", modifiers: .command)
                    .help("Previous step (⌘[)")
                    .accessibilityLabel("Previous step")
                    Button {
                        selectStep(binding, from: id, by: 1)
                    } label: {
                        Image(systemName: "chevron.right")
                    }
                    .disabled(i >= binding.wrappedValue.steps.count - 1)
                    .keyboardShortcut("]", modifiers: .command)
                    .help("Next step (⌘])")
                    .accessibilityLabel("Next step")
                    stepMenu(binding, index: i, id: id)
                }
                .buttonStyle(.borderless)
            }
        }
    }

    /// The chosen step's place, or the first step's.
    private func selectedIndex(_ scene: CustomScene) -> Int? {
        guard !scene.steps.isEmpty else { return nil }
        return scene.steps.firstIndex { $0.id == selected } ?? 0
    }

    /// One step, looked up by its ID each time (the steps can change under it: iCloud, moves).
    private func stepBinding(_ scene: Binding<CustomScene>, _ id: UUID) -> Binding<CustomScene.Step> {
        let fallback = scene.wrappedValue.steps.first { $0.id == id } ?? CustomScene.Step()
        return Binding(
            get: { scene.wrappedValue.steps.first { $0.id == id } ?? fallback },
            set: { new in
                if let i = scene.wrappedValue.steps.firstIndex(where: { $0.id == id }) { scene.wrappedValue.steps[i] = new }
            }
        )
    }

    /// Every step as a chip (its colour, number and times); click one to edit it.
    private func stepStrip(_ scene: Binding<CustomScene>) -> some View {
        let steps = scene.wrappedValue.steps
        let current = selectedIndex(scene.wrappedValue)
        let start = min(max(scene.wrappedValue.startStep, 0), max(steps.count - 1, 0))
        return ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: true) {
                HStack(spacing: 8) {
                    ForEach(Array(steps.enumerated()), id: \.element.id) { i, step in
                        Button {
                            selected = step.id
                            showsStep = true
                        } label: {
                            StepChip(step: step, number: i + 1, isStart: i == start, isSelected: i == current,
                                     ownTiming: scene.wrappedValue.timing == .steps)
                        }
                        .buttonStyle(.plain)
                        .id(step.id)
                        .accessibilityLabel("Step \(i + 1)\(i == start ? ", the start" : "")")
                        .accessibilityValue(step.spokenSummary(ownTiming: scene.wrappedValue.timing == .steps))
                        .accessibilityHint("Shows the step's settings")
                        .accessibilityAddTraits(i == current ? .isSelected : [])
                    }
                    Button {
                        addStep(scene)
                    } label: {
                        Image(systemName: "plus")
                            .font(.title3)
                            .frame(width: 44, height: 64)
                            .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(steps.count >= CustomScene.maxSteps)
                    .help("Add a step after the chosen one (a copy of it)")
                    .accessibilityLabel("Add step")
                }
                .padding(.vertical, 4)
            }
            .onChange(of: selected) { _, id in
                guard let id else { return }
                withAnimation(reduceMotion ? nil : .default) { proxy.scrollTo(id) }
            }
        }
    }

    /// Selects the step `offset` away from `id`, found as the steps are now (they can change under
    /// the view: iCloud).
    private func selectStep(_ scene: Binding<CustomScene>, from id: UUID, by offset: Int) {
        let steps = scene.wrappedValue.steps
        guard let i = steps.firstIndex(where: { $0.id == id }), steps.indices.contains(i + offset) else { return }
        selected = steps[i + offset].id
    }

    /// A copy of the chosen step, after it, and chosen.
    private func addStep(_ scene: Binding<CustomScene>) {
        guard scene.wrappedValue.steps.count < CustomScene.maxSteps else { return }
        let i = selectedIndex(scene.wrappedValue) ?? scene.wrappedValue.steps.count - 1
        var copy = scene.wrappedValue.steps.indices.contains(i) ? scene.wrappedValue.steps[i] : CustomScene.Step()
        copy.id = UUID()
        let at = min(i + 1, scene.wrappedValue.steps.count)
        scene.wrappedValue.steps.insert(copy, at: at)
        if scene.wrappedValue.startStep >= at, at < scene.wrappedValue.steps.count - 1 { scene.wrappedValue.startStep += 1 }
        selected = copy.id
    }

    /// The start step, kept to one of the steps.
    private func startStep(_ scene: Binding<CustomScene>) -> Binding<Int> {
        Binding(
            get: { min(max(scene.wrappedValue.startStep, 0), scene.wrappedValue.steps.count - 1) },
            set: { scene.wrappedValue.startStep = $0 }
        )
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

    /// The step's actions. Each looks the step up again by `id` when chosen, as the steps can
    /// change while the menu is open (iCloud).
    private func stepMenu(_ scene: Binding<CustomScene>, index: Int, id: UUID) -> some View {
        let i = index
        return Menu {
            Button("Duplicate") {
                // Checked again here: the steps can change while the menu is open.
                guard scene.wrappedValue.steps.count < CustomScene.maxSteps,
                      let i = scene.wrappedValue.steps.firstIndex(where: { $0.id == id }) else { return }
                var copy = scene.wrappedValue.steps[i]
                copy.id = UUID()
                scene.wrappedValue.steps.insert(copy, at: i + 1)
                if scene.wrappedValue.startStep > i { scene.wrappedValue.startStep += 1 }
                selected = copy.id
            }
            .disabled(scene.wrappedValue.steps.count >= CustomScene.maxSteps)
            Button("Start Here") {
                if let i = scene.wrappedValue.steps.firstIndex(where: { $0.id == id }) { scene.wrappedValue.startStep = i }
            }
            .disabled(scene.wrappedValue.startStep == i)
            Button("Move Left") { move(scene, id, by: -1) }.disabled(i == 0)
            Button("Move Right") { move(scene, id, by: 1) }
                .disabled(i >= scene.wrappedValue.steps.count - 1)
            Button("Delete", role: .destructive) {
                guard scene.wrappedValue.steps.count > 1,
                      let i = scene.wrappedValue.steps.firstIndex(where: { $0.id == id }) else { return }
                scene.wrappedValue.steps.remove(at: i)
                if scene.wrappedValue.startStep > i { scene.wrappedValue.startStep -= 1 }
                scene.wrappedValue.startStep = min(scene.wrappedValue.startStep, scene.wrappedValue.steps.count - 1)
                selected = scene.wrappedValue.steps[min(i, scene.wrappedValue.steps.count - 1)].id
            }
            .disabled(scene.wrappedValue.steps.count <= 1)
        } label: {
            Image(systemName: "ellipsis.circle")
        }
        .menuStyle(.button)
        .buttonStyle(.borderless)
        .fixedSize()
        .accessibilityLabel("Step \(i + 1) actions")
    }

    /// Swaps a step with the one before (-1) or after (1), the start step going with its step.
    private func move(_ scene: Binding<CustomScene>, _ id: UUID, by offset: Int) {
        guard let i = scene.wrappedValue.steps.firstIndex(where: { $0.id == id }) else { return }
        let j = i + offset
        guard scene.wrappedValue.steps.indices.contains(j) else { return }
        scene.wrappedValue.steps.swapAt(i, j)
        let start = scene.wrappedValue.startStep
        if start == i { scene.wrappedValue.startStep = j } else if start == j { scene.wrappedValue.startStep = i }
    }
}

/// One keyframe: colour (RGBCW, a temperature, or dark), level, hold and fade, and how much the
/// hold and fade vary.
struct StepEditor: View {
    @Binding var step: CustomScene.Step
    /// The bulb's colour-temperature range (from getModelConfig; 2200–6500 K until it's known).
    var kelvinRange = 2200...6500
    /// The step's level: 0–100. It scales the channels before the bulb's dimming, so the bulb's
    /// minimum dimming doesn't apply to it.
    var levelRange = 0...100
    /// The scene uses each step's hold and fade (not one of the bulb's fixed timings).
    var ownTiming = true

    var body: some View {
        HStack {
            Picker("Colour", selection: $step.kind) {
                Text("RGBCW").tag(CustomScene.Step.Kind.rgbcw)
                Text("Temperature").tag(CustomScene.Step.Kind.temperature)
                Text("Dark").tag(CustomScene.Step.Kind.dark)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            RoundedRectangle(cornerRadius: 5)
                .fill((step.colour.swatch?.color ?? .black).opacity(Double(max(step.level, 15)) / 100))
                .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(.separator))
                .frame(width: 36, height: 22)
                .accessibilityElement()
                .accessibilityLabel("Step colour")
                .accessibilityValue(step.spokenColour)
        }
        if step.dark {
            Text("No light: every channel at 0.")
                .font(.callout)
                .foregroundStyle(.secondary)
        } else if step.useTemp {
            IntSliderRow(label: "Temperature", value: $step.temp, range: kelvinRange, kelvin: true,
                         tint: ColourTemperature.color(kelvin: Double(step.temp)))
        } else {
            IntSliderRow(label: "Red", value: $step.r, range: 0...255, tint: .red)
            IntSliderRow(label: "Green", value: $step.g, range: 0...255, tint: .green)
            IntSliderRow(label: "Blue", value: $step.b, range: 0...255, tint: .blue)
            IntSliderRow(label: "Cool white", value: $step.c, range: 0...255, tint: ColourTemperature.color(kelvin: 6500))
            IntSliderRow(label: "Warm white", value: $step.w, range: 0...255, tint: ColourTemperature.color(kelvin: 2700))
        }
        if !step.dark {
            IntSliderRow(label: "Level", value: $step.level, range: levelRange, unit: "%")
        }
        Group {
            MillisecondsRow(label: "Hold", value: $step.hold)
            MillisecondsRow(label: "Fade", value: $step.fade)
        }
        .disabled(!ownTiming)
        // Tucked away unless the step uses it.
        DisclosureGroup(isExpanded: $showsVariation) {
            Picker("Vary Hold", selection: $step.holdJitter) {
                ForEach(CustomScene.Step.holdJitters, id: \.self) { Text(Self.jitterName($0)).tag($0) }
            }
            Picker("Vary Fade", selection: $step.fadeJitter) {
                ForEach(CustomScene.Step.fadeJitters, id: \.self) { Text(Self.jitterName($0)).tag($0) }
            }
            if step.jitters {
                Picker("How Often", selection: $step.jitterChance) {
                    ForEach(CustomScene.Step.jitterChances, id: \.self) {
                        Text($0 == 100 ? "Every Time" : "\($0)% of the Time").tag($0)
                    }
                }
            }
        } label: {
            LabeledContent("Random Variation", value: step.jitters ? "On" : "None")
        }
        .onAppear { showsVariation = step.jitters }
    }

    @State private var showsVariation = false

    /// Random variation, either way, each time the step plays.
    private static func jitterName(_ percent: Int) -> String {
        percent == 0 ? "None" : "Up to ±\(percent)%"
    }
}

/// A step in the scene editor's strip: its colour (at its level), number and times.
struct StepChip: View {
    let step: CustomScene.Step
    let number: Int
    var isStart = false
    var isSelected = false
    /// The scene uses each step's own times (otherwise they're not shown).
    var ownTiming = true

    var body: some View {
        VStack(spacing: 3) {
            RoundedRectangle(cornerRadius: 6)
                .fill(step.dark ? Color.black : (step.colour.swatch?.color ?? .black).opacity(Double(max(step.level, 15)) / 100))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.separator))
                .overlay {
                    if step.dark { Image(systemName: "moon.fill").font(.caption2).foregroundStyle(.white.opacity(0.7)) }
                }
                .overlay(alignment: .topLeading) {
                    if isStart {
                        Image(systemName: "play.fill")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundStyle(.white)
                            .padding(3)
                            .background(Color.accentColor, in: Circle())
                            .padding(2)
                            .help("The scene starts here")
                    }
                }
                .frame(width: 52, height: 30)
            Text(verbatim: "\(number)").font(.caption.weight(.semibold))
            Text(verbatim: ownTiming ? "\(Self.seconds(step.hold)) + \(Self.seconds(step.fade))" : " ")
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .padding(5)
        .background(isSelected ? Color.accentColor.opacity(0.18) : .clear, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(isSelected ? Color.accentColor : .clear, lineWidth: 1.5))
        .contentShape(Rectangle())
        .help(ownTiming ? "Hold \(Self.seconds(step.hold)), then fade \(Self.seconds(step.fade))" : "")
    }

    /// "1.5s", "0.4s", "12s"; under a tenth of a second, "40ms" (not "0s").
    static func seconds(_ ms: Int) -> String {
        if ms > 0, ms < 100 { return "\(ms)ms" }
        let s = (Double(ms) / 100).rounded() / 10 // tenths first: 1999 is "2s", 9960 "10s"
        return s >= 10 || s == s.rounded() ? "\(Int(s.rounded()))s" : String(format: "%.1fs", s)
    }
}

/// A name field that doesn't leave a name empty: emptied and left, it's given `untitled`
/// (a blank row and picker item otherwise).
struct NameField: View {
    @Binding var name: String
    let untitled: String
    @FocusState private var focused: Bool

    var body: some View {
        TextField("Name", text: $name)
            .focused($focused)
            .onChange(of: focused) { _, now in if !now { fill() } }
            .onDisappear { fill() }
    }

    private func fill() {
        if name.trimmingCharacters(in: .whitespaces).isEmpty { name = untitled }
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
    /// At least this wide, so the rows line up; wider with larger text (iPhone and iPad).
    @ScaledMetric private var labelWidth: CGFloat = 100

    var body: some View {
        HStack {
            Text(label).frame(minWidth: labelWidth, alignment: .leading)
            MillisecondsField(label: label, value: $value, maximum: 999_999)
            Text("ms").foregroundStyle(.secondary)
        }
    }
}

/// A custom scene in a list: its swatch, name and number of steps.
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
        // The swatch in words: the first lit step's colour.
        .accessibilityElement(children: .combine)
        .accessibilityValue(scene.swatch.map { ColourNames.name($0) } ?? "")
    }
}

// Main actor: it uses StepChip's formatting, and only views ask.
@MainActor
extension CustomScene.Step {
    /// The step's colour in words, for VoiceOver: "warm white, 2700 K, level 60%", or "dark".
    var spokenColour: String {
        if dark { return "dark" }
        let words = colour.colourName ?? ""
        let colourText = useTemp ? "\(words), \(temp) K" : words
        return level < 100 ? "\(colourText), level \(level)%" : colourText
    }

    /// The colour, then the times when the scene uses them: "pale blue, hold 1s, fade 0.5s".
    func spokenSummary(ownTiming: Bool) -> String {
        guard ownTiming else { return spokenColour }
        return "\(spokenColour), hold \(StepChip.seconds(hold)), fade \(StepChip.seconds(fade))"
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
        copy.name = uniqueSceneName(scene.name + " copy") // as a CCT scale's duplicate is named
        copy.steps = scene.steps.map { var s = $0; s.id = UUID(); return s }
        let i = customScenes.firstIndex { $0.id == scene.id }.map { $0 + 1 } ?? customScenes.endIndex
        customScenes.insert(copy, at: i)
        return copy
    }
}
