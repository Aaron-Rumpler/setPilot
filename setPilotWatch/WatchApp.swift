import SwiftUI

@main
struct SetPilotWatchApp: App {
    @State private var link = PhoneLink.shared
    @Environment(\.scenePhase) private var phase

    init() { PhoneLink.shared.start() }

    var body: some Scene {
        WindowGroup {
            PresetsView(link: link)
                .onOpenURL { link.open($0) } // from the complications
        }
        .onChange(of: phase) { _, new in
            if new == .active { link.refresh() }
        }
    }
}

/// The main screen: power and the presets, with everything else a level down.
struct PresetsView: View {
    let link: PhoneLink
    /// The preset whose edit screen is open (swipe a preset, then Edit).
    @State private var editing: Preset?

    var body: some View {
        NavigationStack {
            List {
                PowerRow(link: link)
                if let mismatch = link.snapshot?.mismatch {
                    MismatchText(text: mismatch)
                }
                if let error = link.error {
                    Text(error)
                        .font(.footnote)
                        .foregroundStyle(.orange)
                        .listRowBackground(Color.clear)
                }
                Section("Presets") {
                    if link.presets.isEmpty {
                        Text("Save presets here or in setPilot on your iPhone. Swipe one to edit it.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    ForEach(link.presets) { preset in
                        Button { link.send(.applyPreset(preset.id)) } label: {
                            HStack(spacing: 10) {
                                Swatch(rgb: swatch(preset.colour), isScene: preset.colour.isScene)
                                VStack(alignment: .leading, spacing: 0) {
                                    Text(preset.name).lineLimit(2)
                                    Text("\(preset.dimming)%")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                        .swipeActions {
                            Button { editing = preset } label: { Label("Edit", systemImage: "pencil") }
                                .tint(.blue)
                        }
                    }
                }
                Section {
                    NavigationLink {
                        ControlsView(link: link)
                    } label: {
                        Label("Controls", systemImage: "slider.horizontal.3")
                    }
                    NavigationLink {
                        WatchComposeView(link: link)
                    } label: {
                        Label("Compose", systemImage: "paperplane")
                    }
                    .disabled(link.snapshot?.canControl != true)
                    NavigationLink {
                        CustomScenesView(link: link)
                    } label: {
                        Label("Custom Scenes", systemImage: "sparkles")
                    }
                    .disabled(link.scenes.isEmpty)
                    TextFieldLink(prompt: Text("Preset name")) {
                        Label("Save Current Light", systemImage: "plus")
                    } onSubmit: { name in
                        link.send(.savePreset(name: name))
                    }
                    .disabled(link.snapshot?.canControl != true)
                }
                Section {
                    NavigationLink {
                        BulbsView(link: link)
                    } label: {
                        VStack(alignment: .leading, spacing: 1) {
                            Label("Bulb", systemImage: "lightbulb.2")
                            if let name = link.snapshot?.bulbName {
                                Text(name).font(.caption2).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            .navigationTitle("setPilot")
            .navigationDestination(item: $editing) { preset in PresetEditView(link: link, presetID: preset.id) }
            .task { await link.poll() } // live updates while the app is open
        }
    }

    private func swatch(_ colour: LightColour) -> RGB? {
        if case let .custom(id, _) = colour { return link.scenes.first { $0.id == id }?.swatch ?? nil }
        return colour.swatch
    }
}

struct MismatchText: View {
    let text: String

    var body: some View {
        Label(text, systemImage: "exclamationmark.triangle.fill")
            .font(.footnote)
            .foregroundStyle(.orange)
            .listRowBackground(Color.clear)
    }
}

struct PowerRow: View {
    let link: PhoneLink

    var body: some View {
        let s = link.snapshot
        Toggle(isOn: Binding(get: { s?.isOn ?? false }, set: { link.send(.power($0)) })) {
            VStack(alignment: .leading, spacing: 1) {
                Text(s?.bulbName ?? "Bulb").lineLimit(1)
                Text(statusText)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .disabled(s?.canControl != true || !link.reachable)
    }

    private var statusText: String {
        if !link.reachable { return "iPhone not reachable" }
        if link.busy { return "Sending…" }
        guard let s = link.snapshot else { return "Waiting for your iPhone" }
        switch s.link {
        case .none: return "No bulb chosen on iPhone"
        case .connecting: return "Connecting…"
        case .unreachable: return "Bulb not answering. Open setPilot on your iPhone to check."
        case .connected: return s.isOn == true ? "On · \(Int(s.dimming))%" : "Off"
        }
    }
}

struct Swatch: View {
    let rgb: RGB?
    var isScene = false

    var body: some View {
        Circle()
            .fill((rgb?.color ?? .gray).gradient)
            .overlay {
                if isScene {
                    Image(systemName: "sparkles").font(.system(size: 9, weight: .bold)).foregroundStyle(.white)
                }
            }
            .frame(width: 24, height: 24)
            .accessibilityHidden(true)
    }
}

struct CustomScenesView: View {
    let link: PhoneLink

    var body: some View {
        List(link.scenes) { scene in
            Button { link.send(.playCustom(scene.id)) } label: {
                HStack(spacing: 10) {
                    Swatch(rgb: scene.swatch, isScene: true)
                    Text(scene.name)
                    Spacer()
                    if link.snapshot?.customScene == scene.id {
                        Image(systemName: "play.fill").foregroundStyle(.secondary).accessibilityLabel("Playing")
                    }
                }
            }
            .disabled(link.snapshot?.canControl != true)
        }
        .navigationTitle("Custom Scenes")
    }
}

/// The bulbs the iPhone has been used with; choosing one switches the iPhone (and watch) to it.
struct BulbsView: View {
    let link: PhoneLink

    var body: some View {
        let bulbs = link.snapshot?.bulbs ?? []
        List {
            ForEach(bulbs) { bulb in
                Button { link.send(.chooseBulb(address: bulb.address, mac: bulb.mac)) } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(bulb.name ?? bulb.address).lineLimit(1)
                            if bulb.name != nil {
                                Text(bulb.address).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                            }
                        }
                        Spacer()
                        if bulb.address == link.snapshot?.address {
                            Image(systemName: "checkmark").foregroundStyle(.tint).accessibilityLabel("In use")
                        }
                    }
                }
            }
            Text(bulbs.isEmpty ? "Add a bulb in setPilot on your iPhone." : "Add bulbs in setPilot on your iPhone.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .listRowBackground(Color.clear)
        }
        .navigationTitle("Bulb")
    }
}

/// One preset: apply, rename, update to the current light, delete.
struct PresetEditView: View {
    let link: PhoneLink
    let presetID: UUID
    @State private var name = ""
    @State private var confirmingUpdate = false
    @State private var confirmingDelete = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let preset = link.presets.first { $0.id == presetID }
        List {
            if let preset {
                Button { link.send(.applyPreset(preset.id)) } label: { Label("Apply", systemImage: "play.fill") }
                TextField("Name", text: $name)
                    .onSubmit {
                        let n = name.trimmingCharacters(in: .whitespaces)
                        if !n.isEmpty, n != preset.name { link.send(.renamePreset(preset.id, name: n)) }
                    }
                Button { confirmingUpdate = true } label: {
                    Label("Update to Current Light", systemImage: "arrow.triangle.2.circlepath")
                }
                .disabled(link.snapshot?.canControl != true)
                Button(role: .destructive) { confirmingDelete = true } label: { Label("Delete", systemImage: "trash") }
            } else {
                Text("This preset has been deleted.").foregroundStyle(.secondary)
            }
        }
        .navigationTitle(preset?.name ?? "Preset")
        .onAppear { name = preset?.name ?? "" }
        .confirmationDialog("Replace “\(preset?.name ?? "")” with the current light?", isPresented: $confirmingUpdate,
                            titleVisibility: .visible) {
            Button("Update") { link.send(.updatePreset(presetID)) }
        }
        .confirmationDialog("Delete “\(preset?.name ?? "")”?", isPresented: $confirmingDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                link.send(.deletePreset(presetID))
                dismiss()
            }
        }
    }
}
