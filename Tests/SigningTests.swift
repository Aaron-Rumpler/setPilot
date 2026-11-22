import XCTest

final class SigningTests: XCTestCase {
    /// The example in docs/UDP-API.md (pywizlight's scheme): a made-up key.
    func testDocumentedExample() throws {
        let data = try XCTUnwrap(RequestSigning.message("setPilot", params: ["state": true],
                                                        key: "00112233445566778899aabbccddeeff",
                                                        now: Date(timeIntervalSince1970: 1790441723)))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(object["hmac"] as? String, "vARMv4JpVsxYabcBovABd25ISBzYT8+71v0CUtpU1sg=")
        XCTAssertEqual(object["env"] as? String, "pro")
        let text = String(decoding: data, as: UTF8.self)
        XCTAssertTrue(text.contains("\"sigTs\":1790441723}"), "sigTs goes last: \(text)")
    }

    func testUnsignedWithoutKey() throws {
        let data = try XCTUnwrap(RequestSigning.message("getPilot", params: [:], key: nil))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertNil(object["hmac"])
        XCTAssertNil(object["env"])
    }

    func testKeyNormalising() {
        XCTAssertEqual(RequestSigning.normalised(" 00112233445566778899AABBCCDDEEFF "), "00112233445566778899aabbccddeeff")
        XCTAssertNil(RequestSigning.normalised("not a key"))
        XCTAssertNil(RequestSigning.normalised("0011"))
    }
}
