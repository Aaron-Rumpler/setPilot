import XCTest

final class PresetUsageTests: XCTestCase {
    private let calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Pacific/Auckland")!
        return c
    }()

    private func at(_ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 11, day: day, hour: hour, minute: minute))!
    }

    func testNothingUntilThreeDays() {
        let now = at(20, 12)
        let uses = [PresetUsage.Use(key: PresetUsage.powerOff, at: at(18, 23)), .init(key: PresetUsage.powerOff, at: at(19, 23))]
        XCTAssertEqual(PresetUsage.usualness(uses, keys: nil, at: at(20, 23), now: now, calendar: calendar), 0)
    }

    func testScatteredTimesFillTheGaps() {
        // Off at 11 pm, midnight and 3 am on different nights: the hours between count too.
        let now = at(25, 12)
        let uses = [
            PresetUsage.Use(key: PresetUsage.powerOff, at: at(20, 23)),
            .init(key: PresetUsage.powerOff, at: at(22, 0)),
            .init(key: PresetUsage.powerOff, at: at(23, 3)),
        ]
        func u(_ h: Int, _ m: Int = 0) -> Double {
            PresetUsage.usualness(uses, keys: [PresetUsage.powerOff], at: at(25, h, m), now: now, calendar: calendar)
        }
        XCTAssertGreaterThan(u(1, 30), u(0) * 0.5, "between the uses")
        XCTAssertGreaterThan(u(0), u(12) * 10, "not at midday")
        XCTAssertGreaterThan(u(23, 30), u(15) * 10, "across midnight")
    }

    func testOldUsesCountLess() {
        let now = at(30, 12)
        let recent = [PresetUsage.Use(key: "a", at: at(29, 20)), .init(key: "a", at: at(28, 20)), .init(key: "a", at: at(27, 20))]
        let old = recent.map { PresetUsage.Use(key: $0.key, at: $0.at.addingTimeInterval(-60 * 86_400 + 86_400)) }
        XCTAssertGreaterThan(PresetUsage.usualness(recent, keys: nil, at: at(30, 20), now: now, calendar: calendar),
                             PresetUsage.usualness(old, keys: nil, at: at(30, 20), now: now, calendar: calendar))
    }
}
