import SwiftUI

/// The fade time setting (`trans`), with the bulb's own defaults for reference.
struct FadeSetting: View {
    let model: Model
    /// -1 leaves it to the bulb (`Model.fade` reads the same key when sending).
    @AppStorage(Model.fadeKey) private var stored: Int = -1

    var body: some View {
        // The controls' fade may be this setting, and on iPhone the widgets' ready-made preset
        // requests and the watch carry it: pass the change on, as for a change to the presets.
        // (On the rows' first, not a Group, which would give each row its own and pass it on twice.)
        rows
    }

    @ViewBuilder private var rows: some View {
        Toggle("Set the fade time", isOn: Binding(
            get: { stored >= 0 },
            set: { stored = $0 ? 500 : -1 }
        ))
        .onChange(of: stored) { model.library.onChange?() }
        if stored >= 0 {
            LabeledContent("Fade time") {
                HStack {
                    MillisecondsField(value: $stored)
                        .frame(maxWidth: 80)
                    Text("ms").foregroundStyle(.secondary)
                    Stepper("Fade time", value: Binding(get: { stored }, set: { stored = min(max($0, 0), 60_000) }),
                            in: 0...60_000, step: 100) // the range disables − and + at the ends
                        .labelsHidden()
                }
            }
        }
        LabeledContent("The bulb's own", value: bulbDefault)
    }

    private var bulbDefault: String {
        switch (model.fadeIn, model.fadeOut) {
        case let (i?, o?): "\(i) ms on, \(o) ms off"
        case let (i?, nil): "\(i) ms on"
        case let (nil, o?): "\(o) ms off"
        default: model.link == .connected ? "Not reported" : "—"
        }
    }
}

/// The main controls' fade, under Dimming: the fade time setting, none, or a value just for them
/// (as Compose has for one change).
struct ControlsFadeRow: View {
    let model: Model

    var body: some View {
        FadeRow(choice: Binding(get: { model.controlsFade }, set: { model.controlsFade = $0 }),
                ms: Binding(get: { model.controlsFadeMs }, set: { model.controlsFadeMs = $0 }))
            .help("The fade (trans) for changes made with these controls")
    }
}

/// A fade choice with its time when it's Custom, as one row.
struct FadeRow: View {
    @Binding var choice: FadeChoice
    @Binding var ms: Int
    /// The fade time setting (-1 for none), observed so the choices follow it when it changes.
    @AppStorage(Model.fadeKey) private var stored: Int = -1

    private var setting: Int? { stored >= 0 ? stored : nil }

    /// "The setting" isn't offered while there's no fade time setting; it then means none.
    private var shown: Binding<FadeChoice> {
        Binding(get: { choice == .setting && setting == nil ? .none : choice }, set: { choice = $0 })
    }

    var body: some View {
        HStack(spacing: 8) {
            #if os(macOS)
            Text("Fade").frame(width: ChannelSlider.labelWidth, alignment: .leading)
            #endif
            Picker("Fade", selection: shown) {
                ForEach(FadeChoice.options(setting: setting), id: \.self) {
                    Text($0.title(setting: setting)).tag($0)
                }
            }
            #if os(macOS)
            .labelsHidden()
            .fixedSize()
            #endif
            if shown.wrappedValue == .custom {
                MillisecondsField(value: $ms)
                    .frame(width: 70)
                Text("ms").foregroundStyle(.secondary)
            }
            #if os(macOS)
            Spacer(minLength: 0)
            #endif
        }
    }
}

/// A time in ms (0 to `maximum`), taken as it's typed: a `value:` field only takes it when editing
/// ends, which on iPhone (a number pad has no Return) is only once focus moves, so a slider moved
/// or Send tapped straight after would use the old one.
struct MillisecondsField: View {
    var label = "Fade time"
    @Binding var value: Int
    var maximum = 60_000
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        TextField(label, text: $text)
            .focused($focused)
            .labelsHidden()
            .multilineTextAlignment(.trailing)
            #if os(iOS)
            .keyboardType(.numberPad)
            // The number pad has no Return (the value's taken as it's typed; this puts it away).
            .toolbar {
                if focused {
                    ToolbarItemGroup(placement: .keyboard) {
                        Spacer()
                        Button("Done") { focused = false }
                    }
                }
            }
            #endif
            .onAppear { text = String(value) }
            .onChange(of: text) { _, new in
                let digits = new.filter { $0.isASCII && $0.isNumber } // what Int() can read
                if digits != new { text = digits; return }
                if let n = Int(digits.prefix(6)) {
                    let clamped = min(max(n, 0), maximum)
                    if clamped != value { value = clamped }
                    // Over the limit (or too long): show what's used.
                    if String(clamped) != digits { text = String(clamped) }
                }
            }
            // Emptied and left: show the value that's still in use, rather than a blank.
            .onChange(of: focused) { _, now in if !now, text.isEmpty { text = String(value) } }
            // Changed elsewhere (the stepper, the watch): show it, unless it's what's typed.
            .onChange(of: value) { _, new in if Int(text) != new { text = String(new) } }
    }
}
