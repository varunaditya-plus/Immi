import Network
import SwiftUI
import UIKit
import XCTest
@testable import ImmichApp

@MainActor
final class SearchAlbumCoverPresentationTests: SimulatorHostedTestCase {
    private var server: SearchAlbumCoverHTTPServer?
    private var albumIDs: [String] = []
    private var imageIDs: [String] = []
    private var privateIDs: [String] = []

    override func tearDown() async throws {
        try await super.tearDown()
        albumIDs.forEach { AlbumCoverStore.shared.invalidate($0) }
        server?.stop()
        server = nil
        for id in privateIDs {
            try SwiftDataManager.shared.recordServerVisibility([makeTestAsset(id: id)])
        }
        for id in imageIDs {
            await ImageCache.shared.remove(key: "\(id)-thumbnail", maxPixelSize: 600)
        }
    }

    func testNonemptySearchAlbumWithoutAnExplicitCoverResolvesAndRendersItsFallback() async throws {
        let (album, server, session) = try await fixture(privateCover: false)

        let window = try await show(album, session: session)

        try await waitUntil("The Search album card resolves its fallback through real metadata and image requests") {
            AlbumCoverStore.shared.coverID(for: album) == server.fallbackID
                && self.cachedImage(server.fallbackID) != nil
        }
        XCTAssertEqual(server.metadataRequests.count, 1)
        assertRequest(try XCTUnwrap(server.metadataRequests.first), albumID: album.id, page: 1)
        XCTAssertEqual(server.thumbnailRequests, [server.fallbackID])
        let image = try await screenshot(window)
        try assertSquareGreenCover(in: image)
    }

    func testSearchAlbumWithAPrivateExplicitCoverPagesToAnAuthorizedFallbackWithoutLoadingPrivateBytes() async throws {
        let (album, server, session) = try await fixture(privateCover: true)
        let hiddenID = try XCTUnwrap(album.albumThumbnailAssetId)
        XCTAssertTrue(SwiftDataManager.shared.privateAssetIDs.contains(hiddenID))
        XCTAssertFalse(AssetVisibilityPolicy().allows(id: hiddenID))
        XCTAssertNil(AlbumCoverStore.shared.coverID(for: album))

        let window = try await show(album, session: session)

        try await waitUntil("The Search card skips the private first page and displays the authorized fallback") {
            AlbumCoverStore.shared.coverID(for: album) == server.fallbackID
                && self.cachedImage(server.fallbackID) != nil
        }
        XCTAssertEqual(server.metadataRequests.count, 2)
        for (index, request) in server.metadataRequests.enumerated() {
            assertRequest(request, albumID: album.id, page: index + 1)
        }
        XCTAssertEqual(server.thumbnailRequests, [server.fallbackID])
        XCTAssertNil(cachedImage(hiddenID), "A private explicit cover must never be fetched or rendered")
        XCTAssertFalse(AssetVisibilityPolicy().allows(id: hiddenID))
        let image = try await screenshot(window)
        try assertSquareGreenCover(in: image)
    }

    private func fixture(privateCover: Bool) async throws -> (AlbumResponseDTO, SearchAlbumCoverHTTPServer, MockSessionManager) {
        let albumID = UUID().uuidString
        let fallbackID = UUID().uuidString
        let privateID = privateCover ? UUID().uuidString : nil
        albumIDs.append(albumID)
        imageIDs.append(fallbackID)
        if let privateID { imageIDs.append(privateID) }
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 80, height: 80))
        let png = try XCTUnwrap(renderer.image { context in
            UIColor(red: 0.05, green: 0.7, blue: 0.12, alpha: 1).setFill()
            context.fill(CGRect(x: 0, y: 0, width: 80, height: 80))
        }.pngData())
        let ready = expectation(description: "Search album-cover loopback server is ready")
        let server = try SearchAlbumCoverHTTPServer(albumID: albumID, fallbackID: fallbackID,
            privateID: privateID, png: png, ready: ready)
        self.server = server
        await fulfillment(of: [ready], timeout: 3)
        let session = MockSessionManager()
        try session.setServer("http://127.0.0.1:\(try XCTUnwrap(server.port))")
        if let privateID {
            var hidden = makeTestAsset(id: privateID)
            hidden.visibility = "locked"
            privateIDs.append(privateID)
            try SwiftDataManager.shared.recordServerVisibility([hidden])
        }
        XCTAssertNil(cachedImage(fallbackID), "A new fixture must start without a decoded cover")
        let album = AlbumResponseDTO(id: albumID, albumName: "Search fallback album", description: nil, assetCount: 2,
            albumThumbnailAssetId: privateID, shared: false, createdAt: .distantPast, assets: nil)
        return (album, server, session)
    }

    private func show(_ album: AlbumResponseDTO, session: SessionManager) async throws -> UIWindow {
        try await host(SearchCollectionResultsView(people: [], albums: [album], groups: [], folders: [], allPeople: [],
            onOpen: { _ in }).environment(session))
    }

    private func cachedImage(_ id: String) -> UIImage? {
        ImageMemoryCache.shared.image(for: ImageCache.memoryKey("\(id)-thumbnail", 600))
    }

    private func assertRequest(_ request: [String: Any], albumID: String, page: Int,
                               file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(request["albumIds"] as? [String], [albumID], file: file, line: line)
        XCTAssertEqual(request["page"] as? Int, page, file: file, line: line)
        XCTAssertEqual(request["size"] as? Int, 1, file: file, line: line)
        XCTAssertEqual(request["order"] as? String, "desc", file: file, line: line)
        XCTAssertEqual(request["withExif"] as? Bool, false, file: file, line: line)
        XCTAssertNil(request["visibility"], "Album covers retain the shared component's archive-compatible scope", file: file, line: line)
    }

    private func assertSquareGreenCover(in image: UIImage, file: StaticString = #filePath, line: UInt = #line) throws {
        let source = try XCTUnwrap(image.cgImage, file: file, line: line)
        let width = source.width, height = source.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        try pixels.withUnsafeMutableBytes { buffer in
            let context = try XCTUnwrap(CGContext(data: buffer.baseAddress, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue), file: file, line: line)
            context.draw(source, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        var count = 0, minX = width, minY = height, maxX = 0, maxY = 0
        for y in 0..<height {
            for x in 0..<width {
                let index = (y * width + x) * 4
                if pixels[index] < 60, pixels[index + 1] > 130, pixels[index + 2] < 80 {
                    count += 1
                    minX = min(minX, x); maxX = max(maxX, x)
                    minY = min(minY, y); maxY = max(maxY, y)
                }
            }
        }
        XCTAssertGreaterThan(count, width * height / 30, "The actual Search card must render the HTTP image, not its gray placeholder", file: file, line: line)
        XCTAssertEqual(Double(maxX - minX), Double(maxY - minY), accuracy: 3,
            "The resolved Search cover must remain square", file: file, line: line)
    }
}

private final class SearchAlbumCoverHTTPServer: @unchecked Sendable {
    let fallbackID: String
    private let albumID: String
    private let privateID: String?
    private let png: Data
    private let listener: NWListener
    private let queue = DispatchQueue(label: "SearchAlbumCoverPresentationTests.HTTP")
    private let lock = NSLock()
    private var connections: [NWConnection] = []
    private var metadata: [[String: Any]] = []
    private var thumbnails: [String] = []
    var port: UInt16? { listener.port?.rawValue }
    var metadataRequests: [[String: Any]] { lock.withLock { metadata } }
    var thumbnailRequests: [String] { lock.withLock { thumbnails } }

    init(albumID: String, fallbackID: String, privateID: String?, png: Data, ready: XCTestExpectation) throws {
        self.albumID = albumID
        self.fallbackID = fallbackID
        self.privateID = privateID
        self.png = png
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
        listener.stateUpdateHandler = { state in
            if case .ready = state { ready.fulfill() }
            if case .failed(let error) = state { XCTFail("Search cover loopback startup failed: \(error)"); ready.fulfill() }
        }
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { connection.cancel(); return }
            self.connections.append(connection)
            connection.start(queue: self.queue)
            self.receive(connection, accumulated: Data())
        }
        listener.start(queue: queue)
    }

    func stop() {
        listener.cancel()
        queue.sync { connections.forEach { $0.cancel() }; connections.removeAll() }
    }

    private func receive(_ connection: NWConnection, accumulated: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, complete, error in
            guard let self, error == nil, let data else { connection.cancel(); return }
            let received = accumulated + data
            guard let headerEnd = received.range(of: Data("\r\n\r\n".utf8)),
                  let header = String(data: received[..<headerEnd.lowerBound], encoding: .utf8) else {
                if complete { connection.cancel() } else { self.receive(connection, accumulated: received) }
                return
            }
            let length = header.components(separatedBy: "\r\n").first { $0.lowercased().hasPrefix("content-length:") }
                .flatMap { Int($0.split(separator: ":", maxSplits: 1)[1].trimmingCharacters(in: .whitespaces)) } ?? 0
            let body = received[headerEnd.upperBound...]
            guard body.count >= length else { self.receive(connection, accumulated: received); return }
            let request = header.components(separatedBy: "\r\n").first?.split(separator: " ").map(String.init) ?? []
            let object = (try? JSONSerialization.jsonObject(with: Data(body.prefix(length)))) as? [String: Any] ?? [:]
            let response = self.response(method: request.first ?? "", target: request.dropFirst().first ?? "", body: object)
            let payload = Data("HTTP/1.1 \(response.0) Response\r\nContent-Length: \(response.1.count)\r\nContent-Type: \(response.2)\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n".utf8) + response.1
            connection.send(content: payload, completion: .contentProcessed { _ in connection.cancel() })
        }
    }

    private func response(method: String, target: String, body: [String: Any]) -> (Int, Data, String) {
        lock.withLock {
            let path = target.split(separator: "?", maxSplits: 1).first.map(String.init) ?? target
            if method == "POST", path == "/api/search/metadata" {
                metadata.append(body)
                guard body["albumIds"] as? [String] == [albumID] else { return (400, Data("{}".utf8), "application/json") }
                let page = body["page"] as? Int ?? 1
                let lockedPage = privateID != nil && page == 1
                let id = lockedPage ? privateID! : fallbackID
                let photo: [String: Any] = ["id": id, "type": "IMAGE", "originalFileName": "synthetic-cover.png",
                    "fileCreatedAt": "2026-10-01T12:00:00.000Z", "localDateTime": "2026-10-01T12:00:00.000Z",
                    "isFavorite": false, "isArchived": false, "isTrashed": false,
                    "visibility": lockedPage ? "locked" : "timeline"]
                let result: [String: Any] = ["assets": ["items": [photo], "total": privateID == nil ? 1 : 2,
                    "nextPage": lockedPage ? "2" as Any : NSNull()]]
                return (200, (try? JSONSerialization.data(withJSONObject: result)) ?? Data(), "application/json")
            }
            if method == "GET", let id = [fallbackID, privateID].compactMap({ $0 }).first(where: { path == "/api/assets/\($0)/thumbnail" }) {
                thumbnails.append(id)
                return (200, png, "image/png")
            }
            return (503, Data("{}".utf8), "application/json")
        }
    }
}
