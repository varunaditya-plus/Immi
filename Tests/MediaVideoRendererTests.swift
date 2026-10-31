import AVFoundation
import CoreGraphics
import CryptoKit
import XCTest
@testable import ImmichApp

@MainActor
final class MediaVideoRendererTests: XCTestCase {
    private var directories: [URL] = []
    private var outputs: [URL] = []
    override func tearDown() async throws {
        TemporaryMediaStore.remove(outputs)
        for directory in directories { try FileManager.default.removeItem(at: directory) }
        try await super.tearDown()
    }

    func testTrimAndSpeedExportActualFramesAudioAndOrientationWithoutChangingTheOriginal() async throws {
        let source = try await fixture()
        let checksum = SHA256.hash(data: try Data(contentsOf: source))
        let recipe = VideoEditRecipe(trimStart: 1, trimEnd: 2, rate: 0.5)
        let output = try await MediaVideoRenderer.shared.renderVideo(sourceURL: source, video: recipe)
        outputs.append(output)
        let asset = AVURLAsset(url: output)
        let duration = try await asset.load(.duration).seconds
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        XCTAssertEqual(duration, 2, accuracy: 0.08)
        XCTAssertEqual(audioTracks.count, 1)
        let image = try await frame(asset, at: 0.5)
        XCTAssertEqual(image.width, 16)
        XCTAssertEqual(image.height, 32)
        let pixel = try centerPixel(image)
        XCTAssertGreaterThan(Int(pixel[1]), Int(pixel[0]) + 60, "The saved clip must start with the selected green second, not the original red frame")
        XCTAssertGreaterThan(Int(pixel[1]), Int(pixel[2]) + 60)
        XCTAssertEqual(SHA256.hash(data: try Data(contentsOf: source)), checksum)
    }

    func testMutedFilteredCropChangesTheExportedMovieInsteadOfOnlyItsPreview() async throws {
        let source = try await fixture()
        var photo = PhotoEditRecipe()
        photo.framing = CGRect(x: 0, y: 0, width: 0.5, height: 1)
        photo.filter = .mono
        let output = try await MediaVideoRenderer.shared.renderVideo(sourceURL: source,
            video: VideoEditRecipe(trimStart: 1, trimEnd: 2, isMuted: true), photo: photo)
        outputs.append(output)
        let asset = AVURLAsset(url: output)
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        XCTAssertTrue(audioTracks.isEmpty)
        let image = try await frame(asset, at: 0.25)
        XCTAssertEqual(image.width, 16)
        XCTAssertEqual(image.height, 64)
        let pixel = try centerPixel(image)
        XCTAssertLessThan(abs(Int(pixel[0]) - Int(pixel[1])), 12)
        XCTAssertLessThan(abs(Int(pixel[1]) - Int(pixel[2])), 12)
        XCTAssertGreaterThan(Int(pixel[1]), 30)
    }

    func testFramingCropsTheSelectedSpatialRegionOnceAfterOrientation() async throws {
        let source = try await fixture(spatialBands: true)
        var photo = PhotoEditRecipe()
        photo.framing = CGRect(x: 0, y: 0, width: 0.5, height: 1)
        let output = try await MediaVideoRenderer.shared.renderVideo(sourceURL: source,
            video: VideoEditRecipe(trimStart: 1, trimEnd: 2), photo: photo)
        outputs.append(output)
        let original = try await frame(AVURLAsset(url: source), at: 1.25)
        let cropped = try await frame(AVURLAsset(url: output), at: 0.25)
        XCTAssertEqual([original.width, original.height], [64, 128])
        XCTAssertEqual([cropped.width, cropped.height], [32, 128])
        let first = try centerPixel(original, x: 0.125), second = try centerPixel(original, x: 0.375)
        var distance = 0
        for channel in 0..<3 { distance += abs(Int(first[channel]) - Int(second[channel])) }
        XCTAssertGreaterThan(distance, 100)
        for (actual, expected) in [(try centerPixel(cropped, x: 0.25), first), (try centerPixel(cropped, x: 0.75), second)] {
            for channel in 0..<3 { XCTAssertLessThanOrEqual(abs(Int(actual[channel]) - Int(expected[channel])), 30) }
        }
    }

    func testInvalidAndCanceledExportsCannotPublishAnOutputOrChangeTheirSource() async throws {
        let source = try await fixture()
        let original = try Data(contentsOf: source)
        do {
            _ = try await MediaVideoRenderer.shared.renderVideo(sourceURL: source, video: VideoEditRecipe(trimStart: 2, trimEnd: 1))
            XCTFail("An inverted range must fail")
        } catch { XCTAssertTrue(error is MediaVideoEditError) }
        let task = Task { try await MediaVideoRenderer.shared.renderVideo(sourceURL: source, video: VideoEditRecipe(rate: 0.5)) }
        task.cancel()
        do { outputs.append(try await task.value); XCTFail("A canceled export cannot publish its file") }
        catch { XCTAssertTrue(error is CancellationError || (error as NSError).code == NSUserCancelledError) }
        XCTAssertEqual(try Data(contentsOf: source), original)
    }

    private func fixture(spatialBands: Bool = false) async throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("video-render-tests-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        directories.append(directory)
        return try await makeVideoEditingFixture(in: directory, spatialBands: spatialBands)
    }
    private func frame(_ asset: AVAsset, at time: Double) async throws -> CGImage {
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        return try await generator.image(at: CMTime(seconds: time, preferredTimescale: 600)).image
    }
    private func centerPixel(_ image: CGImage, x: CGFloat = 0.5) throws -> [UInt8] {
        var pixel = [UInt8](repeating: 0, count: 4)
        try pixel.withUnsafeMutableBytes { bytes in
            let context = try XCTUnwrap(CGContext(data: bytes.baseAddress, width: 1, height: 1, bitsPerComponent: 8,
                bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.draw(image, in: CGRect(x: -CGFloat(image.width) * x, y: -CGFloat(image.height) / 2,
                width: CGFloat(image.width), height: CGFloat(image.height)))
        }
        return pixel
    }
}

@MainActor
func makeVideoEditingFixture(in directory: URL, spatialBands: Bool = false) async throws -> URL {
    let width = spatialBands ? 128 : 32, height = spatialBands ? 64 : 16
    let video = directory.appendingPathComponent("frames.mov")
    let writer = try AVAssetWriter(outputURL: video, fileType: .mov)
    let input = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264,
        AVVideoWidthKey: width, AVVideoHeightKey: height])
    input.transform = CGAffineTransform(rotationAngle: .pi / 2)
    let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB,
        kCVPixelBufferWidthKey as String: width, kCVPixelBufferHeightKey as String: height])
    writer.add(input)
    XCTAssertTrue(writer.startWriting())
    writer.startSession(atSourceTime: .zero)
    for index in 0..<3 {
        let deadline = Date().addingTimeInterval(3)
        while !input.isReadyForMoreMediaData, Date() < deadline { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertTrue(input.isReadyForMoreMediaData)
        var raw: CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferPoolCreatePixelBuffer(nil, try XCTUnwrap(adaptor.pixelBufferPool), &raw), kCVReturnSuccess)
        let buffer = try XCTUnwrap(raw)
        CVPixelBufferLockBaseAddress(buffer, [])
        let context = try XCTUnwrap(CGContext(data: CVPixelBufferGetBaseAddress(buffer), width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(buffer), space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
        let colors = [CGColor(red: 1, green: 0, blue: 0, alpha: 1), CGColor(red: 0, green: 1, blue: 0, alpha: 1),
            CGColor(red: 0, green: 0, blue: 1, alpha: 1), CGColor(gray: 1, alpha: 1)]
        if spatialBands {
            for band in 0..<4 {
                context.setFillColor(colors[band])
                context.fill(CGRect(x: 0, y: height * band / 4, width: width, height: height / 4))
            }
        } else {
            context.setFillColor(colors[index]); context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        }
        CVPixelBufferUnlockBaseAddress(buffer, [])
        XCTAssertTrue(adaptor.append(buffer, withPresentationTime: CMTime(value: Int64(index), timescale: 1)))
    }
    writer.endSession(atSourceTime: CMTime(seconds: 3, preferredTimescale: 600))
    input.markAsFinished(); await writer.finishWriting()
    XCTAssertEqual(writer.status, .completed)
    let audio = directory.appendingPathComponent("tone.caf")
    let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 8000, channels: 1))
    let samples = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 24000))
    samples.frameLength = 24000
    let channel = try XCTUnwrap(samples.floatChannelData?.pointee)
    for index in 0..<24000 { channel[index] = Float(sin(Double(index) * 2 * .pi * 440 / 8000)) * 0.2 }
    do { let file = try AVAudioFile(forWriting: audio, settings: format.settings); try file.write(from: samples) }
    let videoAsset = AVURLAsset(url: video), audioAsset = AVURLAsset(url: audio), composition = AVMutableComposition()
    let sourceVideos = try await videoAsset.loadTracks(withMediaType: .video)
    let sourceVideo = try XCTUnwrap(sourceVideos.first)
    let targetVideo = try XCTUnwrap(composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid))
    try targetVideo.insertTimeRange(CMTimeRange(start: .zero, duration: CMTime(seconds: 3, preferredTimescale: 600)), of: sourceVideo, at: .zero)
    targetVideo.preferredTransform = try await sourceVideo.load(.preferredTransform)
    let targetAudio = try XCTUnwrap(composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid))
    let sourceAudios = try await audioAsset.loadTracks(withMediaType: .audio)
    try targetAudio.insertTimeRange(CMTimeRange(start: .zero, duration: CMTime(seconds: 3, preferredTimescale: 600)),
        of: try XCTUnwrap(sourceAudios.first), at: .zero)
    let output = directory.appendingPathComponent("original.mov")
    let exporter = try XCTUnwrap(AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetPassthrough))
    try await exporter.export(to: output, as: .mov)
    return output
}
