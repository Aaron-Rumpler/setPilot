import AppKit
import SwiftUI

extension View {
    /// A window that's as tall as its content at most and scrolls below that: it opens showing
    /// everything (the ideal), can be made shorter down to `minimum`, and no taller than the
    /// content. With `.windowResizability(.contentSize)` the window takes these as its limits.
    /// `content` is the measured content height (nil until measured: no limit yet).
    ///
    /// The window shrinks with the content by itself (its limit comes down), but doesn't grow
    /// back: so if it was showing everything, it's made taller to keep doing so.
    func windowHeight(content: CGFloat?, minimum: CGFloat) -> some View {
        let full = content.map { $0.rounded(.up) }
        return frame(minHeight: min(full ?? minimum, minimum), idealHeight: full, maxHeight: full ?? .infinity)
            .modifier(GrowsWithContent(content: full))
    }
}

private struct GrowsWithContent: ViewModifier {
    let content: CGFloat?
    /// The height the window gives the view now.
    @State private var shown: CGFloat = 0
    @State private var window = WindowBox()

    func body(content view: Content) -> some View {
        view
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { shown = $0 }
            .background(WindowReader(box: window))
            .onChange(of: content) { old, new in
                guard let old, let new, new > old, shown >= old - 1, let w = window.window else { return }
                var frame = w.frame
                // Downwards (the title bar stays put), as far as the screen allows.
                let room = frame.minY - (w.screen?.visibleFrame.minY ?? -.infinity)
                let grow = min(new - old, room)
                guard grow > 0 else { return }
                frame.origin.y -= grow
                frame.size.height += grow
                w.setFrame(frame, display: true)
            }
    }
}

/// The window a view is in, found without changing any state.
private final class WindowBox {
    weak var window: NSWindow?
}

private struct WindowReader: NSViewRepresentable {
    let box: WindowBox

    func makeNSView(context: Context) -> NSView {
        let view = ReaderView()
        view.box = box
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {}

    private final class ReaderView: NSView {
        var box: WindowBox?
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            box?.window = window
        }
    }
}

extension View {
    /// Reports the height of a scrolling view's content (macOS 15 and later). On 14 it can't be
    /// measured, so the view is as tall as it wants to be instead, as before it could scroll.
    @ViewBuilder func scrollContentHeight(_ action: @escaping (CGFloat) -> Void) -> some View {
        if #available(macOS 15.0, *) {
            onScrollGeometryChange(for: CGFloat.self) { g in
                g.contentSize.height + g.contentInsets.top + g.contentInsets.bottom
            } action: { _, height in
                action(height)
            }
        } else {
            fixedSize(horizontal: false, vertical: true)
        }
    }
}
