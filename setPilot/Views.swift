import AppKit
import QuartzCore
import SwiftUI

struct ContentView: View {
    @AppStorage("bulbIP") private var ip = ""
    @AppStorage("deviceExpanded") private var deviceExpanded = false
    @State private var model = Model()
    @State private var confirming: Maintenance?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            connectionRow

            HStack {
                Button("On") { model.power(true) }
                Button("Off") { model.power(false) }
                Text(model.isOn.map { $0 ? "Bulb is on" : "Bulb is off" } ?? "")
                    .foregroundStyle(.secondary)
                Spacer()
                if model.mode == .rgbcw {
                    Button("Zero RGBCW") {
                        model.r = 0; model.g = 0; model.b = 0; model.c = 0; model.w = 0
                        model.changed()
                    }
                }
            }

            Divider()

            HStack {
                Picker("Mode", selection: Binding(get: { model.mode }, set: { model.setMode($0) })) {
                    ForEach(Mode.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                ProgressView()
                    .controlSize(.small)
                    .opacity(model.pending ? 1 : 0)
                    .help("Waiting for the bulb to confirm")
            }

            switch model.mode {
            case .rgbcw:
                ChannelSlider(label: "Red", tint: .red, range: 0...255, value: bind(\.r))
                ChannelSlider(label: "Green", tint: .green, range: 0...255, value: bind(\.g))
                ChannelSlider(label: "Blue", tint: .blue, range: 0...255, value: bind(\.b))
                ChannelSlider(label: "Cool W", tint: .cyan, range: 0...255, value: bind(\.c))
                ChannelSlider(label: "Warm W", tint: .orange, range: 0...255, value: bind(\.w))
            case .temp:
                ChannelSlider(label: "Kelvin", tint: .orange, range: model.tempRange, step: 50,
                              marks: [2200, 2400, 2700, 4200, 6500], scale: .mired, value: bind(\.temp))
            case .scene:
                Picker("Scene", selection: Binding(get: { model.sceneId }, set: { model.setScene($0) })) {
                    ForEach(Scenes.all) { Text("\($0.name) (\($0.id))").tag($0.id) }
                }
                ChannelSlider(label: "Speed", tint: .purple, range: 10...200, value: bind(\.speed))
            }
            ChannelSlider(label: "Dimming", tint: .gray, range: model.minDimming...100, value: bind(\.dimming))

            Divider()

            Text(model.lastSent.isEmpty ? " " : "setPilot \(model.lastSent)")
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
            if let mismatch = model.mismatch {
                Label(mismatch, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .textSelection(.enabled)
            }
            Text(model.status).font(.caption).foregroundStyle(.secondary)
            Text(model.liveStatus).font(.caption).foregroundStyle(.secondary)

            DisclosureGroup("Device", isExpanded: $deviceExpanded) { deviceSection }
        }
        .padding()
        .frame(width: 520)
        .fixedSize()
        .background(GeometryReader { WindowSizer(size: $0.size) })
        // Pin to the top and always match the window (min 0: never larger than it). Otherwise,
        // while the window catches up with a new size, the hosting view centres the content,
        // so it slides down (expand) or is clipped at the top (collapse).
        .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity, alignment: .top)
        .onAppear { if !ip.isEmpty { model.connect(ip) } }
        .confirmationDialog(
            confirming?.title ?? "",
            isPresented: Binding(get: { confirming != nil }, set: { if !$0 { confirming = nil } }),
            presenting: confirming
        ) { m in
            Button(m.title, role: .destructive) { model.run(m) }
        } message: { m in
            Text(m.message)
        }
    }

    private var connectionRow: some View {
        HStack {
            TextField("Bulb IP", text: $ip)
                .textFieldStyle(.roundedBorder)
                .onSubmit { model.connect(ip) }
            Button("Connect") { model.connect(ip) }
            Button(model.discovering ? "Finding…" : "Find") {
                Task {
                    if let found = await model.find() { use(found) }
                }
            }
            .disabled(model.discovering)
            .help("Broadcast discovery on all interfaces (5 s)")
            if model.discovered.count > 1 {
                Menu("\(model.discovered.count) found") {
                    ForEach(model.discovered) { d in
                        Button("\(d.ip)  \(d.mac)") { use(d.ip) }
                    }
                }
                .fixedSize()
            }
            Button("Sync") { model.sync() }
                .help("Read current values from the bulb (getPilot)")
        }
    }

    private var deviceSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Button("Read config") { model.readConfig() }
                    .help("getSystemConfig, getModelConfig, getUserConfig, getPower")
                Spacer()
                Button("Reboot…") { confirming = .reboot }
                Button("Factory reset…") { confirming = .reset }
            }
            if let mac = model.mac {
                Text("MAC \(mac)" + (model.rssi.map { "   RSSI \($0) dBm" } ?? ""))
                    .font(.caption)
                    .textSelection(.enabled)
            }
            if !model.info.isEmpty {
                ScrollView {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(model.info.keys.sorted(), id: \.self) { key in
                            Text(key).font(.caption.bold())
                            Text(model.info[key] ?? "")
                                .font(.system(.caption, design: .monospaced))
                                .textSelection(.enabled)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(height: 220)
            }
        }
        .padding(.top, 4)
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
    let label: String
    let tint: Color
    let range: ClosedRange<Double>
    /// Slider snapping (drag, arrow keys, VoiceOver); the field and stepper still work in 1s.
    var step: Double = 1
    var marks: [Double] = []
    var scale: SliderScale = .linear
    @Binding var value: Double

    var body: some View {
        HStack {
            Text(label).frame(width: 60, alignment: .leading)
            SnappingSlider(value: $value, range: range, step: step, marks: marks, scale: scale, tint: tint)
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
