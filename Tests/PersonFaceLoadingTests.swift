import Foundation
import UIKit
import XCTest
@testable import ImmichApp

@MainActor
final class PersonFaceLoadingTests: XCTestCase {
    private var session: MockSessionManager!
    private var transport: URLSession!
    private var api: APIClient!
    private var cacheKeys: [String] = []

    override func setUp() async throws {
        try await super.setUp()
        MockURLProtocol.reset()
        session = MockSessionManager()
        try session.setServer("https://faces.example")
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        transport = URLSession(configuration: configuration)
        api = APIClient(session: session, urlSession: transport)
    }

    override func tearDown() async throws {
        transport.invalidateAndCancel()
        for key in cacheKeys { await ImageCache.shared.remove(key: key, maxPixelSize: 600) }
        cacheKeys.removeAll()
        api = nil
        transport = nil
        session = nil
        MockURLProtocol.reset()
        try await super.tearDown()
    }

    func testFailedFaceMetadataDoesNotCacheAWholePhotoAndTheNextRequestRetriesTheFace() async throws {
        let preview = Self.preview()
        for firstStatus in [503, 200] {
            let assetID = UUID().uuidString, personID = UUID().uuidString
            let faces = try Self.faces(personID: personID)
            let loader = PhotoThumbnailLoader(session: session, faceAPI: api)
            cacheKeys.append(loader.faceCacheKey(for: assetID, personID: personID))
            var faceRequests = 0, previews = 0
            MockURLProtocol.responseProvider = { request in
                XCTAssertEqual(request.httpMethod, "GET")
                let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
                if request.url?.path == "/api/faces" {
                    faceRequests += 1
                    XCTAssertEqual(query.first(where: { $0.name == "id" })?.value, assetID)
                    if faceRequests == 1 {
                        return Self.response(request, status: firstStatus, data: Data("invalid face response".utf8))
                    }
                    return Self.response(request, data: faces)
                }
                XCTAssertEqual(request.url?.path, "/api/assets/\(assetID)/thumbnail")
                XCTAssertEqual(query.first(where: { $0.name == "size" })?.value, "preview")
                XCTAssertEqual(query.first(where: { $0.name == "cropped" })?.value, "false")
                XCTAssertEqual(query.first(where: { $0.name == "edited" })?.value, "true")
                previews += 1
                return Self.response(request, data: preview)
            }

            let failed = await loader.faceImage(for: assetID, personID: personID)

            XCTAssertNil(failed, "A transport or decoding failure must remain retryable")
            XCTAssertNil(loader.cachedFaceImage(for: assetID, personID: personID))
            XCTAssertEqual(previews, 0, "Failure to read face bounds must not store the ordinary preview as a face")

            let retried = await loader.faceImage(for: assetID, personID: personID)
            let cropped = try XCTUnwrap(retried)

            XCTAssertEqual(faceRequests, 2)
            XCTAssertEqual(previews, 1)
            XCTAssertEqual(cropped.size.width, cropped.size.height, accuracy: 1)
            let pixel = Self.centerPixel(cropped)
            XCTAssertGreaterThan(pixel[0], 240)
            XCTAssertLessThan(pixel[2], 15, "The recovered face crop contains only the red left-hand subject")
            XCTAssertEqual(Self.centerPixel(try XCTUnwrap(loader.cachedFaceImage(for: assetID, personID: personID))), pixel)

            let cached = await loader.faceImage(for: assetID, personID: personID)
            XCTAssertEqual(Self.centerPixel(try XCTUnwrap(cached)), pixel)
            XCTAssertEqual(faceRequests, 2)
            XCTAssertEqual(previews, 1, "A successful crop should still use the cache on subsequent requests")
        }
    }

    func testSuccessfulMissingOrInvalidFaceBoundsKeepTheWholePhotoFallback() async throws {
        let preview = Self.preview()
        let expected = Self.centerPixel(try XCTUnwrap(UIImage(data: preview)))
        for missing in [true, false] {
            let assetID = UUID().uuidString, personID = UUID().uuidString
            let faces = try missing ? Data("[]".utf8) : Self.faces(personID: personID, invalidBounds: true)
            let loader = PhotoThumbnailLoader(session: session, faceAPI: api)
            cacheKeys.append(loader.faceCacheKey(for: assetID, personID: personID))
            var faceRequests = 0, previews = 0
            MockURLProtocol.responseProvider = { request in
                if request.url?.path == "/api/faces" {
                    faceRequests += 1
                    return Self.response(request, data: faces)
                }
                XCTAssertEqual(request.url?.path, "/api/assets/\(assetID)/thumbnail")
                previews += 1
                return Self.response(request, data: preview)
            }

            let result = await loader.faceImage(for: assetID, personID: personID)
            let image = try XCTUnwrap(result)

            XCTAssertEqual(image.size.width / image.size.height, 2, accuracy: 0.01)
            XCTAssertEqual(Self.centerPixel(image), expected)
            XCTAssertNotNil(loader.cachedFaceImage(for: assetID, personID: personID))
            let cached = await loader.faceImage(for: assetID, personID: personID)
            XCTAssertEqual(Self.centerPixel(try XCTUnwrap(cached)), expected)
            XCTAssertEqual(faceRequests, 1)
            XCTAssertEqual(previews, 1)
        }
    }

    private static func preview() -> Data {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: CGSize(width: 200, height: 100), format: format).pngData { context in
            UIColor.red.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 100, height: 100))
            UIColor.blue.setFill()
            context.fill(CGRect(x: 100, y: 0, width: 100, height: 100))
        }
    }

    private static func faces(personID: String, invalidBounds: Bool = false) throws -> Data {
        try JSONSerialization.data(withJSONObject: [[
            "id": "face", "imageWidth": 200, "imageHeight": 100,
            "boundingBoxX1": 10, "boundingBoxY1": 10,
            "boundingBoxX2": invalidBounds ? 5 : 60, "boundingBoxY2": 60,
            "person": ["id": personID, "name": "Synthetic", "isHidden": false],
        ]])
    }

    private static func centerPixel(_ image: UIImage) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: 4)
        guard let source = image.cgImage else { XCTFail("The fixture must decode real pixels"); return bytes }
        bytes.withUnsafeMutableBytes { raw in
            guard let context = CGContext(data: raw.baseAddress, width: 1, height: 1, bitsPerComponent: 8,
                bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
                XCTFail("The pixel buffer must be usable")
                return
            }
            context.draw(source, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        }
        return bytes
    }

    private nonisolated static func response(_ request: URLRequest, status: Int = 200, data: Data)
        -> (Data?, URLResponse?, Error?) {
        (data, HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil), nil)
    }
}
