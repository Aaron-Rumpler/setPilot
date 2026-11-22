#if os(iOS)
import ActivityKit
import Foundation

/// Keeps the light show's Live Activity in step with the player: started when a show plays,
/// updated on play, pause, seeking and each new cue (at most once a second), and ended when the
/// show stops, ends or is closed.
@MainActor
final class LightShowLiveActivity {
    static let shared = LightShowLiveActivity()
    private var activity: Activity<LightShowAttributes>?
    private var lastUpdate = Date.distantPast
    private var pendingUpdate: Task<Void, Never>?

    func changed(_ player: LightShowPlayer) {
        if activity == nil {
            guard player.isPlaying, ActivityAuthorizationInfo().areActivitiesEnabled else { return }
            let attributes = LightShowAttributes(title: player.mediaName ?? "Light Show", show: player.show?.title ?? player.showName)
            activity = try? Activity.request(attributes: attributes, content: ActivityContent(state: state(player), staleDate: nil))
            lastUpdate = .now
            LightShowControl.handler = { [weak player] action in
                switch action {
                case .toggle: player?.togglePlay()
                case .stop: player?.stop()
                }
            }
            return
        }
        // Live Activities have an update budget: a burst of cues comes as one update.
        pendingUpdate?.cancel()
        let wait = max(0, 1 - Date.now.timeIntervalSince(lastUpdate))
        pendingUpdate = Task { [weak self, weak player] in
            if wait > 0 { try? await Task.sleep(for: .seconds(wait)) }
            guard !Task.isCancelled, let self, let player, let activity = self.activity else { return }
            self.lastUpdate = .now
            await activity.update(ActivityContent(state: self.state(player), staleDate: nil))
        }
    }

    func end() {
        pendingUpdate?.cancel()
        LightShowControl.handler = nil
        guard let activity else { return }
        self.activity = nil
        Task { await activity.end(nil, dismissalPolicy: .immediate) }
    }

    private func state(_ player: LightShowPlayer) -> LightShowAttributes.ContentState {
        let cue = player.currentCue.flatMap { i in player.show.map { $0.cues.indices.contains(i) ? $0.cues[i] : nil } ?? nil }
        return .init(playing: player.isPlaying, position: player.time, at: .now, duration: player.duration,
                     cue: cue?.label, swatch: player.swatch)
    }
}
#endif
