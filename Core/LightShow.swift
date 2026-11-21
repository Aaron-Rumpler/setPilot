import AVFoundation
import Foundation
#if os(iOS)
import UIKit
#endif

/// A light show file: setPilot states to send at times in a piece of media. See docs/LIGHT-SHOW.md.
struct LightShow {
    struct Cue: Identifiable {
        /// Its place in the sorted list.
        let id: Int
        /// Media time, in seconds.
        let time: Double
        /// setPilot params, sent as they are.
        let pilot: [String: Any]
        let label: String?

        /// The params as one line of JSON, for the cue list.
        var summary: String { JSONText.compact(pilot) }
    }

    var title: String?
    var media: String?
    var cues: [Cue]
    /// Things in the file that will probably misbehave on the bulb (it's still playable).
    var warnings: [String]

    struct ParseError: Error { let message: String }

    static func parse(_ data: Data) -> Result<LightShow, ParseError> {
        guard let obj = Net.json(data) else { return .failure(ParseError(message: "Not a JSON object.")) }
        guard (obj["setPilotLightShow"] as? NSNumber)?.intValue == 1 else {
            return .failure(ParseError(message: "Not a setPilot light show (no \"setPilotLightShow\": 1)."))
        }
        guard let list = obj["cues"] as? [Any] else { return .failure(ParseError(message: "No \"cues\" list.")) }
        var raw: [(time: Double, pilot: [String: Any], label: String?)] = []
        for (i, item) in list.enumerated() {
            guard let cue = item as? [String: Any] else { return .failure(ParseError(message: "Cue \(i + 1) isn't an object.")) }
            guard let time = cue["t"].flatMap(Self.seconds), time >= 0 else {
                return .failure(ParseError(message: "Cue \(i + 1) has no valid \"t\" (seconds, or \"m:ss.sss\")."))
            }
            guard let pilot = cue["pilot"] as? [String: Any], !pilot.isEmpty else {
                return .failure(ParseError(message: "Cue \(i + 1) has no \"pilot\" params."))
            }
            raw.append((time, pilot, cue["label"] as? String))
        }
        // Stable, so cues at the same time keep the file's order.
        let sorted = raw.enumerated().sorted { ($0.element.time, $0.offset) < ($1.element.time, $1.offset) }.map(\.element)
        let cues = sorted.enumerated().map { Cue(id: $0.offset, time: $0.element.time, pilot: $0.element.pilot, label: $0.element.label) }
        return .success(LightShow(title: obj["title"] as? String, media: obj["media"] as? String,
                                  cues: cues, warnings: warnings(cues)))
    }

    /// Seconds from a number, or from "m:ss.sss" / "h:mm:ss.sss". Only times that can be: 0 or
    /// more, and finite and within reason (Double parses "inf", and JSON allows 1e300).
    static func seconds(_ value: Any) -> Double? {
        func valid(_ t: Double) -> Double? { t >= 0 && t < 10_000_000 ? t : nil } // NaN fails too
        // JSON true/false are NSNumbers too, but `is Bool` can't tell them apart: it holds for any
        // NSNumber that's 0 or 1 (so "t": 0 would be refused). CF's boolean type can.
        if let n = value as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() { return valid(n.doubleValue) }
        guard let s = value as? String else { return nil }
        let parts = s.trimmingCharacters(in: .whitespaces).split(separator: ":", omittingEmptySubsequences: false)
        guard (1...3).contains(parts.count) else { return nil }
        var total = 0.0
        for part in parts {
            guard let v = Double(part), v >= 0 else { return nil }
            total = total * 60 + v
        }
        return valid(total)
    }

    private static func warnings(_ cues: [Cue]) -> [String] {
        var out: [String] = []
        let close = zip(cues, cues.dropFirst()).filter { $1.time - $0.time < 0.08 }.count
        if close > 0 { out.append("\(close) cue\(close == 1 ? " comes" : "s come") less than 80 ms after the one before: the bulb may drop some.") }
        let channels = ["r", "g", "b", "c", "w"]
        let dark = cues.filter { cue in
            channels.allSatisfy { cue.pilot[$0] != nil } && channels.allSatisfy { (cue.pilot[$0] as? NSNumber)?.intValue == 0 }
        }
        if let first = dark.first {
            out.append("\(dark.count) cue\(dark.count == 1 ? " sets" : "s set") every channel to 0 (first at \(LightShowPlayer.format(first.time))), which the bulb refuses.")
        }
        return out
    }

    /// The state the show is in after these cues: a colour replaces the previous colour (and its
    /// scene speed), everything else accumulates. Fades are dropped, to jump straight there.
    static func state(after cues: some Sequence<Cue>) -> [String: Any] {
        let colourKeys: Set<String> = ["r", "g", "b", "c", "w", "temp", "sceneId", "elm", "speed"]
        var state: [String: Any] = [:]
        for cue in cues {
            if cue.pilot.keys.contains(where: { ["r", "g", "b", "c", "w", "temp", "sceneId"].contains($0) }) {
                state = state.filter { !colourKeys.contains($0.key) }
            }
            // A setPilot without "state" switches the bulb on: an earlier off no longer holds.
            if cue.pilot["state"] == nil, cue.pilot.keys.contains(where: { $0 != "trans" }) { state["state"] = nil }
            state.merge(cue.pilot) { $1 }
        }
        state["trans"] = nil
        return state
    }
}

/// Plays media and sends the bulb the light show's cues as it goes, each `delay` early.
@MainActor @Observable
final class LightShowPlayer {
    let model: Model
    let player = AVPlayer()

    private(set) var mediaName: String?
    private(set) var hasVideo = false
    private(set) var duration = 0.0
    private(set) var show: LightShow?
    private(set) var showName: String?
    var error: String?

    /// The media time, for the transport (updated as it plays).
    private(set) var time = 0.0
    private(set) var isPlaying = false {
        didSet {
            #if os(iOS)
            // Video keeps the screen on by itself; audio doesn't, and a locked phone suspends the
            // app, show and all.
            if isPlaying != oldValue { UIApplication.shared.isIdleTimerDisabled = isPlaying }
            #endif
        }
    }
    /// The cue sent most recently, for the cue list.
    private(set) var currentCue: Int?
    /// The show's state as last sent, for the on-screen swatch.
    private(set) var light: [String: Any] = [:]

    /// How early cues are sent, in ms (negative: late). Remembered.
    var delay: Double = (UserDefaults.standard.object(forKey: LightShowPlayer.delayKey) as? Double)
        .flatMap { $0.isFinite ? min(max($0, -500), 1500) : nil } ?? 200 {
        didSet {
            UserDefaults.standard.set(delay, forKey: Self.delayKey)
            if !isPlaying { showPosition(at: time) } // the highlight and stage follow while paused
        }
    }
    static let delayKey = "lightShowDelay"
    /// Off: play the show on screen only.
    var sendsToBulb = UserDefaults.standard.object(forKey: LightShowPlayer.sendKey) as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(sendsToBulb, forKey: Self.sendKey)
            // Turned on part way: bring the bulb to where the show is, not just the cues to come.
            if sendsToBulb, !oldValue { sentUpTo = nil }
        }
    }
    static let sendKey = "lightShowSends"
    /// Put the light back as it was before the show, when it's stopped or ends.
    var restores = UserDefaults.standard.object(forKey: LightShowPlayer.restoreKey) as? Bool ?? true {
        didSet { UserDefaults.standard.set(restores, forKey: Self.restoreKey) }
    }
    static let restoreKey = "lightShowRestores"

    /// The show time cues have been sent up to; nil until playback starts (or after a jump is due).
    @ObservationIgnored private var sentUpTo: Double?
    @ObservationIgnored private var nextCue = 0
    @ObservationIgnored private var saved: Model.SavedLight?
    @ObservationIgnored private var endObserver: NSObjectProtocol?
    @ObservationIgnored private var mediaAccess: URL?
    @ObservationIgnored private var scrubbing = false
    /// A seek is under way: the player's time is still the old one until it finishes.
    @ObservationIgnored private var seeking = false
    @ObservationIgnored private var seekGeneration = 0
    /// How close to its time a cue counts as due: a seek lands on the nearest 1/600 s (often just
    /// before the time asked for), and adding the delay back can come out a hair short, so a cue
    /// tapped in the list would otherwise not be the current one when the media gets there.
    static let slack = 0.002
    /// A scene's speed, sent separately just after it: cancelled by a stop (or a newer state).
    @ObservationIgnored private var speedTask: Task<Void, Never>?
    /// A scene's speed held back while the show has the bulb off, for when it's switched on.
    @ObservationIgnored private var speedOwed: Any?
    /// The delay the cues were last sent with, to tell a change of it from a jump in the media.
    @ObservationIgnored private var sentDelay: Double?

    init(model: Model) {
        self.model = model
        startTicking()
    }

    // MARK: Files

    func openMedia(_ url: URL) {
        stop()
        mediaAccess?.stopAccessingSecurityScopedResource()
        mediaAccess = url.startAccessingSecurityScopedResource() ? url : nil
        #if os(iOS)
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
        #endif
        let asset = AVURLAsset(url: url)
        let item = AVPlayerItem(asset: asset)
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        endObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.ended() }
        }
        player.replaceCurrentItem(with: item)
        seekGeneration += 1 // a seek still landing was in the old item
        seeking = false
        mediaName = url.lastPathComponent
        hasVideo = false
        duration = 0
        time = 0
        error = nil
        let name = url.lastPathComponent
        Task {
            do {
                let (playable, length) = try await asset.load(.isPlayable, .duration)
                let video = try await asset.loadTracks(withMediaType: .video)
                guard player.currentItem === item else { return }
                if !playable { error = "\(name) can't be played." }
                hasVideo = !video.isEmpty
                let seconds = CMTimeGetSeconds(length)
                duration = seconds.isFinite ? seconds : 0
            } catch {
                guard player.currentItem === item else { return }
                self.error = "Couldn't open \(name): \(error.localizedDescription)"
            }
        }
    }

    func openShow(_ url: URL) {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: url) else {
            error = "Couldn't read \(url.lastPathComponent)."
            return
        }
        switch LightShow.parse(data) {
        case .success(let s):
            show = s
            showName = url.lastPathComponent
            error = nil
            sentUpTo = nil // catch up to wherever the media is, on the next tick that plays
            nextCue = 0
            showPosition(at: time)
        case .failure(let e):
            error = "\(url.lastPathComponent): \(e.message)"
        }
    }

    // MARK: Transport

    func togglePlay() { isPlaying ? pause() : play() }

    func play() {
        guard player.currentItem != nil else { return }
        if duration > 0, time >= duration - 0.05 { seek(to: 0) }
        player.play()
    }

    func pause() { player.pause() }

    /// Stops, rewinds, and puts the light back (if set to).
    func stop() {
        player.pause()
        // Through seek(to:), so that until it lands a tick (a quick Play, say) doesn't take the
        // old time for the new place and send its state again.
        seek(to: 0)
        time = 0
        sentUpTo = nil
        currentCue = nil
        light = [:]
        restore()
    }

    func seek(to seconds: Double) {
        // The duration is 0 until it's known (or with no media): only the bottom limit then.
        let t = duration > 0 ? min(max(seconds, 0), duration) : max(seconds, 0)
        time = t
        sentUpTo = nil // a jump: send the state at the new place first, once the seek has landed
        seekGeneration += 1
        let generation = seekGeneration
        if !isPlaying { showPosition(at: t) } // while playing, the catch-up after the seek does it
        // A seek with a completion handler raises before the item is ready to play (still
        // loading, or failed): then a plain one, which needs no waiting for.
        guard player.currentItem?.status == .readyToPlay else {
            seeking = false
            player.seek(to: CMTime(seconds: t, preferredTimescale: 600))
            return
        }
        seeking = true
        player.seek(to: CMTime(seconds: t, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero) { _ in
            Task { @MainActor [weak self] in
                guard let self, self.seekGeneration == generation else { return }
                self.seeking = false
            }
        }
    }

    /// While the transport slider is dragged, its value isn't overwritten by playback.
    func setScrubbing(_ on: Bool) { scrubbing = on }

    private func ended() {
        isPlaying = false
        restore()
    }

    /// Puts the light back if anything was sent (`saved` is set then), even if sending has since
    /// been turned off.
    private func restore() {
        speedTask?.cancel() // a speed still to come would switch the bulb back on
        speedTask = nil
        speedOwed = nil
        guard let saved else { return }
        self.saved = nil
        if restores { model.restore(saved) }
    }

    // MARK: Sending

    /// About 100 times a second: follow the media's time and send the cues that are due.
    private func startTicking() {
        Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                self.tick()
                try? await Task.sleep(for: .milliseconds(10))
            }
        }
    }

    private func tick() {
        let now = CMTimeGetSeconds(player.currentTime())
        guard now.isFinite else { return }
        // Observed values change only when they need to: this runs 100 times a second.
        let playing = player.rate != 0
        if playing != isPlaying { isPlaying = playing }
        // Not while a seek lands either: the player still has the old time until then.
        if !scrubbing, !seeking, abs(now - time) >= 0.05 || !playing { if now != time { time = now } }
        guard playing, let show, !show.cues.isEmpty else { return }
        // Nothing while the position is being dragged or a seek is landing: the state at the new
        // place goes once it's there, not once per step on the way.
        guard !scrubbing, !seeking else { return }
        let showTime = now + delay / 1000
        // The delay was changed (likely by dragging its slider): carry on from the new point
        // rather than catching up from scratch. Cues it moved past go as the state they add up
        // to; moved back, the ones since are sent again as they come round.
        if let sentUpTo, delay != sentDelay {
            sentDelay = delay
            if abs(showTime - sentUpTo) < 2 {
                let next = show.cues.firstIndex { $0.time > showTime + Self.slack } ?? show.cues.count
                if next > nextCue { sendState(LightShow.state(after: show.cues[nextCue..<next]), trans: 0) }
                if next != nextCue {
                    currentCue = next > 0 ? next - 1 : nil
                    light = next > 0 ? LightShow.state(after: show.cues[..<next]) : [:]
                }
                nextCue = next
                self.sentUpTo = showTime
                return
            }
        }
        sentDelay = delay
        // A jump (seek, a stall, starting): send the state at the new place.
        if sentUpTo == nil || showTime < sentUpTo! - 0.05 || showTime > sentUpTo! + 0.5 {
            catchUp(to: showTime, in: show)
            return
        }
        var due: [LightShow.Cue] = []
        while nextCue < show.cues.count, show.cues[nextCue].time <= showTime + Self.slack {
            due.append(show.cues[nextCue])
            nextCue += 1
        }
        sentUpTo = showTime
        guard let last = due.last else { return }
        if due.count == 1 || showTime - due[0].time < 0.1 {
            for cue in due { send(cue.pilot) }
        } else {
            // Running behind (a slow tick): just the state they add up to, with the last one's fade
            // (`state(after:)` leaves fades out).
            sendState(LightShow.state(after: due), trans: last.pilot["trans"])
        }
        currentCue = last.id
        light = LightShow.state(after: show.cues[...last.id])
    }

    private func catchUp(to showTime: Double, in show: LightShow) {
        nextCue = show.cues.firstIndex { $0.time > showTime + Self.slack } ?? show.cues.count
        sentUpTo = showTime
        guard nextCue > 0 else {
            currentCue = nil
            light = [:]
            return
        }
        // A cut, unless the latest cue has only just come due (playing from the start, or a seek
        // to a cue): then its own fade, as if it had been sent as it came.
        let latest = show.cues[nextCue - 1]
        let fresh = showTime - latest.time <= max(delay, 0) / 1000 + 0.1
        // (A cue without one gets the bulb's own fade, as it would sent alone.)
        speedOwed = nil // the state at the new place is the whole story; it may owe its own
        let trans: Any? = fresh ? latest.pilot["trans"] : 0
        sendState(LightShow.state(after: show.cues[..<nextCue]), trans: trans)
        currentCue = nextCue - 1
        light = LightShow.state(after: show.cues[..<nextCue])
    }

    /// Several cues' combined state, as one setPilot with the given fade. Speed only takes in a
    /// setPilot of its own, so it goes separately, after the scene.
    /// `trans` nil: none, so the bulb's own fade (as for a cue without one).
    private func sendState(_ combined: [String: Any], trans: Any?) {
        var state = combined
        let speed = state.removeValue(forKey: "speed")
        state["trans"] = trans // nil leaves it out
        // Anything besides the fade (which is there or not, as given).
        if state.keys.contains(where: { $0 != "trans" }) { send(state) }
        if Self.supersedesSpeed(combined) {
            speedTask?.cancel()
            speedTask = nil
        }
        guard let speed else { return }
        if state["state"] as? Bool == false {
            // Off: on its own now it would switch it back on. It goes when something does.
            speedOwed = speed
        } else {
            scheduleSpeed(speed)
        }
    }

    /// A scene's speed in a setPilot of its own, just after the scene's.
    private func scheduleSpeed(_ speed: Any) {
        speedTask?.cancel()
        speedTask = Task {
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            self.send(["speed": speed], followUp: true)
        }
    }

    /// The cue list's highlight and the stage's light for a place in the media, without sending:
    /// for seeking while paused, and a show opened part way through.
    private func showPosition(at mediaTime: Double) {
        guard let show else { return }
        let showTime = mediaTime + delay / 1000
        let next = show.cues.firstIndex { $0.time > showTime + Self.slack } ?? show.cues.count
        currentCue = next > 0 ? next - 1 : nil
        light = next > 0 ? LightShow.state(after: show.cues[..<next]) : [:]
    }

    /// Whether a state makes a scene's speed still to be sent out of date: a new colour or scene
    /// (the speed would apply to it), off (it would switch the bulb back on), or a speed of its
    /// own. A dimming or fade change leaves it to follow.
    private static func supersedesSpeed(_ pilot: [String: Any]) -> Bool {
        let keys: Set<String> = ["r", "g", "b", "c", "w", "temp", "sceneId", "elm", "speed"]
        return pilot["state"] as? Bool == false || pilot.keys.contains(where: keys.contains)
    }

    /// `followUp`: a scene's speed, sent separately just after it.
    private func send(_ pilot: [String: Any], followUp: Bool = false) {
        if !followUp, Self.supersedesSpeed(pilot) {
            speedTask?.cancel()
            speedTask = nil
            speedOwed = nil // a new colour, scene or speed: the owed one is out of date
        }
        guard sendsToBulb else { return }
        // The first cue sent: remember the light to put back (whether it's put back is decided
        // when the show stops).
        if saved == nil { saved = model.savedLight }
        model.sendLightCue(pilot)
        // Back on (a setPilot without "state": false switches it on): the speed it was owed.
        if !followUp, pilot["state"] as? Bool != false, let owed = speedOwed {
            speedOwed = nil
            scheduleSpeed(owed)
        }
    }

    // MARK: Display

    /// Roughly the colour the show has the bulb at now.
    var swatch: RGB? {
        if let k = (light["temp"] as? NSNumber)?.intValue { return LightColour.temp(k).swatch }
        if let id = (light["sceneId"] as? NSNumber)?.intValue { return Scenes.swatch(id) }
        let ch = ["r", "g", "b", "c", "w"].map { (light[$0] as? NSNumber)?.intValue ?? 0 }
        return LightColour.rgbcw(r: ch[0], g: ch[1], b: ch[2], c: ch[3], w: ch[4]).swatch
    }

    var brightness: Double {
        if light["state"] as? Bool == false { return 0 }
        return ((light["dimming"] as? NSNumber)?.doubleValue ?? 100) / 100
    }

    nonisolated static func format(_ seconds: Double) -> String {
        // Int() traps on infinity and huge values (a media duration can be either).
        guard seconds.isFinite, seconds < 1e9 else { return "–" }
        let s = max(seconds, 0)
        let m = Int(s) / 60
        return String(format: "%d:%05.2f", m, s - Double(m * 60))
    }

    /// The window or screen has gone: stop, and let go of the files. (The ticker ends by itself
    /// once nothing holds the player.)
    func close() {
        stop()
        player.replaceCurrentItem(with: nil)
        seekGeneration += 1
        seeking = false
        mediaName = nil
        hasVideo = false
        duration = 0
        mediaAccess?.stopAccessingSecurityScopedResource()
        mediaAccess = nil
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        endObserver = nil
        #if os(iOS)
        UIApplication.shared.isIdleTimerDisabled = false
        // Let audio the show interrupted (music in another app) carry on.
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        #endif
    }
}

extension Model {
    /// The light as it is, to put back after a light show.
    struct SavedLight {
        let values: LightValues
        let customScene: UUID?
        let isOn: Bool?
        /// The bulb it's from: another chosen since isn't given this one's light.
        let mac: String?
    }

    var savedLight: SavedLight { SavedLight(values: values, customScene: customSceneId, isOn: isOn, mac: chosenMAC) }

    func restore(_ saved: SavedLight) {
        guard canControl, saved.mac == chosenMAC else { return }
        // The show left it on. Off before: one setPilot with "state": false (the colour kept for
        // when it's switched on, with no flash of it now, and no speed, which would switch it on).
        isOn = saved.isOn != false
        if saved.values.mode == .scene, saved.values.sceneId == Scenes.inlineCustom { customSceneId = saved.customScene }
        // A scene's speed too: the show may have changed it.
        apply(saved.values, fields: saved.values.mode == .scene ? [.colour, .dimming, .speed] : [.colour, .dimming])
    }
}
