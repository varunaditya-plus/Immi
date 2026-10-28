import Foundation
import XCTest
@testable import ImmichApp

@MainActor
final class BackupAlbumOwnershipTests: XCTestCase {
    private var repository: AlbumRepository!

    override func setUp() async throws {
        try await super.setUp()
        MockURLProtocol.reset()
        let session = MockSessionManager()
        try session.setServer("https://backup-album-ownership.example")
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        repository = AlbumRepository(api: APIClient(
            session: session, urlSession: URLSession(configuration: configuration)))
    }

    override func tearDown() async throws {
        repository = nil
        MockURLProtocol.reset()
        try await super.tearDown()
    }

    // Ownership fields follow the upstream contracts:
    // https://github.com/immich-app/immich/blob/v2.0.0/server/src/dtos/album.dto.ts
    // https://github.com/immich-app/immich/blob/main/server/src/dtos/album.dto.ts
    func testLegacyOwnedAlbumSharedOutwardIsReusedWithoutAV3OnlyQuery() async throws {
        stub("""
        [{"id":"legacy-owned","albumName":"Camera","ownerId":"current-user",
          "shared":true,"assetCount":2,"createdAt":"2026-10-01T00:00:00.000Z"}]
        """)

        let album = try await repository.ownedAlbum(named: "Camera", ownerID: "current-user")

        XCTAssertEqual(album?.id, "legacy-owned")
        XCTAssertEqual(album?.ownerId, "current-user")
        XCTAssertEqual(album?.shared, true)
        let request = try XCTUnwrap(MockURLProtocol.lastRequest)
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertEqual(request.url?.path, "/api/albums")
        XCTAssertNil(request.url?.query, "v2 does not support the v3 isOwned query parameter")
    }

    func testV3OwnedAlbumWinsOverForeignAndUnknownSameNameAlbums() async throws {
        stub("""
        [
          {"id":"foreign","albumName":"Camera","shared":true,"albumUsers":[
            {"user":{"id":"other-user"},"role":"owner"},
            {"user":{"id":"current-user"},"role":"editor"}]},
          {"id":"unknown","albumName":"Camera"},
          {"id":"owned","albumName":"Camera","shared":true,"albumUsers":[
            {"user":{"id":"friend"},"role":"editor"},
            {"user":{"id":"current-user"},"role":"owner"}]}
        ]
        """)

        let album = try await repository.ownedAlbum(named: "Camera", ownerID: "current-user")

        XCTAssertEqual(album?.id, "owned")
        XCTAssertEqual(album?.ownerId, "current-user")
        XCTAssertEqual(album?.shared, true)
    }

    func testForeignEditorAndViewerAlbumsAreNeverBackupDestinations() async throws {
        for role in ["editor", "viewer"] {
            stub("""
            [{"id":"foreign-\(role)","albumName":"Camera","shared":true,"albumUsers":[
              {"user":{"id":"other-user"},"role":"owner"},
              {"user":{"id":"current-user"},"role":"\(role)"}]}]
            """)

            let album = try await repository.ownedAlbum(named: "Camera", ownerID: "current-user")

            XCTAssertNil(album, "A shared \(role) album must not receive automatic backup placement")
        }
    }

    func testUnknownSameNameOwnershipDoesNotProveAnOwnedAlbumIsAbsent() async throws {
        for ownership in ["", ",\"albumUsers\":[]",
                          ",\"albumUsers\":[{\"user\":{\"id\":\"current-user\"},\"role\":\"editor\"}]"] {
            stub("""
            [{"id":"unknown","albumName":"Camera"\(ownership)}]
            """)

            do {
                _ = try await repository.ownedAlbum(named: "Camera", ownerID: "current-user")
                XCTFail("An incomplete same-name response must not permit album creation")
            } catch {
                XCTAssertTrue(error is AlbumOwnershipUnavailableError)
            }
        }
    }

    func testUnrelatedUnknownOwnershipDoesNotBlockNamedAbsence() async throws {
        stub("""
        [{"id":"unrelated","albumName":"Other","albumUsers":[]}]
        """)

        let album = try await repository.ownedAlbum(named: "Camera", ownerID: "current-user")

        XCTAssertNil(album)
    }

    func testForeignLegacyOwnerDoesNotBecomeABackupDestination() async throws {
        stub("""
        [{"id":"foreign","albumName":"Camera","ownerId":"other-user","shared":true}]
        """)

        let album = try await repository.ownedAlbum(named: "Camera", ownerID: "current-user")

        XCTAssertNil(album)
    }

    func testFailedListingPropagatesInsteadOfReportingAbsence() async throws {
        stub("{}", status: 500)

        do {
            _ = try await repository.ownedAlbum(named: "Camera", ownerID: "current-user")
            XCTFail("A failed request cannot prove that the destination is absent")
        } catch let error as APIError {
            guard case .server(let status, _) = error else {
                XCTFail("Expected the original server failure, got \(error)")
                return
            }
            XCTAssertEqual(status, 500)
        }
    }

    private func stub(_ json: String, status: Int = 200) {
        MockURLProtocol.mockData = Data(json.utf8)
        MockURLProtocol.mockResponse = HTTPURLResponse(
            url: URL(string: "https://backup-album-ownership.example/api/albums")!,
            statusCode: status, httpVersion: nil, headerFields: nil)
    }
}
