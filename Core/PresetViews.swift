import SwiftUI

/// The presets as a grid of tiles: tap to apply. A context menu renames, updates, moves and
/// deletes them.
struct PresetGrid: View {
    @Environment(\.confirmFlashing) private var confirmFlashing
    let model: Model
    /// Fixed columns, or nil for as many as fit.
    var columns: Int? = nil
    /// Only the favourites (if any are starred): the menu bar panel.
    var featuredOnly = false
    @State private var renaming: Preset?
    @State private var newName = ""
    @State private var deleting: Preset?
    /// The name in the delete confirmation, kept while it closes (deleting is cleared first).
    @State private var deletingName = ""
    /// Which prompt each tile last opened (rename true, delete false), kept while it closes:
    /// deciding by `renaming`, which closing clears, showed the delete prompt for a moment as a
    /// rename prompt faded out. Per tile, so another tile's prompt can't change it meanwhile.
    @State private var promptIsRename: [UUID: Bool] = [:]
    /// The tiles' narrowest, wider with larger text so names have room (iPhone and iPad).
    @ScaledMetric private var tileWidth: CGFloat = 96

    var body: some View {
        let lib = model.library
        Group {
            if featuredOnly, !lib.presets.isEmpty, lib.presets.favourites.isEmpty {
                Text(Favourites.none)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else if lib.presets.isEmpty {
                Text("No presets yet. Set up the light, then save it as a preset.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                LazyVGrid(columns: gridColumns, spacing: 8) {
                    ForEach(featuredOnly ? lib.presets.favourites : lib.presets) { preset in
                        Button {
                            let flashes = model.flashes(preset.colour)
                            let scene = model.library.customSceneOf(preset.colour)
                            confirmFlashing(preset.name, flashes: flashes) {
                                // As asked about: not if it's been edited or deleted meanwhile (the Mac's
                                // menu bar panel asks in the main window).
                                guard let now = model.library.presets.first(where: { $0.id == preset.id }),
                                      model.unchanged(now, asked: preset, scene: scene) else {
                                    model.status = "“\(preset.name)” was changed or deleted while being asked about; start it again."
                                    return
                                }
                                model.apply(now)
                            }
                        } label: {
                            PresetTile(name: preset.name, swatch: lib.swatch(preset.colour),
                                       isScene: preset.colour.isScene, isFavourite: preset.isFavourite)
                        }
                        .buttonStyle(.plain)
                        #if os(iOS)
                        .hoverEffect(.lift) // the iPad's pointer
                        #endif
                        .disabled(model.link != .connected)
                        .accessibilityLabel(preset.name)
                        .accessibilityValue("\(lib.spokenName(of: preset.colour)), \(preset.dimming)%")
                        .accessibilityHint("Applies the preset")
                        .help("\(lib.name(of: preset.colour)), \(preset.dimming)%")
                        .contextMenu { menu(for: preset) }
                        #if os(macOS)
                        // Popovers, not an alert: the grid is also in the menu bar panel, which
                        // can't show alerts.
                        .popover(isPresented: prompting(preset), arrowEdge: .bottom) { prompt(for: preset) }
                        #endif
                    }
                }
            }
        }
        #if os(iOS)
        // presenting: the preset is handed to the buttons, so it doesn't matter whether dismissing
        // clears `renaming` before or after their actions run.
        .alert("Rename Preset", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } }),
               presenting: renaming) { p in
            TextField("Name", text: $newName)
            Button("Rename") {
                model.renamePreset(p.id, to: newName)
                renaming = nil
            }
            Button("Cancel", role: .cancel) { renaming = nil }
        }
        .onChange(of: deleting?.name) { _, name in if let name { deletingName = name } }
        .confirmationDialog("Delete “\(deleting?.name ?? deletingName)”?",
                            isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
                            presenting: deleting) { p in
            Button("Delete", role: .destructive) {
                lib.presets.removeAll { $0.id == p.id }
                deleting = nil
            }
        }
        #endif
    }

    #if os(macOS)
    /// Renaming or deleting this preset.
    private func prompting(_ preset: Preset) -> Binding<Bool> {
        Binding(get: { renaming?.id == preset.id || deleting?.id == preset.id },
                set: { if !$0 { renaming = nil; deleting = nil } })
    }

    @ViewBuilder private func prompt(for preset: Preset) -> some View {
        if promptIsRename[preset.id] ?? true {
            NamePrompt(title: "Rename Preset", name: $newName,
                       onSave: {
                           model.renamePreset(preset.id, to: newName)
                           renaming = nil
                       },
                       onCancel: { renaming = nil })
        } else {
            ConfirmPrompt(title: "Delete “\(preset.name)”?", actionTitle: "Delete",
                          onConfirm: {
                              model.library.presets.removeAll { $0.id == preset.id }
                              deleting = nil
                          },
                          onCancel: { deleting = nil })
        }
    }
    #endif

    private var gridColumns: [GridItem] {
        if let columns { return Array(repeating: GridItem(.flexible(), spacing: 8), count: columns) }
        return [GridItem(.adaptive(minimum: tileWidth), spacing: 8)]
    }

    /// Swaps a preset with its neighbour among the tiles shown (looked up now, by ID).
    private func move(_ id: UUID, by offset: Int) {
        let lib = model.library
        let shown = featuredOnly ? lib.presets.favourites : lib.presets
        guard let i = shown.firstIndex(where: { $0.id == id }), shown.indices.contains(i + offset) else { return }
        let other = shown[i + offset].id
        guard let a = lib.presets.firstIndex(where: { $0.id == id }),
              let b = lib.presets.firstIndex(where: { $0.id == other }) else { return }
        lib.presets.swapAt(a, b)
    }

    @ViewBuilder private func menu(for preset: Preset) -> some View {
        let lib = model.library
        // Moves among the tiles shown: with only favourites showing, past the next favourite.
        let shown = featuredOnly ? lib.presets.favourites : lib.presets
        let i = shown.firstIndex(where: { $0.id == preset.id }) ?? 0
        Button("Rename…") {
            newName = preset.name
            promptIsRename[preset.id] = true
            renaming = preset
        }
        Button("Update to Current Light") { model.updatePreset(preset.id) }
        .disabled(model.currentColour == nil || !model.canControl)
        Button(preset.isFavourite ? "Remove from Favourites" : "Add to Favourites") {
            model.setFavourite(preset.id, !preset.isFavourite)
        }
        let shared = SharedItem.preset(preset, from: lib)
        ShareLink(item: shared, preview: SharePreview(preset.name))
        if let link = shared.link {
            Button("Copy Link") { Pasteboard.copy(link.absoluteString) }
        }
        Divider()
        // By ID, not the index the menu was built with: the presets can change while it's open
        // (iCloud, or the watch).
        Button("Move Left") { move(preset.id, by: -1) }.disabled(i == 0)
        Button("Move Right") { move(preset.id, by: 1) }.disabled(i >= shown.count - 1)
        Divider()
        Button("Delete…", role: .destructive) {
            promptIsRename[preset.id] = false
            deleting = preset
        }
    }
}

/// A swatch with the preset's name under it.
struct PresetTile: View {
    let name: String
    let swatch: RGB?
    var isScene = false
    var isFavourite = false

    var body: some View {
        VStack(spacing: 4) {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill((swatch?.color ?? .gray).gradient)
                .overlay {
                    if isScene {
                        Image(systemName: "sparkles")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.white)
                            .shadow(radius: 1)
                    }
                }
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(.separator))
                .overlay(alignment: .topTrailing) {
                    if isFavourite {
                        Image(systemName: "star.fill")
                            .font(.caption2)
                            .foregroundStyle(.white)
                            .shadow(radius: 1)
                            .padding(3)
                            .accessibilityLabel("Favourite")
                    }
                }
                .frame(height: 34)
            Text(name)
                .font(.caption)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity)
        }
        .contentShape(Rectangle())
    }
}

/// "Save Current Light…": asks for a name, then saves the light as it is now.
struct SavePresetButton: View {
    let model: Model
    var title = "Save Current Light…"
    @State private var asking = false
    @State private var name = ""

    var body: some View {
        Button(title) {
            name = model.library.uniquePresetName(suggestedName)
            asking = true
        }
        .disabled(!model.canControl || model.currentColour == nil)
        .help("Save the light as it is now as a preset")
        .alert("Save as Preset", isPresented: $asking) {
            TextField("Name", text: $name)
            Button("Save") { model.savePreset(named: name) }
            Button("Cancel", role: .cancel) {}
        }
    }

    private var suggestedName: String {
        guard let colour = model.currentColour else { return "Preset" }
        switch colour {
        case .temp(let k): return "\(k) K"
        case .scene(let id, _): return Scenes.name(id)
        case .custom(let id, _): return model.library.customScene(id)?.name ?? "Preset"
        case .customCCT(_, let k): return "\(k) K"
        case .rgbcw: return "Preset"
        }
    }
}

/// A scene in a picker: one of the bulb's or one of ours.
enum SceneChoice: Hashable {
    case builtin(Int)
    case custom(UUID)
}

extension Model {
    /// The scene in use, as the picker lists it.
    var currentSceneChoice: SceneChoice {
        if sceneId == Scenes.inlineCustom, let id = customSceneId { return .custom(id) }
        return .builtin(sceneId)
    }

    /// The Scene picker's selection: a flashing custom scene is asked about first (`confirm`, the
    /// window's), as everywhere a person starts one.
    func sceneChoice(_ confirm: ConfirmFlashing) -> Binding<SceneChoice> {
        Binding(
            get: { self.currentSceneChoice },
            set: { choice in
                switch choice {
                case .builtin(let id): self.setScene(id)
                case .custom(let id):
                    guard let s = self.library.customScene(id) else { return }
                    confirm(s.name, flashes: self.flashes(s)) { self.playAsked(s) }
                }
            }
        )
    }

    /// The current scene isn't one the picker lists (Rhythm, a newer ID, a deleted custom scene).
    var sceneIsUnlisted: Bool {
        if sceneId == Scenes.inlineCustom { return customSceneId.flatMap(library.customScene) == nil }
        return !Scenes.isKnown(sceneId)
    }
}

/// The scene picker's items: the bulb's scenes, then ours, then whatever the bulb reported.
struct SceneMenuItems: View {
    let model: Model

    var body: some View {
        // Sections, not Dividers: on iPhone the picker is a list, where a Divider is an empty row
        // (in a menu, sections are divided the same).
        Section { ForEach(Scenes.all) { Text($0.name).tag(SceneChoice.builtin($0.id)) } }
        if !model.library.customScenes.isEmpty {
            Section { ForEach(model.library.customScenes) { Text($0.name).tag(SceneChoice.custom($0.id)) } }
        }
        if model.sceneIsUnlisted {
            Section { Text(Scenes.name(model.sceneId)).tag(model.currentSceneChoice) }
        }
    }
}

/// The Scene picker, asking about a flashing custom scene in the window it's in.
struct ScenePicker: View {
    let model: Model
    @Environment(\.confirmFlashing) private var confirmFlashing

    var body: some View {
        Picker("Scene", selection: model.sceneChoice(confirmFlashing)) { SceneMenuItems(model: model) }
    }
}
