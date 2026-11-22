import AVKit
import SwiftUI

/// AVKit's own video player view, without its controls: the Light Show window has its own
/// transport, which also handles the light. (Not SwiftUI's `VideoPlayer`, which crashed on macOS
/// 26.4 setting up its view class the first time it appeared.)
#if os(macOS)
struct PlayerView: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.player = player
        view.controlsStyle = .none
        view.videoGravity = .resizeAspect
        return view
    }

    func updateNSView(_ view: AVPlayerView, context: Context) {
        if view.player !== player { view.player = player }
    }
}
#else
struct PlayerView: UIViewControllerRepresentable {
    let player: AVPlayer

    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let controller = AVPlayerViewController()
        controller.player = player
        controller.showsPlaybackControls = false
        controller.videoGravity = .resizeAspect
        context.coordinator.watch(controller, player: player)
        return controller
    }

    func updateUIViewController(_ controller: AVPlayerViewController, context: Context) {
        if controller.player !== player, !context.coordinator.inBackground { controller.player = player }
        context.coordinator.player = player
    }

    func makeCoordinator() -> BackgroundPlayback { BackgroundPlayback() }

    /// With the app in the background, iOS pauses a player that's showing video. Taking the player
    /// off the screen then lets the soundtrack, and the show's cues with it, carry on (the audio
    /// background mode); it goes back on when the app comes forward.
    @MainActor
    final class BackgroundPlayback {
        weak var controller: AVPlayerViewController?
        var player: AVPlayer?
        private(set) var inBackground = false
        private var observers: [NSObjectProtocol] = []

        func watch(_ controller: AVPlayerViewController, player: AVPlayer) {
            self.controller = controller
            self.player = player
            let centre = NotificationCenter.default
            observers.append(centre.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.inBackground = true
                    self?.controller?.player = nil
                }
            })
            observers.append(centre.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.inBackground = false
                    self.controller?.player = self.player
                }
            })
        }

        deinit {
            for o in observers { NotificationCenter.default.removeObserver(o) }
        }
    }
}
#endif
