import XCTest

final class URLCommandTests: XCTestCase {
    private func command(_ s: String) -> ScriptCommand? {
        try? URLCommands.command(from: URL(string: s)!).get()
    }

    /// Sorted keys: an encoder's key order isn't fixed from one run to the next.
    private func encoded(_ c: ScriptCommand?) -> String? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return c.flatMap { try? encoder.encode($0) }.map { String(decoding: $0, as: UTF8.self) }
    }

    func testActions() {
        XCTAssertEqual(encoded(command("setpilot://power?on=toggle")), encoded(.power(nil)))
        XCTAssertEqual(encoded(command("setpilot://power?on=off")), encoded(.power(false)))
        XCTAssertEqual(encoded(command("setpilot://x-callback-url/brightness?level=40")), encoded(.brightness(40)))
        XCTAssertEqual(encoded(command("setpilot://dimmer?step=5")), encoded(.adjustBrightness(-5)))
        XCTAssertEqual(encoded(command("setpilot://scene?name=Ocean&speed=150&on=1")), encoded(.scene("Ocean", speed: 150, power: true)))
        XCTAssertEqual(encoded(command("setpilot://temperature?kelvin=2700&scale=bulb")), encoded(.temperature(2700, scale: "bulb", power: nil)))
        XCTAssertEqual(encoded(command("setpilot://colour?r=255&w=10")), encoded(.colour(r: 255, g: 0, b: 0, c: 0, w: 10, power: nil)))
    }

    func testSetAndFade() {
        let url = URL(string: "setpilot://set?scene=Warm+white&brightness=40&power=on&fade=2000")!
        XCTAssertEqual(encoded(try? URLCommands.command(from: url).get()),
                       encoded(.set(ScriptChange(scene: "Warm white", brightness: 40, power: true))))
        XCTAssertEqual(URLCommands.fade(from: url), 2000)
        XCTAssertEqual(encoded(command("setpilot://set?rgb=255,0,10")), encoded(.set(ScriptChange(rgbcw: [255, 0, 10]))))
        XCTAssertEqual(encoded(command("setpilot://list?what=presets")), encoded(.list(.presets)))
    }

    func testCallbacksRefuseFileURLs() {
        let url = URL(string: "setpilot://get?x-success=file:///Applications/Calculator.app")!
        let state = LightState(bulb: .init(name: "Desk", mac: "aabbcc000001", address: "192.168.1.2"), link: "connected", on: true, mode: "rgbcw", dimming: 50)
        XCTAssertNil(URLCommands.callback(for: url, result: ScriptResult(state: state)))
        let ok = URLCommands.callback(for: URL(string: "setpilot://get?x-success=app://ok")!, result: ScriptResult(state: state))
        XCTAssertFalse(ok?.absoluteString.contains("aabbcc000001") ?? true, "no MAC in callbacks")
        XCTAssertFalse(ok?.absoluteString.contains("192.168") ?? true, "no address in callbacks")
    }

    func testBadLinks() {
        if case .failure(let e) = URLCommands.command(from: URL(string: "setpilot://setUserConfig?x=1")!) {
            XCTAssertEqual(e.code, .badArguments)
        } else {
            XCTFail("raw methods aren't actions")
        }
        if case .success = URLCommands.command(from: URL(string: "setpilot://brightness")!) { XCTFail("needs a level") }
    }

    func testCallbacks() throws {
        let url = URL(string: "setpilot://x-callback-url/get?x-success=app://ok&x-error=app://err")!
        let state = LightState(bulb: .init(name: "Desk", mac: nil, address: nil), link: "connected", on: true, mode: "rgbcw", dimming: 50)
        let ok = try XCTUnwrap(URLCommands.callback(for: url, result: ScriptResult(state: state)))
        XCTAssertEqual(ok.host(), "ok")
        let stateJSON = try XCTUnwrap(URLComponents(url: ok, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "state" }?.value)
        XCTAssertEqual(try JSONDecoder().decode(LightState.self, from: Data(stateJSON.utf8)), state)
        let err = try XCTUnwrap(URLCommands.callback(for: url, result: ScriptResult(error: ScriptError(code: .notAnswering, message: "No"))))
        XCTAssertEqual(err.host(), "err")
        XCTAssertTrue(err.absoluteString.contains("errorCode=not-answering"))
        XCTAssertNil(URLCommands.callback(for: URL(string: "setpilot://get")!, result: ScriptResult(state: state)))
    }
}

final class ScriptProtocolTests: XCTestCase {
    func testRequestsRoundTrip() throws {
        let request = ScriptRequest(command: .temperature(3000, scale: "Warm", power: true), watch: nil)
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let data = try encoder.encode(request)
        let back = try JSONDecoder().decode(ScriptRequest.self, from: data)
        XCTAssertEqual(try encoder.encode(back), data)
    }

    func testExitCodesAreDistinct() {
        let codes: [ScriptError.Code] = [.notAnswering, .refused, .notApplied, .noBulb, .notFound, .badArguments, .appUnavailable]
        let exits = codes.map { ScriptError(code: $0, message: "").exitCode }
        XCTAssertEqual(Set(exits).count, codes.count)
        XCTAssertFalse(exits.contains(0))
        XCTAssertFalse(exits.contains(1))
    }

    func testAppGroupNeedsATeam() {
        // The test bundle has no SetPilotAppGroup key: no team, no shared container.
        XCTAssertNil(ScriptSocket.appGroup)
    }
}
