import SwiftUI

/// Asks before playing a custom scene or light show that flashes quickly (Flashing), from the
/// places a person starts one: Play on a scene, a preset of one, the light show's Play. The
/// question comes up in the window it was asked from; "Don't Ask Again" turns the question off
/// (Settings turns it back on), leaving the note on the scene or show.
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

/// A scene or preset started from outside the app's windows (Spotlight) that flashes: asked about
/// in the main window (the one guard given `outside`).
@MainActor @Observable
final class FlashingRequests {
    static let shared = FlashingRequests()
    struct Request {
        let id = UUID()
        let name: String
        let action: () -> Void
    }
    /// Waiting to be asked about, in turn (a second may come before the first is taken).
    var requests: [Request] = []

    func ask(_ name: String, _ action: @escaping () -> Void) {
        requests.append(Request(name: name, action: action))
        #if os(macOS)
        HandoffRouter.shared.open(.controls) // the main window, where it's asked
        #endif
    }
}

extension Flashing {
    /// Whether flashing scenes are asked about before they play.
    static var asks: Bool { UserDefaults.standard.object(forKey: askKey) as? Bool ?? true }
}

extension View {
    /// Where the question about flashing light is asked, for the views inside; with `outside`,
    /// also for scenes started from outside the app (FlashingRequests).
    /// `elsewhere`: a place that can't show the question (the Mac's menu bar panel) hands it to
    /// the main window.
    func flashingGuard(outside: Bool = false, elsewhere: Bool = false) -> some View {
        modifier(FlashingGuard(outside: outside, elsewhere: elsewhere))
    }
}

private struct FlashingGuard: ViewModifier {
    let outside: Bool
    let elsewhere: Bool
    @AppStorage(Flashing.askKey) private var asks = true
    @State private var pending: Pending?
    /// The name in the question, kept while it closes (pending is cleared first).
    @State private var shownName = ""

    struct Pending {
        let name: String
        let action: () -> Void
    }

    /// The question's title: the scene by name, or with none (the console's inline scene) just this.
    private func title(_ name: String) -> String {
        name.isEmpty ? "This scene flashes quickly" : "“\(name)” flashes quickly"
    }

    /// One question at a time: another asked meanwhile waits its turn.
    @State private var waiting: [Pending] = []

    private func ask(_ p: Pending) {
        if pending == nil { pending = p } else { waiting.append(p) }
    }

    private func next() {
        // Not asking any more ("Don't Ask Again"): the others asked meanwhile just go.
        guard asks else {
            let all = waiting
            waiting = []
            return all.forEach { $0.action() }
        }
        guard !waiting.isEmpty else { return }
        let p = waiting.removeFirst()
        DispatchQueue.main.async { // once this alert has gone
            // Another asked in the moment between: this one's still first.
            if pending == nil { pending = p } else { waiting.insert(p, at: 0) }
        }
    }

    func body(content: Content) -> some View {
        content
            .environment(\.confirmFlashing, ConfirmFlashing { name, flashes, action in
                guard asks && flashes else { return action() }
                if elsewhere { FlashingRequests.shared.ask(name, action) } else { ask(Pending(name: name, action: action)) }
            })
            .onChange(of: pending?.name) { _, name in if let name { shownName = name } }
            .onChange(of: FlashingRequests.shared.requests.map(\.id), initial: true) {
                guard outside, !FlashingRequests.shared.requests.isEmpty else { return }
                let all = FlashingRequests.shared.requests
                FlashingRequests.shared.requests = []
                for r in all {
                    if asks { ask(Pending(name: r.name, action: r.action)) } else { r.action() }
                }
            }
            .alert(title(pending?.name ?? shownName),
                   isPresented: Binding(get: { pending != nil }, set: { if !$0 { pending = nil; next() } }),
                   presenting: pending) { p in
                Button("Play") { p.action() }
                Button("Play, and Don't Ask Again") {
                    asks = false
                    p.action()
                }
                Button("Cancel", role: .cancel) {}
            } message: { _ in
                Text("It changes the light more than 3 times a second. Take care if you, or anyone who'll see it, is sensitive to flashing light.")
            }
    }
}

extension Preset {
    /// The same light (a favourite starred meanwhile doesn't count as a change).
    func sameLight(as other: Preset) -> Bool { colour == other.colour && dimming == other.dimming }
}

extension Model {
    /// Whether a custom scene flashes as it would play: at `speed`, or with none given, the
    /// speed the bulb's on (as fast as it may go: at least as timed).
    func flashes(_ scene: CustomScene, speed: Int? = nil) -> Bool {
        // Never slower than as timed (as the bulb's own speed is judged).
        scene.flashes(atSpeed: speed.map { max(100, $0) } ?? flashingSpeed)
    }

    /// The speed something with no speed of its own is judged at for flashing: the bulb's (at
    /// least as timed); not read yet (just launched, by a quick action say), the fastest.
    var flashingSpeed: Int { isOn == nil ? 200 : max(100, Int(speed)) }

    /// Plays a custom scene that was asked about: only as it was then (not edited or deleted
    /// meanwhile; the Mac's menu bar panel asks in the main window, others stay usable).
    func playAsked(_ scene: CustomScene) {
        guard library.customScene(scene.id) == scene else {
            status = "“\(scene.name)” was changed or deleted while being asked about; start it again."
            return
        }
        _ = playCustom(scene)
    }

    /// Whether a preset is the light it was when asked about (its scene too, if it's one).
    func unchanged(_ now: Preset?, asked: Preset, scene: CustomScene?) -> Bool {
        guard let now, now.sameLight(as: asked) else { return false }
        return library.customSceneOf(now.colour) == scene
    }

    /// Whether a colour plays a custom scene that flashes (at its own speed, if it has one).
    func flashes(_ colour: LightColour?) -> Bool {
        guard case let .custom(id, speed)? = colour, let scene = library.customScene(id) else { return false }
        return flashes(scene, speed: speed)
    }

    /// Whether a preset is asked about before it plays (one of a custom scene that flashes).
    func asksFirst(_ preset: Preset) -> Bool {
        Flashing.asks && flashes(preset.colour)
    }

    /// A preset a person started from a menu or a quick action: asked about first, in the main
    /// window, if it flashes; applied at once otherwise.
    func applyAsking(_ preset: Preset) {
        if asksFirst(preset) {
            let scene = library.customSceneOf(preset.colour)
            // Once confirmed, through the shared runner: it waits for the bulb if need be (a quick
            // action that launched the app), and the status says why if it doesn't go.
            FlashingRequests.shared.ask(preset.name) { [self] in
                // What was asked about: not a preset edited or deleted meanwhile.
                guard unchanged(library.presets.first(where: { $0.id == preset.id }), asked: preset, scene: scene) else {
                    status = "“\(preset.name)” was changed or deleted while being asked about; start it again."
                    return
                }
                Task { if let error = await Scripting.run(.preset(preset.id.uuidString), confirmed: true, on: self).error { status = error.message } }
            }
        } else {
            _ = apply(preset)
        }
    }
}
