import AVKit
import SwiftUI
import UniformTypeIdentifiers

/// The Light Show player: a video or audio file, with a light show file's cues sent to the bulb as
/// it plays. The Mac's Light Show window and the iPhone's Light Show screen.
struct LightShowView: View {
    let model: Model
    @State private var player: LightShowPlayer
    @State private var importing = false
    /// What the file importer is choosing (kept apart from `importing`, which is cleared first).
    @State private var choosing = Choosing.media

    private enum Choosing { case media, show }

    init(model: Model) {
        self.model = model
        _player = State(initialValue: LightShowPlayer(model: model))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            files
            screen
            transport
            settings
            if let error = player.error {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.orange)
            }
            if let show = player.show {
                ForEach(show.warnings, id: \.self) { warning in
                    Label(warning, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.secondary)
                }
                cueList(show)
            } else {
                Spacer(minLength: 0)
            }
        }
        .padding(14)
        .fileImporter(isPresented: $importing,
                      allowedContentTypes: choosing == .show ? [.json] : [.audiovisualContent]) { result in
            guard case .success(let url) = result else { return }
            if choosing == .show { player.openShow(url) } else { player.openMedia(url) }
        }
        .onDisappear { player.close() }
    }

    // MARK: Parts

    private var files: some View {
        HStack(spacing: 10) {
            Button {
                choosing = .media
                importing = true
            } label: {
                Label(player.mediaName ?? "Open Media…", systemImage: "film")
                    .lineLimit(1)
            }
            .help("An audio or video file")
            Button {
                choosing = .show
                importing = true
            } label: {
                Label(player.showName ?? "Open Light Show…", systemImage: "lightbulb.max")
                    .lineLimit(1)
            }
            .help("A .lights.json file: what to send the bulb, and when")
            Spacer()
            if let title = player.show?.title {
                Text(title).font(.callout).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        #if os(iOS)
        .buttonStyle(.bordered)
        #endif
    }

    /// The video, or for audio the show's colour on its own; the light as it should be now beside it.
    @ViewBuilder private var screen: some View {
        HStack(spacing: 10) {
            if player.hasVideo {
                PlayerView(player: player.player)
                    .frame(minHeight: 200)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            }
            lightSwatch
                .frame(maxWidth: player.hasVideo ? 70 : .infinity)
        }
        .frame(height: player.hasVideo ? nil : 90)
        .frame(maxHeight: player.hasVideo ? .infinity : 90)
    }

    private var lightSwatch: some View {
        RoundedRectangle(cornerRadius: 8)
            .fill((player.swatch?.color ?? .black).opacity(0.15 + 0.85 * player.brightness))
            .background(Color.black, in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.separator))
            .overlay(alignment: .bottomLeading) {
                if let id = player.currentCue, let cue = player.show?.cues[id], let label = cue.label {
                    Text(label).font(.caption2.weight(.semibold)).foregroundStyle(.white).shadow(radius: 2).padding(6)
                }
            }
            .animation(.easeOut(duration: 0.15), value: player.currentCue)
            .accessibilityLabel("The light the show is sending")
            .help("The light the show is sending now (roughly)")
    }

    private var transport: some View {
        HStack(spacing: 10) {
            Button {
                player.togglePlay()
            } label: {
                Image(systemName: player.isPlaying ? "pause.fill" : "play.fill").frame(width: 18)
            }
            .disabled(player.mediaName == nil)
            .accessibilityLabel(player.isPlaying ? "Pause" : "Play")
            Button {
                player.stop()
            } label: {
                Image(systemName: "stop.fill")
            }
            .disabled(player.mediaName == nil)
            .accessibilityLabel("Stop")
            .help("Stop and rewind (and put the light back, if set to)")
            Text(verbatim: LightShowPlayer.format(player.time)).monospacedDigit().font(.callout)
            Slider(value: Binding(get: { player.time }, set: { player.seek(to: $0) }),
                   in: 0...max(player.duration, 0.1),
                   onEditingChanged: { player.setScrubbing($0) })
                .disabled(player.duration == 0)
                .accessibilityLabel("Position")
            Text(verbatim: LightShowPlayer.format(player.duration)).monospacedDigit().font(.callout).foregroundStyle(.secondary)
        }
        #if os(iOS)
        .buttonStyle(.borderless)
        #endif
    }

    @ViewBuilder private var settings: some View {
        LiveSlider(label: "Bulb delay", range: -500...1500, unit: " ms",
                   value: Binding(get: { player.delay }, set: { player.delay = $0.rounded() }))
            .help("How early each cue is sent, so the bulb changes on time. Below zero if the picture or sound is the late one")
        Text("Sends each cue this much early, to make up for the bulb taking a moment to change. Dial it in until a hard cut on screen and the bulb change together.")
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        HStack(spacing: 16) {
            Toggle("Send to bulb", isOn: Binding(get: { player.sendsToBulb }, set: { player.sendsToBulb = $0 }))
                .help("Off: play the show on screen only")
            Toggle("Put the light back when stopped", isOn: Binding(get: { player.restores }, set: { player.restores = $0 }))
                .help("When the show is stopped or ends, the light goes back to how it was when it started")
            Spacer()
            if player.sendsToBulb && !model.canControl {
                Label("Bulb not connected", systemImage: "exclamationmark.circle").font(.caption).foregroundStyle(.orange)
            }
        }
        .font(.callout)
        #if os(macOS)
        .toggleStyle(.checkbox)
        #endif
    }

    private func cueList(_ show: LightShow) -> some View {
        ScrollViewReader { proxy in
            List(show.cues) { cue in
                Button {
                    player.seek(to: cue.time)
                } label: {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(verbatim: LightShowPlayer.format(cue.time)).monospacedDigit().foregroundStyle(.secondary)
                        if let label = cue.label { Text(label).fontWeight(.medium) }
                        Text(verbatim: cue.summary)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .listRowBackground(cue.id == player.currentCue ? Color.accentColor.opacity(0.2) : Color.clear)
                .id(cue.id)
                .help("Go to this cue")
            }
            .listStyle(.plain)
            .frame(minHeight: 120)
            .onChange(of: player.currentCue) { _, id in
                guard let id else { return }
                withAnimation { proxy.scrollTo(id, anchor: .center) }
            }
        }
    }
}
