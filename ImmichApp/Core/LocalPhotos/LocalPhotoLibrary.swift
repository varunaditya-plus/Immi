import AVFoundation
import Observation
import Photos
import UIKit

/// Penampung byte yang aman dipakai dari beberapa antrean sekaligus.
///
/// Sengaja sekecil ini: satu kunci, satu buffer, satu bendera. Yang dijaga hanya
/// perakitan potongan berkas dari `PHAssetResourceManager` — bukan sebuah
/// abstraksi umum.
private final class DataAccumulator: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer = Data()
    private var completed = false

    func append(_ chunk: Data) {
        lock.lock()
        defer { lock.unlock() }
        buffer.append(chunk)
    }

    var value: Data {
        lock.lock()
        defer { lock.unlock() }
        return buffer
    }

    /// - Returns: true HANYA untuk pemanggil pertama.
    func claimCompletion() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !completed else { return false }
        completed = true
        return true
    }
}

/// `PHImageManager` dapat memanggil result handler lebih dari sekali (preview
/// terdegradasi lalu hasil final). Continuation Swift hanya boleh diselesaikan
/// sekali, jadi seluruh jalan keluar melewati gerbang ini.
private final class PhotoContinuationGate<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, Never>?

    init(_ continuation: CheckedContinuation<Value, Never>) {
        self.continuation = continuation
    }

    func resume(returning value: Value) {
        lock.lock()
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume(returning: value)
    }
}

/// Satu album di perangkat yang bisa dipilih untuk ikut ditampilkan.
struct LocalAlbum: Identifiable, Sendable {
    let id: String
    let title: String
    let count: Int
    /// `PHAsset.localIdentifier` foto sampulnya, kalau albumnya tidak kosong.
    var coverAssetID: String?
}

/// Satu foto milik perangkat, dilihat dari sisi aplikasi ini.
struct LocalPhoto: Identifiable, Sendable {
    /// `PHAsset.localIdentifier`.
    let id: String
    let createdAt: Date
    /// Tanggal perubahan asli dari PhotoKit. Upload tidak boleh menyalin
    /// `createdAt` ke field modified karena server memakai keduanya untuk
    /// menyusun metadata dan mendeteksi perubahan asset.
    let modifiedAt: Date
    let isVideo: Bool
    /// Live Photo adalah satu item di UI, tetapi dua resource saat backup:
    /// still image dan motion video.
    let isLivePhoto: Bool
    let duration: Double?
    let ratio: Double
}

struct LocalPhotoDisplayMetadata: Sendable {
    let filename: String
    let isVideo: Bool
    let createdAt: Date
}

/// Hitungan ringan untuk halaman Sync Status.
///
/// Tidak membawa `PHAsset` keluar dari antrean PhotoKit dan tidak membaca byte
/// foto, jadi aman disegarkan setiap kali halaman dibuka.
struct LocalLibraryStatusCounts: Sendable {
    let assets: Int
    let albums: Int
}

/// Metadata minimum untuk menemukan kembali pasangan PhotoKit milik aset
/// server lama yang belum mempunyai `BackupRecord`.
struct LocalLivePhotoMatchHint: Equatable, Sendable {
    let createdAt: Date
    let pixelWidth: Int?
    let pixelHeight: Int?
    let originalFileName: String?
}

/// Jembatan ke pustaka foto perangkat.
///
/// **Kenapa terpisah dari lapisan jaringan.** Foto perangkat dan foto server
/// tidak berbagi apa pun kecuali tempatnya berakhir: keduanya sama-sama petak di
/// linimasa. Sumbernya, cara memuat gambarnya, izin yang dibutuhkannya, dan cara
/// menghapusnya semuanya berbeda — dan menyelipkan percabangan itu ke dalam
/// repository yang sudah ada hanya membuat setiap pemanggil ikut menanggung
/// keduanya.
///
/// Yang disatukan justru di titik paling akhir: `AssetLite`. Grid, layar detail,
/// dan mode pilih tidak perlu tahu asal fotonya kecuali untuk menggambar lencana.
@MainActor
@Observable
final class LocalPhotoLibrary: NSObject, LocalSpaceLibrary {
    static let shared = LocalPhotoLibrary()

    /// Awalan id untuk membedakan aset perangkat dari aset server.
    ///
    /// Keduanya hidup berdampingan di daftar yang sama dan diindeks dengan
    /// `String` yang sama, jadi tabrakan id bukan sesuatu yang boleh
    /// diserahkan pada keberuntungan — `localIdentifier` berbentuk UUID beserta
    /// sufiks, dan id server juga UUID.
    nonisolated static let idPrefix = "device:"

    private(set) var photos: [LocalPhoto] = []
    private(set) var isAuthorized = false

    /// Status langsung dari PhotoKit, termasuk saat singleton baru dibuat dan
    /// `requestAccess()` belum sempat memperbarui state observasinya.
    nonisolated static var hasReadAccess: Bool {
        let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        return status == .authorized || status == .limited
    }

    /// Bertambah setiap kali PhotoKit memberi tahu bahwa pustaka berubah.
    ///
    /// Tidak semua perubahan mengubah jumlah `photos` (satu foto bisa hilang
    /// sementara foto lain masuk), jadi jumlah array bukan sinyal yang cukup
    /// untuk menyegarkan asal aset dan menu yang bergantung padanya.
    private(set) var revision = 0
    private var accountGeneration = UUID()

    /// `localIdentifier` foto → nama album perangkat asalnya.
    ///
    /// Dipakai "Sync albums": aset yang diunggah ditaruh di album server dengan
    /// nama yang sama. Dikumpulkan sekalian saat enumerasi karena keanggotaan
    /// album hanya bisa dibaca dari arah album ke aset — menanyakannya per foto
    /// belakangan berarti mengulang seluruh enumerasi sekali lagi.
    private(set) var albumTitles: [String: String] = [:]

    /// Dipasang layanan backup. PhotoKit tidak membangunkan aplikasi yang sudah
    /// disuspend, tetapi perubahan yang datang saat aktif atau ketika iOS
    /// memberi waktu background dapat langsung memicu scan tanpa menunggu view.
    @ObservationIgnored var onLibraryChange: (() -> Void)?

    /// Album perangkat yang ikut ditampilkan dan dicocokkan.
    ///
    /// KOSONG secara bawaan, dan itu disengaja — sama seperti Immich resmi.
    /// Menghitung checksum berarti membaca seluruh byte setiap foto, dan pada
    /// pustaka yang sebagian isinya masih di iCloud itu berarti mengunduhnya
    /// lebih dulu. Pekerjaan sebesar itu tidak boleh dimulai tanpa seseorang
    /// memintanya.
    var selectedAlbumIDs: Set<String> {
        didSet {
            guard selectedAlbumIDs != oldValue else { return }
            UserDefaults.standard.set(Array(selectedAlbumIDs), forKey: Self.selectionKey)
        }
    }

    private static let selectionKey = "localPhotos.selectedAlbums"

    private let imageManager = PHCachingImageManager()

    /// SATU opsi untuk permintaan maupun prefetch.
    ///
    /// PhotoKit hanya memakai ulang hasil `startCachingImages` kalau opsinya
    /// sama persis dengan permintaannya. Dua objek berbeda dengan isi yang sama
    /// pun tidak cukup — jadi keduanya berbagi yang ini.
    ///
    /// `.highQualityFormat`, bukan `.opportunistic`: yang terakhir memanggil
    /// handler-nya dua kali (buram lalu asli) dan kadang berhenti di yang buram,
    /// sedangkan `withCheckedContinuation` hanya boleh dilanjutkan tepat sekali
    /// — tidak lebih (jatuh), tidak kurang (menggantung selamanya).
    private let thumbnailOptions: PHImageRequestOptions = {
        let options = PHImageRequestOptions()
        options.deliveryMode = .highQualityFormat
        options.resizeMode = .fast
        options.isNetworkAccessAllowed = true
        return options
    }()

    private override init() {
        let stored = UserDefaults.standard.stringArray(forKey: Self.selectionKey) ?? []
        selectedAlbumIDs = Set(stored)
        super.init()
        PHPhotoLibrary.shared().register(self)
    }

    // MARK: - Album

    /// Album yang bisa dipilih: album buatan pengguna plus beberapa album pintar
    /// yang berarti sehari-hari.
    ///
    /// Yang kosong dibuang — memilihnya tidak menghasilkan apa pun, dan
    /// daftarnya jadi panjang tanpa isi.
    func albums() async -> [LocalAlbum] {
        // Dipecah, dengan alasan yang sama seperti di `load()`: sisi kanan `||`
        // adalah autoclosure, dan autoclosure tidak mendukung `await`.
        if !isAuthorized {
            guard await requestAccess() else { return [] }
        }
        return await Task.detached(priority: .userInitiated) { Self.fetchAlbums() }.value
    }

    /// Jumlah seluruh foto/video dan album yang dapat diakses aplikasi.
    ///
    /// Berbeda dari `photos`, yang memang hanya berisi album pilihan backup.
    /// Layar status perlu menjelaskan keadaan pustaka perangkat, bukan subset
    /// yang kebetulan dipilih untuk tampil di linimasa.
    func statusCounts() async -> LocalLibraryStatusCounts {
        if !isAuthorized {
            guard await requestAccess() else {
                return LocalLibraryStatusCounts(assets: 0, albums: 0)
            }
        }

        return await Task.detached(priority: .userInitiated) {
            let options = PHFetchOptions()
            options.predicate = NSPredicate(
                format: "mediaType == %d OR mediaType == %d",
                PHAssetMediaType.image.rawValue,
                PHAssetMediaType.video.rawValue)
            return LocalLibraryStatusCounts(
                assets: PHAsset.fetchAssets(with: options).count,
                albums: Self.fetchAlbums().count)
        }.value
    }

    /// Metadata seluruh foto/video yang dapat diakses, untuk job manual
    /// pencocokan cloud id dan hash. Tidak mengubah pilihan album backup dan
    /// tidak menimpa `photos` yang sedang dipakai linimasa.
    func allPhotosForSync() async -> [LocalPhoto] {
        if !isAuthorized {
            guard await requestAccess() else { return [] }
        }
        return await Task.detached(priority: .userInitiated) {
            Self.fetchAllPhotosForSync()
        }.value
    }

    private nonisolated static func fetchAllPhotosForSync() -> [LocalPhoto] {
        let options = PHFetchOptions()
        options.predicate = NSPredicate(
            format: "mediaType == %d OR mediaType == %d",
            PHAssetMediaType.image.rawValue,
            PHAssetMediaType.video.rawValue)
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: true)]

        let assets = PHAsset.fetchAssets(with: options)
        var result: [LocalPhoto] = []
        result.reserveCapacity(assets.count)
        assets.enumerateObjects { asset, _, _ in
            guard let createdAt = asset.creationDate ?? asset.modificationDate else { return }
            let modifiedAt = asset.modificationDate ?? createdAt
            let height = max(asset.pixelHeight, 1)
            result.append(LocalPhoto(
                id: asset.localIdentifier,
                createdAt: createdAt,
                modifiedAt: modifiedAt,
                isVideo: asset.mediaType == .video,
                isLivePhoto: asset.mediaType == .image
                    && asset.mediaSubtypes.contains(.photoLive),
                duration: asset.mediaType == .video ? asset.duration : nil,
                ratio: Double(asset.pixelWidth) / Double(height)))
        }
        return result
    }

    private nonisolated static func fetchAlbums() -> [LocalAlbum] {
        var result: [LocalAlbum] = []

        func collect(_ collections: PHFetchResult<PHAssetCollection>) {
            collections.enumerateObjects { collection, _, _ in
                let assets = PHAsset.fetchAssets(in: collection, options: nil)
                guard assets.count > 0 else { return }
                result.append(LocalAlbum(
                    id: collection.localIdentifier,
                    title: collection.localizedTitle ?? "Untitled",
                    count: assets.count,
                    // Foto TERAKHIR, bukan yang pertama.
                    //
                    // Urutan bawaan PhotoKit menaik, jadi yang pertama adalah
                    // foto tertua di album — sampul yang tidak pernah berubah
                    // meski albumnya bertambah tiap hari. Photos sendiri memakai
                    // yang terbaru.
                    coverAssetID: assets.lastObject?.localIdentifier))
            }
        }

        // Album pintar yang benar-benar dipakai orang; sisanya (Slo-mo, Bursts,
        // Hidden) hanya memanjangkan daftar.
        for subtype: PHAssetCollectionSubtype in [
            .smartAlbumUserLibrary, .smartAlbumFavorites, .smartAlbumScreenshots,
            .smartAlbumSelfPortraits, .smartAlbumVideos,
        ] {
            collect(PHAssetCollection.fetchAssetCollections(
                with: .smartAlbum, subtype: subtype, options: nil))
        }
        collect(PHAssetCollection.fetchAssetCollections(
            with: .album, subtype: .any, options: nil))
        return result
    }

    // MARK: - Free Up Space

    /// Hashes the current PhotoKit originals instead of trusting backup records.
    func candidates(from localIDs: Set<String>, rules: LocalSpaceRules) async throws -> [LocalSpaceCandidate] {
        guard !localIDs.isEmpty else { return [] }
        if !Self.hasReadAccess {
            guard await requestAccess() else { throw LocalSpaceLibraryError.accessRequired }
        }
        let work = Task.detached(priority: .userInitiated) {
            try await Self.verifiedSpaceCandidates(localIDs: localIDs, rules: rules)
        }
        let candidates = try await withTaskCancellationHandler {
            try await work.value
        } onCancel: {
            work.cancel()
        }
        try Task.checkCancellation()
        guard Self.hasReadAccess else { throw LocalSpaceLibraryError.accessRequired }
        return candidates
    }

    private nonisolated static func verifiedSpaceCandidates(
        localIDs: Set<String>, rules: LocalSpaceRules
    ) async throws -> [LocalSpaceCandidate] {
        try Task.checkCancellation()
        let protectedIDs = try protectedSpaceAssetIDs(in: rules.keepAlbumIDs)
        let assets = PHAsset.fetchAssets(withLocalIdentifiers: Array(localIDs), options: nil)
        var candidates: [LocalSpaceCandidate] = []
        for index in 0..<assets.count {
            try Task.checkCancellation()
            let asset = assets.object(at: index)
            guard let snapshot = spaceSnapshot(for: asset, protectedIDs: protectedIDs),
                  LocalSpaceSafety.isEligible(snapshot.state, rules: rules),
                  let roles = LocalSpaceSafety.resourceRoles(for: snapshot.state.version) else { continue }
            var checksums: [LocalSpaceResource: String] = [:]
            for (role, type) in roles {
                guard let resource = snapshot.resources.first(where: { $0.type.rawValue == type }),
                      let checksum = await LocalSpaceResourceHash.checksum(resource) else { break }
                checksums[role] = checksum
            }
            try Task.checkCancellation()
            guard checksums.count == roles.count else { continue }
            candidates.append(LocalSpaceCandidate(
                id: snapshot.state.id, version: snapshot.state.version, resourceChecksums: checksums))
        }
        // Asset versions and album membership can change during a long scan.
        let refreshedProtectedIDs = try protectedSpaceAssetIDs(in: rules.keepAlbumIDs)
        return candidates.filter { candidate in
            guard let asset = fetchAsset(candidate.id),
                  let current = spaceSnapshot(for: asset, protectedIDs: refreshedProtectedIDs)?.state
            else { return false }
            return LocalSpaceSafety.canDelete([candidate], current: [current], rules: rules)
        }.sorted { $0.createdAt < $1.createdAt }
    }

    /// Rechecks the reviewed versions and keep rules inside the final PhotoKit
    /// transaction. A changed or missing item aborts the entire deletion batch.
    func deleteVerified(_ candidates: [LocalSpaceCandidate], rules: LocalSpaceRules) async throws -> Set<String> {
        guard !candidates.isEmpty else { return [] }
        guard Self.hasReadAccess else { throw LocalSpaceLibraryError.accessRequired }
        try Task.checkCancellation()
        let transaction = LocalSpaceDeletionTransaction()
        try await withTaskCancellationHandler {
            try await PHPhotoLibrary.shared().performChanges {
                guard !transaction.isCancelled else { return }
                let ids = candidates.map(\.id)
                let assets = PHAsset.fetchAssets(withLocalIdentifiers: ids, options: nil)
                guard let protectedIDs = try? Self.protectedSpaceAssetIDs(in: rules.keepAlbumIDs) else { return }
                let current = (0..<assets.count).compactMap {
                    Self.spaceSnapshot(for: assets.object(at: $0), protectedIDs: protectedIDs)?.state
                }
                guard LocalSpaceSafety.canDelete(candidates, current: current, rules: rules) else { return }
                _ = transaction.authorize(Set(ids)) {
                    PHAssetChangeRequest.deleteAssets(assets)
                }
            }
        } onCancel: {
            transaction.cancel()
        }
        guard let removed = transaction.authorizedIDs else {
            if transaction.isCancelled { throw CancellationError() }
            throw LocalSpaceLibraryError.libraryChanged
        }
        photos.removeAll { removed.contains($0.id) }
        return removed
    }

    private nonisolated static func spaceSnapshot(
        for asset: PHAsset, protectedIDs: Set<String>
    ) -> (state: LocalSpaceAssetState, resources: [PHAssetResource])? {
        guard asset.mediaType == .image || asset.mediaType == .video,
              let createdAt = asset.creationDate, let modifiedAt = asset.modificationDate else { return nil }
        let resources = PHAssetResource.assetResources(for: asset)
        let descriptors = resources.map {
            LocalSpaceResourceDescriptor(type: $0.type.rawValue, filename: $0.originalFilename,
                contentType: $0.contentType.identifier)
        }.sorted {
            if $0.type != $1.type { return $0.type < $1.type }
            if $0.filename != $1.filename { return $0.filename < $1.filename }
            return $0.contentType < $1.contentType
        }
        let version = LocalAssetVersion(
            createdAt: createdAt, modifiedAt: modifiedAt, isFavorite: asset.isFavorite,
            isVideo: asset.mediaType == .video, isLivePhoto: asset.mediaSubtypes.contains(.photoLive),
            pixelWidth: asset.pixelWidth, pixelHeight: asset.pixelHeight, duration: asset.duration,
            resources: descriptors)
        return (LocalSpaceAssetState(id: asset.localIdentifier, version: version,
            isInKeptAlbum: protectedIDs.contains(asset.localIdentifier)), resources)
    }

    private nonisolated static func protectedSpaceAssetIDs(in albumIDs: Set<String>) throws -> Set<String> {
        guard !albumIDs.isEmpty else { return [] }
        let collections = PHAssetCollection.fetchAssetCollections(withLocalIdentifiers: Array(albumIDs), options: nil)
        guard collections.count == albumIDs.count else { throw LocalSpaceLibraryError.libraryChanged }
        var protectedIDs: Set<String> = []
        collections.enumerateObjects { collection, _, _ in
            PHAsset.fetchAssets(in: collection, options: nil).enumerateObjects { asset, _, _ in
                protectedIDs.insert(asset.localIdentifier)
            }
        }
        return protectedIDs
    }

    /// Foto satu album, tanpa menyentuh `photos`.
    ///
    /// Terpisah dari `load()` dengan sengaja: `photos` adalah gabungan seluruh
    /// album TERPILIH dan dipakai linimasa. Detail album butuh isi satu album
    /// saja — termasuk yang sudah terunggah, yang justru dibuang dari linimasa.
    func photos(inAlbum id: String) async -> [LocalPhoto] {
        if !isAuthorized {
            guard await requestAccess() else { return [] }
        }
        return await Task.detached(priority: .userInitiated) {
            Self.fetchPhotos(inAlbums: [id]).photos
        }.value
    }

    // MARK: - Id

    nonisolated static func isLocal(_ id: String) -> Bool {
        id.hasPrefix(idPrefix)
    }

    /// `device:` dilepas kembali jadi `PHAsset.localIdentifier`.
    ///
    /// Id yang bukan milik perangkat dikembalikan apa adanya, bukan dipotong
    /// tujuh karakter — memotongnya menghasilkan identifier yang mirip sah dan
    /// bisa menunjuk foto yang salah.
    nonisolated static func localIdentifier(from id: String) -> String {
        isLocal(id) ? String(id.dropFirst(idPrefix.count)) : id
    }

    nonisolated static func assetID(for localIdentifier: String) -> String {
        idPrefix + localIdentifier
    }

    // MARK: - Izin & pemuatan

    /// - Returns: true kalau pustakanya boleh dibaca.
    ///
    /// `.readWrite`, bukan `.addOnly`: menghapus foto dari perangkat menuntut
    /// akses tulis, dan meminta izin dua kali pada dua kesempatan berbeda hanya
    /// membuat permintaan kedua terasa mencurigakan.
    @discardableResult
    func requestAccess() async -> Bool {
        let status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        isAuthorized = status == .authorized || status == .limited
        return isAuthorized
    }

    func load() async {
        let generation = accountGeneration
        // DIPECAH, bukan `isAuthorized || await requestAccess()`.
        //
        // Sisi kanan `||` adalah autoclosure, dan autoclosure itu tidak
        // mendukung `await` — bentuk ringkasnya tidak sekadar kurang rapi, ia
        // tidak kompilasi.
        if !isAuthorized {
            guard await requestAccess() else {
                photos = []
                albumTitles = [:]
                return
            }
        }
        // Enumerasi DI LUAR main actor.
        //
        // Pustaka puluhan ribu foto berarti puluhan ribu iterasi, dan tidak satu
        // pun bagiannya butuh main thread — sama seperti pengelompokan linimasa
        // yang sudah lebih dulu dipindahkan keluar.
        guard generation == accountGeneration else { return }
        let albumIDs = selectedAlbumIDs
        // Tidak ada yang dipilih berarti tidak ada yang perlu dibaca.
        guard !albumIDs.isEmpty else {
            photos = []
            albumTitles = [:]
            return
        }
        let result = await Task.detached(priority: .userInitiated) {
            Self.fetchPhotos(inAlbums: albumIDs)
        }.value
        guard generation == accountGeneration else { return }
        photos = result.photos
        albumTitles = result.albumTitles
    }

    /// Foto dari album TERPILIH saja.
    ///
    /// Di iOS satu foto bisa berada di beberapa album sekaligus, jadi hasilnya
    /// disatukan lewat kamus ber-id — kalau tidak, foto yang ada di dua album
    /// terpilih akan muncul dua petak.
    private nonisolated static func fetchPhotos(
        inAlbums ids: Set<String>
    ) -> (photos: [LocalPhoto], albumTitles: [String: String]) {
        let collections = PHAssetCollection.fetchAssetCollections(
            withLocalIdentifiers: Array(ids), options: nil)

        let options = PHFetchOptions()
        options.predicate = NSPredicate(
            format: "mediaType == %d || mediaType == %d",
            PHAssetMediaType.image.rawValue, PHAssetMediaType.video.rawValue)

        var unique: [String: LocalPhoto] = [:]
        var titles: [String: String] = [:]
        collections.enumerateObjects { collection, _, _ in
            let title = collection.localizedTitle
            PHAsset.fetchAssets(in: collection, options: options)
                .enumerateObjects { asset, _, _ in
                    guard unique[asset.localIdentifier] == nil else { return }
                    // Album PERTAMA yang memuatnya, dan hanya itu.
                    //
                    // Satu foto bisa ada di beberapa album terpilih sekaligus;
                    // menaruhnya di semuanya di server berarti menggandakan
                    // aset yang sama ke banyak album tanpa pernah diminta.
                    if let title { titles[asset.localIdentifier] = title }
                    let width = Double(asset.pixelWidth)
                    let height = Double(asset.pixelHeight)
                    let createdAt = asset.creationDate ?? asset.modificationDate ?? Date()
                    unique[asset.localIdentifier] = LocalPhoto(
                        id: asset.localIdentifier,
                        createdAt: createdAt,
                        modifiedAt: asset.modificationDate ?? createdAt,
                        isVideo: asset.mediaType == .video,
                        isLivePhoto: asset.mediaType == .image
                            && asset.mediaSubtypes.contains(.photoLive),
                        duration: asset.mediaType == .video ? asset.duration : nil,
                        ratio: height > 0 ? width / height : 1)
                }
        }

        // MENAIK, sama dengan urutan cache linimasa — penggabungannya jadi
        // sekadar merge dua deret terurut, bukan pengurutan ulang. Pengurutan
        // per-album tidak cukup karena hasilnya digabung dari beberapa album.
        return (unique.values.sorted { $0.createdAt < $1.createdAt }, titles)
    }

    // MARK: - Gambar

    /// Thumbnail untuk sel grid.
    ///
    /// `PHCachingImageManager` punya cache-nya sendiri, jadi hasilnya TIDAK
    /// dititipkan ke `ImageCache`: menyalin byte foto yang sudah ada di
    /// perangkat ke cache disk aplikasi hanya menggandakan penyimpanan untuk
    /// sesuatu yang tidak pernah perlu diunduh.
    func thumbnail(for id: String, size: CGSize) async -> UIImage? {
        guard let asset = Self.fetchAsset(id) else { return nil }

        return await withCheckedContinuation { continuation in
            imageManager.requestImage(
                for: asset,
                targetSize: size,
                contentMode: .aspectFill,
                options: thumbnailOptions
            ) { image, _ in
                continuation.resume(returning: image)
            }
        }
    }

    /// Versi untuk layar detail: UTUH, bukan dipenuhi.
    ///
    /// `.aspectFill` benar untuk petak grid yang memang persegi, tapi di layar
    /// detail ia memotong sisi panjang foto — yang terlihat bukan fotonya,
    /// melainkan bagian tengahnya.
    func preview(for id: String, size: CGSize) async -> UIImage? {
        guard let asset = Self.fetchAsset(id) else { return nil }

        return await withCheckedContinuation { continuation in
            imageManager.requestImage(
                for: asset,
                targetSize: size,
                contentMode: .aspectFit,
                options: thumbnailOptions
            ) { image, _ in
                continuation.resume(returning: image)
            }
        }
    }

    /// Aset video yang masih tersedia di perangkat, tanpa membaca seluruh
    /// berkas ke memori dan tanpa menunggu unduhan dari iCloud.
    ///
    /// `AVPlayer` dapat membaca `AVAsset` dari PhotoKit secara langsung. Jalur
    /// lokal ini membuat video yang baru saja diunggah mulai seketika; kalau
    /// salinan penuhnya tidak ada di perangkat, pemanggil segera beralih ke
    /// streaming server alih-alih menggantung menunggu iCloud.
    func videoAsset(for id: String) async -> AVAsset? {
        guard let asset = Self.fetchAsset(id), asset.mediaType == .video else {
            return nil
        }

        let options = PHVideoRequestOptions()
        options.deliveryMode = .automatic
        options.isNetworkAccessAllowed = false

        return await withCheckedContinuation { continuation in
            imageManager.requestAVAsset(
                forVideo: asset,
                options: options
            ) { videoAsset, _, _ in
                continuation.resume(returning: videoAsset)
            }
        }
    }

    /// Apakah aset PhotoKit ini benar-benar Live Photo.
    ///
    /// Deteksi dari `mediaSubtypes`, bukan dari ekstensi atau durasi. Sebuah
    /// Live Photo terlihat sebagai image biasa sampai flag ini dibaca.
    func isLivePhoto(_ id: String) -> Bool {
        guard let asset = Self.fetchAsset(id) else { return false }
        return asset.mediaType == .image && asset.mediaSubtypes.contains(.photoLive)
    }

    /// Mencari Live Photo lokal yang sama dengan aset server.
    ///
    /// Tanggal saja tidak cukup (burst bisa berbagi detik), dan dimensi saja
    /// juga tidak cukup. Kandidat diterima hanya jika nama file persis sama,
    /// atau tanggal + dimensi sama. Dengan begitu foto biasa tidak mendapat
    /// badge LIVE palsu.
    func matchingLivePhoto(for hint: LocalLivePhotoMatchHint) async -> String? {
        await Task.detached(priority: .userInitiated) {
            Self.findMatchingLivePhoto(hint)
        }.value
    }

    private nonisolated static func findMatchingLivePhoto(
        _ hint: LocalLivePhotoMatchHint
    ) -> String? {
        let options = PHFetchOptions()
        options.predicate = NSPredicate(
            format: "mediaType == %d AND creationDate >= %@ AND creationDate <= %@",
            PHAssetMediaType.image.rawValue,
            hint.createdAt.addingTimeInterval(-5) as NSDate,
            hint.createdAt.addingTimeInterval(5) as NSDate)

        let candidates = PHAsset.fetchAssets(with: options)
        var best: (id: String, score: Int)?
        candidates.enumerateObjects { asset, _, _ in
            guard asset.mediaSubtypes.contains(.photoLive),
                  let date = asset.creationDate
            else { return }

            let delta = abs(date.timeIntervalSince(hint.createdAt))
            let dimensionsMatch: Bool
            if let width = hint.pixelWidth, let height = hint.pixelHeight {
                dimensionsMatch = (asset.pixelWidth == width && asset.pixelHeight == height)
                    || (asset.pixelWidth == height && asset.pixelHeight == width)
            } else {
                dimensionsMatch = false
            }

            let filenameMatch: Bool
            if let expected = hint.originalFileName, !expected.isEmpty {
                filenameMatch = PHAssetResource.assetResources(for: asset).contains {
                    $0.originalFilename.caseInsensitiveCompare(expected) == .orderedSame
                }
            } else {
                filenameMatch = false
            }

            guard filenameMatch || (dimensionsMatch && delta <= 5) else { return }
            var score = filenameMatch ? 100 : 0
            if dimensionsMatch { score += 20 }
            if delta <= 0.1 { score += 10 }
            else if delta <= 1 { score += 5 }

            if best == nil || score > best!.score {
                best = (asset.localIdentifier, score)
            }
        }
        return best.map { Self.assetID(for: $0.id) }
    }

    /// Meminta pasangan still + motion sebagai objek native PhotoKit.
    /// `PHLivePhotoView` kemudian menangani sinkronisasi frame dan transisinya,
    /// sama seperti aplikasi Photos.
    func livePhoto(for id: String, targetSize: CGSize) async -> PHLivePhoto? {
        guard let asset = Self.fetchAsset(id),
              asset.mediaType == .image,
              asset.mediaSubtypes.contains(.photoLive)
        else { return nil }

        let options = PHLivePhotoRequestOptions()
        options.deliveryMode = .highQualityFormat
        options.isNetworkAccessAllowed = true

        return await withCheckedContinuation { continuation in
            let gate = PhotoContinuationGate<PHLivePhoto?>(continuation)
            imageManager.requestLivePhoto(
                for: asset,
                targetSize: targetSize,
                contentMode: .aspectFit,
                options: options
            ) { livePhoto, info in
                let degraded = info?[PHImageResultIsDegradedKey] as? Bool ?? false
                if degraded { return }
                gate.resume(returning: livePhoto)
            }
        }
    }

    func startCaching(_ ids: [String], size: CGSize) {
        let assets = ids.compactMap(Self.fetchAsset)
        guard !assets.isEmpty else { return }
        imageManager.startCachingImages(
            for: assets,
            targetSize: size,
            contentMode: .aspectFill,
            options: thumbnailOptions)
    }

    /// Melupakan seluruh state PhotoKit milik sesi tanpa menghapus foto asli.
    func resetForLogout() {
        accountGeneration = UUID()
        imageManager.stopCachingImagesForAllAssets()
        photos = []
        albumTitles = [:]
        selectedAlbumIDs = []
    }

    // MARK: - Berkas asli

    /// Mengekspor resource asli ke file sementara untuk hashing dan upload.
    ///
    /// Video tidak boleh dirakit menjadi satu `Data`: setelah badan multipart
    /// ikut dibuat, ukuran memorinya menjadi dua kali ukuran video. File ini
    /// memungkinkan hashing dan penyusunan multipart dilakukan per potongan.
    nonisolated func originalFile(
        for id: String,
        allowsNetworkFallback: Bool = true
    ) async -> (url: URL, filename: String)? {
        guard let resource = await Task.detached(priority: .utility, operation: {
            guard let asset = Self.fetchAsset(id) else { return PHAssetResource?.none }
            return Self.primaryResource(for: asset)
        }).value else { return nil }

        if let localURL = await Self.writeTemporaryFile(resource, allowsNetwork: false) {
            return (localURL, resource.originalFilename)
        }
        guard allowsNetworkFallback,
              let remoteURL = await Self.writeTemporaryFile(resource, allowsNetwork: true)
        else { return nil }
        return (remoteURL, resource.originalFilename)
    }

    /// Motion resource pasangan Live Photo.
    ///
    /// PhotoKit menyimpan Live Photo sebagai `.photo + .pairedVideo`. Asset
    /// yang pernah diedit dapat memakai pasangan `.fullSizePhoto +
    /// .fullSizePairedVideo`; pemilih resource di bawah selalu mengambil dua
    /// sisi dari pasangan yang sama agar still dan motion tidak berbeda versi.
    nonisolated func livePhotoMotionFile(
        for id: String,
        allowsNetworkFallback: Bool = true
    ) async -> (url: URL, filename: String)? {
        guard let resource = await Task.detached(priority: .utility, operation: {
            guard let asset = Self.fetchAsset(id),
                  asset.mediaSubtypes.contains(.photoLive)
            else { return PHAssetResource?.none }
            return Self.uploadResources(for: asset).motion
        }).value else { return nil }

        if let localURL = await Self.writeTemporaryFile(resource, allowsNetwork: false) {
            return (localURL, resource.originalFilename)
        }
        guard allowsNetworkFallback,
              let remoteURL = await Self.writeTemporaryFile(resource, allowsNetwork: true)
        else { return nil }
        return (remoteURL, resource.originalFilename)
    }

    /// Membaca metadata satu asset langsung dari PhotoKit. Dipakai saat iOS
    /// meluncurkan ulang aplikasi hanya untuk menyelesaikan tahap kedua upload
    /// Live Photo; daftar album di memori belum tentu sudah dimuat saat itu.
    nonisolated func photoMetadata(for id: String) async -> LocalPhoto? {
        await Task.detached(priority: .utility) {
            guard let asset = Self.fetchAsset(id) else { return nil }
            let createdAt = asset.creationDate ?? asset.modificationDate ?? Date()
            let height = max(asset.pixelHeight, 1)
            return LocalPhoto(
                id: asset.localIdentifier,
                createdAt: createdAt,
                modifiedAt: asset.modificationDate ?? createdAt,
                isVideo: asset.mediaType == .video,
                isLivePhoto: asset.mediaType == .image
                    && asset.mediaSubtypes.contains(.photoLive),
                duration: asset.mediaType == .video ? asset.duration : nil,
                ratio: Double(asset.pixelWidth) / Double(height))
        }.value
    }

    /// Metadata ringan untuk baris antrean backup. Tidak mengekspor byte aset;
    /// nama asli dibaca langsung dari resource PhotoKit.
    nonisolated func displayMetadata(for id: String) async -> LocalPhotoDisplayMetadata? {
        await Task.detached(priority: .utility) {
            guard let asset = Self.fetchAsset(id),
                  let resource = Self.primaryResource(for: asset)
            else { return nil }
            return LocalPhotoDisplayMetadata(
                filename: resource.originalFilename,
                isVideo: asset.mediaType == .video,
                createdAt: asset.creationDate ?? asset.modificationDate ?? Date())
        }.value
    }

    private nonisolated static func writeTemporaryFile(
        _ resource: PHAssetResource,
        allowsNetwork: Bool
    ) async -> URL? {
        let ext = URL(fileURLWithPath: resource.originalFilename).pathExtension
        let suffix = ext.isEmpty ? "" : ".\(ext)"
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("backup-source-\(UUID().uuidString)\(suffix)")
        let options = PHAssetResourceRequestOptions()
        options.isNetworkAccessAllowed = allowsNetwork

        return await withCheckedContinuation { continuation in
            PHAssetResourceManager.default().writeData(
                for: resource,
                toFile: destination,
                options: options
            ) { error in
                if error != nil {
                    try? FileManager.default.removeItem(at: destination)
                    continuation.resume(returning: nil)
                } else {
                    continuation.resume(returning: destination)
                }
            }
        }
    }

    /// Menyimpan hasil download server ke pustaka perangkat dan mengembalikan
    /// `PHAsset.localIdentifier` yang baru dibuat.
    func saveDownloadedFile(_ fileURL: URL, isVideo: Bool) async -> String? {
        if !isAuthorized {
            guard await requestAccess() else { return nil }
        }

        var localIdentifier: String?
        do {
            try await PHPhotoLibrary.shared().performChanges {
                let request = PHAssetCreationRequest.forAsset()
                request.addResource(
                    with: isVideo ? .video : .photo,
                    fileURL: fileURL,
                    options: nil)
                localIdentifier = request.placeholderForCreatedAsset?.localIdentifier
            }
            return localIdentifier
        } catch {
            return nil
        }
    }

    /// Byte asli, untuk diunggah maupun dibagikan.
    ///
    /// Lewat `PHAssetResourceManager`, BUKAN `PHImageManager`.
    ///
    /// Yang terakhir hanya mengerti gambar — video tidak punya "image data" dan
    /// akan pulang dengan tangan kosong. Resource manager membaca berkas
    /// aslinya apa adanya, foto maupun video, berikut nama berkas yang benar.
    /// Ia mengirimkan datanya BERPOTONG-POTONG, jadi buffernya dirakit sendiri.
    /// `nonisolated`, dan itu bukan penghalusan.
    ///
    /// Sebelumnya seluruh fungsi ini terikat main actor, dan akibatnya ada dua.
    /// Yang pertama terlihat di konsol: `PHAssetResource.assetResources(for:)`
    /// dijalankan di main queue, dan PhotoKit sendiri yang memperingatkan bahwa
    /// itu menurunkan kinerja — ia menarik metadata aset secara sinkron di sana.
    /// Yang kedua jauh lebih parah: membaca SELURUH byte setiap berkas juga
    /// terjadi di main actor, dan pencocokan checksum melakukan hal yang sama
    /// untuk seluruh pustaka pada saat yang bersamaan. Dua pekerjaan besar
    /// mengantre di satu-satunya utas yang juga harus menggambar antarmuka —
    /// itulah unggahan yang tidak bergerak selama belasan menit.
    ///
    /// Fungsi `nonisolated async` berjalan di kolam eksekutor umum, bukan di
    /// aktor pemanggilnya. Tidak ada state instance yang disentuh di sini, jadi
    /// tidak ada yang perlu dilindungi.
    nonisolated func originalData(for id: String) async -> (data: Data, filename: String)? {
        // `Task.detached`, bukan mengandalkan `nonisolated` saja.
        //
        // Target ini menyalakan `SWIFT_APPROACHABLE_CONCURRENCY`, dan dengan itu
        // fungsi `nonisolated async` MEWARISI eksekutor pemanggilnya alih-alih
        // pindah ke kolam umum. Pemanggilnya sering main actor — jadi
        // `PHAssetResource.assetResources(for:)`, yang menarik metadata aset
        // secara sinkron, tetap berjalan di main queue persis seperti sebelum
        // fungsi ini dijadikan nonisolated. Itulah peringatan "Fetching on
        // demand on the main queue" yang masih muncul di konsol.
        //
        // `requestData` di bawah tidak kena karena ia menyerahkan diri lewat
        // continuation; yang perlu dipindahkan hanya pencarian resource-nya.
        guard let resource = await Task.detached(priority: .utility, operation: {
            guard let asset = Self.fetchAsset(id) else { return PHAssetResource?.none }
            return Self.primaryResource(for: asset)
        }).value else { return nil }

        // DUA percobaan, dan yang pertama tidak menyentuh jaringan sama sekali.
        //
        // `isNetworkAccessAllowed = true` membuat PhotoKit menghubungi daemon
        // iCloud untuk SETIAP berkas — termasuk yang salinan penuhnya sudah ada
        // di perangkat. Kalau daemon itu sedang bermasalah (`com.apple.accounts
        // Code=7` di konsol), permintaannya tidak ditolak cepat; ia menggantung
        // belasan menit lalu menyerah. Satu foto 3 KB yang sebenarnya sudah ada
        // di disk pun ikut menunggu.
        //
        // Jalur pertama menjawab dalam milidetik untuk semua yang ada di
        // perangkat — dan itu mayoritasnya. Jaringan hanya dipakai untuk yang
        // memang benar-benar tidak ada di sini.
        if let local = await Self.requestData(resource, allowsNetwork: false) {
            return (local, resource.originalFilename)
        }
        guard let remote = await Self.requestData(resource, allowsNetwork: true) else {
            return nil
        }
        return (remote, resource.originalFilename)
    }

    private nonisolated static func requestData(
        _ resource: PHAssetResource, allowsNetwork: Bool
    ) async -> Data? {
        let options = PHAssetResourceRequestOptions()
        options.isNetworkAccessAllowed = allowsNetwork

        return await withCheckedContinuation { continuation in
            // Penampung berkunci, bukan `var` lokal yang ditangkap closure.
            //
            // `dataReceivedHandler` dipanggil PhotoKit dari antreannya sendiri,
            // berkali-kali, sementara `completionHandler` membacanya dari
            // antrean yang belum tentu sama. Menumbuhkan sebuah `Data` dari dua
            // arah tanpa penyelarasan adalah balapan data — yang gagalnya tidak
            // sopan: bukan kesalahan yang terbaca, melainkan byte yang hilang
            // atau proses yang jatuh.
            let buffer = DataAccumulator()
            PHAssetResourceManager.default().requestData(
                for: resource,
                options: options,
                dataReceivedHandler: { buffer.append($0) },
                completionHandler: { error in
                    // Penjaga sekali-jalan: continuation yang dilanjutkan dua
                    // kali menjatuhkan proses, bukan sekadar keliru.
                    guard buffer.claimCompletion() else { return }
                    continuation.resume(returning: error == nil ? buffer.value : nil)
                })
        }
    }

    /// Berkas UTAMA sebuah aset.
    ///
    /// Satu aset bisa punya beberapa resource — foto beserta versi suntingannya,
    /// video beserta foto sampulnya. Yang diambil harus sesuai jenis asetnya,
    /// kalau tidak sebuah video bisa terunggah sebagai gambar diam.
    private nonisolated static func primaryResource(for asset: PHAsset) -> PHAssetResource? {
        uploadResources(for: asset).primary
    }

    /// Memilih pasangan resource yang konsisten untuk upload.
    private nonisolated static func uploadResources(
        for asset: PHAsset
    ) -> (primary: PHAssetResource?, motion: PHAssetResource?) {
        let resources = PHAssetResource.assetResources(for: asset)
        if asset.mediaType == .video {
            return (resources.first { $0.type == .video } ?? resources.first, nil)
        }

        if asset.mediaSubtypes.contains(.photoLive) {
            let fullSizePhoto = resources.first { $0.type == .fullSizePhoto }
            let fullSizeMotion = resources.first { $0.type == .fullSizePairedVideo }
            if let fullSizePhoto, let fullSizeMotion {
                return (fullSizePhoto, fullSizeMotion)
            }

            let photo = resources.first { $0.type == .photo } ?? fullSizePhoto
            let motion = resources.first { $0.type == .pairedVideo } ?? fullSizeMotion
            return (photo ?? resources.first, motion)
        }

        return (resources.first { $0.type == .photo } ?? resources.first, nil)
    }

    // MARK: - Hapus

    /// Menghapus dari PUSTAKA PERANGKAT.
    ///
    /// iOS memunculkan konfirmasinya sendiri — sistem tidak mengizinkan aplikasi
    /// menghapus foto orang tanpa satu ketukan terakhir dari pemiliknya. Karena
    /// itu tidak perlu ada dialog buatan kita sebelum ini.
    @discardableResult
    func delete(_ ids: [String]) async -> Bool {
        let identifiers = ids.map(Self.localIdentifier(from:))
        let assets = PHAsset.fetchAssets(withLocalIdentifiers: identifiers, options: nil)
        guard assets.count > 0 else { return false }

        do {
            try await PHPhotoLibrary.shared().performChanges {
                PHAssetChangeRequest.deleteAssets(assets)
            }
            let removed = Set(identifiers)
            photos.removeAll { removed.contains($0.id) }
            return true
        } catch {
            return false
        }
    }

    /// Id PhotoKit yang masih dapat diakses aplikasi saat ini.
    ///
    /// Sumber kebenaran untuk aksi perangkat harus PhotoKit, bukan catatan
    /// backup. Catatan itu sengaja bertahan setelah unggahan selesai dan bisa
    /// menjadi usang ketika foto dihapus lewat Photos atau aplikasi lain.
    nonisolated static func existingLocalIdentifiers(_ ids: [String]) -> Set<String> {
        guard !ids.isEmpty else { return [] }
        let identifiers = ids.map(localIdentifier(from:))
        let assets = PHAsset.fetchAssets(withLocalIdentifiers: identifiers, options: nil)
        var existing = Set<String>()
        existing.reserveCapacity(assets.count)
        assets.enumerateObjects { asset, _, _ in
            existing.insert(asset.localIdentifier)
        }
        return existing
    }

    nonisolated static func assetExists(_ id: String) -> Bool {
        existingLocalIdentifiers([id]).isEmpty == false
    }

    /// `static` dan `nonisolated`: tidak menyentuh state apa pun, dan memaksanya
    /// lewat main actor berarti setiap pembacaan berkas mengantre di belakang
    /// antarmuka. `static` supaya bisa dipanggil dari `Task.detached` tanpa
    /// menyeret `self` melintasi isolasi.
    fileprivate nonisolated static func fetchAsset(_ id: String) -> PHAsset? {
        let identifier = Self.isLocal(id) ? Self.localIdentifier(from: id) : id
        return PHAsset.fetchAssets(withLocalIdentifiers: [identifier], options: nil).firstObject
    }
}

extension LocalPhotoLibrary: PHPhotoLibraryChangeObserver {
    nonisolated func photoLibraryDidChange(_ changeInstance: PHChange) {
        Task { @MainActor [weak self] in
            self?.revision &+= 1
            self?.onLibraryChange?()
        }
    }
}
