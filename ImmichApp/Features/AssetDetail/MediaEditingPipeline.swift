import AVFoundation
import CryptoKit
import CoreImage
import Observation
import Photos
import UIKit

struct MediaEditDocument: Codable, Equatable, Sendable {
    enum Kind: String, Codable, Sendable { case photo, video, livePhoto }
    var kind: Kind = .photo
    var photo = PhotoEditRecipe()
    var video = VideoEditRecipe()
    var live = LivePhotoEditRecipe()
    var motionAssetID: String?
    var deviceAssetID: String?
    var sourceAspectRatio: Double?

    var isIdentity: Bool { photo.isIdentity && video.isIdentity && live.isIdentity }
}

@MainActor
@Observable
final class MediaEditingPipeline {
    static let shared = MediaEditingPipeline()
    static let recordType = "media-edits"
    static let schemaVersion = 1

    struct SavedEdit {
        let assetID: String
        let record: MediaEditRecord
        let document: MediaEditDocument
        let signature: String
        let aliases: [String]
    }

    private let store: MediaEditStore
    @ObservationIgnored private var cacheRevision: MediaEditStore.Revision?
    @ObservationIgnored private var mappingRevision: UUID?
    @ObservationIgnored private var cached: [String: Result<SavedEdit?, Error>] = [:]

    init(store: MediaEditStore? = nil) { self.store = store ?? .shared }

    func savedEdit(for id: String, session: SessionManager) throws -> SavedEdit? {
        guard session.isLoggedIn, session.backupQueueOwner != nil else { return nil }
        store.configure(session: session)
        let revision = store.revision
        let mappings = SwiftDataManager.shared.backupMappingRevision
        if cacheRevision != revision || mappingRevision != mappings {
            cached.removeAll()
            cacheRevision = revision
            mappingRevision = mappings
        }
        if let result = cached[id] { return try result.get() }
        let result: Result<SavedEdit?, Error>
        do {
            var found: SavedEdit?
            for candidate in candidates(for: id) {
                guard let record = try store.read(assetID: candidate) else { continue }
                guard record.type == Self.recordType else { throw MediaEditStoreError.unsupportedRecord }
                let document = try record.decode(MediaEditDocument.self, supportedSchemaVersion: Self.schemaVersion)
                let encoder = JSONEncoder()
                encoder.outputFormatting = .sortedKeys
                found = SavedEdit(assetID: candidate, record: record, document: document,
                    signature: Self.digest(try encoder.encode(record)), aliases: candidates(for: id))
                break
            }
            result = .success(found)
        } catch MediaEditStoreError.accountUnavailable { result = .success(nil) }
        catch { result = .failure(error) }
        cached[id] = result
        return try result.get()
    }

    func effectiveEdited(_ id: String, fallback: Bool?, session: SessionManager) -> Bool? {
        guard let saved = try? savedEdit(for: id, session: session) else { return fallback }
        if let deviceID = saved.document.deviceAssetID {
            return !saved.document.isIdentity || LocalPhotoLibrary.shared.hasAdjustments(deviceID)
        }
        return !saved.document.isIdentity
    }

    func displayAsset(_ asset: AssetLite, session: SessionManager) -> AssetLite {
        guard let edit = try? savedEdit(for: asset.id, session: session) else { return asset }
        return Self.displayAsset(asset, document: edit.document)
    }

    static func displayAsset(_ asset: AssetLite, document: MediaEditDocument) -> AssetLite {
        let photo = document.photo.normalized()
        var ratio = document.sourceAspectRatio ?? asset.ratio
        if !ratio.isFinite || ratio <= 0 { ratio = 1 }
        ratio *= photo.crop.width / photo.crop.height
        if photo.quarterTurns % 2 != 0 { ratio = 1 / ratio }
        ratio *= photo.framing.width / photo.framing.height
        var displayed = AssetLite(id: asset.id, isVideo: asset.isVideo, ratio: ratio,
            thumbhash: asset.thumbhash, createdAt: asset.createdAt, isFavorite: asset.isFavorite,
            duration: asset.duration, livePhotoVideoID: asset.livePhotoVideoID, origin: asset.origin,
            trashVisibility: asset.trashVisibility)
        if asset.isVideo, let duration = asset.duration,
           let selection = try? document.video.selection(duration: duration) {
            displayed.duration = selection.duration.seconds / document.video.rate
        }
        return displayed
    }

    static func sourceAspectRatio(_ url: URL, isVideo: Bool) async throws -> Double {
        if isVideo {
            guard let track = try await AVURLAsset(url: url).loadTracks(withMediaType: .video).first else {
                throw MediaVideoEditError.unavailableVideo
            }
            let size = try await track.load(.naturalSize)
            let transform = try await track.load(.preferredTransform)
            let extent = CGRect(origin: .zero, size: size).applying(transform)
            guard extent.width != 0, extent.height != 0 else { throw MediaVideoEditError.unavailableVideo }
            return abs(extent.width / extent.height)
        }
        guard let image = CIImage(contentsOf: url, options: [.applyOrientationProperty: true]),
              image.extent.width > 0, image.extent.height > 0 else { throw PhotoEditRenderError.unavailable }
        return image.extent.width / image.extent.height
    }

    static func validateOriginal(_ url: URL, checksum: String?) async throws {
        guard let checksum, let expected = Data(base64Encoded: checksum), expected.count == 20 else { return }
        let actual = try await Task.detached(priority: .userInitiated) {
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            var hash = Insecure.SHA1()
            while let bytes = try handle.read(upToCount: 1_048_576), !bytes.isEmpty {
                try Task.checkCancellation()
                hash.update(data: bytes)
            }
            return Data(hash.finalize())
        }.value
        try Task.checkCancellation()
        guard actual == expected else { throw MediaEditStoreError.sourceChanged }
    }

    func cacheKey(_ base: String, assetID: String, session: SessionManager) -> String {
        do {
            guard let saved = try savedEdit(for: assetID, session: session) else { return base }
            return base + "-edit-" + saved.signature
        } catch {
            return base + "-edit-unavailable-" + Self.digest(Data(String(describing: store.revision).utf8))
        }
    }

    func imageData(_ endpoint: Endpoint, api: APIClient) async throws -> Data {
        let components = endpoint.path.split(separator: "/")
        guard components.count == 3, components[0] == "assets", components[2] == "thumbnail",
              endpoint.query.first(where: { $0.name == "edited" })?.value != "false",
              let saved = try savedEdit(for: String(components[1]), session: api.session) else {
            return try await api.rawData(endpoint)
        }
        let id = String(components[1]), context = api.session.snapshot
        try api.checkCurrent(context)
        let image: UIImage
        if let deviceID = saved.document.deviceAssetID {
            try await validateDeviceSource(saved, deviceID: deviceID)
            guard let source = await LocalPhotoLibrary.shared.preview(for: deviceID,
                size: CGSize(width: 2048, height: 2048)) else { throw PhotoExportError.unsupportedMedia }
            image = try await devicePreview(source, id: id, session: api.session, maxPixelSize: 2048)
        } else if saved.document.kind == .video && saved.document.video.trimStart > 0 {
            let source = try remoteOriginal(id, context: context)
            image = try await videoFrame(source, time: saved.document.video.trimStart, photo: saved.document.photo)
        } else if saved.document.kind == .livePhoto,
                  saved.document.live.keyPhotoTime != nil || saved.document.live.mode == .longExposure
                    || saved.document.video.trimStart > 0 || saved.document.video.trimEnd != nil {
            image = try await livePoster(saved, api: api)
        } else {
            var original = endpoint
            original.query.removeAll { ["edited", "cropped", "size"].contains($0.name) }
            original.query += [.init(name: "edited", value: "false"), .init(name: "cropped", value: "false"),
                .init(name: "size", value: "preview")]
            let data = try await api.rawData(original)
            guard let source = UIImage(data: data) else { throw PhotoExportError.unsupportedMedia }
            image = try await PhotoEditRenderer.shared.renderPreview(source, recipe: saved.document.photo)
        }
        try await validate(saved, id: id, api: api, context: context)
        let data = try await Task.detached(priority: .userInitiated) {
            guard let data = image.pngData() else { throw PhotoExportError.conversionFailed }
            return data
        }.value
        try await validate(saved, id: id, api: api, context: context)
        return data
    }

    func devicePreview(_ image: UIImage, id: String, session: SessionManager, maxPixelSize: Int) async throws -> UIImage {
        guard let saved = try savedEdit(for: id, session: session) else { return image }
        let context = session.snapshot, api = session.imageAPI
        let rendered: UIImage
        if let deviceID = saved.document.deviceAssetID {
            try await validateDeviceSource(saved, deviceID: deviceID)
            if saved.document.kind == .video && saved.document.video.trimStart > 0 {
                guard let asset = await LocalPhotoLibrary.shared.videoAsset(for: deviceID) else {
                    throw MediaVideoEditError.unavailableVideo
                }
                rendered = try await videoFrame(asset, time: saved.document.video.trimStart, photo: saved.document.photo)
            } else if saved.document.kind == .livePhoto,
                      saved.document.live.keyPhotoTime != nil || saved.document.live.mode == .longExposure
                    || saved.document.video.trimStart > 0 || saved.document.video.trimEnd != nil {
                rendered = try await livePoster(saved, api: api)
            } else {
                rendered = try await PhotoEditRenderer.shared.renderPreview(image, recipe: saved.document.photo,
                    maxPixelSize: maxPixelSize)
            }
        } else {
            let data = try await imageData(.init(path: "/assets/\(saved.assetID)/thumbnail"), api: api)
            guard let result = UIImage(data: data) else { throw PhotoExportError.unsupportedMedia }
            rendered = result
        }
        try await validate(saved, id: id, api: api, context: context)
        return rendered
    }

    func playbackItem(asset: AVAsset, assetID: String, session: SessionManager) async throws -> AVPlayerItem {
        guard let saved = try savedEdit(for: assetID, session: session) else { return AVPlayerItem(asset: asset) }
        let context = session.snapshot, api = session.imageAPI
        let composition = try await MediaVideoRenderer.composition(source: asset, recipe: saved.document.video)
        let item = AVPlayerItem(asset: composition)
        item.audioTimePitchAlgorithm = .spectral
        item.videoComposition = try await MediaVideoRenderer.videoComposition(asset: composition, photo: saved.document.photo)
        try await validate(saved, id: assetID, api: api, context: context)
        return item
    }

    func currentFile(_ source: URL, assetID: String, api: APIClient, saved: SavedEdit? = nil) async throws -> URL {
        guard let saved = try saved ?? savedEdit(for: assetID, session: api.session) else { return source }
        let context = api.session.snapshot
        if saved.document.isIdentity {
            try await validate(saved, id: assetID, api: api, context: context)
            return source
        }
        var owned: [URL] = []
        do {
            let output: URL
            if saved.document.kind == .video {
                output = try await MediaVideoRenderer.shared.renderVideo(sourceURL: source,
                    video: saved.document.video, photo: saved.document.photo)
            } else if saved.document.kind == .livePhoto {
                let motion = try await motionFile(saved, api: api)
                owned.append(motion)
                if [.live, .off, .longExposure].contains(saved.document.live.mode) {
                    output = try await MediaLiveRenderer.shared.renderPoster(motionURL: motion, stillURL: source,
                        video: saved.document.video, live: saved.document.live, photo: saved.document.photo)
                } else {
                    let result = try await MediaLiveRenderer.shared.render(motionURL: motion, stillURL: source,
                        video: saved.document.video, live: saved.document.live, photo: saved.document.photo)
                    output = result.primaryURL
                }
            } else {
                output = try await PhotoEditRenderer.shared.renderFile(source, recipe: saved.document.photo)
            }
            owned.append(output)
            try await validate(saved, id: assetID, api: api, context: context)
            owned.removeAll { $0 == output }
            TemporaryMediaStore.remove(owned)
            return output
        } catch { TemporaryMediaStore.remove(owned); throw error }
    }

    func exportDeviceFile(for id: String, session: SessionManager) async throws -> (url: URL, filename: String)? {
        let saved = try savedEdit(for: id, session: session)
        let deviceID = saved?.document.deviceAssetID ?? id
        guard LocalPhotoLibrary.isLocal(deviceID) else { return nil }
        let context = session.snapshot, api = session.imageAPI
        if let saved { try await validateDeviceSource(saved, deviceID: deviceID) }
        guard let source = await LocalPhotoLibrary.shared.exportFile(for: deviceID) else { return nil }
        defer { try? FileManager.default.removeItem(at: source.url) }
        let managed = try TemporaryMediaStore.adoptShareFile(at: source.url, suggestedFilename: source.filename)
        var rendered: URL?
        do {
            let output = try await currentFile(managed, assetID: id, api: api, saved: saved)
            rendered = output
            if output != managed { TemporaryMediaStore.remove(managed) }
            try api.checkCurrent(context)
            return (output, output.lastPathComponent)
        } catch {
            TemporaryMediaStore.remove([managed] + [rendered].compactMap { $0 })
            throw error
        }
    }

    func editedLivePhoto(assetID: String, session: SessionManager, targetSize: CGSize,
                         isAllowed: @escaping @MainActor () -> Bool) async -> EditedLivePhotoResult {
        var owned: [URL] = []
        do {
            guard let saved = try savedEdit(for: assetID, session: session),
                  saved.document.kind == .livePhoto else { return .original }
            if saved.document.live.mode == .off || saved.document.live.mode == .longExposure { return .off }
            guard isAllowed() else { throw CancellationError() }
            let context = session.snapshot, api = session.imageAPI
            let still: URL
            if let deviceID = saved.document.deviceAssetID {
                try await validateDeviceSource(saved, deviceID: deviceID)
                guard let source = await LocalPhotoLibrary.shared.exportFile(for: deviceID) else {
                    throw PhotoEditRenderError.unavailable
                }
                defer { try? FileManager.default.removeItem(at: source.url) }
                still = try TemporaryMediaStore.adoptShareFile(at: source.url, suggestedFilename: source.filename)
            } else {
                still = try await AssetDetailRepository(api: api).downloadOriginalFile(saved.assetID, filename: saved.assetID)
            }
            owned.append(still)
            let motion = try await motionFile(saved, api: api)
            owned.append(motion)
            guard isAllowed() else { throw CancellationError() }
            let rendered = try await MediaLiveRenderer.shared.render(motionURL: motion, stillURL: still,
                video: saved.document.video, live: saved.document.live, photo: saved.document.photo)
            owned += rendered.ownedURLs
            try await validate(saved, id: assetID, api: api, context: context)
            guard isAllowed() else { throw CancellationError() }
            if rendered.isVideo {
                let item = AVPlayerItem(url: rendered.primaryURL)
                TemporaryMediaStore.remove(owned.filter { !rendered.ownedURLs.contains($0) })
                return .movie(item, isMuted: saved.document.video.isMuted, loops: true, ownedURLs: rendered.ownedURLs)
            }
            guard let motion = rendered.motionURL else { throw MediaVideoEditError.unavailableVideo }
            let photo: PHLivePhoto? = await PhotoMediaRequest.load(request: { completion in
                PHLivePhoto.request(withResourceFileURLs: [rendered.primaryURL, motion], placeholderImage: nil,
                    targetSize: targetSize, contentMode: .aspectFit) { photo, info in
                    guard info[PHLivePhotoInfoIsDegradedKey] as? Bool != true else { return }
                    completion(photo)
                }
            }, cancel: { PHLivePhoto.cancelRequest(withRequestID: $0) })
            try await validate(saved, id: assetID, api: api, context: context)
            guard isAllowed(), let photo else { throw MediaVideoEditError.unavailableVideo }
            TemporaryMediaStore.remove(owned.filter { !rendered.ownedURLs.contains($0) })
            return .native(photo, isMuted: saved.document.video.isMuted, ownedURLs: rendered.ownedURLs)
        } catch {
            TemporaryMediaStore.remove(owned)
            return .unavailable
        }
    }

    func livePoster(_ saved: SavedEdit, api: APIClient) async throws -> UIImage {
        let context = api.session.snapshot
        let motion = try await motionFile(saved, api: api)
        defer { TemporaryMediaStore.remove(motion) }
        let still: URL
        if let deviceID = saved.document.deviceAssetID {
            guard let source = await LocalPhotoLibrary.shared.exportFile(for: deviceID) else {
                throw PhotoEditRenderError.unavailable
            }
            defer { try? FileManager.default.removeItem(at: source.url) }
            still = try TemporaryMediaStore.adoptShareFile(at: source.url, suggestedFilename: source.filename)
        } else {
            still = try await AssetDetailRepository(api: api).downloadOriginalFile(saved.assetID, filename: saved.assetID)
        }
        defer { TemporaryMediaStore.remove(still) }
        let output = try await MediaLiveRenderer.shared.renderPoster(motionURL: motion, stillURL: still,
            video: saved.document.video, live: saved.document.live, photo: saved.document.photo, maxPixelSize: 2048)
        defer { TemporaryMediaStore.remove(output) }
        try await validate(saved, id: saved.assetID, api: api, context: context)
        guard let image = UIImage(contentsOfFile: output.path) else { throw PhotoExportError.conversionFailed }
        return image
    }

    func motionFile(_ saved: SavedEdit, api: APIClient) async throws -> URL {
        if let deviceID = saved.document.deviceAssetID {
            try await validateDeviceSource(saved, deviceID: deviceID)
            guard let file = await LocalPhotoLibrary.shared.livePhotoMotionFile(for: deviceID) else {
                throw MediaVideoEditError.unavailableVideo
            }
            defer { try? FileManager.default.removeItem(at: file.url) }
            return try TemporaryMediaStore.adoptShareFile(at: file.url, suggestedFilename: file.filename)
        }
        guard let motionID = saved.document.motionAssetID else { throw MediaVideoEditError.unavailableVideo }
        return try await AssetDetailRepository(api: api).downloadOriginalFile(motionID, filename: motionID)
    }

    func videoFrame(_ asset: AVAsset, time: Double, photo: PhotoEditRecipe) async throws -> UIImage {
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 2048, height: 2048)
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        let (image, _) = try await generator.image(at: CMTime(seconds: max(0, time), preferredTimescale: 60_000))
        try Task.checkCancellation()
        return try await PhotoEditRenderer.shared.renderPreview(UIImage(cgImage: image), recipe: photo)
    }

    func remoteOriginal(_ id: String, context: SessionRequestContext) throws -> AVURLAsset {
        guard let base = context.baseURL else { throw APIError.invalidURL }
        var url = URLComponents(url: base.appendingPathComponent("/assets/\(id)/original"), resolvingAgainstBaseURL: false)
        url?.queryItems = [.init(name: "edited", value: "false")]
        guard let resolved = url?.url else { throw APIError.invalidURL }
        return AVURLAsset(url: resolved, options: ["AVURLAssetHTTPHeaderFieldsKey": context.authHeaders])
    }

    static func fingerprint(_ asset: AssetResponseDTO) -> String {
        if let checksum = asset.checksum, !checksum.isEmpty { return "original:" + checksum }
        return "asset:" + digest(Data([asset.id, asset.originalFileName,
            asset.fileModifiedAt.map { String($0.timeIntervalSince1970) } ?? ""].joined(separator: "|").utf8))
    }

    static func deviceFingerprint(_ metadata: LocalPhoto) -> String {
        "device:" + metadata.id + ":" + String(metadata.modifiedAt.timeIntervalSince1970)
    }

    private func validateDeviceSource(_ saved: SavedEdit, deviceID: String) async throws {
        guard let metadata = await LocalPhotoLibrary.shared.photoMetadata(for: deviceID),
              Self.deviceFingerprint(metadata) == saved.record.sourceFingerprint else { throw MediaEditStoreError.sourceChanged }
    }

    private func validate(_ saved: SavedEdit, id: String, api: APIClient, context: SessionRequestContext) async throws {
        try Task.checkCancellation()
        try api.checkCurrent(context)
        guard candidates(for: id) == saved.aliases else { throw MediaEditStoreError.sourceChanged }
        guard let current = try savedEdit(for: id, session: api.session), current.assetID == saved.assetID,
              current.record == saved.record else { throw MediaEditStoreError.editChanged }
        if let deviceID = saved.document.deviceAssetID {
            try await validateDeviceSource(saved, deviceID: deviceID)
            try api.checkCurrent(context)
            guard candidates(for: id) == saved.aliases else { throw MediaEditStoreError.sourceChanged }
            guard try savedEdit(for: id, session: api.session)?.record == saved.record else {
                throw MediaEditStoreError.editChanged
            }
        }
        if let metadata = LocalSnapshot.load(AssetResponseDTO.self, for: LocalSnapshot.Key.assetDetail(saved.assetID)),
           saved.document.deviceAssetID == nil,
           Self.fingerprint(metadata) != saved.record.sourceFingerprint { throw MediaEditStoreError.sourceChanged }
    }

    private func candidates(for id: String) -> [String] {
        if LocalPhotoLibrary.isLocal(id) {
            let localID = LocalPhotoLibrary.localIdentifier(from: id)
            if let serverID = SwiftDataManager.shared.getBackupRecord(localIdentifier: localID)?.assetId,
               !serverID.isEmpty, serverID != id { return [serverID, id] }
        } else if let localID = SwiftDataManager.shared.localIdentifier(forServerAsset: id) {
            return [id, LocalPhotoLibrary.assetID(for: localID)]
        }
        return [id]
    }

    private static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
