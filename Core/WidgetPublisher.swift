#if os(macOS)
import AppKit
#endif
import Foundation
import Observation
import WidgetKit

/// Keeps what the widgets and controls show (and, for ones that send themselves, what they send)
/// in the App Group: the state, the presets with their ready-made requests, the address, the
/// signing key and the controls' fade. Reloads them only when something they show changes (they
/// have a reload budget). The iPhone app and the Mac app each run one.
@MainActor
final class WidgetPublisher {
    static let shared = WidgetPublisher()
    private var model: Model?

    func start(model: Model) {
        // No App Group (a Mac build without a team): nothing would read it.
        guard self.model == nil, SharedStore.isShared else { return }
        self.model = model
        publishLibrary()
        observe()
        keepHeardCurrent()
        #if os(macOS)
        // Asleep, nothing keeps the state current (and a Mac can sleep for days): shown as not
        // known meanwhile, and as it is again once awake. So it needn't be re-stamped often while
        // the Mac's awake (LightSnapshot.trustedFor is longer here), which saves reloads.
        let workspace = NSWorkspace.shared.notificationCenter
        workspace.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated {
                WidgetPublisher.shared.wakeWait?.cancel()
                WidgetPublisher.shared.asleep = true
                WidgetPublisher.shared.publishUnknown()
            }
        }
        workspace.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { WidgetPublisher.shared.awoke() }
        }
        #endif
        // "Ask before playing" turned on or off: which presets a widget refuses.
        NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: UserDefaults.standard, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, Flashing.asks != self.publishedAsks else { return }
                self.libraryChanged()
            }
        }
    }

    // MARK: State

    private var scheduled = false
    private var lastSnapshot: LightSnapshot?
    /// The Mac's going to sleep: the not-known state stays until it's awake (a change as the
    /// network goes mustn't write over it).
    private var asleep = false
    private var wakeWait: Task<Void, Never>?

    private func observe() {
        guard let model else { return }
        withObservationTracking {
            _ = model.snapshot
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.schedule()
                self?.observe()
            }
        }
        schedule()
    }

    /// At most every 0.3 s.
    private func schedule() {
        guard !scheduled else { return }
        scheduled = true
        Task {
            try? await Task.sleep(for: .milliseconds(300))
            scheduled = false
            guard !asleep, let snapshot = model?.snapshot, snapshot != lastSnapshot else { return }
            lastSnapshot = snapshot
            publishState(snapshot)
        }
    }

    private var widgetKey: String?
    private var reloadedDimming: Int?
    private var trailingReload: Task<Void, Never>?
    private var publishedFloor: Double?
    private var publishedAddress: String?
    private var publishedKey: String?

    private func publishState(_ s: LightSnapshot) {
        // The presets' ready-made requests clamp to the bulb's minimum dimming: again once it's
        // known, or another bulb is chosen (unchanged, nothing's reloaded).
        if s.minDimming != publishedFloor || s.address != publishedAddress {
            publishedFloor = s.minDimming
            publishedAddress = s.address
            publishLibrary()
        }
        // Shown as only the last known by now: reloaded whatever else has changed.
        let wasStale = shownStale(within: 0)
        let stampedElsewhere = saveState(s)
        SharedStore.defaults.set(s.address, forKey: SharedStore.addressKey)
        let signingKey = model?.signingKey(for: model?.chosenMAC)
        if signingKey != publishedKey { // the Keychain only when it changes
            publishedKey = signingKey
            SigningKeyStore.set(signingKey, for: SigningKeyStore.current)
        }
        let key = "\(s.link) \(String(describing: s.isOn)) \(Int(s.dimming / 5)) \(s.bulbName ?? "")"
        trailingReload?.cancel()
        if key != widgetKey || wasStale || stampedElsewhere {
            widgetKey = key
            reloadedDimming = Int(s.dimming)
            reload()
        } else if Int(s.dimming) != reloadedDimming {
            // Within the same step of 5, but they show the exact level: once it's settled, so a
            // drag costs one more reload, not one per step.
            trailingReload = Task {
                try? await Task.sleep(for: .seconds(1.5))
                guard !Task.isCancelled else { return }
                reloadedDimming = Int(s.dimming)
                reload()
            }
        }
    }

    /// When the shared state says the bulb was last heard, and when it said so as the widgets were
    /// last reloaded (what they go by until the next).
    private var publishedHeard: Date?
    private var reloadedHeard: Date?

    /// Writes the state with when the bulb was last heard. True if the one there had been stamped
    /// by someone else since (a Mac widget's tap, which backdates it and reloads them): what they
    /// show goes by that, so they're to be reloaded with this one.
    @discardableResult
    private func saveState(_ s: LightSnapshot) -> Bool {
        var s = s
        s.heardAt = model?.heardAt
        // (Within a second: the stamp goes through JSON.)
        var stampedElsewhere = false
        if let there = SharedStore.snapshot?.heardAt {
            stampedElsewhere = publishedHeard.map { abs(there.timeIntervalSince($0)) > 1 } ?? true
        }
        publishedHeard = s.heardAt
        SharedStore.save(s, SharedStore.snapshotKey)
        return stampedElsewhere
    }

    /// Whether what the widgets show turns into the last known state within `seconds`.
    private func shownStale(within seconds: TimeInterval) -> Bool {
        guard let heard = reloadedHeard else { return false }
        return Date.now.addingTimeInterval(seconds) >= heard.addingTimeInterval(LightSnapshot.trustedFor)
    }

    /// The bulb is heard from all the time without the state changing, so once a minute the time
    /// it was last heard is written again (read when the widgets next reload). They're reloaded
    /// only when theirs is about to show as the last known, or already does (the app was
    /// suspended, or the Mac asleep), as they have a reload budget.
    private func keepHeardCurrent() {
        Task { [weak self] in
            while true {
                try? await Task.sleep(for: .seconds(60))
                guard let self else { return }
                guard !self.asleep, let s = self.lastSnapshot, let heard = self.model?.heardAt, heard != self.publishedHeard else { continue }
                let due = self.shownStale(within: 5 * 60)
                if self.saveState(s) || due { self.reload() }
            }
        }
    }

    /// The app's leaving the foreground (iPhone, at .inactive): what the widgets hold may be up to minutes
    /// older than the state (they're reloaded only as it's about to show as the last known), and
    /// nothing rewrites it once the app's suspended. Reloaded once, with when the bulb was last
    /// heard, so they show it as the bulb's own for the whole of `trustedFor` from now.
    func enteringBackground() {
        guard !asleep, let s = lastSnapshot, let heard = model?.heardAt, heard > (reloadedHeard ?? .distantPast) else { return }
        saveState(s)
        reload()
    }

    /// The Mac app is quitting: nothing keeps the state current once it's gone, so the widgets and
    /// controls show it as not known (until one of them hears from the bulb itself).
    func appTerminating() {
        publishUnknown()
    }

    /// Back from sleep: the state as it is now, reloaded whether or not it differs from the one
    /// before sleep. Not until the bulb's been heard since waking, or the link's no longer
    /// connected: until then the model still holds the state from before sleep, and the link
    /// can stay connected through a quiet retry. Polled, as hearing it changes nothing observed.
    private func awoke() {
        wakeWait?.cancel()
        let woke = Date.now
        wakeWait = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, let model = self.model else { return }
                if model.heardSince(woke) || model.link != .connected {
                    self.asleep = false
                    self.lastSnapshot = nil
                    self.widgetKey = nil
                    self.schedule()
                    return
                }
                try? await Task.sleep(for: .milliseconds(250))
            }
        }
    }

    /// Shown as not known, until the app (or a widget, hearing from the bulb itself) says again.
    private func publishUnknown() {
        guard let model else { return }
        var s = lastSnapshot ?? model.snapshot
        s.isOn = nil
        s.heardAt = .distantPast
        publishedHeard = s.heardAt // this one's own stamp (not another's, when it's next written)
        SharedStore.save(s, SharedStore.snapshotKey)
        reload()
    }

    // MARK: Library

    private var publishedLibrary: [Data?] = []
    private var publishedAsks = true
    private var fadeReload: Task<Void, Never>?
    private var libraryScheduled = false

    /// The library or a setting they carry (the fades) changed: at most twice a second.
    func libraryChanged() {
        guard !libraryScheduled else { return }
        libraryScheduled = true
        Task {
            try? await Task.sleep(for: .milliseconds(500))
            libraryScheduled = false
            publishLibrary()
        }
    }

    /// The presets, each with its setPilot ready to send.
    func publishLibrary() {
        guard let model else { return }
        SharedStore.save(model.library.presets, SharedStore.presetsKey)
        SharedStore.save(model.library.summaries, SharedStore.customScenesKey) // for custom scene swatches
        var params: [String: Data] = [:]
        for preset in model.library.presets {
            // Sorted keys: compared below, so unchanged must match.
            if let p = model.pilotParams(for: preset), let d = try? JSONSerialization.data(withJSONObject: p, options: .sortedKeys) {
                params[preset.id.uuidString] = d
            }
        }
        SharedStore.defaults.set(params, forKey: SharedStore.presetParamsKey)
        // Those a tap can't play: the app asks before a flashing scene (a person's tap, which a
        // widget can't ask about), and one of the bulb's stored scenes is only started in the app,
        // asked about or not (it can't be judged), as scripts refuse it.
        publishedAsks = Flashing.asks
        let stored = model.library.presets.filter(\.colour.isStoredScene).map(\.id.uuidString)
        // At the fastest speed: the widgets' requests carry no speed, so it plays at the bulb's.
        let flashing = publishedAsks
            ? model.library.presets.filter { model.library.customSceneOf($0.colour)?.flashes(atSpeed: 200) == true }.map(\.id.uuidString) : []
        SharedStore.defaults.set(stored + flashing, forKey: SharedStore.flashingPresetsKey)
        SharedStore.defaults.set(stored, forKey: SharedStore.storedPresetsKey)
        SharedStore.defaults.set(publishedAsks, forKey: SharedStore.asksFlashingKey)
        SharedStore.defaults.set(model.fadeForControls, forKey: SharedStore.controlsTransKey)
        // Only when something they show or send has changed (most library edits, a custom scene's
        // steps say, don't).
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let shown = [try? encoder.encode(model.library.presets), try? encoder.encode(model.library.summaries),
                     try? encoder.encode(params), try? encoder.encode(model.fadeForControls)]
        guard shown != publishedLibrary else { return }
        let onlyFade = publishedLibrary.count == shown.count && Array(shown.dropLast()) == Array(publishedLibrary.dropLast())
        publishedLibrary = shown
        fadeReload?.cancel()
        if onlyFade {
            // Only the controls' fade (being typed, say): once it's settled, not each keystroke.
            fadeReload = Task {
                try? await Task.sleep(for: .seconds(2))
                guard !Task.isCancelled else { return }
                reload()
            }
        } else {
            reload()
        }
    }

    func reload() {
        reloadedHeard = publishedHeard
        WidgetCenter.shared.reloadAllTimelines()
        ControlCenter.shared.reloadAllControls()
    }
}

extension Model {
    /// When the bulb was last heard (a reply or a push), while it's answering.
    var heardAt: Date? { link == .connected && lastHeard != .distantPast ? lastHeard : nil }
}
