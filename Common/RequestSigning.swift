import CryptoKit
import Foundation

/// Signed requests, for firmware that answers with `"env": "pro"` and refuses unsigned writes. As
/// pywizlight signs them: `sigTs` (Unix seconds) is added to `params`, and the request gets
/// `"env": "pro"` and `hmac`, the Base64 HMAC-SHA256 of the compact `params` JSON keyed with the
/// home's `udp_signing_key` (hex-decoded). See docs/UDP-API.md.
enum RequestSigning {
    /// A key as typed or pasted (spaces, quotes, upper case allowed), as 32 lower-case hex digits,
    /// or nil if it isn't one.
    static func normalised(_ text: String) -> String? {
        let hex = text.lowercased().filter { !$0.isWhitespace && $0 != "\"" && $0 != "'" }
        guard hex.count == 32, hex.allSatisfy(\.isHexDigit) else { return nil }
        return hex
    }

    static func keyData(_ hex: String) -> Data? {
        guard let hex = normalised(hex) else { return nil }
        var bytes = [UInt8]()
        var i = hex.startIndex
        while i < hex.endIndex {
            let j = hex.index(i, offsetBy: 2)
            guard let b = UInt8(hex[i..<j], radix: 16) else { return nil }
            bytes.append(b)
            i = j
        }
        return Data(bytes)
    }

    private static let options: JSONSerialization.WritingOptions = [.sortedKeys, .withoutEscapingSlashes]

    /// The request as sent: signed when there's a key (32 hex digits), plain otherwise. `params`
    /// nil leaves the key out of an unsigned request (a signed one always has params, for sigTs).
    static func message(_ method: String, params: [String: Any]?, key: String?, now: Date = .now) -> Data? {
        guard let key, let secret = keyData(key) else {
            var request: [String: Any] = ["method": method]
            if let params { request["params"] = params }
            return try? JSONSerialization.data(withJSONObject: request, options: options)
        }
        var signed = params ?? [:]
        signed["sigTs"] = Int(now.timeIntervalSince1970)
        guard let body = try? JSONSerialization.data(withJSONObject: signed, options: options),
              let name = try? JSONSerialization.data(withJSONObject: method, options: [.fragmentsAllowed])
        else { return nil }
        let mac = HMAC<SHA256>.authenticationCode(for: body, using: SymmetricKey(data: secret))
        // Built by hand so the params go out byte for byte as signed.
        var out = Data(#"{"method":"#.utf8)
        out += name
        out += Data(#","env":"pro","params":"#.utf8)
        out += body
        out += Data(#","hmac":""#.utf8)
        out += Data(Data(mac).base64EncodedString().utf8)
        out += Data(#""}"#.utf8)
        return out
    }
}
