import SwiftUI

/// A labelled slider row: − and + step to round numbers (`Stepping`), and tapping the value opens
/// a popover to type one or fine-tune it in 1s. Kelvin uses a mired scale (equal steps look
/// equally different, so warm whites get more room) with a colour-temperature strip under it,
/// and snaps to `step`.
struct MobileSlider: View {
    let label: String
    var tint: Color? = nil
    let range: ClosedRange<Double>
    var step: Double = 1
    var mired = false
    var unit = ""
    @Binding var value: Double

    @State private var editing = false
    @Environment(\.isEnabled) private var isEnabled

    private var coarse: Double { Stepping.coarse(for: range) }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 10) {
                Text(label)
                Spacer()
                stepButton(up: false)
                Button {
                    editing = true
                } label: {
                    Text(verbatim: "\(Int(value))\(unit)")
                        .monospacedDigit()
                        .foregroundStyle(isEnabled ? .primary : .secondary)
                        .frame(minWidth: 52, alignment: .trailing)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("\(label): type or fine-tune the value")
                .popover(isPresented: $editing) {
                    FineValueEditor(label: label, range: range, unit: unit, value: $value)
                        .presentationCompactAdaptation(.popover)
                }
                stepButton(up: true)
            }
            Slider(value: position, in: 0...1)
                .tint(tint)
                .accessibilityLabel(label)
                .accessibilityValue("\(Int(value))\(unit)")
                .accessibilityAdjustableAction { direction in
                    value = Stepping.next(value, up: direction == .increment, by: coarse, in: range)
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
    }

    /// − or +: to the next round number (borderless, so each button in the list row takes its own taps).
    private func stepButton(up: Bool) -> some View {
        Button {
            let v = Stepping.next(value, up: up, by: coarse, in: range)
            if v != value { value = v }
        } label: {
            Image(systemName: up ? "plus.circle" : "minus.circle")
                .font(.title3)
        }
        .buttonStyle(.borderless)
        .disabled(up ? value >= range.upperBound : value <= range.lowerBound)
        .accessibilityLabel(up ? "\(label) up \(Int(coarse))" : "\(label) down \(Int(coarse))")
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

/// The value popover: type a value, or fine-tune it in 1s with the system stepper (which
/// repeats, faster and faster, while held).
private struct FineValueEditor: View {
    let label: String
    let range: ClosedRange<Double>
    let unit: String
    @Binding var value: Double
    @State private var typed = ""
    @FocusState private var focused: Bool
    @Environment(\.dismiss) private var dismiss

    private var typedValue: Double? {
        Double(typed.trimmingCharacters(in: .whitespaces)).flatMap { range.contains($0) ? $0.rounded() : nil }
    }

    var body: some View {
        VStack(spacing: 12) {
            Text(label).font(.headline)
            HStack(spacing: 4) {
                TextField(label, text: $typed)
                    .keyboardType(.numberPad)
                    .multilineTextAlignment(.center)
                    .font(.title2.monospacedDigit())
                    .focused($focused)
                    .frame(width: 110)
                    .foregroundStyle(typedValue == nil && !typed.isEmpty ? Color.orange : Color.primary)
                if !unit.isEmpty { Text(unit.trimmingCharacters(in: .whitespaces)).foregroundStyle(.secondary) }
            }
            Stepper(label, value: Binding(get: { value }, set: { new in
                value = new
                typed = String(Int(new))
            }), in: range, step: 1)
            .labelsHidden()
            Text(verbatim: "\(Int(range.lowerBound))–\(Int(range.upperBound))\(unit)")
                .font(.caption)
                .foregroundStyle(.secondary)
            Button("Set") {
                if let v = typedValue { value = v }
                dismiss()
            }
            .buttonStyle(.borderedProminent)
            .disabled(typedValue == nil)
        }
        .padding()
        .frame(minWidth: 220)
        .onAppear { typed = String(Int(value)) }
    }
}
