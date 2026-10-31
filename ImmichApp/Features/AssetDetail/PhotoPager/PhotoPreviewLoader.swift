import AVFoundation
import Photos
import UIKit

/// Satu pintu untuk gambar layar detail.
///
/// Kembarannya `PhotoThumbnailLoader` untuk grid; dipisah karena ukuran decode,
/// endpoint, dan urutan cadangannya berbeda — dan menyatukannya hanya melahirkan
/// parameter yang harus dibaca ulang setiap kali.
@MainActor
class PhotoPreviewLoader {
    var visibilityPolicy = AssetVisibilityPolicy()
    /// Sisi terpanjang untuk layar detail.
    ///
    /// 2048px sudah melampaui resolusi layar mana pun, sementara membongkar
    /// bitmap 4000px berarti puluhan megabyte dan puluhan milidetik untuk setiap
    /// usapan halaman.
    static let maxPixelSize = 2048

    private let session: SessionManager
    private let accountGeneration = LocalSnapshot.generation
    private let imageCache: ImageCache
    private let serverIDForLocalAsset: @MainActor (String) -> String?
    private let localPreview: @MainActor (String) async -> UIImage?
    private let localPlayback: @MainActor (String, Bool) async -> AVAsset?

    var requestContext: SessionRequestContext { session.snapshot }

    init(
        session: SessionManager,
        imageCache: ImageCache = .shared,
        serverIDForLocalAsset: @escaping @MainActor (String) -> String? = {
            SwiftDataManager.shared.getBackupRecord(localIdentifier: $0)?.assetId
        },
        localPreview: @escaping @MainActor (String) async -> UIImage? = {
            await LocalPhotoLibrary.shared.preview(for: $0,
                size: CGSize(width: PhotoPreviewLoader.maxPixelSize, height: PhotoPreviewLoader.maxPixelSize))
        },
        localPlayback: @escaping @MainActor (String, Bool) async -> AVAsset? = { id, allowsNetwork in
            await LocalPhotoLibrary.shared.videoAsset(for: id, allowsNetworkAccess: allowsNetwork)
        }
    ) {
        self.session = session
        self.imageCache = imageCache
        self.serverIDForLocalAsset = serverIDForLocalAsset
        self.localPreview = localPreview
        self.localPlayback = localPlayback
    }

    private func cacheKey(for assetId: String) -> String {
        MediaEditingPipeline.shared.cacheKey("\(assetId)-preview", assetID: assetId, session: session)
    }

    private func serverPreviewID(for assetID: String) -> String? {
        guard LocalPhotoLibrary.isLocal(assetID) else { return assetID }
        let localID = LocalPhotoLibrary.localIdentifier(from: assetID)
        guard let serverID = serverIDForLocalAsset(localID), !serverID.isEmpty else { return nil }
        return serverID
    }

    func sourceID(for assetID: String) -> String { serverPreviewID(for: assetID) ?? assetID }

    func displayAsset(_ asset: AssetLite) -> AssetLite {
        MediaEditingPipeline.shared.displayAsset(asset, session: session)
    }

    func isAudioRemovedByEdit(for assetID: String) -> Bool {
        guard accountGeneration == LocalSnapshot.generation,
              let saved = try? MediaEditingPipeline.shared.savedEdit(for: assetID, session: session),
              saved.document.kind == .video else { return false }
        return saved.document.video.isMuted
    }

    /// Gambar terbaik yang SUDAH ada di memori, tanpa `await`.
    ///
    /// Kalau versi tajamnya belum ada, thumbnail seukuran grid dipakai lebih
    /// dulu — layar detail hampir selalu dibuka dari grid, jadi versi kecilnya
    /// pasti sudah ada. Menampilkannya seketika inilah yang membuat aplikasi
    /// resmi terasa tanpa loading.
    func cachedImage(for assetId: String) -> UIImage? {
        guard accountGeneration == LocalSnapshot.generation else { return nil }
        let sourceID = serverPreviewID(for: assetId) ?? assetId
        if let preview = ImageMemoryCache.shared.image(
            for: ImageCache.memoryKey(cacheKey(for: sourceID), Self.maxPixelSize)) {
            return preview
        }
        if let thumbnail = ImageMemoryCache.shared.image(
            for: ImageCache.memoryKey(MediaEditingPipeline.shared.cacheKey("\(sourceID)-thumbnail", assetID: sourceID, session: session), PhotoThumbnailLoader.maxPixelSize)) {
            return thumbnail
        }
        guard sourceID != assetId else { return nil }
        return ImageMemoryCache.shared.image(
            for: ImageCache.memoryKey(MediaEditingPipeline.shared.cacheKey("\(assetId)-thumbnail", assetID: assetId, session: session), PhotoThumbnailLoader.maxPixelSize))
    }

    /// true kalau yang ada di memori sudah versi tajamnya, jadi tidak perlu
    /// mengambil apa pun.
    func hasPreview(for assetId: String) -> Bool {
        guard accountGeneration == LocalSnapshot.generation else { return false }
        let sourceID = serverPreviewID(for: assetId) ?? assetId
        return ImageMemoryCache.shared.image(
            for: ImageCache.memoryKey(cacheKey(for: sourceID), Self.maxPixelSize)) != nil
    }

    func image(for assetId: String) async -> UIImage? {
        guard accountGeneration == LocalSnapshot.generation, !Task.isCancelled else { return nil }
        // Display ID lokal tetap stabil setelah upload, tetapi edit server
        // berada pada preview server. Foto yang belum tertaut tetap lokal.
        guard let sourceID = serverPreviewID(for: assetId) else {
            guard let image = await localPreview(assetId), accountGeneration == LocalSnapshot.generation, !Task.isCancelled else { return nil }
            return try? await MediaEditingPipeline.shared.devicePreview(image, id: assetId, session: session, maxPixelSize: Self.maxPixelSize)
        }

        let api = session.imageAPI
        let endpoint = Endpoint(
            path: "/assets/\(sourceID)/thumbnail",
            query: [
                .init(name: "size", value: "preview"),
                // Kalau aset punya crop/rotate/mirror, tampilkan hasilnya.
                // Untuk aset tanpa edit server mengembalikan preview biasa.
                .init(name: "edited", value: "true"),
            ])

        do {
            let image = try await imageCache.image(
                key: cacheKey(for: sourceID),
                maxPixelSize: Self.maxPixelSize,
                fetch: { try await MediaEditingPipeline.shared.imageData(endpoint, api: api) })
            guard accountGeneration == LocalSnapshot.generation else { return nil }
            UnreadableAssets.shared.noteSuccess()
            return image
        } catch {
            guard accountGeneration == LocalSnapshot.generation, !Task.isCancelled else { return nil }
            if LocalPhotoLibrary.isLocal(assetId) {
                guard let image = await localPreview(assetId), accountGeneration == LocalSnapshot.generation, !Task.isCancelled else { return nil }
                return try? await MediaEditingPipeline.shared.devicePreview(image, id: assetId, session: session, maxPixelSize: Self.maxPixelSize)
            }
            // Aset yang ditolak server dibuang dari linimasa — lihat
            // `UnreadableAssets`.
            UnreadableAssets.shared.report(assetId, error: error)
            return nil
        }
    }

    /// Sumber editor harus selalu original. Memakai preview `edited=true`
    /// kemudian mengirim koordinatnya terhadap original membuat crop kedua
    /// meleset setelah foto pernah diedit sekali.
    func originalImageForEditing(_ assetId: String) async -> UIImage? {
        guard accountGeneration == LocalSnapshot.generation, !Task.isCancelled else { return nil }
        if LocalPhotoLibrary.isLocal(assetId) {
            let image = await LocalPhotoLibrary.shared.preview(
                for: assetId,
                size: CGSize(width: Self.maxPixelSize, height: Self.maxPixelSize))
            return accountGeneration == LocalSnapshot.generation && !Task.isCancelled ? image : nil
        }

        let api = session.imageAPI
        do {
            let image = try await ImageCache.shared.image(
                key: "\(assetId)-preview-original",
                maxPixelSize: Self.maxPixelSize,
                fetch: {
                    try await api.rawData(.init(
                        path: "/assets/\(assetId)/thumbnail",
                        query: [
                            .init(name: "size", value: "preview"),
                            .init(name: "edited", value: "false"),
                        ]))
                })
            return accountGeneration == LocalSnapshot.generation && !Task.isCancelled ? image : nil
        } catch {
            return nil
        }
    }

    /// URL streaming video beserta header autentikasinya.
    ///
    /// `AVPlayer` mengambil bytenya sendiri, di luar `APIClient` — jadi
    /// headernya harus ikut dititipkan ke `AVURLAsset`, bukan dipasang di
    /// `URLRequest` seperti permintaan lain.
    func videoSource(for assetId: String) -> (url: URL, headers: [String: String])? {
        guard accountGeneration == LocalSnapshot.generation else { return nil }
        let context = session.snapshot
        let baseURL = context.baseURL
        let headers = context.authHeaders
        guard let baseURL else { return nil }
        return (baseURL.appendingPathComponent("/assets/\(assetId)/video/playback"), headers)
    }

    /// Sumber playback tercepat yang tersedia.
    ///
    /// Aset server yang berasal dari perangkat ini tetap punya pasangan
    /// `PHAsset.localIdentifier`. Memutar pasangan lokal lebih dahulu menghindari
    /// round-trip dan transcoding server. Bila berkas lokal sudah dihapus atau
    /// hanya ada di iCloud, endpoint playback server menjadi fallback.
    func playbackAsset(for assetId: String) async -> AVAsset? {
        guard accountGeneration == LocalSnapshot.generation, !Task.isCancelled else { return nil }
        let context = requestContext, sourceID = self.sourceID(for: assetId)
        let saved: MediaEditingPipeline.SavedEdit?
        do { saved = try MediaEditingPipeline.shared.savedEdit(for: assetId, session: session) }
        catch { return nil }
        func isCurrent() -> Bool {
            guard !Task.isCancelled, accountGeneration == LocalSnapshot.generation, context == requestContext,
                  sourceID == self.sourceID(for: assetId) else { return false }
            do { return try MediaEditingPipeline.shared.savedEdit(for: assetId, session: session)?.record == saved?.record }
            catch { return false }
        }
        guard isCurrent() else { return nil }
        let localAssetID: String?
        if let saved {
            if let deviceID = saved.document.deviceAssetID { localAssetID = deviceID }
            else {
                guard !LocalPhotoLibrary.isLocal(saved.assetID) else { return nil }
                return try? MediaEditingPipeline.shared.remoteOriginal(saved.assetID, context: context)
            }
        } else if LocalPhotoLibrary.isLocal(assetId) {
            localAssetID = assetId
        } else if let identifier = SwiftDataManager.shared.localIdentifier(
            forServerAsset: assetId) {
            localAssetID = LocalPhotoLibrary.assetID(for: identifier)
        } else {
            localAssetID = nil
        }

        if let localAssetID, let localAsset = await localPlayback(localAssetID, false) {
            guard isCurrent() else {
                localAsset.cancelLoading()
                return nil
            }
            return localAsset
        }

        guard isCurrent() else { return nil }
        if saved == nil, !LocalPhotoLibrary.isLocal(sourceID), let source = videoSource(for: sourceID) {
            return AVURLAsset(url: source.url, options: ["AVURLAssetHTTPHeaderFieldsKey": source.headers])
        }
        // Only this explicitly selected, device-only video may fetch its iCloud original.
        guard let localAssetID else { return nil }
        let cloud = await localPlayback(localAssetID, true)
        guard isCurrent() else { cloud?.cancelLoading(); return nil }
        return cloud
    }

    func playbackItem(for assetID: String) async -> AVPlayerItem? {
        let context = requestContext, sourceID = self.sourceID(for: assetID)
        let recipeKey = cacheKey(for: assetID)
        guard let asset = await playbackAsset(for: assetID) else { return nil }
        guard !Task.isCancelled, context == requestContext, sourceID == self.sourceID(for: assetID), recipeKey == cacheKey(for: assetID) else {
            asset.cancelLoading()
            return nil
        }
        do {
            let item = try await MediaEditingPipeline.shared.playbackItem(asset: asset, assetID: assetID, session: session)
            guard !Task.isCancelled, context == requestContext, sourceID == self.sourceID(for: assetID), recipeKey == cacheKey(for: assetID) else {
                item.asset.cancelLoading()
                return nil
            }
            return item
        } catch { return nil }
    }

    /// Identifier PhotoKit untuk aset perangkat maupun aset server yang masih
    /// mempunyai salinan tertaut di perangkat ini.
    private func localAssetID(for assetId: String) -> String? {
        if LocalPhotoLibrary.isLocal(assetId) { return assetId }
        guard let identifier = SwiftDataManager.shared.localIdentifier(
            forServerAsset: assetId)
        else { return nil }
        return LocalPhotoLibrary.assetID(for: identifier)
    }

    /// Deteksi native untuk Live Photo lokal. Jalur ini melengkapi
    /// `livePhotoVideoId` server, bukan menggantikannya: foto yang baru diambil
    /// atau cache server lama tetap dikenali dari metadata PhotoKit.
    func localLivePhotoAssetID(for assetId: String) -> String? {
        guard accountGeneration == LocalSnapshot.generation else { return nil }
        guard let localID = localAssetID(for: assetId) else { return nil }
        return LocalPhotoLibrary.shared.isLivePhoto(localID) ? localID : nil
    }

    func matchingLocalLivePhoto(for hint: LocalLivePhotoMatchHint) async -> String? {
        guard accountGeneration == LocalSnapshot.generation, !Task.isCancelled else { return nil }
        let localID = await LocalPhotoLibrary.shared.matchingLivePhoto(for: hint)
        return accountGeneration == LocalSnapshot.generation && !Task.isCancelled ? localID : nil
    }

    func localLivePhoto(forLocalAssetID localID: String, targetSize: CGSize) async -> PHLivePhoto? {
        guard accountGeneration == LocalSnapshot.generation, !Task.isCancelled else { return nil }
        let context = requestContext, sourceID = self.sourceID(for: localID)
        let image = await LocalPhotoLibrary.shared.livePhoto(for: localID, targetSize: targetSize)
        return accountGeneration == LocalSnapshot.generation && !Task.isCancelled && context == requestContext
            && sourceID == self.sourceID(for: localID) && visibilityPolicy.allows(id: localID) ? image : nil
    }

    func editedLivePhoto(for assetID: String, targetSize: CGSize) async -> EditedLivePhotoResult {
        let context = requestContext, sourceID = self.sourceID(for: assetID)
        func isAllowed() -> Bool {
            accountGeneration == LocalSnapshot.generation && !Task.isCancelled && context == requestContext
                && sourceID == self.sourceID(for: assetID) && visibilityPolicy.allows(id: assetID)
                && visibilityPolicy.allows(id: sourceID)
        }
        guard isAllowed() else { return .unavailable }
        let result = await MediaEditingPipeline.shared.editedLivePhoto(assetID: assetID, session: session,
            targetSize: targetSize, isAllowed: isAllowed)
        guard isAllowed() else {
            if case .movie(let item, _, _, _) = result { item.asset.cancelLoading() }
            TemporaryMediaStore.remove(result.ownedURLs)
            return .unavailable
        }
        return result
    }

    func livePhotoMode(for assetID: String) -> LivePhotoEditRecipe.Mode {
        guard accountGeneration == LocalSnapshot.generation else { return .off }
        do {
            guard let saved = try MediaEditingPipeline.shared.savedEdit(for: assetID, session: session),
                  saved.document.kind == .livePhoto else { return .live }
            return saved.document.live.mode
        } catch { return .off }
    }

    /// Menghangatkan halaman tetangga sebelum diusap ke sana.
    func prefetch(_ assetIds: [String]) {
        guard accountGeneration == LocalSnapshot.generation else { return }
        let serverIDs = assetIds.compactMap(serverPreviewID(for:))
        guard !serverIDs.isEmpty else { return }

        let api = session.imageAPI
        let sources = Dictionary(serverIDs.map { (cacheKey(for: $0), $0) }, uniquingKeysWith: { first, _ in first })
        imageCache.prefetch(
            keys: Array(sources.keys),
            maxPixelSize: Self.maxPixelSize,
            fetch: { key in
                guard let assetId = sources[key] else { throw CancellationError() }
                return try await MediaEditingPipeline.shared.imageData(.init(
                    path: "/assets/\(assetId)/thumbnail",
                    query: [
                        .init(name: "size", value: "preview"),
                        .init(name: "edited", value: "true"),
                    ]), api: api)
            })
    }

    func invalidate(_ assetId: String) async {
        guard accountGeneration == LocalSnapshot.generation else { return }
        let sourceID = serverPreviewID(for: assetId) ?? assetId
        await imageCache.remove(
            key: cacheKey(for: sourceID), maxPixelSize: Self.maxPixelSize)
    }
}
