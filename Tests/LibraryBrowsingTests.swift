import Foundation
import XCTest
@testable import ImmichApp

@MainActor
final class LibraryBrowsingTests: XCTestCase {
    private var directories: [URL] = []
    override func tearDown() async throws {
        MockURLProtocol.reset()
        directories.forEach { try? FileManager.default.removeItem(at: $0) }
        directories.removeAll()
        try await super.tearDown()
    }

    func testRecentlyAddedUsesUploadDatesWithoutChangingCaptureDates() async {
        let earlyCapture = asset("old-capture-new-upload", captured: 1)
        let lateCapture = asset("new-capture-old-upload", captured: 20)
        let source = LibraryMetadataStub(index: .init(assets: [earlyCapture, lateCapture], metadata: [
            earlyCapture.id: .init(addedAt: Date(timeIntervalSince1970: 100), isEdited: false),
            lateCapture.id: .init(addedAt: Date(timeIntervalSince1970: 50), isEdited: false),
        ]))
        let model = TimelineViewModel(libraryMetadataRepository: source)
        await model.updateLibraryOptions(.init(sort: .recentlyAdded))

        XCTAssertEqual(model.libraryAssets.map(\.id), [lateCapture.id, earlyCapture.id])
        XCTAssertEqual(model.libraryAssets.last?.createdAt, Date(timeIntervalSince1970: 1))
        XCTAssertEqual(model.librarySections.map(\.id), ["library.added"])
        XCTAssertEqual(model.asset(for: earlyCapture.id)?.id, earlyCapture.id,
            "Photos admitted by the complete metadata index must also open in the viewer")
    }

    func testFavoritePhotoEditedAndNotInAlbumFiltersIntersectAcrossTheCompleteIndex() async {
        let included = asset("included", captured: 5, favorite: true)
        let video = asset("video", captured: 6, video: true, favorite: true)
        let unedited = asset("unedited", captured: 7, favorite: true)
        let albumMember = asset("album-member", captured: 8, favorite: true)
        let notFavorite = asset("not-favorite", captured: 9)
        let assets = [included, video, unedited, albumMember, notFavorite]
        let index = LibraryMetadataIndex(assets: assets, metadata: Dictionary(uniqueKeysWithValues: assets.map {
            ($0.id, LibraryAssetMetadata(isEdited: $0.id != unedited.id, isNotInAlbum: $0.id != albumMember.id))
        }))
        let source = LibraryMetadataStub(index: index)
        let model = TimelineViewModel(libraryMetadataRepository: source)
        await model.updateLibraryOptions(.init(filters: [.photos, .favorites, .edited, .notInAlbum]))

        XCTAssertEqual(model.libraryAssets.map(\.id), [included.id])
        XCTAssertEqual(model.librarySections.flatMap(\.assets).map(\.id), [included.id])
        XCTAssertEqual(source.membershipRequests, [true])
        XCTAssertTrue(model.libraryMonthNavigationItems.allSatisfy { $0.cover.id == included.id })
        model.setFavorite(included.id, to: false)
        XCTAssertTrue(model.libraryAssets.isEmpty, "An accepted unfavorite must disappear from an active Favorites filter")
    }

    func testBasicFilterUsesAllCachedPhotosWithoutANetworkRequest() async {
        let source = LibraryMetadataStub(index: .init(assets: [], metadata: [:]))
        let model = TimelineViewModel(libraryMetadataRepository: source)
        let assets = (0..<2_001).map { asset("asset-\($0)", captured: Double($0), favorite: $0 == 2_000) }
        model.sections = [TimelineSection(id: "month", title: "Month", assets: assets)]

        await model.updateLibraryOptions(.init(filters: [.favorites]))

        XCTAssertEqual(model.libraryAssets.map(\.id), ["asset-2000"])
        XCTAssertTrue(source.membershipRequests.isEmpty)
    }

    func testActionsUseVisibleMetadataWhileTheTimelineCacheCatchesUp() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("library-visible-metadata-\(UUID())")
        directories.append(directory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let manager = SwiftDataManager(storeURL: directory.appendingPathComponent("test.store"),
            backupJournalURL: directory.appendingPathComponent("backup.json"))
        let item = asset("updated-metadata", captured: 20, favorite: true)
        try manager.insertOrUpdateCachedAsset(CachedAsset(id: item.id, assetId: item.id, type: "IMAGE",
            isFavorite: false, createdAt: Date(timeIntervalSince1970: 1)))
        let source = LibraryMetadataStub(index: .init(assets: [item], metadata: [
            item.id: .init(isEdited: true, isFavorite: true),
        ]))
        let mutations = LibraryActionRepository(api: makeStubAPIClient())
        let model = TimelineViewModel(dataManager: manager, assetRepo: mutations, libraryMetadataRepository: source)
        await model.loadTimeline()
        await model.updateLibraryOptions(.init(filters: [.favorites, .edited]))

        XCTAssertEqual(model.allAssets.first?.isFavorite, false,
            "The fixture must retain stale cached values while complete metadata is visible")
        XCTAssertEqual(model.libraryAssets.map(\.id), [item.id])
        let visible = try XCTUnwrap(model.asset(for: item.id))
        XCTAssertEqual(visible.isFavorite, true)
        XCTAssertEqual(visible.createdAt, item.createdAt)

        let accepted = await model.toggleFavorite(visible)

        XCTAssertTrue(accepted)
        XCTAssertEqual(mutations.favoriteUpdates, [false],
            "Unfavorite must remove the visible favorite instead of resending the stale cache value")
        XCTAssertTrue(model.libraryAssets.isEmpty)
        XCTAssertEqual(manager.getCachedAsset(id: item.id)?.isFavorite, false)
    }

    func testMissingAddedOrEditedMetadataPreservesThePreviousViewAndReportsFailure() async {
        let item = asset("missing-fields", captured: 2)
        let source = LibraryMetadataStub(index: .init(assets: [item], metadata: [:]))
        let model = TimelineViewModel(libraryMetadataRepository: source)
        model.sections = [TimelineSection(id: "month", title: "Month", assets: [item])]
        for options in [LibraryBrowseOptions(sort: .recentlyAdded), .init(filters: [.edited])] {
            model.actionError = nil
            await model.updateLibraryOptions(options)
            XCTAssertEqual(model.libraryOptions, LibraryBrowseOptions())
            XCTAssertEqual(model.libraryAssets.map(\.id), [item.id])
            XCTAssertNotNil(model.actionError)
            XCTAssertFalse(model.isUpdatingLibraryOptions)
        }
    }

    func testAnOlderOptionsRequestCannotOverwriteANewerFilter() async {
        let held = HeldLibraryIndex()
        let source = LibraryMetadataStub(index: .init(assets: [], metadata: [:]))
        source.read = { await held.value() }
        let model = TimelineViewModel(libraryMetadataRepository: source)
        let favorite = asset("favorite", captured: 1, favorite: true)
        model.sections = [TimelineSection(id: "month", title: "Month", assets: [favorite])]
        let old = Task { await model.updateLibraryOptions(.init(sort: .recentlyAdded)) }
        await fulfillment(of: [held.started], timeout: 2)
        await model.updateLibraryOptions(.init(filters: [.favorites]))
        held.finish(.init(assets: [], metadata: [:]))
        await old.value
        XCTAssertEqual(model.libraryOptions.filters, [.favorites])
        XCTAssertEqual(model.libraryOptions.sort, .dateCaptured)
        XCTAssertEqual(model.libraryAssets.map(\.id), [favorite.id])
    }

    func testAnOldAccountMetadataResponseCannotPublish() async {
        let held = HeldLibraryIndex()
        let source = LibraryMetadataStub(index: .init(assets: [], metadata: [:]))
        source.read = { await held.value() }
        let model = TimelineViewModel(libraryMetadataRepository: source)
        let old = Task { await model.updateLibraryOptions(.init(sort: .recentlyAdded)) }
        await fulfillment(of: [held.started], timeout: 2)
        LocalSnapshot.clearAll()
        held.finish(.init(assets: [asset("previous-account", captured: 1)], metadata: [
            "previous-account": .init(addedAt: Date(), isEdited: true),
        ]))
        await old.value
        XCTAssertTrue(model.libraryAssets.isEmpty)
        XCTAssertEqual(model.libraryOptions, LibraryBrowseOptions())
    }

    func testDeviceMetadataUsesAuthoritativeSubtypeAndFavoriteValues() async throws {
        let screenshot = asset(LocalPhotoLibrary.assetID(for: "selected-screenshot"), captured: 1)
        let photo = asset(LocalPhotoLibrary.assetID(for: "selected-photo"), captured: 2, favorite: true)
        let model = TimelineViewModel(libraryDeviceMetadata: { assets in
            XCTAssertEqual(Set(assets.map(\.id)), [screenshot.id, photo.id])
            return [screenshot.id: .init(isEdited: true, isScreenshot: true, isFavorite: true, isNotInAlbum: false),
                    photo.id: .init(isEdited: false, isScreenshot: false, isFavorite: false, isNotInAlbum: false)]
        })
        model.sections = [TimelineSection(id: "month", title: "Month", assets: [screenshot, photo])]
        await model.updateLibraryOptions(.init(filters: [.screenshots, .favorites]))
        XCTAssertEqual(model.libraryAssets.map(\.id), [screenshot.id])
        let includedScreenshot = try XCTUnwrap(model.libraryAssets.first)
        XCTAssertTrue(includedScreenshot.isFavorite)
        XCTAssertEqual(PhotoAssetAccessibility.value(for: includedScreenshot), String(localized: "Favorite"),
            "The rendered photo's accessibility value must reflect its authoritative favorite state")
        await model.updateLibraryOptions(.init(showsScreenshots: false))
        XCTAssertEqual(model.libraryAssets.map(\.id), [photo.id])
        let includedPhoto = try XCTUnwrap(model.libraryAssets.first)
        XCTAssertFalse(includedPhoto.isFavorite)
        XCTAssertNil(PhotoAssetAccessibility.value(for: includedPhoto))
    }

    func testMappedDeviceFallbackKeepsAcceptedServerFavoritesAcrossLibraryFilters() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("library-mapped-favorite-\(UUID())")
        directories.append(directory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let manager = SwiftDataManager(storeURL: directory.appendingPathComponent("test.store"),
            backupJournalURL: directory.appendingPathComponent("backup.json"))
        var uploaded = localPhoto()
        uploaded.isFavorite = true
        let unuploaded = localPhoto()
        let uploadedID = LocalPhotoLibrary.assetID(for: uploaded.id)
        let unuploadedID = LocalPhotoLibrary.assetID(for: unuploaded.id)
        let serverID = UUID().uuidString
        try manager.linkDeviceAsset(localIdentifier: uploaded.id, to: serverID)
        var photoKitFavorite = false
        let mutations = LibraryActionRepository(api: makeStubAPIClient())
        let model = TimelineViewModel(dataManager: manager, assetRepo: mutations,
            libraryDeviceMetadata: { assets in
                Dictionary(uniqueKeysWithValues: assets.map { ($0.id, LibraryAssetMetadata(isFavorite: photoKitFavorite)) })
            }, localPhotos: { [uploaded, unuploaded] })
        await model.loadTimeline()
        let original = try XCTUnwrap(model.asset(for: uploadedID))
        XCTAssertEqual(original.origin, .both)
        XCTAssertFalse(original.isFavorite, "Mapped fallbacks must not substitute the device favorite for unknown server state")
        XCTAssertNil(manager.getCachedAsset(id: serverID), "The uploaded photo must still use its device fallback")

        let favorited = await model.toggleFavorite(original)
        XCTAssertTrue(favorited)
        for filters: Set<LibraryFilter> in [[.photos], [.favorites]] {
            await model.updateLibraryOptions(.init(filters: filters))
            XCTAssertEqual(model.libraryAssets.first(where: { $0.id == uploadedID })?.isFavorite, true)
        }
        XCTAssertEqual(model.libraryAssets.map(\.id), [uploadedID],
            "The accepted server favorite must remain even while PhotoKit says false")
        await model.loadTimeline()
        XCTAssertEqual(model.libraryAssets.map(\.id), [uploadedID])

        photoKitFavorite = true
        let favorite = try XCTUnwrap(model.asset(for: uploadedID))
        let unfavorited = await model.toggleFavorite(favorite)
        XCTAssertTrue(unfavorited)
        await model.updateLibraryOptions(.init(filters: [.photos]))
        XCTAssertEqual(model.libraryAssets.first(where: { $0.id == uploadedID })?.isFavorite, false)
        XCTAssertEqual(model.libraryAssets.first(where: { $0.id == unuploadedID })?.isFavorite, true)
        await model.updateLibraryOptions(.init(filters: [.favorites]))
        XCTAssertEqual(model.libraryAssets.map(\.id), [unuploadedID],
            "Only the unuploaded photo should use PhotoKit's favorite state")
        XCTAssertEqual(mutations.favoriteUpdates, [true, false])
    }

    func testDefaultLibraryUsesDeviceSnapshotFavoritesWithoutAdditionalMetadataQueries() async throws {
        var favorite = localPhoto()
        favorite.isFavorite = true
        var photos = [favorite, localPhoto()]
        let favoriteID = LocalPhotoLibrary.assetID(for: favorite.id)
        var metadataQueries = 0
        let model = TimelineViewModel(libraryDeviceMetadata: { _ in
            metadataQueries += 1
            return [:]
        }, localPhotos: { photos })

        await model.loadTimeline()

        XCTAssertEqual(model.libraryOptions, LibraryBrowseOptions())
        let included = try XCTUnwrap(model.asset(for: favoriteID))
        XCTAssertTrue(included.isFavorite)
        XCTAssertEqual(PhotoAssetAccessibility.value(for: included), String(localized: "Favorite"))
        XCTAssertEqual(model.libraryAssets.filter(\.isFavorite).map(\.id), [favoriteID])
        XCTAssertEqual(metadataQueries, 0, "Default browsing must reuse the selected-device scan")

        photos[0].isFavorite = false
        await model.loadTimeline()

        XCTAssertEqual(model.asset(for: favoriteID)?.isFavorite, false)
        XCTAssertTrue(model.libraryAssets.filter(\.isFavorite).isEmpty)
        XCTAssertEqual(metadataQueries, 0)
    }

    func testCompleteMetadataAndMembershipRequestsFollowEveryContinuationAndExcludePrivatePhotos() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("library-network-index-\(UUID())")
        directories.append(directory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let manager = SwiftDataManager(storeURL: directory.appendingPathComponent("test.store"),
            backupJournalURL: directory.appendingPathComponent("backup.json"))
        let session = MockSessionManager()
        try session.setServer("https://library-browsing.example")
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let api = APIClient(session: session, urlSession: URLSession(configuration: configuration))
        var requests: [[String: Any]] = []
        MockURLProtocol.responseProvider = { request in
            let body = (try? JSONSerialization.jsonObject(with: request.httpBody ?? MockURLProtocol.lastRequestBody ?? Data())) as? [String: Any] ?? [:]
            requests.append(body)
            let page = body["page"] as? Int ?? 1
            let membership = body["isNotInAlbum"] as? Bool == true
            let ids = membership ? (page == 1 ? ["first"] : ["last"]) : (page == 1 ? ["first", "private"] : ["last"])
            let items = ids.map { id -> [String: Any] in
                ["id": id, "type": "IMAGE", "originalFileName": "\(id).jpg",
                 "fileCreatedAt": "2026-01-01T00:00:00.000Z", "createdAt": id == "first" ? "2026-10-10T00:00:00.000Z" : "2026-10-20T00:00:00.000Z",
                 "localDateTime": "2026-01-01T00:00:00.000Z", "isFavorite": false,
                 "isArchived": false, "isTrashed": false, "isEdited": id == "last", "visibility": id == "private" ? "locked" : "timeline"]
            }
            let data = try! JSONSerialization.data(withJSONObject: ["assets": ["items": items, "total": 1, "nextPage": page == 1 ? "7" as Any : NSNull()]])
            return (data, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil), nil)
        }
        let result = try await LibraryMetadataRepository(api: api, dataManager: manager).load(includingAlbumMembership: true)
        XCTAssertEqual(result.assets.map(\.id), ["first", "last"])
        XCTAssertEqual(result.metadata["last"]?.isEdited, true)
        XCTAssertEqual(result.metadata["last"]?.isNotInAlbum, true)
        XCTAssertNotEqual(result.metadata["first"]?.addedAt, result.assets.first?.createdAt)
        XCTAssertEqual(requests.compactMap { $0["page"] as? Int }, [1, 7, 1, 7])
        XCTAssertTrue(requests.allSatisfy { $0["visibility"] as? String == "timeline" })
    }

    func testPhotoAndVideoChoicesReplaceEachOtherButPreserveOtherFilters() {
        var options = LibraryBrowseOptions(filters: [.favorites, .photos])
        options.toggle(.videos)
        XCTAssertEqual(options.filters, [.favorites, .videos])
        options.toggle(.videos)
        XCTAssertEqual(options.filters, [.favorites])
    }

    func testRecentlyAddedRejectsLocalCaptureTimeWhenAddedDateIsUnknown() async {
        let local = asset(LocalPhotoLibrary.assetID(for: "selected-local"), captured: 100)
        let source = LibraryMetadataStub(index: .init(assets: [], metadata: [:]))
        let model = TimelineViewModel(libraryMetadataRepository: source, libraryDeviceMetadata: { _ in [:] })
        model.sections = [TimelineSection(id: "month", title: "Month", assets: [local])]
        await model.updateLibraryOptions(.init(sort: .recentlyAdded))
        XCTAssertEqual(model.libraryOptions.sort, .dateCaptured)
        XCTAssertEqual(model.libraryAssets.map(\.id), [local.id])
        XCTAssertNotNil(model.actionError)
        XCTAssertTrue(source.membershipRequests.isEmpty)
    }

    func testDeletingAMetadataOnlyPhotoRemovesItAfterTheAcceptedServerAction() async {
        let item = asset("metadata-only-delete", captured: 1)
        let source = LibraryMetadataStub(index: .init(assets: [item], metadata: [item.id: .init(isEdited: true)]))
        let mutations = LibraryActionRepository(api: makeStubAPIClient())
        let model = TimelineViewModel(assetRepo: mutations, libraryMetadataRepository: source)
        await model.updateLibraryOptions(.init(filters: [.edited]))
        XCTAssertTrue(model.allAssets.isEmpty, "The fixture must exercise a photo absent from the sync cache")
        XCTAssertEqual(model.libraryAssets.map(\.id), [item.id])
        let deleted = await model.delete(item)
        XCTAssertTrue(deleted)
        XCTAssertEqual(mutations.deleted, [item.id])
        XCTAssertTrue(model.libraryAssets.isEmpty)
        XCTAssertTrue(model.librarySections.isEmpty)
    }

    func testAddingAMetadataOnlyPhotoToAnAlbumRemovesItFromNotInAlbumFilter() async {
        let item = asset("metadata-only-member", captured: 1)
        let source = LibraryMetadataStub(index: .init(assets: [item], metadata: [item.id: .init(isNotInAlbum: true)]))
        let repository = LibraryAlbumActionRepository(api: makeStubAPIClient())
        let model = TimelineViewModel(albumRepo: repository, libraryMetadataRepository: source)
        await model.updateLibraryOptions(.init(filters: [.notInAlbum]))
        let album = AlbumResponseDTO(id: "target", albumName: "Target", description: nil, assetCount: 0,
            albumThumbnailAssetId: nil, shared: false, createdAt: .distantPast, assets: nil)
        let added = await model.addToAlbum([item.id], album: album)
        XCTAssertTrue(added)
        XCTAssertEqual(repository.added, [item.id])
        XCTAssertTrue(model.libraryAssets.isEmpty)
    }

    func testRevertingSavedEditsRefetchesTheActiveEditedFilter() async {
        let item = asset("metadata-only-edit", captured: 1)
        let source = LibraryMetadataStub(index: .init(assets: [item], metadata: [item.id: .init(isEdited: true)]))
        let model = TimelineViewModel(libraryMetadataRepository: source)
        await model.updateLibraryOptions(.init(filters: [.edited]))
        source.index.metadata[item.id]?.isEdited = false
        await model.assetWasUpdated(item.id)
        XCTAssertTrue(model.libraryAssets.isEmpty)
        XCTAssertEqual(source.membershipRequests.count, 2)
    }

    func testLateMetadataCannotUndoAnAcceptedUnfavoriteWithoutACacheRevision() async {
        let item = asset("held-favorite", captured: 1, favorite: true)
        let original = LibraryMetadataIndex(assets: [item], metadata: [item.id: .init(addedAt: Date(), isEdited: true)])
        let source = LibraryMetadataStub(index: original)
        let mutations = LibraryActionRepository(api: makeStubAPIClient())
        let model = TimelineViewModel(assetRepo: mutations, libraryMetadataRepository: source)
        await model.updateLibraryOptions(.init(filters: [.favorites, .edited]))
        let held = HeldLibraryIndex()
        source.read = { await held.value() }
        let old = Task { await model.updateLibraryOptions(.init(sort: .recentlyAdded, filters: [.favorites, .edited])) }
        await fulfillment(of: [held.started], timeout: 2)

        let accepted = await model.toggleFavorite(item)
        XCTAssertTrue(accepted)
        XCTAssertTrue(model.libraryAssets.isEmpty)
        held.finish(original)
        await old.value

        XCTAssertTrue(model.libraryAssets.isEmpty, "An old complete index cannot restore an accepted favorite value")
        XCTAssertEqual(model.libraryOptions.sort, .dateCaptured)
        XCTAssertEqual(mutations.favoriteUpdates, [false])
        XCTAssertFalse(model.isUpdatingLibraryOptions)
    }

    func testLateMetadataCannotResurrectAnAcceptedMetadataOnlyDeletion() async {
        let item = asset("held-delete", captured: 1)
        let original = LibraryMetadataIndex(assets: [item], metadata: [item.id: .init(addedAt: Date(), isEdited: true)])
        let source = LibraryMetadataStub(index: original)
        let mutations = LibraryActionRepository(api: makeStubAPIClient())
        let model = TimelineViewModel(assetRepo: mutations, libraryMetadataRepository: source)
        await model.updateLibraryOptions(.init(filters: [.edited]))
        let held = HeldLibraryIndex()
        source.read = { await held.value() }
        let old = Task { await model.updateLibraryOptions(.init(sort: .recentlyAdded, filters: [.edited])) }
        await fulfillment(of: [held.started], timeout: 2)

        let accepted = await model.delete(item)
        XCTAssertTrue(accepted)
        held.finish(original)
        await old.value

        XCTAssertTrue(model.libraryAssets.isEmpty)
        XCTAssertEqual(mutations.deleted, [item.id])
        XCTAssertFalse(model.isUpdatingLibraryOptions)
    }

    func testLateMembershipIndexCannotUndoAnAcceptedAlbumAddition() async {
        let item = asset("held-album", captured: 1)
        let original = LibraryMetadataIndex(assets: [item], metadata: [item.id: .init(addedAt: Date(), isNotInAlbum: true)])
        let source = LibraryMetadataStub(index: original)
        let mutations = LibraryAlbumActionRepository(api: makeStubAPIClient())
        let model = TimelineViewModel(albumRepo: mutations, libraryMetadataRepository: source)
        await model.updateLibraryOptions(.init(filters: [.notInAlbum]))
        let held = HeldLibraryIndex()
        source.read = { await held.value() }
        let old = Task { await model.updateLibraryOptions(.init(sort: .recentlyAdded, filters: [.notInAlbum])) }
        await fulfillment(of: [held.started], timeout: 2)
        let album = AlbumResponseDTO(id: "target", albumName: "Target", description: nil, assetCount: 0,
            albumThumbnailAssetId: nil, shared: false, createdAt: .distantPast, assets: nil)

        let accepted = await model.addToAlbum([item.id], album: album)
        XCTAssertTrue(accepted)
        held.finish(original)
        await old.value

        XCTAssertTrue(model.libraryAssets.isEmpty)
        XCTAssertEqual(mutations.added, [item.id])
        XCTAssertFalse(model.isUpdatingLibraryOptions)
    }

    func testMetadataIsRefetchedWhenTheSyncedCacheChangesDuringItsRequest() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("library-index-revision-\(UUID())")
        directories.append(directory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let manager = SwiftDataManager(storeURL: directory.appendingPathComponent("test.store"),
            backupJournalURL: directory.appendingPathComponent("backup.json"))
        let item = asset("changed-cache", captured: 1, favorite: true)
        try manager.insertOrUpdateCachedAsset(CachedAsset(id: item.id, assetId: item.id, type: "IMAGE", isFavorite: true,
            createdAt: item.createdAt))
        let original = LibraryMetadataIndex(assets: [item], metadata: [item.id: .init(addedAt: Date())])
        let source = LibraryMetadataStub(index: original)
        let model = TimelineViewModel(dataManager: manager, libraryMetadataRepository: source)
        await model.loadTimeline()
        let held = HeldLibraryIndex()
        var calls = 0
        source.read = {
            calls += 1
            return calls == 1 ? await held.value() : source.index
        }
        let load = Task { await model.updateLibraryOptions(.init(sort: .recentlyAdded)) }
        await fulfillment(of: [held.started], timeout: 2)
        try manager.patchCachedAsset(item.id, isFavorite: false)
        source.index.assets[0].isFavorite = false
        held.finish(original)
        await load.value

        XCTAssertEqual(calls, 2)
        XCTAssertEqual(model.libraryAssets.first?.isFavorite, false)
        XCTAssertEqual(model.libraryOptions.sort, .recentlyAdded)
        XCTAssertFalse(model.isUpdatingLibraryOptions)
    }

    func testScreenshotCapabilityIncludesMetadataOnlyServerPhotosAndSurvivesBasicFilterChanges() async {
        let photo = localPhoto()
        let localID = LocalPhotoLibrary.assetID(for: photo.id)
        let remote = asset(UUID().uuidString, captured: 2)
        let source = LibraryMetadataStub(index: .init(assets: [remote], metadata: [remote.id: .init(isEdited: true)]))
        let model = TimelineViewModel(libraryMetadataRepository: source,
            libraryDeviceMetadata: { _ in [localID: .init(isEdited: true, isScreenshot: true)] }, localPhotos: { [photo] })
        await model.loadTimeline()
        XCTAssertTrue(model.supportsScreenshotFilter)

        await model.updateLibraryOptions(.init(filters: [.edited]))

        XCTAssertTrue(model.allAssets.allSatisfy { LocalPhotoLibrary.isLocal($0.id) },
            "The regression requires server photos that are not yet in the sync cache")
        XCTAssertEqual(Set(model.libraryAssets.map(\.id)), [localID, remote.id])
        XCTAssertFalse(model.supportsScreenshotFilter)
        await model.updateLibraryOptions(.init(filters: [.edited, .screenshots]))
        XCTAssertEqual(model.libraryOptions.filters, [.edited])
        XCTAssertNotNil(model.actionError)
        XCTAssertEqual(Set(model.libraryAssets.map(\.id)), [localID, remote.id])

        await model.updateLibraryOptions(.init())
        XCTAssertFalse(model.supportsScreenshotFilter,
            "Returning to the cached view cannot forget complete metadata evidence of unclassified server photos")
    }

    func testActiveScreenshotOnlyChoicesAreRemovedWhenServerPhotosArrive() async throws {
        for choice in [LibraryBrowseOptions(filters: [.screenshots]), .init(showsScreenshots: false)] {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("library-screenshot-scope-\(UUID())")
            directories.append(directory)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let manager = SwiftDataManager(storeURL: directory.appendingPathComponent("test.store"),
                backupJournalURL: directory.appendingPathComponent("backup.json"))
            let photo = localPhoto()
            let localID = LocalPhotoLibrary.assetID(for: photo.id)
            let model = TimelineViewModel(dataManager: manager,
                libraryDeviceMetadata: { _ in [localID: .init(isScreenshot: true)] }, localPhotos: { [photo] })
            await model.loadTimeline()
            await model.updateLibraryOptions(choice)
            XCTAssertEqual(model.libraryOptions, choice)
            let remote = asset(UUID().uuidString, captured: 2)
            try manager.insertOrUpdateCachedAsset(CachedAsset(id: remote.id, assetId: remote.id, type: "IMAGE",
                createdAt: remote.createdAt))

            await model.loadTimeline()

            XCTAssertFalse(model.supportsScreenshotFilter)
            XCTAssertFalse(model.libraryOptions.filters.contains(.screenshots))
            XCTAssertTrue(model.libraryOptions.showsScreenshots)
            XCTAssertEqual(Set(model.libraryAssets.map(\.id)), [localID, remote.id],
                "Unknown server subtypes must not silently disappear behind a global screenshot choice")
        }
    }

    private func localPhoto() -> LocalPhoto {
        LocalPhoto(id: "selected-\(UUID())", createdAt: Date(timeIntervalSince1970: 1),
            modifiedAt: Date(timeIntervalSince1970: 1), isVideo: false, isLivePhoto: false, duration: nil, ratio: 1)
    }

    private func asset(_ id: String, captured: Double, video: Bool = false, favorite: Bool = false) -> AssetLite {
        AssetLite(id: id, isVideo: video, ratio: 1, thumbhash: nil,
            createdAt: Date(timeIntervalSince1970: captured), isFavorite: favorite)
    }
}

@MainActor
private final class LibraryMetadataStub: LibraryMetadataProviding {
    var index: LibraryMetadataIndex
    var read: (() async throws -> LibraryMetadataIndex)?
    var membershipRequests: [Bool] = []
    init(index: LibraryMetadataIndex) { self.index = index }
    func load(includingAlbumMembership: Bool) async throws -> LibraryMetadataIndex {
        membershipRequests.append(includingAlbumMembership)
        return try await read?() ?? index
    }
}

@MainActor
private final class HeldLibraryIndex {
    let started = XCTestExpectation(description: "Library metadata request began")
    private var continuation: CheckedContinuation<LibraryMetadataIndex, Never>?
    func value() async -> LibraryMetadataIndex {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            started.fulfill()
        }
    }
    func finish(_ index: LibraryMetadataIndex) {
        continuation?.resume(returning: index)
        continuation = nil
    }
}

private final class LibraryActionRepository: AssetDetailRepository {
    var deleted: [String] = []
    var favoriteUpdates: [Bool] = []
    override func toggleFavorite(_ id: String, to value: Bool) async throws { favoriteUpdates.append(value) }
    override func delete(_ id: String) async throws { deleted.append(id) }
}

private final class LibraryAlbumActionRepository: AlbumRepository {
    var added: [String] = []
    override func addAssets(_ ids: [String], to albumId: String) async throws -> [String] {
        added.append(contentsOf: ids)
        return []
    }
}
