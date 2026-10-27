import XCTest
@testable import ImmichApp

@MainActor
final class MediaSharingCallerTests: XCTestCase {
    private var fixtures: [SharingFixture] = []
    private var preparedURLs: [URL] = []

    override func tearDown() async throws {
        TemporaryMediaStore.remove(preparedURLs)
        for fixture in fixtures { try? FileManager.default.removeItem(at: fixture.directory) }
        fixtures.removeAll()
        preparedURLs.removeAll()
        try await super.tearDown()
    }

    func testEveryBulkSharingScreenPreservesOriginalNamesFormatsAndBytes() async throws {
        for screen in BulkScreen.allCases {
            let fixture = try fixture()
            let share = bulkShare(screen, repository: fixture.repository, api: fixture.api)

            let urls = await share(["photo", "video", "raw"])
            preparedURLs.append(contentsOf: urls)

            XCTAssertEqual(urls.count, 3, "Screen: \(screen)")
            try assertFiles(urls, ids: ["photo", "video", "raw"], fixture: fixture)
            XCTAssertEqual(fixture.api.requests.map(\.path), [
                "/assets/photo/original", "/assets/video/original", "/assets/raw/original",
            ])
            XCTAssertTrue(fixture.api.requests.allSatisfy { $0.query.isEmpty },
                "Sharing originals must not silently request edited bytes")
            XCTAssertTrue(fixture.api.dataRequests.isEmpty)
            XCTAssertTrue(fixture.api.sources.allSatisfy { !FileManager.default.fileExists(atPath: $0.path) })
        }
    }

    func testEveryBulkScreenKeepsSuccessfulFilesWhenAnotherDownloadFails() async throws {
        for screen in BulkScreen.allCases {
            let fixture = try fixture()
            fixture.api.failedIDs = ["unavailable"]
            let share = bulkShare(screen, repository: fixture.repository, api: fixture.api)

            let urls = await share(["photo", "unavailable", "video"])
            preparedURLs.append(contentsOf: urls)

            XCTAssertEqual(urls.count, 2, "Screen: \(screen)")
            try assertFiles(urls, ids: ["photo", "video"], fixture: fixture)
            XCTAssertEqual(fixture.api.requests.map(\.path), [
                "/assets/photo/original", "/assets/unavailable/original", "/assets/video/original",
            ])
            XCTAssertTrue(fixture.api.dataRequests.isEmpty)
        }
    }

    func testCanceledBulkSharingRemovesPreviouslyPreparedAndCurrentFiles() async throws {
        for screen in BulkScreen.allCases {
            let fixture = try fixture()
            let control = try await fixture.repository.shareFile("raw")
            let shareDirectory = control.deletingLastPathComponent()
            TemporaryMediaStore.remove(control)
            fixture.api.requests.removeAll()
            let share = bulkShare(screen, repository: fixture.repository, api: fixture.api)
            var operation: Task<[URL], Never>?
            fixture.api.onDownload = { id in
                if id == "video" { operation?.cancel() }
            }
            operation = Task { await share(["photo", "video", "raw"]) }

            let urls = await operation!.value
            preparedURLs.append(contentsOf: urls)

            XCTAssertTrue(urls.isEmpty, "A canceled share must not publish its completed prefix")
            XCTAssertEqual(fixture.api.requests.map(\.path), ["/assets/photo/original", "/assets/video/original"])
            XCTAssertTrue(fixture.api.sources.allSatisfy { !FileManager.default.fileExists(atPath: $0.path) })
            let remaining = try FileManager.default.contentsOfDirectory(
                at: shareDirectory, includingPropertiesForKeys: nil)
                .filter { $0.lastPathComponent.contains(fixture.token) }
            preparedURLs.append(contentsOf: remaining)
            XCTAssertTrue(remaining.isEmpty, "Completed files from the canceled operation must be removed")
        }
    }

    func testEverySingleSharingScreenUsesTheServerVideoNameAndExactBytes() async throws {
        for screen in SingleScreen.allCases {
            let fixture = try fixture()
            let share = singleShare(screen, repository: fixture.repository, api: fixture.api)
            let asset = AssetLite(makeTestAsset(id: "video", type: "VIDEO"))

            let prepared = await share(asset)
            let url = try XCTUnwrap(prepared)
            preparedURLs.append(url)

            try assertFiles([url], ids: ["video"], fixture: fixture)
            XCTAssertEqual(url.pathExtension, "mp4", "A video must not be renamed to .mov or .jpg")
            XCTAssertEqual(fixture.api.requests.map(\.path), ["/assets/video/original"])
            XCTAssertTrue(fixture.api.dataRequests.isEmpty)
        }
    }

    func testSingleSharingFailuresDoNotReturnANonexistentFile() async throws {
        for screen in SingleScreen.allCases {
            let fixture = try fixture()
            fixture.api.failedIDs = ["video"]
            let share = singleShare(screen, repository: fixture.repository, api: fixture.api)

            let url = await share(AssetLite(makeTestAsset(id: "video", type: "VIDEO")))

            XCTAssertNil(url)
            XCTAssertEqual(fixture.api.requests.map(\.path), ["/assets/video/original"])
            XCTAssertTrue(fixture.api.sources.isEmpty)
            XCTAssertTrue(fixture.api.dataRequests.isEmpty)
        }
    }

    private func assertFiles(_ urls: [URL], ids: [String], fixture: SharingFixture) throws {
        XCTAssertEqual(urls.count, ids.count)
        for (url, id) in zip(urls, ids) {
            let media = try XCTUnwrap(fixture.api.media[id])
            XCTAssertTrue(url.lastPathComponent.hasSuffix(media.filename), url.lastPathComponent)
            XCTAssertEqual(try Data(contentsOf: url), media.bytes)
        }
    }

    private func fixture() throws -> SharingFixture {
        let token = "share-caller-\(UUID().uuidString)"
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(token, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let api = SharingFileAPI(session: MockSessionManager(), directory: directory, token: token)
        let fixture = SharingFixture(directory: directory, token: token, api: api, repository: AssetDetailRepository(api: api))
        fixtures.append(fixture)
        return fixture
    }

    private func bulkShare(
        _ screen: BulkScreen, repository: AssetDetailRepository, api: APIClient
    ) -> ([String]) async -> [URL] {
        switch screen {
        case .timeline:
            let model = TimelineViewModel(assetRepo: repository)
            return { await model.shareURLs(for: $0) }
        case .search:
            let model = SearchViewModel(
                repo: SearchRepository(api: api), assetRepo: repository, albumRepo: AlbumRepository(api: api))
            return { await model.shareURLs(for: $0) }
        case .collection:
            let model = AssetGridViewModel(assetRepo: repository, albumRepo: AlbumRepository(api: api), loader: { [] })
            return { await model.shareURLs(for: $0) }
        case .album:
            let model = AlbumDetailViewModel(
                timelineRepo: TimelineRepository(api: api), albumRepo: AlbumRepository(api: api), assetRepo: repository)
            return { await model.shareURLs(for: $0) }
        }
    }

    private func singleShare(
        _ screen: SingleScreen, repository: AssetDetailRepository, api: APIClient
    ) -> (AssetLite) async -> URL? {
        switch screen {
        case .timeline:
            let model = TimelineViewModel(assetRepo: repository)
            return { await model.shareURL(for: $0) }
        case .library:
            let model = LibraryViewModel(
                memoriesRepo: MemoriesRepository(api: api), albumRepo: AlbumRepository(api: api),
                peopleRepo: PeopleRepository(api: api), searchRepo: SearchRepository(api: api), assetRepo: repository)
            return { await model.shareURL(for: $0) }
        case .memories:
            let model = MemoriesViewModel(repo: MemoriesRepository(api: api), assetRepo: repository)
            return { await model.shareURL(for: $0) }
        }
    }

    private enum BulkScreen: CaseIterable { case timeline, search, collection, album }
    private enum SingleScreen: CaseIterable { case timeline, library, memories }

    private struct SharingFixture {
        let directory: URL
        let token: String
        let api: SharingFileAPI
        let repository: AssetDetailRepository
    }
}

private final class SharingFileAPI: APIClient {
    struct Media {
        let filename: String
        let mimeType: String
        let bytes: Data
    }

    let directory: URL
    let media: [String: Media]
    var requests: [Endpoint] = []
    var sources: [URL] = []
    var dataRequests: [Endpoint] = []
    var failedIDs = Set<String>()
    var onDownload: ((String) -> Void)?

    init(session: SessionManager, directory: URL, token: String) {
        self.directory = directory
        self.media = [
            "photo": Media(filename: "\(token)-portrait original.heic", mimeType: "image/heic", bytes: Data([0, 0, 0, 24, 102, 116, 121, 112, 104, 101, 105, 99])),
            "video": Media(filename: "\(token)-clip original.mp4", mimeType: "video/mp4", bytes: Data([0, 0, 0, 24, 102, 116, 121, 112, 105, 115, 111, 109])),
            "raw": Media(filename: "\(token)-camera original.dng", mimeType: "image/dng", bytes: Data([73, 73, 42, 0, 8, 0, 0, 0])),
        ]
        super.init(session: session)
    }

    override func rawFile(_ endpoint: Endpoint) async throws -> DownloadedFile {
        requests.append(endpoint)
        let id = endpoint.path.split(separator: "/").dropFirst().first.map(String.init) ?? ""
        guard !failedIDs.contains(id), let item = media[id] else {
            throw APIError.server(status: 503, message: "Original unavailable")
        }
        let source = directory.appendingPathComponent(UUID().uuidString + ".download")
        try item.bytes.write(to: source)
        sources.append(source)
        let encodedName = item.filename.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed)!
        let response = HTTPURLResponse(
            url: URL(string: "https://test.example.com/api\(endpoint.path)")!,
            statusCode: 200, httpVersion: nil,
            headerFields: ["Content-Type": item.mimeType, "Content-Disposition": "attachment; filename*=UTF-8''\(encodedName)"])!
        onDownload?(id)
        return DownloadedFile(url: source, response: response)
    }

    override func rawData(_ endpoint: Endpoint) async throws -> Data {
        dataRequests.append(endpoint)
        throw APIError.unknown
    }
}
