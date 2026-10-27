import UIKit
import XCTest
@testable import ImmichApp

@MainActor
final class PhotoPreviewSourceTests: XCTestCase {
    override func tearDown() async throws {
        MockURLProtocol.reset()
        try await super.tearDown()
    }

    func testMappedLocalPreviewUsesTheEditedServerEndpointAndInvalidatesItsServerCache() async throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        let oldPreview = fixture.image(width: 10)
        ImageMemoryCache.shared.insert(oldPreview, for: fixture.serverMemoryKey)
        XCTAssertTrue(fixture.loader.hasPreview(for: fixture.localID))
        XCTAssertTrue(fixture.loader.cachedImage(for: fixture.localID) === oldPreview)

        await fixture.loader.invalidate(fixture.localID)
        XCTAssertFalse(fixture.loader.hasPreview(for: fixture.localID))
        XCTAssertNil(ImageMemoryCache.shared.image(for: fixture.serverMemoryKey))
        fixture.stub(width: 20)
        let editedResult = await fixture.loader.image(for: fixture.localID)
        let edited = try XCTUnwrap(editedResult)
        XCTAssertEqual(edited.size.width, 20)
        XCTAssertTrue(fixture.loader.cachedImage(for: fixture.localID) === edited)
        XCTAssertTrue(fixture.loader.hasPreview(for: fixture.localID))
        XCTAssertTrue(fixture.localRequests.isEmpty)
        let request = try XCTUnwrap(MockURLProtocol.lastRequest)
        XCTAssertEqual(request.url?.path, "/api/assets/\(fixture.serverID)/thumbnail")
        let query = try XCTUnwrap(URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems)
        XCTAssertEqual(query.first { $0.name == "edited" }?.value, "true")
        XCTAssertEqual(query.first { $0.name == "size" }?.value, "preview")

        // Invalidation must remove L2 as well as L1 for the mapped server source.
        await fixture.loader.invalidate(fixture.localID)
        fixture.stub(width: 30)
        let reloadedResult = await fixture.loader.image(for: fixture.localID)
        let reloaded = try XCTUnwrap(reloadedResult)
        XCTAssertEqual(reloaded.size.width, 30)
        await fixture.loader.invalidate(fixture.localID)
    }

    func testUnmappedLocalPreviewNeverRequestsAServerResource() async throws {
        let fixture = try Fixture(mapped: false)
        defer { fixture.close() }
        fixture.stub(width: 20)
        let localResult = await fixture.loader.image(for: fixture.localID)
        let local = try XCTUnwrap(localResult)
        XCTAssertTrue(local === fixture.localImage)
        XCTAssertEqual(fixture.localRequests, [fixture.localID])
        XCTAssertNil(MockURLProtocol.lastRequest)
        fixture.loader.prefetch([fixture.localID])
        XCTAssertNil(MockURLProtocol.lastRequest)
    }

    func testMappedLocalPreviewFallsBackToPhotoKitWhenServerIsUnavailable() async throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        MockURLProtocol.mockError = URLError(.notConnectedToInternet)
        let localResult = await fixture.loader.image(for: fixture.localID)
        let local = try XCTUnwrap(localResult)
        XCTAssertTrue(local === fixture.localImage)
        XCTAssertEqual(fixture.localRequests, [fixture.localID])
        XCTAssertFalse(fixture.loader.hasPreview(for: fixture.localID), "An original fallback must not mask later server edits")
        XCTAssertEqual(MockURLProtocol.lastRequest?.url?.path, "/api/assets/\(fixture.serverID)/thumbnail")

        // Once available, the server's edited preview must replace the fallback.
        fixture.stub(width: 20)
        let serverResult = await fixture.loader.image(for: fixture.localID)
        let server = try XCTUnwrap(serverResult)
        XCTAssertEqual(server.size.width, 20)
        XCTAssertEqual(fixture.localRequests.count, 1)
        await fixture.loader.invalidate(fixture.localID)
    }

    @MainActor
    private final class Fixture {
        let directory: URL
        let serverID = UUID().uuidString
        let localID = LocalPhotoLibrary.assetID(for: UUID().uuidString)
        let session = MockSessionManager()
        let localImage: UIImage
        var localRequests: [String] = []
        let mapped: Bool
        let cache: ImageCache
        lazy var loader = PhotoPreviewLoader(session: session, imageCache: cache,
            serverIDForLocalAsset: { [unowned self] identifier in
                guard self.mapped, identifier == LocalPhotoLibrary.localIdentifier(from: self.localID) else { return nil }
                return self.serverID
            },
            localPreview: { [unowned self] id in
                self.localRequests.append(id)
                return self.localImage
            })
        var serverMemoryKey: String {
            ImageCache.memoryKey("\(serverID)-preview", PhotoPreviewLoader.maxPixelSize)
        }

        init(mapped: Bool = true) throws {
            MockURLProtocol.reset()
            self.mapped = mapped
            directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            cache = ImageCache(diskCacheURL: directory)
            let format = UIGraphicsImageRendererFormat()
            format.scale = 1
            localImage = UIGraphicsImageRenderer(size: CGSize(width: 5, height: 10), format: format).image { _ in }
            try session.setServer("https://test.example.com")
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [MockURLProtocol.self]
            session.imageAPI = APIClient(session: session, urlSession: URLSession(configuration: configuration))
        }

        func image(width: Int) -> UIImage {
            let format = UIGraphicsImageRendererFormat()
            format.scale = 1
            return UIGraphicsImageRenderer(size: CGSize(width: width, height: 10), format: format).image { context in
                UIColor.blue.setFill()
                context.fill(CGRect(x: 0, y: 0, width: width, height: 10))
            }
        }

        func stub(width: Int) {
            MockURLProtocol.reset()
            MockURLProtocol.mockData = image(width: width).pngData()
            MockURLProtocol.mockResponse = HTTPURLResponse(url: URL(string: "https://test.example.com/api")!,
                statusCode: 200, httpVersion: nil, headerFields: nil)
        }

        func close() {
            ImageMemoryCache.shared.remove(for: serverMemoryKey)
            try? FileManager.default.removeItem(at: directory)
        }
    }
}
