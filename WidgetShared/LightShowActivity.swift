#if os(iOS)
import ActivityKit
import AppIntents
import Foundation

/// The light show's Live Activity (Lock Screen, Dynamic Island, and the watch's Smart Stack):
/// what's playing, how far through, the current cue and its colour. Started and updated by the app
/// (Core/LightShowLiveActivity.swift); drawn by the widget extension.
struct LightShowAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        var playing: Bool
        /// Media seconds at `at`; while playing, the progress runs on from there by itself.
        var position: Double
        var at: Date
        var duration: Double
        var cue: String?
        var swatch: RGB?

        /// When the media started, as if played without a break (for the progress while playing).
        var start: Date { at.addingTimeInterval(-position) }
    }

    var title: String
    var show: String?
}

/// Play/pause and Stop on the Live Activity. Runs in the app (a Live Activity intent).
struct LightShowControlIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Control the Light Show"
    static let isDiscoverable = false

    @Parameter(title: "Action") var action: String

    init() {}
    init(_ action: LightShowControl.Action) { self.action = action.rawValue }

    @MainActor
    func perform() async throws -> some IntentResult {
        guard let a = LightShowControl.Action(rawValue: action) else { return .result() }
        if let handler = LightShowControl.handler {
            handler(a)
        } else if a == .stop {
            // No show open (the app was quit or killed with one playing): the activity's left over.
            for activity in Activity<LightShowAttributes>.activities { await activity.end(nil, dismissalPolicy: .immediate) }
        }
        return .result()
    }
}

@MainActor
enum LightShowControl {
    enum Action: String { case toggle, stop }
    /// Set by the app while a show is open.
    static var handler: ((Action) -> Void)?
}
#endif
