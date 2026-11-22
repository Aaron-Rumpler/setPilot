import OSLog

/// setPilot's own log, in the system log (Console.app, or `log stream --predicate
/// 'subsystem == "nz.aaronrumpler.setPilot"'`), and in an exported diagnostics report.
enum Log {
    static let subsystem = "nz.aaronrumpler.setPilot"
    static let bulb = Logger(subsystem: subsystem, category: "bulb")
    static let sync = Logger(subsystem: subsystem, category: "sync")
    static let scripting = Logger(subsystem: subsystem, category: "scripting")
    static let app = Logger(subsystem: subsystem, category: "app")
}
