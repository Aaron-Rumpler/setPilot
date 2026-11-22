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

    func open(_ route: HandoffRoute) {
        switch route {
        case .customScene(let id): sceneToSelect = id
        case .cctScale(let id): scaleToSelect = id
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

    /// Takes activities continued from another device (every setPilot type).
    func onContinueHandoff(_ perform: @escaping (HandoffRoute) -> Void) -> some View {
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
            }
        #else
        content
        #endif
    }
}

private struct HandoffReceiver: ViewModifier {
    let perform: (HandoffRoute) -> Void

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
        if let route = HandoffRoute(activity) { perform(route) }
    }
}
