import Foundation
import SwiftData
import XCTest
@testable import ImmichApp

@MainActor
final class PhotoMapRepositoryTests: XCTestCase {
    private var directory: URL!
    private var store: SwiftDataManager!

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("photo-map-repository-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        store = SwiftDataManager(storeURL: directory.appendingPathComponent("test.store"),
            backupJournalURL: directory.appendingPathComponent("backup.json"))
        MockURLProtocol.reset()
    }

    override func tearDown() async throws {
        MockURLProtocol.reset()
        let container = store.modelContainer
        store = nil
        try container.erase()
        try? FileManager.default.removeItem(at: directory)
        try await super.tearDown()
    }

    func testMapMetadataFollowsEveryContinuationAndPreservesTimelineAndExifFilters() async throws {
        let repository = PhotoMapAssetRepository(api: try api(), dataManager: store)
        var bodies: [[String: Any]] = []
        MockURLProtocol.responseProvider = { request in
            let body = Self.body(request)
            bodies.append(body)
            let page = body["page"] as? Int
            switch page {
            case 1: return Self.response(request, items: [Self.asset("first")], next: "4")
            case 4: return Self.response(request, items: [Self.asset("first"), Self.asset("second")], next: "9")
            case 9: return Self.response(request, items: [Self.asset("last")], next: nil)
            default: return (nil, nil, URLError(.unsupportedURL))
            }
        }

        let assets = try await repository.allAssets()

        XCTAssertEqual(assets.map(\.id), ["first", "second", "last"])
        XCTAssertEqual(bodies.compactMap { $0["page"] as? Int }, [1, 4, 9])
        XCTAssertTrue(bodies.allSatisfy { $0["visibility"] as? String == "timeline" })
        XCTAssertTrue(bodies.allSatisfy { $0["withExif"] as? Bool == true })
        XCTAssertTrue(bodies.allSatisfy { $0["size"] as? Int == 1_000 })
        XCTAssertTrue(bodies.allSatisfy { $0["order"] as? String == "desc" })
    }

    func testArchivedLockedAndTrashedMetadataCannotEnterAMapCollection() async throws {
        let repository = PhotoMapAssetRepository(api: try api(), dataManager: store)
        MockURLProtocol.responseProvider = { request in
            Self.response(request, items: [Self.asset("public"), Self.asset("archive", visibility: "archive"),
                Self.asset("locked", visibility: "locked"), Self.asset("trash", trashed: true)], next: nil)
        }

        let assets = try await repository.allAssets()

        XCTAssertEqual(assets.map(\.id), ["public"])
        XCTAssertTrue(store.privateAssetIDs.contains("locked"))
        XCTAssertTrue(store.archivedAssetIDs.contains("archive"))
    }

    func testALaterPageFailureThrowsInsteadOfReturningOnlyTheFirstLocationsPhotos() async throws {
        let repository = PhotoMapAssetRepository(api: try api(), dataManager: store)
        var requests = 0
        MockURLProtocol.responseProvider = { request in
            requests += 1
            if requests == 1 { return Self.response(request, items: [Self.asset("partial")], next: "2") }
            return (nil, nil, URLError(.notConnectedToInternet))
        }

        do {
            _ = try await repository.allAssets()
            XCTFail("A location collection cannot silently stop at its first metadata page")
        } catch APIError.notConnected {
        } catch { XCTFail("Expected the later-page network failure, received \(error)") }
        XCTAssertEqual(requests, 2)
    }

    private func api() throws -> APIClient {
        let session = MockSessionManager()
        try session.setServer("https://map-pagination.example")
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        return APIClient(session: session, urlSession: URLSession(configuration: configuration))
    }

    private nonisolated static func body(_ request: URLRequest) -> [String: Any] {
        let bytes = request.httpBody ?? MockURLProtocol.lastRequestBody ?? Data()
        return (try? JSONSerialization.jsonObject(with: bytes)) as? [String: Any] ?? [:]
    }

    private nonisolated static func asset(_ id: String, visibility: String = "timeline", trashed: Bool = false) -> [String: Any] {
        ["id": id, "type": "IMAGE", "originalFileName": "\(id).jpg", "isFavorite": false,
         "fileCreatedAt": "2026-10-01T00:00:00.000Z", "localDateTime": "2026-10-01T00:00:00.000Z",
         "isArchived": visibility == "archive", "visibility": visibility, "isTrashed": trashed]
    }

    private nonisolated static func response(_ request: URLRequest, items: [[String: Any]], next: String?)
        -> (Data?, HTTPURLResponse?, Error?) {
        let data = try? JSONSerialization.data(withJSONObject: [
            "assets": ["items": items, "total": 1, "nextPage": next as Any? ?? NSNull()],
        ])
        return (data, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil), nil)
    }
}
