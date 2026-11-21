import AppKit
import SwiftUI

struct ContentView: View {
    @AppStorage(Model.addressKey) private var address = ""
    let model: Model
    @State private var showingConfig = false
    @State private var configHeight: CGFloat = 120
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            bulbPanel
            lightPanel
            presetsPanel
            commandPanel
            devicePanel
        }
        .padding(20)
        .frame(width: 500)
        // A fixed size: with .windowResizability(.contentSize) the window's minimum and maximum
        // are both this, so it opens at the right size, can't be resized, and follows the content.
        .fixedSize()
        .navigationTitle(model.currentName ?? "setPilot")
        .onAppear {
            // The menu bar item normally connects to the saved bulb at launch. First launch (no saved
            // bulb): search straight away, which also brings up the Local Network permission prompt.
            if address.isEmpty, !model.started {
                model.started = true
                Task {
                    // Pick a lone bulb automatically; with several, leave the choice to the picker.
                    let found = await model.discover()
                    if found.count == 1, address.isEmpty { model.choose(found[0].ip, mac: found[0].mac) }
                }
            } else {
                model.startIfSaved()
            }
        }
    }

    // MARK: Bulb

    private var bulbPanel: some View {
        Panel("Bulb") {
            Button {
                model.sync()
            } label: {
                Label("Sync", systemImage: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
            .keyboardShortcut("r")
            .disabled(model.link == .none)
            .help("Read the bulb's current state (⌘R)")
        } content: {
            VStack(alignment: .leading, spacing: 10) {
                BulbPicker(model: model)
                HStack(spacing: 6) {
                    Circle()
                        .fill(model.linkColour)
                        .frame(width: 8, height: 8)
                    Text(model.linkText)
                    if model.link == .connected {
                        Text("·").foregroundStyle(.tertiary)
                        Text(!model.live ? "No live updates" : model.pushSeen ? "Live updates" : "Live updates (none yet)")
                            .foregroundStyle(.secondary)
                            .help(model.liveStatus)
                    }
                    Spacer()
                    // On the bulb, as in the menu bar panel: it's the bulb's state, not a light setting.
                    Toggle("Power", isOn: model.powerBinding)
                        .toggleStyle(.switch)
                        .controlSize(.small)
                        .labelsHidden()
                        .disabled(!model.canControl)
                        .help(model.isOn == true ? "Switch the bulb off (⇧⌘P)" : "Switch the bulb on (⇧⌘P)")
                        .accessibilityLabel("Power")
                }
                .font(.callout)
                .padding(.leading, 2)
            }
        }
    }

    // MARK: Light

    private var lightPanel: some View {
        Panel("Light") {
            ProgressView()
                .controlSize(.small)
                .opacity(model.pending ? 1 : 0)
                .help("Waiting for the bulb to confirm")
        } content: {
            LightControls(model: model)
        }
        .disabled(!model.canControl)
    }

    // MARK: Presets

    private var presetsPanel: some View {
        Panel("Presets") {
            SavePresetButton(model: model)
                .buttonStyle(.borderless)
        } content: {
            PresetGrid(model: model, columns: 5)
        }
    }

    // MARK: Last command

    private var commandPanel: some View {
        Panel("Last Command") {
            Button {
                openWindow(id: "lightshow")
            } label: {
                Label("Light Show…", systemImage: "play.rectangle")
            }
            .buttonStyle(.borderless)
            .help("Play audio or video with the bulb following a light show file (⌥⌘L)")
            Button {
                openWindow(id: "console")
            } label: {
                Label("Console…", systemImage: "terminal")
            }
            .buttonStyle(.borderless)
            .help("Send any method and see every message to and from the bulb (⌥⌘K)")
            Button {
                let pb = NSPasteboard.general
                pb.clearContents()
                pb.setString(model.lastCommandJSON, forType: .string)
            } label: {
                Label("Copy JSON", systemImage: "doc.on.doc")
            }
            .buttonStyle(.borderless)
            .disabled(model.lastSent.isEmpty)
            .help("Copy the full request as JSON")
        } content: {
            VStack(alignment: .leading, spacing: 8) {
                Group {
                    if model.lastSent.isEmpty {
                        Text("Nothing sent yet").foregroundStyle(.tertiary)
                    } else {
                        Text("\(Text(model.lastMethod + " ").foregroundStyle(.secondary))\(Text(JSONHighlighter.highlight(model.lastSent)))")
                    }
                }
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)

                if let mismatch = model.mismatch {
                    Label(mismatch, systemImage: "exclamationmark.triangle.fill")
                        .font(.callout)
                        .foregroundStyle(.orange)
                        .textSelection(.enabled)
                } else if model.status == "Bulb confirmed" {
                    Label("Bulb confirmed", systemImage: "checkmark.circle.fill")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                } else {
                    // Always one line, even when empty, so messages coming and going don't
                    // resize the window.
                    Text(model.status.isEmpty ? " " : model.status)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .help(model.status)
                }
            }
        }
    }

    // MARK: Device

    private var devicePanel: some View {
        Panel("Device") {
            Button {
                model.readConfig()
                showingConfig = true
            } label: {
                Image(systemName: "info.circle")
            }
            .buttonStyle(.borderless)
            .help("Device info: every read the bulb answers")
            .accessibilityLabel("Device info")
            .disabled(model.link != .connected)
            .popover(isPresented: $showingConfig, arrowEdge: .bottom) { configPopover }
        } content: {
            HStack(alignment: .top) {
                Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 5) {
                    GridRow {
                        Text("Name").foregroundStyle(.secondary)
                        HStack(spacing: 6) {
                            deviceValue(model.currentName)
                            if let mac = model.chosenMAC { RenameButton(model: model, mac: mac) }
                        }
                    }
                    GridRow {
                        Text("MAC address").foregroundStyle(.secondary)
                        deviceValue(model.mac, monospaced: true)
                    }
                    GridRow {
                        Text("Module").foregroundStyle(.secondary)
                        deviceValue(model.module)
                    }
                    GridRow {
                        Text("Firmware").foregroundStyle(.secondary)
                        deviceValue(model.firmware)
                    }
                    GridRow {
                        Text("Signing").foregroundStyle(.secondary)
                        HStack(spacing: 6) {
                            deviceValue(model.chosenMAC == nil ? nil : model.signingStatus)
                            if let mac = model.chosenMAC { SigningKeyButton(model: model, mac: mac) }
                        }
                    }
                }
                .font(.callout)
                Spacer()
            }
        }
    }

    private func deviceValue(_ value: String?, monospaced: Bool = false) -> some View {
        Text(value ?? "—")
            .fontDesign(monospaced ? .monospaced : .default)
            .foregroundStyle(value == nil ? HierarchicalShapeStyle.tertiary : .primary)
            .textSelection(.enabled)
    }

    private var configPopover: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text("Device Info").font(.title3.weight(.semibold))
                DeviceInfoView(model: model)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(GeometryReader { g in
                Color.clear.onChange(of: g.size.height, initial: true) { _, h in configHeight = h }
            })
        }
        // Hug the content; scroll only when it's taller than this.
        .frame(width: 480, height: min(configHeight, 680))
    }
}

/// The mode control and the current mode's sliders, plus Dimming and Fade, or Compose's draft in
/// their place. Shared by the window and the menu bar panel.
struct LightControls: View {
    let model: Model
    var compact = false
    /// Read so the colour-temperature colours redraw when the testing setting changes.
    @AppStorage(ColourTemperature.adaptingWhiteKey) private var adaptingWhite = ColourTemperature.defaultAdaptingWhite
    @Environment(\.openWindow) private var openWindow

    private var editScalesButton: some View {
        Button {
            openWindow(id: "scales")
            NSApp.activate()
        } label: {
            Label("CCT Scales…", systemImage: "square.and.pencil")
        }
        .labelStyle(.iconOnly)
        .buttonStyle(.borderless)
        .help("Edit this bulb's custom CCT scales")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 10 : 12) {
            // Compose picks the kind of colour for its draft; live, it changes the bulb's mode.
            Picker("Mode", selection: model.composing
                   ? Binding(get: { model.draft.kind }, set: { model.draft.kind = $0 })
                   : Binding(get: { model.mode.choice }, set: { model.setModeChoice($0) })) {
                ForEach(ModeChoice.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .disabled(model.composing && !model.draft.includeColour)
            .frame(maxWidth: .infinity) // centred
            .overlay(alignment: .trailing) { ComposeToggle(model: model).labelStyle(.iconOnly) }

            if model.composing {
                Text("Composing: nothing is sent until you press Send.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
            }

            Divider()

            if model.composing {
                ComposeControls(model: model)
            } else {
                liveControls
            }
        }
    }

    @ViewBuilder private var liveControls: some View {
            switch model.mode {
            case .rgbcw:
                ChannelSlider(label: "Red", tint: .red, range: 0...255, value: model.binding(\.r))
                ChannelSlider(label: "Green", tint: .green, range: 0...255, value: model.binding(\.g))
                ChannelSlider(label: "Blue", tint: .blue, range: 0...255, value: model.binding(\.b))
                // The white channels in the colours of their LEDs (as on the Kelvin track)
                ChannelSlider(label: "Cool white", tint: Color(nsColor: ColourTemperature.colour(kelvin: 6500)),
                              range: 0...255, value: model.binding(\.c))
                    .id(adaptingWhite)
                ChannelSlider(label: "Warm white", tint: Color(nsColor: ColourTemperature.colour(kelvin: 2700)),
                              range: 0...255, value: model.binding(\.w))
                    .id(adaptingWhite)
            case .temp, .custom:
                HStack(spacing: 8) {
                    Text("Scale").frame(width: ChannelSlider.labelWidth, alignment: .leading)
                    TemperatureScalePicker(model: model)
                        .labelsHidden()
                        .fixedSize()
                    Spacer()
                    editScalesButton
                }
                if model.mode == .custom, let scale = model.activeScale, let range = scale.range {
                    // Marks at the scale's points; the track's colours are black-body, not the scale's.
                    ChannelSlider(label: "Kelvin", range: Double(range.lowerBound)...Double(range.upperBound),
                                  marks: spacedMarks(scale.points.map(\.kelvin), in: range),
                                  scale: .mired, colourTemperatureStrip: true, value: model.binding(\.customKelvin))
                        .id("\(adaptingWhite) \(scale.id) \(range)")
                } else {
                    ChannelSlider(label: "Kelvin", range: model.tempRange,
                                  marks: [2200, 2700, 4200, 6500], scale: .mired, colourTemperatureStrip: true,
                                  value: model.binding(\.temp))
                        .id(adaptingWhite) // rebuild the track when the adapting white changes
                }
            case .scene:
                HStack(spacing: 8) {
                    Text("Scene").frame(width: ChannelSlider.labelWidth, alignment: .leading)
                    // The bulb's scenes, then setPilot's custom scenes, then anything else it reported
                    Picker("Scene", selection: model.sceneChoice) { SceneMenuItems(model: model) }
                        .labelsHidden()
                        .fixedSize()
                    Text(verbatim: "ID \(model.sceneId)") // verbatim: no "1,000"
                        .font(.callout.monospacedDigit())
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button {
                        openWindow(id: "scenes")
                        NSApp.activate()
                    } label: {
                        Label("Custom Scenes…", systemImage: "square.and.pencil")
                    }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .help("Edit custom scenes")
                }
                ChannelSlider(label: "Speed", range: 10...200, value: model.binding(\.speed))
            }
            ChannelSlider(label: "Dimming", range: model.minDimming...100, value: model.binding(\.dimming))
            ControlsFadeRow(model: model)
    }
}

/// A titled section: a heading with optional trailing controls, above a group box.
struct Panel<Accessory: View, Content: View>: View {
    let title: String
    let accessory: Accessory
    let content: Content

    init(_ title: String, @ViewBuilder accessory: () -> Accessory, @ViewBuilder content: () -> Content) {
        self.title = title
        self.accessory = accessory()
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(title).font(.headline)
                Spacer(minLength: 8)
                accessory
            }
            .frame(minHeight: 22) // same height with or without controls
            .padding(.horizontal, 4)
            GroupBox {
                content
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

struct ChannelSlider: View {
    static let labelWidth: CGFloat = 76

    let label: String
    var tint: Color? = nil
    let range: ClosedRange<Double>
    var marks: [Double] = []
    var scale: SliderScale = .linear
    var colourTemperatureStrip = false
    @Binding var value: Double
    @AppStorage(Stepping.snapKey) private var snaps = true

    var body: some View {
        HStack(spacing: 8) {
            Text(label).frame(width: Self.labelWidth, alignment: .leading)
            // Snaps (drag, arrow keys, VoiceOver) to the round step, unless that's off in Settings
            // or Option is held; the field works in 1s.
            SnappingSlider(value: $value, range: range, step: Stepping.snapStep(for: range, snapping: snaps),
                           marks: marks, scale: scale,
                           colourTemperatureStrip: colourTemperatureStrip, tint: tint, label: label)
                // Centre the row on the track, not on the track plus the marks below it.
                .alignmentGuide(VerticalAlignment.center) { _ in SnapSliderContainer.sliderHeight / 2 }
            NumberField(value: $value, range: range, label: label)
                .frame(width: 56)
            // Holding a stepper half repeats (AppKit's own, at a steady rate).
            Stepper(label, onIncrement: { nudge(up: true) }, onDecrement: { nudge(up: false) })
                .labelsHidden()
                .help("Steps of \(Int(buttonStep)); hold Option for steps of 1")
        }
    }

    private var buttonStep: Double { Stepping.coarse(for: range) }

    /// To the next multiple of the step (so 37 goes to 40, then 50), or by 1 with Option held.
    private func nudge(up: Bool) {
        let step = NSEvent.modifierFlags.contains(.option) ? 1 : buttonStep
        let v = Stepping.next(value, up: up, by: step, in: range)
        if v != value { value = v }
    }
}

/// Integer text field that selects everything on the click that focuses it, so you can type a
/// replacement straight away. Commits on Return or when focus leaves; invalid input reverts.
struct NumberField: NSViewRepresentable {
    @Binding var value: Double
    let range: ClosedRange<Double>
    var label = ""

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> SelectAllTextField {
        let field = SelectAllTextField()
        field.alignment = .right
        field.bezelStyle = .roundedBezel
        field.font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        field.delegate = context.coordinator
        field.setAccessibilityLabel(label)
        field.stringValue = Self.format(value)
        context.coordinator.shown = value
        return field
    }

    func updateNSView(_ field: SelectAllTextField, context: Context) {
        context.coordinator.parent = self
        // SwiftUI's .disabled doesn't reach AppKit views by itself.
        field.isEnabled = context.environment.isEnabled
        // Only overwrite the text when the value really changed (slider, stepper, bulb), and
        // never while you're typing a new one: a push from the bulb would wipe it.
        if value != context.coordinator.shown && !context.coordinator.typing {
            field.stringValue = Self.format(value)
            context.coordinator.shown = value
        }
    }

    static func format(_ v: Double) -> String { String(Int(v.rounded())) }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: NumberField
        var shown: Double = .nan
        /// Text has been typed since the field was last committed or updated.
        var typing = false

        init(_ parent: NumberField) { self.parent = parent }

        func controlTextDidChange(_ note: Notification) { typing = true }

        func controlTextDidEndEditing(_ note: Notification) {
            guard let field = note.object as? NSTextField else { return }
            let text = field.stringValue.trimmingCharacters(in: .whitespaces)
            if let v = Double(text) {
                let clamped = min(max(v.rounded(), parent.range.lowerBound), parent.range.upperBound)
                if clamped != parent.value { parent.value = clamped }
            }
            typing = false
            field.stringValue = NumberField.format(parent.value)
            shown = parent.value
        }
    }
}

final class SelectAllTextField: NSTextField {
    override func mouseDown(with event: NSEvent) {
        let wasEditing = currentEditor() != nil
        super.mouseDown(with: event) // tracks until mouse-up, placing the caret
        if !wasEditing { currentEditor()?.selectAll(nil) }
    }
}

/// A scale's points as slider marks, leaving out any too close to the previous one to label
/// (on the mired scale the slider uses).
func spacedMarks(_ kelvins: [Int], in range: ClosedRange<Int>) -> [Double] {
    let lo = 1e6 / Double(range.lowerBound), hi = 1e6 / Double(range.upperBound)
    guard lo > hi else { return [] }
    var kept: [Double] = []
    var last = -1.0
    for k in Set(kelvins).sorted() {
        let at = (lo - 1e6 / Double(k)) / (lo - hi)
        if kept.isEmpty || at - last >= 0.09 {
            kept.append(Double(k))
            last = at
        }
    }
    return kept
}
