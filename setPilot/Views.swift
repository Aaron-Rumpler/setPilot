import AppKit
import SwiftUI

struct ContentView: View {
    @AppStorage(Model.addressKey) private var address = ""
    let model: Model
    @State private var confirmingReboot = false
    @State private var showingConfig = false
    @State private var configHeight: CGFloat = 120

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
        .confirmationDialog("Reboot the bulb?", isPresented: $confirmingReboot) {
            Button("Reboot", role: .destructive) { model.reboot() }
        } message: {
            Text("It will be unreachable for a few seconds while it restarts.")
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
                }
                .font(.callout)
                .padding(.leading, 2)
            }
        }
    }

    // MARK: Light

    private var lightPanel: some View {
        Panel("Light") {
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                    .opacity(model.pending ? 1 : 0)
                    .help("Waiting for the bulb to confirm")
                Toggle("Power", isOn: model.powerBinding)
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize() // the label wrapped on macOS 26 without this
            }
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
                let pb = NSPasteboard.general
                pb.clearContents()
                pb.setString(#"{"method":"setPilot","params":\#(model.lastSent)}"#, forType: .string)
            } label: {
                Label("Copy JSON", systemImage: "doc.on.doc")
            }
            .buttonStyle(.borderless)
            .disabled(model.lastSent.isEmpty)
            .help("Copy the full setPilot request as JSON")
        } content: {
            VStack(alignment: .leading, spacing: 8) {
                Group {
                    if model.lastSent.isEmpty {
                        Text("Nothing sent yet").foregroundStyle(.tertiary)
                    } else {
                        Text("\(Text("setPilot ").foregroundStyle(.secondary))\(Text(JSONHighlighter.highlight(model.lastSent)))")
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
            .help("Device configuration")
            .accessibilityLabel("Device configuration")
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
                }
                .font(.callout)
                Spacer()
                Button("Reboot…") { confirmingReboot = true }
                    .disabled(model.link != .connected)
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
            VStack(alignment: .leading, spacing: 10) {
                Text("Device Configuration").font(.headline)
                if model.info.isEmpty {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Reading…").foregroundStyle(.secondary)
                    }
                }
                ForEach(configOrder.filter { model.info[$0] != nil }, id: \.self) { key in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(key).font(.caption.bold()).foregroundStyle(.secondary)
                        Text(JSONHighlighter.highlight(model.info[key] ?? ""))
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                    }
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(GeometryReader { g in
                Color.clear.onChange(of: g.size.height, initial: true) { _, h in configHeight = h }
            })
        }
        // Hug the content; scroll only when it's taller than this.
        .frame(width: 400, height: min(configHeight, 520))
    }

    /// Identity first, then capabilities, settings and power.
    private let configOrder = ["getSystemConfig", "getModelConfig", "getUserConfig", "getPower"]
}

/// The mode control and the current mode's sliders, plus Dimming. Shared by the window and the
/// menu bar panel.
struct LightControls: View {
    let model: Model
    var compact = false
    /// Read so the colour-temperature colours redraw when the testing setting changes.
    @AppStorage(ColourTemperature.adaptingWhiteKey) private var adaptingWhite = ColourTemperature.defaultAdaptingWhite
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 10 : 12) {
            Picker("Mode", selection: Binding(get: { model.mode }, set: { model.setMode($0) })) {
                ForEach(Mode.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .frame(maxWidth: .infinity) // centred

            Divider()

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
            case .temp:
                ChannelSlider(label: "Kelvin", range: model.tempRange, step: 50,
                              marks: [2200, 2700, 4200, 6500], scale: .mired, colourTemperatureStrip: true,
                              value: model.binding(\.temp))
                    .id(adaptingWhite) // rebuild the track when the adapting white changes
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

        }
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
    /// Slider snapping (drag, arrow keys, VoiceOver); the field and stepper still work in 1s.
    var step: Double = 1
    var marks: [Double] = []
    var scale: SliderScale = .linear
    var colourTemperatureStrip = false
    @Binding var value: Double

    var body: some View {
        HStack(spacing: 8) {
            Text(label).frame(width: Self.labelWidth, alignment: .leading)
            SnappingSlider(value: $value, range: range, step: step, marks: marks, scale: scale,
                           colourTemperatureStrip: colourTemperatureStrip, tint: tint, label: label)
                // Centre the row on the track, not on the track plus the marks below it.
                .alignmentGuide(VerticalAlignment.center) { _ in SnapSliderContainer.sliderHeight / 2 }
            NumberField(value: $value, range: range, label: label)
                .frame(width: 56)
            Stepper(label, value: $value, in: range, step: 1)
                .labelsHidden()
        }
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
