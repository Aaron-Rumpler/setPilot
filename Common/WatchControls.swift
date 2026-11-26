#if os(watchOS)
import AppIntents
import Foundation

/// What the watch's controls (Control Center, the Smart Stack, the Action button) do: they can't
/// reach the iPhone themselves (only the watch app can), so they open the app with a setpilot://
/// link, as the complications do. In both the app and its widget extension, so it runs in the app.
struct WatchLinkIntent: AppIntent {
    static let title: LocalizedStringResource = "Open setPilot"
    static let isDiscoverable = false
    static let openAppWhenRun = true

    @Parameter(title: "Link") var link: String

    init() {}
    init(link: String) { self.link = link }

    @MainActor
    func perform() async throws -> some IntentResult {
        WatchLinkInbox.post(link)
        return .result()
    }
}

/// Links from the controls: handled straight away in the app, or kept until it's running.
@MainActor
enum WatchLinkInbox {
    /// Set by the app.
    static var handler: ((URL) -> Void)?
    private static let key = "shared.pendingLinks"

    static func post(_ link: String) {
        guard let url = URL(string: link) else { return }
        if let handler {
            handler(url)
        } else {
            // Kept in order, each with when it was tapped (two taps of Brighter are two steps).
            var left = SharedStore.defaults.array(forKey: key) as? [[String: Any]] ?? []
            left.append(["link": link, "at": Date.now.timeIntervalSince1970])
            SharedStore.defaults.set(Array(left.suffix(10)), forKey: key)
        }
    }

    /// The links left for the app, once, oldest first, each with when it was tapped (the app
    /// drops one tapped too long ago: a change mustn't land late).
    static func take() -> [(url: URL, at: Date)] {
        let defaults = SharedStore.defaults
        let left = defaults.array(forKey: key) as? [[String: Any]] ?? []
        defaults.removeObject(forKey: key)
        return left.compactMap { entry in
            guard let url = (entry["link"] as? String).flatMap(URL.init(string:)), let at = entry["at"] as? Double else { return nil }
            return (url, Date(timeIntervalSince1970: at))
        }
    }
}
#endif
