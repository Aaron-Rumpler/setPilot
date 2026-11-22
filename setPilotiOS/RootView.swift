import SwiftUI

struct RootView: View {
    let model: Model
    @AppStorage(Model.addressKey) private var address = ""
    @Environment(\.horizontalSizeClass) private var sizeClass
    /// iPhone: the navigation stack, where Handoff and Spotlight take the app too.
    @State private var path = NavigationPath()
    /// iPad (and wide windows): the screen beside the controls, and the stack within it.
    @State private var pane: Pane? = .route(.customScenes)
    @State private var detailPath = NavigationPath()

    /// The screens beside the main controls.
    enum Pane: Hashable {
        case route(HandoffRoute)
        case settings
    }

    var body: some View {
        Group {
            if sizeClass == .regular {
                // Two columns: the controls stay in view beside scenes, the light show, scales
                // and settings.
                NavigationSplitView {
                    // Choosing another screen starts it afresh (not on the last one's path).
                    List(selection: Binding(get: { pane }, set: { pane = $0; detailPath = NavigationPath() })) { controls }
                        .navigationTitle(model.currentName ?? "setPilot")
                        .refreshable { await model.refresh() }
                        .handoff(.controls)
                        .navigationSplitViewColumnWidth(min: 340, ideal: 400, max: 480)
                } detail: {
                    NavigationStack(path: $detailPath) {
                        Group {
                            if let pane { paneView(pane) } else { Text("Choose from the list.").foregroundStyle(.secondary) }
                        }
                        .navigationDestination(for: HandoffRoute.self) { route in destination(route) }
                    }
                    .id(pane) // a new pane starts its own stack
                }
                .navigationSplitViewStyle(.balanced)
            } else {
                NavigationStack(path: $path) {
                    List { controls }
                        .navigationTitle(model.currentName ?? "setPilot")
                        .refreshable { await model.refresh() }
                        .handoff(.controls)
                        .navigationDestination(for: Pane.self) { pane in paneView(pane) }
                        .navigationDestination(for: HandoffRoute.self) { route in destination(route) }
                }
            }
        }
        .providesUndo(to: model) // shake to undo a light change
        .flashingGuard()
        .accountSwitchPrompt()
        .incomingItemsPrompt(model)
        .householdInvitationPrompt()
        // Continued from another device (Handoff), or opened from Spotlight: go there.
        .onContinueHandoff { HandoffRouter.shared.open($0, info: $1) }
        .onChange(of: HandoffRouter.shared.request, initial: true) { _, route in
            guard let route else { return }
            HandoffRouter.shared.request = nil
            go(route)
        }
    }

    @ViewBuilder private var controls: some View {
        bulbSection
        if !address.isEmpty {
            presetsSection
            lightSection
            commandSection
        }
        Section {
            NavigationLink(value: Pane.route(.customScenes)) { Label("Custom Scenes", systemImage: "sparkles") }
            NavigationLink(value: Pane.route(.lightShow)) { Label("Light Show", systemImage: "play.rectangle") }
            NavigationLink(value: Pane.route(.cctScales)) { Label("CCT Scales", systemImage: "thermometer.medium") }
            NavigationLink(value: Pane.settings) { Label("Bulb & Settings", systemImage: "gearshape") }
        }
    }

    private func go(_ route: HandoffRoute) {
        // A scene or scale that isn't here (not synced yet, or a scale of another bulb): its list.
        var route = route
        if case .customScene(let id) = route, model.library.customScene(id) == nil { route = .customScenes }
        if case .cctScale(let id) = route, !model.library.scales(for: model.chosenMAC).contains(where: { $0.id == id }) {
            route = .cctScales
        }
        if sizeClass == .regular {
            var p = NavigationPath()
            switch route {
            case .controls: break
            case .customScenes, .customScene: pane = .route(.customScenes)
            case .cctScales, .cctScale: pane = .route(.cctScales)
            case .lightShow: pane = .route(.lightShow)
            }
            if case .customScene = route { p.append(route) }
            if case .cctScale = route { p.append(route) }
            detailPath = p
        } else {
            var p = NavigationPath()
            switch route {
            case .controls: break
            case .customScenes, .cctScales, .lightShow: p.append(Pane.route(route))
            case .customScene: p.append(Pane.route(.customScenes)); p.append(route)
            case .cctScale: p.append(Pane.route(.cctScales)); p.append(route)
            }
            path = p
        }
    }

    @ViewBuilder private func paneView(_ pane: Pane) -> some View {
        switch pane {
        case .route(let route): destination(route)
        case .settings: BulbSettingsView(model: model)
        }
    }

    @ViewBuilder private func destination(_ route: HandoffRoute) -> some View {
        switch route {
        case .controls: EmptyView()
        case .customScenes: CustomScenesList(model: model)
        case .customScene(let id): CustomSceneEditor(model: model, sceneID: id).handoff(route)
        case .cctScales: CCTScalesList(model: model)
        case .cctScale(let id): CCTScaleEditor(model: model, scaleID: id).handoff(route)
        // Its own title: the media's name, or "Light Show".
        case .lightShow: LightShowView(model: model).navigationBarTitleDisplayMode(.inline).handoff(route)
        }
    }

    // MARK: Bulb

    @ViewBuilder private var bulbSection: some View {
        Section {
            LocalNetworkHelp(model: model)
            BulbNudge(model: model)
            if address.isEmpty {
                NavigationLink(value: Pane.settings) {
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
                        .accessibilityHidden(true) // the text beside it says the same
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
                UndoLightButton(model: model)
                    .labelStyle(.iconOnly)
                    .font(.subheadline)
                if model.canRedo {
                    RedoLightButton(model: model)
                        .labelStyle(.iconOnly)
                        .font(.subheadline)
                }
                ComposeToggle(model: model)
                    .font(.subheadline)
                    .textCase(nil)
                    .disabled(!model.canControl)
                ProgressView().opacity(model.pending ? 1 : 0)
                    .accessibilityLabel("Waiting for the bulb to confirm")
                    .accessibilityHidden(!model.pending)
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
