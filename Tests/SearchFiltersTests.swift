import Foundation
import XCTest
@testable import ImmichApp

final class SearchFiltersTests: XCTestCase {
    func testDayBoundsFollowCalendarDaysAcrossBothDaylightSavingTransitions() throws {
        let calendar = try calendar("America/New_York")
        for (month, day, hours) in [(3, 10, 23.0), (11, 3, 25.0)] {
            let date = try XCTUnwrap(calendar.date(from: DateComponents(year: 2024, month: month, day: day, hour: 12)))
            let bounds = SearchDateRange.day(date).bounds(calendar: calendar)
            let end = try XCTUnwrap(bounds.to)
            XCTAssertEqual(end.timeIntervalSince(bounds.from), hours * 3600, accuracy: 0.001)
            XCTAssertEqual(calendar.component(.hour, from: bounds.from), 0)
            XCTAssertEqual(calendar.component(.hour, from: end), 0)
            XCTAssertEqual(calendar.component(.day, from: end), day + 1)
        }
    }

    func testLeapMonthYearAndCustomRangesUseAnExclusiveFollowingCalendarBoundary() throws {
        let calendar = try calendar("UTC")
        let leap = SearchDateRange.month(year: 2024, month: 2).bounds(calendar: calendar)
        XCTAssertEqual(try XCTUnwrap(leap.to).timeIntervalSince(leap.from), 29 * 86400)
        let year = SearchDateRange.year(2024).bounds(calendar: calendar)
        XCTAssertEqual(try XCTUnwrap(year.to).timeIntervalSince(year.from), 366 * 86400)
        let start = try XCTUnwrap(calendar.date(from: DateComponents(year: 2024, month: 2, day: 28, hour: 18)))
        let end = try XCTUnwrap(calendar.date(from: DateComponents(year: 2024, month: 2, day: 29, hour: 6)))
        let custom = SearchDateRange.custom(from: start, to: end).bounds(calendar: calendar)
        XCTAssertEqual(calendar.dateComponents([.year, .month, .day, .hour], from: custom.from), DateComponents(year: 2024, month: 2, day: 28, hour: 0))
        XCTAssertEqual(calendar.dateComponents([.year, .month, .day, .hour], from: try XCTUnwrap(custom.to)), DateComponents(year: 2024, month: 3, day: 1, hour: 0))
    }

    func testRequestsKeepAnExactLocalExclusiveBoundaryWithoutEncodingItAsAnUnsupportedServerField() throws {
        let calendar = try calendar("America/New_York")
        let date = try XCTUnwrap(calendar.date(from: DateComponents(year: 2024, month: 3, day: 10, hour: 12)))
        var request = SearchRequestDTO()
        SearchFilters(dateRange: .day(date)).apply(to: &request, calendar: calendar)
        let expectedEnd = try XCTUnwrap(calendar.date(from: DateComponents(year: 2024, month: 3, day: 11)))
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        XCTAssertEqual(formatter.date(from: try XCTUnwrap(request.takenBefore)), expectedEnd)
        XCTAssertEqual(request.exclusiveTakenBefore, request.takenBefore)
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(request)) as? [String: Any])
        XCTAssertEqual(body["takenBefore"] as? String, request.takenBefore)
        XCTAssertNil(body["exclusiveTakenBefore"], "The private half-open constraint is enforced by the complete search adapter")
    }

    func testEveryIndependentFilterIsEncodedAndRemovingThemClearsAReusedRequest() throws {
        let person = makePeopleStatePerson("maya", name: "Maya")
        let album = AlbumResponseDTO(id: "travel", albumName: "Travel", description: nil, assetCount: 0,
            albumThumbnailAssetId: nil, shared: false, createdAt: .distantPast, assets: nil)
        let filters = SearchFilters(people: [person], city: "Paris", state: "Ile-de-France", country: "France",
            album: album, dateRange: .year(2024), mediaType: .live)
        var request = SearchRequestDTO()
        filters.apply(to: &request)
        XCTAssertEqual(request.personIds, [person.id])
        XCTAssertEqual(request.albumIds, [album.id])
        XCTAssertEqual(request.city, "Paris")
        XCTAssertEqual(request.state, "Ile-de-France")
        XCTAssertEqual(request.country, "France")
        XCTAssertEqual(request.type, "IMAGE")
        XCTAssertEqual(request.isMotion, true)
        XCTAssertNotNil(request.takenAfter)
        XCTAssertNotNil(request.exclusiveTakenBefore)

        SearchFilters().apply(to: &request)

        XCTAssertNil(request.personIds)
        XCTAssertNil(request.albumIds)
        XCTAssertNil(request.city)
        XCTAssertNil(request.state)
        XCTAssertNil(request.country)
        XCTAssertNil(request.type)
        XCTAssertNil(request.isMotion)
        XCTAssertNil(request.takenAfter)
        XCTAssertNil(request.takenBefore)
        XCTAssertNil(request.exclusiveTakenBefore)
    }

    func testRelativeDateBoundsAdvanceWhenTheSameFilterIsUsedOnALaterDay() throws {
        let calendar = try calendar("UTC")
        let first = try XCTUnwrap(calendar.date(from: DateComponents(year: 2024, month: 5, day: 15)))
        let later = try XCTUnwrap(calendar.date(byAdding: .day, value: 1, to: first))
        let a = SearchDateRange.lastMonth.bounds(now: first, calendar: calendar)
        let b = SearchDateRange.lastMonth.bounds(now: later, calendar: calendar)
        XCTAssertEqual(b.from.timeIntervalSince(a.from), 86400)
        XCTAssertNil(a.to)
        XCTAssertNil(b.to)
    }

    private func calendar(_ zone: String) throws -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: zone))
        return calendar
    }
}
