import AVFoundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import ImmichApp

@MainActor
final class PhotoExportTests: XCTestCase {
    private var directory: URL!
    private var owned: [URL] = []

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("photo-export-tests-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        TemporaryMediaStore.remove(owned)
        try FileManager.default.removeItem(at: directory)
    }

    func testCurrentKeepsTheOriginalFormatBytesAndCallerOwnership() async throws {
        let input = try image(type: .tiff, location: true, orientation: 6)
        let bytes = try Data(contentsOf: input)

        let result = try await prepare(input, .init(format: .current))

        XCTAssertEqual(result.fileURL, input)
        XCTAssertNil(result.compatibleURL)
        XCTAssertTrue(result.ownedURLs.isEmpty)
        XCTAssertEqual(PhotoExportService.contentType(of: input), .tiff)
        XCTAssertEqual(try Data(contentsOf: result.fileURL), bytes)
        TemporaryMediaStore.remove(result.ownedURLs)
        XCTAssertTrue(FileManager.default.fileExists(atPath: input.path))
    }

    func testLocationOffRewritesJPEGMetadataWithoutChangingPixelsOrientationCaptionOrSource() async throws {
        let input = try image(type: .jpeg, location: true, orientation: 6, patterned: true)
        let bytes = try Data(contentsOf: input)
        XCTAssertNotNil(try properties(input)[kCGImagePropertyGPSDictionary as String])
        XCTAssertTrue(try metadataPaths(input).contains { $0.lowercased().contains("gps") })

        let result = try await prepare(input, .init(format: .current, includeLocation: false))

        XCTAssertNotEqual(result.fileURL, input)
        XCTAssertEqual(result.ownedURLs, [result.fileURL])
        XCTAssertEqual(PhotoExportService.contentType(of: result.fileURL), .jpeg)
        let output = try properties(result.fileURL)
        XCTAssertNil(output[kCGImagePropertyGPSDictionary as String])
        XCTAssertFalse(try metadataPaths(result.fileURL).contains { $0.lowercased().contains("gps") || $0.lowercased().contains("city") })
        XCTAssertEqual(output[kCGImagePropertyOrientation as String] as? Int, 6)
        XCTAssertEqual((output[kCGImagePropertyTIFFDictionary as String] as? [String: Any])?[kCGImagePropertyTIFFMake as String] as? String, "Synthetic Camera")
        XCTAssertEqual((output[kCGImagePropertyIPTCDictionary as String] as? [String: Any])?[kCGImagePropertyIPTCCaptionAbstract as String] as? String, "Keep this caption")
        XCTAssertEqual(try pixels(result.fileURL), try pixels(input), "Current metadata removal must keep decoded image pixels unchanged")
        XCTAssertEqual(try Data(contentsOf: input), bytes)
        XCTAssertNotNil(try properties(input)[kCGImagePropertyGPSDictionary as String])
    }

    func testLocationOffDropsOpaqueXMPInsteadOfReturningUnverifiableVendorLocation() async throws {
        let input = try image(type: .jpeg, opaqueMetadata: true)
        XCTAssertTrue(try metadataPaths(input).contains { $0.contains("private:payload") })

        let result = try await prepare(input, .init(format: .current, includeLocation: false))

        XCTAssertNotEqual(result.fileURL, input)
        XCTAssertFalse(try metadataPaths(result.fileURL).contains { $0.contains("private:") })
        XCTAssertTrue(try metadataPaths(input).contains { $0.contains("private:payload") })
    }

    func testAutomaticProvidesAnActualCompatibleAlternativeWhileCurrentStaysTIFF() async throws {
        let input = try image(type: .tiff, orientation: 6)
        let bytes = try Data(contentsOf: input)

        let result = try await prepare(input, .init())

        XCTAssertEqual(result.fileURL, input)
        let compatible = try XCTUnwrap(result.compatibleURL)
        XCTAssertEqual(PhotoExportService.contentType(of: compatible), .jpeg)
        XCTAssertEqual(result.ownedURLs, [compatible])
        XCTAssertEqual(try dimensions(compatible), [64, 48])
        XCTAssertEqual(try properties(compatible)[kCGImagePropertyOrientation as String] as? Int, 6)
        XCTAssertEqual(try Data(contentsOf: input), bytes)
    }

    func testMostCompatibleConvertsHEICAndHonorsLocationOff() async throws {
        let input = try image(type: .heic, location: true, orientation: 6)
        let bytes = try Data(contentsOf: input)
        XCTAssertEqual(PhotoExportService.contentType(of: input), .heic)

        let result = try await prepare(input, .init(format: .mostCompatible, includeLocation: false))

        XCTAssertEqual(PhotoExportService.contentType(of: result.fileURL), .jpeg)
        XCTAssertEqual(result.ownedURLs, [result.fileURL])
        XCTAssertNil(result.compatibleURL)
        XCTAssertEqual(try dimensions(result.fileURL), [64, 48])
        XCTAssertEqual(try properties(result.fileURL)[kCGImagePropertyOrientation as String] as? Int, 6)
        XCTAssertNil(try properties(result.fileURL)[kCGImagePropertyGPSDictionary as String])
        XCTAssertFalse(try metadataPaths(result.fileURL).contains { $0.lowercased().contains("gps") })
        XCTAssertEqual(try Data(contentsOf: input), bytes)
    }

    func testCompatiblePNGKeepsItsAlphaAndGIFKeepsEveryFrameAndDelay() async throws {
        let png = try image(type: .png, alpha: true)
        let gif = try animatedGIF()
        for input in [png, gif] {
            let bytes = try Data(contentsOf: input)
            let result = try await prepare(input, .init(format: .mostCompatible, includeLocation: false))
            XCTAssertEqual(result.fileURL, input)
            XCTAssertNil(result.compatibleURL)
            XCTAssertTrue(result.ownedURLs.isEmpty)
            XCTAssertEqual(try Data(contentsOf: result.fileURL), bytes)
        }
        let pngSource = try XCTUnwrap(CGImageSourceCreateWithURL(png as CFURL, nil))
        XCTAssertTrue([CGImageAlphaInfo.premultipliedLast, .premultipliedFirst, .last, .first].contains(try XCTUnwrap(CGImageSourceCreateImageAtIndex(pngSource, 0, nil)).alphaInfo))
        let gifSource = try XCTUnwrap(CGImageSourceCreateWithURL(gif as CFURL, nil))
        XCTAssertEqual(CGImageSourceGetCount(gifSource), 2)
        for (index, delay) in [0.2, 0.4].enumerated() {
            let props = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(gifSource, index, nil) as? [String: Any])
            let frame = try XCTUnwrap(props[kCGImagePropertyGIFDictionary as String] as? [String: Any])
            XCTAssertEqual(try XCTUnwrap(frame[kCGImagePropertyGIFDelayTime as String] as? Double), delay, accuracy: 0.01)
        }
    }

    func testAnIncompatibleImageWithAlphaConvertsToPNGInsteadOfLosingTransparency() async throws {
        let input = try image(type: .tiff, alpha: true)

        let result = try await prepare(input, .init(format: .mostCompatible))

        XCTAssertEqual(PhotoExportService.contentType(of: result.fileURL), .png)
        XCTAssertEqual(try pixels(result.fileURL), try pixels(input))
        XCTAssertEqual(result.ownedURLs, [result.fileURL])
    }

    func testActualContentWinsOverMisleadingFilenameAndCorruptMediaIsRejected() async throws {
        let png = try image(type: .png)
        let wrongExtension = directory.appendingPathComponent("\(UUID()).mov")
        try FileManager.default.copyItem(at: png, to: wrongExtension)
        XCTAssertEqual(PhotoExportService.contentType(of: wrongExtension), .png)
        let result = try await prepare(wrongExtension, .init(format: .current))
        XCTAssertEqual(result.fileURL, wrongExtension)
        let corrupt = directory.appendingPathComponent("\(UUID()).jpg")
        try Data("This is not media".utf8).write(to: corrupt)
        XCTAssertEqual(PhotoExportService.contentType(of: corrupt), .data)
        do { _ = try await prepare(corrupt, .init()); XCTFail("Corrupt media must not reach a receiving app") }
        catch PhotoExportError.unsupportedMedia {}
        XCTAssertEqual(try Data(contentsOf: corrupt), Data("This is not media".utf8))
    }

    func testRecognizedJPEGWithoutItsPixelPayloadCannotBeReturnedAsCurrent() async throws {
        let valid = try image(type: .jpeg)
        let bytes = try Data(contentsOf: valid)
        let scan = try XCTUnwrap(bytes.range(of: Data([0xff, 0xda])))
        let corrupt = directory.appendingPathComponent("\(UUID()).jpg")
        let truncated = Data(bytes.prefix(scan.upperBound))
        try truncated.write(to: corrupt)
        XCTAssertEqual(PhotoExportService.contentType(of: corrupt), .jpeg,
            "The fixture must pass type sniffing while its pixel payload is missing")
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(corrupt as CFURL, nil))
        XCTAssertNil(CGImageSourceCreateImageAtIndex(source, 0, nil))

        do { _ = try await prepare(corrupt, .init(format: .current)); XCTFail("Current must not bypass media validation") }
        catch PhotoExportError.unsupportedMedia {}

        XCTAssertEqual(try Data(contentsOf: corrupt), truncated)
        XCTAssertTrue(try managedShareFiles { $0.lastPathComponent == corrupt.lastPathComponent }.isEmpty)
    }

    func testCurrentVideoKeepsItsOriginalBytesAndMostCompatibleH264DoesNotReencode() async throws {
        let input = try await movie(codec: .h264)
        let bytes = try Data(contentsOf: input)
        for format in [PhotoExportOptions.Format.current, .mostCompatible, .automatic] {
            let result = try await prepare(input, .init(format: format))
            XCTAssertEqual(result.fileURL, input)
            XCTAssertNil(result.compatibleURL)
            XCTAssertTrue(result.ownedURLs.isEmpty)
            XCTAssertEqual(try Data(contentsOf: input), bytes)
        }
        let codecs = try await videoCodecs(input)
        XCTAssertEqual(codecs, [kCMVideoCodecType_H264])
    }

    func testAutomaticVideoOffersHEVCAndH264RepresentationsAndMostCompatibleUsesH264() async throws {
        let input = try await movie(codec: .hevc, audio: true)
        let bytes = try Data(contentsOf: input)
        let originalCodecs = try await videoCodecs(input)
        let originalAudio = try await audioCodecs(input)
        XCTAssertEqual(originalCodecs, [kCMVideoCodecType_HEVC])
        XCTAssertEqual(originalAudio, [kAudioFormatMPEG4AAC])

        let automatic = try await prepare(input, .init())
        let compatible = try XCTUnwrap(automatic.compatibleURL)
        XCTAssertEqual(automatic.fileURL, input)
        XCTAssertEqual(automatic.ownedURLs, [compatible])
        let compatibleCodecs = try await videoCodecs(compatible)
        let compatibleAudio = try await audioCodecs(compatible)
        XCTAssertEqual(compatibleCodecs, [kCMVideoCodecType_H264])
        XCTAssertEqual(compatibleAudio, [kAudioFormatMPEG4AAC])
        XCTAssertEqual(PhotoExportService.contentType(of: automatic.fileURL), .quickTimeMovie)
        XCTAssertEqual(PhotoExportService.contentType(of: compatible), .mpeg4Movie)
        XCTAssertNotEqual(PhotoExportService.contentType(of: automatic.fileURL).identifier,
            PhotoExportService.contentType(of: compatible).identifier,
            "Native item providers must be able to advertise both codec representations")
        let explicit = try await prepare(input, .init(format: .mostCompatible))
        XCTAssertNil(explicit.compatibleURL)
        XCTAssertEqual(explicit.ownedURLs, [explicit.fileURL])
        let explicitCodecs = try await videoCodecs(explicit.fileURL)
        XCTAssertEqual(explicitCodecs, [kCMVideoCodecType_H264])
        XCTAssertEqual(try Data(contentsOf: input), bytes)
        let duration = try await AVURLAsset(url: explicit.fileURL).load(.duration)
        XCTAssertEqual(CMTimeGetSeconds(duration), 1, accuracy: 0.05)
    }

    func testAutomaticMPEG4OffersAQuickTimeH264AlternativeWithoutChangingItsHEVCSource() async throws {
        let input = try await movie(codec: .hevc, audio: true, fileType: .mp4)
        let bytes = try Data(contentsOf: input)
        let sourceCodecs = try await videoCodecs(input)
        XCTAssertEqual(sourceCodecs, [kCMVideoCodecType_HEVC])
        XCTAssertEqual(PhotoExportService.contentType(of: input), .mpeg4Movie)

        let result = try await prepare(input, .init())

        XCTAssertEqual(result.fileURL, input)
        let compatible = try XCTUnwrap(result.compatibleURL)
        XCTAssertEqual(result.ownedURLs, [compatible])
        XCTAssertEqual(PhotoExportService.contentType(of: compatible), .quickTimeMovie)
        XCTAssertNotEqual(PhotoExportService.contentType(of: result.fileURL).identifier,
            PhotoExportService.contentType(of: compatible).identifier)
        let codecs = try await videoCodecs(compatible)
        let audio = try await audioCodecs(compatible)
        XCTAssertEqual(codecs, [kCMVideoCodecType_H264])
        XCTAssertEqual(audio, [kAudioFormatMPEG4AAC])
        XCTAssertEqual(try Data(contentsOf: input), bytes)
    }

    func testLocationOffVideoRemovesContainerAndTimedCoordinatesWithoutChangingTheSource() async throws {
        for timed in [false, true] {
            let input = try await movie(codec: .h264, location: !timed, timedLocation: timed)
            let bytes = try Data(contentsOf: input)
            let source = AVURLAsset(url: input)
            if timed {
                let tracks = try await source.loadTracks(withMediaType: .metadata)
                XCTAssertFalse(tracks.isEmpty)
            } else {
                let metadata = try await movieMetadata(source)
                XCTAssertTrue(metadata.contains { $0.identifier == .quickTimeMetadataLocationISO6709 })
            }

            let result = try await prepare(input, .init(format: .current, includeLocation: false))

            XCTAssertNotEqual(result.fileURL, input)
            XCTAssertEqual(result.ownedURLs, [result.fileURL])
            XCTAssertEqual(PhotoExportService.contentType(of: result.fileURL), .quickTimeMovie)
            let codecs = try await videoCodecs(result.fileURL)
            XCTAssertEqual(codecs, [kCMVideoCodecType_H264])
            let output = AVURLAsset(url: result.fileURL)
            let metadata = try await movieMetadata(output)
            let timedTracks = try await output.loadTracks(withMediaType: .metadata)
            let duration = try await output.load(.duration)
            XCTAssertFalse(metadata.contains { ($0.identifier?.rawValue ?? "").lowercased().contains("location") })
            XCTAssertTrue(timedTracks.isEmpty)
            XCTAssertEqual(try Data(contentsOf: input), bytes)
            XCTAssertEqual(CMTimeGetSeconds(duration), 1, accuracy: 0.05)
        }
    }

    func testLocationOffRemovesQuickTimeUserDataGPSWhoseKeyDoesNotSayLocation() async throws {
        let input = try await movie(codec: .h264, userDataLocation: true)
        let bytes = try Data(contentsOf: input)
        let original = AVURLAsset(url: input)
        let sourceMetadata = try await movieMetadata(original)
        let coordinates = try XCTUnwrap(sourceMetadata.first { $0.identifier == .quickTimeUserDataLocationISO6709 })
        let sourceCoordinates = try await coordinates.load(.stringValue)
        XCTAssertEqual(sourceCoordinates, "+37.3317-122.0301+000.000/")
        let identity = (coordinates.identifier?.rawValue ?? "") + " " + String(describing: coordinates.key)
        XCTAssertFalse(["location", "gps", "latitude", "longitude"].contains { identity.lowercased().contains($0) },
            "This real user-data fixture must bypass a keyword-only location check")

        for format in [PhotoExportOptions.Format.current, .automatic, .mostCompatible] {
            let result = try await prepare(input, .init(format: format, includeLocation: false))

            XCTAssertNotEqual(result.fileURL, input)
            XCTAssertEqual(result.ownedURLs, [result.fileURL])
            XCTAssertNil(result.compatibleURL)
            let exported = AVURLAsset(url: result.fileURL)
            let metadata = try await movieMetadata(exported)
            XCTAssertFalse(metadata.contains { $0.identifier == .quickTimeUserDataLocationISO6709 })
            for item in metadata {
                let value = try await item.load(.stringValue)
                XCTAssertFalse(value?.contains("37.3317") == true, "The coordinate payload must also be absent")
            }
            let duration = try await exported.load(.duration)
            XCTAssertEqual(CMTimeGetSeconds(duration), 1, accuracy: 0.05)
            let codecs = try await videoCodecs(result.fileURL)
            XCTAssertEqual(codecs, [kCMVideoCodecType_H264])
        }
        XCTAssertEqual(try Data(contentsOf: input), bytes)
        let retainedMetadata = try await movieMetadata(AVURLAsset(url: input))
        XCTAssertTrue(retainedMetadata.contains { $0.identifier == .quickTimeUserDataLocationISO6709 })
    }

    func testLocationOffRemovesISOUserDataCoordinatesFromCurrentAndAutomaticMP4WithoutChangingTheSource() async throws {
        let input = try await movie(codec: .h264, audio: true, fileType: .mp4, isoUserDataLocation: true)
        let bytes = try Data(contentsOf: input)
        let sourceMetadata = try await movieMetadata(AVURLAsset(url: input))
        let coordinates = try XCTUnwrap(sourceMetadata.first { $0.identifier == .identifier3GPUserDataLocation })
        XCTAssertEqual(coordinates.identifier?.rawValue, "uiso/loci")
        let value = try await coordinates.load(.stringValue)
        XCTAssertEqual(value, "+37.3317-122.0301+000.000/")
        XCTAssertEqual(PhotoExportService.contentType(of: input), .mpeg4Movie)

        for format in [PhotoExportOptions.Format.current, .automatic] {
            let result = try await prepare(input, .init(format: format, includeLocation: false))

            XCTAssertNotEqual(result.fileURL, input)
            XCTAssertEqual(result.ownedURLs, [result.fileURL])
            XCTAssertNil(result.compatibleURL)
            XCTAssertEqual(PhotoExportService.contentType(of: result.fileURL), .mpeg4Movie)
            let output = AVURLAsset(url: result.fileURL)
            let metadata = try await movieMetadata(output)
            XCTAssertFalse(metadata.contains { $0.identifier == .identifier3GPUserDataLocation })
            for item in metadata {
                let text = try await item.load(.stringValue)
                XCTAssertFalse(text?.contains("37.3317") == true)
            }
            let video = try await videoCodecs(result.fileURL)
            let audio = try await audioCodecs(result.fileURL)
            let duration = try await output.load(.duration)
            XCTAssertEqual(video, [kCMVideoCodecType_H264])
            XCTAssertEqual(audio, [kAudioFormatMPEG4AAC])
            XCTAssertEqual(CMTimeGetSeconds(duration), 1, accuracy: 0.05)
        }
        XCTAssertEqual(try Data(contentsOf: input), bytes)
        let retainedMetadata = try await movieMetadata(AVURLAsset(url: input))
        XCTAssertTrue(retainedMetadata.contains { $0.identifier == .identifier3GPUserDataLocation })
    }

    func testAlreadyCancelledPreparationLeavesItsSourceAndNoGeneratedFiles() async throws {
        let input = try image(type: .tiff, location: true)
        let bytes = try Data(contentsOf: input)
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            do {
                _ = try await PhotoExportService.prepare(input, options: .init(format: .mostCompatible, includeLocation: false))
                XCTFail("A cancelled share must not publish a representation")
            } catch is CancellationError {}
            catch { XCTFail("Expected cancellation, received \(error)") }
        }
        await task.value
        XCTAssertEqual(try Data(contentsOf: input), bytes)
        XCTAssertTrue(try managedShareFiles { $0.deletingPathExtension().lastPathComponent == input.deletingPathExtension().lastPathComponent }.isEmpty)
    }

    private func prepare(_ input: URL, _ options: PhotoExportOptions) async throws -> PhotoExportRepresentations {
        let result = try await PhotoExportService.prepare(input, options: options)
        owned += result.ownedURLs
        return result
    }

    private func image(type: UTType, location: Bool = false, orientation: Int = 1,
                       alpha: Bool = false, opaqueMetadata: Bool = false, patterned: Bool = false) throws -> URL {
        let context = try XCTUnwrap(CGContext(data: nil, width: 64, height: 48, bitsPerComponent: 8,
            bytesPerRow: 64 * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: (alpha ? CGImageAlphaInfo.premultipliedLast : .noneSkipLast).rawValue))
        context.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.8, alpha: alpha ? 0.4 : 1))
        context.fill(CGRect(x: 0, y: 0, width: 64, height: 48))
        if patterned {
            context.setShouldAntialias(false)
            for y in 0..<48 {
                for x in 0..<64 {
                    context.setFillColor(CGColor(red: CGFloat((x * 17 + y * 3) % 256) / 255,
                        green: CGFloat((x * 5 + y * 29) % 256) / 255,
                        blue: CGFloat((x * 31 + y * 7) % 256) / 255, alpha: 1))
                    context.fill(CGRect(x: CGFloat(x), y: CGFloat(y), width: 1, height: 1))
                }
            }
        }
        let url = directory.appendingPathComponent("\(UUID()).\(type.preferredFilenameExtension!)")
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil))
        var properties: [CFString: Any] = [kCGImagePropertyOrientation: orientation,
            kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFMake: "Synthetic Camera"],
            kCGImagePropertyIPTCDictionary: [kCGImagePropertyIPTCCaptionAbstract: "Keep this caption"]]
        let metadata = CGImageMetadataCreateMutable()
        if location {
            properties[kCGImagePropertyGPSDictionary] = [kCGImagePropertyGPSLatitude: 37.3, kCGImagePropertyGPSLatitudeRef: "N",
                kCGImagePropertyGPSLongitude: 122.1, kCGImagePropertyGPSLongitudeRef: "W"]
            CGImageMetadataRegisterNamespaceForPrefix(metadata, "http://ns.adobe.com/exif/1.0/" as CFString, "exif" as CFString, nil)
            XCTAssertTrue(CGImageMetadataSetValueWithPath(metadata, nil, "exif:GPSLatitude" as CFString, "37,18.0N" as CFString))
            XCTAssertTrue(CGImageMetadataSetValueWithPath(metadata, nil, "exif:GPSLongitude" as CFString, "122,6.0W" as CFString))
            properties[kCGImagePropertyIPTCDictionary] = [kCGImagePropertyIPTCCaptionAbstract: "Keep this caption", kCGImagePropertyIPTCCity: "Synthetic City"]
        }
        if opaqueMetadata {
            XCTAssertTrue(CGImageMetadataRegisterNamespaceForPrefix(metadata, "https://synthetic.example/private/" as CFString, "private" as CFString, nil))
            XCTAssertTrue(CGImageMetadataSetValueWithPath(metadata, nil, "private:payload" as CFString, "latitude=37.3;longitude=-122.1" as CFString))
        }
        CGImageDestinationAddImageAndMetadata(destination, try XCTUnwrap(context.makeImage()), metadata, properties as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination), "The test requires valid generated media")
        return url
    }

    private func animatedGIF() throws -> URL {
        let context = try XCTUnwrap(CGContext(data: nil, width: 16, height: 16, bitsPerComponent: 8,
            bytesPerRow: 64, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let url = directory.appendingPathComponent("\(UUID()).gif")
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, UTType.gif.identifier as CFString, 2, nil))
        CGImageDestinationSetProperties(destination, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
        for (index, delay) in [0.2, 0.4].enumerated() {
            context.setFillColor(CGColor(red: index == 0 ? 1 : 0, green: 0, blue: index == 0 ? 0 : 1, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: 16, height: 16))
            CGImageDestinationAddImage(destination, try XCTUnwrap(context.makeImage()),
                [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: delay]] as CFDictionary)
        }
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return url
    }

    private func properties(_ url: URL) throws -> [String: Any] {
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
        return try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any])
    }

    private func metadataPaths(_ url: URL) throws -> [String] {
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
        guard let metadata = CGImageSourceCopyMetadataAtIndex(source, 0, nil) else { return [] }
        var paths: [String] = []
        CGImageMetadataEnumerateTagsUsingBlock(metadata, nil,
            [kCGImageMetadataEnumerateRecursively: true] as CFDictionary) { path, _ in paths.append(path as String); return true }
        return paths
    }

    private func dimensions(_ url: URL) throws -> [Int] {
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        return [image.width, image.height]
    }

    private func pixels(_ url: URL) throws -> Data {
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        let context = try XCTUnwrap(CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
            bytesPerRow: image.width * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return Data(bytes: try XCTUnwrap(context.data), count: image.width * image.height * 4)
    }

    private func videoCodecs(_ url: URL) async throws -> [FourCharCode] {
        let tracks = try await AVURLAsset(url: url).loadTracks(withMediaType: .video)
        var result: [FourCharCode] = []
        for track in tracks { result += try await track.load(.formatDescriptions).map(CMFormatDescriptionGetMediaSubType) }
        return result
    }

    private func audioCodecs(_ url: URL) async throws -> [FourCharCode] {
        let tracks = try await AVURLAsset(url: url).loadTracks(withMediaType: .audio)
        var result: [FourCharCode] = []
        for track in tracks { result += try await track.load(.formatDescriptions).map(CMFormatDescriptionGetMediaSubType) }
        return result
    }

    private func movieMetadata(_ asset: AVAsset) async throws -> [AVMetadataItem] {
        var items: [AVMetadataItem] = []
        for format in try await asset.load(.availableMetadataFormats) { items += try await asset.loadMetadata(for: format) }
        return items
    }

    private func movie(codec: AVVideoCodecType, location: Bool = false, timedLocation: Bool = false,
                       audio: Bool = false, fileType: AVFileType = .mov,
                       userDataLocation: Bool = false, isoUserDataLocation: Bool = false) async throws -> URL {
        let url = directory.appendingPathComponent("\(UUID()).\(fileType == .mp4 ? "mp4" : "mov")")
        let writer = try AVAssetWriter(outputURL: url, fileType: fileType)
        if location { writer.metadata = [coordinateMetadata()] }
        if userDataLocation || isoUserDataLocation {
            let coordinates = AVMutableMetadataItem()
            coordinates.identifier = isoUserDataLocation ? .identifier3GPUserDataLocation : .quickTimeUserDataLocationISO6709
            coordinates.dataType = kCMMetadataBaseDataType_UTF8 as String
            coordinates.value = "+37.3317-122.0301+000.000/" as NSString
            writer.metadata = [coordinates]
        }
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: codec, AVVideoWidthKey: 64, AVVideoHeightKey: 64])
        let pixels = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB,
            kCVPixelBufferWidthKey as String: 64, kCVPixelBufferHeightKey as String: 64])
        XCTAssertTrue(writer.canAdd(input)); writer.add(input)
        var audioInput: AVAssetWriterInput?
        if audio {
            let track = AVAssetWriterInput(mediaType: .audio, outputSettings: [AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 44_100, AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 64_000])
            XCTAssertTrue(writer.canAdd(track)); writer.add(track); audioInput = track
        }
        var metadataInput: AVAssetWriterInput?
        var metadataAdaptor: AVAssetWriterInputMetadataAdaptor?
        if timedLocation {
            var format: CMMetadataFormatDescription?
            let specification: [CFString: Any] = [kCMMetadataFormatDescriptionMetadataSpecificationKey_Identifier: "mdta/com.apple.quicktime.location.ISO6709",
                kCMMetadataFormatDescriptionMetadataSpecificationKey_DataType: kCMMetadataBaseDataType_UTF8]
            XCTAssertEqual(CMMetadataFormatDescriptionCreateWithMetadataSpecifications(allocator: kCFAllocatorDefault,
                metadataType: kCMMetadataFormatType_Boxed, metadataSpecifications: [specification] as CFArray,
                formatDescriptionOut: &format), noErr)
            let track = AVAssetWriterInput(mediaType: .metadata, outputSettings: nil, sourceFormatHint: try XCTUnwrap(format))
            XCTAssertTrue(writer.canAdd(track)); writer.add(track)
            metadataInput = track
            metadataAdaptor = AVAssetWriterInputMetadataAdaptor(assetWriterInput: track)
        }
        XCTAssertTrue(writer.startWriting(), "Generated movie must start: \(String(describing: writer.error))")
        writer.startSession(atSourceTime: .zero)
        if let audioInput {
            try await waitUntilReady(audioInput)
            XCTAssertTrue(audioInput.append(try silentAudio()))
            audioInput.markAsFinished()
        }
        if let metadataInput, let metadataAdaptor {
            try await waitUntilReady(metadataInput)
            XCTAssertTrue(metadataAdaptor.append(AVTimedMetadataGroup(items: [coordinateMetadata()],
                timeRange: CMTimeRange(start: .zero, duration: CMTime(value: 1, timescale: 1)))))
            metadataInput.markAsFinished()
        }
        for frame in 0..<4 {
            try await waitUntilReady(input)
            var buffer: CVPixelBuffer?
            XCTAssertEqual(CVPixelBufferPoolCreatePixelBuffer(nil, try XCTUnwrap(pixels.pixelBufferPool), &buffer), kCVReturnSuccess)
            let image = try XCTUnwrap(buffer)
            CVPixelBufferLockBaseAddress(image, [])
            memset(try XCTUnwrap(CVPixelBufferGetBaseAddress(image)), Int32(frame * 40), CVPixelBufferGetDataSize(image))
            CVPixelBufferUnlockBaseAddress(image, [])
            XCTAssertTrue(pixels.append(image, withPresentationTime: CMTime(value: Int64(frame), timescale: 4)))
        }
        writer.endSession(atSourceTime: CMTime(value: 1, timescale: 1))
        input.markAsFinished()
        await writer.finishWriting()
        XCTAssertEqual(writer.status, .completed, "Generated movie must finish: \(String(describing: writer.error))")
        return url
    }

    private func silentAudio() throws -> CMSampleBuffer {
        var description = AudioStreamBasicDescription(mSampleRate: 44_100, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked, mBytesPerPacket: 2,
            mFramesPerPacket: 1, mBytesPerFrame: 2, mChannelsPerFrame: 1, mBitsPerChannel: 16, mReserved: 0)
        var format: CMAudioFormatDescription?
        XCTAssertEqual(CMAudioFormatDescriptionCreate(allocator: kCFAllocatorDefault, asbd: &description,
            layoutSize: 0, layout: nil, magicCookieSize: 0, magicCookie: nil, extensions: nil,
            formatDescriptionOut: &format), noErr)
        var block: CMBlockBuffer?
        XCTAssertEqual(CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault, memoryBlock: nil,
            blockLength: 88_200, blockAllocator: kCFAllocatorDefault, customBlockSource: nil, offsetToData: 0,
            dataLength: 88_200, flags: 0, blockBufferOut: &block), kCMBlockBufferNoErr)
        XCTAssertEqual(CMBlockBufferFillDataBytes(with: 0, blockBuffer: try XCTUnwrap(block), offsetIntoDestination: 0,
            dataLength: 88_200), kCMBlockBufferNoErr)
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 44_100), presentationTimeStamp: .zero, decodeTimeStamp: .invalid)
        var size = 2
        var sample: CMSampleBuffer?
        XCTAssertEqual(CMSampleBufferCreateReady(allocator: kCFAllocatorDefault, dataBuffer: block,
            formatDescription: format, sampleCount: 44_100, sampleTimingEntryCount: 1, sampleTimingArray: &timing,
            sampleSizeEntryCount: 1, sampleSizeArray: &size, sampleBufferOut: &sample), noErr)
        return try XCTUnwrap(sample)
    }

    private func coordinateMetadata() -> AVMetadataItem {
        let item = AVMutableMetadataItem()
        item.identifier = .quickTimeMetadataLocationISO6709
        item.dataType = kCMMetadataBaseDataType_UTF8 as String
        item.value = "+37.3317-122.0301+000.000/" as NSString
        return item
    }

    private func waitUntilReady(_ input: AVAssetWriterInput) async throws {
        let deadline = Date().addingTimeInterval(5)
        while !input.isReadyForMoreMediaData, Date() < deadline { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertTrue(input.isReadyForMoreMediaData, "The generated movie writer must become ready")
    }
}
