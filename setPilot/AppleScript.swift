import AppKit

// AppleScript and JavaScript for Automation (setPilot.sdef). Each command goes through the shared
// runner (Core/Commands.swift), as Shortcuts, links and the command-line tool do, and returns the
// light state; a failure is a script error numbered 1000 plus the command-line tool's exit code
// (1004 no bulb, 1005 not found, 1006 not answering, 1007 refused, 1008 not applied, 1002 bad
// arguments), with the reason as its message.

/// The shared part: run a command asynchronously (the script waits) and hand back its result.
class SetPilotCommand: NSScriptCommand {
    /// The command to run, or nil with the error set (bad arguments).
    func command() -> ScriptCommand? { nil }

    override func performDefaultImplementation() -> Any? {
        guard let command = command() else { return nil }
        let fade = evaluatedArguments?["fade"] as? Int
        suspendExecution()
        Task { @MainActor in
            let result = await Scripting.run(command, fade: fade, on: Shared.model)
            if let error = result.error {
                scriptErrorNumber = 1000 + Int(error.exitCode)
                scriptErrorString = error.message
                resumeExecution(withResult: nil)
            } else {
                resumeExecution(withResult: result.state.map(LightStateRecord.dictionary))
            }
        }
        return nil
    }

    /// Bad arguments: say why.
    func refuse(_ message: String) -> ScriptCommand? {
        scriptErrorNumber = 1002
        scriptErrorString = message
        return nil
    }

    var text: String? { directParameter as? String }
}

@objc(SetPilotTurnOnCommand) final class TurnOnCommand: SetPilotCommand {
    override func command() -> ScriptCommand? { .power(true) }
}

@objc(SetPilotTurnOffCommand) final class TurnOffCommand: SetPilotCommand {
    override func command() -> ScriptCommand? { .power(false) }
}

@objc(SetPilotTogglePowerCommand) final class TogglePowerCommand: SetPilotCommand {
    override func command() -> ScriptCommand? { .power(nil) }
}

@objc(SetPilotApplyPresetCommand) final class ApplyPresetCommand: SetPilotCommand {
    override func command() -> ScriptCommand? {
        guard let name = text, !name.isEmpty else { return refuse("Which preset? Give its name.") }
        return .preset(name)
    }
}

@objc(SetPilotChangeBrightnessCommand) final class ChangeBrightnessCommand: SetPilotCommand {
    override func command() -> ScriptCommand? {
        guard let by = evaluatedArguments?["by"] as? Int else { return refuse("By how much? For example: change brightness by 10") }
        return .adjustBrightness(by)
    }
}

@objc(SetPilotSetLightCommand) final class SetLightCommand: SetPilotCommand {
    override func command() -> ScriptCommand? {
        let a = evaluatedArguments ?? [:]
        let change = ScriptChange(
            rgbcw: (a["rgb"] as? [Any])?.compactMap { ($0 as? NSNumber)?.intValue },
            temp: a["temperature"] as? Int, scale: a["scale"] as? String,
            scene: a["scene"] as? String, customScene: a["customScene"] as? String,
            speed: a["speed"] as? Int, brightness: a["brightness"] as? Int, power: a["power"] as? Bool)
        if change == ScriptChange() { return refuse("Nothing to set: give a colour, temperature, scene, brightness or power.") }
        return .set(change)
    }
}

@objc(SetPilotSwitchBulbCommand) final class SwitchBulbCommand: SetPilotCommand {
    override func command() -> ScriptCommand? {
        guard let bulb = text, !bulb.isEmpty else { return refuse("Which bulb? Give its name, MAC or address.") }
        return .switchBulb(bulb)
    }
}

/// The light state as the dictionary Cocoa Scripting turns into the "light state" record
/// (keys as in setPilot.sdef; missing values are left out).
enum LightStateRecord {
    static func dictionary(_ s: LightState) -> NSDictionary {
        var d: [String: Any] = ["link": s.link, "mode": s.mode, "brightness": s.dimming]
        if let v = s.bulb.name { d["bulbName"] = v }
        if let v = s.on { d["power"] = v }
        if let v = s.temp { d["temperature"] = v }
        if let v = s.scale { d["scale"] = v }
        if let v = s.scene { d["scene"] = v }
        if let v = s.speed { d["speed"] = v }
        if let v = s.rgbcw { d["rgbcw"] = v }
        return d as NSDictionary
    }
}

/// The application's properties (power, brightness, the light state, the lists).
extension AppDelegate {
    private static let scriptKeys: Set<String> = [
        "scriptPower", "scriptBrightness", "scriptLightState", "scriptPresetNames",
        "scriptCustomSceneNames", "scriptSceneNames", "scriptBulbNames",
    ]

    func application(_ sender: NSApplication, delegateHandlesKey key: String) -> Bool { Self.scriptKeys.contains(key) }

    @objc var scriptPower: Bool {
        get { readForScript("scriptPower") { NSNumber(value: $0.isOn == true) } as? Bool ?? false }
        set { runForScript(.power(newValue)) }
    }

    @objc var scriptBrightness: Int {
        get { readForScript("scriptBrightness") { NSNumber(value: Int($0.dimming)) } as? Int ?? 0 }
        set { runForScript(.brightness(newValue)) }
    }

    /// A property read by a script. Known (the bulb has answered): at once. Not yet (just
    /// launched, or not answering): the script waits while the bulb is tried (as long as the app's
    /// own read retries, Model.answerTimeout), then gets the value, or the not-answering error rather than a
    /// made-up value (`set power to not power` on a bulb not read yet would go the wrong way).
    /// `key`: the property's; read as part of something else (`properties`, which reads every
    /// property in one command that can't be suspended once per property), it's what's known now.
    private func readForScript(_ key: String, _ value: @escaping (Model) -> NSNumber) -> Any {
        let model = Shared.model
        if model.canControl { return value(model) } // answering: what it is now
        let command = NSScriptCommand.current()
        guard (command?.receiversSpecifier as? NSPropertySpecifier)?.key == key else { return value(model) }
        func fail(_ code: ScriptError.Code, _ message: String) {
            command?.scriptErrorNumber = 1000 + Int(ScriptError(code: code, message: message).exitCode)
            command?.scriptErrorString = message
        }
        // The same reasons, in the same order, as the commands (Scripting.ready).
        guard let a = UserDefaults.standard.string(forKey: Model.addressKey), !a.isEmpty else {
            fail(.noBulb, "Choose a bulb in setPilot first.")
            return NSNumber(value: 0)
        }
        command?.suspendExecution()
        Task { @MainActor in
            if await model.waitUntilControllable() {
                command?.resumeExecution(withResult: value(model))
                return
            }
            // Answering but refusing to say how it is (a wrong signing key, say): that reason.
            if !model.recentlyNotAnswering, model.link == .connected, !model.status.isEmpty {
                fail(.refused, model.status)
            } else {
                fail(.notAnswering, "The bulb isn't answering, so its state isn't known.")
            }
            command?.resumeExecution(withResult: nil)
        }
        return NSNumber(value: 0) // replaced by the result above
    }

    /// A property set by a script: the script waits for the change, and gets its failure as an
    /// error, as for the commands.
    private func runForScript(_ command: ScriptCommand) {
        let scriptCommand = NSScriptCommand.current()
        scriptCommand?.suspendExecution()
        Task { @MainActor in
            let result = await Scripting.run(command, on: Shared.model)
            if let error = result.error {
                scriptCommand?.scriptErrorNumber = 1000 + Int(error.exitCode)
                scriptCommand?.scriptErrorString = error.message
            }
            scriptCommand?.resumeExecution(withResult: nil)
        }
    }

    @objc var scriptLightState: NSDictionary { LightStateRecord.dictionary(Scripting.state(of: Shared.model)) }
    @objc var scriptPresetNames: [String] { Scripting.items(.presets, Shared.model).map(\.name) }
    @objc var scriptCustomSceneNames: [String] { Scripting.items(.customScenes, Shared.model).map(\.name) }
    @objc var scriptSceneNames: [String] { Scripting.items(.scenes, Shared.model).map(\.name) }
    @objc var scriptBulbNames: [String] { Scripting.items(.bulbs, Shared.model).map(\.name) }
}
