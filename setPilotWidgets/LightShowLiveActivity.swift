#if os(iOS)
import ActivityKit
import AppIntents
import SwiftUI
import WidgetKit

/// The light show's Live Activity: the Lock Screen and StandBy, the Dynamic Island, and (small)
/// the watch's Smart Stack.
struct LightShowLiveActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: LightShowAttributes.self) { context in
            LightShowActivityView(context: context)
                .activityBackgroundTint(nil)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    LightSwatch(rgb: context.state.swatch).frame(width: 36, height: 36)
                }
                DynamicIslandExpandedRegion(.center) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(context.attributes.title).font(.headline).lineLimit(1)
                        if let cue = context.state.cue { Text(cue).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                    }
                }
                DynamicIslandExpandedRegion(.trailing) {
                    // Stale: Stop only (to dismiss it).
                    LightShowButtons(playing: context.state.playing, stale: context.isStale)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    if context.isStale { Text("Not playing").font(.caption).foregroundStyle(.secondary) } else { LightShowProgress(state: context.state) }
                }
            } compactLeading: {
                LightSwatch(rgb: context.state.swatch).frame(width: 18, height: 18)
            } compactTrailing: {
                Image(systemName: context.isStale ? "stop.fill" : context.state.playing ? "play.fill" : "pause.fill")
                    // What it's doing, not a button's name.
                    .accessibilityLabel(context.isStale ? "Not playing" : context.state.playing ? "Playing" : "Paused")
            } minimal: {
                LightSwatch(rgb: context.state.swatch).frame(width: 18, height: 18)
            }
        }
        .supplementalActivityFamilies([.small])
    }
}

private struct LightShowActivityView: View {
    let context: ActivityViewContext<LightShowAttributes>
    @Environment(\.activityFamily) private var family

    var body: some View {
        switch family {
        case .small:
            // The watch's Smart Stack (and CarPlay): the colour, the name and how far through.
            HStack(spacing: 8) {
                LightSwatch(rgb: context.state.swatch).frame(width: 24, height: 24)
                VStack(alignment: .leading, spacing: 2) {
                    Text(context.attributes.title).font(.caption).lineLimit(1)
                    // Stale (the app's gone, say): not shown as still playing.
                    if context.isStale { Text("Not playing").font(.caption2).foregroundStyle(.secondary) } else { LightShowProgress(state: context.state) }
                }
            }
            .padding(8)
        default:
            HStack(spacing: 12) {
                LightSwatch(rgb: context.state.swatch).frame(width: 44, height: 44)
                VStack(alignment: .leading, spacing: 4) {
                    Text(context.attributes.title).font(.headline).lineLimit(1)
                    Text(context.isStale ? "Not playing" : context.state.cue ?? context.attributes.show ?? "Light Show")
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    if !context.isStale { LightShowProgress(state: context.state) }
                }
                LightShowButtons(playing: context.state.playing, stale: context.isStale)
            }
            .padding()
        }
    }
}

/// How far through: running by itself while playing, still while paused.
private struct LightShowProgress: View {
    let state: LightShowAttributes.ContentState

    var body: some View {
        if state.duration > 0 {
            if state.playing {
                ProgressView(timerInterval: state.start...state.start.addingTimeInterval(state.duration), countsDown: false) {
                    EmptyView()
                } currentValueLabel: {
                    EmptyView()
                }
            } else {
                ProgressView(value: min(state.position, state.duration), total: state.duration)
            }
        }
    }
}

private struct LightShowButtons: View {
    let playing: Bool
    /// Not playing as far as is known (the app's gone, say): only Stop, which ends it.
    var stale = false

    var body: some View {
        HStack(spacing: 8) {
            if !stale {
                Button(intent: LightShowControlIntent(.toggle)) {
                    Image(systemName: playing ? "pause.fill" : "play.fill")
                }
                .accessibilityLabel(playing ? "Pause" : "Play")
            }
            Button(intent: LightShowControlIntent(.stop)) {
                Image(systemName: "stop.fill")
            }
            .accessibilityLabel("Stop")
        }
        .buttonStyle(.bordered)
    }
}

/// The light's colour, as a lit circle (dark when there isn't one yet).
private struct LightSwatch: View {
    let rgb: RGB?

    var body: some View {
        Circle()
            .fill(rgb?.color ?? Color.black)
            .overlay(Circle().strokeBorder(.secondary.opacity(0.4), lineWidth: 1))
            .accessibilityHidden(true)
    }
}
#endif
