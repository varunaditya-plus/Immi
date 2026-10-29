import Foundation
import XCTest

final class WidgetCalendarTests: XCTestCase {
    func testOrdinaryDayRollsOverAtLocalMidnight() throws {
        let calendar = try calendar(in: "Asia/Kolkata")
        let now = try date(2024, 12, 31, hour: 14, calendar: calendar)

        let next = try XCTUnwrap(WidgetCalendar.nextDay(after: now, calendar: calendar))

        XCTAssertEqual(next, try date(2025, 1, 1, calendar: calendar))
        XCTAssertGreaterThan(next, now)
    }

    func testSpringForwardDayHasTwentyThreeHours() throws {
        let calendar = try calendar(in: "America/Los_Angeles")
        let start = try date(2024, 3, 10, calendar: calendar)
        let now = try date(2024, 3, 10, hour: 12, calendar: calendar)

        let next = try XCTUnwrap(WidgetCalendar.nextDay(after: now, calendar: calendar))

        XCTAssertEqual(next, try date(2024, 3, 11, calendar: calendar))
        XCTAssertEqual(next.timeIntervalSince(start), 23 * 60 * 60)
    }

    func testFallBackDayHasTwentyFiveHours() throws {
        let calendar = try calendar(in: "America/Los_Angeles")
        let start = try date(2024, 11, 3, calendar: calendar)
        let now = try date(2024, 11, 3, hour: 12, calendar: calendar)

        let next = try XCTUnwrap(WidgetCalendar.nextDay(after: now, calendar: calendar))

        XCTAssertEqual(next, try date(2024, 11, 4, calendar: calendar))
        XCTAssertEqual(next.timeIntervalSince(start), 25 * 60 * 60)
    }

    func testLateFallBackEntryDoesNotScheduleARefreshInThePast() throws {
        let calendar = try calendar(in: "America/Los_Angeles")
        let now = try date(2024, 11, 3, hour: 23, minute: 30, calendar: calendar)

        let next = try XCTUnwrap(WidgetCalendar.nextDay(after: now, calendar: calendar))

        XCTAssertGreaterThan(next, now)
        XCTAssertEqual(next, try date(2024, 11, 4, calendar: calendar))
    }

    func testHalfHourClockChangesUseTheFollowingDayBoundary() throws {
        let calendar = try calendar(in: "Australia/Lord_Howe")
        for (month, day, hours) in [(4, 7, 24.5), (10, 6, 23.5)] {
            let start = try date(2024, month, day, calendar: calendar)
            let now = try date(2024, month, day, hour: 12, calendar: calendar)

            let next = try XCTUnwrap(WidgetCalendar.nextDay(after: now, calendar: calendar))

            XCTAssertEqual(next, try date(2024, month, day + 1, calendar: calendar))
            XCTAssertEqual(next.timeIntervalSince(start), hours * 60 * 60)
        }
    }

    func testNextDayCanBeginAfterAMissingMidnight() throws {
        let calendar = try calendar(in: "America/Sao_Paulo")
        let now = try date(2018, 11, 3, hour: 12, calendar: calendar)

        let next = try XCTUnwrap(WidgetCalendar.nextDay(after: now, calendar: calendar))

        XCTAssertEqual(next, try date(2018, 11, 4, hour: 1, calendar: calendar))
        XCTAssertGreaterThan(next, now)
    }

    func testNextDaySkipsADeletedCivilDate() throws {
        let calendar = try calendar(in: "Pacific/Apia")
        let now = try date(2011, 12, 29, hour: 12, calendar: calendar)

        let next = try XCTUnwrap(WidgetCalendar.nextDay(after: now, calendar: calendar))

        XCTAssertEqual(next, try date(2011, 12, 31, calendar: calendar))
        XCTAssertGreaterThan(next, now)
    }

    private func calendar(in zone: String) throws -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: zone))
        return calendar
    }

    private func date(_ year: Int, _ month: Int, _ day: Int, hour: Int = 0, minute: Int = 0,
                      calendar: Calendar) throws -> Date {
        try XCTUnwrap(calendar.date(from: DateComponents(year: year, month: month, day: day,
            hour: hour, minute: minute)))
    }
}
