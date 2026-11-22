import SwiftUI

/// A labelled slider row: − and + step to round numbers (`Stepping`), and tapping the value opens
/// a popover to type one or fine-tune it in 1s. Kelvin uses a mired scale (equal steps look
/// equally different, so warm whites get more room) with a colour-temperature strip under it.
/// Drags snap to the same round step unless that's off in Settings; touching and holding before
/// dragging moves it in 1s.
struct MobileSlider: View {
    let label: String
    var tint: Color? = nil
    let range: ClosedRange<Double>
    var mired = false
    var unit = ""
    @Binding var value: Double

    @State private var editing = false
    /// This drag started with a touch and hold: no snapping.
    @State private var fine = false
    /// The knob is being dragged (or held).
    @State private var sliding = false
    @AppStorage(Stepping.snapKey) private var snaps = true
    @Environment(\.isEnabled) private var isEnabled

    private var coarse: Double { Stepping.coarse(for: range) }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 10) {
                Text(label)
                if fine { FineBadge() }
                Spacer()
                stepButton(up: false)
                Button {
                    editing = true
                } label: {
                    Text(verbatim: "\(Int(value))\(unit)")
                        .monospacedDigit()
                        .foregroundStyle(fine ? Color.accentColor : isEnabled ? Color.primary : Color.secondary)
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
            Slider(value: position, in: 0...1, onEditingChanged: { active in
                sliding = active
                if !active { fine = false }
            })
                .modifier(FineDrag(fine: $fine, sliding: sliding))
                .tint(tint)
                .accessibilityLabel(label)
                .accessibilityValue(spokenValue)
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
        .animation(.easeOut(duration: 0.15), value: fine)
    }

    /// The value for VoiceOver; a temperature's colour in words too ("2700 K, warm white").
    private var spokenValue: String {
        guard mired else { return "\(Int(value))\(unit)" }
        return "\(Int(value)) K, \(ColourNames.name(kelvin: value))"
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
        Stepping.snap(v, to: Stepping.snapStep(for: range, snapping: snaps && !fine), in: range)
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
