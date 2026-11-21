import SwiftUI

struct RootView: View {
    let model: Model
    @AppStorage(Model.addressKey) private var address = ""

    var body: some View {
        NavigationStack {
            List {
                bulbSection
                if !address.isEmpty {
                    presetsSection
                    lightSection
                    commandSection
                }
                Section {
                    NavigationLink {
                        CustomScenesList(model: model)
                    } label: {
                        Label("Custom Scenes", systemImage: "sparkles")
                    }
                    NavigationLink {
                        LightShowView(model: model)
                            .navigationTitle("Light Show")
                            .navigationBarTitleDisplayMode(.inline)
                    } label: {
                        Label("Light Show", systemImage: "play.rectangle")
                    }
                    NavigationLink {
                        CCTScalesList(model: model)
                    } label: {
                        Label("CCT Scales", systemImage: "thermometer.medium")
                    }
                    NavigationLink {
                        BulbSettingsView(model: model)
                    } label: {
                        Label("Bulb & Settings", systemImage: "gearshape")
                    }
                }
            }
            .navigationTitle(model.currentName ?? "setPilot")
            .refreshable { await model.refresh() }
        }
    }

    // MARK: Bulb

    @ViewBuilder private var bulbSection: some View {
        Section {
            if address.isEmpty {
                NavigationLink {
                    BulbSettingsView(model: model)
                } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Add Your Bulb").font(.headline)
                        Text("Enter its IP address or DNS name.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
            } else {
                HStack(spacing: 10) {
                    Circle().fill(model.linkColour).frame(width: 9, height: 9)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(model.linkText)
                        if model.link == .connected {
                            Text(!model.live ? "No live updates" : model.pushSeen ? "Live updates" : "Live updates (none yet)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        } else if model.link == .unreachable, !model.status.isEmpty {
                            Text(model.status).font(.caption).foregroundStyle(.secondary)
                        }
                        if model.link == .unreachable {
                            Button("Try Again") { model.resume() }
                                .font(.caption)
                                .buttonStyle(.borderless)
                        }
                    }
                    Spacer()
                }
            }
        }
    }

    // MARK: Presets

    private var presetsSection: some View {
        Section {
            PresetGrid(model: model)
                .padding(.vertical, 4)
        } header: {
            HStack {
                Text("Presets")
                Spacer()
                SavePresetButton(model: model, title: "Save Current")
                    .font(.subheadline)
                    .textCase(nil)
            }
        } footer: {
            if !model.library.presets.isEmpty {
                Text("Touch and hold a preset to rename, update, move or delete it.")
            }
        }
    }

    // MARK: Light

    private var lightSection: some View {
        Section {
            // Compose picks the kind of colour for its draft; live, it changes the bulb's mode.
            Picker("Mode", selection: model.composing
                   ? Binding(get: { model.draft.kind }, set: { model.draft.kind = $0 })
                   : Binding(get: { model.mode.choice }, set: { model.setModeChoice($0) })) {
                ForEach(ModeChoice.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .listRowSeparator(.hidden)
            .disabled(model.composing && !model.draft.includeColour)

            if model.composing {
                ComposeControls(model: model)
            } else {
                liveRows
            }
        } header: {
            HStack {
                Text("Light")
                Spacer()
                ComposeToggle(model: model)
                    .font(.subheadline)
                    .textCase(nil)
                    .disabled(!model.canControl)
                ProgressView().opacity(model.pending ? 1 : 0)
                // At the top of the light: the first thing to reach for.
                Toggle("Power", isOn: model.powerBinding)
                    .labelsHidden()
                    .disabled(!model.canControl)
            }
        } footer: {
            if model.composing { Text("Composing: nothing is sent until you tap Send.") }
        }
        .disabled(!model.canControl)
    }

    @ViewBuilder private var liveRows: some View {
            switch model.mode {
            case .rgbcw:
                MobileSlider(label: "Red", tint: .red, range: 0...255, value: model.binding(\.r))
                MobileSlider(label: "Green", tint: .green, range: 0...255, value: model.binding(\.g))
                MobileSlider(label: "Blue", tint: .blue, range: 0...255, value: model.binding(\.b))
                MobileSlider(label: "Cool white", tint: ColourTemperature.color(kelvin: 6500), range: 0...255,
                             value: model.binding(\.c))
                MobileSlider(label: "Warm white", tint: ColourTemperature.color(kelvin: 2700), range: 0...255,
                             value: model.binding(\.w))
            case .temp, .custom:
                TemperatureScalePicker(model: model)
                if model.mode == .custom, let range = model.activeScale?.range {
                    MobileSlider(label: "Kelvin", tint: ColourTemperature.color(kelvin: model.customKelvin),
                                 range: Double(range.lowerBound)...Double(range.upperBound), mired: true,
                                 value: model.binding(\.customKelvin))
                } else {
                    MobileSlider(label: "Kelvin", tint: ColourTemperature.color(kelvin: model.temp), range: model.tempRange,
                                 mired: true, value: model.binding(\.temp))
                }
            case .scene:
                Picker("Scene", selection: model.sceneChoice) { SceneMenuItems(model: model) }
                    .pickerStyle(.navigationLink)
                MobileSlider(label: "Speed", range: 10...200, value: model.binding(\.speed))
            }
            MobileSlider(label: "Dimming", range: model.minDimming...100, unit: "%", value: model.binding(\.dimming))
            ControlsFadeRow(model: model)
    }

    // MARK: Last command

    private var commandSection: some View {
        Section("Last Command") {
            VStack(alignment: .leading, spacing: 6) {
                if model.lastSent.isEmpty {
                    Text("Nothing sent yet").foregroundStyle(.tertiary)
                } else {
                    Text("\(Text(model.lastMethod + " ").foregroundStyle(.secondary))\(Text(JSONHighlighter.highlight(model.lastSent)))")
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                }
                if let mismatch = model.mismatch {
                    Label(mismatch, systemImage: "exclamationmark.triangle.fill")
                        .font(.footnote)
                        .foregroundStyle(.orange)
                } else if !model.status.isEmpty {
                    Text(model.status).font(.footnote).foregroundStyle(.secondary)
                }
            }
            .contextMenu {
                Button {
                    UIPasteboard.general.string = model.lastCommandJSON
                } label: {
                    Label("Copy JSON", systemImage: "doc.on.doc")
                }
                .disabled(model.lastSent.isEmpty)
            }
        }
    }
}
