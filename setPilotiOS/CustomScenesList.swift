import SwiftUI

/// The custom scenes, each opening its editor.
struct CustomScenesList: View {
    let model: Model
    /// A scene just created, opened straight away.
    @State private var created: UUID?
    @State private var deleting: CustomScene?

    var body: some View {
        let lib = model.library
        List {
            ForEach(lib.customScenes) { scene in
                NavigationLink(value: scene.id) { CustomSceneRow(scene: scene) }
                    .swipeActions(edge: .leading) {
                        Button { model.playCustom(scene) } label: { Label("Play", systemImage: "play.fill") }
                            .tint(.green)
                            .disabled(!model.canControl)
                    }
                    .contextMenu {
                        Button { model.playCustom(scene) } label: { Label("Play on Bulb", systemImage: "play.fill") }
                            .disabled(!model.canControl)
                        Button { lib.duplicate(scene) } label: { Label("Duplicate", systemImage: "plus.square.on.square") }
                        Button(role: .destructive) { deleting = scene } label: { Label("Delete", systemImage: "trash") }
                    }
            }
            .onDelete { offsets in
                if let i = offsets.first { deleting = lib.customScenes[i] }
            }
            .onMove { lib.customScenes.move(fromOffsets: $0, toOffset: $1) }
        }
        .overlay {
            if lib.customScenes.isEmpty {
                ContentUnavailableView {
                    Label("No Custom Scenes", systemImage: "sparkles")
                } description: {
                    Text("Scenes of up to 12 steps, each with its own colour, level, hold and fade.")
                } actions: {
                    Button("New Scene") { created = lib.addCustomScene().id }
                }
            }
        }
        .navigationTitle("Custom Scenes")
        .navigationDestination(for: UUID.self) { id in CustomSceneEditor(model: model, sceneID: id) }
        .navigationDestination(item: $created) { id in CustomSceneEditor(model: model, sceneID: id) }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { created = lib.addCustomScene().id } label: { Label("New Scene", systemImage: "plus") }
            }
            if !lib.customScenes.isEmpty {
                ToolbarItem(placement: .topBarTrailing) { EditButton() }
            }
        }
        .confirmationDialog("Delete “\(deleting?.name ?? "")”?",
                            isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
                            titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                lib.customScenes.removeAll { $0.id == deleting?.id }
                deleting = nil
            }
        } message: {
            Text("Presets that use it will stop working.")
        }
    }
}
