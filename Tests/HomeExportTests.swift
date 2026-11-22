import XCTest

/// A made-up export in the WiZ app's format (fake MACs and key).
private let sample = """
{"name":"Flat","home_id":1,"region":"eu","udp_signing_key":"00112233445566778899aabbccddeeff","version":"1.0",
 "rooms":[{"room_id":10,"name":"Lounge","type":"LIVING"},{"room_id":11,"name":"Hall","type":"CORRIDOR"}],
 "devices":[
  {"device_id":1,"type":"light","room_id":10,"name":"Lamp","mac_address":"AA:BB:CC:00:00:01"},
  {"device_id":2,"type":"light","room_id":10,"name":"Ceiling","mac_address":"aabbcc000002"},
  {"device_id":3,"type":"light","room_id":11,"name":"Ceiling","mac_address":"aabbcc000003"},
  {"device_id":4,"type":"socket","room_id":11,"name":"Plug","mac_address":"aabbcc000004"},
  {"device_id":5,"type":"light","room_id":null,"name":"Spare","mac_address":"aabbcc000005"}
 ]}
"""

final class HomeExportTests: XCTestCase {
    private func export() throws -> WiZHomeExport {
        try WiZHomeExport.parse(Data(sample.utf8)).get()
    }

    func testDefaultNames() throws {
        let plan = HomeImportPlan(try export(), naming: HomeImportNaming(), currentNames: [:], knownMACs: [])
        let names = Dictionary(uniqueKeysWithValues: plan.items.map { ($0.mac, $0.newName) })
        XCTAssertEqual(names["aabbcc000001"], "Lounge - Lamp")
        XCTAssertEqual(names["aabbcc000002"], "Lounge - Ceiling")
        XCTAssertEqual(names["aabbcc000003"], "Hall", "a room's only light is named after the room")
        XCTAssertEqual(names["aabbcc000005"], "Spare")
        XCTAssertNil(names["aabbcc000004"], "only lights")
        XCTAssertEqual(plan.key, "00112233445566778899aabbccddeeff")
        XCTAssertEqual(plan.homeName, "Flat")
    }

    func testOptions() throws {
        var naming = HomeImportNaming()
        naming.roomOnlyWhenAlone = false
        naming.prefixHome = true
        let plan = HomeImportPlan(try export(), naming: naming, currentNames: [:], knownMACs: [])
        let names = Dictionary(uniqueKeysWithValues: plan.items.map { ($0.mac, $0.newName) })
        XCTAssertEqual(names["aabbcc000003"], "Flat - Hall - Ceiling")
        XCTAssertEqual(names["aabbcc000005"], "Flat - Spare")
    }

    func testKnownFirstWithCurrentNames() throws {
        let plan = HomeImportPlan(try export(), naming: HomeImportNaming(),
                                  currentNames: ["aabbcc000005": "Desk"], knownMACs: ["aabbcc000005"])
        XCTAssertEqual(plan.items.first?.mac, "aabbcc000005")
        XCTAssertEqual(plan.items.first?.currentName, "Desk")
        XCTAssertTrue(plan.items.first?.known == true)
    }

    func testNotAnExport() {
        XCTAssertEqual(WiZHomeExport.parse(Data("{\"presets\":[]}".utf8)).failureValue, .notAnExport)
    }

    func testLoadRejectsNonLinks() async {
        let result = await HomeImportSource.load("ftp://example.com/x")
        XCTAssertEqual(result.failureValue, .notALink)
    }
}

extension Result {
    var failureValue: Failure? {
        if case .failure(let e) = self { return e }
        return nil
    }
}
