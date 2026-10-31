import AVFoundation
import CoreImage
import Foundation
import ImageIO
import UniformTypeIdentifiers

struct LivePhotoRenderedMedia: Sendable {
    let primaryURL: URL
    let motionURL: URL?
    let isVideo: Bool
    var ownedURLs: [URL] { [primaryURL, motionURL].compactMap { $0 } }
}

actor MediaLiveRenderer {
    static let shared = MediaLiveRenderer()
    private let context = CIContext(options: [.cacheIntermediates: false])
    private static let marker = "mdta/com.apple.quicktime.still-image-time"

    /// Older/unpaired motion resources have no marker; only those fall back to their midpoint.
    func photoTime(motionURL: URL) async throws -> Double {
        let asset = AVURLAsset(url: motionURL)
        if let time = try await markerTime(asset) { return time }
        let duration = try await asset.load(.duration).seconds
        guard duration.isFinite, duration > 0 else { throw MediaVideoEditError.unavailableVideo }
        return duration / 2
    }

    func renderPoster(motionURL: URL, stillURL: URL? = nil, video: VideoEditRecipe,
                      live: LivePhotoEditRecipe, photo: PhotoEditRecipe = .init(), maxPixelSize: Int? = nil) async throws -> URL {
        try Task.checkCancellation()
        guard motionURL.isFileURL, stillURL?.isFileURL != false else { throw MediaVideoEditError.unavailableVideo }
        let work = try workDirectory()
        defer { try? FileManager.default.removeItem(at: work) }
        let poster = try await poster(motionURL: motionURL, stillURL: stillURL, video: video,
            live: live, photo: photo, maxPixelSize: maxPixelSize)
        let file = try writeStill(poster.image, properties: poster.properties, identifier: nil, in: work)
        try Task.checkCancellation()
        return try TemporaryMediaStore.adoptShareFile(at: file, suggestedFilename: "Edited Photo.jpg")
    }

    func render(motionURL: URL, stillURL: URL? = nil, video: VideoEditRecipe,
                live: LivePhotoEditRecipe, photo: PhotoEditRecipe = .init()) async throws -> LivePhotoRenderedMedia {
        try Task.checkCancellation()
        guard motionURL.isFileURL, stillURL?.isFileURL != false else { throw MediaVideoEditError.unavailableVideo }
        let original = AVURLAsset(url: motionURL)
        guard try await !original.loadTracks(withMediaType: .video).isEmpty else { throw MediaVideoEditError.unavailableVideo }
        let originalDuration = try await original.load(.duration).seconds
        _ = try live.validatedPhotoTime(video: video, duration: originalDuration)
        if live.mode == .off || live.mode == .longExposure {
            return LivePhotoRenderedMedia(primaryURL: try await renderPoster(motionURL: motionURL,
                stillURL: stillURL, video: video, live: live, photo: photo), motionURL: nil, isVideo: false)
        }
        let work = try workDirectory()
        var intermediates: [URL] = [], owned: [URL] = []
        defer { TemporaryMediaStore.remove(intermediates); try? FileManager.default.removeItem(at: work) }
        do {
            let base: URL
            if video.isIdentity && photo.isIdentity { base = motionURL }
            else {
                base = try await MediaVideoRenderer.shared.renderVideo(sourceURL: motionURL, video: video, photo: photo)
                intermediates.append(base)
            }
            let result: LivePhotoRenderedMedia
            if live.mode == .live {
                let poster = try await poster(motionURL: motionURL, stillURL: stillURL, video: video,
                    live: live, photo: photo, maxPixelSize: nil)
                let source = AVURLAsset(url: motionURL)
                let sourceDuration = try await source.load(.duration).seconds
                let range = try video.selection(duration: sourceDuration)
                let baseDuration = try await AVURLAsset(url: base).load(.duration).seconds
                let time = min(max(0, (poster.time - range.start.seconds) / video.rate), max(0, baseDuration - 0.001))
                let identifier = UUID().uuidString
                let still = try writeStill(poster.image, properties: poster.properties, identifier: identifier, in: work)
                let primary = try TemporaryMediaStore.adoptShareFile(at: still, suggestedFilename: "Edited Live Photo.jpg")
                owned.append(primary)
                let movie = try await pairedMovie(base, identifier: identifier, time: time, in: work)
                let motion = try TemporaryMediaStore.adoptShareFile(at: movie, suggestedFilename: "Edited Live Photo.mov")
                owned.append(motion)
                result = .init(primaryURL: primary, motionURL: motion, isVideo: false)
            } else {
                let movie = live.mode == .loop ? try await loopMovie(base, in: work) : try await bounceMovie(base, in: work)
                let primary = try TemporaryMediaStore.adoptShareFile(at: movie, suggestedFilename: live.mode == .loop ? "Loop.mov" : "Bounce.mov")
                owned.append(primary)
                result = .init(primaryURL: primary, motionURL: nil, isVideo: true)
            }
            try Task.checkCancellation()
            return result
        } catch { TemporaryMediaStore.remove(owned); throw error }
    }

    private struct Poster {
        let image: CIImage
        let properties: [String: Any]
        let time: Double
    }

    private func poster(motionURL: URL, stillURL: URL?, video: VideoEditRecipe,
                        live: LivePhotoEditRecipe, photo: PhotoEditRecipe, maxPixelSize: Int?) async throws -> Poster {
        try Task.checkCancellation()
        if let maxPixelSize, maxPixelSize < 1 { throw MediaVideoEditError.invalidSelection }
        let source = AVURLAsset(url: motionURL)
        guard try await !source.loadTracks(withMediaType: .video).isEmpty else { throw MediaVideoEditError.unavailableVideo }
        let duration = try await source.load(.duration).seconds
        let range = try video.selection(duration: duration)
        let originalTime = try await markerTime(source)
        let requested = try live.validatedPhotoTime(video: video, duration: duration)
        let key = live.keyPhotoTime == nil ? originalTime ?? requested : requested
        let time = min(max(key, range.start.seconds), max(range.start.seconds, range.end.seconds - 0.001))
        if live.mode == .longExposure {
            let image = try await longExposure(source, range: range, maxPixelSize: maxPixelSize)
            return Poster(image: try PhotoEditRenderer.render(image, recipe: photo), properties: [:], time: time)
        }
        if live.keyPhotoTime == nil, key >= range.start.seconds, key < range.end.seconds, let stillURL {
            guard let input = CGImageSourceCreateWithURL(stillURL as CFURL, nil), CGImageSourceGetCount(input) == 1 else {
                throw PhotoEditRenderError.unavailable
            }
            let properties = CGImageSourceCopyPropertiesAtIndex(input, 0, nil) as? [String: Any] ?? [:]
            let image: CGImage?
            if let maxPixelSize {
                image = CGImageSourceCreateThumbnailAtIndex(input, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceThumbnailMaxPixelSize: maxPixelSize] as CFDictionary)
            } else { image = CGImageSourceCreateImageAtIndex(input, 0, nil) }
            guard let image else { throw PhotoEditRenderError.unavailable }
            let orientation = maxPixelSize == nil ? (properties[kCGImagePropertyOrientation as String] as? NSNumber)?.int32Value ?? 1 : 1
            return Poster(image: try PhotoEditRenderer.render(CIImage(cgImage: image).oriented(forExifOrientation: orientation), recipe: photo),
                properties: properties, time: time)
        }
        let generator = imageGenerator(source, maxPixelSize: maxPixelSize)
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        let (image, actual) = try await frame(generator, at: CMTime(seconds: time, preferredTimescale: 60_000))
        return Poster(image: try PhotoEditRenderer.render(CIImage(cgImage: image), recipe: photo), properties: [:], time: actual.seconds)
    }

    private func markerTime(_ asset: AVAsset) async throws -> Double? {
        for track in try await asset.loadTracks(withMediaType: .metadata) {
            let identifiers = try await track.load(.formatDescriptions).flatMap { CMMetadataFormatDescriptionGetIdentifiers($0) as? [String] ?? [] }
            guard identifiers.contains(Self.marker) else { continue }
            let reader = try AVAssetReader(asset: asset)
            let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
            guard reader.canAdd(output) else { continue }
            reader.add(output)
            let adaptor = AVAssetReaderOutputMetadataAdaptor(assetReaderTrackOutput: output)
            guard reader.startReading() else { throw reader.error ?? MediaVideoEditError.unavailableVideo }
            defer { reader.cancelReading() }
            while let group = adaptor.nextTimedMetadataGroup() {
                try Task.checkCancellation()
                for item in group.items where item.identifier?.rawValue == Self.marker {
                    if try await item.load(.numberValue)?.intValue == 0, group.timeRange.start.seconds.isFinite {
                        return group.timeRange.start.seconds
                    }
                }
            }
            if reader.status == .failed { throw reader.error ?? MediaVideoEditError.unavailableVideo }
        }
        return nil
    }

    private func longExposure(_ source: AVAsset, range: CMTimeRange, maxPixelSize: Int?) async throws -> CIImage {
        guard let track = try await source.loadTracks(withMediaType: .video).first else { throw MediaVideoEditError.unavailableVideo }
        let fps = max(1, min(30, Double(try await track.load(.nominalFrameRate))))
        let count = min(60, max(2, Int(ceil(range.duration.seconds * fps))))
        let generator = imageGenerator(source, maxPixelSize: maxPixelSize)
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        var buffers: [CVPixelBuffer] = []
        var extent = CGRect.zero
        let colorSpace = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!
        for index in 0..<count {
            try Task.checkCancellation()
            let time = CMTime(seconds: range.start.seconds + range.duration.seconds * Double(index) / Double(count), preferredTimescale: 60_000)
            let (image, _) = try await frame(generator, at: time)
            if buffers.isEmpty {
                extent = CGRect(x: 0, y: 0, width: image.width, height: image.height)
                buffers = try (0..<2).map { _ in try pixelBuffer(width: image.width, height: image.height, format: kCVPixelFormatType_64RGBAHalf) }
            }
            let incoming = CIImage(cgImage: image)
            let result = index == 0 ? incoming : incoming.applyingFilter("CIDissolveTransition", parameters: [
                kCIInputTargetImageKey: CIImage(cvPixelBuffer: buffers[(index - 1) % 2], options: [.colorSpace: colorSpace]),
                kCIInputTimeKey: Double(index) / Double(index + 1),
            ])
            context.render(result, to: buffers[index % 2], bounds: extent, colorSpace: colorSpace)
        }
        // Materialize the final accumulator so later renders cannot refer to a reused buffer.
        let average = CIImage(cvPixelBuffer: buffers[(count - 1) % 2], options: [.colorSpace: colorSpace])
        guard let image = context.createCGImage(average, from: extent) else { throw PhotoEditRenderError.failed }
        return CIImage(cgImage: image)
    }

    private func writeStill(_ image: CIImage, properties original: [String: Any], identifier: String?, in work: URL) throws -> URL {
        try Task.checkCancellation()
        guard let rendered = context.createCGImage(image, from: image.extent.integral) else { throw PhotoEditRenderError.failed }
        let file = work.appendingPathComponent("\(UUID()).jpg")
        guard let destination = CGImageDestinationCreateWithURL(file as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else {
            throw PhotoEditRenderError.failed
        }
        var properties = original
        properties[kCGImagePropertyOrientation as String] = 1
        properties[kCGImagePropertyPixelWidth as String] = rendered.width
        properties[kCGImagePropertyPixelHeight as String] = rendered.height
        properties[kCGImageDestinationLossyCompressionQuality as String] = 0.98
        if var exif = properties[kCGImagePropertyExifDictionary as String] as? [String: Any] {
            exif[kCGImagePropertyExifPixelXDimension as String] = rendered.width
            exif[kCGImagePropertyExifPixelYDimension as String] = rendered.height
            exif[kCGImagePropertyExifMakerNote as String] = nil
            properties[kCGImagePropertyExifDictionary as String] = exif
        }
        if var tiff = properties[kCGImagePropertyTIFFDictionary as String] as? [String: Any] {
            tiff[kCGImagePropertyTIFFOrientation as String] = 1
            properties[kCGImagePropertyTIFFDictionary as String] = tiff
        }
        var maker = properties[kCGImagePropertyMakerAppleDictionary as String] as? [String: Any] ?? [:]
        if let identifier { maker["17"] = identifier }
        else { maker.removeValue(forKey: "17") }
        properties[kCGImagePropertyMakerAppleDictionary as String] = maker.isEmpty ? nil : maker
        CGImageDestinationAddImage(destination, rendered, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw PhotoEditRenderError.failed }
        if let identifier {
            guard let source = CGImageSourceCreateWithURL(file as CFURL, nil),
                  let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any],
                  (properties[kCGImagePropertyMakerAppleDictionary as String] as? [String: Any])?["17"] as? String == identifier else {
                throw PhotoEditRenderError.failed
            }
        }
        return file
    }

    private func pairedMovie(_ url: URL, identifier: String, time: Double, in work: URL) async throws -> URL {
        let asset = AVURLAsset(url: url)
        let reader = try AVAssetReader(asset: asset)
        let file = work.appendingPathComponent("paired.mov")
        let writer = try AVAssetWriter(outputURL: file, fileType: .mov)
        var channels: [(AVAssetReaderTrackOutput, AVAssetWriterInput)] = []
        for track in try await asset.load(.tracks) where track.mediaType == .video || track.mediaType == .audio {
            guard let format = try await track.load(.formatDescriptions).first else { throw MediaVideoEditError.unavailableVideo }
            let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
            let input = AVAssetWriterInput(mediaType: track.mediaType, outputSettings: nil, sourceFormatHint: format)
            if track.mediaType == .video { input.transform = try await track.load(.preferredTransform) }
            guard reader.canAdd(output), writer.canAdd(input) else { throw MediaVideoEditError.exportUnavailable }
            reader.add(output); writer.add(input); channels.append((output, input))
        }
        guard channels.contains(where: { $0.1.mediaType == .video }) else { throw MediaVideoEditError.unavailableVideo }
        var description: CMMetadataFormatDescription?
        let specification: [CFString: Any] = [kCMMetadataFormatDescriptionMetadataSpecificationKey_Identifier: Self.marker,
            kCMMetadataFormatDescriptionMetadataSpecificationKey_DataType: kCMMetadataBaseDataType_SInt8]
        guard CMMetadataFormatDescriptionCreateWithMetadataSpecifications(allocator: kCFAllocatorDefault,
            metadataType: kCMMetadataFormatType_Boxed, metadataSpecifications: [specification] as CFArray,
            formatDescriptionOut: &description) == noErr, let description else { throw MediaVideoEditError.exportUnavailable }
        let metadataInput = AVAssetWriterInput(mediaType: .metadata, outputSettings: nil, sourceFormatHint: description)
        guard writer.canAdd(metadataInput) else { throw MediaVideoEditError.exportUnavailable }
        writer.add(metadataInput)
        let adaptor = AVAssetWriterInputMetadataAdaptor(assetWriterInput: metadataInput)
        let content = AVMutableMetadataItem()
        content.identifier = .quickTimeMetadataContentIdentifier
        content.dataType = kCMMetadataBaseDataType_UTF8 as String
        content.value = identifier as NSString
        writer.metadata = try await ordinaryMetadata(asset) + [content]
        guard writer.startWriting(), reader.startReading() else { throw writer.error ?? reader.error ?? MediaVideoEditError.exportFailed }
        do {
            writer.startSession(atSourceTime: .zero)
            try await wait(metadataInput, writer: writer)
            let marker = AVMutableMetadataItem()
            marker.identifier = AVMetadataIdentifier(rawValue: Self.marker)
            marker.dataType = kCMMetadataBaseDataType_SInt8 as String
            marker.value = NSNumber(value: Int8(0))
            let duration = try await asset.load(.duration).seconds
            let markerDuration = max(1.0 / 60_000, min(1.0 / 30, duration - time))
            guard adaptor.append(AVTimedMetadataGroup(items: [marker], timeRange: CMTimeRange(
                start: CMTime(seconds: time, preferredTimescale: 60_000),
                duration: CMTime(seconds: markerDuration, preferredTimescale: 60_000)))) else {
                throw writer.error ?? MediaVideoEditError.exportFailed
            }
            metadataInput.markAsFinished()
            var finished = Set<Int>()
            var deadline = ContinuousClock.now + .seconds(30)
            while finished.count < channels.count {
                try Task.checkCancellation()
                var advanced = false
                for index in channels.indices where !finished.contains(index) {
                    let (output, input) = channels[index]
                    guard input.isReadyForMoreMediaData else { continue }
                    if let sample = output.copyNextSampleBuffer() {
                        if CMSampleBufferGetNumSamples(sample) > 0, !input.append(sample) { throw writer.error ?? MediaVideoEditError.exportFailed }
                    } else { input.markAsFinished(); finished.insert(index) }
                    advanced = true
                }
                if reader.status == .failed || writer.status == .failed { throw reader.error ?? writer.error ?? MediaVideoEditError.exportFailed }
                if advanced { deadline = ContinuousClock.now + .seconds(30) }
                else {
                    guard ContinuousClock.now < deadline else { throw MediaVideoEditError.exportFailed }
                    try await Task.sleep(for: .milliseconds(5))
                }
            }
            await writer.finishWriting()
            try Task.checkCancellation()
            guard writer.status == .completed else { throw writer.error ?? MediaVideoEditError.exportFailed }
            return file
        } catch { reader.cancelReading(); writer.cancelWriting(); throw error }
    }

    private func loopMovie(_ url: URL, in work: URL) async throws -> URL {
        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration)
        let composition = AVMutableComposition()
        for track in try await asset.load(.tracks) where track.mediaType == .video || track.mediaType == .audio {
            guard let output = composition.addMutableTrack(withMediaType: track.mediaType, preferredTrackID: kCMPersistentTrackID_Invalid) else {
                throw MediaVideoEditError.exportUnavailable
            }
            let range = try await track.load(.timeRange)
            try output.insertTimeRange(range, of: track, at: range.start)
            try output.insertTimeRange(range, of: track, at: CMTimeAdd(duration, range.start))
            if track.mediaType == .video { output.preferredTransform = try await track.load(.preferredTransform) }
        }
        return try await export(composition, metadata: try await ordinaryMetadata(asset), to: work.appendingPathComponent("loop.mov"))
    }

    private func bounceMovie(_ url: URL, in work: URL) async throws -> URL {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else { throw MediaVideoEditError.unavailableVideo }
        let duration = try await asset.load(.duration).seconds
        let nominalRate = try await track.load(.nominalFrameRate)
        let fps = nominalRate.isFinite ? min(30, max(1, Int(nominalRate.rounded()))) : 30
        let count = max(2, Int(ceil(duration * Double(fps))))
        let indices = Array(0..<count) + Array((1..<(count - 1)).reversed())
        let generator = imageGenerator(asset, maxPixelSize: nil)
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        let (first, _) = try await frame(generator, at: .zero)
        let width = (first.width + 1) / 2 * 2, height = (first.height + 1) / 2 * 2
        let file = work.appendingPathComponent("bounce-frames.mov")
        let writer = try AVAssetWriter(outputURL: file, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width, AVVideoHeightKey: height,
            AVVideoColorPropertiesKey: [AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                AVVideoTransferFunctionKey: AVVideoTransferFunction_IEC_sRGB,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2],
            AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: max(1_000_000, width * height * 6)]])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width, kCVPixelBufferHeightKey as String: height])
        guard writer.canAdd(input) else { throw MediaVideoEditError.exportUnavailable }
        writer.add(input)
        writer.metadata = try await ordinaryMetadata(asset)
        guard writer.startWriting() else { throw writer.error ?? MediaVideoEditError.exportFailed }
        do {
            writer.startSession(atSourceTime: .zero)
            for (position, index) in indices.enumerated() {
                try Task.checkCancellation()
                try await wait(input, writer: writer)
                let image = index == 0 ? first : try await frame(generator,
                    at: CMTime(seconds: min(Double(index) / Double(fps), max(0, duration - 0.001)), preferredTimescale: 60_000)).0
                let buffer = try pixelBuffer(width: width, height: height, format: kCVPixelFormatType_32BGRA)
                CVBufferSetAttachment(buffer, kCVImageBufferColorPrimariesKey,
                    kCVImageBufferColorPrimaries_ITU_R_709_2, .shouldPropagate)
                CVBufferSetAttachment(buffer, kCVImageBufferTransferFunctionKey,
                    kCVImageBufferTransferFunction_sRGB, .shouldPropagate)
                CVBufferSetAttachment(buffer, kCVImageBufferYCbCrMatrixKey,
                    kCVImageBufferYCbCrMatrix_ITU_R_709_2, .shouldPropagate)
                CVBufferSetAttachment(buffer, kCVImageBufferCGColorSpaceKey,
                    CGColorSpace(name: CGColorSpace.sRGB)!, .shouldPropagate)
                let source = CIImage(cgImage: image)
                let fitted = source.transformed(by: CGAffineTransform(scaleX: CGFloat(width) / source.extent.width,
                    y: CGFloat(height) / source.extent.height))
                context.render(fitted, to: buffer, bounds: fitted.extent, colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
                guard adaptor.append(buffer, withPresentationTime: CMTime(value: Int64(position), timescale: Int32(fps))) else {
                    throw writer.error ?? MediaVideoEditError.exportFailed
                }
            }
            writer.endSession(atSourceTime: CMTime(value: Int64(indices.count), timescale: Int32(fps)))
            input.markAsFinished()
            await writer.finishWriting()
            try Task.checkCancellation()
            guard writer.status == .completed else { throw writer.error ?? MediaVideoEditError.exportFailed }
        } catch { writer.cancelWriting(); throw error }
        guard let audio = try await bounceAudio(asset, forwardFrames: count, totalFrames: indices.count, fps: fps, in: work) else { return file }
        let composition = AVMutableComposition()
        for source in [AVURLAsset(url: file), AVURLAsset(url: audio)] {
            for track in try await source.load(.tracks) where track.mediaType == .video || track.mediaType == .audio {
                guard let output = composition.addMutableTrack(withMediaType: track.mediaType, preferredTrackID: kCMPersistentTrackID_Invalid) else {
                    throw MediaVideoEditError.exportUnavailable
                }
                let range = CMTimeRange(start: .zero, duration: CMTime(value: Int64(indices.count), timescale: Int32(fps)))
                let available = CMTimeRangeGetIntersection(range, otherRange: try await track.load(.timeRange))
                try output.insertTimeRange(available, of: track, at: available.start)
            }
        }
        return try await export(composition, metadata: try await ordinaryMetadata(asset), to: work.appendingPathComponent("bounce.mov"))
    }

    private func bounceAudio(_ asset: AVAsset, forwardFrames: Int, totalFrames: Int, fps: Int, in work: URL) async throws -> URL? {
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        guard !tracks.isEmpty else { return nil }
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderAudioMixOutput(audioTracks: tracks, audioSettings: [AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 48_000, AVNumberOfChannelsKey: 2, AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false, AVLinearPCMIsNonInterleaved: false])
        guard reader.canAdd(output) else { throw MediaVideoEditError.exportUnavailable }
        reader.add(output)
        let raw = work.appendingPathComponent("bounce-audio.pcm")
        guard FileManager.default.createFile(atPath: raw.path, contents: nil) else { throw MediaVideoEditError.exportFailed }
        let destination = try FileHandle(forWritingTo: raw)
        do {
            guard reader.startReading() else { throw reader.error ?? MediaVideoEditError.unavailableVideo }
            while let sample = output.copyNextSampleBuffer() {
                try Task.checkCancellation()
                guard let buffer = CMSampleBufferGetDataBuffer(sample) else { throw MediaVideoEditError.exportFailed }
                var bytes = Data(count: CMBlockBufferGetDataLength(buffer))
                let status = bytes.withUnsafeMutableBytes {
                    CMBlockBufferCopyDataBytes(buffer, atOffset: 0, dataLength: $0.count, destination: $0.baseAddress!)
                }
                guard status == kCMBlockBufferNoErr else { throw MediaVideoEditError.exportFailed }
                try destination.write(contentsOf: bytes)
            }
            try destination.close()
            guard reader.status == .completed else { throw reader.error ?? MediaVideoEditError.exportFailed }
        } catch { reader.cancelReading(); try? destination.close(); throw error }
        let inputFile = try FileHandle(forReadingFrom: raw)
        defer { try? inputFile.close() }
        let byteCount = try inputFile.seekToEnd()
        guard byteCount > 0, byteCount % 4 == 0 else { throw MediaVideoEditError.exportFailed }
        let availableFrames = Int(byteCount / 4)
        let sampleRate = 48_000
        let firstHalf = Int((Double(forwardFrames) / Double(fps) * Double(sampleRate)).rounded())
        let reverseStart = min(availableFrames, Int((Double(forwardFrames - 1) / Double(fps) * Double(sampleRate)).rounded()))
        let total = Int((Double(totalFrames) / Double(fps) * Double(sampleRate)).rounded())
        let file = work.appendingPathComponent("bounce-audio.m4a")
        let writer = try AVAssetWriter(outputURL: file, fileType: .m4a)
        let input = AVAssetWriterInput(mediaType: .audio, outputSettings: [AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: sampleRate, AVNumberOfChannelsKey: 2, AVEncoderBitRateKey: 192_000])
        guard writer.canAdd(input) else { throw MediaVideoEditError.exportUnavailable }
        writer.add(input)
        guard writer.startWriting() else { throw writer.error ?? MediaVideoEditError.exportFailed }
        do {
            writer.startSession(atSourceTime: .zero)
            var position = 0
            while position < total {
                try Task.checkCancellation()
                let forward = position < firstHalf
                let count = min(4096, total - position, forward ? firstHalf - position : total - position)
                let end = forward ? position + count : reverseStart - (position - firstHalf)
                let start = forward ? position : end - count
                var bytes = Data(count: count * 4)
                let lower = max(0, start), upper = min(availableFrames, end)
                if upper > lower {
                    try inputFile.seek(toOffset: UInt64(lower * 4))
                    let original = try inputFile.read(upToCount: (upper - lower) * 4) ?? Data()
                    guard original.count == (upper - lower) * 4 else { throw MediaVideoEditError.exportFailed }
                    bytes.replaceSubrange((lower - start) * 4..<(upper - start) * 4, with: original)
                }
                if !forward {
                    bytes.withUnsafeMutableBytes { storage in
                        let frames = storage.bindMemory(to: UInt32.self)
                        for index in 0..<(count / 2) { frames.swapAt(index, count - index - 1) }
                    }
                }
                try await wait(input, writer: writer)
                guard input.append(try audioSample(bytes, position: position, count: count, sampleRate: sampleRate)) else {
                    throw writer.error ?? MediaVideoEditError.exportFailed
                }
                position += count
            }
            writer.endSession(atSourceTime: CMTime(value: Int64(total), timescale: Int32(sampleRate)))
            input.markAsFinished()
            await writer.finishWriting()
            try Task.checkCancellation()
            guard writer.status == .completed else { throw writer.error ?? MediaVideoEditError.exportFailed }
            return file
        } catch { writer.cancelWriting(); throw error }
    }

    private func audioSample(_ bytes: Data, position: Int, count: Int, sampleRate: Int) throws -> CMSampleBuffer {
        var description = AudioStreamBasicDescription(mSampleRate: Double(sampleRate), mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked, mBytesPerPacket: 4,
            mFramesPerPacket: 1, mBytesPerFrame: 4, mChannelsPerFrame: 2, mBitsPerChannel: 16, mReserved: 0)
        var format: CMAudioFormatDescription?
        guard CMAudioFormatDescriptionCreate(allocator: kCFAllocatorDefault, asbd: &description,
            layoutSize: 0, layout: nil, magicCookieSize: 0, magicCookie: nil, extensions: nil,
            formatDescriptionOut: &format) == noErr else { throw MediaVideoEditError.exportFailed }
        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault, memoryBlock: nil,
            blockLength: bytes.count, blockAllocator: kCFAllocatorDefault, customBlockSource: nil,
            offsetToData: 0, dataLength: bytes.count, flags: 0, blockBufferOut: &block) == kCMBlockBufferNoErr,
              let block else { throw MediaVideoEditError.exportFailed }
        let status = bytes.withUnsafeBytes {
            CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block, offsetIntoDestination: 0, dataLength: $0.count)
        }
        guard status == kCMBlockBufferNoErr else { throw MediaVideoEditError.exportFailed }
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: Int32(sampleRate)),
            presentationTimeStamp: CMTime(value: Int64(position), timescale: Int32(sampleRate)), decodeTimeStamp: .invalid)
        var size = 4
        var sample: CMSampleBuffer?
        guard CMSampleBufferCreateReady(allocator: kCFAllocatorDefault, dataBuffer: block, formatDescription: format,
            sampleCount: count, sampleTimingEntryCount: 1, sampleTimingArray: &timing,
            sampleSizeEntryCount: 1, sampleSizeArray: &size, sampleBufferOut: &sample) == noErr,
              let sample else { throw MediaVideoEditError.exportFailed }
        return sample
    }

    private func export(_ asset: AVAsset, metadata: [AVMetadataItem], to file: URL) async throws -> URL {
        guard let exporter = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetPassthrough) else {
            throw MediaVideoEditError.exportUnavailable
        }
        exporter.metadata = metadata
        try await exporter.export(to: file, as: .mov)
        try Task.checkCancellation()
        return file
    }

    private func ordinaryMetadata(_ asset: AVAsset) async throws -> [AVMetadataItem] {
        try await asset.load(.metadata).filter { $0.identifier != .quickTimeMetadataContentIdentifier }
    }

    private func imageGenerator(_ asset: AVAsset, maxPixelSize: Int?) -> AVAssetImageGenerator {
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        if let maxPixelSize { generator.maximumSize = CGSize(width: CGFloat(maxPixelSize), height: CGFloat(maxPixelSize)) }
        return generator
    }

    private func frame(_ generator: AVAssetImageGenerator, at time: CMTime) async throws -> (CGImage, CMTime) {
        try Task.checkCancellation()
        return try await withTaskCancellationHandler {
            try await generator.image(at: time)
        } onCancel: { generator.cancelAllCGImageGeneration() }
    }

    private func pixelBuffer(width: Int, height: Int, format: OSType) throws -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        guard CVPixelBufferCreate(kCFAllocatorDefault, width, height, format,
            [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &buffer) == kCVReturnSuccess, let buffer else {
            throw MediaVideoEditError.exportFailed
        }
        return buffer
    }

    private func wait(_ input: AVAssetWriterInput, writer: AVAssetWriter) async throws {
        let deadline = ContinuousClock.now + .seconds(30)
        while !input.isReadyForMoreMediaData {
            try Task.checkCancellation()
            guard writer.status == .writing, ContinuousClock.now < deadline else { throw writer.error ?? MediaVideoEditError.exportFailed }
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    private func workDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("media-live-edit-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
