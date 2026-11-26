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
            guard let snapshot = model?.snapshot, snapshot != lastSnapshot else { return }
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
        SharedStore.save(s, SharedStore.snapshotKey)
        SharedStore.defaults.set(s.address, forKey: SharedStore.addressKey)
        let signingKey = model?.signingKey(for: model?.chosenMAC)
        if signingKey != publishedKey { // the Keychain only when it changes
            publishedKey = signingKey
            SigningKeyStore.set(signingKey, for: SigningKeyStore.current)
        }
        let key = "\(s.link) \(String(describing: s.isOn)) \(Int(s.dimming / 5)) \(s.mode) \(s.bulbName ?? "")"
        trailingReload?.cancel()
        if key != widgetKey {
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
        // widget can't ask about).
        publishedAsks = Flashing.asks
        // At the fastest speed: the widgets' requests carry no speed, so it plays at the bulb's.
        let flashing = publishedAsks
            ? model.library.presets.filter { model.library.customSceneOf($0.colour)?.flashes(atSpeed: 200) == true }.map(\.id.uuidString) : []
        SharedStore.defaults.set(flashing, forKey: SharedStore.flashingPresetsKey)
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
        WidgetCenter.shared.reloadAllTimelines()
        ControlCenter.shared.reloadAllControls()
    }
}
