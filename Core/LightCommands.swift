import SwiftUI

// The Mac's menu bar, and the iPad's with a hardware keyboard (hold ⌘ for the list).

/// The Light menu: power, and the first nine presets on ⌘1–⌘9.
struct LightCommands: Commands {
    let model: Model

    var body: some Commands {
        CommandMenu("Light") {
            Button(model.isOn == true ? "Switch Off" : "Switch On") { model.power(model.isOn != true) }
                .keyboardShortcut("p", modifiers: [.command, .shift])
                .disabled(!model.canControl)
            Button("Undo Light Change") { model.undo() } // also Edit › Undo (⌘Z)
                .disabled(!model.canUndo)
            Button("Redo Light Change") { model.redo() } // also Edit › Redo (⇧⌘Z)
                .disabled(!model.canRedo)
            Button("Sync") { model.sync() }
                .disabled(model.link == .none)
            Divider()
            let presets = Array(model.library.presets.prefix(9).enumerated())
            if presets.isEmpty {
                Button("No Presets") {}.disabled(true)
            }
            ForEach(presets, id: \.element.id) { i, preset in
                Button(preset.name) { model.applyAsking(preset) }
                    .keyboardShortcut(KeyEquivalent(Character(String(i + 1))), modifiers: .command)
                    .disabled(model.link != .connected)
            }
        }
    }
}
