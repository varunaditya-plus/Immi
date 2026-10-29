import XCTest
@testable import ImmichApp

@MainActor
final class MemoryCalendarTests: XCTestCase {
    func testBuddhistCalendarDoesNotAddFiveHundredYearsToMemoryAge() throws {
        let stories = MemoryStory.build(from: [try memory()], limit: 10,
            now: try instant("2025-01-01T12:00:00Z"), calendar: calendar(.buddhist))

        XCTAssertEqual(stories.count, 1)
        XCTAssertEqual(stories.first?.title, "5 years ago")
    }

    func testNonGregorianMonthAndDayDoNotHideTodaysGregorianMemory() throws {
        for identifier: Calendar.Identifier in [.islamic, .hebrew] {
            let stories = MemoryStory.build(from: [try memory()], limit: 10,
                now: try instant("2025-01-01T12:00:00Z"), calendar: calendar(identifier))

            XCTAssertEqual(stories.map(\.id), ["memory"], "\(identifier)")
            XCTAssertEqual(stories.first?.title, "5 years ago", "\(identifier)")
        }
    }

    func testGregorianComparisonKeepsTheUsersLocalDayAndServerYear() throws {
        let input = try memory(serverYear: 2019)
        var userCalendar = calendar(.buddhist)
        userCalendar.timeZone = try XCTUnwrap(TimeZone(identifier: "Pacific/Honolulu"))

        let stories = MemoryStory.build(from: [input], limit: 10,
            now: try instant("2025-01-02T07:00:00Z"), calendar: userCalendar)

        XCTAssertEqual(stories.count, 1)
        XCTAssertEqual(stories.first?.title, "6 years ago")
    }

    private func calendar(_ identifier: Calendar.Identifier) -> Calendar {
        var calendar = Calendar(identifier: identifier)
        calendar.timeZone = .gmt
        return calendar
    }

    private func memory(serverYear: Int? = nil) throws -> MemoryDTO {
        MemoryDTO(id: "memory", type: "on_this_day", memoryAt: try instant("2020-01-01T00:00:00Z"),
            assets: [makeTestAsset(id: UUID().uuidString)], data: serverYear.map { MemoryDataDTO(year: $0) })
    }

    private func instant(_ value: String) throws -> Date {
        try XCTUnwrap(ISO8601DateFormatter().date(from: value))
    }
}
