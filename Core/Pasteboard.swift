#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// The clipboard (shared with your other devices by Universal Clipboard).
enum Pasteboard {
    @MainActor
    static func copy(_ text: String) {
        #if os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        #else
        UIPasteboard.general.string = text
        #endif
    }
}
