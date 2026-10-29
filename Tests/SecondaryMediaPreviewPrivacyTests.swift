import SwiftUI
import UIKit
import XCTest
@testable import ImmichApp

@MainActor
final class SecondaryMediaPreviewPrivacyTests: XCTestCase {
    func testSharedLinkThumbnailRejectsPrivateAndRemovedPhotosAndKeepsAnArchivedReplacement() throws {
        let firstID = UUID().uuidString
        let archiveID = UUID().uuidString
        let store = SwiftDataManager.shared
        let keys = [cache(firstID, color: .red), cache(archiveID, color: .blue)]
        defer {
            keys.forEach { ImageMemoryCache.shared.remove(for: $0) }
            try? store.setAssetVisibility([firstID, archiveID], to: "timeline")
            RemovedAssets.shared.restore([archiveID])
        }
        var archived = makeTestAsset(id: archiveID)
        archived.visibility = "archive"
        archived.isArchived = true
        try store.setAssetVisibility([archiveID], to: "archive")
        let link = try link(assets: [makeTestAsset(id: firstID), archived])
        let row = SharedLinkRow(link: link)
        let before = try pixels(in: row, size: CGSize(width: 320, height: 120))
        XCTAssertGreaterThan(before.red, 1_000)
        XCTAssertEqual(before.blue, 0)

        try store.setAssetVisibility([firstID], to: "locked")

        let locked = try pixels(in: row, size: CGSize(width: 320, height: 120))
        XCTAssertEqual(locked.red, 0, "The cached first photo must not remain visible after locking")
        XCTAssertGreaterThan(locked.blue, 1_000, "The row should choose another admissible photo, including an archive")
        RemovedAssets.shared.remove([archiveID])
        let removed = try pixels(in: row, size: CGSize(width: 320, height: 120))
        XCTAssertEqual(removed.red, 0)
        XCTAssertEqual(removed.blue, 0)
    }

    func testRetainedContextPreviewCannotRenderCachedMediaAfterLockOrRemoval() throws {
        let id = UUID().uuidString
        let store = SwiftDataManager.shared
        let keys = [cache(id, color: .red), cache(id, color: .red, size: "preview", pixels: 1400)]
        defer {
            keys.forEach { ImageMemoryCache.shared.remove(for: $0) }
            try? store.setAssetVisibility([id], to: "timeline")
            RemovedAssets.shared.restore([id])
        }
        let preview = AssetContextPreview(asset: AssetLite(makeTestAsset(id: id)), session: MockSessionManager())
        let size = CGSize(width: 320, height: 460)
        XCTAssertGreaterThan(try pixels(in: preview, size: size).red, 10_000)

        try store.setAssetVisibility([id], to: "locked")
        XCTAssertEqual(try pixels(in: preview, size: size).red, 0)

        try store.setAssetVisibility([id], to: "archive")
        XCTAssertGreaterThan(try pixels(in: preview, size: size).red, 10_000)
        RemovedAssets.shared.remove([id])
        XCTAssertEqual(try pixels(in: preview, size: size).red, 0)
    }

    func testContextPreviewPreservesAuthorizedLockedAndTrashScopes() throws {
        let id = UUID().uuidString
        let store = SwiftDataManager.shared
        let keys = [cache(id, color: .red), cache(id, color: .red, size: "preview", pixels: 1400)]
        defer {
            keys.forEach { ImageMemoryCache.shared.remove(for: $0) }
            try? store.setAssetVisibility([id], to: "timeline")
            RemovedAssets.shared.restore([id])
        }
        let asset = AssetLite(makeTestAsset(id: id))
        let session = MockSessionManager()
        let size = CGSize(width: 320, height: 460)
        try store.setAssetVisibility([id], to: "locked")
        let unlocked = AssetContextPreview(asset: asset, session: session,
            visibilityPolicy: AssetVisibilityPolicy(scope: .locked))
        XCTAssertGreaterThan(try pixels(in: unlocked, size: size).red, 10_000)

        try store.setAssetVisibility([id], to: "timeline")
        RemovedAssets.shared.remove([id], reason: .trashed)
        let trash = AssetContextPreview(asset: asset, session: session,
            visibilityPolicy: AssetVisibilityPolicy(removalScope: .trash))
        XCTAssertGreaterThan(try pixels(in: trash, size: size).red, 10_000)
        let ordinary = AssetContextPreview(asset: asset, session: session)
        XCTAssertEqual(try pixels(in: ordinary, size: size).red, 0)
    }

    func testSharedLinkCannotRenderExplicitPrivateMetadataWithoutLocalPrivacyRecords() throws {
        for visibility in ["locked", "hidden", "unknown"] {
            let id = UUID().uuidString
            let key = cache(id, color: .red)
            defer { ImageMemoryCache.shared.remove(for: key) }
            var asset = makeTestAsset(id: id)
            asset.visibility = visibility
            XCTAssertTrue(AssetVisibilityPolicy().allows(id: id))

            let row = SharedLinkRow(link: try link(assets: [asset]))

            XCTAssertEqual(try pixels(in: row, size: CGSize(width: 320, height: 120)).red, 0)
        }
    }

    private func cache(_ id: String, color: UIColor, size: String = "thumbnail", pixels: Int = 600) -> String {
        let image = UIGraphicsImageRenderer(size: CGSize(width: 8, height: 8)).image { context in
            color.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        }
        let key = ImageCache.memoryKey("\(id)-\(size)", pixels)
        ImageMemoryCache.shared.insert(image, for: key)
        return key
    }

    private func link(assets: [AssetResponseDTO]) throws -> SharedLinkDTO {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let encodedAssets = try JSONSerialization.jsonObject(with: encoder.encode(assets))
        let object: [String: Any] = ["id": UUID().uuidString, "key": "shared-key", "type": "INDIVIDUAL",
            "assets": encodedAssets]
        return try JSONDecoder.immich.decode(SharedLinkDTO.self, from: JSONSerialization.data(withJSONObject: object))
    }

    private func pixels<Content: View>(in content: Content, size: CGSize) throws -> (red: Int, blue: Int) {
        let renderer = ImageRenderer(content: content
            .environment(MockSessionManager() as SessionManager)
            .environment(\.colorScheme, .light)
            .frame(width: size.width, height: size.height)
            .background(.white))
        renderer.scale = 1
        let image = try XCTUnwrap(renderer.uiImage?.cgImage)
        var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
        try bytes.withUnsafeMutableBytes { buffer in
            let context = try XCTUnwrap(CGContext(data: buffer.baseAddress, width: image.width, height: image.height,
                bitsPerComponent: 8, bytesPerRow: image.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        }
        var red = 0
        var blue = 0
        for offset in stride(from: 0, to: bytes.count, by: 4) where bytes[offset + 3] > 200 {
            if bytes[offset] > 200, bytes[offset + 1] < 50, bytes[offset + 2] < 50 { red += 1 }
            if bytes[offset] < 50, bytes[offset + 1] < 50, bytes[offset + 2] > 200 { blue += 1 }
        }
        return (red, blue)
    }
}
