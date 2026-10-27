import CryptoKit
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

/// Cache gambar dua lapis, plus penjadwal unduhan.
///
/// Tiga hal yang membedakannya dari versi sebelumnya, dan ketiganya penyebab
/// panas serta tersendat saat menggulir perpustakaan besar:
///
/// 1. **Byte dari server disimpan APA ADANYA.** Dulu tiap gambar di-decode lalu
///    di-encode ulang jadi JPEG sebelum ditulis ke disk — satu decode dan satu
///    encode penuh untuk setiap thumbnail yang lewat di layar.
/// 2. **Decode dilakukan sekali, langsung di ukuran tampil,** lewat ImageIO di
///    luar main thread. `UIImage(data:)` menunda decode sampai frame digambar,
///    jadi seluruh biayanya jatuh ke main thread tepat saat menggulir.
/// 3. **Permintaan yang sama digabung dan jumlah unduhan serentak dibatasi.**
///    Tanpa itu, gulir cepat melepas ratusan permintaan sekaligus yang saling
///    memperlambat — dan sebagian besar hasilnya sudah tidak terlihat lagi.
/// Cache memori gambar — SENGAJA di luar actor.
///
/// `NSCache` sudah aman diakses dari thread mana pun, jadi menaruhnya di dalam
/// actor tidak menambah keamanan apa pun; yang ia tambahkan hanyalah penantian.
/// Dan penantian itu terjadi justru di jalur tersibuk: setiap sel yang kembali
/// ke layar, setiap perpindahan tab, setiap gulir balik — semuanya gambar yang
/// SUDAH ada di memori, tapi tetap harus antre di belakang decode dan unduhan
/// yang sedang berjalan.
///
/// Sekarang cache hit dijawab seketika, di thread pemanggil, tanpa `await`.
final class ImageMemoryCache: @unchecked Sendable {
    static let shared = ImageMemoryCache()

    /// Gambar yang SUDAH didecode, dikunci pada ukuran pikselnya.
    ///
    /// Satu aset bisa tampil sebagai petak grid dan sebagai layar penuh; keduanya
    /// butuh ukuran decode yang berbeda dan tidak boleh saling menimpa.
    private let cache = NSCache<NSString, UIImage>()

    /// `totalCostLimit` adalah plafon, bukan alokasi: `NSCache` hanya menyimpan
    /// sebanyak yang benar-benar dipakai, dan melepasnya sendiri saat sistem
    /// kekurangan memori.
    /// Thumbnail Immich sekitar 250px — setelah didecode kira-kira 250 KB.
    /// Dua ratus lima puluh entri berarti sekitar 60 MB: cukup untuk beberapa
    /// layar ke atas dan ke bawah, jauh dari cukup untuk membuat aplikasi
    /// menggenggam ratusan megabyte tanpa alasan.
    private static let countLimit = 250
    private static let costLimit = 64 * 1024 * 1024

    private init() {
        cache.countLimit = Self.countLimit
        cache.totalCostLimit = Self.costLimit
    }

    func image(for key: String) -> UIImage? {
        cache.object(forKey: key as NSString)
    }

    func insert(_ image: UIImage, for key: String) {
        cache.setObject(image, forKey: key as NSString, cost: Self.cost(of: image))
    }

    func remove(for key: String) {
        cache.removeObject(forKey: key as NSString)
    }

    func removeAll() {
        cache.removeAllObjects()
    }

    /// Perkiraan byte gambar setelah didecode — inilah yang benar-benar menempati
    /// memori, bukan ukuran file terkompresinya.
    private static func cost(of image: UIImage) -> Int {
        guard let cgImage = image.cgImage else { return 1 }
        return cgImage.bytesPerRow * cgImage.height
    }
}

/// Cache disk + penjadwal unduhan dan decode.
actor ImageCache {
    static let shared = ImageCache()

    private let diskCacheURL: URL

    private static let diskLimitDefaultsKey = "imageCache.diskLimitBytes"
    private static let defaultDiskLimit = 512 * 1024 * 1024

    private var maxDiskCacheSize: Int

    /// Total byte L2 yang dipelihara secara berjalan, supaya insert tidak perlu
    /// memindai seluruh direktori (pemicu tersendat saat scroll).
    private var runningDiskUsage: Int?

    /// Pekerjaan yang sedang berjalan per (key, ukuran).
    ///
    /// Sepuluh sel yang meminta gambar yang sama hanya menghasilkan satu
    /// unduhan; sisanya menunggu hasil yang sama.
    private var inFlight: [String: Task<UIImage, Error>] = [:]
    /// Dinaikkan saat cache dibersihkan. Prefetch akun lama membawa nomor lama
    /// dan berhenti sebelum dapat memulai permintaan berikutnya.
    private var generation = 0

    /// Pembatas pekerjaan berat yang berjalan serentak — baca disk, decode, DAN
    /// unduhan.
    ///
    /// Dulu hanya unduhan yang dibatasi, padahal decode-lah yang paling mahal:
    /// gulir cepat melepas ratusan `Task.detached` yang masing-masing membuka
    /// piksel sebuah gambar, dan kolam thread kooperatif habis. Sisa aplikasi —
    /// termasuk penyusunan linimasa — ikut mengantre di belakangnya.
    private static let maxConcurrentWork = 4
    private var activeWork = 0
    private var waiting: [CheckedContinuation<Void, Never>] = []

    /// Jatah TERPISAH untuk prefetch.
    ///
    /// Dulu prefetch memakai jatah yang sama dengan gambar yang sedang terlihat.
    /// Karena prefetch menghangatkan puluhan foto sekaligus, keempat jatahnya
    /// selalu terisi olehnya — dan foto yang benar-benar ada di layar menunggu
    /// di belakang foto yang bahkan belum digulir ke sana. Antrean itu tidak
    /// pernah habis, dan aplikasi berhenti menjawab.
    private static let maxConcurrentPrefetch = 2
    private var activePrefetch = 0
    private var prefetchWaiting: [CheckedContinuation<Void, Never>] = []

    /// Penjaga supaya pemindaian dan pembersihan disk tidak berjalan berlapis.
    private var isScanning = false
    private var isEvicting = false

    /// Bertambah setelah setiap mutasi file yang dilakukan di luar scan/evict.
    /// Hasil scan yang dimulai sebelum angka ini berubah sudah basi dan tidak
    /// boleh menggantikan pembukuan terbaru.
    private var diskMutationGeneration = 0

    nonisolated private static let diskCacheDir = FileManager.default
        .urls(for: .cachesDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("immich-image-cache")

    init() {
        diskCacheURL = Self.diskCacheDir

        let stored = UserDefaults.standard.integer(forKey: Self.diskLimitDefaultsKey)
        maxDiskCacheSize = stored > 0 ? stored : Self.defaultDiskLimit

        try? FileManager.default.createDirectory(
            at: diskCacheURL, withIntermediateDirectories: true)
    }

    // MARK: - Jalur utama

    /// Membuang satu varian cache setelah server menghasilkan edit baru.
    func remove(key: String, maxPixelSize: Int?) {
        let memoryKey = Self.memoryKey(key, maxPixelSize)
        inFlight[memoryKey]?.cancel()
        inFlight[memoryKey] = nil
        ImageMemoryCache.shared.remove(for: memoryKey)

        let diskPath = diskCacheURL.appendingPathComponent(hashKey(key))
        let size = (try? diskPath.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        guard (try? FileManager.default.removeItem(at: diskPath)) != nil else { return }
        diskMutationGeneration &+= 1
        if let usage = runningDiskUsage {
            runningDiskUsage = max(0, usage - size)
        }
    }

    /// Mengembalikan gambar siap gambar untuk `key`, mengunduh hanya bila perlu.
    ///
    /// - Parameter maxPixelSize: sisi terpanjang yang benar-benar dibutuhkan di
    ///   layar. Petak grid tidak perlu didecode pada 1440px hanya untuk
    ///   ditampilkan setinggi 130pt.
    ///
    ///   `nil` berarti pakai ukuran aslinya. Untuk layar detail itu yang benar:
    ///   endpoint `preview` sudah mengirim gambar seukuran yang pantas, dan
    ///   menebak-nebak lebar layar hanya menghasilkan angka ajaib yang salah di
    ///   sebagian perangkat.
    /// - Parameter fetch: cara mengambil byte-nya kalau belum ada di disk.
    func image(
        key: String,
        maxPixelSize: Int?,
        isPrefetch: Bool = false,
        expectedGeneration: Int? = nil,
        fetch: @escaping @Sendable () async throws -> Data
    ) async throws -> UIImage {
        let requestGeneration = expectedGeneration ?? generation
        guard requestGeneration == generation else { throw CancellationError() }
        let memoryKey = Self.memoryKey(key, maxPixelSize)

        if let cached = ImageMemoryCache.shared.image(for: memoryKey) {
            return cached
        }

        if let running = inFlight[memoryKey] {
            return try await running.value
        }

        let task = Task<UIImage, Error> { [weak self] in
            guard let self else { throw CancellationError() }
            return try await self.produce(
                key: key, memoryKey: memoryKey,
                maxPixelSize: maxPixelSize, isPrefetch: isPrefetch,
                expectedGeneration: requestGeneration, fetch: fetch)
        }
        inFlight[memoryKey] = task

        defer { inFlight[memoryKey] = nil }
        return try await task.value
    }

    /// Menghangatkan gambar SEBELUM selnya sampai di layar.
    ///
    /// Tanpa ini, sebuah foto baru mulai dimuat pada saat ia sudah terlihat — dan
    /// pada gulir cepat ia sudah lewat sebelum gambarnya datang. Yang tampak
    /// hanyalah petak abu-abu, sementara pekerjaannya tetap dibayar.
    ///
    /// Prioritasnya rendah dan hasilnya dibuang: yang dituju cuma mengisi cache.
    /// - Parameter onFailure: dikabari untuk key yang gagal. Kegagalan prefetch
    ///   biasanya memang tidak menarik — tapi kegagalan yang berarti "aset ini
    ///   tidak bisa dibaca lagi" harus diketahui SEKARANG, selagi selnya masih di
    ///   luar layar. Kalau menunggu sampai selnya terlihat, pembuangannya terjadi
    ///   tepat di depan mata pengguna.
    nonisolated func prefetch(
        keys: [String],
        maxPixelSize: Int?,
        fetch: @escaping @Sendable (String) async throws -> Data,
        onFailure: (@Sendable (String, Error) -> Void)? = nil
    ) {
        Task(priority: .background) {
            let expectedGeneration = await self.generation
            for key in keys {
                guard await self.isCurrentGeneration(expectedGeneration) else { return }
                // Sudah ada di memori — tidak ada yang perlu dikerjakan.
                let memoryKey = Self.memoryKey(key, maxPixelSize)
                if ImageMemoryCache.shared.image(for: memoryKey) != nil { continue }

                do {
                    _ = try await image(
                        key: key,
                        maxPixelSize: maxPixelSize,
                        isPrefetch: true,
                        expectedGeneration: expectedGeneration,
                        fetch: { try await fetch(key) })
                } catch {
                    onFailure?(key, error)
                }
            }
        }
    }

    private func isCurrentGeneration(_ expected: Int) -> Bool {
        expected == generation
    }

    private func produce(
        key: String,
        memoryKey: String,
        maxPixelSize: Int?,
        isPrefetch: Bool,
        expectedGeneration: Int,
        fetch: @Sendable () async throws -> Data
    ) async throws -> UIImage {
        let diskPath = diskCacheURL.appendingPathComponent(hashKey(key))

        // Jatah diambil SEBELUM pekerjaan apa pun, termasuk baca disk.
        await acquireSlot(isPrefetch: isPrefetch)
        defer { releaseSlot(isPrefetch: isPrefetch) }

        // Diperiksa setelah mengantre, bukan hanya setelah mengunduh.
        //
        // Sel yang sudah tergulir jauh dari layar sempat menunggu giliran di
        // sini; melanjutkannya berarti membayar decode untuk gambar yang tidak
        // akan dilihat siapa pun, sementara sel yang benar-benar terlihat
        // menunggu di belakangnya.
        try Task.checkCancellation()

        // Baca disk DAN decode dilakukan di luar actor, dalam satu perjalanan.
        //
        // Keduanya sinkron dan memakan waktu. Dijalankan di actor, setiap sel
        // yang lewat di layar harus mengantre di belakang sel sebelumnya —
        // seluruh I/O gambar berubah jadi satu barisan tunggal, dan itulah yang
        // terasa sebagai tersendat saat menggulir cepat.
        //
        // Actor tetap memegang pembukuannya: cache memori, tabel permintaan yang
        // sedang berjalan, dan jatah unduhan.
        if let image = await Self.loadFromDisk(diskPath, maxPixelSize: maxPixelSize) {
            try Task.checkCancellation()
            guard expectedGeneration == generation else { throw CancellationError() }
            touch(diskPath)
            remember(image, for: memoryKey)
            return image
        }

        let data = try await fetch()
        try Task.checkCancellation()
        guard expectedGeneration == generation else { throw CancellationError() }

        await store(data, at: diskPath)

        guard let image = await Self.decode(data, maxPixelSize: maxPixelSize) else {
            throw APIError.unknown
        }
        try Task.checkCancellation()
        guard expectedGeneration == generation else { throw CancellationError() }
        remember(image, for: memoryKey)
        return image
    }

    /// Membaca berkas cache lalu men-decode-nya, seluruhnya di luar actor.
    ///
    /// Berkas yang gagal di-decode dibuang di tempat: isinya rusak (mis. tulisan
    /// terpotong karena aplikasi ditutup), dan menyimpannya berarti percobaan
    /// berikutnya gagal dengan cara yang sama, selamanya.
    nonisolated private static func loadFromDisk(
        _ path: URL,
        maxPixelSize: Int?
    ) async -> UIImage? {
        await Task.detached(priority: .utility) {
            // Dibaca biasa, BUKAN `.mappedIfSafe`.
            //
            // Pemetaan berkas menambahkan halaman ke jejak memori proses dan
            // menahannya sampai sistem memutuskan membuangnya. Untuk ribuan
            // thumbnail berukuran ratusan kilobyte, pemetaan tidak memberi
            // keuntungan apa pun — tapi jejak memorinya menumpuk sampai ratusan
            // megabyte yang tidak pernah turun.
            guard let data = try? Data(contentsOf: path) else { return nil }

            if let image = decodeSync(data, maxPixelSize: maxPixelSize) {
                return image
            }
            try? FileManager.default.removeItem(at: path)
            return nil
        }.value
    }

    // MARK: - Decode

    /// Decode (dan perkecil kalau diminta) di luar main thread.
    ///
    /// `kCGImageSourceShouldCacheImmediately` memaksa pikselnya dibongkar di
    /// sini juga; tanpa itu Core Graphics menundanya sampai frame digambar, dan
    /// seluruh biayanya jatuh ke main thread persis saat jari sedang menggulir.
    nonisolated private static func decode(
        _ data: Data,
        maxPixelSize: Int?
    ) async -> UIImage? {
        await Task.detached(priority: .utility) {
            decodeSync(data, maxPixelSize: maxPixelSize)
        }.value
    }

    nonisolated private static func decodeSync(
        _ data: Data,
        maxPixelSize: Int?
    ) -> UIImage? {
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, sourceOptions)
        else { return nil }

        var options: [CFString: Any] = [
            kCGImageSourceShouldCacheImmediately: true,
        ]

        guard let maxPixelSize else {
            // Ukuran asli, tapi tetap dibongkar sekarang juga.
            let cgImage = CGImageSourceCreateImageAtIndex(
                source, 0, options as CFDictionary)
            return cgImage.map(UIImage.init(cgImage:))
        }

        options[kCGImageSourceCreateThumbnailFromImageAlways] = true
        options[kCGImageSourceCreateThumbnailWithTransform] = true
        options[kCGImageSourceThumbnailMaxPixelSize] = maxPixelSize

        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(
            source, 0, options as CFDictionary)
        else { return nil }

        return UIImage(cgImage: cgImage)
    }

    // MARK: - Penyimpanan

    /// Kunci cache memori: satu aset bisa punya beberapa ukuran decode.
    nonisolated static func memoryKey(_ key: String, _ maxPixelSize: Int?) -> String {
        maxPixelSize.map { "\(key)@\($0)" } ?? "\(key)@full"
    }

    private func remember(_ image: UIImage, for memoryKey: String) {
        ImageMemoryCache.shared.insert(image, for: memoryKey)
    }

    /// Penulisan disk tetap berjalan di luar actor, tetapi penyelesaiannya
    /// ditunggu sebelum ukuran dibukukan. Dengan begitu scan/eviction tidak bisa
    /// menyatakan cache aman ketika atomic write-nya sebenarnya belum muncul.
    private func store(_ data: Data, at path: URL) async {
        // Pembukuan baru dilakukan SETELAH atomic write selesai. Sebelumnya
        // eviction dapat memindai saat file belum muncul, lalu hasil scan lama
        // menimpa angka pemakaian meskipun banyak write sudah menyusul.
        let sizes: (old: Int, new: Int)? = await Task.detached(priority: .background) {
            let oldSize = (try? path.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            do {
                try data.write(to: path, options: .atomic)
                let newSize = (try? path.resourceValues(forKeys: [.fileSizeKey]).fileSize)
                    ?? data.count
                return (oldSize, newSize)
            } catch {
                return nil
            }
        }.value

        guard let sizes else { return }
        diskMutationGeneration &+= 1

        guard let usage = runningDiskUsage else {
            // Ukuran cache belum diketahui. Memindai direktori berisi ribuan
            // berkas itu lambat, dan di actor ia menahan SELURUH permintaan
            // gambar berikutnya — jadi dijalankan di latar, hasilnya menyusul.
            startUsageScan()
            return
        }

        let updatedUsage = max(0, usage - sizes.old + sizes.new)
        runningDiskUsage = updatedUsage
        if updatedUsage > maxDiskCacheSize { startEviction() }
    }

    /// Menghitung ukuran cache di latar, lalu menyimpan hasilnya.
    private func startUsageScan() {
        guard !isScanning else { return }
        isScanning = true

        let directory = diskCacheURL
        let startedAtGeneration = diskMutationGeneration
        Task { [weak self] in
            let total = await Self.scan(directory).total
            await self?.finishUsageScan(total, startedAtGeneration: startedAtGeneration)
        }
    }

    private func finishUsageScan(_ total: Int, startedAtGeneration: Int) {
        isScanning = false
        guard startedAtGeneration == diskMutationGeneration else {
            // Ada file yang selesai ditulis/dihapus ketika scan berlangsung.
            // Ulangi sampai mendapat snapshot yang stabil.
            runningDiskUsage = nil
            startUsageScan()
            return
        }
        runningDiskUsage = total
        if total > maxDiskCacheSize { startEviction() }
    }

    /// Membuang berkas terlama di latar sampai kembali di bawah batas.
    private func startEviction() {
        guard !isEvicting else { return }
        isEvicting = true

        let directory = diskCacheURL
        let limit = maxDiskCacheSize
        let startedAtGeneration = diskMutationGeneration
        Task { [weak self] in
            let remaining = await Self.evict(in: directory, limit: limit)
            await self?.finishEviction(
                remaining,
                startedAtGeneration: startedAtGeneration)
        }
    }

    private func finishEviction(_ remaining: Int, startedAtGeneration: Int) {
        isEvicting = false
        guard startedAtGeneration == diskMutationGeneration else {
            // Write baru bisa selesai selama eviction berjalan. Nilai
            // `remaining` tidak mencakupnya secara andal, jadi rekonsiliasi
            // lewat scan baru dan jalankan eviction lagi bila masih berlebih.
            runningDiskUsage = nil
            startUsageScan()
            return
        }
        runningDiskUsage = remaining
    }

    // MARK: - Pembatas unduhan

    private func acquireSlot(isPrefetch: Bool) async {
        if isPrefetch {
            guard activePrefetch >= Self.maxConcurrentPrefetch else {
                activePrefetch += 1
                return
            }
            await withCheckedContinuation { prefetchWaiting.append($0) }
            activePrefetch += 1
        } else {
            guard activeWork >= Self.maxConcurrentWork else {
                activeWork += 1
                return
            }
            await withCheckedContinuation { waiting.append($0) }
            activeWork += 1
        }
    }

    private func releaseSlot(isPrefetch: Bool) {
        if isPrefetch {
            activePrefetch -= 1
            guard !prefetchWaiting.isEmpty else { return }
            prefetchWaiting.removeFirst().resume()
        } else {
            activeWork -= 1
            guard !waiting.isEmpty else { return }
            waiting.removeFirst().resume()
        }
    }

    // MARK: - Pemeliharaan

    func clear() async {
        generation &+= 1
        // Permintaan akun lama tidak boleh mengisi cache kembali beberapa saat
        // setelah direktori logout dibersihkan.
        let pending = Array(inFlight.values)
        pending.forEach { $0.cancel() }
        // Finish detached disk writes before replacing the account's cache directory.
        for task in pending { _ = try? await task.value }
        inFlight.removeAll()
        ImageMemoryCache.shared.removeAll()
        try? FileManager.default.removeItem(at: diskCacheURL)
        try? FileManager.default.createDirectory(
            at: diskCacheURL, withIntermediateDirectories: true)
        diskMutationGeneration &+= 1
        runningDiskUsage = 0
    }

    func diskCacheSize() async -> Int {
        await Self.scan(diskCacheURL).total
    }

    func diskCacheLimit() -> Int {
        maxDiskCacheSize
    }

    /// Memulihkan cache yang sudah telanjur melewati batas pada versi lama,
    /// tanpa menunggu pengguna menggulir dan menulis thumbnail baru.
    func enforceDiskLimit() {
        guard let usage = runningDiskUsage else {
            startUsageScan()
            return
        }
        if usage > maxDiskCacheSize { startEviction() }
    }

    func setDiskCacheLimit(_ bytes: Int) {
        maxDiskCacheSize = max(16 * 1024 * 1024, bytes)
        UserDefaults.standard.set(maxDiskCacheSize, forKey: Self.diskLimitDefaultsKey)
        startEviction()
    }

    /// Menandai file sebagai baru dipakai, supaya eviction yang mengurutkan
    /// berdasarkan tanggal modifikasi benar-benar LRU.
    ///
    /// Hanya ditulis kalau stempelnya sudah cukup lama, supaya scroll panjang
    /// tidak berubah jadi ribuan penulisan metadata.
    private func touch(_ url: URL) {
        // Di latar: ini murni pembukuan untuk eviction, dan tidak ada yang
        // menunggunya.
        Task.detached(priority: .background) {
            let modified = try? url.resourceValues(forKeys: [.contentModificationDateKey])
                .contentModificationDate
            if let modified, Date().timeIntervalSince(modified) < touchInterval { return }
            try? FileManager.default.setAttributes(
                [.modificationDate: Date()], ofItemAtPath: url.path)
        }
    }

    /// Pemindaian direktori — selalu di luar actor.
    nonisolated private static func scan(
        _ directory: URL
    ) async -> (total: Int, files: [(url: URL, date: Date, size: Int)]) {
        await Task.detached(priority: .utility) {
            let fileManager = FileManager.default
            guard let contents = try? fileManager.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey])
            else { return (0, []) }

            var totalSize = 0
            var files: [(url: URL, date: Date, size: Int)] = []

            for fileURL in contents {
                let values = try? fileURL.resourceValues(
                    forKeys: [.contentModificationDateKey, .fileSizeKey])
                guard let size = values?.fileSize else { continue }
                totalSize += size
                files.append((fileURL, values?.contentModificationDate ?? Date(), size))
            }

            return (totalSize, files)
        }.value
    }

    /// Membuang berkas terlama sampai turun ke bawah batas dengan sisa ruang 25%,
    /// supaya eviction tidak terpicu lagi pada penyimpanan berikutnya.
    ///
    /// - Returns: sisa pemakaian disk setelah pembersihan.
    nonisolated private static func evict(in directory: URL, limit: Int) async -> Int {
        var (totalSize, files) = await scan(directory)
        guard totalSize > limit else { return totalSize }

        return await Task.detached(priority: .utility) {
            let fileManager = FileManager.default
            files.sort { $0.date < $1.date }
            let target = limit - limit / 4

            for file in files {
                if totalSize <= target { break }
                do {
                    try fileManager.removeItem(at: file.url)
                    totalSize -= file.size
                } catch {
                    // A failed delete does not reclaim any storage.
                    continue
                }
            }
            return totalSize
        }.value
    }

    /// Nama file disk untuk sebuah cache key.
    ///
    /// Harus **stabil lintas proses**: `String.hashValue` di Swift di-seed acak
    /// tiap app dijalankan, jadi nama file lama berubah tiap app dibuka dan disk
    /// cache tidak pernah hit di sesi berikutnya. SHA256 selalu menghasilkan nama
    /// yang sama untuk key yang sama.
    nonisolated private func hashKey(_ key: String) -> String {
        SHA256.hash(data: Data(key.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }
}

/// Jarak minimum antar penulisan stempel waktu berkas cache.
///
/// Tanpa ini, menggulir panjang berubah jadi ribuan penulisan metadata — padahal
/// yang dibutuhkan eviction hanya urutan kasar "mana yang lama dipakai".
private let touchInterval: TimeInterval = 60 * 60

// MARK: - View

@MainActor
struct AuthImage: View {
    let assetId: String
    var size: String = "thumbnail"
    /// Thumbhash asset, kalau ada — dipakai sebagai placeholder blur instan
    /// sebelum gambar aslinya datang.
    var thumbhash: String? = nil
    /// Path kustom (mis. "/people/{id}/thumbnail"); default thumbnail aset.
    var path: String? = nil
    /// `.fill` (default) untuk grid/thumbnail yang memang dipotong ke kotak;
    /// `.fit` untuk tampilan detail supaya gambar tidak pernah ter-crop meski
    /// rasio metadata sedikit meleset dari rasio file aslinya.
    var contentMode: ContentMode = .fill
    /// Batas sisi terpanjang, kalau pemanggil tahu ruangnya jauh lebih kecil
    /// daripada bawaan `size`.
    ///
    /// Kartu memori setinggi 240pt tidak butuh bitmap 2048px — itu 12 MB untuk
    /// petak yang tidak pernah lebih dari 720px. `nil` berarti ikut bawaan.
    var pixelSize: Int? = nil
    /// Memotong bitmap menjadi 1:1 dan menormalkan ukuran intrinsiknya sebelum
    /// dibungkus sebagai SwiftUI `Image`.
    ///
    /// Ini berbeda dari `clipShape`: container seperti sidebar `TabView` dapat
    /// membaca rasio intrinsik gambar dan menata label sebelum modifier view
    /// diterapkan. Nilai ini adalah ukuran sisi dalam point; `nil` tidak crop.
    var squareCropPointSize: CGFloat? = nil

    @Environment(SessionManager.self) private var session
    /// TIDAK ada `UIImage` yang disimpan di sini.
    ///
    /// Inilah sumber memori yang tidak pernah turun. `LazyVGrid` membuat view
    /// selnya secara malas, tapi ia TIDAK membuangnya lagi saat selnya keluar
    /// layar — state milik view itu tetap hidup selama scroll view-nya hidup.
    /// Dengan `@State image: UIImage?`, setiap sel yang PERNAH terlihat menahan
    /// bitmap hasil decode-nya selamanya. Menggulir melewati tiga ribu foto
    /// berarti tiga ribu bitmap tertahan — ratusan megabyte yang tidak pernah
    /// dilepas, persis grafik datar yang kamu lihat.
    ///
    /// Sekarang bitmap hanya dimiliki `ImageMemoryCache`, yang punya batas dan
    /// membuang sendiri isinya. Yang tersimpan di view cuma penanda revisi untuk
    /// memicu gambar ulang saat pemuatan selesai.
    ///
    /// Nilainya HARUS ikut dibaca saat `body` dijalankan — lihat
    /// `displayedImage(revision:)`.
    ///
    /// Memakai `.id(revision)` justru salah: itu mengganti IDENTITAS view, jadi
    /// `task` di dalamnya ikut dimulai ulang setiap gambar selesai dimuat.
    @State private var revision = 0
    @State private var hasError = false

    var body: some View {
        // Dibaca DI SINI, bukan di dalam `ZStack`.
        //
        // SwiftUI menghubungkan sebuah view ke `@State` hanya ketika nilainya
        // benar-benar dibaca selama `body` berjalan. `@State` yang cuma DITULIS
        // tidak menggambar ulang apa pun — tidak ada ketergantungan yang pernah
        // terbentuk.
        //
        // Itulah bug "gambar baru muncul setelah baris ditutup lalu dibuka
        // lagi": pemuatan selesai, gambarnya masuk cache, `revision` naik — dan
        // tidak terjadi apa-apa. Yang memunculkannya bukan pemuatan itu,
        // melainkan pembangunan ulang view-nya, dan pada saat itu gambarnya
        // memang sudah ada di cache sehingga terlihat seketika.
        let shown = displayedImage(revision: revision)

        return ZStack {
            if let shown {
                Image(uiImage: displayImage(shown))
                    .resizable()
                    .aspectRatio(contentMode: contentMode)
            } else if hasError {
                Rectangle()
                    .fill(.fill.tertiary)
                    .overlay {
                        Image(systemName: "photo")
                            .foregroundStyle(.secondary)
                    }
            } else {
                Rectangle().fill(.fill.quaternary)
            }
        }
        .task(id: cacheKey) { await load() }
    }

    /// Selalu dari cache, tidak pernah dari state view.
    ///
    /// Kalau versi tajamnya belum ada, thumbnail seukuran grid dipakai lebih
    /// dulu; kalau itu pun belum ada, barulah thumbhash. Ketiganya murah dicari
    /// dan tidak satu pun ditahan oleh view ini.
    ///
    /// - Parameter revision: isinya TIDAK dipakai. Ia parameter, bukan properti
    ///   yang dibaca di dalam badan fungsi, supaya pembacaannya terjadi di
    ///   `body` dan tidak bisa hilang — bentuk `_ = revision` di dalam sini
    ///   terlihat seperti baris tak berguna dan akan dihapus orang berikutnya.
    private func displayedImage(revision: Int) -> UIImage? {
        if let image = ImageMemoryCache.shared.image(for: memoryKey) { return image }
        if let thumbnailMemoryKey,
           let thumbnail = ImageMemoryCache.shared.image(for: thumbnailMemoryKey) {
            return thumbnail
        }
        return ThumbHash.placeholder(for: thumbhash)
    }

    private func displayImage(_ image: UIImage) -> UIImage {
        guard let squareCropPointSize,
              squareCropPointSize > 0,
              let source = image.cgImage
        else { return image }

        let side = min(source.width, source.height)
        let cropRect = CGRect(
            x: CGFloat((source.width - side) / 2),
            y: CGFloat((source.height - side) / 2),
            width: CGFloat(side),
            height: CGFloat(side))
        guard let cropped = source.cropping(to: cropRect) else { return image }

        // UIImage.size dihitung dari jumlah pixel dibagi scale. Menyetel scale
        // dari target point size membuat semua cover melaporkan intrinsic size
        // yang sama, walaupun bitmap sumbernya punya pixel/scale berbeda.
        let normalizedScale = CGFloat(side) / squareCropPointSize
        return UIImage(
            cgImage: cropped,
            scale: normalizedScale,
            orientation: image.imageOrientation)
    }

    private var cacheKey: String {
        path ?? "\(assetId)-\(size)"
    }

    private var memoryKey: String {
        ImageCache.memoryKey(cacheKey, maxPixelSize)
    }

    /// Sisi terpanjang yang benar-benar dibutuhkan di layar.
    ///
    /// Petak grid tidak perlu bitmap 1440px hanya untuk mengisi ruang 130pt.
    /// Layar detail pun tidak perlu ukuran penuh: 2048px sudah melampaui
    /// resolusi layar mana pun, sementara membongkar bitmap 4000px berarti
    /// puluhan megabyte dan puluhan milidetik untuk setiap usapan halaman.
    private var maxPixelSize: Int? {
        if let pixelSize { return pixelSize }
        switch size {
        case "preview", "fullsize": return 2048
        default: return 600
        }
    }

    /// Kunci thumbnail dari aset yang sama, seukuran grid.
    ///
    /// Layar detail hampir selalu dibuka dari grid, jadi versi kecilnya sudah
    /// ada di memori. Menampilkannya lebih dulu membuat foto muncul SEKETIKA,
    /// lalu dipertajam saat preview-nya datang — inilah yang membuat aplikasi
    /// resmi terasa tanpa loading.
    private var thumbnailMemoryKey: String? {
        guard path == nil, size != "thumbnail" else { return nil }
        return ImageCache.memoryKey("\(assetId)-thumbnail", 600)
    }

    private func load() async {
        let key = cacheKey

        // Sudah tergambar dari cache di `body`; tidak ada yang perlu dikerjakan.
        if ImageMemoryCache.shared.image(for: memoryKey) != nil { return }

        let endpoint = Endpoint(
            path: path ?? "/assets/\(assetId)/thumbnail",
            query: path == nil ? [.init(name: "size", value: size)] : [])
        // Satu klien untuk seluruh gambar, bukan satu per sel. Objeknya memang
        // ringan, tapi membuatnya ribuan kali per gulir tetap sampah yang tidak
        // perlu ada.
        let api = session.imageAPI

        do {
            let loaded = try await ImageCache.shared.image(
                key: key,
                maxPixelSize: maxPixelSize,
                fetch: { try await api.rawData(endpoint) })

            // Hasilnya DIPASANG meski task-nya sudah dibatalkan.
            //
            // Dulu di sini ada `guard !Task.isCancelled else { return }`, dan
            // itulah sumber "gambar tidak muncul sampai barisnya ditutup lalu
            // dibuka lagi". Gambarnya sudah terlanjur diunduh, didecode, dan
            // masuk cache — yang dibatalkan hanya penantiannya. View ini tidak
            // menyimpan gambar apa pun; ia MEMBACA cache setiap kali digambar,
            // dan `revision` cuma pemicu gambar ulang. Membuang pemicu itu
            // berarti view yang masih ada di layar tetap abu-abu padahal
            // gambarnya sudah siap, dan satu-satunya cara memunculkannya adalah
            // membangun ulang view-nya — persis yang terjadi saat baris dilipat
            // lalu dibuka lagi.
            //
            // Menulis `@State` milik view yang memang sudah tidak ada tidak
            // berbahaya: SwiftUI mengabaikannya.
            _ = loaded
            revision &+= 1
        } catch is CancellationError {
            // Digulir lewat; bukan kegagalan.
        } catch {
            guard thumbhash == nil else { return }
            hasError = true
        }
    }
}

#Preview {
    AuthImage(assetId: "test-123")
        .environment(SessionManager())
        .frame(height: 200)
}
