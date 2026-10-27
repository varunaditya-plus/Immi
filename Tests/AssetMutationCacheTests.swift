import Observation
import SwiftData
import XCTest
@testable import ImmichApp

@MainActor
final class AssetMutationCacheTests: XCTestCase {
    private var directory: URL!
    private var manager: SwiftDataManager!
    private var repository: AssetDetailRepository!
    private var session: MockSessionManager!
    private var ids: [String] = []
    private let oldDate = Date(timeIntervalSince1970: 1_700_000_000)

    override func setUp() async throws {
        MockURLProtocol.reset()
        RemovedAssets.shared.clear()
        DeletedServerAssetRegistry.shared.clear()
        ids = (0..<3).map { _ in UUID().uuidString }
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("asset-mutation-cache-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        manager = SwiftDataManager(storeURL: directory.appendingPathComponent("test.store"),
            backupJournalURL: directory.appendingPathComponent("backup.json"))
        manager.modelContext.autosaveEnabled = false
        for (index, id) in ids.enumerated() {
            try manager.insertOrUpdateCachedAsset(CachedAsset(id: id, assetId: id, type: "IMAGE",
                thumbnailPath: "thumbnail-\(index)", previewPath: "preview-\(index)",
                duration: 8, livePhotoVideoId: "live-\(index)",
                createdAt: oldDate.addingTimeInterval(Double(index) * 86_400), updatedAt: oldDate,
                exifData: #"{"make":"Camera","description":"before","latitude":12,"longitude":34,"extra":"preserved"}"#,
                ratio: 1.5, thumbhash: "hash-\(index)"))
            LocalSnapshot.save(detail(id), for: LocalSnapshot.Key.assetDetail(id))
        }
        session = MockSessionManager()
        try session.setServer("https://cache-tests.example")
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let api = APIClient(session: session, urlSession: URLSession(configuration: configuration))
        repository = AssetDetailRepository(api: api, dataManager: manager)
        stub(status: 204)
    }

    override func tearDown() async throws {
        repository = nil
        manager = nil
        session = nil
        for id in ids {
            LocalSnapshot.remove(LocalSnapshot.Key.assetDetail(id))
            DeletedServerAssetRegistry.shared.restore([id])
        }
        RemovedAssets.shared.clear()
        DeletedServerAssetRegistry.shared.clear()
        MockURLProtocol.reset()
        try? FileManager.default.removeItem(at: directory)
    }

    func testFavoriteSuccessPatchesOnlyItsPersistedAssetAndDetailSnapshot() async throws {
        let revision = manager.assetMutationRevision

        try await repository.toggleFavorite(ids[0], to: true)

        let reopened = reopen()
        let changed = try XCTUnwrap(reopened.getCachedAsset(id: ids[0]))
        XCTAssertTrue(changed.isFavorite)
        XCTAssertFalse(try XCTUnwrap(reopened.getCachedAsset(id: ids[1])).isFavorite)
        XCTAssertEqual(changed.createdAt, oldDate)
        XCTAssertEqual(changed.thumbnailPath, "thumbnail-0")
        XCTAssertEqual(changed.previewPath, "preview-0")
        XCTAssertEqual(changed.ratio, 1.5)
        XCTAssertEqual(changed.livePhotoVideoId, "live-0")
        XCTAssertNotEqual(manager.assetMutationRevision, revision)
        XCTAssertEqual(snapshot(ids[0])?.isFavorite, true)
        XCTAssertEqual(snapshot(ids[1])?.isFavorite, false)
        let request = try XCTUnwrap(MockURLProtocol.lastRequest)
        XCTAssertEqual(request.url?.path, "/api/assets/\(ids[0])")
        XCTAssertEqual(request.httpMethod, "PUT")
        XCTAssertEqual(try body(request)["isFavorite"] as? Bool, true)
    }

    func testFailedFavoriteLeavesCacheAndSnapshotUnchanged() async throws {
        let revision = manager.assetMutationRevision
        stub(status: 500)

        await assertRejected { try await self.repository.toggleFavorite(self.ids[0], to: true) }

        XCTAssertFalse(try XCTUnwrap(reopen().getCachedAsset(id: ids[0])).isFavorite)
        XCTAssertEqual(snapshot(ids[0])?.isFavorite, false)
        XCTAssertEqual(manager.assetMutationRevision, revision)
    }

    func testVisibilityActionsPersistWithoutPurgingMediaMetadata() async throws {
        let id = ids[0]
        for (visibility, archived) in [(AssetDetailRepository.Visibility.archive, true), (.locked, true), (.timeline, false)] {
            let revision = manager.assetMutationRevision
            try await repository.setVisibility(id, to: visibility)
            let cached = try XCTUnwrap(reopen().getCachedAsset(id: id))
            XCTAssertEqual(cached.isArchived, archived)
            XCTAssertEqual(cached.ratio, 1.5)
            XCTAssertEqual(cached.createdAt, oldDate)
            XCTAssertEqual(try exif(cached)["make"] as? String, "Camera")
            XCTAssertEqual(try exif(cached)["extra"] as? String, "preserved")
            XCTAssertNotEqual(manager.assetMutationRevision, revision)
            XCTAssertEqual(try body(XCTUnwrap(MockURLProtocol.lastRequest))["visibility"] as? String, visibility.rawValue)
            XCTAssertEqual(manager.timelineAssets().contains { $0.asset.id == id }, !archived)
        }
        XCTAssertFalse(try XCTUnwrap(reopen().getCachedAsset(id: ids[1])).isArchived)
    }

    func testRejectedVisibilityDoesNotRemoveTheAssetFromOfflineTimeline() async throws {
        let revision = manager.assetMutationRevision
        stub(status: 403)

        await assertRejected { try await self.repository.setVisibility(self.ids[0], to: .locked) }

        XCTAssertTrue(reopen().timelineAssets().contains { $0.asset.id == ids[0] })
        XCTAssertEqual(snapshot(ids[0])?.isArchived, false)
        XCTAssertEqual(manager.assetMutationRevision, revision)
    }

    func testAcceptedDateUpdatesOfflineOrderAndMonthWhenDetailRefreshFails() async throws {
        let changedDate = oldDate.addingTimeInterval(100 * 86_400)
        MockURLProtocol.responseProvider = { request in
            let status = request.httpMethod == "PUT" ? 204 : 503
            return (Data(), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil), nil)
        }
        let model = AssetDetailViewModel(repo: repository)
        model.detail = detail(ids[0])

        let accepted = await model.updateDate(ids[0], to: changedDate)

        XCTAssertTrue(accepted, "A failed read cannot undo a date already accepted by the server")
        let reopened = reopen()
        let cached = try XCTUnwrap(reopened.getCachedAsset(id: ids[0]))
        XCTAssertEqual(cached.createdAt, changedDate)
        XCTAssertEqual(cached.monthKey, MonthKey.of(changedDate))
        XCTAssertEqual(reopened.timelineAssets().map(\.asset.id), [ids[1], ids[2], ids[0]])
        XCTAssertEqual(try exif(cached)["make"] as? String, "Camera")
        XCTAssertEqual(try exif(cached)["dateTimeOriginal"] as? String,
            ISO8601DateFormatter.immichFractional.string(from: changedDate))
        XCTAssertNil(snapshot(ids[0]), "A failed refresh must not retain the pre-edit detail snapshot")
        if case .failed = model.phase { } else { XCTFail("The refresh failure should remain represented separately") }
    }

    func testDescriptionAndLocationPatchExifWithoutReplacingOtherFields() async throws {
        try await repository.updateDescription(ids[0], to: "")
        XCTAssertEqual(snapshot(ids[0])?.exifInfo?.description, "")
        try await repository.updateLocation(ids[0], latitude: 0, longitude: 0)

        let reopened = reopen()
        let changed = try XCTUnwrap(reopened.getCachedAsset(id: ids[0]))
        let fields = try exif(changed)
        XCTAssertEqual(fields["description"] as? String, "")
        XCTAssertEqual(fields["latitude"] as? Double, 0)
        XCTAssertEqual(fields["longitude"] as? Double, 0)
        XCTAssertEqual(fields["make"] as? String, "Camera")
        XCTAssertEqual(fields["extra"] as? String, "preserved")
        XCTAssertEqual(changed.createdAt, oldDate)
        XCTAssertEqual(changed.ratio, 1.5)
        XCTAssertEqual(try exif(XCTUnwrap(reopened.getCachedAsset(id: ids[1])))["description"] as? String, "before")
        XCTAssertNil(snapshot(ids[0]), "Place names derived by the server cannot remain cached after coordinates change")
        let payload = try body(XCTUnwrap(MockURLProtocol.lastRequest))
        XCTAssertEqual(payload["latitude"] as? Double, 0)
        XCTAssertEqual(payload["longitude"] as? Double, 0)
    }

    func testRejectedMetadataMutationsLeavePersistentFieldsAndSnapshotsAlone() async throws {
        stub(status: 400)
        let before = try XCTUnwrap(manager.getCachedAsset(id: ids[0])).exifData
        let revision = manager.assetMutationRevision

        await assertRejected { try await self.repository.updateDate(self.ids[0], to: .distantPast) }
        await assertRejected { try await self.repository.updateDescription(self.ids[0], to: "rejected") }
        await assertRejected { try await self.repository.updateLocation(self.ids[0], latitude: 10, longitude: 20) }

        let cached = try XCTUnwrap(reopen().getCachedAsset(id: ids[0]))
        XCTAssertEqual(cached.createdAt, oldDate)
        XCTAssertEqual(cached.exifData, before)
        XCTAssertEqual(snapshot(ids[0])?.exifInfo?.description, "before")
        XCTAssertEqual(manager.assetMutationRevision, revision)
    }

    func testDescriptionWithoutExifUpdatesTheActiveDetailAndItsOfflineSnapshot() async throws {
        let original = makeTestAsset(id: ids[0], exifInfo: nil)
        LocalSnapshot.save(original, for: LocalSnapshot.Key.assetDetail(ids[0]))
        let model = AssetDetailViewModel(repo: repository)
        model.detail = original

        let accepted = await model.updateDescription(ids[0], to: "New caption")

        XCTAssertTrue(accepted)
        XCTAssertEqual(model.detail?.exifInfo?.description, "New caption")
        XCTAssertEqual(snapshot(ids[0])?.exifInfo?.description, "New caption")
        XCTAssertEqual(try exif(XCTUnwrap(reopen().getCachedAsset(id: ids[0])))["description"] as? String, "New caption")
        XCTAssertEqual(snapshot(ids[1])?.exifInfo?.description, "before")
        XCTAssertEqual(try body(XCTUnwrap(MockURLProtocol.lastRequest))["description"] as? String, "New caption")
    }

    func testRejectedDescriptionWithoutExifKeepsTheOriginalDetailAndSnapshot() async throws {
        let original = makeTestAsset(id: ids[0], exifInfo: nil)
        LocalSnapshot.save(original, for: LocalSnapshot.Key.assetDetail(ids[0]))
        let model = AssetDetailViewModel(repo: repository)
        model.detail = original
        stub(status: 500)

        let accepted = await model.updateDescription(ids[0], to: "Rejected caption")

        XCTAssertFalse(accepted)
        XCTAssertNil(model.detail?.exifInfo)
        XCTAssertNil(snapshot(ids[0])?.exifInfo)
        XCTAssertNotNil(snapshot(ids[0]))
        XCTAssertEqual(try exif(XCTUnwrap(reopen().getCachedAsset(id: ids[0])))["description"] as? String, "before")
    }

    func testDetailMoveAndDeleteCannotReappearAfterOfflineRebuild() async throws {
        let model = AssetDetailViewModel(repo: repository)
        model.detail = detail(ids[0])
        let moved = await model.move(ids[0], to: .archive)
        XCTAssertTrue(moved)
        XCTAssertFalse(reopen().timelineAssets().contains { $0.asset.id == ids[0] })
        XCTAssertEqual(snapshot(ids[0])?.isArchived, true)

        let deleted = await model.delete(ids[1])
        XCTAssertTrue(deleted)
        let reopened = reopen()
        XCTAssertNil(reopened.getCachedAsset(id: ids[1]))
        XCTAssertEqual(reopened.timelineAssets().map(\.asset.id), [ids[2]])
        XCTAssertNil(snapshot(ids[1]))
        XCTAssertNotNil(snapshot(ids[2]))
    }

    func testDeletePurgesCacheButPreservesMappingAndTrashEligibility() async throws {
        try manager.linkDeviceAsset(localIdentifier: "local-\(ids[0])", to: ids[0])
        let removed = AssetLite(detail(ids[0]))

        try await repository.delete(ids[0])

        let reopened = reopen()
        XCTAssertNil(reopened.getCachedAsset(id: ids[0]))
        XCTAssertEqual(reopened.getBackupRecord(localIdentifier: "local-\(ids[0])")?.assetId, ids[0])
        XCTAssertTrue(RemovedAssets.shared.filter([removed]).isEmpty)
        XCTAssertEqual(RemovedAssets.shared.filter([removed], scope: .trash).map(\.id), [ids[0]])
        XCTAssertTrue(DeletedServerAssetRegistry.shared.suppressedIDs.contains(ids[0]))
        XCTAssertNil(snapshot(ids[0]))
        XCTAssertNotNil(snapshot(ids[1]))
        let request = try XCTUnwrap(MockURLProtocol.lastRequest)
        XCTAssertEqual(request.httpMethod, "DELETE")
        XCTAssertEqual(try body(request)["ids"] as? [String], [ids[0]])
        XCTAssertEqual(try body(request)["force"] as? Bool, false)
    }

    func testRejectedDeleteLeavesCacheAndRemovalRegistriesUnchanged() async throws {
        let revision = manager.assetMutationRevision
        stub(status: 500)

        await assertRejected { try await self.repository.delete(self.ids[0]) }

        XCTAssertNotNil(reopen().getCachedAsset(id: ids[0]))
        XCTAssertNotNil(snapshot(ids[0]))
        XCTAssertFalse(RemovedAssets.shared.ids.contains(ids[0]))
        XCTAssertFalse(DeletedServerAssetRegistry.shared.suppressedIDs.contains(ids[0]))
        XCTAssertEqual(manager.assetMutationRevision, revision)
    }

    func testPermanentDeleteAlsoExcludesAssetFromTrash() async throws {
        let deleted = AssetLite(detail(ids[0]))
        try await repository.delete([ids[0]], force: true)

        XCTAssertNil(reopen().getCachedAsset(id: ids[0]))
        XCTAssertTrue(RemovedAssets.shared.filter([deleted], scope: .trash).isEmpty)
        XCTAssertEqual(try body(XCTUnwrap(MockURLProtocol.lastRequest))["force"] as? Bool, true)
    }

    func testSuccessfulEditsAndRevertInvalidateOnlyTheirDetailSnapshot() async throws {
        stub(status: 200, json: "{\"assetId\":\"\(ids[0])\"}")
        try await repository.applyEdits([AssetEditCommand(payload: .crop(x: 0, y: 0, width: 100, height: 100))], to: ids[0])
        XCTAssertNil(snapshot(ids[0]))
        XCTAssertNotNil(snapshot(ids[1]))
        LocalSnapshot.save(detail(ids[0]), for: LocalSnapshot.Key.assetDetail(ids[0]))
        stub(status: 204)

        try await repository.removeEdits(from: ids[0])

        XCTAssertNil(snapshot(ids[0]))
        XCTAssertNotNil(snapshot(ids[1]))
        XCTAssertEqual(try XCTUnwrap(reopen().getCachedAsset(id: ids[0])).ratio, 1.5,
            "Edit commands cannot replace original EXIF dimensions with guessed geometry")
        XCTAssertEqual(MockURLProtocol.lastRequest?.url?.path, "/api/assets/\(ids[0])/edits")
        XCTAssertEqual(MockURLProtocol.lastRequest?.httpMethod, "DELETE")
    }

    func testRejectedEditsKeepTheOfflineDetailSnapshot() async throws {
        stub(status: 500)
        await assertRejected { try await self.repository.applyEdits([], to: self.ids[0]) }
        await assertRejected { try await self.repository.removeEdits(from: self.ids[0]) }
        XCTAssertNotNil(snapshot(ids[0]))
        XCTAssertNotNil(snapshot(ids[1]))
    }

    func testMutationRevisionPublishesAfterPersistence() async throws {
        let changed = expectation(description: "mutation revision sees committed favorite")
        let observed = ObservedFavorite()
        withObservationTracking {
            _ = manager.assetMutationRevision
        } onChange: {
            MainActor.assumeIsolated {
                observed.value = self.reopen().getCachedAsset(id: self.ids[0])?.isFavorite
                changed.fulfill()
            }
        }

        try await repository.toggleFavorite(ids[0], to: true)
        await fulfillment(of: [changed], timeout: 2)

        XCTAssertEqual(observed.value, true)
    }

    func testAcceptedMutationForUncachedAssetPublishesWithoutInventingATimelineRow() async throws {
        let id = UUID().uuidString
        let revision = manager.assetMutationRevision
        let before = manager.timelineAssets().map(\.asset.id)
        let changed = expectation(description: "collections can refresh an asset not synced yet")
        withObservationTracking {
            _ = manager.assetMutationRevision
        } onChange: { changed.fulfill() }

        try await repository.toggleFavorite(id, to: true)
        await fulfillment(of: [changed], timeout: 2)

        XCTAssertNotEqual(manager.assetMutationRevision, revision)
        XCTAssertNil(reopen().getCachedAsset(id: id))
        XCTAssertEqual(manager.timelineAssets().map(\.asset.id), before)
        XCTAssertEqual(MockURLProtocol.lastRequest?.url?.path, "/api/assets/\(id)")
    }

    private func reopen() -> SwiftDataManager {
        SwiftDataManager(storeURL: directory.appendingPathComponent("test.store"),
            backupJournalURL: directory.appendingPathComponent("backup.json"))
    }

    private func detail(_ id: String) -> AssetResponseDTO {
        let fields = try! JSONDecoder().decode(ExifDTO.self, from: Data(#"{"description":"before","make":"Camera"}"#.utf8))
        return AssetResponseDTO(id: id, type: "IMAGE", originalFileName: "photo.jpg", fileCreatedAt: oldDate,
            isFavorite: false, isArchived: false, isTrashed: false, duration: nil, thumbhash: "thumbhash",
            localDateTime: oldDate, exifInfo: fields, people: nil)
    }

    private func snapshot(_ id: String) -> AssetResponseDTO? {
        LocalSnapshot.load(AssetResponseDTO.self, for: LocalSnapshot.Key.assetDetail(id))
    }

    private func stub(status: Int, json: String = "") {
        MockURLProtocol.mockData = Data(json.utf8)
        MockURLProtocol.mockResponse = HTTPURLResponse(url: URL(string: "https://cache-tests.example/api")!,
            statusCode: status, httpVersion: nil, headerFields: nil)
        MockURLProtocol.responseProvider = nil
    }

    private func body(_ request: URLRequest) throws -> [String: Any] {
        let data = try XCTUnwrap(request.httpBody ?? MockURLProtocol.lastRequestBody)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func exif(_ asset: CachedAsset) throws -> [String: Any] {
        let data = try XCTUnwrap(asset.exifData?.data(using: .utf8))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func assertRejected(_ operation: () async throws -> Void, file: StaticString = #filePath, line: UInt = #line) async {
        do {
            try await operation()
            XCTFail("Rejected server mutation must throw", file: file, line: line)
        } catch let error as APIError {
            guard case .server(let status, _) = error else {
                return XCTFail("Expected HTTP rejection, received \(error)", file: file, line: line)
            }
            XCTAssertEqual(status, (MockURLProtocol.mockResponse as? HTTPURLResponse)?.statusCode, file: file, line: line)
        } catch {
            XCTFail("Unexpected failure: \(error)", file: file, line: line)
        }
    }
}

@MainActor
private final class ObservedFavorite { var value: Bool? }
