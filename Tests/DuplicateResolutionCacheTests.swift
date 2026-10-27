import Foundation
import XCTest
@testable import ImmichApp

@MainActor
final class DuplicateResolutionCacheTests: XCTestCase {
    private var directories: [URL] = []
    private var snapshotIDs: [String] = []

    override func setUp() async throws {
        MockURLProtocol.reset()
        RemovedAssets.shared.clear()
        DeletedServerAssetRegistry.shared.clear()
    }

    override func tearDown() async throws {
        MockURLProtocol.reset()
        RemovedAssets.shared.clear()
        DeletedServerAssetRegistry.shared.clear()
        for id in snapshotIDs { LocalSnapshot.remove(LocalSnapshot.Key.assetDetail(id)) }
        snapshotIDs.removeAll()
        for directory in directories { try? FileManager.default.removeItem(at: directory) }
        directories.removeAll()
    }

    func testBothResolutionAPIsPurgeOnlyTrashedAssetsAndPreserveDeviceMappings() async throws {
        for usesV3 in [false, true] {
            let fixture = try fixture(usesV3: usesV3)
            stub(groupID: fixture.group.id)

            await fixture.model.resolve(fixture.group, keeping: [fixture.kept])

            XCTAssertTrue(fixture.model.groups.isEmpty)
            XCTAssertNil(fixture.model.actionError)
            let reopened = fixture.reopen()
            XCTAssertNil(reopened.getCachedAsset(id: fixture.trashed))
            XCTAssertEqual(reopened.cachedAssetCount(), 2)
            for id in [fixture.kept, fixture.unrelated] {
                XCTAssertEqual(reopened.getCachedAsset(id: id)?.thumbhash, "hash-\(id)")
                XCTAssertEqual(snapshot(id)?.id, id)
                XCTAssertFalse(RemovedAssets.shared.ids.contains(id))
                XCTAssertFalse(DeletedServerAssetRegistry.shared.suppressedIDs.contains(id))
            }
            for id in [fixture.kept, fixture.trashed] {
                XCTAssertEqual(reopened.getBackupRecord(localIdentifier: "local-\(id)")?.assetId, id)
            }
            XCTAssertNil(snapshot(fixture.trashed))
            let photo = AssetLite(makeTestAsset(id: fixture.trashed))
            XCTAssertTrue(RemovedAssets.shared.filter([photo]).isEmpty)
            XCTAssertEqual(RemovedAssets.shared.filter([photo], scope: .trash).map(\.id), [fixture.trashed])
            XCTAssertTrue(DeletedServerAssetRegistry.shared.isTrashed(fixture.trashed))
        }
    }

    func testRejectedV3GroupLeavesCacheSnapshotsAndRemovalStateUntouched() async throws {
        let fixture = try fixture(usesV3: true)
        let revision = fixture.manager.assetMutationRevision
        stub(groupID: fixture.group.id, success: false)

        await fixture.model.resolve(fixture.group, keeping: [fixture.kept])

        XCTAssertEqual(fixture.model.groups.map(\.id), [fixture.group.id])
        XCTAssertEqual(fixture.model.actionError, "Resolution rejected")
        XCTAssertEqual(fixture.manager.assetMutationRevision, revision)
        for id in [fixture.kept, fixture.trashed, fixture.unrelated] {
            XCTAssertNotNil(fixture.reopen().getCachedAsset(id: id))
            XCTAssertEqual(snapshot(id)?.id, id)
            XCTAssertFalse(RemovedAssets.shared.ids.contains(id))
            XCTAssertFalse(DeletedServerAssetRegistry.shared.suppressedIDs.contains(id))
        }
    }

    func testKeepAllDismissesOnlyTheGroupWithoutRemovingItsPhotos() async throws {
        let fixture = try fixture(usesV3: true)
        let revision = fixture.manager.assetMutationRevision
        stub(groupID: fixture.group.id)

        await fixture.model.keepAll(fixture.group)

        XCTAssertTrue(fixture.model.groups.isEmpty)
        XCTAssertNil(fixture.model.actionError)
        XCTAssertEqual(fixture.manager.assetMutationRevision, revision)
        XCTAssertEqual(fixture.reopen().cachedAssetCount(), 3)
        for id in [fixture.kept, fixture.trashed] {
            XCTAssertEqual(snapshot(id)?.id, id)
            XCTAssertFalse(RemovedAssets.shared.ids.contains(id))
            XCTAssertFalse(DeletedServerAssetRegistry.shared.suppressedIDs.contains(id))
        }
    }

    private func fixture(usesV3: Bool) throws -> Fixture {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("duplicate-cache-\(UUID())")
        directories.append(directory)
        let manager = SwiftDataManager(storeURL: directory.appendingPathComponent("test.store"),
            backupJournalURL: directory.appendingPathComponent("backup.json"))
        XCTAssertTrue(manager.isPersistentStoreAvailable)
        let ids = (0..<3).map { _ in UUID().uuidString }
        snapshotIDs.append(contentsOf: ids)
        for id in ids {
            try manager.insertOrUpdateCachedAsset(CachedAsset(id: id, assetId: id, type: "IMAGE", thumbhash: "hash-\(id)"))
            try manager.upsertBackupRecord(assetID: id, checksum: "checksum-\(id)", localIdentifier: "local-\(id)")
            LocalSnapshot.save(makeTestAsset(id: id), for: LocalSnapshot.Key.assetDetail(id))
        }
        let session = MockSessionManager()
        try session.setServer("https://duplicate-cache.example")
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let api = APIClient(session: session, urlSession: URLSession(configuration: configuration))
        let repository = DuplicateRepository(api: api, dataManager: manager)
        let group = DuplicateGroupDTO(duplicateId: UUID().uuidString,
            assets: ids.prefix(2).map { makeTestAsset(id: $0) })
        let model = DuplicatesViewModel(repository: repository,
            assetRepository: AssetDetailRepository(api: api, dataManager: manager), usesResolveEndpoint: usesV3,
            dataManager: manager)
        model.groups = [group]
        return Fixture(directory: directory, manager: manager, model: model, group: group,
                       kept: ids[0], trashed: ids[1], unrelated: ids[2])
    }

    private func stub(groupID: String, success: Bool = true) {
        MockURLProtocol.responseProvider = { request in
            let resolves = request.url?.path == "/api/duplicates/resolve"
            let data = resolves ? Data("[{\"id\":\"\(groupID)\",\"success\":\(success),\"errorMessage\":\"Resolution rejected\"}]".utf8) : Data()
            return (data, HTTPURLResponse(url: request.url!, statusCode: resolves ? 200 : 204,
                                         httpVersion: nil, headerFields: nil), nil)
        }
    }

    private func snapshot(_ id: String) -> AssetResponseDTO? {
        LocalSnapshot.load(AssetResponseDTO.self, for: LocalSnapshot.Key.assetDetail(id))
    }

    private struct Fixture {
        let directory: URL
        let manager: SwiftDataManager
        let model: DuplicatesViewModel
        let group: DuplicateGroupDTO
        let kept: String
        let trashed: String
        let unrelated: String

        @MainActor
        func reopen() -> SwiftDataManager {
            SwiftDataManager(storeURL: directory.appendingPathComponent("test.store"),
                backupJournalURL: directory.appendingPathComponent("backup.json"))
        }
    }
}
