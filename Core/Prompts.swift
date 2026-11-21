import SwiftUI

// Small prompts for popovers. On the Mac an alert is a sheet on its window, and the menu bar
// panel isn't a window that can take one: an alert from there can't be typed into or dismissed.

/// Asks for a name: Save (Return), Cancel (Escape), and optionally a destructive Remove.
struct NamePrompt: View {
    let title: String
    var message: String? = nil
    @Binding var name: String
    var placeholder = "Name"
    /// Shown (as a destructive button) only when given.
    var removeTitle: String? = nil
    var onRemove: (() -> Void)? = nil
    let onSave: () -> Void
    let onCancel: () -> Void
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.headline)
            if let message {
                Text(message).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            TextField(placeholder, text: $name)
                .textFieldStyle(.roundedBorder)
                .focused($focused)
                .onSubmit(onSave)
            HStack {
                if let removeTitle, let onRemove {
                    Button(removeTitle, role: .destructive, action: onRemove)
                }
                Spacer()
                Button("Cancel", role: .cancel, action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button("Save", action: onSave)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(14)
        .frame(width: 300)
        .onAppear { focused = true }
    }
}

/// Asks before doing something that can't be undone.
struct ConfirmPrompt: View {
    let title: String
    var message: String? = nil
    let actionTitle: String
    let onConfirm: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.headline)
            if let message {
                Text(message).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel, action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button(actionTitle, role: .destructive, action: onConfirm)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(14)
        .frame(width: 300)
    }
}
