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
