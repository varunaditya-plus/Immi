import Foundation
import Observation
import XCTest
@testable import ImmichApp

@MainActor
final class CollectionsCurationTests: XCTestCase {
    private var directories: [URL] = []

    override func tearDown() {
        RemovedAssets.shared.clear()
        DeletedServerAssetRegistry.shared.clear()
        directories.forEach { try? FileManager.default.removeItem(at: $0) }
        directories.removeAll()
    }

    func testFeaturedSelectionWorksWithoutFavoritesAndSpreadsAcrossCaptureMonths() {
        let photos = [asset("october", "2026-10-28T12:00:00Z"), asset("same-session", "2026-10-28T11:00:00Z"),
                      asset("september", "2026-09-01T12:00:00Z"), asset("august", "2026-08-01T12:00:00Z"),
                      asset("video", "2026-07-01T12:00:00Z", video: true)]

        let selected = FeaturedPhotoSelection.select(from: photos, limit: 3, calendar: calendar)

        XCTAssertEqual(selected.map(\.id), ["october", "september", "august"])
        XCTAssertTrue(selected.allSatisfy { !$0.isFavorite && !$0.isVideo })
        XCTAssertEqual(FeaturedPhotoSelection.select(from: photos.reversed(), limit: 3, calendar: calendar).map(\.id), selected.map(\.id))
        XCTAssertTrue(FeaturedPhotoSelection.select(from: photos, limit: 0).isEmpty)
    }

    func testSelectedLocalMergeDeduplicatesServerCopiesAndSuppressesPrivateFallbacks() throws {
        let manager = try fixture()
        let visible = asset("server-visible", "2026-10-28T12:00:00Z")
        let hidden = "server-private-\(UUID())"
        try manager.upsertBackupRecord(assetID: hidden, checksum: "private", localIdentifier: "local-private")
        try manager.setAssetVisibility([hidden], to: "locked")
        let merged = CollectionsAssetSources.merge(
            server: [visible],
            selectedLocal: [local("local-visible"), local("local-only"), local("local-only"), local("local-private")],
            mappings: ["local-visible": visible.id, "local-private": hidden],
            policy: AssetVisibilityPolicy(scope: .timeline, dataManager: manager))

        XCTAssertEqual(merged.map(\.id), [visible.id, LocalPhotoLibrary.assetID(for: "local-only")])
        XCTAssertEqual(merged.map(\.origin), [.both, .device])
    }

    func testRecentAndFeaturedCollectionsRetainSelectedLocalMembersAndDropUnselectedCopiesImmediately() throws {
        let manager = try fixture()
        let serverID = UUID().uuidString
        try manager.insertOrUpdateCachedAsset(CachedAsset(id: serverID, assetId: serverID, type: "IMAGE", createdAt: date("2026-10-28T12:00:00Z")))
        let selection = CollectionsSelectedPhotos()
        selection.photos = [local("selected-local")]
        let api = APIClient(session: MockSessionManager())
        let model = LibraryViewModel(memoriesRepo: MemoriesRepository(api: api), albumRepo: AlbumRepository(api: api),
            peopleRepo: PeopleRepository(api: api), searchRepo: SearchRepository(api: api), assetRepo: AssetDetailRepository(api: api),
            dataManager: manager, localPhotos: { selection.photos })
        model.refreshRecentDays(calendar: calendar)
        let interval = DateInterval(start: date("2026-10-28T00:00:00Z"), end: date("2026-10-29T00:00:00Z"))
        let expected = Set([serverID, LocalPhotoLibrary.assetID(for: "selected-local")])

        XCTAssertEqual(Set(model.recentDays.flatMap(\.assets).map(\.id)), expected)
        XCTAssertEqual(Set(model.featuredPhotos.map(\.id)), expected)
        XCTAssertEqual(Set(model.assets(in: interval).map(\.id)), expected)
        selection.photos = []
        XCTAssertEqual(model.recentDays.first?.assets.map(\.id), [serverID])
        XCTAssertEqual(model.featuredPhotos.map(\.id), [serverID])
        XCTAssertEqual(model.assets(in: interval).map(\.id), [serverID])
    }

    func testSameIDFeaturedMetadataChangesPublishToAnOpenCollection() throws {
        let manager = try fixture()
        let id = UUID().uuidString
        try manager.insertOrUpdateCachedAsset(CachedAsset(id: id, assetId: id, type: "IMAGE", createdAt: date("2026-10-28T12:00:00Z")))
        let api = APIClient(session: MockSessionManager())
        let model = LibraryViewModel(memoriesRepo: MemoriesRepository(api: api), albumRepo: AlbumRepository(api: api),
            peopleRepo: PeopleRepository(api: api), searchRepo: SearchRepository(api: api), assetRepo: AssetDetailRepository(api: api),
            dataManager: manager, localPhotos: { [] })
        model.refreshRecentDays(calendar: calendar)
        let probe = CollectionsCurationPublicationProbe()
        withObservationTracking { _ = model.featuredPhotos.first?.isFavorite } onChange: {
            MainActor.assumeIsolated { probe.changed = true }
        }

        try manager.patchCachedAsset(id, isFavorite: true)
        model.refreshRecentDays(calendar: calendar)

        XCTAssertTrue(probe.changed, "AssetLite identity equality must not suppress a metadata redraw")
        XCTAssertEqual(model.featuredPhotos.first?.id, id)
        XCTAssertEqual(model.featuredPhotos.first?.isFavorite, true)
    }

    func testDayDrilldownFollowsEveryServerPageThenMergesSelectedLocalMembers() async throws {
        let manager = try fixture()
        let api = APIClient(session: MockSessionManager())
        let search = CollectionsDaySearchRepository(api: api, recordsVisibility: false)
        let midnight = dto("next-day", "2026-10-29T00:00:00Z")
        var privatePhoto = dto("private", "2026-10-28T23:00:00Z")
        privatePhoto.visibility = "locked"
        search.pages = [
            1: .init(assets: .init(items: [dto("first", "2026-10-28T01:00:00Z"), midnight], total: 1, nextPage: "7")),
            7: .init(assets: .init(items: [dto("last", "2026-10-28T20:00:00Z"), privatePhoto], total: 1, nextPage: nil))
        ]
        let outsideServerID = "mapped-outside-day"
        try manager.insertOrUpdateCachedAsset(CachedAsset(id: outsideServerID, assetId: outsideServerID, type: "IMAGE", createdAt: date("2026-10-27T12:00:00Z")))
        try manager.upsertBackupRecord(assetID: outsideServerID, checksum: "outside", localIdentifier: "mapped-local")
        var selectionReads = 0
        let repository = RecentDayRepository(repository: search, dataManager: manager, localPhotos: {
            selectionReads += 1
            return [self.local("selected-local"), self.local("outside-day", timestamp: "2026-10-27T12:00:00Z"), self.local("mapped-local")]
        })
        let interval = DateInterval(start: date("2026-10-28T00:00:00Z"), end: date("2026-10-29T00:00:00Z"))

        let result = try await repository.assets(in: interval)

        XCTAssertEqual(result.map(\.id), ["last", LocalPhotoLibrary.assetID(for: "selected-local"), "first"])
        XCTAssertEqual(search.requests.compactMap(\.page), [1, 7])
        XCTAssertTrue(search.requests.allSatisfy { $0.takenAfter == interval.start.ISO8601Format() && $0.takenBefore == interval.end.ISO8601Format() })
        XCTAssertTrue(search.requests.allSatisfy { $0.visibility == "timeline" })
        XCTAssertEqual(selectionReads, 1, "Only already-selected metadata may be read; the collection must not start a PhotoKit scan")
    }

    func testChangedAccountRejectsDayResponseBeforeReadingTheNewLocalSelection() async throws {
        let api = APIClient(session: MockSessionManager())
        let search = CollectionsDaySearchRepository(api: api, recordsVisibility: false)
        search.pages = [1: .init(assets: .init(items: [dto("old-account", "2026-10-28T12:00:00Z")], total: 1, nextPage: nil))]
        search.onPage = { LocalSnapshot.clearAll() }
        var selectionReads = 0
        let repository = RecentDayRepository(repository: search, dataManager: try fixture(), localPhotos: {
            selectionReads += 1
            return [self.local("new-account-selection")]
        })
        do {
            _ = try await repository.assets(in: DateInterval(start: date("2026-10-28T00:00:00Z"), end: date("2026-10-29T00:00:00Z")))
            XCTFail("The old account's response must not become a mixed-account day collection")
        } catch is CancellationError {
        }
        XCTAssertEqual(selectionReads, 0)
    }

    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    private func fixture() throws -> SwiftDataManager {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("collections-curation-\(UUID())")
        directories.append(directory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return SwiftDataManager(storeURL: directory.appendingPathComponent("store"), backupJournalURL: directory.appendingPathComponent("journal.json"))
    }

    private func date(_ text: String) -> Date { ISO8601DateFormatter().date(from: text)! }
    private func asset(_ id: String, _ text: String, video: Bool = false) -> AssetLite {
        AssetLite(id: id, isVideo: video, ratio: 1.5, thumbhash: nil, createdAt: date(text))
    }
    private func local(_ id: String, timestamp: String = "2026-10-28T12:00:00Z") -> LocalPhoto {
        LocalPhoto(id: id, createdAt: date(timestamp), modifiedAt: date(timestamp), isVideo: false, isLivePhoto: false, duration: nil, ratio: 1.5)
    }
    private func dto(_ id: String, _ text: String) -> AssetResponseDTO {
        var asset = makeTestAsset(id: id)
        asset.fileCreatedAt = date(text)
        return asset
    }
}

@MainActor
private final class CollectionsDaySearchRepository: SearchRepository {
    var pages: [Int: SearchResponseDTO] = [:]
    var requests: [SearchRequestDTO] = []
    var onPage: (() -> Void)?

    override func metadataPage(_ request: SearchRequestDTO) async throws -> SearchResponseDTO {
        requests.append(request)
        onPage?()
        return try XCTUnwrap(pages[request.page ?? 1])
    }
}


@MainActor
private final class CollectionsCurationPublicationProbe {
    var changed = false
}


@MainActor
private final class CollectionsSelectedPhotos {
    var photos: [LocalPhoto] = []
}
