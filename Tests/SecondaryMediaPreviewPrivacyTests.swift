import SwiftUI
import UIKit
import XCTest
@testable import ImmichApp

@MainActor
final class SecondaryMediaPreviewPrivacyTests: XCTestCase {
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

    private func cache(_ id: String, color: UIColor, size: String = "thumbnail", pixels: Int = 600) -> String {
        let image = UIGraphicsImageRenderer(size: CGSize(width: 8, height: 8)).image { context in
            color.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        }
        let key = ImageCache.memoryKey("\(id)-\(size)", pixels)
        ImageMemoryCache.shared.insert(image, for: key)
        return key
    }


}
