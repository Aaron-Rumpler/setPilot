import SwiftUI

/// Syntax colouring for JSON (keys, strings, numbers, literals, punctuation), in the spirit of
/// Xcode's default theme. System colours, so it adapts to dark mode. Tolerant: it colours text
/// that isn't valid JSON (yet) as best it can, for editors.
enum JSONHighlighter {
    enum Kind { case key, string, number, literal, punctuation }

    /// The colour runs of `json`, as UTF-16 offsets (so they map straight onto NSRange). Works on
    /// UTF-16 code units: everything JSON gives meaning to is ASCII; anything else is inside a string.
    static func tokens(_ json: String) -> [(range: Range<Int>, kind: Kind)] {
        let u = Array(json.utf16)
        func isDigit(_ c: UInt16) -> Bool { c >= 48 && c <= 57 }
        func isLetter(_ c: UInt16) -> Bool { (c >= 65 && c <= 90) || (c >= 97 && c <= 122) }
        let quote: UInt16 = 34, backslash: UInt16 = 92, minus: UInt16 = 45
        let numberChars: Set<UInt16> = [43, 45, 46, 69, 101] // + - . E e
        var out: [(Range<Int>, Kind)] = []
        var i = 0
        while i < u.count {
            let c = u[i]
            if c == quote {
                var j = i + 1
                while j < u.count, u[j] != quote { j += u[j] == backslash ? 2 : 1 }
                j = min(j + 1, u.count)
                // A string followed by a colon is a key.
                var k = j
                while k < u.count, u[k] == 32 || u[k] == 9 || u[k] == 10 || u[k] == 13 { k += 1 }
                out.append((i..<j, k < u.count && u[k] == 58 ? .key : .string))
                i = j
            } else if c == minus || isDigit(c) {
                var j = i + 1
                while j < u.count, isDigit(u[j]) || numberChars.contains(u[j]) { j += 1 }
                out.append((i..<j, .number))
                i = j
            } else if isLetter(c) {
                var j = i + 1
                while j < u.count, isLetter(u[j]) { j += 1 }
                out.append((i..<j, .literal))
                i = j
            } else {
                var j = i + 1
                while j < u.count, u[j] != quote, u[j] != minus, !isDigit(u[j]), !isLetter(u[j]) { j += 1 }
                out.append((i..<j, .punctuation))
                i = j
            }
        }
        return out
    }

    static func color(_ kind: Kind) -> Color {
        switch kind {
        case .key: .blue
        case .string: .red
        case .number: .purple
        case .literal: .pink
        case .punctuation: .secondary
        }
    }

    static func highlight(_ json: String) -> AttributedString {
        var out = AttributedString()
        for (range, kind) in tokens(json) {
            let lo = String.Index(utf16Offset: range.lowerBound, in: json)
            let hi = String.Index(utf16Offset: range.upperBound, in: json)
            var piece = AttributedString(String(json[lo..<hi]))
            piece.foregroundColor = color(kind)
            out += piece
        }
        return out
    }
}

/// JSON to text, for showing replies and requests.
enum JSONText {
    static func pretty(_ value: Any) -> String {
        string(value, [.prettyPrinted, .sortedKeys, .fragmentsAllowed, .withoutEscapingSlashes])
    }

    static func compact(_ value: Any) -> String {
        string(value, [.sortedKeys, .fragmentsAllowed, .withoutEscapingSlashes])
    }

    private static func string(_ value: Any, _ options: JSONSerialization.WritingOptions) -> String {
        guard JSONSerialization.isValidJSONObject([value]),
              let data = try? JSONSerialization.data(withJSONObject: value, options: options)
        else { return "\(value)" }
        return String(decoding: data, as: UTF8.self)
    }

    /// Parses params typed in the console: an object, or nothing (meaning `{}`). The error says
    /// what's wrong in a line.
    static func parseParams(_ text: String) -> Result<[String: Any], ParamsError> {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return .success([:]) }
        do {
            let value = try JSONSerialization.jsonObject(with: Data(trimmed.utf8), options: [.fragmentsAllowed])
            guard let object = value as? [String: Any] else { return .failure(ParamsError(message: "Params must be a JSON object: { … }")) }
            return .success(object)
        } catch {
            let detail = (error as NSError).userInfo[NSDebugDescriptionErrorKey] as? String
            return .failure(ParamsError(message: detail ?? "Not valid JSON"))
        }
    }

    struct ParamsError: Error { let message: String }
}
