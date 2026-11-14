import SwiftUI

struct ContentView: View {
    @AppStorage("bulbIP") private var ip = ""
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

            Picker("Mode", selection: Binding(get: { model.mode }, set: { model.setMode($0) })) {
                ForEach(Mode.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            switch model.mode {
            case .rgbcw:
                ChannelSlider(label: "Red", tint: .red, range: 0...255, value: bind(\.r))
                ChannelSlider(label: "Green", tint: .green, range: 0...255, value: bind(\.g))
                ChannelSlider(label: "Blue", tint: .blue, range: 0...255, value: bind(\.b))
                ChannelSlider(label: "Cool W", tint: .cyan, range: 0...255, value: bind(\.c))
                ChannelSlider(label: "Warm W", tint: .orange, range: 0...255, value: bind(\.w))
            case .temp:
                ChannelSlider(label: "Kelvin", tint: .orange, range: model.tempRange, step: 10, value: bind(\.temp))
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
            Text(model.status).font(.caption).foregroundStyle(.secondary)
            Text(model.liveStatus).font(.caption).foregroundStyle(.secondary)

            DisclosureGroup("Device") { deviceSection }
        }
        .padding()
        .frame(width: 480)
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
            set: { model[keyPath: kp] = $0.rounded(); model.changed() }
        )
    }
}

struct ChannelSlider: View {
    let label: String
    let tint: Color
    let range: ClosedRange<Double>
    var step: Double = 1
    @Binding var value: Double

    var body: some View {
        HStack {
            Text(label).frame(width: 60, alignment: .leading)
            Slider(value: $value, in: range, step: step).tint(tint)
            TextField("", value: clamped, format: .number.grouping(.never))
                .textFieldStyle(.roundedBorder)
                .multilineTextAlignment(.trailing)
                .frame(width: 56)
        }
    }

    private var clamped: Binding<Double> {
        Binding(get: { value }, set: { value = min(max($0, range.lowerBound), range.upperBound) })
    }
}
