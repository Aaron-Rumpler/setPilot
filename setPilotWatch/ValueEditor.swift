import SwiftUI

/// A value in a list: label, value and a bar. Opens the editor.
struct ValueRow: View {
    let label: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    var unit = ""
    var tint: Color = .accentColor

    var body: some View {
        NavigationLink {
            ValueEditor(label: label, value: $value, range: range, unit: unit, tint: tint)
        } label: {
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(label)
                    Spacer()
                    Text(verbatim: "\(Int(value))\(unit)").monospacedDigit().foregroundStyle(.secondary)
                }
                Gauge(value: min(max(value, range.lowerBound), range.upperBound), in: range) { EmptyView() }
                    .gaugeStyle(.accessoryLinearCapacity)
                    .tint(tint)
                    .accessibilityHidden(true)
            }
        }
    }
}

/// One value, full screen: − and + go to the next round number (`Stepping`), the Digital Crown
/// moves it by the same step per detent (with a haptic tick; in 1s with snapping off on the
/// iPhone), and tapping the value opens the keypad, which fine-tunes in 1s.
struct ValueEditor: View {
    let label: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    var unit = ""
    var tint: Color = .accentColor

    @State private var crown = 0.0
    @State private var typing = false

    var body: some View {
        VStack(spacing: 6) {
            Button { typing = true } label: {
                Text(verbatim: "\(Int(value))\(unit)")
                    .font(.system(size: 40, weight: .semibold, design: .rounded).monospacedDigit())
                    .minimumScaleFactor(0.6)
                    .lineLimit(1)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(Int(value))\(unit): enter or fine-tune the value")
            Gauge(value: min(max(value, range.lowerBound), range.upperBound), in: range) { EmptyView() }
                .gaugeStyle(.accessoryLinearCapacity)
                .tint(tint)
            HStack {
                Button { set(Stepping.next(value, up: false, by: coarse, in: range)) } label: { Image(systemName: "minus") }
                    .accessibilityLabel("Down \(Int(coarse))")
                Button { set(Stepping.next(value, up: true, by: coarse, in: range)) } label: { Image(systemName: "plus") }
                    .accessibilityLabel("Up \(Int(coarse))")
            }
            Text(verbatim: "\(Int(range.lowerBound))–\(Int(range.upperBound))\(unit)")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .focusable()
        .digitalCrownRotation($crown, from: range.lowerBound, through: range.upperBound, by: snapStep,
                              sensitivity: .medium, isContinuous: false, isHapticFeedbackEnabled: true)
        .onChange(of: crown) { _, new in
            // Not when the Crown is just being lined up with the value (opening the editor, or
            // after − and +): only a turn changes it, or a value off the round steps would be
            // snapped, and sent, without being touched.
            guard new != value else { return }
            set(Stepping.snap(new, to: snapStep, in: range))
        }
        .onAppear { crown = value }
        // A change from elsewhere (the iPhone, the bulb) while this is open: the Crown carries on
        // from the new value, not from where it was.
        .onChange(of: value) { _, new in if crown != new { crown = new } }
        .navigationTitle(label)
        .sheet(isPresented: $typing) {
            NumberPad(title: label, range: range, unit: unit, initial: value) { set($0) }
        }
        .accessibilityElement(children: .contain)
        .accessibilityValue("\(Int(value))\(unit)")
    }

    private var coarse: Double { Stepping.coarse(for: range) }
    /// The Crown snaps to the round step, unless snapping is off on the iPhone.
    private var snapStep: Double {
        Stepping.snapStep(for: range, snapping: PhoneLink.shared.snapshot?.snapSliders ?? true)
    }

    private func set(_ v: Double) {
        let clamped = min(max(v.rounded(), range.lowerBound), range.upperBound)
        if clamped != value { value = clamped }
        if crown != clamped { crown = clamped }
    }
}

/// Enters a whole number exactly: digits, delete and OK, starting from the current value (the
/// first digit typed replaces it). − and + and the Crown fine-tune it: by 10 for temperatures and
/// times (the button under the value switches to 1s), by 1 otherwise.
struct NumberPad: View {
    let title: String
    let range: ClosedRange<Double>
    var unit = ""
    var initial: Double? = nil
    let onDone: (Double) -> Void
    @State private var text = ""
    /// The next digit replaces the text (it's the value it started from, or one stepped to).
    @State private var replace = true
    @State private var crown = 0.0
    /// Steps of 1 rather than the in-between step (where there is one).
    @State private var ones = false
    @Environment(\.dismiss) private var dismiss

    private var medium: Double? { Stepping.medium(for: range) }
    private var stepSize: Double { ones ? 1 : medium ?? 1 }

    private var number: Double? { Double(text) }
    private var valid: Bool { number.map(range.contains) ?? false }

    var body: some View {
        VStack(spacing: 4) {
            // Also a text field: tapping it opens the system's input, which offers a number pad
            // for telephone-number fields where watchOS supports one (it hasn't always worked).
            HStack(spacing: 4) {
                Button { step(-stepSize) } label: { Image(systemName: "minus") }
                    .buttonStyle(.bordered)
                    .frame(width: 34)
                    .accessibilityLabel("Down \(Int(stepSize))")
                TextField(String("\(Int(range.lowerBound))–\(Int(range.upperBound))"), text: $text) // String: no "1,541"
                    .textContentType(.telephoneNumber)
                    .multilineTextAlignment(.center)
                    .font(.title3.monospacedDigit())
                    .foregroundStyle(valid || text.isEmpty ? Color.primary : Color.orange)
                    .onChange(of: text) { _, new in
                        let digits = String(new.filter(\.isNumber).prefix(6))
                        if digits != new { text = digits }
                    }
                Button { step(stepSize) } label: { Image(systemName: "plus") }
                    .buttonStyle(.bordered)
                    .frame(width: 34)
                    .accessibilityLabel("Up \(Int(stepSize))")
            }
            if let medium {
                Button {
                    ones.toggle()
                } label: {
                    Text(verbatim: ones ? "Steps of 1 · tap for \(Int(medium))" : "Steps of \(Int(medium)) · tap for 1")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            Grid(horizontalSpacing: 4, verticalSpacing: 4) {
                ForEach([["1", "2", "3"], ["4", "5", "6"], ["7", "8", "9"]], id: \.self) { row in
                    GridRow { ForEach(row, id: \.self) { key($0) } }
                }
                GridRow {
                    Button {
                        if !text.isEmpty { text.removeLast() }
                        replace = false
                    } label: {
                        Image(systemName: "delete.left").frame(maxWidth: .infinity)
                    }
                    .accessibilityLabel("Delete")
                    key("0")
                    Button {
                        if let number, valid {
                            onDone(number)
                            dismiss()
                        }
                    } label: {
                        Image(systemName: "checkmark").frame(maxWidth: .infinity)
                    }
                    .tint(.green)
                    .disabled(!valid)
                    .accessibilityLabel("Done")
                }
            }
            .buttonStyle(.bordered)
        }
        .navigationTitle(title)
        .focusable()
        .digitalCrownRotation($crown, from: range.lowerBound, through: range.upperBound, by: stepSize,
                              sensitivity: .low, isContinuous: false, isHapticFeedbackEnabled: true)
        .onChange(of: crown) { _, new in
            let v = Int(min(max(new.rounded(), range.lowerBound), range.upperBound))
            if text != String(v) {
                text = String(v)
                replace = true
            }
        }
        .onAppear {
            if let initial {
                text = String(Int(initial))
                crown = initial
            }
        }
    }

    /// − and +: by `delta` from what's shown (or the bottom of the range).
    private func step(_ delta: Double) {
        let v = min(max((number ?? range.lowerBound) + delta, range.lowerBound), range.upperBound)
        text = String(Int(v))
        crown = v
        replace = true
    }

    private func key(_ digit: String) -> some View {
        Button(digit) {
            if replace {
                text = digit
                replace = false
            } else if text.count < 6 {
                text += digit
            }
        }
        .frame(maxWidth: .infinity)
        .font(.body.monospacedDigit())
    }
}
