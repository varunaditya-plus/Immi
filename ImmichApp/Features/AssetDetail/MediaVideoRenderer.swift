import AVFoundation
import CoreImage
import Foundation

actor MediaVideoRenderer {
    static let shared = MediaVideoRenderer()

    func renderVideo(sourceURL: URL, video: VideoEditRecipe, photo: PhotoEditRecipe = .init()) async throws -> URL {
        let source = AVURLAsset(url: sourceURL)
        let composition = try await Self.composition(source: source, recipe: video)
        guard let exporter = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetHighestQuality) else {
            throw MediaVideoEditError.exportUnavailable
        }
        exporter.videoComposition = try await Self.videoComposition(asset: composition, photo: photo)
        exporter.metadata = try await source.load(.metadata)
        let types = await exporter.compatibleFileTypes
        let type: AVFileType = types.contains(.mov) ? .mov : .mp4
        guard types.contains(type) else { throw MediaVideoEditError.exportUnavailable }
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("video-edit-\(UUID())")
            .appendingPathExtension(type == .mov ? "mov" : "mp4")
        defer { try? FileManager.default.removeItem(at: file) }
        try Task.checkCancellation()
        let cancellation = MediaVideoExportCancellation(exporter)
        try await withTaskCancellationHandler {
            try await exporter.export(to: file, as: type)
        } onCancel: { cancellation.cancel() }
        try Task.checkCancellation()
        return try TemporaryMediaStore.adoptShareFile(at: file,
            suggestedFilename: sourceURL.deletingPathExtension().lastPathComponent + "." + file.pathExtension)
    }

    @MainActor func previewItem(sourceURL: URL, video: VideoEditRecipe, photo: PhotoEditRecipe = .init()) async throws -> AVPlayerItem {
        try await previewItem(asset: AVURLAsset(url: sourceURL), video: video, photo: photo)
    }

    @MainActor func previewItem(asset: AVAsset, video: VideoEditRecipe, photo: PhotoEditRecipe = .init()) async throws -> AVPlayerItem {
        let composition = try await Self.composition(source: asset, recipe: video)
        let item = AVPlayerItem(asset: composition)
        item.audioTimePitchAlgorithm = .spectral
        item.videoComposition = try await Self.videoComposition(asset: composition, photo: photo)
        return item
    }

    nonisolated static func composition(source: AVAsset, recipe: VideoEditRecipe) async throws -> AVMutableComposition {
        let duration = try await source.load(.duration).seconds
        let range = try recipe.selection(duration: duration)
        let videos = try await source.loadTracks(withMediaType: .video)
        guard let sourceVideo = videos.first else { throw MediaVideoEditError.unavailableVideo }
        let result = AVMutableComposition()
        guard let destination = result.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw MediaVideoEditError.exportUnavailable
        }
        try destination.insertTimeRange(range, of: sourceVideo, at: .zero)
        destination.preferredTransform = try await sourceVideo.load(.preferredTransform)
        if !recipe.isMuted {
            for audio in try await source.loadTracks(withMediaType: .audio) {
                guard let output = result.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else {
                    throw MediaVideoEditError.exportUnavailable
                }
                let available = CMTimeRangeGetIntersection(range, otherRange: try await audio.load(.timeRange))
                if available.duration.seconds > 0 {
                    try output.insertTimeRange(available, of: audio, at: CMTimeSubtract(available.start, range.start))
                }
            }
        }
        if recipe.rate != 1 {
            result.scaleTimeRange(CMTimeRange(start: .zero, duration: range.duration),
                toDuration: CMTimeMultiplyByFloat64(range.duration, multiplier: 1 / recipe.rate))
        }
        try Task.checkCancellation()
        return result
    }

    nonisolated static func videoComposition(asset: AVAsset, photo: PhotoEditRecipe) async throws -> AVVideoComposition? {
        guard !photo.isIdentity else { return nil }
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw MediaVideoEditError.unavailableVideo
        }
        let natural = try await track.load(.naturalSize)
        let transform = try await track.load(.preferredTransform)
        let oriented = CGRect(origin: .zero, size: natural).applying(transform)
        let canvas = CIImage(color: .black).cropped(to: CGRect(x: 0, y: 0,
            width: abs(oriented.width), height: abs(oriented.height)))
        let extent = try PhotoEditRenderer.render(canvas, recipe: photo).extent
        guard extent.width.isFinite, extent.height.isFinite, extent.width > 0, extent.height > 0 else {
            throw MediaVideoEditError.invalidSelection
        }
        // Upscale tiny crops uniformly so the encoded movie remains decodable.
        let minimumScale = max(1, 16 / min(extent.width, extent.height))
        let size = CGSize(width: ceil(extent.width * minimumScale / 2) * 2,
            height: ceil(extent.height * minimumScale / 2) * 2)
        let composition: AVMutableVideoComposition = try await withCheckedThrowingContinuation { continuation in
            AVMutableVideoComposition.videoComposition(with: asset, applyingCIFiltersWithHandler: { request in
                do {
                    let image = try PhotoEditRenderer.render(request.sourceImage, recipe: photo)
                    let normalized = image.transformed(by: CGAffineTransform(translationX: -image.extent.minX, y: -image.extent.minY))
                    let scale = CGAffineTransform(scaleX: size.width / normalized.extent.width, y: size.height / normalized.extent.height)
                    request.finish(with: normalized.transformed(by: scale), context: nil)
                } catch { request.finish(with: error) }
            }, completionHandler: { composition, error in
                if let composition { continuation.resume(returning: composition) }
                else { continuation.resume(throwing: error ?? MediaVideoEditError.exportUnavailable) }
            })
        }
        composition.renderSize = size
        return composition
    }
}

// AVFoundation permits cancellation from another executor while export is suspended.
private final class MediaVideoExportCancellation: @unchecked Sendable {
    private let exporter: AVAssetExportSession
    init(_ exporter: AVAssetExportSession) { self.exporter = exporter }
    func cancel() { exporter.cancelExport() }
}
