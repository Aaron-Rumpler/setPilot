import Foundation

/// How long anything waits for the bulb, shared by the apps, the widgets and the watch, so every
/// path gives up at the same point (and nothing waits so long that a change lands late).
enum BulbTiming {
    /// When each try of a retried request goes, after the one before (the first at once).
    static let tryWaits: [Double] = [0.4, 0.8, 1.5, 1.5, 1.5]
    /// How long a retried request has to be answered before it's given up on.
    static let replyWindow = tryWaits.reduce(0, +)
    /// How long anything waits for the bulb: a request's retries, and a moment more.
    static let answerTimeout = replyWindow + 0.3
    /// After a wait for the bulb came to nothing, how long further waits fail at once.
    static let notAnsweringHold = 10.0
}

/// Why something didn't go, worded the same wherever it's said (the runner, widgets, the watch).
enum BulbReasons {
    #if os(iOS)
    static let notAnswering = "The bulb isn't answering. Check it's powered and on the same network as your iPhone."
    #else
    static let notAnswering = "The bulb isn't answering. Check it's powered and on the same network as your Mac."
    #endif
    static let presetGone = "That preset no longer exists."

    /// A scene that flashes, where it can't be asked about.
    static func flashes(_ name: String) -> String {
        "“\(name)” flashes quickly, so it's only started in setPilot, which asks first (or turn off Ask Before Playing in Settings)."
    }
}
