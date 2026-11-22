import XCTest

final class ColourNamesTests: XCTestCase {
    private func name(_ r: Double, _ g: Double, _ b: Double) -> String { ColourNames.name(RGB(r: r, g: g, b: b)) }

    func testHueFamilies() {
        XCTAssertEqual(name(1, 0, 0), "red")
        XCTAssertEqual(name(1, 0.5, 0), "orange")
        XCTAssertEqual(name(1, 1, 0), "yellow")
        XCTAssertEqual(name(0, 1, 0), "green")
        XCTAssertEqual(name(0, 1, 1), "cyan")
        XCTAssertEqual(name(0, 0, 1), "blue")
        XCTAssertEqual(name(0.5, 0, 1), "purple")
        XCTAssertEqual(name(1, 0, 1), "pink")
    }

    func testQualifiers() {
        XCTAssertEqual(name(0.5, 0, 0), "deep red")
        XCTAssertEqual(name(0, 0, 0.4), "deep blue")
        XCTAssertEqual(name(0.6, 0.7, 1), "pale blue")
        XCTAssertEqual(name(0.7, 1, 0.7), "pale green")
        XCTAssertEqual(name(0.5, 0.4, 0.4), "greyish red")
        XCTAssertEqual(name(1, 0.6, 0.6), "pink", "a pale red is pink")
        XCTAssertEqual(name(0.5, 0.25, 0), "brown", "a deep orange is brown")
    }

    func testWhitesAndDark() {
        XCTAssertEqual(name(0, 0, 0), "dark")
        XCTAssertEqual(name(0.05, 0.02, 0), "dark")
        XCTAssertEqual(name(1, 1, 1), "white")
        XCTAssertEqual(name(0.3, 0.3, 0.3), "grey")
        XCTAssertEqual(name(1, 0.85, 0.7), "warm white")
        XCTAssertEqual(name(0.85, 0.9, 1), "cool white")
    }

    func testOutOfRangeComponentsAreClamped() {
        XCTAssertEqual(name(2, -1, -1), "red")
        XCTAssertEqual(name(.nan, 0, 0), "dark")
    }

    func testKelvin() {
        XCTAssertEqual(ColourNames.name(kelvin: 1800), "warm orange")
        XCTAssertEqual(ColourNames.name(kelvin: 2700), "warm white")
        XCTAssertEqual(ColourNames.name(kelvin: 4200), "daylight")
        XCTAssertEqual(ColourNames.name(kelvin: 6500), "cool white")
    }

    func testLightColours() {
        XCTAssertEqual(LightColour.temp(2700).colourName, "warm white")
        XCTAssertEqual(LightColour.customCCT(scale: UUID(), kelvin: 6500).colourName, "cool white")
        XCTAssertEqual(LightColour.rgbcw(r: 0, g: 0, b: 0, c: 0, w: 0).colourName, "dark")
        XCTAssertEqual(LightColour.rgbcw(r: 0, g: 0, b: 0, c: 0, w: 255).colourName, "warm white")
        XCTAssertEqual(LightColour.rgbcw(r: 0, g: 0, b: 0, c: 255, w: 0).colourName, "cool white")
        XCTAssertEqual(LightColour.rgbcw(r: 255, g: 0, b: 0, c: 0, w: 0).colourName, "red")
        XCTAssertEqual(LightColour.rgbcw(r: 0, g: 0, b: 255, c: 0, w: 0).colourName, "blue")
        XCTAssertNil(LightColour.scene(id: 1, speed: nil).colourName)
    }
}
