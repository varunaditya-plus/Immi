import UIKit

/// Satu pintu untuk thumbnail grid.
///
/// Sel UIKit tidak punya `@Environment`, jadi cara mengambil gambar dititipkan
/// lewat objek ini — sekaligus menjaga agar kunci cache dan ukuran decode-nya
/// hanya ditulis di SATU tempat.
@MainActor
class PhotoThumbnailLoader {
    /// Sisi terpanjang yang dibutuhkan petak grid. Thumbnail Immich sendiri
    /// biasanya lebih kecil dari ini, jadi umumnya tidak ada penyusutan sama
    /// sekali — batasnya cuma penjaga kalau server dikonfigurasi lain.
    static let maxPixelSize = 600

    /// Permintaan gambar baru dihentikan sementara.
    ///
    /// Dipakai saat grid terbang melintasi seluruh perpustakaan menuju foto
    /// terbaru: dalam setengah detik itu puluhan layar penuh sel dibangun dan
    /// dibuang lagi, dan membiarkan masing-masing meminta thumbnail berarti
    /// ratusan unduhan untuk foto yang tidak akan pernah sempat dilihat —
    /// mengantre tepat di depan foto yang benar-benar dituju.
    ///
    /// Yang sudah ada di memori TETAP terpasang; yang belum menampilkan
    /// thumbhash-nya, sama seperti saat digulir cepat dengan jari.
    var isSuspended = false
    var visibilityPolicy = AssetVisibilityPolicy()

    private let session: SessionManager
    private let faceAPI: APIClient
    private let accountGeneration = LocalSnapshot.generation

    init(session: SessionManager, faceAPI: APIClient? = nil) {
        self.session = session
        self.faceAPI = faceAPI ?? session.imageAPI
    }

    func faceCacheKey(for assetID: String, personID: String) -> String {
        let personRevision = LocalSnapshot.invalidationRevision(for: LocalSnapshot.Key.person(personID))
        return "face:\(accountGeneration):\(personID):\(assetID):\(personRevision):\(SwiftDataManager.shared.assetMutationRevision)"
    }

    func cachedFaceImage(for assetID: String, personID: String) -> UIImage? {
        guard accountGeneration == LocalSnapshot.generation, visibilityPolicy.allows(id: assetID) else { return nil }
        return ImageMemoryCache.shared.image(for: ImageCache.memoryKey(
            faceCacheKey(for: assetID, personID: personID), Self.maxPixelSize))
    }

    func faceImage(for assetID: String, personID: String) async -> UIImage? {
        guard !isSuspended, !LocalPhotoLibrary.isLocal(assetID),
              accountGeneration == LocalSnapshot.generation, visibilityPolicy.allows(id: assetID) else { return nil }
        let key = faceCacheKey(for: assetID, personID: personID)
        let api = faceAPI
        let repository = PeopleRepository(api: api)
        do {
            let image = try await ImageCache.shared.image(key: key, maxPixelSize: Self.maxPixelSize) {
                let faces = try await repository.faces(in: assetID)
                try Task.checkCancellation()
                let data = try await api.rawData(.init(path: "/assets/\(assetID)/thumbnail", query: [
                    .init(name: "size", value: "preview"), .init(name: "cropped", value: "false"),
                    .init(name: "edited", value: "true"),
                ]))
                let current = await MainActor.run {
                    self.accountGeneration == LocalSnapshot.generation && self.visibilityPolicy.allows(id: assetID)
                        && self.faceCacheKey(for: assetID, personID: personID) == key
                }
                guard current else { throw CancellationError() }
                // Face bounds are transformed by saved edits on the server;
                // only the matching uncropped edited preview uses that space.
                if let face = faces.first(where: { $0.person?.id == personID }),
                   let cropped = PersonFaceImage.croppedData(data, face: face) { return cropped }
                return data
            }
            guard !Task.isCancelled, accountGeneration == LocalSnapshot.generation,
                  visibilityPolicy.allows(id: assetID), faceCacheKey(for: assetID, personID: personID) == key else { return nil }
            return image
        } catch {
            return nil
        }
    }

    func displayAsset(_ asset: AssetLite) -> AssetLite {
        MediaEditingPipeline.shared.displayAsset(asset, session: session)
    }

    func cacheKey(for assetId: String) -> String {
        MediaEditingPipeline.shared.cacheKey("\(assetId)-thumbnail", assetID: assetId, session: session)
    }

    /// Cache hit, tanpa `await`. Dipakai sel untuk memasang gambar seketika.
    func cachedImage(for assetId: String) -> UIImage? {
        guard accountGeneration == LocalSnapshot.generation,
              visibilityPolicy.allows(id: assetId) else { return nil }
        return ImageMemoryCache.shared.image(
            for: ImageCache.memoryKey(cacheKey(for: assetId), Self.maxPixelSize))
    }

    /// Ukuran permintaan ke PhotoKit, dalam piksel.
    private static var deviceTargetSize: CGSize {
        CGSize(width: maxPixelSize, height: maxPixelSize)
    }

    func image(for assetId: String) async -> UIImage? {
        guard !isSuspended, accountGeneration == LocalSnapshot.generation,
              visibilityPolicy.allows(id: assetId) else { return nil }

        // FOTO PERANGKAT punya jalurnya sendiri, dan tidak boleh melewati
        // `UnreadableAssets`.
        //
        // Pelaporan itu berujung pada pembuangan aset dari cache linimasa — dan
        // foto yang gagal dimuat dari PhotoKit (mis. masih di iCloud dan belum
        // diunduh) bukan aset rusak. Membuangnya berarti menghapus petak untuk
        // foto yang masih ada di perangkat.
        if LocalPhotoLibrary.isLocal(assetId) {
            let key = cacheKey(for: assetId)
            let context = session.snapshot
            let original = await LocalPhotoLibrary.shared.thumbnail(
                for: assetId, size: Self.deviceTargetSize)
            let image: UIImage?
            if let original, context == session.snapshot, key == cacheKey(for: assetId) {
                image = try? await MediaEditingPipeline.shared.devicePreview(original, id: assetId,
                    session: session, maxPixelSize: Self.maxPixelSize)
            } else { image = nil }
            guard accountGeneration == LocalSnapshot.generation, context == session.snapshot,
                  key == cacheKey(for: assetId), visibilityPolicy.allows(id: assetId) else { return nil }
            if let image {
                // Dititipkan ke cache MEMORI saja, bukan ke disk: byte-nya sudah
                // ada di perangkat, dan menyalinnya ke cache aplikasi hanya
                // menggandakan penyimpanan untuk sesuatu yang tak perlu diunduh.
                ImageMemoryCache.shared.insert(
                    image,
                    for: ImageCache.memoryKey(key, Self.maxPixelSize))
            }
            return image
        }

        let key = cacheKey(for: assetId)
        let api = session.imageAPI
        let endpoint = Endpoint(
            path: "/assets/\(assetId)/thumbnail",
            query: [.init(name: "size", value: "thumbnail")])

        do {
            let image = try await ImageCache.shared.image(
                key: key,
                maxPixelSize: Self.maxPixelSize,
                fetch: { try await MediaEditingPipeline.shared.imageData(endpoint, api: api) })
            // Keberhasilan ikut dicatat: itulah yang membedakan "aset ini
            // hilang" dari "sambungannya sedang rusak".
            guard accountGeneration == LocalSnapshot.generation,
                  visibilityPolicy.allows(id: assetId) else { return nil }
            UnreadableAssets.shared.noteSuccess()
            return image
        } catch {
            guard accountGeneration == LocalSnapshot.generation else { return nil }
            // `try?` diganti do/catch justru untuk baris ini.
            //
            // Petak yang gagal karena asetnya sudah tidak bisa dibaca tidak boleh
            // sekadar jadi kotak abu-abu; ia harus hilang dari linimasa. Jenis
            // errornya disaring di dalam `report`.
            UnreadableAssets.shared.report(assetId, error: error)
            return nil
        }
    }

    /// Dipanggil `UICollectionViewDataSourcePrefetching` — pekerjaannya nyata,
    /// tapi hasilnya dibuang: yang dituju cuma mengisi cache sebelum selnya
    /// benar-benar sampai di layar.
    func prefetch(_ assetIds: [String]) {
        guard !isSuspended, accountGeneration == LocalSnapshot.generation else { return }
        let generation = accountGeneration

        // PhotoKit punya mekanisme prefetch-nya sendiri; yang lokal diserahkan
        // ke sana dan tidak ikut ke `ImageCache`.
        let deviceIDs = assetIds.filter(LocalPhotoLibrary.isLocal)
        if !deviceIDs.isEmpty {
            LocalPhotoLibrary.shared.startCaching(deviceIDs, size: Self.deviceTargetSize)
        }
        let serverIDs = assetIds.filter { !LocalPhotoLibrary.isLocal($0) }
        guard !serverIDs.isEmpty else { return }

        let api = session.imageAPI
        let idsByKey = Dictionary(serverIDs.map { (cacheKey(for: $0), $0) }, uniquingKeysWith: { _, value in value })
        ImageCache.shared.prefetch(
            keys: Array(idsByKey.keys),
            maxPixelSize: Self.maxPixelSize,
            fetch: { key in
                guard let assetId = idsByKey[key] else { throw CancellationError() }
                let data = try await MediaEditingPipeline.shared.imageData(.init(
                    path: "/assets/\(assetId)/thumbnail",
                    query: [.init(name: "size", value: "thumbnail")]), api: api)
                // Keberhasilan prefetch ikut dicatat, dan itu penting justru di
                // sini: yang melaporkan kegagalan di jalur ini juga prefetch,
                // dan laporan itu dibuang kalau tidak ada satu pun keberhasilan
                // yang tercatat belakangan.
                await MainActor.run {
                    guard generation == LocalSnapshot.generation else { return }
                    UnreadableAssets.shared.noteSuccess()
                }
                return data
            },
            // Aset yang sudah tidak bisa dibaca ketahuan DI SINI, selagi selnya
            // masih beberapa baris di luar layar — jadi pembuangannya terjadi di
            // tempat yang tidak terlihat, bukan tepat saat barisnya tiba.
            onFailure: { key, error in
                guard let assetId = idsByKey[key] else { return }
                Task { @MainActor in
                    guard generation == LocalSnapshot.generation else { return }
                    UnreadableAssets.shared.report(assetId, error: error)
                }
            })
    }
}
