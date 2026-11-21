import SwiftUI

extension View {
    /// A window that's as tall as its content at most and scrolls below that: it opens showing
    /// everything (the ideal), can be made shorter down to `minimum`, and no taller than the
    /// content. With `.windowResizability(.contentSize)` the window takes these as its limits.
    /// `content` is the measured content height (nil until measured: no limit yet).
    func windowHeight(content: CGFloat?, minimum: CGFloat) -> some View {
        let full = content.map { $0.rounded(.up) }
        return frame(minHeight: min(full ?? minimum, minimum), idealHeight: full, maxHeight: full ?? .infinity)
    }
}

extension View {
    /// Reports the height of a scrolling view's content (macOS 15 and later; on 14 the window just
    /// has no upper limit).
    @ViewBuilder func scrollContentHeight(_ action: @escaping (CGFloat) -> Void) -> some View {
        if #available(macOS 15.0, *) {
            onScrollGeometryChange(for: CGFloat.self) { g in
                g.contentSize.height + g.contentInsets.top + g.contentInsets.bottom
            } action: { _, height in
                action(height)
            }
        } else {
            self
        }
    }
}
