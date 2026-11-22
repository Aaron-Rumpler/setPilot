import SwiftUI

extension Model {
    /// Rounds to whole numbers and triggers a send only on user edits (not on syncs/pushes).
    func binding(_ kp: ReferenceWritableKeyPath<Model, Double>) -> Binding<Double> {
        let field: PilotField = kp == \.dimming ? .dimming : kp == \.speed ? .speed : .colour
        return Binding(
            get: { self[keyPath: kp] },
            set: {
                let v = $0.rounded()
                guard v != self[keyPath: kp] else { return } // continuous sliders move in fractions
                self.noteUndoPoint() // before the change: how it was
                self[keyPath: kp] = v
                self.changed(field)
            }
        )
    }

    var powerBinding: Binding<Bool> {
        Binding(get: { self.isOn ?? false }, set: { self.power($0) })
    }

    var linkColour: Color {
        switch link {
        case .none: .secondary.opacity(0.5)
        case .connecting: .yellow
        case .connected: .green
        case .unreachable: .red
        }
    }

    var linkText: String {
        switch link {
        case .none: "Not connected"
        case .connecting: "Connecting…"
        case .connected: "Connected" + (rssi.map { " · \($0 < 0 ? "\u{2212}" : "")\(abs($0)) dBm" } ?? "")
        case .unreachable: "No response"
        }
    }
}
