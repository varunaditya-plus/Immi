import XCTest
@testable import ImmichApp

@MainActor
final class WidgetPrivacyInvalidationTests: XCTestCase {
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

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("widget-invalidation-\(UUID())")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func makeAPI(
        imageGate: WidgetPrivacyGate? = nil, metadataGate: WidgetPrivacyGate? = nil,
        assetID: String = "was-visible"
    ) throws -> WidgetPrivacyAPI {
        let session = MockSessionManager()
        try session.setServer("https://widget-privacy.test")
        return WidgetPrivacyAPI(session: session, imageGate: imageGate, metadataGate: metadataGate, assetID: assetID)
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
    init(started: XCTestExpectation) { self.started = started }
    func wait() async {
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
}

private actor WidgetThumbnailCount {
    private(set) var value = 0
    func increment() { value += 1 }
}

private final class WidgetPrivacyAPI: APIClient {
    let thumbnailCount = WidgetThumbnailCount()
    private let imageGate: WidgetPrivacyGate?
    private let metadataGate: WidgetPrivacyGate?
    private let assetID: String
    init(session: SessionManager, imageGate: WidgetPrivacyGate?, metadataGate: WidgetPrivacyGate?, assetID: String) {
        self.imageGate = imageGate
        self.metadataGate = metadataGate
        self.assetID = assetID
        super.init(session: session)
    }
    override func send<T: Decodable>(_ endpoint: Endpoint) async throws -> T {
        let data: Data
        switch endpoint.path {
        case "/albums", "/memories": data = Data("[]".utf8)
        case "/search/metadata":
            await metadataGate?.wait()
            data = Data(#"{"assets":{"items":[{"id":"was-visible","type":"IMAGE","originalFileName":"photo.jpg","fileCreatedAt":"2020-01-01T00:00:00Z","localDateTime":"2020-01-01T00:00:00Z","isFavorite":true,"isArchived":false,"isTrashed":false,"visibility":"timeline"}],"total":1,"nextPage":null}}"#
                .replacingOccurrences(of: "was-visible", with: assetID).utf8)
        default: throw URLError(.unsupportedURL)
        }
        return try JSONDecoder.immich.decode(T.self, from: data)
    }
    override func rawData(_ endpoint: Endpoint) async throws -> Data {
        XCTAssertEqual(endpoint.path, "/assets/\(assetID)/thumbnail")
        await thumbnailCount.increment()
        await imageGate?.wait()
        return Data([1, 2, 3])
    }
}
