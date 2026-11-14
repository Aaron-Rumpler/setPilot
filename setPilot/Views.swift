import AppKit
import QuartzCore
import SwiftUI

struct ContentView: View {
    @AppStorage("bulbIP") private var ip = ""
    @State private var model: Model
    @State private var confirmingReboot = false
    @State private var showingConfig = false

    init(model: Model? = nil) {
        _model = State(initialValue: model ?? Model())
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            bulbPanel
            lightPanel
            commandPanel
            devicePanel
        }
        .padding(20)
        .frame(width: 500)
        .fixedSize()
        .background(GeometryReader { WindowSizer(size: $0.size) })
        // Pin to the top and always match the window (min 0: never larger than it). Otherwise,
        // while the window catches up with a new size, the hosting view centres the content,
        // so it slides down (expand) or is clipped at the top (collapse).
        .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity, alignment: .top)
        .onAppear { if !ip.isEmpty { model.connect(ip) } }
        .confirmationDialog("Reboot the bulb?", isPresented: $confirmingReboot) {
            Button("Reboot", role: .destructive) { model.reboot() }
        } message: {
            Text("It will be unreachable for a few seconds while it restarts.")
        }
    }

    // MARK: Bulb

    private var bulbPanel: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    TextField("IP address", text: $ip, prompt: Text("Bulb IP address"))
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { model.connect(ip) }
                    Button("Connect") { model.connect(ip) }
                        .disabled(ip.trimmingCharacters(in: .whitespaces).isEmpty)
                    findButton
                }
                HStack(spacing: 6) {
                    Circle()
                        .fill(linkColour)
                        .frame(width: 8, height: 8)
                    Text(linkText)
                    if model.link == .connected {
                        Text(model.live ? "· Live updates" : "· No live updates")
                            .foregroundStyle(.secondary)
                            .help(model.liveStatus)
                    }
                    Spacer()
                    Button {
                        model.sync()
                    } label: {
                        Label("Sync", systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(.borderless)
                    .keyboardShortcut("r")
                    .disabled(model.link == .none)
                    .help("Read the bulb's current state (⌘R)")
                }
                .font(.callout)
            }
            .padding(6)
        } label: {
            Text("Bulb")
        }
    }

    @ViewBuilder private var findButton: some View {
        if model.discovered.count > 1 && !model.discovering {
            Menu("\(model.discovered.count) found") {
                ForEach(model.discovered) { d in
                    Button("\(d.ip)  —  \(d.mac)") { use(d.ip) }
                }
                Divider()
                Button("Search Again") { find() }
            }
            .fixedSize()
        } else {
            Button {
                find()
            } label: {
                Text("Find")
                    .opacity(model.discovering ? 0 : 1)
                    .overlay { if model.discovering { ProgressView().controlSize(.small) } }
            }
            .disabled(model.discovering)
            .help("Search every network interface for WiZ bulbs (5 s)")
        }
    }

    private var linkColour: Color {
        switch model.link {
        case .none: .secondary.opacity(0.5)
        case .connecting: .yellow
        case .connected: .green
        case .unreachable: .red
        }
    }

    private var linkText: String {
        switch model.link {
        case .none: "Not connected"
        case .connecting: "Connecting…"
        case .connected: "Connected" + (model.rssi.map { " · \($0 < 0 ? "\u{2212}" : "")\(abs($0)) dBm" } ?? "")
        case .unreachable: "No response"
        }
    }

    // MARK: Light

    private var lightPanel: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 10) {
                    Toggle("Power", isOn: Binding(get: { model.isOn ?? false }, set: { model.power($0) }))
                        .toggleStyle(.switch)
                        .fixedSize()
                    Spacer()
                    ProgressView()
                        .controlSize(.small)
                        .opacity(model.pending ? 1 : 0)
                        .help("Waiting for the bulb to confirm")
                    Picker("Mode", selection: Binding(get: { model.mode }, set: { model.setMode($0) })) {
                        ForEach(Mode.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                }

                Divider()

                switch model.mode {
                case .rgbcw:
                    ChannelSlider(label: "Red", tint: .red, range: 0...255, value: bind(\.r))
                    ChannelSlider(label: "Green", tint: .green, range: 0...255, value: bind(\.g))
                    ChannelSlider(label: "Blue", tint: .blue, range: 0...255, value: bind(\.b))
                    ChannelSlider(label: "Cool W", tint: .cyan, range: 0...255, value: bind(\.c))
                    ChannelSlider(label: "Warm W", tint: .orange, range: 0...255, value: bind(\.w))
                case .temp:
                    ChannelSlider(label: "Kelvin", range: model.tempRange, step: 50,
                                  marks: [2200, 2700, 4200, 6500], scale: .mired, colourTemperatureStrip: true,
                                  value: bind(\.temp))
                case .scene:
                    HStack {
                        Text("Scene").frame(width: ChannelSlider.labelWidth, alignment: .leading)
                        Picker("Scene", selection: Binding(get: { model.sceneId }, set: { model.setScene($0) })) {
                            ForEach(Scenes.all) { Text($0.name).tag($0.id) }
                        }
                        .labelsHidden()
                        .fixedSize()
                        Text("ID \(model.sceneId)")
                            .font(.callout.monospacedDigit())
                            .foregroundStyle(.secondary)
                        Spacer()
                    }
                    ChannelSlider(label: "Speed", range: 10...200, value: bind(\.speed))
                }
                ChannelSlider(label: "Dimming", range: model.minDimming...100, value: bind(\.dimming))

                if model.mode == .rgbcw {
                    HStack {
                        Spacer()
                        Button("Set All Channels to 0") {
                            model.r = 0; model.g = 0; model.b = 0; model.c = 0; model.w = 0
                            model.changed()
                        }
                        .controlSize(.small)
                    }
                }
            }
            .padding(6)
        } label: {
            Text("Light")
        }
        .disabled(model.link != .connected)
    }

    // MARK: Last command

    private var commandPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 8) {
                Group {
                    if model.lastSent.isEmpty {
                        Text("No command sent yet").foregroundStyle(.tertiary)
                    } else {
                        Text("setPilot ").foregroundStyle(.secondary) + Text(model.lastSent)
                    }
                }
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                Button {
                    let pb = NSPasteboard.general
                    pb.clearContents()
                    pb.setString(#"{"method":"setPilot","params":\#(model.lastSent)}"#, forType: .string)
                } label: {
                    Image(systemName: "doc.on.doc")
                }
                .buttonStyle(.borderless)
                .disabled(model.lastSent.isEmpty)
                .help("Copy the full setPilot request as JSON")
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 7))

            if let mismatch = model.mismatch {
                Label(mismatch, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.orange)
                    .textSelection(.enabled)
            }
            if !model.status.isEmpty {
                Text(model.status)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: Device

    private var devicePanel: some View {
        GroupBox {
            HStack(spacing: 8) {
                LabeledContent("MAC address") {
                    Text(model.mac ?? "—")
                        .font(.callout.monospaced())
                        .textSelection(.enabled)
                }
                .font(.callout)
                .fixedSize()
                Spacer()
                Button("Config…") {
                    model.readConfig()
                    showingConfig = true
                }
                .help("Show getSystemConfig, getModelConfig, getUserConfig and getPower")
                .popover(isPresented: $showingConfig, arrowEdge: .bottom) { configPopover }
                Button("Reboot…") { confirmingReboot = true }
            }
            .disabled(model.link != .connected)
            .padding(6)
        } label: {
            Text("Device")
        }
    }

    private var configPopover: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                if model.info.isEmpty {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Reading…").foregroundStyle(.secondary)
                    }
                }
                ForEach(model.info.keys.sorted(), id: \.self) { key in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(key).font(.caption.bold()).foregroundStyle(.secondary)
                        Text(model.info[key] ?? "")
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                    }
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(width: 380, height: 360)
    }

    // MARK: Helpers

    private func find() {
        Task {
            if let found = await model.find() { use(found) }
        }
    }

    private func use(_ found: String) {
        ip = found
        model.connect(found)
    }

    /// Rounds to whole numbers and triggers a send only on user edits (not on syncs/pushes).
    private func bind(_ kp: ReferenceWritableKeyPath<Model, Double>) -> Binding<Double> {
        Binding(
            get: { model[keyPath: kp] },
            set: {
                let v = $0.rounded()
                guard v != model[keyPath: kp] else { return } // continuous sliders move in fractions
                model[keyPath: kp] = v
                model.changed()
            }
        )
    }
}

struct ChannelSlider: View {
    static let labelWidth: CGFloat = 64

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
                           colourTemperatureStrip: colourTemperatureStrip, tint: tint)
                // Centre the row on the track, not on the track plus the marks below it.
                .alignmentGuide(VerticalAlignment.center) { _ in SnapSliderContainer.sliderHeight / 2 }
            NumberField(value: $value, range: range)
                .frame(width: 56)
            Stepper("", value: $value, in: range, step: 1)
                .labelsHidden()
        }
    }
}

/// Integer text field that selects everything on the click that focuses it, so you can type a
/// replacement straight away. Commits on Return or when focus leaves; invalid input reverts.
struct NumberField: NSViewRepresentable {
    @Binding var value: Double
    let range: ClosedRange<Double>

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> SelectAllTextField {
        let field = SelectAllTextField()
        field.alignment = .right
        field.bezelStyle = .roundedBezel
        field.font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        field.delegate = context.coordinator
        field.stringValue = Self.format(value)
        context.coordinator.shown = value
        return field
    }

    func updateNSView(_ field: SelectAllTextField, context: Context) {
        context.coordinator.parent = self
        // Only overwrite the text when the value really changed (slider, stepper, bulb),
        // so an unrelated redraw doesn't clobber what you're typing.
        if value != context.coordinator.shown {
            field.stringValue = Self.format(value)
            context.coordinator.shown = value
        }
    }

    static func format(_ v: Double) -> String { String(Int(v.rounded())) }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: NumberField
        var shown: Double = .nan

        init(_ parent: NumberField) { self.parent = parent }

        func controlTextDidEndEditing(_ note: Notification) {
            guard let field = note.object as? NSTextField else { return }
            let text = field.stringValue.trimmingCharacters(in: .whitespaces)
            if let v = Double(text) {
                let clamped = min(max(v.rounded(), parent.range.lowerBound), parent.range.upperBound)
                if clamped != parent.value { parent.value = clamped }
            }
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

/// Sizes the window to the (fixed-size) SwiftUI content, keeping its top edge in place.
/// `.windowResizability(.contentSize)` alone limits the size but doesn't grow the window.
/// Size changes after the window is shown are animated to run alongside SwiftUI's own
/// animations (e.g. the Device section expanding), unless Reduce Motion is on.
struct WindowSizer: NSViewRepresentable {
    let size: CGSize

    func makeNSView(context: Context) -> SizerView { SizerView() }

    func updateNSView(_ view: SizerView, context: Context) {
        view.target = size
        view.apply()
    }

    final class SizerView: NSView {
        var target: CGSize = .zero
        private var animatingTo: NSRect?
        private var hasSized = false

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            // The window always fits its content, so don't offer manual resizing.
            window?.styleMask.remove(.resizable)
            apply()
        }

        func apply() {
            // Not during SwiftUI's update pass; the work reads current state when it runs.
            DispatchQueue.main.async { [weak self] in self?.resize() }
        }

        private func resize() {
            guard let window, let host = window.contentView, target.width > 0, target.height > 0 else { return }
            let insets = host.safeAreaInsets // title bar, if the content view extends under it
            let want = NSSize(width: target.width + insets.left + insets.right,
                              height: target.height + insets.top + insets.bottom)
            // Keep the top edge where it is (or where a running animation is taking it).
            let top = (animatingTo ?? window.frame).maxY
            var frame = window.frameRect(forContentRect: NSRect(origin: .zero, size: want))
            frame.origin = NSPoint(x: (animatingTo ?? window.frame).minX, y: top - frame.height)

            // The first sizing (as the window appears) isn't animated.
            let animate = hasSized && window.isVisible && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
            hasSized = true

            if let animatingTo, animatingTo.size == frame.size { return }
            guard animatingTo != nil || frame.size != window.frame.size else { return }

            if animate {
                animatingTo = frame
                NSAnimationContext.runAnimationGroup({ ctx in
                    ctx.duration = 0.25
                    ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                    window.animator().setFrame(frame, display: true)
                }, completionHandler: { [weak self] in
                    guard let self, self.animatingTo == frame else { return }
                    self.animatingTo = nil
                })
            } else {
                animatingTo = nil
                // Lay out before drawing, or the old layout shows for a frame at the new size.
                window.setFrame(frame, display: false)
                host.layoutSubtreeIfNeeded()
                window.displayIfNeeded()
            }
        }
    }
}
