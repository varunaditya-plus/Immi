import Foundation
import SwiftData
import XCTest
@testable import ImmichApp

@MainActor
final class PhotoMapSelectionTests: XCTestCase {
    private var directory: URL!
    private var store: SwiftDataManager!

    override func setUp() async throws {
        LocalSnapshot.remove(LocalSnapshot.Key.places)
        RemovedAssets.shared.clear()
        DeletedServerAssetRegistry.shared.clear()
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("photo-map-selection-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        store = SwiftDataManager(storeURL: directory.appendingPathComponent("test.store"),
            backupJournalURL: directory.appendingPathComponent("backup.json"))
    }

    override func tearDown() async throws {
        MockURLProtocol.reset()
        LocalSnapshot.remove(LocalSnapshot.Key.places)
        RemovedAssets.shared.clear()
        DeletedServerAssetRegistry.shared.clear()
        let container = store.modelContainer
        store = nil
        try container.erase()
        try? FileManager.default.removeItem(at: directory)
        try await super.tearDown()
    }

    func testLocationSelectionContainsEveryMemberAndReusesTheCompleteIndexForOtherStacks() async throws {
        let model = model()
        await model.load { (0..<260).map { self.marker("photo-\($0)") } + [self.marker("other")] }
        let all = (0..<260).map { asset("photo-\($0)", date: Double($0)) } + [asset("other", date: 300)]
        var queries = 0
        let stack = try await model.assets(for: Set((0..<260).map { "photo-\($0)" })) {
            queries += 1
            return all
        }
        XCTAssertEqual(stack.count, 260)
        XCTAssertEqual(stack.first?.id, "photo-259")
        XCTAssertEqual(stack.last?.id, "photo-0")
        let next = try await model.assets(for: ["other"]) { queries += 1; return [] }
        XCTAssertEqual(next.map(\.id), ["other"])
        XCTAssertEqual(queries, 1)
    }

    func testConcurrentStackQueriesShareOneMetadataRequestWithoutLosingEitherSelection() async throws {
        let model = model()
        await model.load { [self.marker("first"), self.marker("second")] }
        let held = MapAssetResponseGate()
        var queries = 0
        let first = Task { try await model.assets(for: ["first"]) { queries += 1; return try await held.value() } }
        addTeardownBlock { await held.finish(.failure(CancellationError())); _ = try? await first.value }
        await fulfillment(of: [held.started], timeout: 2)
        let entered = XCTestExpectation(description: "The second location query enters the shared index")
        let second = Task {
            entered.fulfill()
            return try await model.assets(for: ["second"]) { queries += 1; return [] }
        }
        addTeardownBlock { await held.finish(.failure(CancellationError())); _ = try? await second.value }
        await fulfillment(of: [entered], timeout: 2)
        held.finish(.success([asset("first"), asset("second")]))
        let a = try await first.value, b = try await second.value
        XCTAssertEqual(a.map(\.id), ["first"])
        XCTAssertEqual(b.map(\.id), ["second"])
        XCTAssertEqual(queries, 1)
    }

    func testConcurrentRetriesAfterASharedFailureKeepOneReplacementMetadataRequest() async throws {
        let model = model()
        await model.load { [self.marker("first"), self.marker("second")] }
        let failed = MapAssetResponseGate()
        let replacement = MapAssetResponseGate()
        let retrying = XCTestExpectation(description: "Both location queries retry after the shared failure")
        retrying.expectedFulfillmentCount = 2
        var queries = 0
        let fetch: @MainActor () async throws -> [AssetLite] = {
            queries += 1
            switch queries {
            case 1: return try await failed.value()
            case 2: return try await replacement.value()
            default: return [self.asset("first"), self.asset("second")]
            }
        }
        let query: @MainActor (String) async throws -> [AssetLite] = { id in
            do { return try await model.assets(for: [id], using: fetch) }
            catch APIError.notConnected {
                retrying.fulfill()
                return try await model.assets(for: [id], using: fetch)
            }
        }
        let first = Task { try await query("first") }
        addTeardownBlock {
            await failed.finish(.failure(CancellationError()))
            await replacement.finish(.failure(CancellationError()))
            _ = try? await first.value
        }
        await fulfillment(of: [failed.started], timeout: 2)
        let entered = XCTestExpectation(description: "The second location query joins the failing request")
        let second = Task {
            entered.fulfill()
            return try await query("second")
        }
        addTeardownBlock {
            await failed.finish(.failure(CancellationError()))
            await replacement.finish(.failure(CancellationError()))
            _ = try? await second.value
        }
        await fulfillment(of: [entered], timeout: 2)
        failed.finish(.failure(APIError.notConnected))
        await fulfillment(of: [retrying, replacement.started], timeout: 2)
        replacement.finish(.success([asset("first"), asset("second")]))
        let a = try await first.value, b = try await second.value
        XCTAssertEqual(a.map(\.id), ["first"])
        XCTAssertEqual(b.map(\.id), ["second"])
        XCTAssertEqual(queries, 2, "Failed waiters must not clear a newer shared metadata request")
    }

    func testUnknownOrPrivateSelectionDoesNotFetchAndCachedResultsRecheckCurrentPrivacy() async throws {
        let model = model()
        await model.load { [self.marker("public"), self.marker("private")] }
        var queries = 0
        let first = try await model.assets(for: ["public", "private"]) {
            queries += 1
            return [self.asset("public"), self.asset("private")]
        }
        XCTAssertEqual(Set(first.map(\.id)), ["public", "private"])
        DeletedServerAssetRegistry.shared.record(["private"], permanently: true)
        let kept = try await model.assets(for: ["public", "private"]) { queries += 1; return [] }
        let absent = try await model.assets(for: ["private", "unknown"]) { queries += 1; return [] }
        XCTAssertEqual(kept.map(\.id), ["public"])
        XCTAssertTrue(absent.isEmpty)
        XCTAssertEqual(queries, 1)
    }

    func testACommittedMutationRejectsHeldMetadataAndTheNextRequestRefetches() async throws {
        let model = model()
        await model.load { [self.marker("public"), self.marker("private")] }
        let held = MapAssetResponseGate()
        let pending = Task { try await model.assets(for: ["public", "private"]) { try await held.value() } }
        addTeardownBlock { await held.finish(.failure(CancellationError())); _ = try? await pending.value }
        await fulfillment(of: [held.started], timeout: 2)
        try store.setAssetVisibility(["private"], to: "locked")
        held.finish(.success([asset("public"), asset("private")]))
        await expectCancellation { try await pending.value }
        var queried = false
        let retried = try await model.assets(for: ["public", "private"]) {
            queried = true
            return [self.asset("public"), self.asset("private")]
        }
        XCTAssertTrue(queried)
        XCTAssertEqual(retried.map(\.id), ["public"])
    }

    func testMarkerRefreshInvalidatesTheIndexSoNewLocationsDoNotLookEmpty() async throws {
        let model = model()
        await model.load { [self.marker("old")] }
        _ = try await model.assets(for: ["old"]) { [self.asset("old")] }
        await model.load { [self.marker("new")] }
        var queries = 0
        let new = try await model.assets(for: ["new"]) { queries += 1; return [self.asset("new")] }
        XCTAssertEqual(new.map(\.id), ["new"])
        XCTAssertEqual(queries, 1)
    }

    func testMetadataFailureIsRetriableAndNeverCachesAPartialIndex() async throws {
        let model = model()
        await model.load { [self.marker("photo")] }
        do {
            _ = try await model.assets(for: ["photo"]) { throw APIError.notConnected }
            XCTFail("A failed complete query cannot pretend its location is empty")
        } catch APIError.notConnected {
        } catch { XCTFail("Expected the transport error, received \(error)") }
        let retried = try await model.assets(for: ["photo"]) { [self.asset("photo")] }
        XCTAssertEqual(retried.map(\.id), ["photo"])
    }

    func testAccountChangeRejectsHeldMetadataAndClearsLiveMapAndCachedSelection() async throws {
        let model = model()
        await model.load { [self.marker("old-account")] }
        let held = MapAssetResponseGate()
        let pending = Task { try await model.assets(for: ["old-account"]) { try await held.value() } }
        addTeardownBlock { await held.finish(.failure(CancellationError())); _ = try? await pending.value }
        await fulfillment(of: [held.started], timeout: 2)
        LocalSnapshot.clearAll()
        held.finish(.success([asset("old-account")]))
        await expectCancellation { try await pending.value }
        XCTAssertTrue(model.admittedMarkers.isEmpty)
        XCTAssertTrue(model.cachedAssets(for: ["old-account"]).isEmpty)
    }

    func testCancelingASelectionRejectsANoncooperativeFetcherWithoutCachingItsResult() async throws {
        let model = model()
        await model.load { [self.marker("photo")] }
        let held = MapAssetResponseGate()
        let pending = Task { try await model.assets(for: ["photo"]) { try await held.value() } }
        addTeardownBlock { await held.finish(.failure(CancellationError())); _ = try? await pending.value }
        await fulfillment(of: [held.started], timeout: 2)
        model.cancelAssetLoading()
        held.finish(.success([asset("obsolete")]))
        await expectCancellation { try await pending.value }
        var queried = false
        let retried = try await model.assets(for: ["photo"]) { queried = true; return [self.asset("photo")] }
        XCTAssertTrue(queried)
        XCTAssertEqual(retried.map(\.id), ["photo"])
    }

    func testSelectedDeviceGPSWorksOfflineWithoutFetchingOrAdmittingUnselectedPhotos() async throws {
        let photo = local("selected")
        var photos = [photo]
        let model = PhotoMapViewModel(dataManager: store, localPhotos: { photos })
        await model.load { throw APIError.notConnected }
        let id = LocalPhotoLibrary.assetID(for: photo.id)
        XCTAssertEqual(model.admittedMarkers.map(\.id), [id])
        var queries = 0
        let selected = try await model.assets(for: [id, "unselected"]) { queries += 1; throw APIError.notConnected }
        XCTAssertEqual(selected.map(\.id), [id])
        XCTAssertEqual(selected.first?.origin, .device)
        XCTAssertEqual(queries, 0)
        photos = []
        XCTAssertTrue(model.admittedMarkers.isEmpty)
        XCTAssertTrue(model.cachedAssets(for: [id]).isEmpty)
    }

    func testCanonicalMappedMarkerOpensOneLocalFallbackForDuplicateDeviceCopies() async throws {
        let a = local("first"), b = local("second")
        try store.linkDeviceAsset(localIdentifier: a.id, to: "server")
        try store.linkDeviceAsset(localIdentifier: b.id, to: "server")
        let model = PhotoMapViewModel(dataManager: store, localPhotos: { [a, b] })
        XCTAssertEqual(model.admittedMarkers.map(\.id), ["server"])
        let seeded = model.cachedAssets(for: ["server"])
        XCTAssertEqual(seeded.count, 1)
        XCTAssertEqual(seeded.first?.origin, .both)
        let selected = try await model.assets(for: ["server"]) { [] }
        XCTAssertEqual(selected.count, 1)
        XCTAssertTrue(selected.first.map { LocalPhotoLibrary.isLocal($0.id) } == true)
        await model.load { [self.marker("server")] }
        let remote = try await model.assets(for: ["server"]) { [self.asset("server")] }
        XCTAssertEqual(remote.map(\.id), ["server"])
        XCTAssertEqual(remote.first?.origin, .both)
    }

    func testCachedServerPhotoWithoutGPSUsesSelectedDeviceCoordinatesAndCanonicalMetadata() async throws {
        let photo = local("copy")
        try store.linkDeviceAsset(localIdentifier: photo.id, to: "server")
        try store.insertOrUpdateCachedAsset(CachedAsset(id: "server", assetId: "server", type: "IMAGE",
            isFavorite: true, createdAt: Date(timeIntervalSince1970: 300)))
        let model = PhotoMapViewModel(dataManager: store, localPhotos: { [photo] })
        XCTAssertEqual(model.admittedMarkers.map(\.id), ["server"])
        XCTAssertEqual(model.admittedMarkers.first?.lon, 179.8)
        let seeded = model.cachedAssets(for: ["server"])
        XCTAssertEqual(seeded.map(\.id), ["server"])
        XCTAssertEqual(seeded.first?.isFavorite, true)
    }

    func testCollectionScopesResolveDeviceAliasesUsingTheirOwnAccountMappings() async throws {
        let photo = local("copy")
        try store.linkDeviceAsset(localIdentifier: photo.id, to: "server")
        let model = PhotoMapViewModel(dataManager: store, localPhotos: { [photo] })
        await model.load { [self.marker("server"), self.marker("outside")] }

        let scoped = model.markers(forAssetIDs: [LocalPhotoLibrary.assetID(for: photo.id)])

        XCTAssertEqual(scoped.map(\.id), ["server"])
        XCTAssertEqual(model.markers(forAssetIDs: nil).count, 2)
        XCTAssertTrue(model.markers(forAssetIDs: []).isEmpty)
        XCTAssertEqual(model.markers(forAssetIDs: ["server"]).map(\.id), ["server"])
    }

    func testMappedFallbackThumbnailUsesTheDeviceUntilCanonicalMetadataArrives() async throws {
        let photo = local("copy")
        let localID = LocalPhotoLibrary.assetID(for: photo.id)
        try store.linkDeviceAsset(localIdentifier: photo.id, to: "server")
        let model = PhotoMapViewModel(dataManager: store, localPhotos: { [photo] })

        XCTAssertEqual(model.thumbnailID(for: "server"), localID)
        XCTAssertEqual(model.thumbnailID(for: localID), localID)
        XCTAssertNil(model.thumbnailID(for: "unknown"))
        _ = try await model.assets(for: ["server"]) { [self.asset("server")] }
        XCTAssertEqual(model.thumbnailID(for: "server"), "server",
            "Known canonical metadata must preserve the server's current rendition")
        try store.setAssetVisibility(["server"], to: "locked")
        XCTAssertNil(model.thumbnailID(for: "server"))
        try store.setAssetVisibility(["server"], to: "timeline")
        LocalSnapshot.clearAll()
        XCTAssertNil(model.thumbnailID(for: "server"))
        XCTAssertTrue(model.selectedLocalPhotos.isEmpty)
    }

    func testKnownServerMarkersAndCachedMetadataNeverSubstituteTheUneditedDeviceOriginal() async throws {
        let photo = local("copy")
        try store.linkDeviceAsset(localIdentifier: photo.id, to: "server")
        let model = PhotoMapViewModel(dataManager: store, localPhotos: { [photo] })
        await model.load { [self.marker("server")] }
        XCTAssertEqual(model.thumbnailID(for: "server"), "server")

        LocalSnapshot.remove(LocalSnapshot.Key.places)
        let cached = PhotoMapViewModel(dataManager: store, localPhotos: { [photo] })
        XCTAssertEqual(cached.thumbnailID(for: "server"), LocalPhotoLibrary.assetID(for: photo.id))
        try store.insertOrUpdateCachedAsset(CachedAsset(id: "server", assetId: "server", type: "IMAGE",
            isFavorite: false, createdAt: .distantPast))
        XCTAssertEqual(cached.thumbnailID(for: "server"), "server")
        let unuploaded = local("unuploaded")
        let device = PhotoMapViewModel(dataManager: store, localPhotos: { [unuploaded] })
        let deviceID = LocalPhotoLibrary.assetID(for: unuploaded.id)
        XCTAssertEqual(device.thumbnailID(for: deviceID), deviceID)
    }

    func testMappingChangesRejectHeldSelectionsAndInvalidateTheMetadataCache() async throws {
        let photo = local("copy")
        try store.linkDeviceAsset(localIdentifier: photo.id, to: "old-server")
        let model = PhotoMapViewModel(dataManager: store, localPhotos: { [photo] })
        let held = MapAssetResponseGate()
        let pending = Task { try await model.assets(for: ["old-server"]) { try await held.value() } }
        addTeardownBlock { await held.finish(.failure(CancellationError())); _ = try? await pending.value }
        await fulfillment(of: [held.started], timeout: 2)
        let previousRevision = store.backupMappingRevision
        try store.upsertBackupRecord(assetID: "new-server", checksum: "replacement", localIdentifier: photo.id)
        XCTAssertNotEqual(store.backupMappingRevision, previousRevision)
        XCTAssertEqual(store.serverAssetIDsByLocalIdentifier()[photo.id], "new-server")
        held.finish(.success([asset("old-server")]))
        await expectCancellation { try await pending.value }
        var queries = 0
        let retried = try await model.assets(for: ["new-server"]) { queries += 1; return [self.asset("new-server")] }
        XCTAssertEqual(retried.map(\.id), ["new-server"])
        XCTAssertEqual(queries, 1)
        XCTAssertEqual(model.admittedMarkers.map(\.id), ["new-server"])
    }

    func testCompletedLocalSelectionChangeRejectsHeldMappedAssets() async throws {
        let photo = local("copy")
        var photos = [photo]
        try store.linkDeviceAsset(localIdentifier: photo.id, to: "server")
        let model = PhotoMapViewModel(dataManager: store, localPhotos: { photos })
        let held = MapAssetResponseGate()
        let pending = Task { try await model.assets(for: ["server"]) { try await held.value() } }
        addTeardownBlock { await held.finish(.failure(CancellationError())); _ = try? await pending.value }
        await fulfillment(of: [held.started], timeout: 2)
        photos = []
        held.finish(.success([asset("server")]))
        await expectCancellation { try await pending.value }
        XCTAssertTrue(model.admittedMarkers.isEmpty)
        XCTAssertTrue(model.cachedAssets(for: ["server"]).isEmpty)
    }

    func testCachedMarkerRefreshFailureHasRetryFeedbackWithoutDiscardingLocations() async {
        let model = model()
        await model.load { [self.marker("kept")] }
        await model.load { throw APIError.notConnected }
        XCTAssertNil(model.loadError)
        XCTAssertNotNil(model.refreshError)
        XCTAssertEqual(model.admittedMarkers.map(\.id), ["kept"])
        await model.load { [] }
        XCTAssertNil(model.refreshError)
        XCTAssertTrue(model.admittedMarkers.isEmpty)
    }

    private func model() -> PhotoMapViewModel { PhotoMapViewModel(dataManager: store, localPhotos: { [] }) }
    private func marker(_ id: String) -> MapMarkerDTO {
        MapMarkerDTO(id: id, lat: 10, lon: 20, city: "Synthetic city", state: nil, country: nil)
    }
    private func asset(_ id: String, date: Double = 1) -> AssetLite {
        AssetLite(id: id, isVideo: false, ratio: 1, thumbhash: nil, createdAt: Date(timeIntervalSince1970: date))
    }
    private func local(_ id: String) -> LocalPhoto {
        LocalPhoto(id: id, createdAt: .distantPast, modifiedAt: .distantPast, isVideo: false,
            isLivePhoto: false, duration: nil, ratio: 1, latitude: -17, longitude: 179.8)
    }
    private func expectCancellation(_ operation: () async throws -> [AssetLite],
                                    file: StaticString = #filePath, line: UInt = #line) async {
        do { _ = try await operation(); XCTFail("Obsolete selection must not publish assets", file: file, line: line) }
        catch is CancellationError {}
        catch { XCTFail("Expected cancellation, received \(error)", file: file, line: line) }
    }
}

@MainActor
private final class MapAssetResponseGate {
    let started = XCTestExpectation(description: "The map metadata query is held")
    private var continuation: CheckedContinuation<[AssetLite], Error>?
    func value() async throws -> [AssetLite] {
        try await withCheckedThrowingContinuation {
            continuation = $0
            started.fulfill()
        }
    }
    func finish(_ result: Result<[AssetLite], Error>) {
        continuation?.resume(with: result)
        continuation = nil
    }
}
