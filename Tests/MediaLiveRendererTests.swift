import AVFoundation
import CoreImage
import ImageIO
import Photos
import UIKit
import UniformTypeIdentifiers
import XCTest
@testable import ImmichApp

@MainActor
final class MediaLiveRendererTests: XCTestCase {
    private var directory: URL!
    private var owned: [URL] = []

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("live-render-tests-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        TemporaryMediaStore.remove(owned)
        try FileManager.default.removeItem(at: directory)
    }

    func testLiveOutputIsARecognizedRealPairPreservingTheHighResolutionStillAndOriginalMarker() async throws {
        let source = try await pair()
        let originalBytes = try [source.still, source.motion].map { try Data(contentsOf: $0) }
        let result = try await render(source, live: .init())
        let motion = try XCTUnwrap(result.motionURL)
        XCTAssertFalse(result.isVideo)
        XCTAssertEqual(result.ownedURLs, [result.primaryURL, motion])
        XCTAssertEqual(try dimensions(result.primaryURL), [160, 120])
        assertColor(try image(result.primaryURL), expected: .green)
        let stillID = try identifier(result.primaryURL)
        XCTAssertNotEqual(stillID, source.identifier)
        let metadata = try await AVURLAsset(url: motion).load(.metadata)
        let movieID = try XCTUnwrap(metadata.first { $0.identifier == .quickTimeMetadataContentIdentifier })
        let value = try await movieID.load(.stringValue)
        XCTAssertEqual(value, stillID)
        let time = try await MediaLiveRenderer.shared.photoTime(motionURL: motion)
        XCTAssertEqual(time, 0.25, accuracy: 0.002)
        let validPair = try await validatesPair(still: result.primaryURL, motion: motion)
        XCTAssertTrue(validPair)
        XCTAssertEqual(try [source.still, source.motion].map { try Data(contentsOf: $0) }, originalBytes)
    }

    func testExplicitKeyPhotoUsesTheActualSelectedFrameAndTransformAppliesToBothResources() async throws {
        let source = try await pair()
        var live = LivePhotoEditRecipe()
        live.keyPhotoTime = 0.5
        var photo = PhotoEditRecipe()
        photo.crop = CGRect(x: 0, y: 0, width: 0.5, height: 1)
        assertColor(try await videoFrame(source.motion, time: 0.5), expected: .blue)
        let result = try await render(source, live: live, photo: photo)
        let motion = try XCTUnwrap(result.motionURL)
        XCTAssertEqual(try dimensions(result.primaryURL), [32, 48])
        assertColor(try image(result.primaryURL), expected: .blue)
        let frame = try await videoFrame(motion, time: 0.5)
        XCTAssertEqual([frame.width, frame.height], [32, 48])
        assertColor(frame, expected: .blue)
        let marker = try await MediaLiveRenderer.shared.photoTime(motionURL: motion)
        XCTAssertEqual(marker, 0.5, accuracy: 0.002)
        let validPair = try await validatesPair(still: result.primaryURL, motion: motion)
        XCTAssertTrue(validPair)
    }

    func testTrimSpeedAndMuteMoveTheMarkerAndExcludeAnOriginalStillOutsideTheTrim() async throws {
        let source = try await pair()
        var video = VideoEditRecipe()
        video.trimStart = 0.5
        video.trimEnd = 1
        video.rate = 2
        video.isMuted = true
        let result = try await render(source, video: video, live: .init())
        let motion = try XCTUnwrap(result.motionURL)
        assertColor(try image(result.primaryURL), expected: .blue)
        XCTAssertEqual(try dimensions(result.primaryURL), [64, 48])
        let asset = AVURLAsset(url: motion)
        let duration = try await asset.load(.duration).seconds
        let audio = try await asset.loadTracks(withMediaType: .audio)
        let marker = try await MediaLiveRenderer.shared.photoTime(motionURL: motion)
        XCTAssertEqual(duration, 0.25, accuracy: 0.04)
        XCTAssertTrue(audio.isEmpty)
        XCTAssertEqual(marker, 0, accuracy: 0.002)
        let validPair = try await validatesPair(still: result.primaryURL, motion: motion)
        XCTAssertTrue(validPair)
    }

    func testLoopContainsTwoRealVideoAndAudioCyclesWithoutLivePairMetadata() async throws {
        let source = try await pair()
        var live = LivePhotoEditRecipe(); live.mode = .loop
        assertColor(try await videoFrame(source.motion, time: 0.1), expected: .red)
        assertColor(try await videoFrame(source.motion, time: 0.6), expected: .blue)
        let result = try await render(source, live: live)
        XCTAssertTrue(result.isVideo)
        XCTAssertNil(result.motionURL)
        let asset = AVURLAsset(url: result.primaryURL)
        let duration = try await asset.load(.duration).seconds
        let audio = try await asset.loadTracks(withMediaType: .audio)
        XCTAssertEqual(duration, 2, accuracy: 0.05)
        XCTAssertFalse(audio.isEmpty)
        for (time, color) in [(0.1, Color.red), (0.6, .blue), (1.1, .red), (1.6, .blue)] {
            assertColor(try await videoFrame(result.primaryURL, time: time), expected: color)
        }
        let metadata = try await asset.load(.metadata)
        XCTAssertFalse(metadata.contains { $0.identifier == .quickTimeMetadataContentIdentifier })
    }

    func testBounceEncodesForwardThenReverseFramesAndReversesTheAudioWithThem() async throws {
        let source = try await pair()
        var live = LivePhotoEditRecipe(); live.mode = .bounce
        for (index, color) in [Color.red, .green, .blue, .white].enumerated() {
            assertColor(try await videoFrame(source.motion, time: Double(index) / 4), expected: color)
        }
        let result = try await render(source, live: live)
        XCTAssertTrue(result.isVideo)
        XCTAssertNil(result.motionURL)
        let duration = try await AVURLAsset(url: result.primaryURL).load(.duration).seconds
        XCTAssertEqual(duration, 1.5, accuracy: 0.05)
        for (index, color) in [Color.red, .green, .blue, .white, .blue, .green].enumerated() {
            assertColor(try await videoFrame(result.primaryURL, time: Double(index) / 4 + 0.08), expected: color)
        }
        let levels = try await audioLevels(result.primaryURL)
        XCTAssertEqual(levels.count, 6)
        XCTAssertGreaterThan(levels[4], levels[0] * 4, "The reverse half must not contain another forward audio cycle")
        XCTAssertEqual(levels[4], levels[2], accuracy: levels[2] * 0.25)
        XCTAssertEqual(levels[5], levels[1], accuracy: levels[1] * 0.25)
    }

    func testLongExposureBlendsDifferentMotionFramesAndLiveOffProducesAnUnpairedStill() async throws {
        let source = try await pair(colors: [.red, .blue], fps: 2, marker: 0)
        assertColor(try await videoFrame(source.motion, time: 0), expected: .red)
        assertColor(try await videoFrame(source.motion, time: 0.5), expected: .blue)
        var live = LivePhotoEditRecipe(); live.mode = .longExposure
        let result = try await render(source, live: live)
        XCTAssertFalse(result.isVideo)
        XCTAssertNil(result.motionURL)
        let color = try pixel(image(result.primaryURL))
        XCTAssertGreaterThan(color[0], 100)
        XCTAssertGreaterThan(color[2], 100)
        XCTAssertLessThan(color[1], 25)
        let properties = try imageProperties(result.primaryURL)
        XCTAssertNil((properties[kCGImagePropertyMakerAppleDictionary as String] as? [String: Any])?["17"])
        live.mode = .off
        let still = try await render(source, live: live)
        XCTAssertFalse(still.isVideo)
        XCTAssertNil(still.motionURL)
        XCTAssertEqual(try dimensions(still.primaryURL), [160, 120])
        assertColor(try image(still.primaryURL), expected: .red)
    }

    func testPosterIsBoundedAndUsesActualOriginalMarkerRatherThanTheMidpoint() async throws {
        let source = try await pair()
        let marker = try await MediaLiveRenderer.shared.photoTime(motionURL: source.motion)
        XCTAssertEqual(marker, 0.25, accuracy: 0.002)
        let result = try await MediaLiveRenderer.shared.renderPoster(motionURL: source.motion, stillURL: source.still,
            video: .init(), live: .init(), maxPixelSize: 32)
        owned.append(result)
        XCTAssertEqual(try dimensions(result), [32, 24])
        assertColor(try image(result), expected: .green)
        let unpaired = try await makePagerPlaybackMovie()
        defer { try? FileManager.default.removeItem(at: unpaired) }
        let fallback = try await MediaLiveRenderer.shared.photoTime(motionURL: unpaired)
        XCTAssertEqual(fallback, 1.5, accuracy: 0.002)
    }

    func testInvalidAndCancelledEditsDoNotChangeOriginalsOrLeaveManagedOutputs() async throws {
        let source = try await pair()
        let bytes = try [source.still, source.motion].map { try Data(contentsOf: $0) }
        let before = try managedShareFiles { ["Edited Live Photo.jpg", "Edited Live Photo.mov"].contains($0.lastPathComponent) }
        var invalid = LivePhotoEditRecipe(); invalid.keyPhotoTime = 3
        do { _ = try await render(source, live: invalid); XCTFail("An out-of-range frame cannot be saved") }
        catch is MediaVideoEditError {}
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            do {
                _ = try await MediaLiveRenderer.shared.render(motionURL: source.motion, stillURL: source.still,
                    video: .init(), live: .init())
                XCTFail("A cancelled edit must not publish files")
            } catch is CancellationError {}
        }
        try await task.value
        XCTAssertEqual(try [source.still, source.motion].map { try Data(contentsOf: $0) }, bytes)
        XCTAssertEqual(Set(try managedShareFiles { ["Edited Live Photo.jpg", "Edited Live Photo.mov"].contains($0.lastPathComponent) }), Set(before))
    }

    private struct Pair { let still: URL; let motion: URL; let identifier: String }
    private enum Color: Equatable { case red, green, blue, white
        var cgColor: CGColor {
            let components: [CGFloat] = switch self {
            case .red: [1, 0, 0, 1]
            case .green: [0, 1, 0, 1]
            case .blue: [0, 0, 1, 1]
            case .white: [1, 1, 1, 1]
            }
            return CGColor(colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!, components: components)!
        }
    }

    private func render(_ source: Pair, video: VideoEditRecipe = .init(), live: LivePhotoEditRecipe,
                        photo: PhotoEditRecipe = .init()) async throws -> LivePhotoRenderedMedia {
        let result = try await MediaLiveRenderer.shared.render(motionURL: source.motion, stillURL: source.still,
            video: video, live: live, photo: photo)
        owned += result.ownedURLs
        return result
    }

    private func pair(colors: [Color] = [.red, .green, .blue, .white], fps: Int = 4, marker: Double = 0.25) async throws -> Pair {
        let identifier = UUID().uuidString
        let still = directory.appendingPathComponent("\(identifier).jpg")
        let context = try XCTUnwrap(CGContext(data: nil, width: 160, height: 120, bitsPerComponent: 8, bytesPerRow: 640,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        let key = min(colors.count - 1, Int(marker * Double(fps)))
        context.setFillColor(colors[key].cgColor); context.fill(CGRect(x: 0, y: 0, width: 160, height: 120))
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(still as CFURL, UTType.jpeg.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try XCTUnwrap(context.makeImage()),
            [kCGImagePropertyMakerAppleDictionary: ["17": identifier]] as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        let motion = directory.appendingPathComponent("\(identifier).mov")
        let writer = try AVAssetWriter(outputURL: motion, fileType: .mov)
        let content = AVMutableMetadataItem(); content.identifier = .quickTimeMetadataContentIdentifier
        content.dataType = kCMMetadataBaseDataType_UTF8 as String; content.value = identifier as NSString
        writer.metadata = [content]
        let video = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: 64, AVVideoHeightKey: 48,
            AVVideoColorPropertiesKey: [AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                AVVideoTransferFunctionKey: AVVideoTransferFunction_IEC_sRGB,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2]])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: video, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: 64, kCVPixelBufferHeightKey as String: 48])
        writer.add(video)
        let audio = AVAssetWriterInput(mediaType: .audio, outputSettings: [AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 48_000, AVNumberOfChannelsKey: 2, AVEncoderBitRateKey: 192_000])
        writer.add(audio)
        var description: CMMetadataFormatDescription?
        let specification: [CFString: Any] = [kCMMetadataFormatDescriptionMetadataSpecificationKey_Identifier: "mdta/com.apple.quicktime.still-image-time",
            kCMMetadataFormatDescriptionMetadataSpecificationKey_DataType: kCMMetadataBaseDataType_SInt8]
        XCTAssertEqual(CMMetadataFormatDescriptionCreateWithMetadataSpecifications(allocator: kCFAllocatorDefault,
            metadataType: kCMMetadataFormatType_Boxed, metadataSpecifications: [specification] as CFArray,
            formatDescriptionOut: &description), noErr)
        let metadata = AVAssetWriterInput(mediaType: .metadata, outputSettings: nil, sourceFormatHint: try XCTUnwrap(description))
        writer.add(metadata)
        let metadataAdaptor = AVAssetWriterInputMetadataAdaptor(assetWriterInput: metadata)
        XCTAssertTrue(writer.startWriting()); writer.startSession(atSourceTime: .zero)
        try await ready(metadata)
        let item = AVMutableMetadataItem(); item.identifier = AVMetadataIdentifier(rawValue: "mdta/com.apple.quicktime.still-image-time")
        item.dataType = kCMMetadataBaseDataType_SInt8 as String; item.value = NSNumber(value: Int8(0))
        XCTAssertTrue(metadataAdaptor.append(AVTimedMetadataGroup(items: [item], timeRange: CMTimeRange(
            start: CMTime(seconds: marker, preferredTimescale: 600), duration: CMTime(value: 1, timescale: 30)))))
        metadata.markAsFinished()
        try await ready(audio)
        XCTAssertTrue(audio.append(try tone(duration: Double(colors.count) / Double(fps))))
        audio.markAsFinished()
        for (index, color) in colors.enumerated() {
            try await ready(video)
            var buffer: CVPixelBuffer?
            XCTAssertEqual(CVPixelBufferPoolCreatePixelBuffer(nil, try XCTUnwrap(adaptor.pixelBufferPool), &buffer), kCVReturnSuccess)
            let pixel = try XCTUnwrap(buffer)
            CVBufferSetAttachment(pixel, kCVImageBufferColorPrimariesKey,
                kCVImageBufferColorPrimaries_ITU_R_709_2, .shouldPropagate)
            CVBufferSetAttachment(pixel, kCVImageBufferTransferFunctionKey,
                kCVImageBufferTransferFunction_sRGB, .shouldPropagate)
            CVBufferSetAttachment(pixel, kCVImageBufferYCbCrMatrixKey,
                kCVImageBufferYCbCrMatrix_ITU_R_709_2, .shouldPropagate)
            CVBufferSetAttachment(pixel, kCVImageBufferCGColorSpaceKey,
                CGColorSpace(name: CGColorSpace.sRGB)!, .shouldPropagate)
            CVPixelBufferLockBaseAddress(pixel, [])
            let storage = try XCTUnwrap(CVPixelBufferGetBaseAddress(pixel)).assumingMemoryBound(to: UInt8.self)
            let stride = CVPixelBufferGetBytesPerRow(pixel)
            let rgb = color.cgColor.components!
            for y in 0..<48 {
                for x in 0..<64 {
                    let offset = y * stride + x * 4
                    storage[offset] = UInt8((rgb[2] * 255).rounded())
                    storage[offset + 1] = UInt8((rgb[1] * 255).rounded())
                    storage[offset + 2] = UInt8((rgb[0] * 255).rounded())
                    storage[offset + 3] = 255
                }
            }
            CVPixelBufferUnlockBaseAddress(pixel, [])
            XCTAssertTrue(adaptor.append(pixel, withPresentationTime: CMTime(value: Int64(index), timescale: Int32(fps))))
        }
        writer.endSession(atSourceTime: CMTime(value: Int64(colors.count), timescale: Int32(fps)))
        video.markAsFinished(); await writer.finishWriting()
        XCTAssertEqual(writer.status, .completed, String(describing: writer.error))
        return Pair(still: still, motion: motion, identifier: identifier)
    }

    private func tone(duration: Double) throws -> CMSampleBuffer {
        let count = Int(duration * 48_000)
        var samples = [Int16](repeating: 0, count: count * 2)
        for index in 0..<count {
            let section = min(3, index / 12_000)
            let amplitude = [1000.0, 6000, 12_000, 20_000][section]
            let value = Int16(sin(Double(index) / 48_000 * 880 * 2 * .pi) * amplitude)
            samples[index * 2] = value; samples[index * 2 + 1] = value
        }
        let data = samples.withUnsafeBytes { Data($0) }
        var description = AudioStreamBasicDescription(mSampleRate: 48_000, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked, mBytesPerPacket: 4,
            mFramesPerPacket: 1, mBytesPerFrame: 4, mChannelsPerFrame: 2, mBitsPerChannel: 16, mReserved: 0)
        var format: CMAudioFormatDescription?
        XCTAssertEqual(CMAudioFormatDescriptionCreate(allocator: kCFAllocatorDefault, asbd: &description,
            layoutSize: 0, layout: nil, magicCookieSize: 0, magicCookie: nil, extensions: nil, formatDescriptionOut: &format), noErr)
        var block: CMBlockBuffer?
        XCTAssertEqual(CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault, memoryBlock: nil,
            blockLength: data.count, blockAllocator: kCFAllocatorDefault, customBlockSource: nil,
            offsetToData: 0, dataLength: data.count, flags: 0, blockBufferOut: &block), kCMBlockBufferNoErr)
        try data.withUnsafeBytes { bytes in
            XCTAssertEqual(CMBlockBufferReplaceDataBytes(with: try XCTUnwrap(bytes.baseAddress), blockBuffer: try XCTUnwrap(block),
                offsetIntoDestination: 0, dataLength: bytes.count), kCMBlockBufferNoErr)
        }
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 48_000), presentationTimeStamp: .zero, decodeTimeStamp: .invalid)
        var size = 4
        var sample: CMSampleBuffer?
        XCTAssertEqual(CMSampleBufferCreateReady(allocator: kCFAllocatorDefault, dataBuffer: block, formatDescription: format,
            sampleCount: count, sampleTimingEntryCount: 1, sampleTimingArray: &timing,
            sampleSizeEntryCount: 1, sampleSizeArray: &size, sampleBufferOut: &sample), noErr)
        return try XCTUnwrap(sample)
    }

    private func audioLevels(_ url: URL) async throws -> [Double] {
        let asset = AVURLAsset(url: url)
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderAudioMixOutput(audioTracks: try await asset.loadTracks(withMediaType: .audio),
            audioSettings: [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 48_000, AVNumberOfChannelsKey: 1,
                AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsNonInterleaved: false])
        reader.add(output); XCTAssertTrue(reader.startReading())
        var data = Data()
        while let sample = output.copyNextSampleBuffer() {
            let block = try XCTUnwrap(CMSampleBufferGetDataBuffer(sample))
            var bytes = Data(count: CMBlockBufferGetDataLength(block))
            let status = bytes.withUnsafeMutableBytes { CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: $0.count, destination: $0.baseAddress!) }
            XCTAssertEqual(status, kCMBlockBufferNoErr); data.append(bytes)
        }
        XCTAssertEqual(reader.status, .completed)
        let count = data.count / 2
        return data.withUnsafeBytes { storage in
            let samples = storage.bindMemory(to: Int16.self)
            return stride(from: 6000, to: count, by: 12_000).map { center in
                let range = max(0, center - 1000)..<min(count, center + 1000)
                return sqrt(range.reduce(0.0) { $0 + pow(Double(samples[$1]), 2) } / Double(range.count))
            }
        }
    }

    private func ready(_ input: AVAssetWriterInput) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !input.isReadyForMoreMediaData, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertTrue(input.isReadyForMoreMediaData)
    }

    private func videoFrame(_ url: URL, time: Double) async throws -> CGImage {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url)); generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero; generator.requestedTimeToleranceAfter = .zero
        return try await generator.image(at: CMTime(seconds: time, preferredTimescale: 600)).image
    }

    private func image(_ url: URL) throws -> CGImage {
        try XCTUnwrap(CGImageSourceCreateImageAtIndex(try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil)), 0, nil))
    }
    private func dimensions(_ url: URL) throws -> [Int] { let image = try image(url); return [image.width, image.height] }
    private func imageProperties(_ url: URL) throws -> [String: Any] {
        try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil)), 0, nil) as? [String: Any])
    }
    private func identifier(_ url: URL) throws -> String {
        try XCTUnwrap((try imageProperties(url)[kCGImagePropertyMakerAppleDictionary as String] as? [String: Any])?["17"] as? String)
    }
    private func pixel(_ image: CGImage) throws -> [Int] {
        let context = try XCTUnwrap(CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        let bytes = try XCTUnwrap(context.data).assumingMemoryBound(to: UInt8.self)
        return (0..<3).map { Int(bytes[$0]) }
    }
    private func assertColor(_ image: CGImage, expected: Color, file: StaticString = #filePath, line: UInt = #line) {
        do {
            let actual = try pixel(image)
            let wanted = expected == .red ? [255, 0, 0] : expected == .green ? [0, 255, 0] : expected == .blue ? [0, 0, 255] : [255, 255, 255]
            for index in 0..<3 {
                XCTAssertEqual(Double(actual[index]), Double(wanted[index]), accuracy: 25,
                    "Decoded sRGB \(actual), expected \(wanted)", file: file, line: line)
            }
        } catch { XCTFail(String(describing: error), file: file, line: line) }
    }
    private func validatesPair(still: URL, motion: URL) async throws -> Bool {
        let state = LivePairCompletion()
        return try await withCheckedThrowingContinuation { continuation in
            PHLivePhoto.request(withResourceFileURLs: [still, motion], placeholderImage: nil,
                targetSize: CGSize(width: 160, height: 120), contentMode: .aspectFit) { photo, info in
                if info[PHLivePhotoInfoIsDegradedKey] as? Bool == true { return }
                state.once {
                    if let error = info[PHLivePhotoInfoErrorKey] as? Error { continuation.resume(throwing: error) }
                    else { continuation.resume(returning: photo != nil) }
                }
            }
        }
    }
}

private final class LivePairCompletion: @unchecked Sendable {
    private let lock = NSLock()
    private var completed = false
    func once(_ block: () -> Void) {
        let accepted = lock.withLock { if completed { return false }; completed = true; return true }
        if accepted { block() }
    }
}
