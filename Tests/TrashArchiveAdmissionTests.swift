import Foundation
import XCTest
@testable import ImmichApp

@MainActor
final class TrashArchiveAdmissionTests: XCTestCase {
    private var directory: URL!
    private var manager: SwiftDataManager!
    private var session: MockSessionManager!
    private var transport: URLSession!

    override func setUp() async throws {
        try await super.setUp()
        MockURLProtocol.reset()
        RemovedAssets.shared.clear()
        DeletedServerAssetRegistry.shared.clear()
        LocalSnapshot.remove(LocalSnapshot.Key.trash)
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("trash-archive-admission-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        manager = SwiftDataManager(storeURL: directory.appendingPathComponent("test.store"),
            backupJournalURL: directory.appendingPathComponent("backup.json"))
        XCTAssertTrue(manager.isPersistentStoreAvailable)
        session = MockSessionManager()
        try session.setServer("https://trash-archive-admission.example")
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        transport = URLSession(configuration: configuration)
    }

    override func tearDown() async throws {
        transport?.invalidateAndCancel()
        transport = nil
        session = nil
        manager = nil
        RemovedAssets.shared.clear()
        DeletedServerAssetRegistry.shared.clear()
        LocalSnapshot.remove(LocalSnapshot.Key.trash)
        MockURLProtocol.reset()
        try? FileManager.default.removeItem(at: directory)
        directory = nil
        try await super.tearDown()
    }

    func testRestoreAllFromAnOlderEmptyWindowPreservesNewlyDiscoveredArchives() async throws {
        let ids = ["explicit-archive", "legacy-archive"]
        for id in ids {
            try manager.restoreToTimeline([photo(id)])
            try manager.linkDeviceAsset(localIdentifier: "local-\(id)", to: id)
        }
        XCTAssertTrue(manager.archivedAssetIDs.isEmpty,
            "The later Trash read must supply archive evidence missing from the stale public cache")
        let api = APIClient(session: session, urlSession: transport)
        let repository = TrashRepository(api: api, dataManager: manager)
        let older = model(api: api) { [] }
        await older.load()
        XCTAssertTrue(older.assets.isEmpty)
        var paths: [String] = []
        MockURLProtocol.responseProvider = { request in
            let path = request.url?.path ?? ""
            paths.append(path)
            if path == "/api/search/metadata" {
                XCTAssertEqual(request.httpMethod, "POST")
                return Self.response(request, items: [
                    Self.archived("explicit-archive", visibility: "archive"),
                    Self.archived("legacy-archive", visibility: nil),
                ])
            }
            XCTAssertEqual(path, "/api/trash/restore")
            XCTAssertEqual(request.httpMethod, "POST")
            return (Data(), HTTPURLResponse(url: request.url!, statusCode: 204,
                httpVersion: nil, headerFields: nil), nil)
        }
        let newer = model(api: api) { try await repository.assets().map(AssetLite.init) }
        await newer.load()
        XCTAssertEqual(newer.assets.map(\.id), ids)
        XCTAssertEqual(newer.assets.map(\.trashVisibility), ["archive", "archive"])
        XCTAssertEqual(DeletedServerAssetRegistry.shared.trashedIDs, Set(ids))
        XCTAssertTrue(older.assets.isEmpty, "The bulk action has no archive hints in its own retained input")

        let restored = await older.restoreAll(using: repository)

        XCTAssertTrue(restored)
        XCTAssertEqual(paths, ["/api/search/metadata", "/api/trash/restore"])
        XCTAssertTrue(DeletedServerAssetRegistry().suppressedIDs.isEmpty,
            "Archive visibility must survive without retaining obsolete deletion markers")
        XCTAssertEqual(LocalSnapshot.load([AssetLite].self, for: LocalSnapshot.Key.trash)?.count, 0)
        assertArchiveVisibility(in: manager, ids: ids)
        RemovedAssets.shared.clear()
        let reopened = SwiftDataManager(storeURL: directory.appendingPathComponent("test.store"),
            backupJournalURL: directory.appendingPathComponent("backup.json"))
        assertArchiveVisibility(in: reopened, ids: ids)
    }

    private func assertArchiveVisibility(in store: SwiftDataManager, ids: [String],
        file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(store.archivedAssetIDs, Set(ids), file: file, line: line)
        XCTAssertTrue(store.privateAssetIDs.isEmpty, "Archived photos must remain available in ordinary collections",
            file: file, line: line)
        XCTAssertTrue(store.timelineAssets().isEmpty, "Stale public rows must stay out of the timeline",
            file: file, line: line)
        let timeline = AssetVisibilityPolicy(scope: .timeline, dataManager: store)
        let collection = AssetVisibilityPolicy(dataManager: store)
        for id in ids {
            XCTAssertEqual(store.getCachedAsset(id: id)?.isArchived, true, file: file, line: line)
            XCTAssertFalse(timeline.allows(id: id), file: file, line: line)
            XCTAssertFalse(timeline.allows(id: "device:local-\(id)"), file: file, line: line)
            XCTAssertTrue(collection.allows(id: id), file: file, line: line)
            XCTAssertTrue(collection.allows(id: "device:local-\(id)"), file: file, line: line)
        }
    }

    private func photo(_ id: String) -> AssetLite {
        AssetLite(id: id, isVideo: false, ratio: 1.5, thumbhash: nil,
            createdAt: Date(timeIntervalSince1970: 1_760_000_000))
    }

    private func model(api: APIClient, loader: @escaping () async throws -> [AssetLite]) -> AssetGridViewModel {
        AssetGridViewModel(assetRepo: AssetDetailRepository(api: api, dataManager: manager),
            albumRepo: AlbumRepository(api: api), snapshotKey: LocalSnapshot.Key.trash,
            dataManager: manager, loader: loader)
    }

    private nonisolated static func archived(_ id: String, visibility: String?) -> [String: Any] {
        var value: [String: Any] = ["id": id, "type": "IMAGE", "originalFileName": "\(id).jpg",
            "fileCreatedAt": "2026-10-01T00:00:00.000Z", "localDateTime": "2026-10-01T00:00:00.000Z",
            "isFavorite": false, "isArchived": true, "isTrashed": true]
        if let visibility { value["visibility"] = visibility }
        return value
    }

    private nonisolated static func response(_ request: URLRequest, items: [[String: Any]]) ->
        (Data?, HTTPURLResponse?, Error?) {
        let data = try! JSONSerialization.data(withJSONObject: ["assets": ["items": items,
            "total": items.count, "nextPage": NSNull()]])
        return (data, HTTPURLResponse(url: request.url!, statusCode: 200,
            httpVersion: nil, headerFields: nil), nil)
    }
}
