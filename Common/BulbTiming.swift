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
    /// The device the bulb is controlled from (the watch's iPhone, for the watch).
    private static var device: String {
        #if os(macOS)
        "Mac"
        #elseif os(iOS)
        isPad ? "iPad" : "iPhone"
        #else
        "iPhone"
        #endif
    }
    #if os(iOS)
    /// From the hardware model ("iPad13,4"), which any thread (and the widgets) can read; the
    /// simulator gives its own in the environment.
    private static let isPad: Bool = {
        if let sim = ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"] { return sim.hasPrefix("iPad") }
        var info = utsname()
        uname(&info)
        let machine = withUnsafeBytes(of: info.machine) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
        return machine.hasPrefix("iPad")
    }()
    #endif
    static var notAnswering: String { "The bulb isn't answering. Check it's powered and on the same network as your \(device)." }
    static let presetGone = "That preset no longer exists."
    static let sceneGone = "That custom scene no longer exists."
    static let presetPartGone = "That preset can't be sent: its custom scene or CCT scale has been deleted."

    /// The setting that turns the question about flashing off, as Settings labels it.
    #if os(macOS)
    private static let askSetting = "“Ask before playing it”"
    #else
    private static let askSetting = "“Ask Before Playing It”"
    #endif

    #if os(watchOS)
    private static let whereAsked = "in setPilot on your iPhone"
    #else
    private static let whereAsked = "in setPilot"
    #endif

    /// A scene that flashes, where it can't be asked about.
    static func flashes(_ name: String) -> String {
        "“\(name)” flashes quickly, so it's only started \(whereAsked), which asks first (or turn off \(askSetting) in setPilot's Settings)."
    }
}
