import AVFoundation
import Photos
import UIKit

/// Satu pintu untuk gambar layar detail.
///
/// Kembarannya `PhotoThumbnailLoader` untuk grid; dipisah karena ukuran decode,
/// endpoint, dan urutan cadangannya berbeda — dan menyatukannya hanya melahirkan
/// parameter yang harus dibaca ulang setiap kali.
@MainActor
final class PhotoPreviewLoader {
    /// Sisi terpanjang untuk layar detail.
    ///
    /// 2048px sudah melampaui resolusi layar mana pun, sementara membongkar
    /// bitmap 4000px berarti puluhan megabyte dan puluhan milidetik untuk setiap
    /// usapan halaman.
    static let maxPixelSize = 2048

    private let session: SessionManager
    private let accountGeneration = LocalSnapshot.generation

    init(session: SessionManager) {
        self.session = session
    }

    private func cacheKey(for assetId: String) -> String {
        "\(assetId)-preview"
    }

    /// Gambar terbaik yang SUDAH ada di memori, tanpa `await`.
    ///
    /// Kalau versi tajamnya belum ada, thumbnail seukuran grid dipakai lebih
    /// dulu — layar detail hampir selalu dibuka dari grid, jadi versi kecilnya
    /// pasti sudah ada. Menampilkannya seketika inilah yang membuat aplikasi
    /// resmi terasa tanpa loading.
    func cachedImage(for assetId: String) -> UIImage? {
        guard accountGeneration == LocalSnapshot.generation else { return nil }
        if let preview = ImageMemoryCache.shared.image(
            for: ImageCache.memoryKey(cacheKey(for: assetId), Self.maxPixelSize)) {
            return preview
        }
        return ImageMemoryCache.shared.image(
            for: ImageCache.memoryKey("\(assetId)-thumbnail", PhotoThumbnailLoader.maxPixelSize))
    }

    /// true kalau yang ada di memori sudah versi tajamnya, jadi tidak perlu
    /// mengambil apa pun.
    func hasPreview(for assetId: String) -> Bool {
        ImageMemoryCache.shared.image(
            for: ImageCache.memoryKey(cacheKey(for: assetId), Self.maxPixelSize)) != nil
    }

    func image(for assetId: String) async -> UIImage? {
        guard accountGeneration == LocalSnapshot.generation else { return nil }
        // Aset PERANGKAT tidak punya alamat di server.
        //
        // Memintanya ke sana berakhir 400/404, dan itu dibaca `UnreadableAssets`
        // sebagai "aset ini sudah tidak bisa dibaca" — lalu petaknya DIBUANG
        // dari linimasa. Foto yang masih ada di perangkat hilang dari grid
        // hanya karena dibuka.
        if LocalPhotoLibrary.isLocal(assetId) {
            let image = await LocalPhotoLibrary.shared.preview(
                for: assetId,
                size: CGSize(width: Self.maxPixelSize, height: Self.maxPixelSize))
            return accountGeneration == LocalSnapshot.generation ? image : nil
        }

        let api = session.imageAPI
        let endpoint = Endpoint(
            path: "/assets/\(assetId)/thumbnail",
            query: [
                .init(name: "size", value: "preview"),
                // Kalau aset punya crop/rotate/mirror, tampilkan hasilnya.
                // Untuk aset tanpa edit server mengembalikan preview biasa.
                .init(name: "edited", value: "true"),
            ])

        do {
            let image = try await ImageCache.shared.image(
                key: cacheKey(for: assetId),
                maxPixelSize: Self.maxPixelSize,
                fetch: { try await api.rawData(endpoint) })
            guard accountGeneration == LocalSnapshot.generation else { return nil }
            UnreadableAssets.shared.noteSuccess()
            return image
        } catch {
            guard accountGeneration == LocalSnapshot.generation else { return nil }
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
        if LocalPhotoLibrary.isLocal(assetId) {
            return await LocalPhotoLibrary.shared.preview(
                for: assetId,
                size: CGSize(width: Self.maxPixelSize, height: Self.maxPixelSize))
        }

        let api = session.imageAPI
        do {
            return try await ImageCache.shared.image(
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
            guard !Task.isCancelled else {
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
        guard let localID = localAssetID(for: assetId) else { return nil }
        return LocalPhotoLibrary.shared.isLivePhoto(localID) ? localID : nil
    }

    func matchingLocalLivePhoto(for hint: LocalLivePhotoMatchHint) async -> String? {
        await LocalPhotoLibrary.shared.matchingLivePhoto(for: hint)
    }

    func localLivePhoto(forLocalAssetID localID: String, targetSize: CGSize) async -> PHLivePhoto? {
        return await LocalPhotoLibrary.shared.livePhoto(
            for: localID, targetSize: targetSize)
    }

    /// Menghangatkan halaman tetangga sebelum diusap ke sana.
    func prefetch(_ assetIds: [String]) {
        guard accountGeneration == LocalSnapshot.generation else { return }
        // Id perangkat tidak punya alamat di server; menembakkannya ke sana
        // hanya menghasilkan 404 untuk setiap tetangga halaman.
        let serverIDs = assetIds.filter { !LocalPhotoLibrary.isLocal($0) }
        guard !serverIDs.isEmpty else { return }

        let api = session.imageAPI
        ImageCache.shared.prefetch(
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
        await ImageCache.shared.remove(
            key: cacheKey(for: assetId), maxPixelSize: Self.maxPixelSize)
    }
}
