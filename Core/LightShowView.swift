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
    @AppStorage("lightShowCues") private var showsCues = true

    private enum Choosing { case media, show }

    init(model: Model) {
        self.model = model
        _player = State(initialValue: LightShowPlayer(model: model))
    }

    var body: some View {
        VStack(spacing: 0) {
            stage
            Divider()
            controls
        }
        .navigationTitle(player.mediaName ?? "Light Show")
        #if os(macOS)
        .navigationSubtitle(player.show?.title ?? player.showName ?? "")
        #endif
        .toolbar { toolbar }
        .inspector(isPresented: Binding(get: { showsCues && player.show != nil }, set: { showsCues = $0 })) {
            if let show = player.show { cueList(show) }
        }
        .fileImporter(isPresented: $importing,
                      allowedContentTypes: choosing == .show ? [.json] : [.audiovisualContent]) { result in
            guard case .success(let url) = result else { return }
            if choosing == .show { player.openShow(url) } else { player.openMedia(url) }
        }
        .onDisappear { player.close() }
    }

    private func open(_ kind: Choosing) {
        choosing = kind
        importing = true
    }

    // MARK: Toolbar

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            Button { open(.media) } label: { Label("Open Media…", systemImage: "film") }
                .help("Open an audio or video file")
            Button { open(.show) } label: { Label("Open Light Show…", systemImage: "lightbulb.max") }
                .help("Open a light show file (.lights.json): what to send the bulb, and when")
            Button { showsCues.toggle() } label: { Label("Cues", systemImage: "list.bullet.rectangle") }
                .disabled(player.show == nil)
                .help("Show or hide the cue list")
        }
    }

    // MARK: Stage

    /// The video on a backdrop lit with the light the show is sending (like a TV's ambient light),
    /// or for audio that light on its own; a prompt to open something when there's nothing yet.
    @ViewBuilder private var stage: some View {
        ZStack {
            Color.black
            if player.mediaName == nil {
                ContentUnavailableView {
                    Label("Nothing Open", systemImage: "play.rectangle")
                } description: {
                    Text("Open an audio or video file, and a light show to go with it.")
                } actions: {
                    Button("Open Media…") { open(.media) }
                    Button("Open Light Show…") { open(.show) }
                }
                .environment(\.colorScheme, .dark)
            } else if player.hasVideo {
                RadialGradient(colors: [light, light.opacity(0.35)], center: .center, startRadius: 40, endRadius: 600)
                PlayerView(player: player.player)
                    .padding(28)
                    .shadow(color: .black.opacity(0.6), radius: 12)
            } else {
                RadialGradient(colors: [light, light.opacity(0.25), .clear], center: .center, startRadius: 10, endRadius: 260)
                Image(systemName: "lightbulb.fill")
                    .font(.system(size: 44))
                    .foregroundStyle(.white.opacity(0.5))
            }
        }
        .overlay(alignment: .bottomLeading) {
            if let id = player.currentCue, let label = player.show?.cues[id].label {
                Text(label)
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(.black.opacity(0.55), in: Capsule())
                    .padding(10)
            }
        }
        .animation(.easeOut(duration: 0.12), value: player.currentCue)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
    }

    /// Roughly the light the show is sending now (black before the first cue).
    private var light: Color {
        guard let rgb = player.swatch else { return .black }
        let k = player.brightness
        return Color(.sRGB, red: rgb.r * k, green: rgb.g * k, blue: rgb.b * k)
    }

    // MARK: Controls

    private var controls: some View {
        VStack(alignment: .leading, spacing: 10) {
            transport
            HStack(spacing: 6) {
                LiveSlider(label: "Bulb delay", range: -500...1500, unit: " ms",
                           value: Binding(get: { player.delay }, set: { player.delay = $0.rounded() }))
                #if os(macOS)
                Text("ms").foregroundStyle(.secondary)
                #endif
            }
            .help("How early each cue is sent, to make up for the bulb taking a moment to change: dial it in until a hard cut on screen and the bulb change together. Below zero if the picture or sound is the late one")
            HStack(spacing: 16) {
                Toggle("Send to bulb", isOn: Binding(get: { player.sendsToBulb }, set: { player.sendsToBulb = $0 }))
                    .help("Off: play the show on screen only")
                Toggle("Put the light back when stopped", isOn: Binding(get: { player.restores }, set: { player.restores = $0 }))
                    .help("When the show is stopped or ends, the light goes back to how it was when it started")
                Spacer(minLength: 0)
                status
            }
            .font(.callout)
            #if os(macOS)
            .toggleStyle(.checkbox)
            #endif
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var transport: some View {
        HStack(spacing: 12) {
            Button {
                player.togglePlay()
            } label: {
                Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                    .font(.title2)
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .keyboardShortcut(.space, modifiers: [])
            .disabled(player.mediaName == nil)
            .accessibilityLabel(player.isPlaying ? "Pause" : "Play")
            .help(player.isPlaying ? "Pause (Space)" : "Play (Space)")
            Button {
                player.stop()
            } label: {
                Image(systemName: "stop.fill")
                    .font(.title3)
                    .frame(width: 24, height: 28)
                    .contentShape(Rectangle())
            }
            .disabled(player.mediaName == nil)
            .accessibilityLabel("Stop")
            .help("Stop and rewind (and put the light back, if set to)")
            Text(verbatim: LightShowPlayer.format(player.time))
                .monospacedDigit()
                .frame(minWidth: 64, alignment: .trailing)
            Slider(value: Binding(get: { player.time }, set: { player.seek(to: $0) }),
                   in: 0...max(player.duration, 0.1),
                   onEditingChanged: { player.setScrubbing($0) })
                .disabled(player.duration == 0)
                .accessibilityLabel("Position")
            Text(verbatim: LightShowPlayer.format(player.duration))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(minWidth: 64, alignment: .leading)
        }
        .buttonStyle(.borderless)
        .font(.callout)
    }

    /// One line: what's wrong, if anything; otherwise what's loaded.
    @ViewBuilder private var status: some View {
        if let error = player.error {
            Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange).lineLimit(1)
        } else if let warning = player.show?.warnings.first {
            Label(warning, systemImage: "exclamationmark.triangle").foregroundStyle(.secondary).lineLimit(1).help(warning)
        } else if player.sendsToBulb && !model.canControl {
            Label("Bulb not connected", systemImage: "exclamationmark.circle").foregroundStyle(.orange)
        } else if let show = player.show {
            Text("\(show.cues.count) cues").foregroundStyle(.secondary)
        } else if player.mediaName != nil {
            Button("Open Light Show…") { open(.show) }.buttonStyle(.link)
        }
    }

    // MARK: Cues

    private func cueList(_ show: LightShow) -> some View {
        ScrollViewReader { proxy in
            List(show.cues) { cue in
                Button {
                    player.seek(to: cue.time)
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(verbatim: LightShowPlayer.format(cue.time)).monospacedDigit().foregroundStyle(.secondary)
                            if let label = cue.label { Text(label).fontWeight(.medium).lineLimit(1) }
                        }
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
            .onChange(of: player.currentCue) { _, id in
                guard let id else { return }
                withAnimation { proxy.scrollTo(id, anchor: .center) }
            }
        }
        .inspectorColumnWidth(min: 220, ideal: 280, max: 420)
    }
}
