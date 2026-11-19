import SwiftUI

/// A value in a list: label, value and a bar. Opens the editor.
struct ValueRow: View {
    let label: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    var step: Double = 1
    var unit = ""
    var tint: Color = .accentColor

    var body: some View {
        NavigationLink {
            ValueEditor(label: label, value: $value, range: range, step: step, unit: unit, tint: tint)
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
/// fine-tunes it a step per detent (with a haptic tick), and the keypad enters an exact number.
struct ValueEditor: View {
    let label: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    var step: Double = 1
    var unit = ""
    var tint: Color = .accentColor

    @State private var crown = 0.0
    @State private var typing = false

    var body: some View {
        VStack(spacing: 6) {
            Text(verbatim: "\(Int(value))\(unit)")
                .font(.system(size: 40, weight: .semibold, design: .rounded).monospacedDigit())
                .minimumScaleFactor(0.6)
                .lineLimit(1)
            Gauge(value: min(max(value, range.lowerBound), range.upperBound), in: range) { EmptyView() }
                .gaugeStyle(.accessoryLinearCapacity)
                .tint(tint)
            HStack {
                Button { set(Stepping.next(value, up: false, by: coarse, in: range)) } label: { Image(systemName: "minus") }
                    .accessibilityLabel("Down \(Int(coarse))")
                Button { typing = true } label: { Image(systemName: "number") }
                    .accessibilityLabel("Enter a value")
                Button { set(Stepping.next(value, up: true, by: coarse, in: range)) } label: { Image(systemName: "plus") }
                    .accessibilityLabel("Up \(Int(coarse))")
            }
            Text(verbatim: "\(Int(range.lowerBound))–\(Int(range.upperBound))\(unit)")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .focusable()
        .digitalCrownRotation($crown, from: range.lowerBound, through: range.upperBound, by: step,
                              sensitivity: .medium, isContinuous: false, isHapticFeedbackEnabled: true)
        .onChange(of: crown) { _, new in set(new) }
        .onAppear { crown = value }
        .navigationTitle(label)
        .sheet(isPresented: $typing) {
            NumberPad(title: label, range: range, unit: unit) { set($0) }
        }
        .accessibilityElement(children: .contain)
        .accessibilityValue("\(Int(value))\(unit)")
    }

    private var coarse: Double { Stepping.coarse(for: range) }

    private func set(_ v: Double) {
        let clamped = min(max(v.rounded(), range.lowerBound), range.upperBound)
        if clamped != value { value = clamped }
        if crown != clamped { crown = clamped }
    }
}

/// Enters a whole number exactly: digits, delete and OK.
struct NumberPad: View {
    let title: String
    let range: ClosedRange<Double>
    var unit = ""
    let onDone: (Double) -> Void
    @State private var text = ""
    @Environment(\.dismiss) private var dismiss

    private var number: Double? { Double(text) }
    private var valid: Bool { number.map(range.contains) ?? false }

    var body: some View {
        VStack(spacing: 4) {
            // Also a text field: tapping it opens the system's input, which offers a number pad
            // for telephone-number fields where watchOS supports one (it hasn't always worked).
            TextField(String("\(Int(range.lowerBound))–\(Int(range.upperBound))"), text: $text) // String: no "1,541"
                .textContentType(.telephoneNumber)
                .multilineTextAlignment(.center)
                .font(.title3.monospacedDigit())
                .foregroundStyle(valid || text.isEmpty ? Color.primary : Color.orange)
                .onChange(of: text) { _, new in
                    let digits = String(new.filter(\.isNumber).prefix(6))
                    if digits != new { text = digits }
                }
            Grid(horizontalSpacing: 4, verticalSpacing: 4) {
                ForEach([["1", "2", "3"], ["4", "5", "6"], ["7", "8", "9"]], id: \.self) { row in
                    GridRow { ForEach(row, id: \.self) { key($0) } }
                }
                GridRow {
                    Button { if !text.isEmpty { text.removeLast() } } label: {
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
    }

    private func key(_ digit: String) -> some View {
        Button(digit) { if text.count < 6 { text += digit } }
            .frame(maxWidth: .infinity)
            .font(.body.monospacedDigit())
    }
}
