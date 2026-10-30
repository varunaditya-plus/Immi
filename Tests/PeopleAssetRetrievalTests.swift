import Foundation
import UIKit
import XCTest
@testable import ImmichApp

@MainActor
final class PeopleAssetRetrievalTests: XCTestCase {
    private var api: APIClient!
    private var transport: URLSession!
    private var snapshotKeys: [String] = []
    private let personID = "33333333-3333-4333-8333-333333333333"

    override func setUp() async throws {
        try await super.setUp()
        MockURLProtocol.reset()
        let session = MockSessionManager()
        try session.setServer("https://people.example")
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        transport = URLSession(configuration: configuration)
        api = APIClient(session: session, urlSession: transport)
    }

    override func tearDown() async throws {
        transport.invalidateAndCancel()
        for key in snapshotKeys { LocalSnapshot.remove(key) }
        snapshotKeys.removeAll()
        api = nil
        transport = nil
        MockURLProtocol.reset()
        try await super.tearDown()
    }

    func testPersonCollectionLoadsAndCachesMoreThanOneHundredPhotos() async throws {
        let expectedIDs = (0..<201).map(Self.assetID)
        var requests: [[String: Any]] = []
        MockURLProtocol.responseProvider = { request in
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.url?.path, "/api/search/metadata")
            let body = Self.body(request)
            requests.append(body)
            let page = body["page"] as? Int ?? 0
            guard (1...3).contains(page) else {
                return Self.response(request, status: 500, data: Data())
            }
            let start = (page - 1) * 100
            let ids = Array(expectedIDs[start..<min(start + 100, expectedIDs.count)])
            return Self.response(request, data: Self.page(ids: ids, total: ids.count,
                nextPage: page < 3 ? String(page + 1) : nil))
        }
        let key = newSnapshotKey()
        let model = grid(snapshotKey: key)

        await model.load()

        XCTAssertEqual(model.assets.map(\.id), expectedIDs)
        XCTAssertEqual(model.assets.first?.ratio, 4.0 / 3.0)
        XCTAssertEqual(LocalSnapshot.load([AssetLite].self, for: key)?.map(\.id), expectedIDs)
        XCTAssertEqual(requests.compactMap { $0["page"] as? Int }, [1, 2, 3])
        for body in requests {
            XCTAssertEqual(body["personIds"] as? [String], [personID])
            XCTAssertEqual(body["size"] as? Int, 100)
            XCTAssertEqual(body["order"] as? String, "desc")
            XCTAssertEqual(body["withExif"] as? Bool, true)
        }
        if case .loaded = model.phase {} else { XCTFail("A complete person collection should be loaded") }
    }

    func testSmallServerPagesFollowTheReportedContinuation() async throws {
        let expectedIDs = (0..<5).map(Self.assetID)
        var pages: [Int] = []
        MockURLProtocol.responseProvider = { request in
            let page = Self.body(request)["page"] as? Int ?? 0
            pages.append(page)
            guard (1...3).contains(page) else {
                return Self.response(request, status: 500, data: Data())
            }
            let start = (page - 1) * 2
            return Self.response(request, data: Self.page(
                ids: Array(expectedIDs[start..<min(start + 2, expectedIDs.count)]),
                total: min(2, expectedIDs.count - start),
                nextPage: page < 3 ? String(page + 1) : nil))
        }

        let assets = try await PeopleRepository(api: api).assets(personId: personID)

        XCTAssertEqual(assets.map(\.id), expectedIDs)
        XCTAssertEqual(pages, [1, 2, 3], "The server may cap pages below the requested size of 100")
    }

    func testOverlappingPagesDoNotDuplicatePhotosInThePersonCollection() async throws {
        let expectedIDs = (0..<3).map(Self.assetID)
        var pages: [Int] = []
        MockURLProtocol.responseProvider = { request in
            let page = Self.body(request)["page"] as? Int ?? 0
            pages.append(page)
            guard page == 1 || page == 2 else {
                return Self.response(request, status: 500, data: Data())
            }
            let ids = page == 1 ? Array(expectedIDs.prefix(2)) : Array(expectedIDs.suffix(2))
            return Self.response(request, data: Self.page(ids: ids, total: 3,
                nextPage: page == 1 ? "2" : nil))
        }

        let assets = try await PeopleRepository(api: api).assets(personId: personID)

        XCTAssertEqual(assets.map(\.id), expectedIDs)
        XCTAssertEqual(pages, [1, 2])
    }

    func testLaterPageFailureDoesNotPublishOrCacheTheFirstPageAsACompleteCollection() async {
        var pages: [Int] = []
        stubLaterPageFailure { pages.append($0) }
        let key = newSnapshotKey()
        let model = grid(snapshotKey: key)

        await model.load()

        XCTAssertEqual(pages, [1, 2])
        XCTAssertTrue(model.assets.isEmpty)
        XCTAssertNil(LocalSnapshot.load([AssetLite].self, for: key))
        XCTAssertNotNil(model.phase.errorMessage)
    }

    func testLaterPageFailureKeepsThePreviouslyCompletePersonSnapshot() async {
        var pages: [Int] = []
        stubLaterPageFailure { pages.append($0) }
        let key = newSnapshotKey()
        let cached = (20..<24).map {
            AssetLite(id: Self.assetID($0), isVideo: false, ratio: 1, thumbhash: nil,
                createdAt: Date(timeIntervalSince1970: 1_700_000_000))
        }
        LocalSnapshot.save(cached, for: key)
        let model = grid(snapshotKey: key)

        await model.load()

        XCTAssertEqual(pages, [1, 2])
        XCTAssertEqual(model.assets.map(\.id), cached.map(\.id))
        XCTAssertEqual(LocalSnapshot.load([AssetLite].self, for: key)?.map(\.id), cached.map(\.id))
        if case .loaded = model.phase {} else { XCTFail("A failed refresh must retain the complete cached collection") }
    }

    func testAnEmptyPersonCollectionIsASuccessfulEmptySnapshot() async {
        var requests = 0
        MockURLProtocol.responseProvider = { request in
            requests += 1
            return Self.response(request, data: Self.page(ids: [], total: 0))
        }
        let key = newSnapshotKey()
        let model = grid(snapshotKey: key)

        await model.load()

        XCTAssertEqual(requests, 1)
        XCTAssertTrue(model.assets.isEmpty)
        XCTAssertEqual(LocalSnapshot.load([AssetLite].self, for: key)?.count, 0)
        if case .loaded = model.phase {} else { XCTFail("An empty person collection is a valid result") }
    }

    func testRepeatedAdvertisedPageCannotBecomeATruncatedPersonSnapshot() async {
        var pages: [Int] = []
        MockURLProtocol.responseProvider = { request in
            let page = Self.body(request)["page"] as? Int ?? 0
            pages.append(page)
            guard page == 1 || page == 2 else {
                return Self.response(request, status: 503, data: Data())
            }
            return Self.response(request, data: Self.page(ids: [Self.assetID(0)], total: 3,
                nextPage: String(page + 1)))
        }
        let key = newSnapshotKey()
        let model = grid(snapshotKey: key)

        await model.load()

        XCTAssertEqual(pages, [1, 2], "A repeated page must stop without claiming a complete collection")
        XCTAssertTrue(model.assets.isEmpty)
        XCTAssertNotNil(model.phase.errorMessage)
        XCTAssertNil(LocalSnapshot.load([AssetLite].self, for: key))
    }

    func testPeopleDirectoryLoadsBeyondTheServerDefaultPageLimit() async throws {
        let expectedIDs = (0..<501).map(Self.assetID)
        var pages: [Int] = []
        MockURLProtocol.responseProvider = { request in
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertEqual(request.url?.path, "/api/people")
            let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
            XCTAssertEqual(query.first(where: { $0.name == "withHidden" })?.value, "false")
            XCTAssertEqual(query.first(where: { $0.name == "size" })?.value, "500")
            let page = Int(query.first(where: { $0.name == "page" })?.value ?? "") ?? 0
            pages.append(page)
            guard page == 1 || page == 2 else {
                return Self.response(request, status: 500, data: Data())
            }
            let ids = page == 1 ? Array(expectedIDs.prefix(500)) : Array(expectedIDs.suffix(1))
            return Self.response(request, data: Self.peoplePage(ids: ids, hasNextPage: page == 1))
        }

        let people = try await PeopleRepository(api: api).all()

        XCTAssertEqual(people.map(\.id), expectedIDs)
        XCTAssertEqual(pages, [1, 2])
    }

    func testAnExplicitPeoplePreviewLimitStillUsesOneBoundedRequest() async throws {
        let expectedIDs = (0..<15).map(Self.assetID)
        var requests = 0
        MockURLProtocol.responseProvider = { request in
            requests += 1
            let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
            XCTAssertEqual(query.first(where: { $0.name == "size" })?.value, "15")
            XCTAssertEqual(query.first(where: { $0.name == "page" })?.value, "1")
            return Self.response(request, data: Self.peoplePage(ids: expectedIDs, hasNextPage: true))
        }

        let people = try await PeopleRepository(api: api).all(size: 15)

        XCTAssertEqual(people.map(\.id), expectedIDs)
        XCTAssertEqual(requests, 1, "The Library preview should not load the full directory")
    }

    func testFailedOrRepeatedPeoplePagesCannotReturnAPartialDirectory() async {
        for repeatedPage in [false, true] {
            var pages: [Int] = []
            MockURLProtocol.responseProvider = { request in
                let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
                let page = Int(query.first(where: { $0.name == "page" })?.value ?? "") ?? 0
                pages.append(page)
                if page == 1 || (page == 2 && repeatedPage) {
                    return Self.response(request, data: Self.peoplePage(ids: [Self.assetID(0)], hasNextPage: true))
                }
                return Self.response(request, status: 503, data: Data())
            }

            do {
                _ = try await PeopleRepository(api: api).all()
                XCTFail("An interrupted directory must not be returned as a complete list")
            } catch {
                if repeatedPage {
                    XCTAssertEqual((error as? URLError)?.code, .badServerResponse)
                } else if case APIError.server(let status, _) = error {
                    XCTAssertEqual(status, 503)
                } else {
                    XCTFail("Expected the later page's server error, received \(error)")
                }
            }
            XCTAssertEqual(pages, [1, 2])
        }
    }

    private func grid(snapshotKey: String) -> AssetGridViewModel {
        let people = PeopleRepository(api: api)
        let personID = personID
        return AssetGridViewModel(assetRepo: AssetDetailRepository(api: api),
            albumRepo: AlbumRepository(api: api), snapshotKey: snapshotKey,
            loader: { try await people.assets(personId: personID).map(AssetLite.init) })
    }

    func testFavoriteAndDelayedKeyFaceUseStableBulkUpdatesAndRefreshTheCachedThumbnail() async throws {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 2, height: 2), format: format)
        let old = renderer.pngData { context in UIColor.red.setFill(); context.fill(CGRect(x: 0, y: 0, width: 2, height: 2)) }
        let fresh = renderer.pngData { context in UIColor.blue.setFill(); context.fill(CGRect(x: 0, y: 0, width: 2, height: 2)) }
        let id = UUID().uuidString, chosen = UUID().uuidString
        var writes: [[String: Any]] = []
        var thumbnails = 0
        let accepted = try JSONSerialization.data(withJSONObject: [["id": id, "success": true]])
        MockURLProtocol.responseProvider = { request in
            if request.url?.path == "/api/people/\(id)/thumbnail" {
                thumbnails += 1
                return Self.response(request, data: thumbnails < 3 ? old : fresh)
            }
            XCTAssertEqual(request.httpMethod, "PUT")
            XCTAssertEqual(request.url?.path, "/api/people")
            guard let item = (Self.body(request)["people"] as? [[String: Any]])?.first else {
                XCTFail("The bulk update must contain a person item")
                return Self.response(request, status: 400, data: Data())
            }
            XCTAssertEqual(item["id"] as? String, id)
            writes.append(item)
            return Self.response(request, data: accepted)
        }
        let repository = PeopleRepository(api: api)
        try await repository.setFavorite(id, to: true)
        try await repository.setKeyPhoto(id, assetID: chosen)
        XCTAssertEqual(writes.count, 2)
        XCTAssertEqual(writes[0]["isFavorite"] as? Bool, true)
        XCTAssertNil(writes[0]["featureFaceAssetId"])
        XCTAssertEqual(writes[1]["featureFaceAssetId"] as? String, chosen)
        XCTAssertGreaterThanOrEqual(thumbnails, 3, "The accepted update must wait past the worker's old thumbnail")
        let key = "/people/\(id)/thumbnail"
        let image = try XCTUnwrap(ImageMemoryCache.shared.image(for: ImageCache.memoryKey(key, 600)))
        XCTAssertEqual(Self.centerPixel(image), Self.centerPixel(try XCTUnwrap(UIImage(data: fresh))))
        XCTAssertNotEqual(Self.centerPixel(image), Self.centerPixel(try XCTUnwrap(UIImage(data: old))))
        await ImageCache.shared.remove(key: key, maxPixelSize: 600)
    }

    func testFaceReadsAndReassignmentUseTheAssetAndDestinationPersonContracts() async throws {
        let assetID = UUID().uuidString, target = UUID().uuidString, face = UUID().uuidString
        let encoded = try JSONEncoder.immich.encode(PersonDTO(id: target, name: "Target", birthDate: nil, thumbnailPath: nil, isHidden: false))
        var reads = 0, writes = 0
        let faceData = try JSONSerialization.data(withJSONObject: [[
            "id": face, "imageWidth": 200, "imageHeight": 100, "boundingBoxX1": 10,
            "boundingBoxY1": 10, "boundingBoxX2": 60, "boundingBoxY2": 60, "person": NSNull(),
        ]])
        MockURLProtocol.responseProvider = { request in
            if request.httpMethod == "GET" {
                reads += 1
                XCTAssertEqual(request.url?.path, "/api/faces")
                let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems
                XCTAssertEqual(query?.first(where: { $0.name == "id" })?.value, assetID)
                return Self.response(request, data: faceData)
            }
            writes += 1
            XCTAssertEqual(request.httpMethod, "PUT")
            XCTAssertEqual(request.url?.path, "/api/faces/\(target)")
            XCTAssertEqual(Self.body(request)["id"] as? String, face)
            return Self.response(request, data: encoded)
        }
        let repository = PeopleRepository(api: api)
        let faces = try await repository.faces(in: assetID)
        XCTAssertEqual(faces.map(\.id), [face])
        let updated = try await repository.reassign(faceID: face, to: target)
        XCTAssertEqual(updated.id, target)
        XCTAssertEqual(reads, 1)
        XCTAssertEqual(writes, 1)
    }

    private static func centerPixel(_ image: UIImage) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: 4)
        guard let source = image.cgImage else { XCTFail("The fixture must decode real pixels"); return [] }
        bytes.withUnsafeMutableBytes { raw in
            guard let context = CGContext(data: raw.baseAddress, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
                XCTFail("The pixel buffer must be usable"); return
            }
            context.draw(source, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        }
        return bytes
    }

    private func newSnapshotKey() -> String {
        let key = "people-retrieval-\(UUID().uuidString)"
        snapshotKeys.append(key)
        return key
    }

    private func stubLaterPageFailure(record: @escaping (Int) -> Void) {
        MockURLProtocol.responseProvider = { request in
            let page = Self.body(request)["page"] as? Int ?? 0
            record(page)
            if page == 1 {
                return Self.response(request, data: Self.page(ids: [Self.assetID(0), Self.assetID(1)],
                    total: 3, nextPage: "2"))
            }
            return Self.response(request, status: 503, data: Data(#"{"message":"Try again later"}"#.utf8))
        }
    }

    private nonisolated static func assetID(_ index: Int) -> String {
        String(format: "00000000-0000-4000-8000-%012d", index)
    }

    private nonisolated static func body(_ request: URLRequest) -> [String: Any] {
        guard let data = request.httpBody ?? MockURLProtocol.lastRequestBody,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            XCTFail("The production person request must carry a JSON body")
            return [:]
        }
        return object
    }

    private nonisolated static func page(ids: [String], total: Int, nextPage: String? = nil) -> Data {
        let items: [[String: Any]] = ids.map { id in
            ["id": id, "type": "IMAGE", "originalFileName": "photo.jpg",
             "fileCreatedAt": "2026-08-08T01:00:00.000Z", "localDateTime": "2026-08-08T08:00:00.000Z",
             "isFavorite": false, "isArchived": false, "isTrashed": false,
             "exifInfo": ["exifImageWidth": 4000, "exifImageHeight": 3000]]
        }
        return try! JSONSerialization.data(withJSONObject: ["assets": [
            "items": items, "total": total, "nextPage": nextPage.map { $0 as Any } ?? NSNull(),
        ]])
    }

    private nonisolated static func peoplePage(ids: [String], hasNextPage: Bool) -> Data {
        let people = ids.map { ["id": $0, "name": "Person \($0)", "isHidden": false] as [String: Any] }
        return try! JSONSerialization.data(withJSONObject: ["people": people, "hasNextPage": hasNextPage])
    }

    private nonisolated static func response(_ request: URLRequest, status: Int = 200, data: Data)
        -> (Data?, URLResponse?, Error?) {
        (data, HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil), nil)
    }
}
