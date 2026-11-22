import SwiftUI

/// Where Handoff asked to go, for whichever view can take it there (the Mac's windows, the
/// iPhone's navigation).
@MainActor @Observable
final class HandoffRouter {
    static let shared = HandoffRouter()
    /// Set when another device's activity is continued here; cleared by whoever acts on it.
    var request: HandoffRoute?
    /// The scene or scale to select once its window or list is showing (the Mac).
    var sceneToSelect: UUID?
    var scaleToSelect: UUID?
    /// A light show to open where another device was (LastShow.handoffInfo), once its screen shows.
    var lightShowResume: [String: Any]?

    func open(_ route: HandoffRoute, info: [String: Any]? = nil) {
        switch route {
        case .customScene(let id): sceneToSelect = id
        case .cctScale(let id): scaleToSelect = id
        case .lightShow: if let info, info["media"] != nil || info["show"] != nil { lightShowResume = info }
        case .controls:
            // A Compose draft from the other device: carried on here, in Compose.
            if let draft = info?["draft"] as? [String: Any] {
                Shared.model.draft.take(draft)
                Shared.model.composing = true
            }
        default: break
        }
        request = route
    }
}

extension View {
    /// Offers this place to the user's other devices through Handoff while the view is showing.
    /// Nothing in builds without iCloud.
    func handoff(_ route: HandoffRoute?) -> some View {
        modifier(HandoffAdvertiser(route: route))
    }

    /// Takes activities continued from another device (every setPilot type), with what they carry.
    func onContinueHandoff(_ perform: @escaping (HandoffRoute, [String: Any]?) -> Void) -> some View {
        modifier(HandoffReceiver(perform: perform))
    }
}

private struct HandoffAdvertiser: ViewModifier {
    let route: HandoffRoute?
    /// Only while it's on screen: a view under a pushed one stays alive, but isn't where you are.
    @State private var showing = false

    func body(content: Content) -> some View {
        #if WIZ_ICLOUD
        content
            .onAppear { showing = true }
            .onDisappear { showing = false }
            .userActivity(route?.activityType ?? HandoffRoute.types[0], isActive: showing && route != nil) { activity in
                route?.fill(activity)
                if route == .lightShow { activity.addUserInfoEntries(from: LastShow.handoffInfo(LightShowPlayer.current)) }
                if route == .controls, Shared.model.composing { activity.addUserInfoEntries(from: ["draft": Shared.model.draft.handoffInfo]) }
            }
        #else
        content
        #endif
    }
}

private struct HandoffReceiver: ViewModifier {
    let perform: (HandoffRoute, [String: Any]?) -> Void

    func body(content: Content) -> some View {
        #if WIZ_ICLOUD
        content
            .onContinueUserActivity(HandoffRoute.types[0], perform: take)
            .onContinueUserActivity(HandoffRoute.types[1], perform: take)
            .onContinueUserActivity(HandoffRoute.types[2], perform: take)
            .onContinueUserActivity(HandoffRoute.types[3], perform: take)
            .onContinueUserActivity(HandoffRoute.types[4], perform: take)
            .onContinueUserActivity(HandoffRoute.types[5], perform: take)
        #else
        content
        #endif
    }

    private func take(_ activity: NSUserActivity) {
        guard let route = HandoffRoute(activity) else { return }
        let info = activity.userInfo.map { Dictionary(uniqueKeysWithValues: $0.compactMap { k, v in (k as? String).map { ($0, v) } }) }
        perform(route, info)
    }
}
