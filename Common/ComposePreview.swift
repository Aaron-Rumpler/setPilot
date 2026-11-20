import Foundation

extension LightChange {
    /// Roughly what sending this will send, for Compose (custom scenes' definitions shortened).
    /// `isOn` is the bulb's power now; `channels` gives a custom CCT scale's channels at a kelvin
    /// as JSON (`"r":…,"g":…`), or nil if they aren't known here.
    func preview(isOn: Bool?, channels: (UUID, Int) -> String?) -> String {
        var parts: [String] = []
        switch colour {
        case let .rgbcw(r, g, b, c, w)?: parts.append("\"r\":\(r),\"g\":\(g),\"b\":\(b),\"c\":\(c),\"w\":\(w)")
        case let .temp(k)?: parts.append("\"temp\":\(k)")
        case let .scene(id, _)?: parts.append("\"sceneId\":\(id)")
        case .custom?: parts.append("\"sceneId\":\(Scenes.inlineCustom),\"elm\":{…}")
        case let .customCCT(id, k)?: parts.append(channels(id, k) ?? "\"r\":…,\"g\":…,\"b\":…,\"c\":…,\"w\":…")
        case nil: break
        }
        if let d = dimming { parts.append("\"dimming\":\(d)") }
        // As Model.send: a fade only goes with a change or with switching on, never alone when
        // switching off.
        if let f = fade, !parts.isEmpty || power == true { parts.append("\"trans\":\(f)") }
        if parts.isEmpty && power == true { return "setState {\"state\":true}" }
        if power == false || (power == nil && isOn == false && !parts.isEmpty) { parts.append("\"state\":false") }
        if parts.isEmpty { return "Nothing to send" }
        var text = "setPilot {" + parts.joined(separator: ",") + "}"
        switch colour {
        case let .scene(_, s?)?, let .custom(_, s?)?: text += "\nthen setPilot {\"speed\":\(s)}"
        default: break
        }
        return text
    }

    /// Something worth saying about this change before sending it, if anything.
    func note(isOn: Bool?) -> String? {
        if power == false {
            return "Turning off always uses the bulb's own fade-out. To fade out slowly, fade the brightness down instead."
        }
        if isOn == false && power == nil && (colour != nil || dimming != nil) {
            return "The bulb is off and stays off; the change shows when it's switched on."
        }
        switch colour {
        case .scene(_, _?)?, .custom(_, _?)?:
            return "The speed goes in a setPilot of its own just after: the firmware ignores it alongside anything else."
        default:
            return nil
        }
    }

    var isEmpty: Bool { colour == nil && dimming == nil && power == nil }
}
