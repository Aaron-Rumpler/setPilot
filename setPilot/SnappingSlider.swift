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
/// and draws tick marks only at `marks`. Optionally shows a colour-temperature strip under the
/// track (values in kelvin).
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
    var colourTemperatureStrip = false
    /// Track fill colour; nil for the system default.
    var tint: Color? = nil

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> SnapSliderContainer {
        let container = SnapSliderContainer()
        let slider = container.slider
        slider.isContinuous = true
        slider.target = context.coordinator
        slider.action = #selector(Coordinator.moved(_:))
        configure(container)
        slider.value = value
        return container
    }

    func updateNSView(_ container: SnapSliderContainer, context: Context) {
        context.coordinator.parent = self
        configure(container)
        let slider = container.slider
        // Compare with a tolerance: position ↔ value round trips aren't exact for mired.
        if abs(slider.value - value) > 1e-6 { slider.value = value }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: SnapSliderContainer, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 200, height: nsView.intrinsicContentSize.height)
    }

    private func configure(_ container: SnapSliderContainer) {
        let slider = container.slider
        let mappingChanged = slider.range != range || slider.scale != scale
        let current = slider.value
        slider.range = range
        slider.scale = scale
        slider.step = step
        slider.trackFillColor = tint.map { NSColor($0) }
        if mappingChanged { slider.value = current } // keep the knob on the same value
        if container.marks != marks { container.marks = marks }
        if container.colourTemperatureStrip != colourTemperatureStrip {
            container.colourTemperatureStrip = colourTemperatureStrip
        }
        container.needsDisplay = true // range or scale may have moved the marks
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
    var range: ClosedRange<Double> = 0...1
    var scale: SliderScale = .linear
    var step: Double = 1

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

/// The slider at its natural height, with the optional colour-temperature strip and marks drawn
/// in their own space below it. (NSSlider centres its track in a taller frame, so drawing them
/// inside the slider would collide with the knob.)
final class SnapSliderContainer: NSView {
    let slider = SnapSlider()
    var marks: [Double] = [] { didSet { invalidateIntrinsicContentSize() } }
    var colourTemperatureStrip = false { didSet { invalidateIntrinsicContentSize() } }

    private static let stripSpace: CGFloat = 7 // 3 gap + 4 strip
    private static let marksSpace: CGFloat = 6 // 2 gap + 4 mark

    override init(frame: NSRect) {
        super.init(frame: frame)
        addSubview(slider)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var isFlipped: Bool { true }

    private var sliderHeight: CGFloat { max(slider.intrinsicContentSize.height, 16) }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric,
               height: sliderHeight + (colourTemperatureStrip ? Self.stripSpace : 0) + (marks.isEmpty ? 0 : Self.marksSpace))
    }

    override func layout() {
        super.layout()
        slider.frame = NSRect(x: 0, y: 0, width: bounds.width, height: sliderHeight)
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        var y = slider.frame.maxY

        if colourTemperatureStrip {
            // Sample along the track (not in kelvin) so colours line up with the knob on any scale.
            let samples = 48
            var colours: [NSColor] = []
            var locations: [CGFloat] = [] // passed as a C array to NSGradient
            for i in 0...samples {
                let p = Double(i) / Double(samples)
                colours.append(ColourTemperature.colour(kelvin: slider.scale.value(at: p, in: slider.range)))
                locations.append(CGFloat(p))
            }
            let x0 = slider.knobCentreX(at: slider.range.lowerBound)
            let x1 = slider.knobCentreX(at: slider.range.upperBound)
            let bar = NSRect(x: x0 - 2, y: y + 3, width: x1 - x0 + 4, height: 4)
            let path = NSBezierPath(roundedRect: bar, xRadius: 2, yRadius: 2)
            NSGradient(colors: colours, atLocations: locations, colorSpace: .sRGB)?.draw(in: path, angle: 0)
            NSColor.separatorColor.setStroke() // keeps the near-white cool end visible
            path.lineWidth = 0.5
            path.stroke()
            y += Self.stripSpace
        }

        NSColor.tertiaryLabelColor.setFill()
        for mark in marks where slider.range.contains(mark) {
            let x = slider.knobCentreX(at: mark)
            NSBezierPath(roundedRect: NSRect(x: x - 1, y: y + 2, width: 2, height: 4), xRadius: 1, yRadius: 1).fill()
        }
    }
}
