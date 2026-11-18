import SwiftUI

/// The fade time setting (`trans`), with the bulb's own defaults for reference.
struct FadeSetting: View {
    let model: Model
    /// -1 leaves it to the bulb (`Model.fade` reads the same key when sending).
    @AppStorage(Model.fadeKey) private var stored: Int = -1

    var body: some View {
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
