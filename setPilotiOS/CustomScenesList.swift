import SwiftUI

/// The custom scenes, each opening its editor.
struct CustomScenesList: View {
    @Environment(\.confirmFlashing) private var confirmFlashing
    let model: Model
    /// A scene just created, opened straight away.
    @State private var created: UUID?
    @State private var deleting: CustomScene?
    /// The name in the delete confirmation, kept while it closes (deleting is cleared first).
    @State private var deletingName = ""

    var body: some View {
        let lib = model.library
        // Not while the stored scenes are a newer build's: nothing here would reach them, or iCloud.
        let locked = !lib.canEdit(Library.customScenesKey)
        List {
            // Stored by a newer build this one can't read (some taken from iCloud meanwhile are
            // listed): why they can't be added to or changed. Empty, the overlay says it.
            if !lib.customScenes.isEmpty, let note = lib.newerNote(Library.customScenesKey) {
                Text(note).font(.footnote).foregroundStyle(.secondary)
            }
            ForEach(lib.customScenes) { scene in
                NavigationLink(value: scene.id) { CustomSceneRow(scene: scene) }
                    .swipeActions(edge: .leading) {
                        Button { confirmFlashing(scene.name, flashes: model.flashes(scene)) { model.playAsked(scene) } } label: { Label("Play", systemImage: "play.fill") }
                            .tint(.green)
                            .disabled(!model.canControl)
                    }
                    // A row with swipe actions loses onDelete's swipe, so Delete is given here.
                    .swipeActions(edge: .trailing) {
                        // Not .destructive: that takes the row away at once, before the confirmation.
                        Button { deleting = scene } label: { Label("Delete", systemImage: "trash") }
                            .tint(.red)
                            .disabled(locked)
                    }
                    .contextMenu {
                        Button { confirmFlashing(scene.name, flashes: model.flashes(scene)) { model.playAsked(scene) } } label: { Label("Play on Bulb", systemImage: "play.fill") }
                            .disabled(!model.canControl)
                        Button { lib.duplicate(scene) } label: { Label("Duplicate", systemImage: "plus.square.on.square") }
                            .disabled(locked)
                        ShareLink(item: SharedItem.scene(scene, from: lib), preview: SharePreview(scene.name))
                        if let link = SharedItem.scene(scene, from: lib).link {
                            Button { Pasteboard.copy(link.absoluteString) } label: { Label("Copy Link", systemImage: "link") }
                        }
                        Button(role: .destructive) { deleting = scene } label: { Label("Delete", systemImage: "trash") }
                            .disabled(locked)
                    }
            }
            .onDelete(perform: locked ? nil : delete)
            .onMove(perform: locked ? nil : move)
        }
        .overlay {
            if lib.customScenes.isEmpty {
                ContentUnavailableView {
                    Label("No Custom Scenes", systemImage: "sparkles")
                } description: {
                    Text(lib.newerNote(Library.customScenesKey) ?? "Scenes of up to 12 steps, each with its own colour, level, hold and fade.")
                } actions: {
                    Button("New Scene") { created = lib.addCustomScene().id }
                        .disabled(!lib.canEdit(Library.customScenesKey))
                }
            }
        }
        .navigationTitle("Custom Scenes")
        .handoff(.customScenes)
        .navigationDestination(for: UUID.self) { id in CustomSceneEditor(model: model, sceneID: id).handoff(.customScene(id)) }
        .navigationDestination(item: $created) { id in CustomSceneEditor(model: model, sceneID: id).handoff(.customScene(id)) }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { created = lib.addCustomScene().id } label: { Label("New Scene", systemImage: "plus") }
                    .disabled(!lib.canEdit(Library.customScenesKey))
            }
            if !lib.customScenes.isEmpty, !locked {
                ToolbarItem(placement: .topBarTrailing) { EditButton() }
            }
        }
        .onChange(of: deleting?.name) { _, name in if let name { deletingName = name } }
        .confirmationDialog("Delete “\(deleting?.name ?? deletingName)”?",
                            isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
                            titleVisibility: .visible,
                            presenting: deleting) { d in
            Button("Delete", role: .destructive) {
                if lib.canEdit(Library.customScenesKey) { lib.customScenes.removeAll { $0.id == d.id } }
                deleting = nil
            }
        } message: { _ in
            Text("Presets that use it will stop working.")
        }
    }

    private func delete(_ offsets: IndexSet) {
        if let i = offsets.first { deleting = model.library.customScenes[i] }
    }

    private func move(_ from: IndexSet, _ to: Int) {
        model.library.customScenes.move(fromOffsets: from, toOffset: to)
    }
}
