import XCTest

/// The Mac app's screens, driven as a person would. No bulb is needed: these check the windows,
/// menus and settings come up and hold together.
final class SetPilotUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() {
        continueAfterFailure = false
        app = XCUIApplication()
        // A fresh start each time, not the windows left open last time.
        app.launchArguments += ["-ApplePersistenceIgnoreState", "YES"]
        app.launch()
    }

    override func tearDown() {
        app.terminate()
    }

    func testMainWindowAndLightMenu() {
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 15), "The main window didn't open")
        let light = app.menuBars.menuBarItems["Light"]
        XCTAssertTrue(light.exists, "No Light menu")
        light.click()
        XCTAssertTrue(app.menuItems["Undo Light Change"].exists)
        app.typeKey(.escape, modifierFlags: [])
    }

    func testSettingsOpens() {
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 15))
        app.typeKey(",", modifierFlags: .command)
        XCTAssertTrue(app.staticTexts["iCloud sync"].waitForExistence(timeout: 10), "Settings didn't show its Sync section")
        XCTAssertTrue(app.buttons["Export Diagnostics…"].exists)
    }

    func testOtherWindowsOpen() {
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 15))
        app.typeKey("l", modifierFlags: [.command, .option])
        XCTAssertTrue(app.windows["Light Show"].waitForExistence(timeout: 10), "The Light Show window didn't open")
        app.typeKey("k", modifierFlags: [.command, .option])
        XCTAssertTrue(app.windows["Console"].waitForExistence(timeout: 10), "The console didn't open")
    }
}
