import SwiftUI

@main
struct SetPilotWatchApp: App {
    @State private var link = PhoneLink.shared
    @Environment(\.scenePhase) private var phase

    init() {
        PhoneLink.shared.start()
        // The controls' links (Common/WatchControls.swift), now and from before the app was running.
        WatchLinkInbox.handler = { PhoneLink.shared.open($0) }
        for link in WatchLinkInbox.take() { PhoneLink.shared.open(link.url, at: link.at) }
        WatchShortcuts.updateAppShortcutParameters() // the preset names Siri knows, from the last context
    }

    var body: some Scene {
        WindowGroup {
            PresetsView(link: link)
                .onOpenURL { link.open($0) } // from the complications
                #if WIZ_ICLOUD
                // Handoff: carry on with the light on the iPhone or Mac.
                .userActivity(HandoffRoute.controls.activityType) { HandoffRoute.controls.fill($0) }
                #endif
        }
        .onChange(of: phase) { _, new in
            link.isActive = new == .active
            if new == .active {
                // The controls' taps, left while the app wasn't running, go first: a read ahead of
                // them could use up their time on the iPhone, and their replies bring the state.
                let left = WatchLinkInbox.take()
                for tap in left { link.open(tap.url, at: tap.at) }
                if left.isEmpty { link.refresh() }
            }
        }
    }
}

/// The main screen: power and the presets, with everything else a level down.
struct PresetsView: View {
    let link: PhoneLink
    /// The preset whose edit screen is open (swipe a preset, then Edit).
    @State private var editing: Preset?
    /// Every preset, not just the favourites.
    @State private var showAll = false

    var body: some View {
        NavigationStack {
            List {
                PowerRow(link: link)
                if let mismatch = link.snapshot?.mismatch {
                    MismatchText(text: mismatch)
                }
                ErrorRow(link: link)
                Section("Presets") {
                    // Stored by a newer build on the iPhone: why none can be saved or edited.
                    if link.presetsLocked {
                        Text("Your presets were saved by a newer version of setPilot. Update setPilot on your iPhone to see and edit them.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    } else if link.presets.isEmpty {
                        Text("Save presets here or in setPilot on your iPhone. Swipe one to edit it.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    if !showAll, !link.presets.isEmpty, link.presets.favourites.isEmpty {
                        Text("No favourites yet. Star presets from their edit screen (swipe one, then Edit).")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    ForEach(showAll ? link.presets : link.presets.favourites) { preset in
                        Button { link.send(.applyPreset(preset.id)) } label: {
                            HStack(spacing: 10) {
                                Swatch(rgb: swatch(preset.colour), isScene: preset.colour.isScene)
                                VStack(alignment: .leading, spacing: 0) {
                                    Text(preset.name).lineLimit(2)
                                    Text("\(preset.dimming)%")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                                if link.pending.contains(preset.id.uuidString) {
                                    Spacer(minLength: 4)
                                    ProgressView().accessibilityLabel("Applying")
                                }
                            }
                        }
                        .accessibilityValue(colourName(preset.colour))
                        .accessibilityHint("Applies the preset")
                        .swipeActions {
                            Button { editing = preset } label: { Label("Edit", systemImage: "pencil") }
                                .tint(.blue)
                                .disabled(link.presetsLocked)
                        }
                    }
                    // With favourites starred, those come first; the rest are a tap away.
                    if !link.presets.isEmpty {
                        Button(showAll ? "Favourites Only" : "All Presets") { showAll.toggle() }
                            .foregroundStyle(.secondary)
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
                    .disabled(link.snapshot?.canControl != true || link.presetsLocked)
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
        }
        // On the stack, not its root list: the list's task would be cancelled while a screen
        // (Controls, say) is pushed over it.
        .task { await link.poll() } // live updates while the app is open
    }

    /// The swatch in words, for VoiceOver ("warm white"), or the scene's name.
    private func colourName(_ colour: LightColour) -> String {
        switch colour {
        case let .scene(id, _): return Scenes.name(id)
        case let .custom(id, _): return link.scenes.first { $0.id == id }?.name ?? "a custom scene"
        default: return colour.colourName ?? ""
        }
    }

    private func swatch(_ colour: LightColour) -> RGB? {
        if case let .custom(id, _) = colour { return link.scenes.first { $0.id == id }?.swatch ?? nil }
        return colour.swatch
    }
}

/// Why the last action didn't work, on whichever screen it was done from.
struct ErrorRow: View {
    let link: PhoneLink

    var body: some View {
        if let error = link.error {
            Text(error)
                .font(.footnote)
                .foregroundStyle(.orange)
                .listRowBackground(Color.clear)
        }
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
    /// The switch as tapped, until the iPhone answers (or its next state comes): it doesn't jump
    /// back meanwhile.
    @State private var asked: Bool?
    /// Switches sent and not answered yet: `asked` stays until the last has.
    @State private var sending = 0

    var body: some View {
        let s = link.snapshot
        Toggle(isOn: Binding(get: { asked ?? s?.isOn ?? false }, set: { on in
            asked = on
            sending += 1
            link.send(.power(on)) { _ in
                sending -= 1
                if sending == 0 { asked = nil }
            }
        })) {
            VStack(alignment: .leading, spacing: 1) {
                Text(s?.bulbName ?? "Bulb").lineLimit(1)
                Text(statusText)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .disabled(s?.canControl != true || !link.reachable)
        // Waiting for the bulb to confirm: a spinner, as the iPhone and Mac show.
        .overlay(alignment: .trailing) {
            if link.pending.contains("power") { ProgressView().padding(.trailing, 44).accessibilityLabel("Switching") }
        }
        .handGestureShortcut(.primaryAction) // double tap (Series 9 and Ultra 2 on) switches it
    }

    private var statusText: String {
        if !link.reachable { return "Can't reach your iPhone" }
        if link.busy { return "Sending…" }
        guard let s = link.snapshot else { return "Waiting for your iPhone" }
        switch s.link {
        case .none: return "No bulb chosen on iPhone"
        case .connecting: return "Connecting…"
        case .unreachable: return "The bulb isn't answering. Open setPilot on your iPhone to check."
        case .connected:
            switch s.isOn {
            case true?: return "On · \(Int(s.dimming))%"
            case false?: return "Off"
            case nil: return "Reading…" // answering, its state not known yet (as the complications say)
            }
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
    /// Values being adjusted, until the last live change has been answered.
    @State private var pending: LightValues?

    var body: some View {
        let s = link.snapshot
        List {
            ErrorRow(link: link)
            ForEach(link.scenes) { scene in
                Button { link.send(.playCustom(scene.id, switchOn: true)) } label: {
                    HStack(spacing: 10) {
                        Swatch(rgb: scene.swatch, isScene: true)
                        Text(scene.name)
                        Spacer()
                        if link.pending.contains(scene.id.uuidString) {
                            ProgressView().accessibilityLabel("Starting")
                        } else if s?.customScene == scene.id {
                            Image(systemName: "play.fill").foregroundStyle(.secondary).accessibilityLabel("Playing")
                        }
                    }
                }
                .disabled(s?.canControl != true)
                .accessibilityValue(scene.swatch.map { ColourNames.name($0) } ?? "")
            }
            // While one of these is playing: the two settings that apply to it.
            if let s, s.canControl, let id = s.customScene, link.scenes.contains(where: { $0.id == id }) {
                Section("Playing") {
                    ValueRow(label: "Speed", value: binding(s, \.speed, .speed), range: 10...200)
                    ValueRow(label: "Brightness", value: binding(s, \.dimming, .dimming), range: s.minDimming...100, unit: "%")
                }
            }
        }
        .navigationTitle("Custom Scenes")
        .onChange(of: link.liveSettled) { pending = nil }
    }

    private func binding(_ s: LightSnapshot, _ kp: WritableKeyPath<LightValues, Double>, _ field: PilotField) -> Binding<Double> {
        // The snapshot as it is when asked, not as it was when drawn: a pushed editor may keep
        // the binding (as for the controls' fade time).
        Binding(
            get: { (pending ?? link.snapshot?.values ?? s.values)[keyPath: kp] },
            set: { new in
                var v = pending ?? link.snapshot?.values ?? s.values
                v[keyPath: kp] = new
                pending = v
                link.sendLive(v, fields: [field])
            }
        )
    }
}

/// The bulbs the iPhone has been used with; choosing one switches the iPhone (and watch) to it.
struct BulbsView: View {
    let link: PhoneLink
    @State private var renaming: KnownBulb?

    private func connectionText(_ s: LightSnapshot) -> String {
        switch s.link {
        case .none: "No bulb chosen"
        case .connecting: "Connecting…"
        case .connected: "Connected"
        case .unreachable: "Not answering"
        }
    }

    var body: some View {
        let s = link.snapshot
        let bulbs = (s?.bulbs ?? []).filter { !$0.address.isEmpty } // ones not found yet (WiZ import) need the iPhone
        List {
            ErrorRow(link: link)
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
                        if bulb.address == s?.address {
                            Image(systemName: "checkmark").foregroundStyle(.tint).accessibilityLabel("In use")
                        }
                    }
                }
                .swipeActions {
                    if bulb.mac != nil {
                        Button { renaming = bulb } label: { Label("Name", systemImage: "pencil") }
                            .tint(.blue)
                    }
                }
            }
            // Naming needs a MAC: a typed address that never answered has no swipe.
            Text(bulbs.isEmpty ? "Add a bulb in setPilot on your iPhone."
                 : bulbs.contains { $0.mac != nil } ? "Swipe a bulb to name it. Add bulbs in setPilot on your iPhone."
                 : "Add bulbs in setPilot on your iPhone.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .listRowBackground(Color.clear)
            if let s, s.link != .none {
                Section("This Bulb") {
                    LabeledContent("Connection", value: connectionText(s))
                    if s.link == .connected {
                        LabeledContent("Live updates", value: s.live != true ? "Off" : s.pushSeen == true ? "On" : "On (none yet)")
                    }
                    LabeledContent("MAC", value: s.mac ?? "—")
                    LabeledContent("Module", value: s.module ?? "—")
                    LabeledContent("Firmware", value: s.firmware ?? "—")
                    NavigationLink("Device Info") { WatchDeviceInfoView(link: link) }
                        .disabled(s.link != .connected)
                }
            }
            Section {
                LabeledContent("setPilot", value: BuildInfo.summary)
            }
        }
        .navigationTitle("Bulb")
        .navigationDestination(item: $renaming) { bulb in BulbNameView(link: link, bulb: bulb) }
    }
}

/// One preset: apply, rename, update to the current light, move, delete.
struct PresetEditView: View {
    let link: PhoneLink
    let presetID: UUID
    @State private var name = ""
    /// The preset's name as last seen, for the dialogs as they close after it's deleted.
    @State private var shownName = ""
    @State private var confirmingUpdate = false
    @State private var confirmingDelete = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let preset = link.presets.first { $0.id == presetID }
        List {
            ErrorRow(link: link)
            if let preset {
                Button { link.send(.applyPreset(preset.id)) } label: { Label("Apply", systemImage: "play.fill") }
                // Stored by a newer build on the iPhone: applied, but not edited (as Edit's swipe).
                let locked = link.presetsLocked
                TextField("Name", text: $name)
                    .onSubmit {
                        let n = name.trimmingCharacters(in: .whitespaces)
                        if !n.isEmpty, n != preset.name { link.send(.renamePreset(preset.id, name: n)) }
                    }
                    .disabled(locked)
                Button { confirmingUpdate = true } label: {
                    Label("Update to Current Light", systemImage: "arrow.triangle.2.circlepath")
                }
                .disabled(link.snapshot?.canControl != true || locked) // it reads the light
                Button { link.send(.favourite(preset.id, !preset.isFavourite)) } label: {
                    Label(preset.isFavourite ? "Remove from Favourites" : "Add to Favourites",
                          systemImage: preset.isFavourite ? "star.slash" : "star")
                }
                .disabled(locked)
                let i = link.presets.firstIndex { $0.id == presetID } ?? 0
                Button { link.send(.movePreset(presetID, by: -1)) } label: { Label("Move Up", systemImage: "arrow.up") }
                    .disabled(i == 0 || locked)
                Button { link.send(.movePreset(presetID, by: 1)) } label: { Label("Move Down", systemImage: "arrow.down") }
                    .disabled(i >= link.presets.count - 1 || locked)
                Button(role: .destructive) { confirmingDelete = true } label: { Label("Delete", systemImage: "trash") }
                    .disabled(locked)
            } else {
                Text(BulbReasons.presetGone).foregroundStyle(.secondary)
            }
        }
        .navigationTitle(preset?.name ?? "Preset")
        .onAppear {
            name = preset?.name ?? ""
            shownName = name
        }
        // The name for the dialogs once the preset has gone (deleting it closes them).
        .onChange(of: preset?.name) { _, n in
            guard let n else { return }
            if name == shownName { name = n } // renamed elsewhere, and not edited here
            shownName = n
        }
        .confirmationDialog("Replace “\(preset?.name ?? shownName)” with the current light?", isPresented: $confirmingUpdate,
                            titleVisibility: .visible) {
            Button("Update") { link.send(.updatePreset(presetID)) }
        }
        .confirmationDialog("Delete “\(preset?.name ?? shownName)”?", isPresented: $confirmingDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                link.send(.deletePreset(presetID))
                dismiss()
            }
        }
    }
}

/// Names a bulb (kept on the iPhone, by MAC).
struct BulbNameView: View {
    let link: PhoneLink
    let bulb: KnownBulb
    @State private var name = ""
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        List {
            ErrorRow(link: link)
            TextField("Name", text: $name)
                .onSubmit(save)
            Button("Save", action: save)
            if bulb.name != nil {
                Button("Remove Name", role: .destructive) {
                    name = ""
                    save()
                }
            }
            Text(bulb.address).font(.footnote).foregroundStyle(.secondary).listRowBackground(Color.clear)
        }
        .navigationTitle("Name")
        .onAppear { name = bulb.name ?? "" }
    }

    private func save() {
        guard let mac = bulb.mac else { return }
        link.send(.renameBulb(mac: mac, name: name))
        dismiss()
    }
}

/// Every read the bulb answers, as it sent them, one per screen.
struct WatchDeviceInfoView: View {
    let link: PhoneLink
    /// Read once per visit, not again on coming back from a read's screen.
    @State private var requested = false

    var body: some View {
        List {
            ErrorRow(link: link)
            if link.deviceInfo.isEmpty {
                HStack {
                    if link.busy { ProgressView().frame(width: 20) }
                    Text(link.busy ? "Reading…" : "Nothing read yet").foregroundStyle(.secondary)
                }
            }
            ForEach(link.deviceInfo) { entry in
                NavigationLink {
                    ScrollView {
                        Text(entry.text)
                            .font(.system(.caption2, design: .monospaced))
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .navigationTitle(entry.method)
                } label: {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(entry.method).lineLimit(1).minimumScaleFactor(0.7)
                        if let error = entry.error {
                            Text(error).font(.caption2).foregroundStyle(.orange)
                        }
                    }
                }
            }
        }
        .navigationTitle("Device Info")
        .onAppear {
            guard !requested else { return }
            requested = true
            link.readDeviceInfo()
        }
    }
}
