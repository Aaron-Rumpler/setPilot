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
    private static let key = "shared.pendingLink"

    static func post(_ link: String) {
        guard let url = URL(string: link) else { return }
        if let handler { handler(url) } else { SharedStore.defaults.set(link, forKey: key) }
    }

    /// A link left for the app, once.
    static func take() -> URL? {
        guard let link = SharedStore.defaults.string(forKey: key) else { return nil }
        SharedStore.defaults.removeObject(forKey: key)
        return URL(string: link)
    }
}
#endif
