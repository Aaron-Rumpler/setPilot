import Foundation

/// When presets are applied and the light switched on or off, to learn your habits: for the watch's
/// Smart Stack (setPilot's widgets come forward when you usually use them) and the iPhone's quick
/// actions (your most used presets). Recorded on the iPhone and Mac (Model), synced between them
/// through iCloud (CloudSync), and passed from the iPhone to the watch with the presets.
///
/// Habits vary, so this learns a spread rather than fixed times: each use adds a bump of about an
/// hour either side at its time of day, recent days counting more (a use a fortnight old counts
/// half). A bedtime anywhere between 11 pm and 5 am becomes a broad stretch of middling relevance
/// across those hours, strongest where it's most often.
enum PresetUsage {
    struct Use: Codable, Hashable, Sendable {
        /// A preset's ID, or `powerOn` / `powerOff`.
        var key: String
        var at: Date

        init(key: String, at: Date) {
            self.key = key
            self.at = at
        }

        // Earlier builds kept only presets, as `id`.
        private enum CodingKeys: String, CodingKey { case key, id, at }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            at = try c.decode(Date.self, forKey: .at)
            key = try c.decodeIfPresent(String.self, forKey: .key) ?? c.decode(UUID.self, forKey: .id).uuidString
        }

        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(key, forKey: .key)
            try c.encode(at, forKey: .at)
        }
    }

    static let key = "presetUsage"
    static let powerOn = "powerOn"
    static let powerOff = "powerOff"
    /// Posted after a use is recorded (the iPhone passes it on to the watch).
    static let recorded = Notification.Name("PresetUsage.recorded")
    /// How far back it looks, and how many it keeps.
    private static let days = 60.0
    private static let limit = 1000
    /// How much a use counts after this many days: half.
    private static let halfLife = 14.0
    /// The spread of each use around its time of day, in minutes.
    private static let spread = 60.0

    static func load(_ defaults: UserDefaults) -> [Use] {
        guard let d = defaults.data(forKey: key) else { return [] }
        return (try? JSONDecoder().decode([Use].self, from: d)) ?? []
    }

    static func record(_ key: String, in defaults: UserDefaults, at date: Date = .now) {
        save(load(defaults) + [Use(key: key, at: date)], in: defaults)
        NotificationCenter.default.post(name: recorded, object: nil)
    }

    /// Adds uses from another device. Returns whether anything was new.
    @discardableResult
    static func merge(_ uses: [Use], into defaults: UserDefaults) -> Bool {
        let had = load(defaults)
        let all = Set(had + uses)
        guard all.count != had.count else { return false }
        save(Array(all), in: defaults)
        return true
    }

    private static func save(_ uses: [Use], in defaults: UserDefaults) {
        let since = Date.now.addingTimeInterval(-days * 86_400)
        let kept = uses.filter { $0.at > since }.sorted { $0.at < $1.at }.suffix(limit)
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys // compared byte for byte on the watch
        if let d = try? encoder.encode(Array(kept)) { defaults.set(d, forKey: key) }
    }

    private static func weight(_ use: Use, now: Date) -> Double {
        let age = max(0, now.timeIntervalSince(use.at) / 86_400)
        return pow(0.5, age / halfLife)
    }

    /// How usual `keys` (any, if nil) are at `time`, from 0: the weighted bumps of past uses at
    /// that time of day. Nothing until they've been used on at least 3 different days.
    static func usualness(_ uses: [Use], keys: Set<String>?, at time: Date, now: Date = .now,
                          calendar: Calendar = .current) -> Double {
        let mine = uses.filter { keys?.contains($0.key) ?? true }
        let days = Set(mine.map { calendar.startOfDay(for: $0.at) })
        guard days.count >= 3 else { return 0 }
        let t = minuteOfDay(time, calendar)
        var total = 0.0
        for use in mine {
            var d = abs(minuteOfDay(use.at, calendar) - t)
            d = min(d, 1440 - d) // round the clock: 11 pm and 1 am are 2 hours apart
            total += weight(use, now: now) * exp(-(d * d) / (2 * spread * spread))
        }
        return total
    }

    /// The presets used most (recent uses counting more), most first.
    static func mostUsed(_ uses: [Use], now: Date = .now) -> [UUID] {
        var score: [UUID: Double] = [:]
        for use in uses { if let id = UUID(uuidString: use.key) { score[id, default: 0] += weight(use, now: now) } }
        return score.sorted { $0.value > $1.value }.map(\.key)
    }

    private static func minuteOfDay(_ date: Date, _ calendar: Calendar) -> Double {
        let c = calendar.dateComponents([.hour, .minute], from: date)
        return Double((c.hour ?? 0) * 60 + (c.minute ?? 0))
    }
}
