import SwiftUI

/// Syntax colouring for small JSON snippets (keys, strings, numbers, literals, punctuation),
/// in the spirit of Xcode's default theme. System colours, so it adapts to dark mode.
enum JSONHighlighter {
    static func highlight(_ json: String) -> AttributedString {
        var out = AttributedString()
        let chars = Array(json)
        var i = 0

        func append(_ s: String, _ colour: Color) {
            var piece = AttributedString(s)
            piece.foregroundColor = colour
            out += piece
        }

        while i < chars.count {
            let c = chars[i]
            if c == "\"" {
                var j = i + 1
                while j < chars.count, chars[j] != "\"" { j += chars[j] == "\\" ? 2 : 1 }
                j = min(j + 1, chars.count)
                // A string followed by a colon is a key.
                var k = j
                while k < chars.count, chars[k] == " " { k += 1 }
                let isKey = k < chars.count && chars[k] == ":"
                append(String(chars[i..<j]), isKey ? Color(nsColor: .systemBlue) : Color(nsColor: .systemRed))
                i = j
            } else if c == "-" || c.isNumber {
                var j = i + 1
                while j < chars.count, chars[j].isNumber || "+-.eE".contains(chars[j]) { j += 1 }
                append(String(chars[i..<j]), Color(nsColor: .systemPurple))
                i = j
            } else if c.isLetter {
                var j = i + 1
                while j < chars.count, chars[j].isLetter { j += 1 }
                append(String(chars[i..<j]), Color(nsColor: .systemPink))
                i = j
            } else {
                var j = i + 1
                while j < chars.count, !"\"-".contains(chars[j]), !chars[j].isNumber, !chars[j].isLetter { j += 1 }
                append(String(chars[i..<j]), .secondary)
                i = j
            }
        }
        return out
    }
}
