import XCTest
import Observation
@testable import ImmichApp

@MainActor
final class SearchVisibilityPrivacyTests: XCTestCase {
    private var api: APIClient!
    private var requests: PrivacyRequestLog!

    override func setUp() async throws {
        requests = PrivacyRequestLog()
        let requests = requests!
        PrivacyURLProtocol.handler = { request, body in
            requests.record(request, body: body)
            return Data(#"{"assets":{"items":[],"total":0,"nextPage":null}}"#.utf8)
        }
        let session = MockSessionManager()
        try session.setServer("https://privacy.test")
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [PrivacyURLProtocol.self]
        api = APIClient(session: session, urlSession: URLSession(configuration: configuration))
    }

    override func tearDown() async throws {
        PrivacyURLProtocol.handler = nil
        api = nil
        requests = nil
    }

    func testOrdinarySmartSearchExplicitlyRequestsTimelineVisibility() async throws {
        let model = makeModel()
        model.searchText = "mountains"
        await model.search()

        let request = try XCTUnwrap(requests.entries.first)
        XCTAssertEqual(request.path, "/api/search/smart")
        XCTAssertEqual(try request.object()["visibility"] as? String, "timeline")
        XCTAssertEqual(try request.object()["query"] as? String, "mountains")
        XCTAssertEqual(try request.object()["size"] as? Int, 100)
        XCTAssertEqual(requests.entries.count, 1)
    }

    func testMetadataSearchAndNextPageKeepTimelineVisibility() async throws {
        let requests = requests!
        PrivacyURLProtocol.handler = { request, body in
            let entry = requests.record(request, body: body)
            let page = (try? entry.object())?["page"] as? Int
            return try JSONSerialization.data(withJSONObject: ["assets": [
                "items": [Self.assetJSON(id: page == 1 ? "first" : "second", visibility: "timeline")],
                "total": 2,
                "nextPage": page == 1 ? "2" as Any : NSNull(),
            ]])
        }
        let model = makeModel()
        model.filters.mediaType = .video
        await model.search()
        await model.loadMore()

        XCTAssertEqual(model.results.map(\.id), ["first", "second"])
        XCTAssertEqual(requests.entries.count, 2)
        for (offset, entry) in requests.entries.enumerated() {
            XCTAssertEqual(entry.path, "/api/search/metadata")
            XCTAssertEqual(try entry.object()["visibility"] as? String, "timeline")
            XCTAssertEqual(try entry.object()["page"] as? Int, offset + 1)
            XCTAssertEqual(try entry.object()["type"] as? String, "VIDEO")
        }
    }

    func testSearchResponsesExcludePrivatePhotosOnFirstAndLaterPages() async throws {
        let requests = requests!
        PrivacyURLProtocol.handler = { request, body in
            let entry = requests.record(request, body: body)
            let page = (try? entry.object())?["page"] as? Int
            let assets = page == 1
                ? [Self.assetJSON(id: "locked", visibility: "locked"),
                   Self.assetJSON(id: "first-visible", visibility: "timeline")]
                : [Self.assetJSON(id: "hidden", visibility: "hidden"),
                   Self.assetJSON(id: "archived", visibility: "archive"),
                   Self.assetJSON(id: "second-visible", visibility: "timeline")]
            return try JSONSerialization.data(withJSONObject: ["assets": [
                "items": assets, "total": 5,
                "nextPage": page == 1 ? "2" as Any : NSNull(),
            ]])
        }
        let model = makeModel()
        model.searchText = "mountains"
        await model.search()
        XCTAssertEqual(model.results.map(\.id), ["first-visible"])

        await model.loadMore()
        XCTAssertEqual(model.results.map(\.id), ["first-visible", "second-visible"])
        XCTAssertEqual(requests.entries.count, 2)
    }

    func testAlreadyLoadedSearchObservesVisibilityChangesWithoutAnotherRequest() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("search-visibility-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SwiftDataManager(storeURL: directory.appendingPathComponent("test.store"),
            backupJournalURL: directory.appendingPathComponent("backup.json"))
        XCTAssertTrue(store.isPersistentStoreAvailable)
        let requests = requests!
        PrivacyURLProtocol.handler = { request, body in
            requests.record(request, body: body)
            return try JSONSerialization.data(withJSONObject: ["assets": [
                "items": [Self.assetJSON(id: "to-hide", visibility: "timeline"),
                          Self.assetJSON(id: "still-visible", visibility: "timeline")],
                "total": 2, "nextPage": NSNull(),
            ]])
        }
        let model = makeModel(dataManager: store)
        model.searchText = "mountains"
        await model.search()
        XCTAssertEqual(model.results.map(\.id), ["to-hide", "still-visible"])
        let changed = expectation(description: "Loaded results observe the privacy store")
        withObservationTracking {
            _ = model.results
        } onChange: {
            changed.fulfill()
        }

        try store.setTimelineVisibility(["to-hide"], inTimeline: false)

        XCTAssertEqual(model.results.map(\.id), ["still-visible"])
        await fulfillment(of: [changed], timeout: 1)
        XCTAssertEqual(requests.entries.count, 1, "Hiding loaded photos must not require a refresh")
        try store.setTimelineVisibility(["to-hide"], inTimeline: true)
        XCTAssertEqual(model.results.map(\.id), ["to-hide", "still-visible"])
        XCTAssertEqual(requests.entries.count, 1)
    }

    func testSuccessfulArchiveUpdatesResultCountAfterThePrivacyStoreHidesThePhoto() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("search-archive-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SwiftDataManager(storeURL: directory.appendingPathComponent("test.store"),
            backupJournalURL: directory.appendingPathComponent("backup.json"))
        XCTAssertTrue(store.isPersistentStoreAvailable)
        let requests = requests!
        PrivacyURLProtocol.handler = { request, body in
            requests.record(request, body: body)
            if request.url?.path == "/api/assets/to-archive" { return Data("{}".utf8) }
            return try JSONSerialization.data(withJSONObject: ["assets": [
                "items": [Self.assetJSON(id: "to-archive", visibility: "timeline"),
                          Self.assetJSON(id: "still-visible", visibility: "timeline")],
                "total": 2, "nextPage": NSNull(),
            ]])
        }
        let model = makeModel(dataManager: store)
        model.searchText = "mountains"
        await model.search()
        XCTAssertEqual(model.totalResults, 2)
        XCTAssertEqual(model.results.map(\.id), ["to-archive", "still-visible"])

        let succeeded = await model.archive(["to-archive"])

        XCTAssertTrue(succeeded)
        XCTAssertTrue(store.nonTimelineAssetIDs.contains("to-archive"))
        XCTAssertEqual(model.results.map(\.id), ["still-visible"])
        XCTAssertEqual(model.totalResults, 1)
        XCTAssertEqual(requests.entries.count, 2)
        let mutation = try XCTUnwrap(requests.entries.last)
        XCTAssertEqual(mutation.path, "/api/assets/to-archive")
        XCTAssertEqual(try mutation.object()["visibility"] as? String, "archive")
    }

    func testPrivateOnlyMemoryIsOmittedWithoutConsumingTheStoryLimit() throws {
        let now = try XCTUnwrap(Calendar.current.date(from:
            DateComponents(year: 2026, month: 10, day: 27, hour: 12)))
        let privateAssets = try ["locked", "hidden", "archive"].map { visibility in
            try decodedAsset(id: visibility, visibility: visibility)
        }
        let privateMemory = try memory(id: "private-memory", year: 2025,
            assets: privateAssets, now: now)
        let visibleMemory = try memory(id: "visible-memory", year: 2020,
            assets: [decodedAsset(id: "visible", visibility: "timeline")], now: now)

        let stories = MemoryStory.build(from: [visibleMemory, privateMemory], limit: 1, now: now)

        XCTAssertEqual(stories.map(\.id), ["visible-memory"])
        XCTAssertEqual(stories.first?.assets.map(\.id), ["visible"])
    }

    func testMemoryCardUsesVisibleCoverAndExcludesPrivateStoryPhotos() throws {
        let now = try XCTUnwrap(Calendar.current.date(from:
            DateComponents(year: 2026, month: 10, day: 27, hour: 12)))
        let assets = try [
            decodedAsset(id: "locked-cover", visibility: "locked"),
            decodedAsset(id: "hidden", visibility: "hidden"),
            decodedAsset(id: "archived", visibility: "archive"),
            decodedAsset(id: "visible-cover", visibility: "timeline"),
            decodedAsset(id: "legacy-visible", visibility: nil),
        ]
        let entry = try memory(id: "mixed-memory", year: 2020, assets: assets, now: now)

        let stories = MemoryStory.build(from: [entry], limit: 10, now: now)

        XCTAssertEqual(stories.count, 1)
        XCTAssertEqual(stories.first?.cover?.id, "visible-cover")
        XCTAssertEqual(stories.first?.assets.map(\.id), ["visible-cover", "legacy-visible"])
    }

    func testDefaultBrowsingIsTimelineAndPrivateCollectionsKeepExplicitVisibility() async throws {
        let repository = SearchRepository(api: api)
        _ = try await repository.metadataSearch(SearchRequestDTO(isFavorite: true))
        _ = try await repository.metadataSearch(SearchRequestDTO(visibility: "archive"))
        _ = try await repository.metadataSearch(SearchRequestDTO(visibility: "locked"))
        _ = try await repository.metadataSearch(SearchRequestDTO(visibility: nil))

        XCTAssertEqual(requests.entries.count, 4)
        let bodies = try requests.entries.map { try $0.object() }
        XCTAssertEqual(bodies[0]["visibility"] as? String, "timeline")
        XCTAssertEqual(bodies[0]["isFavorite"] as? Bool, true)
        XCTAssertEqual(bodies[1]["visibility"] as? String, "archive")
        XCTAssertEqual(bodies[2]["visibility"] as? String, "locked")
        XCTAssertNil(bodies[3]["visibility"], "Unrestricted access must be an explicit opt-out")
    }

    func testPeopleCollectionRequestsTimelineVisibility() async throws {
        _ = try await PeopleRepository(api: api).assets(personId: "person-a")

        let request = try XCTUnwrap(requests.entries.first)
        XCTAssertEqual(requests.entries.count, 1)
        XCTAssertEqual(request.path, "/api/search/metadata")
        XCTAssertEqual(try request.object()["personIds"] as? [String], ["person-a"])
        XCTAssertEqual(try request.object()["visibility"] as? String, "timeline")
    }

    func testAssetVisibilitySurvivesSnapshotRoundTripAndLegacyArchiveRemainsPrivate() throws {
        for visibility in ["timeline", "archive", "hidden", "locked", "future-private-mode"] {
            let data = try JSONSerialization.data(withJSONObject: Self.assetJSON(id: visibility, visibility: visibility))
            let asset = try JSONDecoder.immich.decode(AssetResponseDTO.self, from: data)
            let restored = try JSONDecoder().decode(AssetResponseDTO.self, from: JSONEncoder().encode(asset))
            XCTAssertEqual(restored.visibility, visibility)
            XCTAssertEqual(restored.isTimelineVisible, visibility == "timeline")
        }
        var legacy = Self.assetJSON(id: "legacy", visibility: nil)
        let visible = try JSONDecoder.immich.decode(AssetResponseDTO.self,
            from: JSONSerialization.data(withJSONObject: legacy))
        XCTAssertTrue(visible.isTimelineVisible)
        legacy["isArchived"] = true
        let archived = try JSONDecoder.immich.decode(AssetResponseDTO.self,
            from: JSONSerialization.data(withJSONObject: legacy))
        XCTAssertFalse(archived.isTimelineVisible)
        legacy["isArchived"] = false
        legacy["isTrashed"] = true
        let trashed = try JSONDecoder.immich.decode(AssetResponseDTO.self,
            from: JSONSerialization.data(withJSONObject: legacy))
        XCTAssertFalse(trashed.isTimelineVisible)
    }

    func testWidgetExportRejectsPrivateFavoritesAlbumPhotosAndMemoryCovers() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("widget-privacy-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let requests = requests!
        let now = Date()
        let components = Calendar.current.dateComponents([.month, .day], from: now)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .gmt
        let memoryDate = try XCTUnwrap(calendar.date(from: DateComponents(year: 2020, month: components.month, day: components.day)))
        let memoryAt = ISO8601DateFormatter().string(from: memoryDate)
        PrivacyURLProtocol.handler = { request, body in
            requests.record(request, body: body)
            let path = request.url!.path
            if path.hasSuffix("/thumbnail") { return Data([1, 2, 3]) }
            let mixedAssets = [
                Self.assetJSON(id: "locked", visibility: "locked"),
                Self.assetJSON(id: "hidden", visibility: "hidden"),
                Self.assetJSON(id: "archived", visibility: "archive"),
                Self.assetJSON(id: "visible", visibility: "timeline"),
            ]
            let object: Any
            switch path {
            case "/api/albums": object = [["id": "album-a", "albumName": "Album", "assetCount": 4]]
            case "/api/albums/album-a": object = ["id": "album-a", "albumName": "Album", "assetCount": 4, "assets": mixedAssets]
            case "/api/memories": object = [["id": "memory-a", "type": "on_this_day", "memoryAt": memoryAt, "assets": mixedAssets]]
            case "/api/search/metadata": object = ["assets": ["items": mixedAssets, "total": 4, "nextPage": NSNull()]]
            default: throw PrivacyTestError.unexpectedPath(path)
            }
            return try JSONSerialization.data(withJSONObject: object)
        }

        await WidgetSnapshotExporter.refresh(api: api, imageAPI: api,
            container: directory, selectedAlbumIDs: ["album-a"])

        let metadata = try XCTUnwrap(requests.entries.first { $0.path == "/api/search/metadata" })
        XCTAssertEqual(try metadata.object()["visibility"] as? String, "timeline")
        XCTAssertEqual(try metadata.object()["isFavorite"] as? Bool, true)
        let thumbnails = requests.entries.filter { $0.path.hasSuffix("/thumbnail") }
        XCTAssertEqual(thumbnails.count, 3, "Visible favorites, album photos, and memory covers still export")
        XCTAssertTrue(thumbnails.allSatisfy { $0.path == "/api/assets/visible/thumbnail" })
        let snapshotData = try Data(contentsOf: directory.appendingPathComponent("Widgets/snapshot.json"))
        let snapshot = try XCTUnwrap(JSONSerialization.jsonObject(with: snapshotData) as? [String: Any])
        let albums = try XCTUnwrap(snapshot["albums"] as? [[String: Any]])
        XCTAssertEqual(albums.count, 2)
        for album in albums {
            XCTAssertEqual((album["imageNames"] as? [String])?.count, 1)
        }
        let memories = try XCTUnwrap(snapshot["memories"] as? [[String: Any]])
        XCTAssertEqual(memories.count, 1)
        XCTAssertNotNil(memories[0]["imageName"] as? String)
    }

    private func decodedAsset(id: String, visibility: String?) throws -> AssetResponseDTO {
        try JSONDecoder.immich.decode(AssetResponseDTO.self,
            from: JSONSerialization.data(withJSONObject: Self.assetJSON(id: id, visibility: visibility)))
    }

    private func memory(id: String, year: Int, assets: [AssetResponseDTO], now: Date) throws -> MemoryDTO {
        let day = Calendar.current.dateComponents([.month, .day], from: now)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .gmt
        let date = try XCTUnwrap(calendar.date(from: DateComponents(year: year, month: day.month, day: day.day)))
        return MemoryDTO(id: id, type: "on_this_day", memoryAt: date, assets: assets,
            data: MemoryDataDTO(year: year))
    }

    private func makeModel(dataManager: SwiftDataManager? = nil) -> SearchViewModel {
        SearchViewModel(repo: SearchRepository(api: api),
            assetRepo: AssetDetailRepository(api: api, dataManager: dataManager), albumRepo: AlbumRepository(api: api),
            dataManager: dataManager)
    }

    nonisolated private static func assetJSON(id: String, visibility: String?) -> [String: Any] {
        var object: [String: Any] = [
            "id": id, "type": "IMAGE", "originalFileName": "photo.jpg",
            "fileCreatedAt": "2020-01-01T00:00:00.000Z", "localDateTime": "2020-01-01T00:00:00.000Z",
            "isFavorite": true, "isArchived": visibility == "archive", "isTrashed": false,
        ]
        object["visibility"] = visibility
        return object
    }
}

private enum PrivacyTestError: Error { case unexpectedPath(String) }

private final class PrivacyRequestLog {
    struct Entry {
        let path: String
        let body: Data?
        func object() throws -> [String: Any] {
            try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(body)) as? [String: Any])
        }
    }
    private let lock = NSLock()
    private var recorded: [Entry] = []
    var entries: [Entry] { lock.withLock { recorded } }
    @discardableResult
    func record(_ request: URLRequest, body: Data?) -> Entry {
        let entry = Entry(path: request.url!.path, body: body)
        lock.withLock { recorded.append(entry) }
        return entry
    }
}

private final class PrivacyURLProtocol: URLProtocol {
    static var handler: ((URLRequest, Data?) throws -> Data)?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            var body = request.httpBody
            if body == nil, let stream = request.httpBodyStream {
                stream.open()
                defer { stream.close() }
                var data = Data()
                var buffer = [UInt8](repeating: 0, count: 4_096)
                while stream.hasBytesAvailable {
                    let count = stream.read(&buffer, maxLength: buffer.count)
                    guard count > 0 else { break }
                    data.append(buffer, count: count)
                }
                body = data
            }
            guard let handler = Self.handler else { throw URLError(.cancelled) }
            let data = try handler(request, body)
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200,
                httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }
    override func stopLoading() {}
}
