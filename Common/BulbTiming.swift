import Foundation

/// How long anything waits for the bulb, shared by the apps, the widgets and the watch, so every
/// path gives up at the same point (and nothing waits so long that a change lands late).
enum BulbTiming {
    /// How long each of a retried request's tries waits for an answer before the next goes (the
    /// first goes at once; after the last, it's given up on).
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

    /// A scene that flashes, where it can't be asked about. `fromWatch`: asked for on the watch
    /// (judged on the iPhone, which words it for the watch). `unknown`: one that can't be judged
    /// (stored on the bulb), so it may.
    static func flashes(_ name: String, fromWatch: Bool = false, unknown: Bool = false) -> String {
        let what = unknown ? "may flash quickly (setPilot can't tell how fast it changes the light)" : "flashes quickly"
        return "“\(name)” \(what), so it's only started \(startedIn(fromWatch)), which asks first (or turn off \(askSetting) in setPilot's Settings)."
    }

    /// One of the bulb's stored scenes (Custom Mode 1–10), which scripting never starts: it can't
    /// be judged for flashing, so with `asks` it's refused as one that may flash, and without, it's
    /// still only started in setPilot. `preset`: the preset of it that was asked for, if one was.
    static func stored(_ name: String, preset: String? = nil, asks: Bool, fromWatch: Bool = false) -> String {
        if asks { return flashes(preset ?? name, fromWatch: fromWatch, unknown: true) }
        let what = preset.map { "“\($0)” plays “\(name)”, which" } ?? "“\(name)”"
        return "\(what) is stored on the bulb, so it's only started \(startedIn(fromWatch))."
    }

    /// Where a scene that scripting won't start is started (the iPhone, for the watch).
    private static func startedIn(_ fromWatch: Bool) -> String {
        #if os(watchOS)
        let watch = true
        #else
        let watch = fromWatch
        #endif
        return watch ? "in setPilot on your iPhone" : "in setPilot"
    }
}
