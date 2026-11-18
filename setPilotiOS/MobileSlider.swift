import SwiftUI

/// A labelled slider row: the value shows on the right, and tapping it lets you type one.
/// Kelvin uses a mired scale (equal steps look equally different, so warm whites get more room)
/// with a colour-temperature strip under it, and snaps to `step`.
struct MobileSlider: View {
    let label: String
    var tint: Color? = nil
    let range: ClosedRange<Double>
    var step: Double = 1
    var mired = false
    var unit = ""
    @Binding var value: Double

    @State private var editing = false
    @State private var typed = ""
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(label)
                Spacer()
                Button {
                    typed = String(Int(value))
                    editing = true
                } label: {
                    Text(verbatim: "\(Int(value))\(unit)")
                        .monospacedDigit()
                        .foregroundStyle(isEnabled ? .primary : .secondary)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Type a value for \(label)")
            }
            Slider(value: position, in: 0...1)
                .tint(tint)
                .accessibilityLabel(label)
                .accessibilityValue("\(Int(value))\(unit)")
                .accessibilityAdjustableAction { direction in
                    let delta = step * (step == 1 ? 5 : 1)
                    value = clamp(direction == .increment ? value + delta : value - delta)
                }
            if mired {
                LinearGradient(stops: stripStops, startPoint: .leading, endPoint: .trailing)
                    .frame(height: 6)
                    .clipShape(Capsule())
                    .opacity(isEnabled ? 1 : 0.4)
                    .accessibilityHidden(true)
            }
        }
        .padding(.vertical, 2)
        .alert(label, isPresented: $editing) {
            TextField(label, text: $typed).keyboardType(.numberPad)
            Button("Set") {
                if let v = Double(typed.trimmingCharacters(in: .whitespaces)) { value = clamp(v) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("\(Int(range.lowerBound))–\(Int(range.upperBound))\(unit)")
        }
    }

    /// The slider works in 0…1; this maps it to the value (linearly, or in mireds).
    private var position: Binding<Double> {
        Binding(
            get: { fraction(of: value) },
            set: { value = clamp(self.value(at: $0)) }
        )
    }

    private func clamp(_ v: Double) -> Double {
        let snapped = (v / step).rounded() * step
        return min(max(snapped, range.lowerBound), range.upperBound)
    }

    private func value(at t: Double) -> Double {
        guard mired, range.lowerBound > 0 else { return range.lowerBound + t * (range.upperBound - range.lowerBound) }
        let lo = 1e6 / range.lowerBound, hi = 1e6 / range.upperBound
        return 1e6 / (lo + t * (hi - lo))
    }

    private func fraction(of v: Double) -> Double {
        guard range.upperBound > range.lowerBound else { return 0 }
        guard mired, range.lowerBound > 0 else { return (v - range.lowerBound) / (range.upperBound - range.lowerBound) }
        let lo = 1e6 / range.lowerBound, hi = 1e6 / range.upperBound
        return (1e6 / max(v, 1) - lo) / (hi - lo)
    }

    private var stripStops: [Gradient.Stop] {
        (0...12).map { i in
            let t = Double(i) / 12
            return .init(color: ColourTemperature.color(kelvin: value(at: t)), location: t)
        }
    }
}
