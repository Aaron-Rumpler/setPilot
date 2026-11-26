import SwiftUI

/// The Custom Scenes window: the scenes on the left, the selected one's steps on the right.
struct CustomScenesWindow: View {
    @Environment(\.confirmFlashing) private var confirmFlashing
    let model: Model
    @State private var selection: UUID?
    @State private var deleting: CustomScene?
    /// The name in the delete confirmation, kept while it closes (deleting is cleared first).
    @State private var deletingName = ""

    var body: some View {
        let lib = model.library
        NavigationSplitView {
            List(selection: $selection) {
                ForEach(lib.customScenes) { scene in
                    CustomSceneRow(scene: scene)
                        .tag(scene.id)
                        .contextMenu {
                            Button("Play on Bulb") {
                                // A number still being typed in the editor reaches the scene once
                                // its field ends editing.
                                NSApp.keyWindow?.makeFirstResponder(nil)
                                DispatchQueue.main.async {
                                    if let s = lib.customScene(scene.id) {
                                        confirmFlashing(s.name, flashes: model.flashes(s)) { model.playAsked(s) }
                                    }
                                }
                            }
                            .disabled(!model.canControl)
                            Button("Duplicate") { selection = lib.duplicate(scene).id }
                            ShareLink(item: SharedItem.scene(scene), preview: SharePreview(scene.name))
                            if let link = SharedItem.scene(scene).link { Button("Copy Link") { Pasteboard.copy(link.absoluteString) } }
                            Divider()
                            Button("Delete…", role: .destructive) { deleting = scene }
                        }
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
                        Button("New Scene") { selection = lib.addCustomScene().id }
                    }
                }
            }
            .navigationSplitViewColumnWidth(min: 200, ideal: 220)
            .toolbar {
                ToolbarItem {
                    Button { selection = lib.addCustomScene().id } label: { Label("New Scene", systemImage: "plus") }
                        .help("New custom scene")
                }
            }
        } detail: {
            if let selection, lib.customScene(selection) != nil {
                CustomSceneEditor(model: model, sceneID: selection)
                    .id(selection)
                    .handoff(.customScene(selection))
            } else {
                Text(lib.customScenes.isEmpty ? "" : "Select a scene").foregroundStyle(.secondary)
                    .handoff(.customScenes)
            }
        }
        .onDeleteCommand { if let id = selection { deleting = lib.customScene(id) } }
        .onChange(of: deleting?.name) { _, name in if let name { deletingName = name } }
        .confirmationDialog("Delete “\(deleting?.name ?? deletingName)”?",
                            isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
                            presenting: deleting) { d in
            Button("Delete", role: .destructive) {
                lib.customScenes.removeAll { $0.id == d.id }
                if selection == d.id { selection = nil }
                deleting = nil
            }
        } message: { _ in
            Text("Presets that use it will stop working.")
        }
        .onAppear { if selection == nil { selection = lib.customScenes.first?.id } }
        .flashingGuard()
        // Handoff from another device (setPilot/App.swift opens this window).
        .onChange(of: HandoffRouter.shared.sceneToSelect, initial: true) { _, id in
            guard let id else { return }
            HandoffRouter.shared.sceneToSelect = nil
            if lib.customScene(id) != nil { selection = id } // not synced here yet: leave it
        }
    }
}
