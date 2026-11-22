import SwiftUI

/// Asks before playing a custom scene or light show that flashes quickly (Flashing), from the
/// places a person starts one: Play on a scene, a preset of one, the light show's Play. The
/// question comes up in the window it was asked from; "Don't Ask Again" turns the warning off
/// (Settings turns it back on).
struct ConfirmFlashing {
    fileprivate var run: (_ name: String, _ flashes: Bool, _ action: @escaping () -> Void) -> Void = { _, _, action in action() }

    func callAsFunction(_ name: String, flashes: Bool, _ action: @escaping () -> Void) {
        run(name, flashes, action)
    }
}

private struct ConfirmFlashingKey: EnvironmentKey {
    static let defaultValue = ConfirmFlashing()
}

extension EnvironmentValues {
    var confirmFlashing: ConfirmFlashing {
        get { self[ConfirmFlashingKey.self] }
        set { self[ConfirmFlashingKey.self] = newValue }
    }
}

extension View {
    /// Where the question about flashing light is asked, for the views inside.
    func flashingGuard() -> some View { modifier(FlashingGuard()) }
}

private struct FlashingGuard: ViewModifier {
    @AppStorage(Flashing.warnKey) private var warns = true
    @State private var pending: Pending?
    /// The name in the question, kept while it closes (pending is cleared first).
    @State private var shownName = ""

    struct Pending {
        let name: String
        let action: () -> Void
    }

    func body(content: Content) -> some View {
        content
            .environment(\.confirmFlashing, ConfirmFlashing { name, flashes, action in
                if warns && flashes { pending = Pending(name: name, action: action) } else { action() }
            })
            .onChange(of: pending?.name) { _, name in if let name { shownName = name } }
            .alert("“\(pending?.name ?? shownName)” flashes quickly",
                   isPresented: Binding(get: { pending != nil }, set: { if !$0 { pending = nil } }),
                   presenting: pending) { p in
                Button("Play") { p.action() }
                Button("Play, and Don't Ask Again") {
                    warns = false
                    p.action()
                }
                Button("Cancel", role: .cancel) {}
            } message: { _ in
                Text("It changes the light more than 3 times a second. Take care if you, or anyone who'll see it, is sensitive to flashing light.")
            }
    }
}
