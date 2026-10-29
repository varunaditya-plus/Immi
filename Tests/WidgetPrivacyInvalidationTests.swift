import XCTest
@testable import ImmichApp

@MainActor
final class WidgetPrivacyInvalidationTests: XCTestCase {
    override func setUp() async throws {
        RemovedAssets.shared.clear()
        DeletedServerAssetRegistry.shared.clear()
    }

    override func tearDown() async throws {
        RemovedAssets.shared.clear()
        DeletedServerAssetRegistry.shared.clear()
    }

    func testClearingPublishedWidgetsRemovesSnapshotAndImageFiles() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let images = directory.appendingPathComponent("Widgets/old-generation")
        try FileManager.default.createDirectory(at: images, withIntermediateDirectories: true)
        try Data([1]).write(to: images.appendingPathComponent("private.image"))
        try Data("old snapshot".utf8).write(to: directory.appendingPathComponent("Widgets/snapshot.json"))

        WidgetSnapshotExporter.clear(container: directory)

        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("Widgets").path))
    }

    func testLateThumbnailCannotReplaceCurrentWidgetAfterPrivacyInvalidation() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let started = expectation(description: "Visible thumbnail request started")
        let gate = WidgetPrivacyGate(started: started)
        let api = try makeAPI(imageGate: gate)
        let export = Task { await WidgetSnapshotExporter.refresh(
            api: api, imageAPI: api, container: directory, selectedAlbumIDs: []) }
        await fulfillment(of: [started], timeout: 2)

        WidgetSnapshotExporter.clear(container: directory)
        let currentAPI = try makeAPI(assetID: "current-visible")
        await WidgetSnapshotExporter.refresh(api: currentAPI, imageAPI: currentAPI,
            container: directory, selectedAlbumIDs: [])
        let snapshotURL = directory.appendingPathComponent("Widgets/snapshot.json")
        let currentSnapshot = try Data(contentsOf: snapshotURL)
        await gate.release()
        await export.value

        let thumbnailCount = await api.thumbnailCount.value
        XCTAssertEqual(thumbnailCount, 1)
        XCTAssertEqual(try Data(contentsOf: snapshotURL), currentSnapshot)
        XCTAssertEqual(try imageNames(in: directory).count, 1)
    }

    func testUnavailablePrivacyStoreClearsPublishedWidgetsAndCannotExportVisibleMetadata() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let images = directory.appendingPathComponent("Widgets/old-generation")
        try FileManager.default.createDirectory(at: images, withIntermediateDirectories: true)
        try Data([1]).write(to: images.appendingPathComponent("private.image"))
        try Data("old snapshot".utf8).write(to: directory.appendingPathComponent("Widgets/snapshot.json"))
        let blockedParent = directory.appendingPathComponent("not-a-directory")
        try Data("blocked".utf8).write(to: blockedParent)
        let store = SwiftDataManager(storeURL: blockedParent.appendingPathComponent("test.store"),
            backupJournalURL: directory.appendingPathComponent("journal.json"))
        let api = try makeAPI(assetID: UUID().uuidString)
        XCTAssertFalse(store.isPersistentStoreAvailable)

        await WidgetSnapshotExporter.refresh(api: api, imageAPI: api, container: directory,
            selectedAlbumIDs: [], dataManager: store)

        let thumbnailCount = await api.thumbnailCount.value
        XCTAssertEqual(thumbnailCount, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("Widgets").path))
    }

    func testPersistentStoreAwaitingVisibilityRecoveryCannotRetainOrRepublishWidgets() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let storeURL = directory.appendingPathComponent("test.store")
        let journalURL = directory.appendingPathComponent("backup.json")
        do {
            let store = SwiftDataManager(storeURL: storeURL, backupJournalURL: journalURL)
            XCTAssertTrue(store.isVisibilityStateAvailable)
        }
        let marker = storeURL.appendingPathExtension("visibility-recovery")
        try Data().write(to: marker)
        let store = SwiftDataManager(storeURL: storeURL, backupJournalURL: journalURL)
        XCTAssertTrue(store.isPersistentStoreAvailable)
        XCTAssertTrue(store.requiresVisibilityRefresh)
        XCTAssertFalse(store.isVisibilityStateAvailable)
        let images = directory.appendingPathComponent("Widgets/old-generation")
        try FileManager.default.createDirectory(at: images, withIntermediateDirectories: true)
        try Data([1]).write(to: images.appendingPathComponent("private.image"))
        let snapshot = directory.appendingPathComponent("Widgets/snapshot.json")
        try Data("old snapshot".utf8).write(to: snapshot)
        XCTAssertTrue(FileManager.default.fileExists(atPath: snapshot.path))
        let api = try makeAPI(assetID: UUID().uuidString)

        await WidgetSnapshotExporter.refresh(api: api, imageAPI: api, container: directory,
            selectedAlbumIDs: [], dataManager: store)

        let thumbnailCount = await api.thumbnailCount.value
        XCTAssertEqual(thumbnailCount, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("Widgets").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: marker.path))
    }

    func testCurrentThumbnailStillPublishesReferencedImageBytes() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let started = expectation(description: "Current thumbnail request started")
        let gate = WidgetPrivacyGate(started: started)
        let api = try makeAPI(imageGate: gate)
        let export = Task { await WidgetSnapshotExporter.refresh(
            api: api, imageAPI: api, container: directory, selectedAlbumIDs: []) }
        await fulfillment(of: [started], timeout: 2)
        await gate.release()
        await export.value

        let names = try imageNames(in: directory)
        XCTAssertEqual(names.count, 1)
        let file = directory.appendingPathComponent("Widgets").appendingPathComponent(try XCTUnwrap(names.first))
        XCTAssertEqual(try Data(contentsOf: file), Data([1, 2, 3]))
    }

    func testExportedMemoryIncludesRawDateAndAgeForWidgetLocalization() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let api = try makeAPI(assetID: UUID().uuidString, includesCollections: true)

        await WidgetSnapshotExporter.refresh(api: api, imageAPI: api, container: directory, selectedAlbumIDs: [])

        let data = try Data(contentsOf: directory.appendingPathComponent("Widgets/snapshot.json"))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let memories = try XCTUnwrap(object["memories"] as? [[String: Any]])
        let memory = try XCTUnwrap(memories.first)
        let year = try XCTUnwrap(memory["yearsAgo"] as? Int)
        let date = try XCTUnwrap(memory["memoryAt"] as? String)
        let instant = try XCTUnwrap(ISO8601DateFormatter().date(from: date))
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .gmt
        XCTAssertEqual(year, Calendar(identifier: .gregorian).component(.year, from: Date()) - 2020)
        XCTAssertEqual(calendar.component(.year, from: instant), 2020)
        XCTAssertNotNil(memory["title"], "Keep the captions readable by an older widget process")
        XCTAssertNotNil(memory["subtitle"])
        XCTAssertNotNil(memory["imageName"])
    }

    func testLateMetadataCannotStartAnExportAfterPrivacyInvalidation() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let started = expectation(description: "Old metadata request started")
        let gate = WidgetPrivacyGate(started: started)
        let api = try makeAPI(metadataGate: gate)
        let export = Task { await WidgetSnapshotExporter.refresh(
            api: api, imageAPI: api, container: directory, selectedAlbumIDs: []) }
        await fulfillment(of: [started], timeout: 2)
        WidgetSnapshotExporter.clear(container: directory)
        await gate.release()
        await export.value

        let thumbnailCount = await api.thumbnailCount.value
        XCTAssertEqual(thumbnailCount, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("Widgets").path))
    }

    func testLateThumbnailCannotReplaceCurrentWidgetAfterAccountGenerationChanges() async throws {
        let directory = try temporaryDirectory()
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let started = expectation(description: "Previous account thumbnail started")
        let gate = WidgetPrivacyGate(started: started)
        let oldAPI = try makeAPI(imageGate: gate)
        let oldExport = Task {
            await WidgetSnapshotExporter.refresh(api: oldAPI, imageAPI: oldAPI,
                container: directory, selectedAlbumIDs: [])
        }
        addTeardownBlock {
            await gate.close()
            await oldExport.value
        }
        await fulfillment(of: [started], timeout: 2)

        // Advance account ownership without invalidating widget visibility.
        // The fake response bypasses APIClient, so publication must check it too.
        LocalSnapshot.clearAll()
        let currentAPI = try makeAPI(assetID: "current-account-visible")
        await WidgetSnapshotExporter.refresh(api: currentAPI, imageAPI: currentAPI,
            container: directory, selectedAlbumIDs: [])
        let snapshotURL = directory.appendingPathComponent("Widgets/snapshot.json")
        let currentSnapshot = try Data(contentsOf: snapshotURL)
        await gate.release()
        await oldExport.value

        let oldThumbnailCount = await oldAPI.thumbnailCount.value
        XCTAssertEqual(oldThumbnailCount, 1)
        XCTAssertEqual(try Data(contentsOf: snapshotURL), currentSnapshot)
        let names = try imageNames(in: directory)
        XCTAssertEqual(names.count, 1)
        let image = directory.appendingPathComponent("Widgets")
            .appendingPathComponent(try XCTUnwrap(names.first))
        XCTAssertEqual(try Data(contentsOf: image), Data([1, 2, 3]))
    }

    func testLateMetadataCannotStartAnExportAfterAccountGenerationChanges() async throws {
        let directory = try temporaryDirectory()
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let started = expectation(description: "Previous account metadata started")
        let gate = WidgetPrivacyGate(started: started)
        let api = try makeAPI(metadataGate: gate)
        let export = Task {
            await WidgetSnapshotExporter.refresh(api: api, imageAPI: api,
                container: directory, selectedAlbumIDs: [])
        }
        addTeardownBlock {
            await gate.close()
            await export.value
        }
        await fulfillment(of: [started], timeout: 2)

        LocalSnapshot.clearAll()
        await gate.release()
        await export.value

        let thumbnailCount = await api.thumbnailCount.value
        XCTAssertEqual(thumbnailCount, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("Widgets").path))
    }

    func testProtectedPrivateIDsOverrideStaleVisibleMetadata() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SwiftDataManager(storeURL: directory.appendingPathComponent("test.store"),
            backupJournalURL: directory.appendingPathComponent("backup.json"))
        try store.setTimelineVisibility(["was-visible"], inTimeline: false)
        let api = try makeAPI()

        await WidgetSnapshotExporter.refresh(api: api, imageAPI: api, container: directory,
            selectedAlbumIDs: [], dataManager: store)

        let thumbnailCount = await api.thumbnailCount.value
        XCTAssertEqual(thumbnailCount, 0)
        XCTAssertTrue(try imageNames(in: directory).isEmpty)
    }

    func testPurgePreventsLateThumbnailFromReplacingTheCurrentWidget() async throws {
        let directory = try temporaryDirectory()
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let store = SwiftDataManager(storeURL: directory.appendingPathComponent("test.store"),
            backupJournalURL: directory.appendingPathComponent("backup.json"))
        let started = expectation(description: "Deleted photo thumbnail started")
        let gate = WidgetPrivacyGate(started: started)
        let oldAPI = try makeAPI(imageGate: gate, assetID: "deleted-photo")
        let export = Task {
            await WidgetSnapshotExporter.refresh(api: oldAPI, imageAPI: oldAPI,
                container: directory, selectedAlbumIDs: [], dataManager: store)
        }
        addTeardownBlock {
            await gate.close()
            await export.value
        }
        await fulfillment(of: [started], timeout: 2)

        try store.purgeAssets(["deleted-photo"], reason: .trashed)
        XCTAssertTrue(RemovedAssets.shared.ids.contains("deleted-photo"))
        let currentAPI = try makeAPI(assetID: "current-photo")
        await WidgetSnapshotExporter.refresh(api: currentAPI, imageAPI: currentAPI,
            container: directory, selectedAlbumIDs: [], dataManager: store)
        let snapshotURL = directory.appendingPathComponent("Widgets/snapshot.json")
        let currentSnapshot = try Data(contentsOf: snapshotURL)
        await gate.release()
        await export.value

        XCTAssertEqual(try Data(contentsOf: snapshotURL), currentSnapshot)
        let names = try imageNames(in: directory)
        XCTAssertEqual(names.count, 1)
        let image = directory.appendingPathComponent("Widgets")
            .appendingPathComponent(try XCTUnwrap(names.first))
        XCTAssertEqual(try Data(contentsOf: image), Data([1, 2, 3]))
        let generations = try FileManager.default.contentsOfDirectory(
            at: directory.appendingPathComponent("Widgets"), includingPropertiesForKeys: nil)
            .filter(\.hasDirectoryPath)
        XCTAssertEqual(generations.count, 1, "An invalidated export must remove its staged images")
    }

    func testSyncDeletionPreventsHeldMetadataFromStartingAnExport() async throws {
        let directory = try temporaryDirectory()
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let store = SwiftDataManager(storeURL: directory.appendingPathComponent("test.store"),
            backupJournalURL: directory.appendingPathComponent("backup.json"))
        let started = expectation(description: "Deleted photo metadata started")
        let gate = WidgetPrivacyGate(started: started)
        let api = try makeAPI(metadataGate: gate, assetID: "deleted-photo")
        let export = Task {
            await WidgetSnapshotExporter.refresh(api: api, imageAPI: api,
                container: directory, selectedAlbumIDs: [], dataManager: store)
        }
        addTeardownBlock {
            await gate.close()
            await export.value
        }
        await fulfillment(of: [started], timeout: 2)

        try store.applySyncBatch(upserts: [], deletedIds: ["deleted-photo"])
        XCTAssertTrue(RemovedAssets.shared.ids.contains("deleted-photo"))
        await gate.release()
        await export.value

        let count = await api.thumbnailCount.value
        XCTAssertEqual(count, 0)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: directory.appendingPathComponent("Widgets").path))
    }

    func testRemovedIDsCannotReturnThroughStaleFavoritesAlbumsOrMemoryCovers() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SwiftDataManager(storeURL: directory.appendingPathComponent("test.store"),
            backupJournalURL: directory.appendingPathComponent("backup.json"))
        RemovedAssets.shared.remove(["unavailable-photo"])
        DeletedServerAssetRegistry.shared.record(["trashed-photo"], permanently: false)
        DeletedServerAssetRegistry.shared.record(["deleted-photo"], permanently: true)
        let api = try makeAPI(assetID: "unavailable-photo",
            additionalAssetIDs: ["trashed-photo", "deleted-photo", "current-photo"],
            includesCollections: true)

        await WidgetSnapshotExporter.refresh(api: api, imageAPI: api, container: directory,
            selectedAlbumIDs: ["widget-album"], dataManager: store)

        let requestedIDs = await api.thumbnailCount.assetIDs
        XCTAssertEqual(requestedIDs.count, 3, "Current favorites, album photos, and memory covers still export")
        XCTAssertTrue(requestedIDs.allSatisfy { $0 == "current-photo" })
        let data = try Data(contentsOf: directory.appendingPathComponent("Widgets/snapshot.json"))
        let snapshot = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let albums = try XCTUnwrap(snapshot["albums"] as? [[String: Any]])
        XCTAssertEqual(albums.count, 2)
        XCTAssertEqual(albums.compactMap { ($0["imageNames"] as? [String])?.count }, [1, 1])
        let memories = try XCTUnwrap(snapshot["memories"] as? [[String: Any]])
        XCTAssertEqual(memories.count, 1)
        XCTAssertNotNil(memories.first?["imageName"] as? String)
    }

    func testFreshTrashEvidenceInvalidatesAHeldWidgetThumbnail() async throws {
        let directory = try temporaryDirectory()
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let store = SwiftDataManager(storeURL: directory.appendingPathComponent("test.store"),
            backupJournalURL: directory.appendingPathComponent("backup.json"))
        let started = expectation(description: "The old widget thumbnail is held")
        let gate = WidgetPrivacyGate(started: started)
        let oldAPI = try makeAPI(imageGate: gate, assetID: "newly-discovered-trash")
        let export = Task {
            await WidgetSnapshotExporter.refresh(api: oldAPI, imageAPI: oldAPI,
                container: directory, selectedAlbumIDs: [], dataManager: store)
        }
        addTeardownBlock { await gate.close(); await export.value }
        await fulfillment(of: [started], timeout: 2)

        let trashed = try await readTrash("newly-discovered-trash", using: store)
        XCTAssertEqual(trashed.map(\.id), ["newly-discovered-trash"])
        XCTAssertTrue(DeletedServerAssetRegistry.shared.isTrashed("newly-discovered-trash"))
        let currentAPI = try makeAPI(assetID: "current-widget-photo")
        await WidgetSnapshotExporter.refresh(api: currentAPI, imageAPI: currentAPI,
            container: directory, selectedAlbumIDs: [], dataManager: store)
        let snapshotURL = directory.appendingPathComponent("Widgets/snapshot.json")
        let currentSnapshot = try Data(contentsOf: snapshotURL)
        await gate.release()
        await export.value

        XCTAssertEqual(try Data(contentsOf: snapshotURL), currentSnapshot,
            "A thumbnail for a photo just discovered in Trash cannot replace the current widget")
        let generations = try FileManager.default.contentsOfDirectory(
            at: directory.appendingPathComponent("Widgets"), includingPropertiesForKeys: nil)
            .filter(\.hasDirectoryPath)
        XCTAssertEqual(generations.count, 1, "The invalidated widget must discard its staged image files")
    }

    func testUnchangedTrashEvidenceDoesNotInvalidateAnUnrelatedCurrentWidget() async throws {
        let directory = try temporaryDirectory()
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let store = SwiftDataManager(storeURL: directory.appendingPathComponent("test.store"),
            backupJournalURL: directory.appendingPathComponent("backup.json"))
        _ = try await readTrash("already-known-trash", using: store)
        let started = expectation(description: "The current widget thumbnail is held")
        let gate = WidgetPrivacyGate(started: started)
        let api = try makeAPI(imageGate: gate, assetID: "unrelated-current-photo")
        let export = Task {
            await WidgetSnapshotExporter.refresh(api: api, imageAPI: api,
                container: directory, selectedAlbumIDs: [], dataManager: store)
        }
        addTeardownBlock { await gate.close(); await export.value }
        await fulfillment(of: [started], timeout: 2)

        _ = try await readTrash("already-known-trash", using: store)
        await gate.release()
        await export.value

        XCTAssertEqual(try imageNames(in: directory).count, 1,
            "Reopening unchanged Trash must not blank an unrelated current widget export")
    }

    private func readTrash(_ id: String, using store: SwiftDataManager) async throws -> [AssetResponseDTO] {
        MockURLProtocol.reset()
        defer { MockURLProtocol.reset() }
        let session = MockSessionManager()
        try session.setServer("https://trash-widget.example")
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let transport = URLSession(configuration: configuration)
        defer { transport.invalidateAndCancel() }
        MockURLProtocol.responseProvider = { request in
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.url?.path, "/api/search/metadata")
            let asset: [String: Any] = ["id": id, "type": "IMAGE", "originalFileName": "photo.jpg",
                "fileCreatedAt": "2020-01-01T00:00:00Z", "localDateTime": "2020-01-01T00:00:00Z",
                "isFavorite": false, "isArchived": false, "isTrashed": true, "visibility": "timeline"]
            let data = try! JSONSerialization.data(withJSONObject: ["assets": ["items": [asset],
                "total": 1, "nextPage": NSNull()]])
            return (data, HTTPURLResponse(url: request.url!, statusCode: 200,
                httpVersion: nil, headerFields: nil), nil)
        }
        return try await TrashRepository(api: APIClient(session: session, urlSession: transport),
            dataManager: store).assets()
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("widget-invalidation-\(UUID())")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func makeAPI(
        imageGate: WidgetPrivacyGate? = nil, metadataGate: WidgetPrivacyGate? = nil,
        assetID: String = "was-visible", additionalAssetIDs: [String] = [],
        includesCollections: Bool = false
    ) throws -> WidgetPrivacyAPI {
        let session = MockSessionManager()
        try session.setServer("https://widget-privacy.test")
        return WidgetPrivacyAPI(session: session, imageGate: imageGate, metadataGate: metadataGate,
            assetIDs: [assetID] + additionalAssetIDs, includesCollections: includesCollections)
    }

    private func imageNames(in directory: URL) throws -> [String] {
        let data = try Data(contentsOf: directory.appendingPathComponent("Widgets/snapshot.json"))
        let snapshot = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let albums = try XCTUnwrap(snapshot["albums"] as? [[String: Any]])
        return try XCTUnwrap(albums.first?["imageNames"] as? [String])
    }
}

private actor WidgetPrivacyGate {
    let started: XCTestExpectation
    private var continuation: CheckedContinuation<Void, Never>?
    private var isClosed = false
    init(started: XCTestExpectation) { self.started = started }
    func wait() async {
        guard !isClosed else { return }
        await withCheckedContinuation {
            continuation = $0
            started.fulfill()
        }
    }
    func release() {
        XCTAssertNotNil(continuation, "The export must reach its response boundary first")
        continuation?.resume()
        continuation = nil
    }
    func close() {
        isClosed = true
        continuation?.resume()
        continuation = nil
    }
}

private actor WidgetThumbnailCount {
    private(set) var assetIDs: [String] = []
    var value: Int { assetIDs.count }
    func record(_ assetID: String) { assetIDs.append(assetID) }
}

private final class WidgetPrivacyAPI: APIClient {
    let thumbnailCount = WidgetThumbnailCount()
    private let imageGate: WidgetPrivacyGate?
    private let metadataGate: WidgetPrivacyGate?
    private let assetIDs: [String]
    private let includesCollections: Bool
    @MainActor
    init(session: SessionManager, imageGate: WidgetPrivacyGate?, metadataGate: WidgetPrivacyGate?,
         assetIDs: [String], includesCollections: Bool) {
        self.imageGate = imageGate
        self.metadataGate = metadataGate
        self.assetIDs = assetIDs
        self.includesCollections = includesCollections
        super.init(session: session)
    }
    override func send<T: Decodable>(_ endpoint: Endpoint) async throws -> T {
        let assets: [[String: Any]] = assetIDs.map { id in [
            "id": id, "type": "IMAGE", "originalFileName": "photo.jpg",
            "fileCreatedAt": "2020-01-01T00:00:00Z", "localDateTime": "2020-01-01T00:00:00Z",
            "isFavorite": true, "isArchived": false, "isTrashed": false, "visibility": "timeline",
        ] }
        let object: Any
        switch endpoint.path {
        case "/albums":
            object = includesCollections
                ? [["id": "widget-album", "albumName": "Album", "assetCount": assetIDs.count]] : []
        case "/memories":
            let today = Calendar.current.dateComponents([.month, .day], from: Date())
            let memoryAt = String(format: "2020-%02d-%02dT00:00:00Z",
                try XCTUnwrap(today.month), try XCTUnwrap(today.day))
            object = includesCollections
                ? [["id": "widget-memory", "type": "on_this_day", "memoryAt": memoryAt, "assets": assets]] : []
        case "/search/metadata":
            await metadataGate?.wait()
            object = ["assets": ["items": assets, "total": assets.count, "nextPage": NSNull()]]
        default: throw URLError(.unsupportedURL)
        }
        let data = try JSONSerialization.data(withJSONObject: object)
        return try JSONDecoder.immich.decode(T.self, from: data)
    }
    override func rawData(_ endpoint: Endpoint) async throws -> Data {
        let components = endpoint.path.split(separator: "/")
        guard components.count == 3 else { throw URLError(.unsupportedURL) }
        let assetID = String(components[1])
        XCTAssertEqual(endpoint.path, "/assets/\(assetID)/thumbnail")
        XCTAssertTrue(assetIDs.contains(assetID))
        await thumbnailCount.record(assetID)
        await imageGate?.wait()
        return Data([1, 2, 3])
    }
}
