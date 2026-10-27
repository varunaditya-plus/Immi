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

    init(
        session: SessionManager,
        imageCache: ImageCache = .shared,
        serverIDForLocalAsset: @escaping @MainActor (String) -> String? = {
            SwiftDataManager.shared.getBackupRecord(localIdentifier: $0)?.assetId
        },
        localPreview: @escaping @MainActor (String) async -> UIImage? = {
            await LocalPhotoLibrary.shared.preview(for: $0,
                size: CGSize(width: PhotoPreviewLoader.maxPixelSize, height: PhotoPreviewLoader.maxPixelSize))
        }
    ) {
        self.session = session
        self.imageCache = imageCache
        self.serverIDForLocalAsset = serverIDForLocalAsset
        self.localPreview = localPreview
    }

    private func cacheKey(for assetId: String) -> String {
        "\(assetId)-preview"
    }

    private func serverPreviewID(for assetID: String) -> String? {
        guard LocalPhotoLibrary.isLocal(assetID) else { return assetID }
        let localID = LocalPhotoLibrary.localIdentifier(from: assetID)
        guard let serverID = serverIDForLocalAsset(localID), !serverID.isEmpty else { return nil }
        return serverID
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
            for: ImageCache.memoryKey("\(sourceID)-thumbnail", PhotoThumbnailLoader.maxPixelSize)) {
            return thumbnail
        }
        guard sourceID != assetId else { return nil }
        return ImageMemoryCache.shared.image(
            for: ImageCache.memoryKey("\(assetId)-thumbnail", PhotoThumbnailLoader.maxPixelSize))
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
            let image = await localPreview(assetId)
            return accountGeneration == LocalSnapshot.generation && !Task.isCancelled ? image : nil
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
                fetch: { try await api.rawData(endpoint) })
            guard accountGeneration == LocalSnapshot.generation else { return nil }
            UnreadableAssets.shared.noteSuccess()
            return image
        } catch {
            guard accountGeneration == LocalSnapshot.generation, !Task.isCancelled else { return nil }
            if LocalPhotoLibrary.isLocal(assetId) {
                let image = await localPreview(assetId)
                return accountGeneration == LocalSnapshot.generation && !Task.isCancelled ? image : nil
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
        let localAssetID: String?
        if LocalPhotoLibrary.isLocal(assetId) {
            localAssetID = assetId
        } else if let identifier = SwiftDataManager.shared.localIdentifier(
            forServerAsset: assetId) {
            localAssetID = LocalPhotoLibrary.assetID(for: identifier)
        } else {
            localAssetID = nil
        }

        if let localAssetID,
           let localAsset = await LocalPhotoLibrary.shared.videoAsset(for: localAssetID) {
            guard accountGeneration == LocalSnapshot.generation, !Task.isCancelled else {
                localAsset.cancelLoading()
                return nil
            }
            return localAsset
        }

        // Aset yang hanya ada di perangkat tidak punya fallback server.
        guard !Task.isCancelled, !LocalPhotoLibrary.isLocal(assetId),
              let source = videoSource(for: assetId)
        else { return nil }

        return AVURLAsset(
            url: source.url,
            options: ["AVURLAssetHTTPHeaderFieldsKey": source.headers])
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
        let image = await LocalPhotoLibrary.shared.livePhoto(for: localID, targetSize: targetSize)
        return accountGeneration == LocalSnapshot.generation && !Task.isCancelled ? image : nil
    }

    /// Menghangatkan halaman tetangga sebelum diusap ke sana.
    func prefetch(_ assetIds: [String]) {
        guard accountGeneration == LocalSnapshot.generation else { return }
        let serverIDs = assetIds.compactMap(serverPreviewID(for:))
        guard !serverIDs.isEmpty else { return }

        let api = session.imageAPI
        imageCache.prefetch(
            keys: serverIDs.map(cacheKey(for:)),
            maxPixelSize: Self.maxPixelSize,
            fetch: { key in
                let assetId = String(key.dropLast("-preview".count))
                return try await api.rawData(.init(
                    path: "/assets/\(assetId)/thumbnail",
                    query: [
                        .init(name: "size", value: "preview"),
                        .init(name: "edited", value: "true"),
                    ]))
            })
    }

    func invalidate(_ assetId: String) async {
        guard accountGeneration == LocalSnapshot.generation else { return }
        let sourceID = serverPreviewID(for: assetId) ?? assetId
        await imageCache.remove(
            key: cacheKey(for: sourceID), maxPixelSize: Self.maxPixelSize)
    }
}
