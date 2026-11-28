import Foundation

// What scripting can ask for, and what it gets back: shared by the apps (Core/Commands.swift runs
// it) and the command-line tool, which sends it to the Mac app as JSON over a socket.

/// The light as scripting reports it.
struct LightState: Codable, Equatable, Sendable {
    struct Bulb: Codable, Equatable, Sendable {
        var name: String?
        var mac: String?
        var address: String?
    }
    var bulb: Bulb
    /// "connected", "connecting", "unreachable" or "none".
    var link: String
    /// Nil while it isn't known.
    var on: Bool?
    /// "rgbcw", "temperature" or "scene".
    var mode: String
    var dimming: Int
    var temp: Int?
    /// The CCT scale Temperature is on; nil for the bulb's own.
    var scale: String?
    var scene: String?
    var sceneId: Int?
    var speed: Int?
    /// r, g, b, c, w.
    var rgbcw: [Int]?
}

struct ScriptError: Error, Codable, Equatable, Sendable {
    enum Code: String, Codable, Sendable {
        case notAnswering = "not-answering"
        case refused
        case notApplied = "not-applied"
        case noBulb = "no-bulb"
        case notFound = "not-found"
        case badArguments = "bad-arguments"
        /// The CLI couldn't reach the app.
        case appUnavailable = "app-unavailable"
    }
    var code: Code
    var message: String

    /// For the CLI: each kind its own, so scripts can tell them apart without parsing.
    var exitCode: Int32 {
        switch code {
        case .badArguments: 2
        case .appUnavailable: 3
        case .noBulb: 4
        case .notFound: 5
        case .notAnswering: 6
        case .refused: 7
        case .notApplied: 8
        }
    }
}

/// Something to list (for choosing by name).
enum ScriptList: String, Codable, Sendable, CaseIterable {
    case presets, scenes, customScenes = "custom-scenes", scales, bulbs
}

enum ScriptCommand: Codable, Sendable {
    case get
    /// Nil switches it the other way.
    case power(Bool?)
    case brightness(Int)
    case adjustBrightness(Int)
    /// `power`: true switches the bulb on too; nil leaves it as it is (as the controls do).
    case colour(r: Int, g: Int, b: Int, c: Int, w: Int, power: Bool?)
    /// `scale`: a CCT scale's name or ID, "bulb" for the bulb's own, nil for Temperature as last used.
    case temperature(Int, scale: String?, power: Bool?)
    /// A built-in scene, by name or number.
    case scene(String, speed: Int?, power: Bool?)
    /// One of your custom scenes, by name or ID.
    case customScene(String, power: Bool?)
    /// The current scene's speed.
    case speed(Int)
    /// A preset, by name or ID (switches the bulb on, as applying one does).
    case preset(String)
    /// Another of your bulbs, by name, MAC or address.
    case switchBulb(String)
    case list(ScriptList)
    /// Several things at once, in one setPilot (as Compose sends): a colour of one kind, a
    /// brightness, the power.
    case set(ScriptChange)
}

/// What a command gives back.
struct ScriptResult: Codable, Equatable, Sendable {
    var state: LightState?
    /// For `list`: names (each with its ID where it has one).
    var items: [ScriptItem]?
    var error: ScriptError?
}

struct ScriptItem: Codable, Equatable, Sendable {
    var name: String
    var id: String
}

/// What `set` changes; anything left nil stays as it is.
struct ScriptChange: Codable, Equatable, Sendable {
    /// r, g, b, and optionally c and w (0–255).
    var rgbcw: [Int]?
    var temp: Int?
    /// For `temp`: a CCT scale's name or ID, or "bulb"; nil for Temperature as last used.
    var scale: String?
    /// A built-in scene's name or number.
    var scene: String?
    /// One of your custom scenes, by name or ID.
    var customScene: String?
    /// A scene's speed (with `scene` or `customScene`, or the current scene's).
    var speed: Int?
    var brightness: Int?
    /// true switches on, false off; nil leaves it.
    var power: Bool?

    init(rgbcw: [Int]? = nil, temp: Int? = nil, scale: String? = nil, scene: String? = nil, customScene: String? = nil,
         speed: Int? = nil, brightness: Int? = nil, power: Bool? = nil) {
        (self.rgbcw, self.temp, self.scale, self.scene, self.customScene) = (rgbcw, temp, scale, scene, customScene)
        (self.speed, self.brightness, self.power) = (speed, brightness, power)
    }
}

/// A line the command-line tool sends the app: one command, or a request for the state as it changes.
struct ScriptRequest: Codable, Sendable {
    var command: ScriptCommand?
    /// The fade for this change, in ms (setPilot's trans); nil for the controls' fade.
    var fade: Int?
    /// Keep the connection open, the app writing the state (one LightState per line) when it changes.
    var watch: Bool?
    /// When the command was given (seconds since 1970): waits for the bulb count from then (the
    /// app may have had to be launched first), and a change too late to send isn't.
    var asked: Double?
}

/// Where the Mac app and the command-line tool meet: a socket in their shared App Group container.
enum ScriptSocket {
    /// The App Group (Team ID prefixed, so no provisioning profile is needed on the Mac), from the
    /// Info.plist key the build fills in. Nil without a team (an ad-hoc build): no shared container then.
    static var appGroup: String? {
        guard let id = Bundle.main.object(forInfoDictionaryKey: "SetPilotAppGroup") as? String, isTeamGroup(id) else { return nil }
        return id
    }

    /// Starts with a Team ID (10 upper-case letters and digits), as $(TeamIdentifierPrefix) gives.
    static func isTeamGroup(_ id: String) -> Bool {
        let team = id.prefix { $0 != "." }
        return team.count == 10 && team.allSatisfy { $0.isASCII && ($0.isUppercase || $0.isNumber) }
    }

    static var path: String? { path(for: appGroup) }

    /// In the group's container.
    static func path(for group: String?) -> String? {
        guard let group,
              let dir = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group) else { return nil }
        return dir.appendingPathComponent("cli.sock").path
    }

    /// Calls `body` (bind or connect) with an address for the socket at `path`. A Unix socket's
    /// address holds its path in a fixed 104-byte field (`sun_path` in Darwin's `sockaddr_un`,
    /// NUL included), and the group container's path, under the home folder, can be longer than
    /// that with a long user name. Then the address holds just the file's name, relative to the
    /// container, made the working directory for the moment it takes.
    static func withAddress(_ path: String, _ body: (UnsafePointer<sockaddr>, socklen_t) -> Int32) -> Int32 {
        var address = sockaddr_un()
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        var bytes = Array(path.utf8)
        var restore: String?
        if bytes.count >= capacity {
            let url = URL(fileURLWithPath: path)
            restore = FileManager.default.currentDirectoryPath
            guard FileManager.default.changeCurrentDirectoryPath(url.deletingLastPathComponent().path) else { return -1 }
            bytes = Array(url.lastPathComponent.utf8)
        }
        defer { if let restore { FileManager.default.changeCurrentDirectoryPath(restore) } }
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            buffer.copyBytes(from: bytes)
            buffer[bytes.count] = 0
        }
        return withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { body($0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
    }
}

extension ScriptCommand {
    /// Whether it changes the light, rather than only reading. (Switching bulbs counts as
    /// reading: it's the way out of one that isn't answering.)
    var changes: Bool {
        switch self {
        // Switching bulbs is the way out of one that isn't answering, and lands on another.
        // (Used by the watch relay and the command-line tool too.)
        case .get, .list, .switchBulb: false
        default: true
        }
    }
}
