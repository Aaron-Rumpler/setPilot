import Foundation

/// One message to or from the bulb, for the console's log.
struct LogEntry: Identifiable, Sendable {
    enum Kind: Sendable {
        /// A request (once, however many times it's retried).
        case sent
        /// A reply on the control connection.
        case received
        /// A syncPilot push on port 38900.
        case push
        /// No reply, or couldn't send.
        case failure
    }

    var id = UUID()
    var date = Date()
    let kind: Kind
    /// The request's method, or the method a reply or push names ("" if none).
    let method: String
    /// The message as JSON text (for failures, what went wrong).
    let text: String

    /// The request as method and params (nil if it had none), to send again.
    var request: (method: String, params: [String: Any]?)? {
        guard kind == .sent, let obj = Net.json(Data(text.utf8)), let method = obj["method"] as? String else { return nil }
        return (method, obj["params"] as? [String: Any])
    }

    /// 24-hour time with milliseconds, whatever the locale's clock.
    static let timeFormat = Date.VerbatimFormatStyle(
        format: "\(hour: .twoDigits(clock: .twentyFourHour, hourCycle: .zeroBased)):\(minute: .twoDigits):\(second: .twoDigits).\(secondFraction: .fractional(3))",
        timeZone: .current, calendar: .current)

    /// One line for Copy All: time, direction, JSON.
    var line: String {
        let arrow = switch kind {
        case .sent: "→"
        case .received: "←"
        case .push: "⇠"
        case .failure: "✕"
        }
        return "\(date.formatted(Self.timeFormat)) \(arrow) \(text)"
    }
}

extension Model {
    /// How many entries the log keeps (oldest dropped first); set in the console.
    static let logLimitKey = "logLimit"
    static let logLimitChoices = [100, 500, 1000, 5000, 20_000]
    static var logLimit: Int {
        let v = UserDefaults.standard.integer(forKey: logLimitKey)
        return v > 0 ? v : 1000
    }

    func appendLog(_ kind: LogEntry.Kind, method: String, text: String) {
        log.append(LogEntry(kind: kind, method: method, text: text))
        trimLog()
    }

    /// Drops the oldest entries beyond the limit (also when the limit is lowered).
    func trimLog() {
        let limit = Self.logLimit
        if log.count > limit { log.removeFirst(log.count - limit) }
    }

    /// The log as text, oldest first.
    func logText(_ entries: [LogEntry]) -> String { entries.map(\.line).joined(separator: "\n") }
}
