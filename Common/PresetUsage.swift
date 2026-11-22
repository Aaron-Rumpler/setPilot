import Foundation

/// When presets have been applied, for the watch's Smart Stack: a preset you apply at about the
/// same time of day on several days is put forward around then. Recorded on the iPhone and Mac
/// (Model.apply) and on the watch; the iPhone passes its record to the watch with the presets.
enum PresetUsage {
    struct Use: Codable, Hashable, Sendable {
        var id: UUID
        var at: Date
    }

    static let key = "presetUsage"
    /// Posted after a use is recorded (the iPhone passes it on to the watch).
    static let recorded = Notification.Name("PresetUsage.recorded")
    /// How far back it looks, and how many it keeps.
    private static let days = 30.0
    private static let limit = 300

    static func load(_ defaults: UserDefaults) -> [Use] {
        guard let d = defaults.data(forKey: key) else { return [] }
        return (try? JSONDecoder().decode([Use].self, from: d)) ?? []
    }

    static func record(_ id: UUID, in defaults: UserDefaults, at date: Date = .now) {
        save(load(defaults) + [Use(id: id, at: date)], in: defaults)
        NotificationCenter.default.post(name: recorded, object: nil)
    }

    /// Adds uses from another device (the iPhone's, on the watch).
    static func merge(_ uses: [Use], into defaults: UserDefaults) {
        save(Array(Set(load(defaults) + uses)), in: defaults)
    }

    private static func save(_ uses: [Use], in defaults: UserDefaults) {
        let since = Date.now.addingTimeInterval(-days * 86_400)
        let kept = uses.filter { $0.at > since }.sorted { $0.at < $1.at }.suffix(limit)
        if let d = try? JSONEncoder().encode(Array(kept)) { defaults.set(d, forKey: key) }
    }

    /// The times in the next day when `preset` (or any preset, if nil) is usually applied: each
    /// half hour of the day it's been applied in on at least two days, with how many days.
    static func usualTimes(_ uses: [Use], preset: UUID?, after now: Date = .now,
                           calendar: Calendar = .current) -> [(start: Date, days: Int)] {
        var daysBySlot: [Int: Set<DateComponents>] = [:]
        for use in uses where preset == nil || use.id == preset {
            let c = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: use.at)
            guard let h = c.hour, let m = c.minute else { continue }
            let slot = h * 2 + m / 30
            daysBySlot[slot, default: []].insert(DateComponents(year: c.year, month: c.month, day: c.day))
        }
        let today = calendar.startOfDay(for: now)
        return daysBySlot.compactMap { slot, days -> (Date, Int)? in
            guard days.count >= 2 else { return nil }
            // Put forward from a quarter of an hour before the slot.
            guard var start = calendar.date(byAdding: .minute, value: slot * 30 - 15, to: today) else { return nil }
            if start.addingTimeInterval(45 * 60) < now { start = start.addingTimeInterval(86_400) }
            return (start, days.count)
        }
        .sorted { $0.0 < $1.0 }
    }
}
