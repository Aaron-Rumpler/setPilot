import AppKit
import SwiftUI

/// How values map onto the slider's track.
enum SliderScale {
    case linear
    /// Equal steps in 10⁶/value (mireds, for colour temperature) take equal distance: the usual
    /// approximation of perceptually even colour-temperature steps.
    case mired

    /// Track position (0...1) of `v`. Mired needs a positive range; otherwise it's linear.
    func position(of v: Double, in r: ClosedRange<Double>) -> Double {
        let (lo, hi) = (r.lowerBound, r.upperBound)
        guard hi > lo else { return 0 }
        switch self {
        case .mired where lo > 0: return (1 / lo - 1 / v) / (1 / lo - 1 / hi)
        default: return (v - lo) / (hi - lo)
        }
    }

    func value(at p: Double, in r: ClosedRange<Double>) -> Double {
        let (lo, hi) = (r.lowerBound, r.upperBound)
        guard hi > lo else { return lo }
        switch self {
        case .mired where lo > 0: return 1 / (1 / lo - p * (1 / lo - 1 / hi))
        default: return lo + p * (hi - lo)
        }
    }
}

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
    var scale: SliderScale = .linear
    var tint: Color = .accentColor

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> SnapSlider {
        let slider = SnapSlider()
        slider.isContinuous = true
        slider.target = context.coordinator
        slider.action = #selector(Coordinator.moved(_:))
        configure(slider)
        slider.value = value
        return slider
    }

    func updateNSView(_ slider: SnapSlider, context: Context) {
        context.coordinator.parent = self
        configure(slider)
        // Compare with a tolerance: position ↔ value round trips aren't exact for mired.
        if abs(slider.value - value) > 1e-6 { slider.value = value }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: SnapSlider, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 200, height: nsView.intrinsicContentSize.height + (marks.isEmpty ? 0 : 6))
    }

    private func configure(_ slider: SnapSlider) {
        let mappingChanged = slider.range != range || slider.scale != scale
        let current = slider.value
        slider.range = range
        slider.scale = scale
        slider.step = step
        slider.trackFillColor = NSColor(tint)
        if mappingChanged { slider.value = current } // keep the knob on the same value
        if slider.marks != marks { slider.marks = marks }
    }

    final class Coordinator: NSObject {
        var parent: SnappingSlider
        init(_ parent: SnappingSlider) { self.parent = parent }

        @objc func moved(_ sender: SnapSlider) {
            let snapped = sender.snap(sender.value)
            sender.value = snapped // knob jumps between steps
            if parent.value != snapped { parent.value = snapped }
        }
    }
}

/// NSSlider working in track positions 0...1; `value` maps through `scale` onto `range`.
final class SnapSlider: NSSlider {
    var range: ClosedRange<Double> = 0...1 { didSet { if range != oldValue { marksView.needsDisplay = true } } }
    var scale: SliderScale = .linear { didSet { if scale != oldValue { marksView.needsDisplay = true } } }
    var step: Double = 1
    var marks: [Double] = [] { didSet { marksView.needsDisplay = true } }

    private lazy var marksView: MarksView = {
        let v = MarksView()
        v.slider = self
        v.autoresizingMask = [.width, .height]
        addSubview(v)
        return v
    }()

    override init(frame: NSRect) {
        super.init(frame: frame)
        minValue = 0
        maxValue = 1
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    var value: Double {
        get { scale.value(at: doubleValue, in: range) }
        set { doubleValue = scale.position(of: min(max(newValue, range.lowerBound), range.upperBound), in: range) }
    }

    override func layout() {
        super.layout()
        marksView.frame = bounds
    }

    /// Nearest multiple of `step`, clamped so both ends stay reachable.
    func snap(_ v: Double) -> Double {
        guard step > 0 else { return v }
        return min(max((v / step).rounded() * step, range.lowerBound), range.upperBound)
    }

    private func nudge(_ steps: Double) {
        value = snap(snap(value) + steps * step)
        sendAction(action, to: target)
    }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 123, 125: nudge(-1) // ← ↓
        case 124, 126: nudge(1)  // → ↑
        case 115: value = range.lowerBound; sendAction(action, to: target) // Home
        case 119: value = range.upperBound; sendAction(action, to: target) // End
        default: super.keyDown(with: event)
        }
    }

    override func accessibilityPerformIncrement() -> Bool { nudge(1); return true }
    override func accessibilityPerformDecrement() -> Bool { nudge(-1); return true }
    override func accessibilityValue() -> Any? { NSNumber(value: value) }

    /// x of the knob's centre at `value`, in this view's coordinates.
    func knobCentreX(at value: Double) -> CGFloat {
        let inset = (cell as? NSSliderCell)?.knobThickness ?? 20
        return inset / 2 + (bounds.width - inset) * CGFloat(scale.position(of: value, in: range))
    }
}

private final class MarksView: NSView {
    weak var slider: SnapSlider?

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil } // clicks go to the slider

    override func draw(_ dirtyRect: NSRect) {
        guard let slider else { return }
        NSColor.tertiaryLabelColor.setFill()
        for mark in slider.marks where slider.range.contains(mark) {
            let x = slider.knobCentreX(at: mark)
            NSBezierPath(roundedRect: NSRect(x: x - 1, y: bounds.maxY - 4, width: 2, height: 4),
                         xRadius: 1, yRadius: 1).fill()
        }
    }
}
