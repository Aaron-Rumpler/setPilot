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
        // Exactly 1: not true (an NSNumber too, told apart as in `seconds`), and not 1.5.
        guard let format = obj["setPilotLightShow"] as? NSNumber, CFGetTypeID(format) != CFBooleanGetTypeID(),
              format.doubleValue == 1 else {
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
        for (i, part) in parts.enumerated() {
            // Plain numbers only ("1e3" and "inf" are Doubles too); minutes and hours whole, and
            // seconds and minutes after the first part under 60 ("1:75" is a typo, not 2:15).
            guard !part.isEmpty, part.allSatisfy({ $0.isASCII && ($0.isNumber || $0 == ".") }),
                  let v = Double(part), v >= 0 else { return nil }
            if i < parts.count - 1, v != v.rounded() { return nil }
            if i > 0, v >= 60 { return nil }
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
        let channels: Set<String> = ["r", "g", "b", "c", "w"]
        let otherColour: Set<String> = ["temp", "sceneId", "elm", "speed"]
        var state: [String: Any] = [:]
        for cue in cues {
            if cue.pilot["temp"] != nil || cue.pilot["sceneId"] != nil {
                // A temperature or scene replaces the colour altogether.
                state = state.filter { !channels.contains($0.key) && !otherColour.contains($0.key) }
            } else if cue.pilot.keys.contains(where: channels.contains) {
                // Channels: a temperature or scene goes, but the channels not sent stay as they
                // were (the bulb keeps them), as when the cues are played one by one.
                state = state.filter { !otherColour.contains($0.key) }
            }
            // A setPilot without "state" switches the bulb on: an earlier off no longer holds. Not a
            // speed on its own, though: the player holds that while the bulb is off.
            if cue.pilot["state"] == nil, cue.pilot.keys.contains(where: { $0 != "trans" && $0 != "speed" }) {
                state["state"] = nil
            }
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
    /// Why the light wasn't wholly put back after the last show, until the next one starts.
    private(set) var restoreNote: String?

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
    /// A scene's speed still to be sent. Speed only takes in a setPilot of its own, so it goes
    /// 300 ms after the scene's (`speedTask`), and only while the bulb is on: on its own it would
    /// switch the bulb on. So while the show has the bulb off it waits for a cue that switches it
    /// back on. A new colour, scene or speed makes it out of date; a dimming or fade change, or
    /// switching off, doesn't.
    @ObservationIgnored private var pendingSpeed: Any?
    @ObservationIgnored private var speedTask: Task<Void, Never>?
    /// A seek made without a completion handler (the item wasn't ready): where to, and when.
    @ObservationIgnored private var plainSeek: (to: Double, at: Date)?
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
        plainSeek = nil
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
        restoreNote = nil // about the last show
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
            pendingSpeed = nil // the old show's
            speedTask?.cancel()
            speedTask = nil
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
        showPosition(at: 0) // a cue at the very start is the current one, as when seeking there
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
            // No completion to wait for: treat it as landed once the player's time gets there
            // (or after a moment, if the item never becomes ready), so the time shown doesn't jump
            // back meanwhile.
            seeking = true
            plainSeek = (t, .now)
            player.seek(to: CMTime(seconds: t, preferredTimescale: 600))
            return
        }
        plainSeek = nil
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
        pendingSpeed = nil
        guard let saved else { return }
        self.saved = nil
        if restores { restoreNote = model.restore(saved) }
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
        if let seek = plainSeek, abs(now - seek.to) < 0.05 || Date.now.timeIntervalSince(seek.at) > 2 {
            plainSeek = nil
            seeking = false
        }
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
            // Where the show would be now with the delay as it was: cues up to there came due
            // anyway, and go as they are (their own fades); only the ones the change moved past
            // go as the state they add up to, as a cut.
            let natural = now + (sentDelay ?? delay) / 1000
            sentDelay = delay
            if abs(showTime - sentUpTo) < 2 {
                let next = show.cues.firstIndex { $0.time > showTime + Self.slack } ?? show.cues.count
                if next > nextCue {
                    let due = show.cues[nextCue..<next]
                    let skipped = due.firstIndex { $0.time > natural + Self.slack } ?? next
                    for cue in due[..<skipped] {
                        send(cue.pilot)
                        light = LightShow.state(after: show.cues[...cue.id])
                    }
                    if skipped < next { sendState(LightShow.state(after: show.cues[skipped..<next]), trans: 0) }
                }
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
            for cue in due {
                send(cue.pilot)
                light = LightShow.state(after: show.cues[...cue.id]) // the next one sees this one's
            }
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
        // The state at the new place is the whole story, its speed included (none, before the
        // first cue): a speed from before the jump is out of date.
        pendingSpeed = nil
        speedTask?.cancel()
        speedTask = nil
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
        let trans: Any? = fresh ? latest.pilot["trans"] : 0
        // The show's state at the new place first: sending goes by it (a speed held while off).
        currentCue = nextCue - 1
        light = LightShow.state(after: show.cues[..<nextCue])
        sendState(light, trans: trans)
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
        guard let speed else { return }
        pendingSpeed = speed // replaces any older one
        // Off: this state switches it off, or (speed alone) the show already has it off.
        let alone = !state.keys.contains(where: { $0 != "trans" })
        if state["state"] as? Bool == false || alone && light["state"] as? Bool == false {
            speedTask?.cancel() // off: it waits for the bulb to be switched on
            speedTask = nil
        } else {
            scheduleSpeed()
        }
    }

    /// Sends `pendingSpeed` in 300 ms (just after the setPilot that's gone or going now).
    private func scheduleSpeed() {
        speedTask?.cancel()
        speedTask = Task {
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled, let speed = self.pendingSpeed else { return }
            self.pendingSpeed = nil
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

    /// `followUp`: a pending speed, being sent.
    private func send(_ pilot: [String: Any], followUp: Bool = false) {
        // A speed on its own while the show has the bulb off (`light` is the show's state so far)
        // would switch it on: hold it until a cue does.
        if pilot.keys.allSatisfy({ $0 == "speed" || $0 == "trans" }), let speed = pilot["speed"],
           light["state"] as? Bool == false {
            pendingSpeed = speed
            speedTask?.cancel()
            speedTask = nil
            return
        }
        let off = pilot["state"] as? Bool == false
        if !followUp {
            let replacing: Set<String> = ["r", "g", "b", "c", "w", "temp", "sceneId", "elm", "speed"]
            if pilot.keys.contains(where: replacing.contains) {
                pendingSpeed = nil // out of date: a new colour or scene, or a speed of its own
                speedTask?.cancel()
                speedTask = nil
            } else if off {
                speedTask?.cancel() // kept for when the bulb is switched back on
                speedTask = nil
            }
        }
        guard sendsToBulb else { return }
        // The first cue sent: remember the light to put back (whether it's put back is decided
        // when the show stops).
        if saved == nil { saved = model.savedLight; restoreNote = nil }
        model.sendLightCue(pilot)
        // On (a setPilot without "state": false switches it on), with a speed waiting: send it.
        // (A fade on its own isn't taken as switching it on, as elsewhere.)
        if !followUp, !off, pilot.keys.contains(where: { $0 != "trans" }), pendingSpeed != nil, speedTask == nil {
            scheduleSpeed()
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
        // Rounded to hundredths first, so 59.996 is 1:00.00 rather than 0:60.00.
        let s = (max(seconds, 0) * 100).rounded() / 100
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
        plainSeek = nil
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

    /// Nil, or why only part of it could be put back.
    @discardableResult
    func restore(_ saved: SavedLight) -> String? {
        guard saved.mac == chosenMAC else { return nil } // another bulb chosen since: not this one's
        guard canControl else { return "The bulb wasn't answering when the show ended, so the light wasn't put back" }
        // The show left it on. Off before: one setPilot with "state": false (the colour kept for
        // when it's switched on, with no flash of it now, and no speed, which would switch it on).
        // (Not known when the show started: as it is now.)
        if let was = saved.isOn { isOn = was }
        if saved.values.mode == .scene, saved.values.sceneId == Scenes.inlineCustom { customSceneId = saved.customScene }
        // A scene's speed too: the show may have changed it. A scene that can't be sent (Rhythm, one
        // newer than this app, a custom scene deleted meanwhile) would become another: only the
        // brightness and power go back then.
        let v = saved.values
        if v.mode == .scene, !Scenes.isKnown(v.sceneId),
           !(v.sceneId == Scenes.inlineCustom && saved.customScene.flatMap(library.customScene) != nil) {
            apply(v, fields: [.dimming])
            return "The scene from before (\(Scenes.name(v.sceneId))) can't be sent: only the brightness and power were put back"
        }
        apply(v, fields: v.mode == .scene ? [.colour, .dimming, .speed] : [.colour, .dimming])
        return nil
    }
}
