import Foundation
#if canImport(Darwin)
import Darwin
#endif

// setpilot: the command-line tool. It asks the setPilot Mac app (launching it in the background if
// it isn't running) to do what its controls do, over a socket in their shared App Group container.

let usage = """
usage: setpilot [--json] <command> [arguments]

  get                          the light's state
  on | off | toggle            switch the bulb
  brightness <1–100>
  brighter [step] | dimmer [step]
  colour <r> <g> <b> [c] [w]   channels 0–255
  temp <kelvin> [--scale <name>|bulb]
  scene <name|number> [--speed <10–200>]
  custom <name>                one of your custom scenes
  speed <10–200>               the current scene's speed
  preset <name>                switches the bulb on, as applying a preset does
  switch <bulb>                another of your bulbs, by name, MAC or address
  set [options]                several at once, in one change (as Compose sends):
        --rgb r,g,b[,c,w] | --temp <kelvin> [--scale <name>|bulb]
        | --scene <name|number> | --custom <name>
        [--speed <10–200>] [--brightness <1–100>] [--on | --off]
  list presets|scenes|custom-scenes|scales|bulbs
  watch                        the state, one line each time it changes, until stopped

  --on     also switch the bulb on (colour, temp, scene, custom); otherwise
           the power is left as it is, as the app's controls do
  --fade <ms>  this change's fade (0–86400000, a day); otherwise the controls' fade
               (not for speed: a speed change has no fade)
  --json   JSON output (watch: one object per line)

Changes are reported once the bulb has answered and read back as asked.
Exit codes: 0 done, 2 bad arguments, 3 app unavailable, 4 no bulb chosen,
5 not found, 6 not answering, 7 refused, 8 not applied.
"""

// MARK: Arguments

// When the command was given: the app counts its waits from then (launching it counts).
let started = Date()
var args = Array(CommandLine.arguments.dropFirst())
/// A flag given more than once (refused below, once --json is known: it says how to report it).
var repeatedFlag: String?
func takeFlag(_ name: String) -> Bool {
    guard let i = args.firstIndex(of: name) else { return false }
    args.remove(at: i)
    // Given twice: refused as an option is (a second left behind would be taken for a name).
    if args.contains(name), repeatedFlag == nil { repeatedFlag = name }
    args.removeAll { $0 == name }
    return true
}
/// Every option and flag, so one isn't taken for another's value.
let optionNames: Set<String> = ["--json", "--on", "--off", "--scale", "--speed", "--fade", "--rgb", "--temp",
                                "--scene", "--custom", "--brightness"]
func takeOption(_ name: String) -> String? {
    guard let i = args.firstIndex(of: name) else { return nil }
    // Given twice: which was meant isn't clear.
    if args[(i + 1)...].contains(name) { badArguments("\(name) is given more than once.") }
    // Followed by another option instead (its value left out): not taken for this one's value,
    // or the error would blame the wrong thing.
    guard i + 1 < args.count, !optionNames.contains(args[i + 1]) else { badArguments("\(name) needs a value.") }
    let value = args[i + 1]
    args.removeSubrange(i...(i + 1))
    return value
}

let json = takeFlag("--json")
let onFlag = takeFlag("--on")
let offFlag = takeFlag("--off")
let switchOn: Bool? = onFlag ? true : nil
let scaleOption = takeOption("--scale")
let speedOption = takeOption("--speed")
let fadeOption = takeOption("--fade")
let rgbOption = takeOption("--rgb")
let tempOption = takeOption("--temp")
let sceneOption = takeOption("--scene")
let customOption = takeOption("--custom")
let brightnessOption = takeOption("--brightness")

func fail(_ error: ScriptError) -> Never {
    if json {
        print(encode(ScriptResult(state: nil, error: error)))
    } else {
        FileHandle.standardError.write(Data("setpilot: \(error.message)\n".utf8))
    }
    exit(error.exitCode)
}
func badArguments(_ message: String) -> Never {
    if !json { FileHandle.standardError.write(Data((usage + "\n").utf8)) }
    fail(ScriptError(code: .badArguments, message: message))
}
func int(_ s: String?, _ what: String) -> Int {
    guard let s, let n = Int(s) else { badArguments("\(what) has to be a whole number.") }
    return n
}

func encode<T: Encodable>(_ value: T) -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    return (try? encoder.encode(value)).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
}

guard let verb = args.first?.lowercased() else {
    // Options but no command (an empty variable in a script, say): a mistake, not a request for help.
    if CommandLine.arguments.count > 1 { badArguments("No command given.") }
    print(usage)
    exit(0)
}
if let repeatedFlag { badArguments("\(repeatedFlag) is given more than once.") }
if offFlag, verb != "set" { badArguments("--off goes with set (for the others, use off).") }
let rest = Array(args.dropFirst())

var watching = false
let command: ScriptCommand
switch verb {
case "-h", "--help", "help":
    print(usage)
    exit(0)
case "get", "state": command = .get
case "on": command = .power(true)
case "off": command = .power(false)
case "toggle": command = .power(nil)
case "brightness", "dim", "dimming":
    guard let level = rest.first else { badArguments("brightness takes a level, 1–100.") }
    command = .brightness(int(level, "The brightness"))
case "brighter", "dimmer":
    // A step of 1–100: the verb says which way (a negative one would go the other).
    let step = rest.first.map { int($0, "The step") } ?? 10
    guard (1...100).contains(step) else { badArguments("The step is 1–100.") }
    command = .adjustBrightness(verb == "dimmer" ? -step : step)
case "colour", "color", "rgb", "rgbcw":
    guard (3...5).contains(rest.count) else { badArguments("colour takes r g b, and optionally c and w.") }
    let v = rest.map { int($0, "Each channel") } + Array(repeating: 0, count: 5 - rest.count)
    command = .colour(r: v[0], g: v[1], b: v[2], c: v[3], w: v[4], power: switchOn)
case "temp", "temperature", "kelvin":
    guard let kelvin = rest.first else { badArguments("temp takes a kelvin, such as 2700.") }
    command = .temperature(int(kelvin, "The kelvin"), scale: scaleOption, power: switchOn)
case "scene":
    guard !rest.isEmpty else { badArguments("scene takes a scene's name or number.") }
    command = .scene(rest.joined(separator: " "), speed: speedOption.map { int($0, "The speed") }, power: switchOn)
case "custom", "custom-scene", "customscene":
    guard !rest.isEmpty else { badArguments("custom takes one of your custom scenes' names.") }
    command = .customScene(rest.joined(separator: " "), power: switchOn)
case "speed":
    guard let speed = rest.first else { badArguments("speed takes 10–200.") }
    command = .speed(int(speed, "The speed"))
case "preset":
    guard !rest.isEmpty else { badArguments("preset takes a preset's name.") }
    command = .preset(rest.joined(separator: " "))
case "switch", "bulb":
    guard !rest.isEmpty else { badArguments("switch takes a bulb's name, MAC or address.") }
    command = .switchBulb(rest.joined(separator: " "))
case "list":
    guard let kind = rest.first.flatMap({ ScriptList(rawValue: $0.lowercased()) }) else {
        badArguments("list takes one of: \(ScriptList.allCases.map(\.rawValue).joined(separator: ", ")).")
    }
    command = .list(kind)
case "set":
    guard !(onFlag && offFlag) else { badArguments("--on or --off, not both.") }
    // An empty part is an error (as in links), not skipped.
    let rgb = rgbOption.map { $0.split(separator: ",", omittingEmptySubsequences: false).map { int(String($0).trimmingCharacters(in: .whitespaces), "Each channel") } }
    command = .set(ScriptChange(rgbcw: rgb, temp: tempOption.map { int($0, "The kelvin") }, scale: scaleOption,
                                scene: sceneOption, customScene: customOption,
                                speed: speedOption.map { int($0, "The speed") },
                                brightness: brightnessOption.map { int($0, "The brightness") },
                                power: onFlag ? true : offFlag ? false : nil))
case "watch":
    watching = true
    command = .get
default:
    badArguments("Unknown command “\(verb)”.")
}

// More words than the command takes (`temp 2700 bulb`, meaning --scale bulb): refused, not dropped.
let maxWords: [String: Int] = [
    "get": 0, "state": 0, "on": 0, "off": 0, "toggle": 0, "watch": 0, "set": 0,
    "brightness": 1, "dim": 1, "dimming": 1, "brighter": 1, "dimmer": 1,
    "temp": 1, "temperature": 1, "kelvin": 1, "speed": 1, "list": 1,
]
if let most = maxWords[verb], rest.count > most {
    badArguments("\(verb) takes \(most == 0 ? "nothing after it" : "one value"); “\(rest[most])” isn't part of it.")
}

// An option the command doesn't use is a mistake, not something to drop without a word.
let colourVerbs: Set = ["colour", "color", "rgb", "rgbcw", "temp", "temperature", "kelvin", "scene", "custom", "custom-scene", "customscene", "set"]
let optionUse: [(String, Bool, Set<String>)] = [
    ("--on", onFlag, colourVerbs),
    ("--scale", scaleOption != nil, ["temp", "temperature", "kelvin", "set"]),
    ("--speed", speedOption != nil, ["scene", "set"]),
    ("--rgb", rgbOption != nil, ["set"]), ("--temp", tempOption != nil, ["set"]),
    ("--scene", sceneOption != nil, ["set"]), ("--custom", customOption != nil, ["set"]),
    ("--brightness", brightnessOption != nil, ["set"]),
    ("--fade", fadeOption != nil, colourVerbs.union(["on", "off", "toggle", "brightness", "dim", "dimming", "brighter", "dimmer", "preset"])),
]
for (name, given, verbs) in optionUse where given && !verbs.contains(verb) {
    badArguments("\(name) doesn't go with \(verb).")
}
// Checked before the app's reached (and perhaps launched).
let fade = fadeOption.map { int($0, "The fade") }
if let fade, !(0...86_400_000).contains(fade) { badArguments("The fade is 0–86400000 ms (a day).") }

// MARK: Talking to the app

/// The setPilot.app this tool is inside (Contents/Helpers/setpilot), following a symlink to it.
let enclosingApp: URL? = {
    // The executable's own path (argv[0] is just "setpilot" when it's found on the PATH).
    guard let me = Bundle.main.executableURL?.resolvingSymlinksInPath() else { return nil }
    let app = me.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    return app.pathExtension == "app" ? app : nil
}()

/// The App Group: the enclosing app's (so a team set only on the app target still works), else
/// this tool's own.
let appGroup: String? = {
    if let app = enclosingApp, let bundle = Bundle(url: app),
       let id = bundle.object(forInfoDictionaryKey: "SetPilotAppGroup") as? String, ScriptSocket.isTeamGroup(id) {
        return id
    }
    return ScriptSocket.appGroup
}()

func connect() -> Int32? {
    guard let path = ScriptSocket.path(for: appGroup) else { return nil }
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { return nil }
    var on: Int32 = 1
    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
    let ok = ScriptSocket.withAddress(path) { Darwin.connect(fd, $0, $1) }
    guard ok == 0 else { close(fd); return nil }
    return fd
}

/// The app's socket, launching the app (in the background, without a window) if it isn't running.
func connectToApp() -> Int32 {
    guard appGroup != nil else {
        fail(ScriptError(code: .appUnavailable, message: "This build has no App Group (it needs a development team), so the app can't be reached."))
    }
    if let fd = connect() { return fd }
    // The app this tool is inside (through a symlink on the PATH too), else the one Launch
    // Services knows; in the background, without a window.
    let open = Process()
    open.executableURL = URL(fileURLWithPath: "/usr/bin/open")
    if let app = enclosingApp {
        open.arguments = ["-g", "-j", app.path]
    } else {
        open.arguments = ["-g", "-j", "-b", "nz.aaronrumpler.setPilot"]
    }
    // Started as a login item is (the menu bar item only: no window, no Dock icon).
    open.arguments! += ["--args", "--background"]
    try? open.run()
    open.waitUntilExit()
    guard open.terminationStatus == 0 else {
        fail(ScriptError(code: .appUnavailable, message: "Couldn't open the setPilot app (is it installed?)."))
    }
    for _ in 0..<50 {
        usleep(100_000)
        if let fd = connect() { return fd }
    }
    fail(ScriptError(code: .appUnavailable, message: "Couldn't reach the setPilot app (is it installed, and built with App Groups?)."))
}

let fd = connectToApp()
if !watching {
    // A hung app doesn't hang the tool: longer than a bulb's retries (about 6 s) plus the read-back,
    // or for switching, finding a bulb known only by its MAC (which can wait on Local Network access).
    var switching = false
    if case .switchBulb = command { switching = true }
    var wait = timeval(tv_sec: switching ? 90 : 30, tv_usec: 0)
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &wait, socklen_t(MemoryLayout<timeval>.size))
}
let request = Array((encode(ScriptRequest(command: command, fade: fade, watch: watching ? true : nil, asked: started.timeIntervalSince1970)) + "\n").utf8)
// write(2) and read(2), not FileHandle: its methods raise (an abort, not an exit code) on an error.
guard request.withUnsafeBytes({ Darwin.write(fd, $0.baseAddress, $0.count) }) == request.count else {
    fail(ScriptError(code: .appUnavailable, message: "The setPilot app closed the connection."))
}

/// The app didn't answer in time (rather than closing the connection).
var timedOut = false

/// Lines from the app, as they come.
func lines(_ each: (Data) -> Bool) {
    var buffer = Data()
    var chunk = [UInt8](repeating: 0, count: 4096)
    while true {
        let n = read(fd, &chunk, chunk.count)
        if n < 0, errno == EAGAIN || errno == EWOULDBLOCK { timedOut = true }
        if n <= 0 { return } // the app closed it (or didn't answer in time)
        buffer.append(contentsOf: chunk[0..<n])
        while let nl = buffer.firstIndex(of: 0x0A) {
            let line = buffer[buffer.startIndex..<nl]
            buffer.removeSubrange(buffer.startIndex...nl)
            if !line.isEmpty, !each(Data(line)) { return }
        }
    }
}

// MARK: Output

func describe(_ s: LightState) -> String {
    let name = [s.bulb.name, s.bulb.address.map { "(\($0))" }].compactMap { $0 }.joined(separator: " ")
    guard s.link == "connected" else {
        let link = switch s.link {
        case "none": "no bulb chosen"
        case "unreachable": "not answering"
        default: s.link
        }
        return "\(name.isEmpty ? "Bulb" : name): \(link)"
    }
    guard let on = s.on else { return "\(name): state not known yet" }
    guard on else { return "\(name): off" }
    let colour = switch s.mode {
    case "temperature": "Temperature \(s.temp ?? 0) K" + (s.scale.map { " (\($0))" } ?? "")
    case "scene": "\(s.scene ?? "Scene")" + (s.speed.map { ", speed \($0)" } ?? "")
    default: "RGBCW " + (s.rgbcw ?? []).map(String.init).joined(separator: " ")
    }
    return "\(name): on, \(colour), \(s.dimming)%"
}

let decoder = JSONDecoder()
let stamp = ISO8601DateFormatter()
stamp.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

if watching {
    // Each line is the state when it changed; a closed connection (the app quit) is an error.
    lines { data in
        guard let state = try? decoder.decode(LightState.self, from: data) else { return true }
        if json {
            var object = (try? JSONSerialization.jsonObject(with: Data(encode(state).utf8))) as? [String: Any] ?? [:]
            object["t"] = stamp.string(from: Date())
            if let out = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes]) {
                print(String(decoding: out, as: UTF8.self))
            }
        } else {
            print(describe(state))
        }
        fflush(stdout)
        return true
    }
    fail(ScriptError(code: .appUnavailable, message: "The setPilot app stopped."))
}

var answer: ScriptResult?
lines { data in
    answer = try? decoder.decode(ScriptResult.self, from: data)
    return false
}
guard let result = answer else {
    if timedOut {
        // (Switching bulbs may still happen too.)
        var switching = false
        if case .switchBulb = command { switching = true }
        fail(ScriptError(code: .notAnswering, message: command.changes || switching
            ? "The setPilot app didn't answer in time (the change may still go through)."
            : "The setPilot app didn't answer in time."))
    }
    fail(ScriptError(code: .appUnavailable, message: "The setPilot app closed the connection without an answer (did it quit, or is it a different version?)."))
}
if let error = result.error { fail(error) }
if json {
    if let items = result.items { print(encode(items)) } else if let state = result.state { print(encode(state)) }
} else if let items = result.items {
    for item in items { print(item.name == item.id ? item.name : "\(item.name)\t\(item.id)") }
} else if let state = result.state {
    print(describe(state))
}
exit(0)
