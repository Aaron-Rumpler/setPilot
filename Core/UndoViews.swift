import SwiftUI

/// Puts the light back as it was before the last change made here (Model.undo).
struct UndoLightButton: View {
    let model: Model

    var body: some View {
        Button { model.undo() } label: {
            Label("Undo", systemImage: "arrow.uturn.backward")
        }
        .disabled(!model.canUndo)
        .help("Put the light back as it was before the last change")
        .accessibilityHint("Puts the light back as it was before the last change")
    }
}

/// Puts back the change last undone (Model.redo).
struct RedoLightButton: View {
    let model: Model

    var body: some View {
        Button { model.redo() } label: {
            Label("Redo", systemImage: "arrow.uturn.forward")
        }
        .disabled(!model.canRedo)
        .help("Put back the change last undone")
        .accessibilityHint("Puts back the change last undone")
    }
}

extension View {
    /// Gives the model this window's undo manager, for Edit › Undo, ⌘Z and shake to undo.
    func providesUndo(to model: Model) -> some View {
        modifier(UndoManagerLink(model: model))
    }
}

private struct UndoManagerLink: ViewModifier {
    let model: Model
    @Environment(\.undoManager) private var undoManager

    func body(content: Content) -> some View {
        content
            .onAppear { model.undoManager = undoManager }
            .onChange(of: undoManager) { _, new in model.undoManager = new }
    }
}
