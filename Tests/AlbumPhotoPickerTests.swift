import Foundation
import XCTest
@testable import ImmichApp

@MainActor
final class AlbumPhotoPickerTests: XCTestCase {
    private var repo: SearchRepository!

    override func setUp() async throws {
        try await super.setUp()
        MockURLProtocol.reset()
        let session = MockSessionManager()
        try session.setServer("https://picker.example")
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        repo = SearchRepository(api: APIClient(session: session,
            urlSession: URLSession(configuration: configuration)))
    }

    override func tearDown() async throws {
        MockURLProtocol.reset()
        repo = nil
        try await super.tearDown()
    }

    func testOlderPhotosRemainAvailableWhenTheFirstTwoHundredAreAlreadyInTheAlbum() async {
        let existing = (0..<200).map { "existing-\($0)" }
        var pages: [Int] = []
        MockURLProtocol.responseProvider = { request in
            let body = Self.body(request)
            let page = body["page"] as? Int ?? 0
            pages.append(page)
            XCTAssertEqual(request.url?.path, "/api/search/metadata")
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(body["size"] as? Int, 200)
            XCTAssertEqual(body["order"] as? String, "desc")
            XCTAssertEqual(body["withExif"] as? Bool, true)
            return Self.response(request, ids: page == 1 ? existing : ["older-photo", "older-video"],
                total: 202, nextPage: page == 1 ? "2" : nil)
        }
        let vm = AlbumPhotoPickerViewModel(repo: repo, existingIDs: Set(existing))

        await vm.load()

        XCTAssertEqual(pages, [1, 2])
        XCTAssertEqual(vm.assets.map(\.id), ["older-photo", "older-video"])
        XCTAssertTrue(vm.assets.allSatisfy { $0.ratio == 2 })
        assertLoaded(vm)
    }

    func testServerCappedPagesAreFullyLoadedBeforeFiltering() async {
        let pageIDs = [1: ["existing", "a"], 2: ["b"], 3: ["c", "d"]]
        var pages: [Int] = []
        MockURLProtocol.responseProvider = { request in
            let page = Self.body(request)["page"] as? Int ?? 0
            pages.append(page)
            return Self.response(request, ids: pageIDs[page] ?? [], total: 5, nextPage: nil)
        }
        let vm = AlbumPhotoPickerViewModel(repo: repo, existingIDs: ["existing"])

        await vm.load()

        XCTAssertEqual(pages, [1, 2, 3])
        XCTAssertEqual(vm.assets.map(\.id), ["a", "b", "c", "d"])
        assertLoaded(vm)
        await vm.load()
        XCTAssertEqual(pages, [1, 2, 3], "A completed picker must not repeat the full search when its view task resumes")
    }

    func testOverlappingPagesDoNotOfferTheSamePhotoTwice() async {
        var pages: [Int] = []
        MockURLProtocol.responseProvider = { request in
            let page = Self.body(request)["page"] as? Int ?? 0
            pages.append(page)
            return Self.response(request, ids: page == 1 ? ["a", "b"] : ["b", "c"],
                total: 3, nextPage: page == 1 ? "2" : nil)
        }
        let vm = AlbumPhotoPickerViewModel(repo: repo, existingIDs: [])

        await vm.load()

        XCTAssertEqual(vm.assets.map(\.id), ["a", "b", "c"])
        XCTAssertEqual(pages, [1, 2])
        assertLoaded(vm)
    }

    func testLaterPageFailureIsNotPublishedAsAnEmptyOrPartialPickerAndRetryRestartsAtPageOne() async {
        var shouldFail = true
        var pages: [Int] = []
        MockURLProtocol.responseProvider = { request in
            let page = Self.body(request)["page"] as? Int ?? 0
            pages.append(page)
            if page == 2 && shouldFail {
                return (nil, nil, URLError(.notConnectedToInternet))
            }
            return Self.response(request, ids: page == 1 ? ["existing", "recent"] : ["older"],
                total: 3, nextPage: page == 1 ? "2" : nil)
        }
        let vm = AlbumPhotoPickerViewModel(repo: repo, existingIDs: ["existing"])

        await vm.load()

        XCTAssertTrue(vm.assets.isEmpty)
        XCTAssertNotNil(vm.phase.errorMessage, "Network failure must show Retry, not No Photos to Add")
        shouldFail = false
        await vm.load()

        XCTAssertEqual(pages, [1, 2, 1, 2])
        XCTAssertEqual(vm.assets.map(\.id), ["recent", "older"])
        assertLoaded(vm)
    }

    func testBrokenContinuationCannotPublishPartialPhotosAsACompletePicker() async {
        var pages: [Int] = []
        MockURLProtocol.responseProvider = { request in
            let page = Self.body(request)["page"] as? Int ?? 0
            pages.append(page)
            if page > 2 { return (nil, nil, URLError(.badServerResponse)) }
            return Self.response(request, ids: ["repeated"], total: 3,
                nextPage: page == 1 ? "2" : nil)
        }
        let vm = AlbumPhotoPickerViewModel(repo: repo, existingIDs: [])

        await vm.load()

        XCTAssertEqual(pages, [1, 2], "A repeated server page must terminate the search")
        XCTAssertTrue(vm.assets.isEmpty)
        XCTAssertNotNil(vm.phase.errorMessage, "A truncated response must offer Retry instead of appearing complete")
    }

    func testAFullyExcludedCollectionIsARealEmptySuccess() async {
        var requests = 0
        MockURLProtocol.responseProvider = { request in
            requests += 1
            return Self.response(request, ids: ["existing"], total: 1, nextPage: nil)
        }
        let vm = AlbumPhotoPickerViewModel(repo: repo, existingIDs: ["existing"])

        await vm.load()

        XCTAssertEqual(requests, 1)
        XCTAssertTrue(vm.assets.isEmpty)
        assertLoaded(vm)
    }

    func testCancellationWhileLoadingCannotPublishLateResultsAndCanBeRetried() async throws {
        let held = HeldPickerSearch()
        let vm = AlbumPhotoPickerViewModel(repo: held, existingIDs: [])
        let work = Task { await vm.load() }
        defer { work.cancel(); held.cancelIfWaiting() }
        await fulfillment(of: [held.started], timeout: 2)
        XCTAssertTrue(vm.phase.isLoading)
        let secondFinished = XCTestExpectation(description: "An overlapping picker load returns without another search")
        let second = Task { await vm.load(); secondFinished.fulfill() }
        defer { second.cancel(); held.cancelIfWaiting() }
        await fulfillment(of: [secondFinished], timeout: 2)
        XCTAssertEqual(held.calls, 1, "A second task must not start another in-flight picker load")
        work.cancel()
        second.cancel()
        held.resolve([makeTestAsset(id: "late")])
        await work.value
        await second.value

        XCTAssertTrue(vm.assets.isEmpty)
        XCTAssertTrue(vm.phase.isIdle)
        XCTAssertNil(vm.phase.errorMessage)
        held.result = [makeTestAsset(id: "retry")]
        await vm.load()
        XCTAssertEqual(held.calls, 2)
        XCTAssertEqual(vm.assets.map(\.id), ["retry"])
        assertLoaded(vm)
    }

    private func assertLoaded(_ vm: AlbumPhotoPickerViewModel, file: StaticString = #filePath, line: UInt = #line) {
        guard case .loaded = vm.phase else {
            return XCTFail("Expected the complete picker to be loaded", file: file, line: line)
        }
    }

    private static func body(_ request: URLRequest) -> [String: Any] {
        guard let data = request.httpBody ?? MockURLProtocol.lastRequestBody,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            XCTFail("The real search request did not contain a JSON body")
            return [:]
        }
        return object
    }

    private static func response(_ request: URLRequest, ids: [String], total: Int, nextPage: String?)
        -> (Data?, URLResponse?, Error?) {
        let items: [[String: Any]] = ids.map { id in
            ["id": id, "type": "IMAGE", "originalFileName": "\(id).jpg",
             "fileCreatedAt": "2026-08-08T01:00:00.000Z", "localDateTime": "2026-08-08T01:00:00.000Z",
             "isFavorite": false, "isArchived": false, "isTrashed": false,
             "exifInfo": ["exifImageWidth": 2000, "exifImageHeight": 1000]]
        }
        let object: [String: Any] = ["assets": ["items": items, "total": total, "nextPage": nextPage as Any? ?? NSNull()]]
        let data = try? JSONSerialization.data(withJSONObject: object)
        XCTAssertNotNil(data)
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)
        return (data, response, nil)
    }
}

@MainActor
private final class HeldPickerSearch: SearchRepository {
    let started = XCTestExpectation(description: "The picker is awaiting a complete search")
    private(set) var calls = 0
    var result: [AssetResponseDTO]?
    private var continuations: [CheckedContinuation<[AssetResponseDTO], Error>] = []

    init() { super.init(api: makeStubAPIClient()) }

    override func allMetadata(_ request: SearchRequestDTO) async throws -> [AssetResponseDTO] {
        calls += 1
        if let result { return result }
        return try await withCheckedThrowingContinuation { continuation in
            continuations.append(continuation)
            if calls == 1 { started.fulfill() }
        }
    }

    func resolve(_ assets: [AssetResponseDTO]) {
        guard !continuations.isEmpty else { return XCTFail("The picker did not reach the held search boundary") }
        let pending = continuations
        continuations.removeAll()
        pending.forEach { $0.resume(returning: assets) }
    }

    func cancelIfWaiting() {
        let pending = continuations
        continuations.removeAll()
        pending.forEach { $0.resume(throwing: CancellationError()) }
    }
}
