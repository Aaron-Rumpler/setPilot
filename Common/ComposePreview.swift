import Foundation

extension LightChange {
    /// Roughly what sending this will send, for Compose (custom scenes' definitions shortened).
    /// `isOn` is the bulb's power now; `channels` gives a custom CCT scale's channels at a kelvin
    /// as JSON (`"r":…,"g":…`), or nil if they aren't known here.
    /// `owedSpeed`: a scene speed changed while the bulb was off, which goes with switching it on
    /// (Model's `owedSpeed`).
    func preview(isOn: Bool?, owedSpeed: Int? = nil, channels: (UUID, Int) -> String?) -> String {
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
        // As Model.send: a fade goes with a change or with switching (on or off), never alone.
        if let f = fade, !parts.isEmpty || power != nil { parts.append("\"trans\":\(f)") }
        if power == true { parts.append("\"state\":true") }
        if power == false || (power == nil && isOn == false && !parts.isEmpty) { parts.append("\"state\":false") }
        if parts.isEmpty { return "Nothing to send" }
        var text = "setPilot {" + parts.joined(separator: ",") + "}"
        // As Model.send: no speed while it's (to be) off, as on its own it would switch it on.
        let off = power == false || (power == nil && isOn == false)
        switch colour {
        case let .scene(_, s?)?, let .custom(_, s?)?: if !off { text += "\nthen setPilot {\"speed\":\(s)}" }
        case nil:
            // At the same moment when only switching on; after the change otherwise.
            if !off, let s = owedSpeed { text += "\n\(dimming == nil ? "and" : "then") setPilot {\"speed\":\(s)}" }
        default: break
        }
        return text
    }

    /// Something worth saying about this change before sending it, if anything.
    /// RGBCW with every channel at 0, which the bulb refuses.
    var allChannelsZero: Bool {
        if case .rgbcw(0, 0, 0, 0, 0)? = colour { return true }
        return false
    }

    func note(isOn: Bool?) -> String? {
        if allChannelsZero { return "The bulb refuses all five channels at 0: raise at least one to send this." }
        if power == false, fade != nil {
            return "The bulb may ignore the fade when switching off and use its own fade-out. To fade out slowly, fade the brightness down instead."
        }
        if isOn == false && power == nil && (colour != nil || dimming != nil) {
            return "The bulb is off and stays off; the change shows when it's switched on."
        }
        switch colour {
        case .scene(_, _?)? where power != false, .custom(_, _?)? where power != false:
            // (Not when it's to be off: no speed is sent then.)
            return "The speed goes in a setPilot of its own just after: the firmware ignores it alongside anything else."
        default:
            return nil
        }
    }

    var isEmpty: Bool { colour == nil && dimming == nil && power == nil }
}
