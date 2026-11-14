import AppKit
import SwiftUI

/// A slider that snaps to multiples of `step` when dragged, with arrow keys and with VoiceOver,
/// and draws tick marks only at `marks`.
///
/// SwiftUI can't do this on macOS: `Slider(step:)` draws a tick per step, and the macOS 26
/// `tick:`/`ticks:` APIs are ignored or drawn evenly spaced by the underlying NSSlider. NSSlider's
/// own tick marks can't be restyled either (the cell's drawTickMarks() isn't called), so this
/// uses no AppKit ticks and snaps by itself.
struct SnappingSlider: NSViewRepresentable {
    @Binding var value: Double
    let range: ClosedRange<Double>
    var step: Double = 1
    var marks: [Double] = []
    var tint: Color = .accentColor

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> SnapSlider {
        let slider = SnapSlider()
        slider.isContinuous = true
        slider.target = context.coordinator
        slider.action = #selector(Coordinator.moved(_:))
        configure(slider)
        slider.doubleValue = value
        return slider
    }

    func updateNSView(_ slider: SnapSlider, context: Context) {
        context.coordinator.parent = self
        configure(slider)
        if slider.doubleValue != value { slider.doubleValue = value }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: SnapSlider, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 200, height: nsView.intrinsicContentSize.height + (marks.isEmpty ? 0 : 6))
    }

    private func configure(_ slider: SnapSlider) {
        if slider.minValue != range.lowerBound { slider.minValue = range.lowerBound }
        if slider.maxValue != range.upperBound { slider.maxValue = range.upperBound }
        slider.step = step
        slider.trackFillColor = NSColor(tint)
        if slider.marks != marks { slider.marks = marks }
    }

    final class Coordinator: NSObject {
        var parent: SnappingSlider
        init(_ parent: SnappingSlider) { self.parent = parent }

        @objc func moved(_ sender: SnapSlider) {
            let snapped = sender.snap(sender.doubleValue)
            if sender.doubleValue != snapped { sender.doubleValue = snapped } // knob jumps between steps
            if parent.value != snapped { parent.value = snapped }
        }
    }
}

final class SnapSlider: NSSlider {
    var step: Double = 1
    var marks: [Double] = [] { didSet { marksView.needsDisplay = true } }
    private lazy var marksView: MarksView = {
        let v = MarksView()
        v.slider = self
        v.autoresizingMask = [.width, .height]
        addSubview(v)
        return v
    }()

    override func layout() {
        super.layout()
        marksView.frame = bounds
    }

    /// Nearest multiple of `step`, clamped so both ends stay reachable.
    func snap(_ v: Double) -> Double {
        guard step > 0 else { return v }
        return min(max((v / step).rounded() * step, minValue), maxValue)
    }

    private func nudge(_ steps: Double) {
        doubleValue = snap(doubleValue + steps * step)
        sendAction(action, to: target)
    }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 123, 125: nudge(-1) // ← ↓
        case 124, 126: nudge(1)  // → ↑
        case 115: doubleValue = minValue; sendAction(action, to: target) // Home
        case 119: doubleValue = maxValue; sendAction(action, to: target) // End
        default: super.keyDown(with: event)
        }
    }

    override func accessibilityPerformIncrement() -> Bool { nudge(1); return true }
    override func accessibilityPerformDecrement() -> Bool { nudge(-1); return true }

    /// x of the knob's centre at `value`, in this view's coordinates.
    func knobCentreX(at value: Double) -> CGFloat {
        let inset = (cell as? NSSliderCell)?.knobThickness ?? 20
        let usable = bounds.width - inset
        let f = maxValue > minValue ? (value - minValue) / (maxValue - minValue) : 0
        return inset / 2 + usable * CGFloat(f)
    }
}

private final class MarksView: NSView {
    weak var slider: SnapSlider?

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil } // clicks go to the slider

    override func draw(_ dirtyRect: NSRect) {
        guard let slider else { return }
        NSColor.tertiaryLabelColor.setFill()
        for mark in slider.marks where (slider.minValue...slider.maxValue).contains(mark) {
            let x = slider.knobCentreX(at: mark)
            NSBezierPath(roundedRect: NSRect(x: x - 1, y: bounds.maxY - 4, width: 2, height: 4),
                         xRadius: 1, yRadius: 1).fill()
        }
    }
}
