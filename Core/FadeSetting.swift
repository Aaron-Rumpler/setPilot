import SwiftUI

/// The fade time setting (`trans`), with the bulb's own defaults for reference.
struct FadeSetting: View {
    let model: Model
    /// -1 leaves it to the bulb (`Model.fade` reads the same key when sending).
    @AppStorage(Model.fadeKey) private var stored: Int = -1

    var body: some View {
        Group { rows }
            // Presets' ready-made requests for widgets (iPhone) carry the controls' fade, which may
            // be this setting: pass the change on,
            // as for a change to the presets. Nothing listens on the Mac.
            .onChange(of: stored) { model.library.onChange?() }
    }

    @ViewBuilder private var rows: some View {
        Toggle("Set the fade time", isOn: Binding(
            get: { stored >= 0 },
            set: { stored = $0 ? 500 : -1 }
        ))
        if stored >= 0 {
            LabeledContent("Fade time") {
                HStack {
                    TextField("Fade time", value: Binding(get: { stored }, set: { stored = min(max($0, 0), 60_000) }),
                              format: .number.grouping(.never))
                        .labelsHidden()
                        .multilineTextAlignment(.trailing)
                        .frame(maxWidth: 80)
                        #if os(iOS)
                        .keyboardType(.numberPad)
                        #endif
                    Text("ms").foregroundStyle(.secondary)
                    Stepper("Fade time", value: Binding(get: { stored }, set: { stored = min(max($0, 0), 60_000) }),
                            step: 100)
                        .labelsHidden()
                }
            }
        }
        LabeledContent("The bulb's own", value: bulbDefault)
    }

    private var bulbDefault: String {
        switch (model.fadeIn, model.fadeOut) {
        case let (i?, o?): "\(i) ms on, \(o) ms off"
        case let (i?, nil): "\(i) ms"
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
                TextField("Fade time", value: Binding(get: { ms }, set: { ms = min(max($0, 0), 60_000) }),
                          format: .number.grouping(.never))
                    .labelsHidden()
                    .multilineTextAlignment(.trailing)
                    .frame(width: 70)
                    #if os(iOS)
                    .keyboardType(.numberPad)
                    #endif
                Text("ms").foregroundStyle(.secondary)
            }
            #if os(macOS)
            Spacer(minLength: 0)
            #endif
        }
    }
}
