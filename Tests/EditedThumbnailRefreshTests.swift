import CryptoKit
import SwiftUI
import UIKit
import XCTest
@testable import ImmichApp

@MainActor
final class EditedThumbnailRefreshTests: SimulatorHostedTestCase {
    private var session: ThumbnailEditingSession!
    private var ownerDirectory: URL!

    override func tearDown() async throws {
        try await super.tearDown()
        session = nil
        if let ownerDirectory, FileManager.default.fileExists(atPath: ownerDirectory.path) {
            try FileManager.default.removeItem(at: ownerDirectory)
        }
    }

    func testSavingAndRevertingUpdatesAlreadyMountedGridAndFilmstripPixelsWithoutAnAssetSnapshot() async throws {
        try startSyntheticSession()
        let id = "thumbnail-edit-\(UUID())"
        let asset = AssetLite(id: id, isVideo: false, ratio: 1, thumbhash: nil, createdAt: .now)
        let window = try await host(VStack(spacing: 20) {
            PhotoGridView(sections: [.init(id: "synthetic", title: "Synthetic", assets: [asset])],
                configuration: .init(columns: 3, showsSectionHeaders: false),
                isSelecting: .constant(false), selectedIDs: .constant([]), menuActions: { _ in [] }, session: session)
                .frame(height: 300)
            PhotoFilmstripView(assets: [asset], currentAssetID: id, onSelect: { _ in }, session: session)
                .frame(height: 64)
        })
        try await waitUntil("Both production thumbnail cells have loaded their synthetic original") {
            guard let grid = self.gridCell(in: window), let strip = self.stripCell(in: window) else { return false }
            return self.level(grid.displayedImage) != nil && self.level(self.stripImage(strip)) != nil
        }
        let grid = try XCTUnwrap(gridCell(in: window))
        let strip = try XCTUnwrap(stripCell(in: window))
        let originalGrid = try XCTUnwrap(level(grid.displayedImage))
        let originalStrip = try XCTUnwrap(level(stripImage(strip)))
        XCTAssertEqual(originalGrid, 90, accuracy: 5)
        XCTAssertEqual(originalStrip, 90, accuracy: 5)
        var edited = MediaEditDocument(); edited.photo[.exposure] = 0.8

        try save(edited, id: id)

        try await waitUntil("An actual store Save replaces pixels in the existing cells") {
            (self.level(grid.displayedImage) ?? 0) > originalGrid + 35
                && (self.level(self.stripImage(strip)) ?? 0) > originalStrip + 35
        }
        XCTAssertTrue(gridCell(in: window) === grid)
        XCTAssertTrue(stripCell(in: window) === strip)

        try save(MediaEditDocument(), id: id)

        try await waitUntil("An identity Revert restores the same mounted cells to the original pixels") {
            abs((self.level(grid.displayedImage) ?? 0) - originalGrid) < 5
                && abs((self.level(self.stripImage(strip)) ?? 0) - originalStrip) < 5
        }
        XCTAssertTrue(gridCell(in: window) === grid)
        XCTAssertTrue(stripCell(in: window) === strip)
    }

    func testVisibleFilmstripAnnouncesTheTrimmedDurationThenRestoresItAfterRevert() async throws {
        try startSyntheticSession()
        let id = "thumbnail-video-\(UUID())"
        let asset = AssetLite(id: id, isVideo: true, ratio: 1, thumbhash: nil, createdAt: .now, duration: 4)
        let window = try await host(PhotoFilmstripView(assets: [asset], currentAssetID: id, onSelect: { _ in }, session: session)
            .frame(height: 64))
        try await waitUntil("The actual filmstrip exposes its original four-second video") {
            guard let cell = self.stripCell(in: window) else { return false }
            return cell.accessibilityValue == "Duration: 0:04" && self.stripImage(cell) != nil
        }
        let cell = try XCTUnwrap(stripCell(in: window))
        var trimmed = MediaEditDocument(); trimmed.kind = .video; trimmed.video.trimEnd = 2

        try save(trimmed, id: id)

        try await waitUntil("Saving a trim updates the mounted cell's actual accessibility duration") {
            cell.accessibilityValue == "Duration: 0:02"
        }
        XCTAssertTrue(stripCell(in: window) === cell)
        XCTAssertEqual(asset.duration, 4, "Presentation metadata must not replace the original asset model")
        var reverted = MediaEditDocument(); reverted.kind = .video

        try save(reverted, id: id)

        try await waitUntil("Identity Revert restores the same visible cell's original duration") {
            cell.accessibilityValue == "Duration: 0:04"
        }
        XCTAssertTrue(stripCell(in: window) === cell)
    }

    private func startSyntheticSession() throws {
        let owner = BackupQueueOwner(server: "https://thumbnail-edit.example.invalid/api", userID: "synthetic-\(UUID())")
        let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
        let ownerKey = SHA256.hash(data: try encoder.encode(owner)).map { String(format: "%02x", $0) }.joined()
        ownerDirectory = URL.applicationSupportDirectory.appendingPathComponent("media-edits", isDirectory: true)
            .appendingPathComponent(ownerKey, isDirectory: true)
        session = ThumbnailEditingSession(owner: owner, bytes: try sourceBytes())
    }

    private func save(_ document: MediaEditDocument, id: String) throws {
        let store = MediaEditStore.shared
        store.configure(session: session)
        let record = try MediaEditRecord(type: MediaEditingPipeline.recordType,
            schemaVersion: MediaEditingPipeline.schemaVersion, sourceFingerprint: "synthetic-original", value: document)
        try store.save(record, using: store.capture(assetID: id, sourceFingerprint: record.sourceFingerprint))
    }

    private func gridCell(in window: UIWindow) -> PhotoGridCell? {
        views(window).compactMap { $0 as? PhotoGridCell }.first
    }

    private func stripCell(in window: UIWindow) -> UICollectionViewCell? {
        func find(_ controller: UIViewController) -> PhotoFilmstripController? {
            if let strip = controller as? PhotoFilmstripController { return strip }
            return controller.children.lazy.compactMap(find).first
        }
        guard let root = window.rootViewController, let strip = find(root) else { return nil }
        return views(strip.view).compactMap { $0 as? UICollectionView }.first?
            .cellForItem(at: IndexPath(item: 0, section: 0))
    }

    private func stripImage(_ cell: UICollectionViewCell) -> UIImage? {
        cell.contentView.subviews.compactMap { $0 as? UIImageView }.first?.image
    }

    private func views(_ view: UIView) -> [UIView] { [view] + view.subviews.flatMap(views) }

    private func level(_ image: UIImage?) -> Double? {
        guard let cg = image?.cgImage else { return nil }
        var pixel = [UInt8](repeating: 0, count: 4)
        let drawn = pixel.withUnsafeMutableBytes { bytes -> Bool in
            guard let context = CGContext(data: bytes.baseAddress, width: 1, height: 1, bitsPerComponent: 8,
                bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.draw(cg, in: CGRect(x: 0, y: 0, width: 1, height: 1))
            return true
        }
        return drawn ? Double(pixel[0]) : nil
    }

    private func sourceBytes() throws -> Data {
        let format = UIGraphicsImageRendererFormat(); format.scale = 1; format.opaque = true
        let image = UIGraphicsImageRenderer(size: CGSize(width: 64, height: 64), format: format).image { context in
            UIColor(white: 90 / 255, alpha: 1).setFill(); context.fill(CGRect(x: 0, y: 0, width: 64, height: 64))
        }
        return try XCTUnwrap(image.pngData())
    }
}

@MainActor
private final class ThumbnailEditingSession: MockSessionManager {
    private let owner: BackupQueueOwner
    private let bytes: Data
    init(owner: BackupQueueOwner, bytes: Data) {
        self.owner = owner; self.bytes = bytes
        super.init()
        isLoggedIn = true
    }
    override var backupQueueOwner: BackupQueueOwner? { owner }
    override var imageAPI: APIClient { ThumbnailEditingAPI(session: self, bytes: bytes) }
}

@MainActor
private final class ThumbnailEditingAPI: APIClient {
    private let bytes: Data
    init(session: SessionManager, bytes: Data) { self.bytes = bytes; super.init(session: session) }
    override func rawData(_ endpoint: Endpoint) async throws -> Data { bytes }
}
