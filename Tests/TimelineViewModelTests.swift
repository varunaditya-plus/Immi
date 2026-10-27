import XCTest
@testable import ImmichApp

/// Linimasa kini dibangun dari cache lokal, bukan dari `/timeline/buckets`.
/// Yang diuji karena itu bukan lagi jalur jaringannya, melainkan pengelompokan
/// per bulan dan penyusunan ulang setelah ada aset yang dibuang.
@MainActor
final class TimelineViewModelTests: XCTestCase {
    var viewModel: TimelineViewModel!

    override func setUp() async throws {
        try await super.setUp()
        viewModel = TimelineViewModel()
    }

    override func tearDown() async throws {
        viewModel = nil
        try await super.tearDown()
    }

    func testInitialState() {
        XCTAssertTrue(viewModel.sections.isEmpty)
        if case .idle = viewModel.phase {} else {
            XCTFail("Expected idle phase")
        }
    }

    /// Tanpa `SwiftDataManager`, tidak ada apa pun yang bisa dibaca — dan itu
    /// bukan kegagalan, hanya perpustakaan yang belum tersinkron.
    func testLoadWithoutStoreLeavesEmptyTimeline() async {
        await viewModel.loadTimeline()

        XCTAssertTrue(viewModel.sections.isEmpty)
        if case .loaded = viewModel.phase {} else {
            XCTFail("Expected loaded phase")
        }
    }

    func testSetFavoritePatchesInPlace() async {
        viewModel.sections = [
            TimelineSection(
                id: "2024-08",
                title: "August 2024",
                assets: [
                    makeAsset("a"),
                    makeAsset("b"),
                ],
                count: 2,
                startIndex: 0),
        ]

        viewModel.setFavorite("b", to: true)

        XCTAssertFalse(viewModel.sections[0].assets[0].isFavorite)
        XCTAssertTrue(viewModel.sections[0].assets[1].isFavorite)
    }

    /// Section yang kehilangan seluruh isinya ikut hilang, dan offset section
    /// berikutnya dirapatkan — offset itu dipakai sebagai identitas sel di grid,
    /// jadi lubang di tengahnya akan menabrakkan identitas.
    func testRemovingAssetsCompactsSections() async {
        viewModel.sections = [
            TimelineSection(
                id: "2024-08", title: "August 2024",
                assets: [makeAsset("a")], count: 1, startIndex: 0),
            TimelineSection(
                id: "2024-07", title: "July 2024",
                assets: [makeAsset("b"), makeAsset("c")], count: 2, startIndex: 1),
        ]

        viewModel.assetWasRemoved("a")

        XCTAssertEqual(viewModel.sections.count, 1)
        XCTAssertEqual(viewModel.sections[0].id, "2024-07")
        XCTAssertEqual(viewModel.sections[0].startIndex, 0)
        XCTAssertEqual(viewModel.sections[0].count, 2)
    }

    func testFormatBucketTitle() {
        XCTAssertEqual(TimelineViewModel.formatBucketTitle("2024-08"), "August 2024")
        // Kunci yang tidak bisa diurai dikembalikan apa adanya, bukan jadi teks
        // kosong yang menyesatkan.
        XCTAssertEqual(TimelineViewModel.formatBucketTitle("not-a-month"), "not-a-month")
    }

    func testMonthNavigationTargetsFirstAssetInEveryMonth() {
        viewModel.sections = [
            TimelineSection(
                id: "2024-12", title: "December 2024",
                assets: [makeAsset("dec-first"), makeAsset("dec-last")],
                count: 2, startIndex: 0),
            TimelineSection(
                id: "2025-01", title: "January 2025",
                assets: [makeAsset("jan-first")],
                count: 1, startIndex: 2),
        ]

        XCTAssertEqual(viewModel.monthNavigationItems.map(\.id), ["2024-12", "2025-01"])
        XCTAssertEqual(
            viewModel.monthNavigationItems.map(\.targetAssetID),
            ["dec-first", "jan-first"])
    }

    func testYearNavigationCollapsesMonthsAndTargetsFirstAssetOfYear() {
        viewModel.sections = [
            TimelineSection(
                id: "2024-12", title: "December 2024",
                assets: [makeAsset("2024-first")], count: 1, startIndex: 0),
            TimelineSection(
                id: "2025-01", title: "January 2025",
                assets: [makeAsset("2025-first")], count: 1, startIndex: 1),
            TimelineSection(
                id: "2025-06", title: "June 2025",
                assets: [makeAsset("2025-later")], count: 1, startIndex: 2),
        ]

        XCTAssertEqual(viewModel.yearNavigationItems.map(\.id), ["2024", "2025"])
        XCTAssertEqual(
            viewModel.yearNavigationItems.map(\.targetAssetID),
            ["2024-first", "2025-first"])
    }

    func testMonthHighlightsChooseThreeBusiestDatesInChronologicalOrder() {
        useCalendar(timeZone: "UTC")
        let counts = [1, 5, 2, 4, 3]
        let assets = counts.enumerated().flatMap { offset, count in
            (0..<count).map { index in
                makeAsset(
                    "day-\(offset + 1)-\(index)",
                    createdAt: "2026-09-0\(offset + 1)T12:00:00Z")
            }
        }
        viewModel.sections = [makeSection(assets: assets)]

        let highlights = viewModel.monthNavigationItems[0].highlights
        XCTAssertEqual(highlights.map(\.title), ["2", "4", "5"])
        XCTAssertEqual(highlights.map(\.count), [5, 4, 3])
        XCTAssertEqual(highlights.map(\.id), ["2026-09-02", "2026-09-04", "2026-09-05"])
        XCTAssertEqual(highlights.map(\.targetAssetID), ["day-2-0", "day-4-0", "day-5-0"])
    }

    func testMonthHighlightRankingTiesChooseEarlierDatesRegardlessOfAssetOrder() {
        useCalendar(timeZone: "UTC")
        let assets = (1...4).reversed().map { day in
            makeAsset("day-\(day)", createdAt: "2026-09-0\(day)T12:00:00Z")
        }
        viewModel.sections = [makeSection(assets: assets)]

        XCTAssertEqual(
            viewModel.monthNavigationItems[0].highlights.map(\.title),
            ["1", "2", "3"])
    }

    func testMonthHighlightsUseLocalMidnightForDayBoundaries() {
        useCalendar(timeZone: "Asia/Jakarta")
        viewModel.sections = [makeSection(assets: [
            makeAsset("before-midnight", createdAt: "2026-09-01T16:59:59Z"),
            makeAsset("midnight", createdAt: "2026-09-01T17:00:00Z"),
            makeAsset("morning", createdAt: "2026-09-02T01:00:00Z"),
        ])]

        let highlights = viewModel.monthNavigationItems[0].highlights
        XCTAssertEqual(highlights.map(\.title), ["1", "2"])
        XCTAssertEqual(highlights.map(\.count), [1, 2])
        XCTAssertEqual(
            highlights[1].date,
            ISO8601DateFormatter().date(from: "2026-09-01T17:00:00Z"))
    }

    func testNonGregorianPreferenceKeepsGregorianDaysAndLocalTimeZone() {
        var calendar = Calendar(identifier: .islamicUmmAlQura)
        calendar.locale = Locale(identifier: "ar_SA")
        calendar.timeZone = TimeZone(identifier: "Asia/Jakarta")!
        viewModel = TimelineViewModel(calendar: calendar)
        viewModel.sections = [makeSection(assets: [
            makeAsset("before-midnight", createdAt: "2026-09-01T16:59:59Z"),
            makeAsset("midnight", createdAt: "2026-09-01T17:00:00Z"),
            makeAsset("end-of-month", createdAt: "2026-09-30T12:00:00Z"),
        ])]

        let highlights = viewModel.monthNavigationItems[0].highlights
        XCTAssertEqual(highlights.map(\.title), ["1", "2", "30"])
        XCTAssertEqual(highlights.map(\.id), ["2026-09-01", "2026-09-02", "2026-09-30"])
        XCTAssertEqual(Set(highlights.map(\.id)).count, highlights.count)
        XCTAssertEqual(
            highlights[1].date,
            ISO8601DateFormatter().date(from: "2026-09-01T17:00:00Z"))
    }

    func testMonthHighlightPrefersStillPhotoAndStableCoverForEqualTimestamps() {
        useCalendar(timeZone: "UTC")
        viewModel.sections = [makeSection(assets: [
            makeAsset("video", createdAt: "2026-09-01T09:00:00Z", isVideo: true),
            makeAsset("photo-z", createdAt: "2026-09-01T10:00:00Z"),
            makeAsset("photo-a", createdAt: "2026-09-01T10:00:00Z"),
            makeAsset("later-photo", createdAt: "2026-09-01T11:00:00Z"),
            makeAsset("only-video", createdAt: "2026-09-02T09:00:00Z", isVideo: true),
        ])]

        let highlights = viewModel.monthNavigationItems[0].highlights
        XCTAssertEqual(highlights.map(\.targetAssetID), ["photo-a", "only-video"])
        XCTAssertEqual(highlights.map(\.count), [4, 1])
    }

    func testHighlightLimitAppliesSeparatelyToEachMonthAndSkipsEmptySections() {
        useCalendar(timeZone: "UTC")
        let september = (1...4).map {
            makeAsset("sep-\($0)", createdAt: "2026-09-0\($0)T12:00:00Z")
        }
        let october = (1...4).map {
            makeAsset("oct-\($0)", createdAt: "2026-10-0\($0)T12:00:00Z")
        }
        viewModel.sections = [
            makeSection(id: "2026-08", assets: []),
            makeSection(assets: september),
            makeSection(id: "2026-10", assets: october),
        ]

        XCTAssertEqual(viewModel.monthNavigationItems.map(\.id), ["2026-09", "2026-10"])
        XCTAssertEqual(viewModel.monthNavigationItems.map { $0.highlights.count }, [3, 3])
        XCTAssertEqual(viewModel.yearNavigationItems.map(\.id), ["2026"])

        viewModel.sections = []
        XCTAssertTrue(viewModel.monthNavigationItems.isEmpty)
        XCTAssertTrue(viewModel.yearNavigationItems.isEmpty)
    }

    func testRemovingHighlightCoverUpdatesCoverCountAndCachedNavigators() {
        useCalendar(timeZone: "UTC")
        viewModel.sections = [makeSection(assets: [
            makeAsset("first", createdAt: "2026-09-01T10:00:00Z"),
            makeAsset("second", createdAt: "2026-09-01T11:00:00Z"),
        ])]

        viewModel.assetWasRemoved("first")

        let highlights = viewModel.monthNavigationItems[0].highlights
        XCTAssertEqual(highlights.map(\.targetAssetID), ["second"])
        XCTAssertEqual(highlights.map(\.count), [1])
        XCTAssertEqual(viewModel.yearNavigationItems[0].targetAssetID, "second")

        viewModel.setFavorite("second", to: true)
        XCTAssertTrue(viewModel.monthNavigationItems[0].highlights[0].cover.isFavorite)
    }

    func testRemovingMonthPreservesOtherHighlightsAndUpdatesYearCover() {
        useCalendar(timeZone: "UTC")
        viewModel.sections = [
            makeSection(id: "2025-12", assets: [
                makeAsset("previous-year", createdAt: "2025-12-01T12:00:00Z"),
            ]),
            makeSection(assets: [
                makeAsset("september", createdAt: "2026-09-01T12:00:00Z"),
            ]),
            makeSection(id: "2026-10", assets: [
                makeAsset("october-first", createdAt: "2026-10-01T12:00:00Z"),
                makeAsset("october-second", createdAt: "2026-10-02T12:00:00Z"),
            ]),
        ]
        let octoberHighlights = viewModel.monthNavigationItems[2].highlights

        viewModel.assetWasRemoved("september")

        XCTAssertEqual(viewModel.monthNavigationItems.map(\.id), ["2025-12", "2026-10"])
        XCTAssertEqual(viewModel.monthNavigationItems[1].highlights, octoberHighlights)
        XCTAssertEqual(
            viewModel.yearNavigationItems.map(\.targetAssetID),
            ["previous-year", "october-first"])
        XCTAssertEqual(viewModel.sections.map(\.startIndex), [0, 1])

        viewModel.assetWasRemoved("previous-year")
        XCTAssertEqual(viewModel.yearNavigationItems.map(\.id), ["2026"])
        XCTAssertEqual(viewModel.monthNavigationItems[0].highlights, octoberHighlights)

        viewModel.assetWasRemoved("october-first")
        viewModel.assetWasRemoved("october-second")
        XCTAssertTrue(viewModel.sections.isEmpty)
        XCTAssertTrue(viewModel.monthNavigationItems.isEmpty)
        XCTAssertTrue(viewModel.yearNavigationItems.isEmpty)
    }

    private func useCalendar(timeZone: String) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: timeZone)!
        viewModel = TimelineViewModel(calendar: calendar)
    }

    private func makeSection(id: String = "2026-09", assets: [AssetLite]) -> TimelineSection {
        TimelineSection(id: id, title: id, assets: assets, count: assets.count)
    }

    private func makeAsset(
        _ id: String,
        createdAt: String? = nil,
        isVideo: Bool = false
    ) -> AssetLite {
        AssetLite(
            id: id,
            isVideo: isVideo,
            ratio: 1,
            thumbhash: nil,
            createdAt: createdAt.flatMap { ISO8601DateFormatter().date(from: $0) }
                ?? Date(timeIntervalSince1970: 0),
            isFavorite: false)
    }
}
