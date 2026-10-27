import ImageIO
import UIKit
import UniformTypeIdentifiers
import XCTest
@testable import ImmichApp

final class SharePreviewThumbnailTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("share-preview-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: directory)
        directory = nil
    }

    func testLargeLandscapePreviewRetainsOnlyThumbnailSizedPixels() throws {
        let original = try imageFile(width: 4096, height: 3072)

        let preview = try XCTUnwrap(SharePreviewThumbnail.image(at: original))
        let pixels = try XCTUnwrap(preview.cgImage)

        XCTAssertEqual(pixels.width, 216)
        XCTAssertEqual(pixels.height, 162)
        XCTAssertLessThanOrEqual(pixels.bytesPerRow * pixels.height, 512 * 1024)
        XCTAssertEqual(preview.imageOrientation, .up)
    }

    func testLargePortraitPreviewPreservesItsAspectRatioWithinThePixelLimit() throws {
        let original = try imageFile(width: 3072, height: 4096)

        let pixels = try XCTUnwrap(SharePreviewThumbnail.image(at: original)?.cgImage)

        XCTAssertEqual(pixels.width, 162)
        XCTAssertEqual(pixels.height, 216)
        XCTAssertLessThanOrEqual(pixels.bytesPerRow * pixels.height, 512 * 1024)
    }

    func testPreviewAppliesExifRotationBeforeReturningTheBoundedImage() throws {
        let original = try imageFile(width: 4096, height: 3072, orientation: 6)

        let preview = try XCTUnwrap(SharePreviewThumbnail.image(at: original))
        let pixels = try XCTUnwrap(preview.cgImage)

        XCTAssertEqual(pixels.width, 162)
        XCTAssertEqual(pixels.height, 216)
        XCTAssertEqual(preview.imageOrientation, .up)
    }

    func testSmallPNGPreviewIsNotUpscaled() throws {
        let original = try imageFile(width: 40, height: 20, type: .png)

        let pixels = try XCTUnwrap(SharePreviewThumbnail.image(at: original)?.cgImage)

        XCTAssertEqual(pixels.width, 40)
        XCTAssertEqual(pixels.height, 20)
    }

    func testPreviewDoesNotModifyTheOriginalBytesOrDimensions() throws {
        let original = try imageFile(width: 2048, height: 1024, orientation: 3)
        let before = try Data(contentsOf: original)

        let preview = try XCTUnwrap(SharePreviewThumbnail.image(at: original)?.cgImage)

        XCTAssertEqual(preview.width, 216)
        XCTAssertEqual(try Data(contentsOf: original), before)
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(original as CFURL, nil))
        let properties = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
        XCTAssertEqual(properties[kCGImagePropertyPixelWidth] as? Int, 2048)
        XCTAssertEqual(properties[kCGImagePropertyPixelHeight] as? Int, 1024)
        XCTAssertEqual(properties[kCGImagePropertyOrientation] as? Int, 3)
    }

    func testCorruptAndNonImageFilesKeepTheirSourceAndReturnNoPreview() throws {
        for (name, bytes) in [
            ("broken.jpg", Data([0xff, 0xd8, 0xff])),
            ("not-an-image.mov", Data("non-image source".utf8)),
        ] {
            let original = directory.appendingPathComponent(name)
            try bytes.write(to: original)

            XCTAssertNil(SharePreviewThumbnail.image(at: original))
            XCTAssertEqual(try Data(contentsOf: original), bytes)
        }
    }

    func testMissingFileDoesNotProduceAPreviewOrCreateAFile() {
        let missing = directory.appendingPathComponent("missing.jpg")

        XCTAssertNil(SharePreviewThumbnail.image(at: missing))
        XCTAssertFalse(FileManager.default.fileExists(atPath: missing.path))
    }

    private func imageFile(
        width: Int, height: Int, orientation: Int = 1, type: UTType = .jpeg
    ) throws -> URL {
        try autoreleasepool {
            let context = try XCTUnwrap(CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.setFillColor(CGColor(red: 0.2, green: 0.5, blue: 0.8, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            let image = try XCTUnwrap(context.makeImage())
            let url = directory.appendingPathComponent("\(UUID().uuidString).\(type.preferredFilenameExtension!)")
            let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil))
            CGImageDestinationAddImage(destination, image, [kCGImagePropertyOrientation: orientation] as CFDictionary)
            guard CGImageDestinationFinalize(destination) else { throw FixtureError.failedToEncodeImage }
            return url
        }
    }

    private enum FixtureError: Error { case failedToEncodeImage }
}
