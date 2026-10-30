import Foundation
import XCTest
@testable import ImmichApp

@MainActor
final class RecentDayCollectionTests: XCTestCase {
    private var directories: [URL] = []

    override func tearDown() {
        directories.forEach { try? FileManager.default.removeItem(at: $0) }
        directories.removeAll()
        RemovedAssets.shared.clear()
        DeletedServerAssetRegistry.shared.clear()
    }

    func testLimitingPreviewDaysRetainsEveryMemberOfTheVisibleDay() throws {
        let photos = [photo("old", "2026-10-27T23:59:59Z"), photo("start", "2026-10-28T00:00:00Z"),
                      photo("middle", "2026-10-28T12:00:00Z"), photo("end", "2026-10-28T23:59:59Z")]

        let days = RecentDayCollection.build(from: photos, calendar: calendar("UTC"), limit: 1)

        XCTAssertEqual(days.count, 1)
        XCTAssertEqual(days.first?.assets.map(\.id), ["end", "middle", "start"])
        XCTAssertEqual(days.first?.start, date("2026-10-28T00:00:00Z"))
        XCTAssertEqual(days.first?.end, date("2026-10-29T00:00:00Z"))
    }

    func testGroupingAndQueryBoundsFollowLocalCalendarAcrossDaylightSaving() throws {
        let day = try XCTUnwrap(RecentDayCollection.build(
            from: [photo("first-1am", "2026-11-01T08:30:00Z"), photo("second-1am", "2026-11-01T09:30:00Z")],
            calendar: calendar("America/Los_Angeles")).first)

        XCTAssertEqual(day.assets.map(\.id), ["second-1am", "first-1am"])
        XCTAssertEqual(day.start, date("2026-11-01T07:00:00Z"))
        XCTAssertEqual(day.end, date("2026-11-02T08:00:00Z"))
        XCTAssertEqual(day.end.timeIntervalSince(day.start), 25 * 60 * 60)
        let spring = try XCTUnwrap(RecentDayCollection.build(
            from: [photo("spring", "2026-03-08T12:00:00Z")], calendar: calendar("America/Los_Angeles")).first)
        XCTAssertEqual(spring.end.timeIntervalSince(spring.start), 23 * 60 * 60)
    }

    func testInclusiveServerEndBoundaryCannotShowTheFollowingDay() {
        let interval = DateInterval(start: date("2026-10-28T00:00:00Z"), end: date("2026-10-29T00:00:00Z"))
        let rows = [dto("before", "2026-10-27T23:59:59Z"), dto("start", "2026-10-28T00:00:00Z"),
                    dto("last", "2026-10-28T23:59:59Z"), dto("next-midnight", "2026-10-29T00:00:00Z")]

        XCTAssertEqual(CollectionCaptureDateScope.filter(rows, interval: interval).map(\.id), ["start", "last"])
    }

    func testRecentDayCoversAndMembersImmediatelyRespectNewPrivacyRestrictions() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("recent-days-\(UUID())")
        directories.append(directory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let manager = SwiftDataManager(storeURL: directory.appendingPathComponent("test.store"),
            backupJournalURL: directory.appendingPathComponent("backup.json"))
        let ids = (0..<4).map { _ in UUID().uuidString }
        for (offset, id) in ids.enumerated() {
            try manager.insertOrUpdateCachedAsset(CachedAsset(id: id, assetId: id, type: "IMAGE",
                createdAt: date("2026-10-28T12:00:00Z").addingTimeInterval(Double(offset))))
        }
        let api = APIClient(session: MockSessionManager())
        let model = LibraryViewModel(memoriesRepo: MemoriesRepository(api: api), albumRepo: AlbumRepository(api: api),
            peopleRepo: PeopleRepository(api: api), searchRepo: SearchRepository(api: api),
            assetRepo: AssetDetailRepository(api: api), dataManager: manager)
        model.refreshRecentDays(calendar: calendar("UTC"))
        XCTAssertEqual(model.recentDays.first?.assets.map(\.id), ids.reversed().map { $0 })
        let pushedSnapshot = try XCTUnwrap(model.recentDays.first)
        let policy = AssetVisibilityPolicy(scope: .timeline, dataManager: manager)

        try manager.setAssetVisibility([ids[3]], to: "locked")
        try manager.setAssetVisibility([ids[2]], to: "archive")
        DeletedServerAssetRegistry.shared.record([ids[1]], permanently: false)

        XCTAssertEqual(model.recentDays.first?.assets.map(\.id), [ids[0]])
        XCTAssertEqual(model.recentDays.first?.cover?.id, ids[0])
        XCTAssertEqual(pushedSnapshot.filteringAssets(using: policy)?.cover?.id, ids[0],
            "A pushed destination must read current privacy even when its day value was captured earlier")
        try manager.purgeAssets([ids[0]], reason: .trashed)
        XCTAssertTrue(model.recentDays.isEmpty)
        XCTAssertNil(pushedSnapshot.filteringAssets(using: policy))
    }

    private func calendar(_ zone: String) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: zone)!
        return calendar
    }

    private func date(_ text: String) -> Date { ISO8601DateFormatter().date(from: text)! }

    private func photo(_ id: String, _ timestamp: String) -> AssetLite {
        AssetLite(id: id, isVideo: false, ratio: 1, thumbhash: nil, createdAt: date(timestamp))
    }

    private func dto(_ id: String, _ timestamp: String) -> AssetResponseDTO {
        var asset = makeTestAsset(id: id)
        asset.fileCreatedAt = date(timestamp)
        return asset
    }
}
