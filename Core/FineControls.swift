#if os(iOS)
import SwiftUI

/// The value popover on iPhone: type a value on the number pad, or fine-tune it with − and + in
/// 1s (the system stepper, which repeats faster and faster while held), and for temperatures and
/// times ±10 as well. Nothing here snaps.
struct FineValueEditor: View {
    let label: String
    let range: ClosedRange<Double>
    let unit: String
    @Binding var value: Double
    @State private var typed = ""
    @Environment(\.dismiss) private var dismiss
    /// The field's width, growing with the text size.
    @ScaledMetric(relativeTo: .title2) private var fieldWidth: CGFloat = 110

    private var typedValue: Double? {
        Double(typed.trimmingCharacters(in: .whitespaces)).flatMap { range.contains($0) ? $0.rounded() : nil }
    }

    var body: some View {
        VStack(spacing: 12) {
            Text(label).font(.headline)
            HStack(spacing: 4) {
                TextField(label, text: $typed)
                    // The number pad has no minus key.
                    .keyboardType(range.lowerBound < 0 ? .numbersAndPunctuation : .numberPad)
                    .multilineTextAlignment(.center)
                    .font(.title2.monospacedDigit())
                    .frame(width: fieldWidth)
                    .foregroundStyle(typedValue == nil && !typed.isEmpty ? Color.orange : Color.primary)
                if !unit.isEmpty { Text(unit.trimmingCharacters(in: .whitespaces)).foregroundStyle(.secondary) }
            }
            HStack(spacing: 12) {
                if let m = Stepping.medium(for: range) {
                    Button { adjust(-m) } label: { Text(verbatim: "−\(Int(m))").monospacedDigit() }
                        .buttonStyle(.bordered)
                        .accessibilityLabel("\(label) down \(Int(m))")
                }
                // From what's typed, if it's a value: tapping + after typing carries on from it.
                Stepper(label, value: Binding(get: { typedValue ?? value }, set: { set($0) }), in: range, step: 1)
                    .labelsHidden()
                if let m = Stepping.medium(for: range) {
                    Button { adjust(m) } label: { Text(verbatim: "+\(Int(m))").monospacedDigit() }
                        .buttonStyle(.bordered)
                        .accessibilityLabel("\(label) up \(Int(m))")
                }
            }
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
        .frame(minWidth: 240)
        .onAppear { typed = String(Int(value)) }
    }

    private func adjust(_ delta: Double) { set(min(max((typedValue ?? value) + delta, range.lowerBound), range.upperBound)) }

    private func set(_ v: Double) {
        value = v
        typed = String(Int(v))
    }
}

/// Shown by a slider's label while a fine drag moves it in 1s.
struct FineBadge: View {
    var body: some View {
        Text(verbatim: "1s")
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(Color.accentColor.opacity(0.18), in: Capsule())
            .foregroundStyle(Color.accentColor)
            .transition(.opacity)
            .accessibilityLabel("Moving in steps of 1")
    }
}

/// Touch and hold a slider for a moment before dragging, and that drag moves in 1s instead of
/// snapping (iPhone's stand-in for Option on the Mac); a haptic tick says it's on. `fine` is set
/// here and should be cleared when the drag ends (the slider's onEditingChanged). Only while
/// the knob is held (`sliding`, from onEditingChanged): a hold on the track, or one that turns
/// into a scroll, starts no drag, so nothing would end it.
struct FineDrag: ViewModifier {
    @Binding var fine: Bool
    let sliding: Bool

    func body(content: Content) -> some View {
        content
            .simultaneousGesture(LongPressGesture(minimumDuration: 0.35).onEnded { _ in if sliding { fine = true } })
            .sensoryFeedback(.selection, trigger: fine) { _, now in now }
    }
}
#endif
