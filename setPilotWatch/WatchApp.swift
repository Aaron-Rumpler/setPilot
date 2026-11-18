import SwiftUI

@main
struct SetPilotWatchApp: App {
    @State private var link = PhoneLink.shared
    @Environment(\.scenePhase) private var phase

    init() { PhoneLink.shared.start() }

    var body: some Scene {
        WindowGroup {
            PresetsView(link: link)
        }
        .onChange(of: phase) { _, new in
            if new == .active { link.refresh() }
        }
    }
}

/// The main screen: power and the presets, with everything else a level down.
struct PresetsView: View {
    let link: PhoneLink

    var body: some View {
        NavigationStack {
            List {
                PowerRow(link: link)
                if let error = link.error {
                    Text(error)
                        .font(.footnote)
                        .foregroundStyle(.orange)
                        .listRowBackground(Color.clear)
                }
                Section("Presets") {
                    if link.presets.isEmpty {
                        Text("Save presets in setPilot on your iPhone, or below.")
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
                            Button(role: .destructive) { link.send(.deletePreset(preset.id)) } label: {
                                Label("Delete", systemImage: "trash")
                            }
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
            }
            .navigationTitle("setPilot")
        }
    }

    private func swatch(_ colour: LightColour) -> RGB? {
        if case let .custom(id, _) = colour { return link.scenes.first { $0.id == id }?.swatch ?? nil }
        return colour.swatch
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
        case .unreachable: return "Bulb not answering"
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
                }
            }
            .disabled(link.snapshot?.canControl != true)
        }
        .navigationTitle("Custom Scenes")
    }
}
