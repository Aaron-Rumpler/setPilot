import AVKit
import SwiftUI
import UniformTypeIdentifiers

/// The Light Show player: a video or audio file, with a light show file's cues sent to the bulb as
/// it plays. The Mac's Light Show window and the iPhone's Light Show screen.
///
/// The player is made when the view appears, not in `init`: a NavigationLink builds its
/// destination on every redraw of the screen it's on, and `@State` would throw each one away.
struct LightShowView: View {
    let model: Model
    @State private var player: LightShowPlayer?

    var body: some View {
        if let player {
            LightShowScreen(model: model, player: player)
        } else {
            Color.black.onAppear { player = LightShowPlayer(model: model) }
        }
    }
}

private struct LightShowScreen: View {
    @Environment(\.confirmFlashing) private var confirmFlashing
    let model: Model
    let player: LightShowPlayer
    @State private var importing = false
    /// Open Last Show (or a Handoff), waiting for its files to download.
    @State private var opening: Task<Void, Never>?
    /// What the file importer is choosing (kept apart from `importing`, which is cleared first).
    @State private var choosing = Choosing.media
    /// The cue list (an inspector; on iPhone a sheet over the player, so off to start with).
    @AppStorage("lightShowCues") private var showsCues = LightShowScreen.cuesByDefault
    @AppStorage(Flashing.warnKey) private var warnsFlashing = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// The transport buttons' size, growing with the text size on iPhone and iPad.
    @ScaledMetric(relativeTo: .title2) private var buttonSize: CGFloat = 28
    #if os(iOS)
    private static let cuesByDefault = false
    #else
    private static let cuesByDefault = true
    #endif

    private enum Choosing { case media, show }

    var body: some View {
        VStack(spacing: 0) {
            stage
                // Handed off from another device: open what it had, where it was.
                .onChange(of: HandoffRouter.shared.lightShowResume != nil, initial: true) { _, has in
                    guard has, let info = HandoffRouter.shared.lightShowResume else { return }
                    HandoffRouter.shared.lightShowResume = nil
                    openLast(media: LastShow.resolve(info["media"] as? String), show: LastShow.resolve(info["show"] as? String),
                             at: info["position"] as? Double)
                }
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
            opening?.cancel() // chosen by hand: a last show still downloading isn't wanted now
            opening = nil
            if choosing == .show { player.openShow(url) } else { player.openMedia(url) }
        }
        .startsInCloudFolder()
        .onDisappear {
            opening?.cancel()
            opening = nil
            player.close()
        }
    }

    /// Opens a show and its media (the last ones, or another device's), and goes to a place in it.
    private func openLast(media: URL?, show: URL?, at position: Double?) {
        opening?.cancel() // the latest asked for
        opening = Task {
            // Not downloaded here yet (from another device): opened once it's down, unless
            // something else was opened (or the screen left) meanwhile.
            if let media { await LastShow.downloaded(media) }
            if let show { await LastShow.downloaded(show) }
            guard !Task.isCancelled else { return }
            if let media { player.openMedia(media) }
            if let show { player.openShow(show) }
            guard let position, position > 0 else { opening = nil; return }
            // Once the media's length is known (seeking before then is clamped to the start).
            for _ in 0..<50 where player.duration == 0 { try? await Task.sleep(for: .milliseconds(100)) }
            guard !Task.isCancelled else { return }
            player.seek(to: position)
            opening = nil
        }
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
                    if LastShow.media != nil || LastShow.show != nil {
                        Button("Open Last Show") { openLast(media: LastShow.media, show: LastShow.show, at: nil) }
                            .help("The show and media last opened from setPilot's iCloud Drive folder, on any of your devices")
                    }
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
                    // The stage's light, for VoiceOver.
                    .accessibilityLabel("Bulb")
                    .accessibilityValue(lightDescription)
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
                    .accessibilityLabel("Cue: \(label)")
            }
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: player.currentCue)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
    }

    /// Roughly the light the show is sending now (black before the first cue).
    private var light: Color {
        guard let rgb = player.swatch else { return .black }
        let k = player.brightness
        return Color(.sRGB, red: rgb.r * k, green: rgb.g * k, blue: rgb.b * k)
    }

    /// The light the show is sending now, in words: "warm white, 40%".
    private var lightDescription: String {
        guard let rgb = player.swatch, player.brightness > 0 else { return "Off" }
        return "\(ColourNames.name(rgb)), \(Int((player.brightness * 100).rounded()))%"
    }

    /// The colour a cue sets, in words (nil for a cue that leaves the colour as it is).
    private static func colourName(_ pilot: [String: Any]) -> String? {
        if pilot["state"] as? Bool == false { return "off" }
        if let k = (pilot["temp"] as? NSNumber)?.intValue { return ColourNames.name(kelvin: Double(k)) }
        if let id = (pilot["sceneId"] as? NSNumber)?.intValue { return Scenes.name(id) }
        let keys = ["r", "g", "b", "c", "w"]
        guard keys.contains(where: { pilot[$0] != nil }) else { return nil }
        let ch = keys.map { (pilot[$0] as? NSNumber)?.intValue ?? 0 }
        return LightColour.rgbcw(r: ch[0], g: ch[1], b: ch[2], c: ch[3], w: ch[4]).colourName
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
            #if os(iOS)
            Text("How early each cue is sent: dial it in until a hard cut on screen and the bulb change together.")
                .font(.caption).foregroundStyle(.secondary)
            #endif
            #if os(macOS)
            HStack(spacing: 16) {
                options
                Spacer(minLength: 0)
                status
            }
            .font(.callout)
            .toggleStyle(.checkbox)
            #else
            // Switches don't fit side by side at phone width.
            options
            status.font(.callout)
            #endif
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    @ViewBuilder private var options: some View {
        Toggle("Send to bulb", isOn: Binding(get: { player.sendsToBulb }, set: { player.sendsToBulb = $0 }))
            .help("Off: play the show on screen only")
        Toggle("Put the light back afterwards", isOn: Binding(get: { player.restores }, set: { player.restores = $0 }))
            .help("When the show is stopped or ends, the light goes back to how it was when it started")
    }

    private var transport: some View {
        HStack(spacing: 12) {
            Button {
                if player.isPlaying {
                    player.togglePlay()
                } else {
                    let opened = player.opened
                    confirmFlashing(player.show?.title ?? player.showName ?? "This light show",
                                    flashes: player.showFlashes) {
                        // The show asked about, not another opened meanwhile (a Handoff, say).
                        guard player.opened == opened else {
                            player.error = "Another show was opened while asking: press Play again."
                            return
                        }
                        player.play() // play, whatever it's doing by now
                    }
                }
            } label: {
                Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                    .font(.title2)
                    .frame(width: buttonSize, height: buttonSize)
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
                    .frame(width: buttonSize * 24 / 28, height: buttonSize)
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

    /// The Mac has the whole text as a tooltip; iPhone has none, so it wraps there.
    #if os(iOS)
    static let statusLines = 4
    #else
    static let statusLines = 1
    #endif

    /// One line: what's wrong, if anything; otherwise what's loaded.
    @ViewBuilder private var status: some View {
        if let error = player.error {
            Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange).lineLimit(Self.statusLines)
        } else if let note = player.restoreNote {
            Label(note, systemImage: "info.circle").foregroundStyle(.secondary).lineLimit(Self.statusLines).help(note)
        } else if player.sendsToBulb && model.link != .connected {
            // Ahead of a show's warnings: nothing reaches the bulb until it's fixed. (Connected
            // with its state still to be read is fine: cues go anyway.)
            Label("Bulb not connected", systemImage: "exclamationmark.circle").foregroundStyle(.orange)
        } else if warnsFlashing, let show = player.show, player.showFlashes {
            // With the summary and any other warning (on iPhone this is the only place the title shows).
            let text = ([summary(show), Flashing.warning] + show.warnings.prefix(1)).joined(separator: " · ")
            Label(text, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange).lineLimit(Self.statusLines).help(text)
        } else if let show = player.show, let warning = show.warnings.first {
            // The summary too (on iPhone it's the only place the title shows).
            Label("\(summary(show)) · \(warning)", systemImage: "exclamationmark.triangle")
                .foregroundStyle(.secondary).lineLimit(Self.statusLines).help(warning)
        } else if let show = player.show {
            Text(verbatim: summary(show)).foregroundStyle(.secondary).lineLimit(1)
        } else if player.mediaName != nil {
            Button("Open Light Show…") { open(.show) }
                #if os(macOS)
                .buttonStyle(.link)
                #endif
        }
    }

    /// The show's title (on the Mac it's the window's subtitle), its cues, and the media it was made
    /// for if that isn't what's open.
    private func summary(_ show: LightShow) -> String {
        var parts: [String] = []
        #if os(iOS)
        if let title = show.title { parts.append(title) }
        #endif
        parts.append("\(show.cues.count) cue\(show.cues.count == 1 ? "" : "s")")
        if let media = show.media, let open = player.mediaName, media != open { parts.append("made for \(media)") }
        return parts.joined(separator: " · ")
    }

    // MARK: Cues

    private func cueList(_ show: LightShow) -> some View {
        ScrollViewReader { proxy in
            List(show.cues) { cue in
                Button {
                    // To where this cue is due: the show runs `delay` ahead of the media.
                    player.seek(to: cue.time - player.delay / 1000)
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
                // The row's highlight, and the colour in words rather than the raw params.
                .accessibilityLabel(cue.label.map { "\(LightShowPlayer.format(cue.time)), \($0)" } ?? LightShowPlayer.format(cue.time))
                .accessibilityValue(Self.colourName(cue.pilot) ?? cue.summary)
                .accessibilityHint("Goes to this cue")
                .accessibilityAddTraits(cue.id == player.currentCue ? .isSelected : [])
            }
            .onChange(of: player.currentCue) { _, id in
                guard let id else { return }
                withAnimation(reduceMotion ? nil : .default) { proxy.scrollTo(id, anchor: .center) }
            }
        }
        .inspectorColumnWidth(min: 220, ideal: 280, max: 420)
    }
}
