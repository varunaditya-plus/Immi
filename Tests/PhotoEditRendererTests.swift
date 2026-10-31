import CoreImage
import ImageIO
import UIKit
import UniformTypeIdentifiers
import XCTest
@testable import ImmichApp

@MainActor
final class PhotoEditRendererTests: XCTestCase {
    private var files: [URL] = []

    override func tearDown() async throws {
        for file in files { try? FileManager.default.removeItem(at: file) }
        files.removeAll()
        try await super.tearDown()
    }

    func testSourceCropQuarterTurnAndPostTransformFramingSelectTheExpectedOriginalPixels() async throws {
        let source = try quadrants()
        var recipe = PhotoEditRecipe()
        recipe.crop = CGRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5)
        recipe.quarterTurns = 1
        recipe.framing = CGRect(x: 0.5, y: 0, width: 0.5, height: 1)

        let result = try await PhotoEditRenderer.shared.renderPreview(source, recipe: recipe)

        XCTAssertEqual(result.size, CGSize(width: 3, height: 8))
        let raster = try raster(result)
        assertColor(raster, x: 1, y: 1, expected: (255, 0, 0))
        assertColor(raster, x: 1, y: 6, expected: (0, 255, 0))
    }

    func testServerReflectionAndRotationOrderMatchesTheImportedRecipePixels() async throws {
        let source = try quadrants()
        let cases: [(String, [(Int, Int, Int)])] = [
            (#"[{"action":"mirror","parameters":{"axis":"horizontal"}}]"#, [(0, 0, 255), (255, 255, 0), (255, 0, 0), (0, 255, 0)]),
            (#"[{"action":"mirror","parameters":{"axis":"vertical"}}]"#, [(0, 255, 0), (255, 0, 0), (255, 255, 0), (0, 0, 255)]),
            (#"[{"action":"rotate","parameters":{"angle":90}},{"action":"mirror","parameters":{"axis":"horizontal"}}]"#,
                [(255, 0, 0), (0, 0, 255), (0, 255, 0), (255, 255, 0)]),
            (#"[{"action":"mirror","parameters":{"axis":"horizontal"}},{"action":"rotate","parameters":{"angle":90}}]"#,
                [(255, 255, 0), (0, 255, 0), (0, 0, 255), (255, 0, 0)]),
        ]
        for (json, expected) in cases {
            let edits = try JSONDecoder().decode([AssetEditRecord].self, from: Data(json.utf8))
            let recipe = PhotoEditRecipe(serverEdits: edits, originalPixelSize: source.size)
            let result = try await PhotoEditRenderer.shared.renderPreview(source, recipe: recipe)
            let raster = try raster(result)
            let points = [(1, 1), (raster.width - 2, 1), (1, raster.height - 2), (raster.width - 2, raster.height - 2)]
            for (point, expected) in zip(points, expected) {
                assertColor(raster, x: point.0, y: point.1, expected: expected)
            }
        }
    }

    func testEveryManualAdjustmentChangesActualPixelsAndZeroValuesRetainTheNeutralRender() async throws {
        let source = try patterned()
        let baseline = try raster(await PhotoEditRenderer.shared.renderPreview(source, recipe: PhotoEditRecipe()))
        for adjustment in PhotoAdjustment.allCases where adjustment != .auto {
            let input = adjustment == .noiseReduction ? try noise() : source
            let neutral = adjustment == .noiseReduction
                ? try raster(await PhotoEditRenderer.shared.renderPreview(input, recipe: PhotoEditRecipe())) : baseline
            var recipe = PhotoEditRecipe()
            recipe[adjustment] = 0.7
            let changed = try raster(await PhotoEditRenderer.shared.renderPreview(input, recipe: recipe))
            XCTAssertNotEqual(changed.bytes, neutral.bytes, "\(adjustment) must change pixels, not just its slider label")
            recipe[adjustment] = 0
            let reset = try raster(await PhotoEditRenderer.shared.renderPreview(input, recipe: recipe))
            XCTAssertEqual(reset.bytes, neutral.bytes, "\(adjustment) must reset its actual effect")
        }
    }

    func testExposureHasOppositeEffectsAndAutoEnhancementProcessesADarkLowContrastImage() async throws {
        let source = try patterned(dark: true)
        let baseline = try raster(await PhotoEditRenderer.shared.renderPreview(source, recipe: PhotoEditRecipe()))
        var brighter = PhotoEditRecipe(), darker = PhotoEditRecipe(), automatic = PhotoEditRecipe()
        brighter[.exposure] = 0.5
        darker[.exposure] = -0.5
        automatic[.auto] = 1
        let high = try raster(await PhotoEditRenderer.shared.renderPreview(source, recipe: brighter))
        let low = try raster(await PhotoEditRenderer.shared.renderPreview(source, recipe: darker))
        let enhanced = try raster(await PhotoEditRenderer.shared.renderPreview(source, recipe: automatic))

        XCTAssertGreaterThan(high.meanLuminance, baseline.meanLuminance)
        XCTAssertLessThan(low.meanLuminance, baseline.meanLuminance)
        XCTAssertNotEqual(enhanced.bytes, baseline.bytes)
    }

    func testFiltersHaveDistinctRenderedEffectsAndZeroIntensityDoesNotAlterTheImage() async throws {
        let source = try patterned()
        let baseline = try raster(await PhotoEditRenderer.shared.renderPreview(source, recipe: PhotoEditRecipe()))
        var outputs = Set<Data>()
        for filter in PhotoEditFilter.allCases where filter != .original {
            var recipe = PhotoEditRecipe()
            recipe.filter = filter
            let pixels = try raster(await PhotoEditRenderer.shared.renderPreview(source, recipe: recipe))
            XCTAssertNotEqual(pixels.bytes, baseline.bytes, filter.rawValue)
            outputs.insert(pixels.bytes)
            recipe.filterIntensity = 0
            let neutral = try raster(await PhotoEditRenderer.shared.renderPreview(source, recipe: recipe))
            XCTAssertEqual(neutral.bytes, baseline.bytes, filter.rawValue)
        }
        XCTAssertEqual(outputs.count, PhotoEditFilter.allCases.count - 1, "Named looks must not be aliases for the same rendered filter")
    }

    func testHighlightsUseTheSamePositiveAndNegativeBrightnessDirectionAsThePhotosSlider() async throws {
        let source = try fixture(width: 64, height: 48) { x, _ in (130 + x, 130 + x, 130 + x) }
        var raised = PhotoEditRecipe(), lowered = PhotoEditRecipe()
        raised[.highlights] = 0.7
        lowered[.highlights] = -0.7
        let baseline = try raster(await PhotoEditRenderer.shared.renderPreview(source, recipe: PhotoEditRecipe()))
        let high = try raster(await PhotoEditRenderer.shared.renderPreview(source, recipe: raised))
        let low = try raster(await PhotoEditRenderer.shared.renderPreview(source, recipe: lowered))

        XCTAssertGreaterThan(high.meanLuminance, baseline.meanLuminance)
        XCTAssertLessThan(low.meanLuminance, baseline.meanLuminance)
    }

    func testStraighteningAndPerspectiveKeepOpaqueCornersInsteadOfAddingEmptyTriangles() async throws {
        let source = try patterned()
        for angle in [-25.0, 25] {
            for vertical in [-0.6, 0.6] {
                var recipe = PhotoEditRecipe()
                recipe.straighten = angle
                recipe.perspectiveVertical = vertical
                recipe.perspectiveHorizontal = -vertical
                let result = try raster(await PhotoEditRenderer.shared.renderPreview(source, recipe: recipe))
                XCTAssertGreaterThan(result.width, 10)
                XCTAssertGreaterThan(result.height, 10)
                for (x, y) in [(0, 0), (result.width - 1, 0), (0, result.height - 1), (result.width - 1, result.height - 1)] {
                    XCTAssertGreaterThan(result.alpha(x: x, y: y), 245)
                }
            }
        }
    }

    func testInputOnlyImageFormatsExportEditedPixelsInAWritableFormatWithoutChangingTheSource() async throws {
        let bytes = try XCTUnwrap(Data(base64Encoded: "UklGRh4AAABXRUJQVlA4TBEAAAAvB8AAAAdQxkIVuf+BiOh/AAA="))
        let source = FileManager.default.temporaryDirectory.appendingPathComponent("edit-original-\(UUID()).webp")
        files.append(source)
        try bytes.write(to: source)
        var recipe = PhotoEditRecipe(); recipe[.exposure] = 0.5

        let result = try await PhotoEditRenderer.shared.renderFile(source, recipe: recipe)
        files.append(result)

        XCTAssertEqual(try Data(contentsOf: source), bytes)
        let input = try XCTUnwrap(CGImageSourceCreateWithURL(source as CFURL, nil))
        let output = try XCTUnwrap(CGImageSourceCreateWithURL(result as CFURL, nil))
        let inputType = try XCTUnwrap(CGImageSourceGetType(input) as String?)
        let outputType = try XCTUnwrap(CGImageSourceGetType(output) as String?)
        let writable = CGImageDestinationCopyTypeIdentifiers() as? [String] ?? []
        XCTAssertTrue(writable.contains(outputType))
        if !writable.contains(inputType) { XCTAssertTrue([UTType.jpeg.identifier, UTType.png.identifier].contains(outputType)) }
        let decoded = try XCTUnwrap(CGImageSourceCreateImageAtIndex(output, 0, nil))
        XCTAssertEqual([decoded.width, decoded.height], [8, 4])
        let changed = try raster(UIImage(cgImage: decoded))
        XCTAssertGreaterThan(changed.rgb(x: 2, y: 2).0, 95)
    }

    func testFullFileRenderBakesOrientationPreservesMetadataAndLeavesTheOriginalBytesUntouched() async throws {
        let image = try quadrants()
        let source = FileManager.default.temporaryDirectory.appendingPathComponent("edit-original-\(UUID()).jpg")
        files.append(source)
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(source as CFURL, UTType.jpeg.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try XCTUnwrap(image.cgImage), [
            kCGImagePropertyOrientation: 6,
            kCGImagePropertyGPSDictionary: [kCGImagePropertyGPSLatitude: 12.5, kCGImagePropertyGPSLatitudeRef: "N"],
            kCGImagePropertyExifDictionary: [kCGImagePropertyExifUserComment: "Synthetic editor original"],
        ] as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        let originalBytes = try Data(contentsOf: source)
        var recipe = PhotoEditRecipe()
        recipe[.exposure] = 0.5

        let result = try await PhotoEditRenderer.shared.renderFile(source, recipe: recipe)
        files.append(result)

        XCTAssertNotEqual(result, source)
        XCTAssertEqual(try Data(contentsOf: source), originalBytes)
        let exported = try XCTUnwrap(CGImageSourceCreateWithURL(result as CFURL, nil))
        let decoded = try XCTUnwrap(CGImageSourceCreateImageAtIndex(exported, 0, nil))
        XCTAssertEqual(decoded.width, 12)
        XCTAssertEqual(decoded.height, 16)
        let properties = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(exported, 0, nil) as? [String: Any])
        XCTAssertEqual((properties[kCGImagePropertyOrientation as String] as? NSNumber)?.intValue, 1)
        XCTAssertEqual((properties[kCGImagePropertyGPSDictionary as String] as? [String: Any])?[kCGImagePropertyGPSLatitude as String] as? Double, 12.5)
        XCTAssertEqual((properties[kCGImagePropertyExifDictionary as String] as? [String: Any])?[kCGImagePropertyExifUserComment as String] as? String, "Synthetic editor original")
    }

    func testUIImageOrientationIsAppliedExactlyOnce() async throws {
        let raw = try quadrants()
        let oriented = UIImage(cgImage: try XCTUnwrap(raw.cgImage), scale: 1, orientation: .right)
        let result = try await PhotoEditRenderer.shared.renderPreview(oriented, recipe: PhotoEditRecipe())
        let pixels = try raster(result)

        XCTAssertEqual(result.imageOrientation, .up)
        XCTAssertEqual(result.size, CGSize(width: 12, height: 16))
        assertColor(pixels, x: 1, y: 1, expected: (0, 0, 255))
        assertColor(pixels, x: pixels.width - 2, y: 1, expected: (255, 0, 0))
    }

    private func quadrants() throws -> UIImage {
        try fixture(width: 16, height: 12) { x, y in
            if y < 6 { return x < 8 ? (255, 0, 0) : (0, 255, 0) }
            return x < 8 ? (0, 0, 255) : (255, 255, 0)
        }
    }

    private func patterned(dark: Bool = false) throws -> UIImage {
        try fixture(width: 128, height: 96) { x, y in
            if dark { return (20 + x / 4, 16 + y / 4, 12 + (x + y) / 8) }
            return ((x * 17 + y * 3) % 256, (x * 5 + y * 13) % 256, (x * 11 + y * 7) % 256)
        }
    }

    private func noise() throws -> UIImage {
        try fixture(width: 128, height: 96) { x, y in
            let value = (x < 64 ? 100 : 155) + (x * 13 + y * 17) % 9 - 4
            return (value, value + 3, value - 2)
        }
    }

    private func fixture(width: Int, height: Int, pixel: (Int, Int) -> (Int, Int, Int)) throws -> UIImage {
        let bytes = (0..<height).flatMap { y in
            (0..<width).flatMap { x -> [UInt8] in
                let value = pixel(x, y)
                return [UInt8(value.0), UInt8(value.1), UInt8(value.2), 255]
            }
        }
        let provider = try XCTUnwrap(CGDataProvider(data: Data(bytes) as CFData))
        let image = try XCTUnwrap(CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
        return UIImage(cgImage: image)
    }

    private func raster(_ image: UIImage) throws -> PhotoEditTestRaster {
        let cg = try XCTUnwrap(image.cgImage)
        var bytes = [UInt8](repeating: 0, count: cg.width * cg.height * 4)
        try bytes.withUnsafeMutableBytes { storage in
            let context = try XCTUnwrap(CGContext(data: storage.baseAddress, width: cg.width, height: cg.height,
                bitsPerComponent: 8, bytesPerRow: cg.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.draw(cg, in: CGRect(x: 0, y: 0, width: cg.width, height: cg.height))
        }
        return PhotoEditTestRaster(width: cg.width, height: cg.height, bytes: Data(bytes))
    }

    private func assertColor(_ raster: PhotoEditTestRaster, x: Int, y: Int, expected: (Int, Int, Int),
                             file: StaticString = #filePath, line: UInt = #line) {
        let actual = raster.rgb(x: x, y: y)
        XCTAssertEqual(actual.0, Double(expected.0), accuracy: 3, file: file, line: line)
        XCTAssertEqual(actual.1, Double(expected.1), accuracy: 3, file: file, line: line)
        XCTAssertEqual(actual.2, Double(expected.2), accuracy: 3, file: file, line: line)
    }
}

private struct PhotoEditTestRaster {
    let width: Int, height: Int
    let bytes: Data
    func rgb(x: Int, y: Int) -> (Double, Double, Double) {
        let offset = (y * width + x) * 4
        return (Double(bytes[offset]), Double(bytes[offset + 1]), Double(bytes[offset + 2]))
    }
    func alpha(x: Int, y: Int) -> UInt8 { bytes[(y * width + x) * 4 + 3] }
    var meanLuminance: Double {
        var total: Double = 0
        for offset in stride(from: 0, to: bytes.count, by: 4) {
            let red = Double(bytes[offset]), green = Double(bytes[offset + 1]), blue = Double(bytes[offset + 2])
            total += (red + green + blue) / 3
        }
        return total / Double(width * height)
    }
}
