import SwiftUI
#if os(macOS)
import AppKit
#endif

/// A change being prepared in Compose: any of colour, brightness and power, with its own fade
/// time, sent as one setPilot. Shared by the window and the menu bar panel, and kept while
/// switching back to the live controls.
@MainActor @Observable
final class ComposeDraft {
    enum Power: String, CaseIterable, Identifiable {
        case leave = "Leave", on = "On", off = "Off"
        var id: Self { self }
    }

    var includeColour = true
    var kind = ModeChoice.temperature
    var r = 255
    var g = 0
    var b = 0
    var c = 0
    var w = 0
    var kelvin = 2700
    /// Temperature's scale, chosen here (nil: the bulb's own): picking one mustn't change the
    /// bulb until Send.
    var scaleID: UUID?
    var scene = SceneChoice.builtin(1)
    var includeSpeed = false
    var speed = 100
    var includeDimming = true
    var dimming = 100
    var power = Power.leave
    var fadeChoice = FadeChoice.none
    var fade = 10_000
    /// Filled in from the bulb's state (once Compose is first used for this bulb, or on request).
    var loaded = false
}

extension Model {
    /// The chosen scale (while it still exists); nil for the bulb's own.
    var draftScale: CCTScale? { usableScales.first { $0.id == draft.scaleID } }

    /// Kelvin within the chosen scale, or the bulb's own range.
    var draftKelvinRange: ClosedRange<Int> {
        draftScale?.range ?? Int(tempRange.lowerBound)...Int(tempRange.upperBound)
    }

    func clampDraftKelvin() {
        let range = draftKelvinRange
        draft.kelvin = min(max(draft.kelvin, range.lowerBound), range.upperBound)
    }

    var draftChange: LightChange {
        let d = draft
        var ch = LightChange()
        if d.includeColour {
            switch d.kind {
            case .rgbcw: ch.colour = .rgbcw(r: d.r, g: d.g, b: d.b, c: d.c, w: d.w)
            case .temperature:
                // Within the range as it is now: the scale may have gone since it was chosen.
                let range = draftKelvinRange
                let kelvin = min(max(d.kelvin, range.lowerBound), range.upperBound)
                if let scale = draftScale { ch.colour = .customCCT(scale: scale.id, kelvin: kelvin) } else { ch.colour = .temp(kelvin) }
            case .scenes:
                switch d.scene {
                case .builtin(let id): ch.colour = .scene(id: id, speed: d.includeSpeed ? d.speed : nil)
                case .custom(let id): ch.colour = .custom(id, speed: d.includeSpeed ? d.speed : nil)
                }
            }
        }
        if d.includeDimming { ch.dimming = d.dimming }
        ch.power = switch d.power {
        case .leave: nil
        case .on: true
        case .off: false
        }
        ch.fade = d.fadeChoice.trans(setting: Model.fade, custom: d.fade)
        return ch
    }

    /// Something to send that the bulb would take (not all five channels at 0).
    var draftHasChange: Bool { !draftChange.isEmpty && !draftChange.allChannelsZero }

    /// Roughly what will be sent.
    var draftPreview: String {
        draftChange.preview(isOn: isOn, owedSpeed: owedSpeed) { id, k in
            library.scale(id)?.scale.channels(at: k).map { "\"r\":\($0.r),\"g\":\($0.g),\"b\":\($0.b),\"c\":\($0.c),\"w\":\($0.w)" }
        }
    }

    var draftNote: String? { draftChange.note(isOn: isOn) }

    /// Starts the draft from the bulb's current state.
    func loadDraft() {
        let d = draft
        d.loaded = true
        d.r = Int(r); d.g = Int(g); d.b = Int(b); d.c = Int(c); d.w = Int(w)
        if mode == .custom, let id = activeScale?.id {
            d.scaleID = id
            d.kelvin = Int(customKelvin)
        } else if mode.choice != .temperature, let id = scaleForTemperature {
            // Not on Temperature now: start from what choosing it would give (its CCT scale).
            d.scaleID = id
            d.kelvin = Int(customKelvin)
        } else {
            d.scaleID = nil
            d.kelvin = Int(temp)
        }
        clampDraftKelvin()
        d.dimming = Int(dimming)
        d.scene = sceneChoice.wrappedValue
        d.speed = min(max(Int(speed), 10), 200)
        d.includeSpeed = false
        // A scene that can't be sent (Rhythm, a deleted custom scene): the picker needs a choice,
        // but Colour starts off, so changing only the brightness leaves the scene playing.
        d.includeColour = currentColour != nil
        if case .builtin(let id) = d.scene, !Scenes.isKnown(id) { d.scene = .builtin(1) }
        if case .custom(let id) = d.scene, library.customScene(id) == nil { d.scene = .builtin(1) }
        d.kind = mode.choice
        d.power = .leave
        // Start from the fade time setting, if there is one.
        d.fadeChoice = Model.fade == nil ? .none : .setting
    }

    /// Sends the draft and goes back to the live controls, which then show the result. The next
    /// Compose starts from the bulb's new state.
    /// If it can't be sent (a scene or scale in it deleted meanwhile), the draft stays, and the
    /// status says why.
    func sendDraft() {
        guard send(draftChange) else { return }
        draft.loaded = false
        composing = false
    }
}

/// The Light controls' Live/Compose switch.
struct ComposeToggle: View {
    let model: Model

    var body: some View {
        Toggle(isOn: Binding(get: { model.composing }, set: { model.composing = $0 })) {
            Label("Compose", systemImage: "paperplane")
        }
        .toggleStyle(.button)
        .help("Prepare a change (colour, brightness, power) without sending it, then send it in one go with its own fade time")
    }
}

/// Compose's controls, in place of the live sliders: the same rows, but nothing is sent until
/// Send. On iPhone each is a list row.
struct ComposeControls: View {
    let model: Model
    /// Watched so the preview follows a change to the fade time setting (Model.fade isn't observed).
    @AppStorage(Model.fadeKey) private var fadeSetting = -1

    var body: some View {
        @Bindable var d = model.draft
        let _ = fadeSetting

        #if os(macOS)
        HStack(spacing: 8) {
            Text("Change").frame(width: ChannelSlider.labelWidth, alignment: .leading)
            Toggle("Colour", isOn: $d.includeColour)
            Toggle("Brightness", isOn: $d.includeDimming)
            Spacer()
        }
        .toggleStyle(.checkbox)
        #else
        Toggle("Change Colour", isOn: $d.includeColour)
        #endif

        if d.includeColour { colourRows }

        #if os(iOS)
        Toggle("Change Brightness", isOn: $d.includeDimming)
        #endif
        if d.includeDimming {
            IntSliderRow(label: "Brightness", value: $d.dimming, range: Int(model.minDimming)...100, unit: "%")
        }

        HStack(spacing: 8) {
            #if os(macOS)
            Text("Power").frame(width: ChannelSlider.labelWidth, alignment: .leading)
            #else
            Text("Power")
            Spacer()
            #endif
            Picker("Power", selection: $d.power) {
                ForEach(ComposeDraft.Power.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            #if os(macOS)
            Spacer()
            #endif
        }
        FadeRow(choice: $d.fadeChoice, ms: $d.fade)

        VStack(alignment: .leading, spacing: 6) {
            Text(model.draftPreview)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let note = model.draftNote {
                Text(note)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }

        HStack {
            Button("From Bulb") { model.loadDraft() }
                .help("Start again from the bulb's current state")
            Spacer()
            Button {
                #if os(macOS)
                // A click doesn't end a number field's editing either (see ⌘Return below).
                NSApp.keyWindow?.makeFirstResponder(nil)
                DispatchQueue.main.async {
                    if model.canControl, model.draftHasChange { model.sendDraft() }
                }
                #else
                model.sendDraft()
                #endif
            } label: {
                Label("Send", systemImage: "paperplane.fill")
            }
            .buttonStyle(.borderedProminent)
            .disabled(!model.canControl || !model.draftHasChange)
            #if os(macOS)
            .help("Send this change (⌘Return)")
            .background {
                // ⌘Return, apart from the button: a number being typed only reaches the draft
                // when its field ends editing, which a shortcut doesn't do, and until then the
                // button may still be disabled. So end it, then send what the draft has become.
                Button("Send") {
                    NSApp.keyWindow?.makeFirstResponder(nil)
                    DispatchQueue.main.async {
                        if model.canControl, model.draftHasChange { model.sendDraft() }
                    }
                }
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(!model.canControl)
                .opacity(0)
                .frame(width: 0, height: 0)
                .accessibilityHidden(true)
            }
            #endif
        }
        #if os(iOS)
        .buttonStyle(.borderless)
        #endif
    }

    @ViewBuilder private var colourRows: some View {
        @Bindable var d = model.draft
        switch d.kind {
        case .rgbcw:
            IntSliderRow(label: "Red", value: $d.r, range: 0...255, tint: .red)
            IntSliderRow(label: "Green", value: $d.g, range: 0...255, tint: .green)
            IntSliderRow(label: "Blue", value: $d.b, range: 0...255, tint: .blue)
            IntSliderRow(label: "Cool white", value: $d.c, range: 0...255, tint: ColourTemperature.color(kelvin: 6500))
            IntSliderRow(label: "Warm white", value: $d.w, range: 0...255, tint: ColourTemperature.color(kelvin: 2700))
        case .temperature:
            row("CCT Scale") {
                Picker("CCT Scale", selection: Binding(get: { model.draftScale?.id }, set: { id in
                    d.scaleID = id
                    model.clampDraftKelvin()
                })) {
                    Text("Bulb's own").tag(UUID?.none)
                    let scales = model.usableScales
                    if !scales.isEmpty {
                        Divider()
                        ForEach(scales) { Text($0.name).tag(Optional($0.id)) }
                    }
                }
            }
            IntSliderRow(label: "Temperature", value: $d.kelvin, range: model.draftKelvinRange, kelvin: true,
                         tint: ColourTemperature.color(kelvin: Double(d.kelvin)))
        case .scenes:
            row("Scene") {
                Picker("Scene", selection: $d.scene) {
                    ForEach(Scenes.all) { Text($0.name).tag(SceneChoice.builtin($0.id)) }
                    if !model.library.customScenes.isEmpty {
                        Divider()
                        ForEach(model.library.customScenes) { Text($0.name).tag(SceneChoice.custom($0.id)) }
                    }
                }
            }
            #if os(macOS)
            HStack(spacing: 8) {
                Color.clear.frame(width: ChannelSlider.labelWidth, height: 1)
                Toggle("Change speed", isOn: $d.includeSpeed).toggleStyle(.checkbox)
                Spacer()
            }
            #else
            Toggle("Change Speed", isOn: $d.includeSpeed)
            #endif
            if d.includeSpeed { IntSliderRow(label: "Speed", value: $d.speed, range: 10...200) }
        }
    }

    /// A picker row: labelled like the sliders on the Mac, a plain picker on iPhone.
    @ViewBuilder private func row<Content: View>(_ label: String, @ViewBuilder _ content: () -> Content) -> some View {
        #if os(macOS)
        HStack(spacing: 8) {
            Text(label).frame(width: ChannelSlider.labelWidth, alignment: .leading)
            content().labelsHidden().fixedSize()
            Spacer()
        }
        #else
        content()
        #endif
    }
}

// MARK: Handoff

extension ComposeDraft {
    /// The draft, for Handoff to another device (the main controls' activity carries it).
    var handoffInfo: [String: Any] {
        var d: [String: Any] = [
            "includeColour": includeColour, "kind": kind.rawValue, "rgbcw": [r, g, b, c, w], "kelvin": kelvin,
            "includeSpeed": includeSpeed, "speed": speed, "includeDimming": includeDimming, "dimming": dimming,
            "power": power.rawValue, "fadeChoice": fadeChoice.rawValue, "fade": fade,
        ]
        if let scaleID { d["scaleID"] = scaleID.uuidString }
        switch scene {
        case .builtin(let id): d["scene"] = id
        case .custom(let id): d["customScene"] = id.uuidString
        }
        return d
    }

    /// Takes a draft handed off from another device.
    func take(_ d: [String: Any]) {
        includeColour = d["includeColour"] as? Bool ?? includeColour
        kind = (d["kind"] as? String).flatMap(ModeChoice.init(rawValue:)) ?? kind
        if let ch = d["rgbcw"] as? [Int], ch.count == 5 { (r, g, b, c, w) = (ch[0], ch[1], ch[2], ch[3], ch[4]) }
        kelvin = d["kelvin"] as? Int ?? kelvin
        scaleID = (d["scaleID"] as? String).flatMap(UUID.init(uuidString:))
        if let id = (d["customScene"] as? String).flatMap(UUID.init(uuidString:)) {
            scene = .custom(id)
        } else if let id = d["scene"] as? Int {
            scene = .builtin(id)
        }
        includeSpeed = d["includeSpeed"] as? Bool ?? includeSpeed
        speed = d["speed"] as? Int ?? speed
        includeDimming = d["includeDimming"] as? Bool ?? includeDimming
        dimming = d["dimming"] as? Int ?? dimming
        power = (d["power"] as? String).flatMap(Power.init(rawValue:)) ?? power
        fadeChoice = (d["fadeChoice"] as? String).flatMap(FadeChoice.init(rawValue:)) ?? fadeChoice
        fade = d["fade"] as? Int ?? fade
        loaded = true
    }
}
