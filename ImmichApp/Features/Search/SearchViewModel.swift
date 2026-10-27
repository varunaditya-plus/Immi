import Foundation
import Observation

@MainActor
@Observable
final class SearchViewModel {
    var searchText = ""
    private var loadedResults: [AssetLite] = []
    var results: [AssetLite] {
        get { loadedResults.filter { !dataManager.nonTimelineAssetIDs.contains($0.id) } }
        set { loadedResults = newValue }
    }
    /// Jumlah SELURUH yang cocok di server, bukan cuma yang sudah dimuat.
    ///
    /// Halamannya seratusan sekali ambil, jadi `results.count` menjawab
    /// pertanyaan yang berbeda: "berapa yang sudah turun", bukan "berapa yang
    /// ketemu" — dan subtitle yang berubah angka setiap kali digulir bukan
    /// informasi, itu gangguan.
    private(set) var totalResults = 0
    var phase: LoadingPhase<Void> = .idle
    var currentPage = 1
    var nextPage: String?
    /// Penyaring yang sedang berlaku.
    var filters = SearchFilters()
    /// Bahan pilihan untuk sheet penyaring; dimuat sekali.
    var people: [PersonDTO] = []
    var cities: [String] = []

    private(set) var hasLoadedOptions = false
    /// Kegagalan AKSI, dipisah dari `phase`.
    ///
    /// `phase` menentukan apa yang digambar layar; menaruh gagalnya arsip di
    /// sana akan mengganti seluruh hasil pencarian dengan layar error hanya
    /// karena satu foto tidak jadi dipindah. Yang ini muncul sebagai alert dan
    /// meninggalkan hasilnya utuh.
    var actionError: String?

    private let repo: SearchRepository
    private let peopleRepo: PeopleRepository?
    private let assetRepo: AssetDetailRepository
    private let albumRepo: AlbumRepository
    private let dataManager: SwiftDataManager
    /// Penomor pencarian.
    ///
    /// `loadMore` berjalan di task lepas yang tidak pernah dibatalkan
    /// `scheduleSearch` — hanya `searchTask` yang dibatalkan. Tanpa penomor ini,
    /// halaman kedua dari pencarian LAMA bisa mendarat setelah pencarian baru
    /// mengosongkan hasilnya, menambahkan foto yang tidak dicari dan merusak
    /// penunjuk halamannya.
    private var generation = 0
    private var searchTask: Task<Void, Never>?
    private var isLoadingMore = false

    init(
        repo: SearchRepository,
        assetRepo: AssetDetailRepository,
        albumRepo: AlbumRepository,
        peopleRepo: PeopleRepository? = nil,
        dataManager: SwiftDataManager? = nil
    ) {
        self.repo = repo
        self.assetRepo = assetRepo
        self.albumRepo = albumRepo
        self.peopleRepo = peopleRepo
        self.dataManager = dataManager ?? .shared
    }

    /// Ada sesuatu untuk dicari: kata kunci, penyaring, atau keduanya.
    ///
    /// Inilah yang membuat penyaring berguna untuk MENJELAJAH, bukan cuma
    /// menyempitkan hasil ketikan — memilih "Last 3 Months" dan "Videos" saja
    /// sudah menghasilkan sesuatu.
    var hasCriteria: Bool {
        !searchText.trimmingCharacters(in: .whitespaces).isEmpty || filters.isActive
    }

    /// Debounce per ketukan; membatalkan pencarian sebelumnya supaya
    /// hasil lama tidak menimpa hasil baru.
    ///
    /// Dipakai juga saat penyaing berubah — dan itu disengaja: mengetuk beberapa
    /// chip beruntun tidak boleh menembakkan satu permintaan per ketukan.
    func scheduleSearch() {
        searchTask?.cancel()
        guard hasCriteria else {
            results = []
            totalResults = 0
            phase = .idle
            return
        }
        searchTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            await self?.search()
        }
    }

    func search() async {
        guard hasCriteria else {
            results = []
            totalResults = 0
            phase = .idle
            return
        }

        phase = .loading
        currentPage = 1
        nextPage = nil
        generation &+= 1

        do {
            let response = try await fetch(page: 1)
            guard !Task.isCancelled else { return }
            results = response.assets.items.filter(\.isTimelineVisible).map(Self.makeAssetLite)
            totalResults = response.assets.total
            nextPage = response.assets.nextPage
            phase = .loaded(())
        } catch is CancellationError {
        } catch {
            guard !Task.isCancelled else { return }
            phase = .failed((error as? APIError)?.errorDescription ?? String(localized: "Search failed"))
        }
    }

    func loadMore() async {
        guard hasCriteria, nextPage != nil, !isLoadingMore else { return }
        isLoadingMore = true
        defer { isLoadingMore = false }

        let startedAt = generation
        do {
            let response = try await fetch(page: currentPage + 1)
            // Pencarian sudah berganti selagi halaman ini diambil; hasilnya milik
            // pertanyaan yang sudah tidak ditanyakan lagi.
            guard startedAt == generation else { return }
            currentPage += 1
            let existing = Set(loadedResults.map(\.id))
            let newAssets = response.assets.items
                .filter { $0.isTimelineVisible && !existing.contains($0.id) }
                .map(Self.makeAssetLite)
            loadedResults.append(contentsOf: newAssets)
            nextPage = response.assets.nextPage
        } catch {
            // Halaman berikutnya gagal — biarkan; onAppear sel terakhir akan mencoba lagi.
        }
    }

    /// DUA endpoint, dipilih dari ada-tidaknya kata kunci.
    ///
    /// `/search/smart` mencari berdasarkan makna gambar dan MEMBUTUHKAN kata
    /// kunci — memanggilnya tanpa itu tidak menghasilkan apa-apa. Penyaring saja
    /// adalah pertanyaan tentang metadata, dan `/search/metadata` yang
    /// menjawabnya.
    private func fetch(page: Int) async throws -> SearchResponseDTO {
        let query = searchText.trimmingCharacters(in: .whitespaces)
        var request = SearchRequestDTO(page: page, size: 100, visibility: "timeline")
        filters.apply(to: &request)

        guard !query.isEmpty else {
            return try await repo.metadataSearch(request)
        }
        request.query = query
        return try await repo.smartSearch(request)
    }

    /// Bahan pilihan penyaring. Kegagalannya senyap: penyaring yang daftarnya
    /// kosong masih bisa dilewati, sedangkan alert di layar pencarian menghalangi
    /// hal yang justru sedang dikerjakan pengguna.
    func loadFilterOptions() async {
        // `task` layar berjalan ulang SETIAP KALI tab dibuka lagi. Tanpa penjaga
        // ini, tiap kunjungan menembakkan dua permintaan baru — dan satu di
        // antaranya yang gagal akan mengosongkan daftar yang sudah bisa dipakai.
        guard !hasLoadedOptions else { return }

        async let loadedPeople = peopleRepo?.all() ?? []
        async let loadedCities = (try? await repo.suggestions()) ?? []
        let (fetchedPeople, fetchedCities) =
            await ((try? await loadedPeople) ?? [], loadedCities)

        // Hasil kosong TIDAK menimpa daftar yang sudah terisi.
        if !fetchedPeople.isEmpty { people = fetchedPeople }
        if !fetchedCities.isEmpty { cities = fetchedCities }
        hasLoadedOptions = !fetchedPeople.isEmpty || !fetchedCities.isEmpty
    }

    // MARK: - Aksi atas hasil

    /// Favorit MASSAL selalu MENYALAKAN, bukan membalik satu per satu.
    ///
    /// Seleksi bisa berisi campuran yang sudah dan belum favorit; membaliknya
    /// masing-masing menghasilkan separuh menyala separuh padam — hasil yang
    /// tidak diminta siapa pun.
    /// - Returns: true kalau semuanya diterima server.
    @discardableResult
    func setFavorite(_ ids: [String], to value: Bool) async -> Bool {
        guard !ids.isEmpty else { return false }
        do {
            for id in ids {
                try await assetRepo.toggleFavorite(id, to: value)
                patchFavorite(id, to: value)
            }
            return true
        } catch {
            actionError = message(error, fallback: String(localized: "Failed to update favorite"))
            return false
        }
    }

    /// Membalik status satu foto; ini yang dipakai context menu.
    @discardableResult
    func toggleFavorite(_ asset: AssetLite) async -> Bool {
        await setFavorite([asset.id], to: !asset.isFavorite)
    }

    /// Memindahkan ke arsip. Fotonya HILANG dari hasil pencarian setelahnya:
    /// pencarian ini menjelajah linimasa, dan yang diarsipkan tidak lagi ada di
    /// sana.
    @discardableResult
    func archive(_ ids: [String]) async -> Bool {
        guard !ids.isEmpty else { return false }
        do {
            for id in ids {
                try await assetRepo.setVisibility(id, to: .archive)
            }
            removeLocally(ids)
            return true
        } catch {
            actionError = message(error, fallback: String(localized: "Failed to archive photos"))
            return false
        }
    }

    /// Ke tong sampah, bukan hapus permanen — hasil pencarian tidak pernah
    /// berisi foto yang sudah ada di sana.
    @discardableResult
    func delete(_ ids: [String]) async -> Bool {
        guard !ids.isEmpty else { return false }
        do {
            try await assetRepo.delete(ids)
            removeLocally(ids)
            return true
        } catch {
            actionError = message(error, fallback: String(localized: "Failed to delete photos"))
            return false
        }
    }

    func addToAlbum(_ ids: [String], album: AlbumResponseDTO) async {
        guard !ids.isEmpty else { return }
        do {
            let duplicates = try await albumRepo.addAssets(ids, to: album.id)
            if !duplicates.isEmpty {
                // "Sudah ada di album" bukan kegagalan, tapi tetap harus
                // terdengar — tanpa itu aksinya tidak menghasilkan apa pun
                // yang terlihat.
                actionError = String(localized: "Already in this album")
            }
        } catch {
            actionError = message(error, fallback: String(localized: "Failed to add to album"))
        }
    }

    /// Yang gagal diunduh dilewati, bukan membatalkan seluruh operasi.
    func shareURLs(for ids: [String]) async -> [URL] {
        var urls: [URL] = []
        for id in ids {
            guard let data = try? await assetRepo.downloadOriginal(id) else { continue }
            if let url = try? TemporaryMediaStore.createShareFile(
                data: data,
                suggestedFilename: "\(id).jpg") {
                urls.append(url)
            }
        }
        return urls
    }

    // MARK: - Penambalan lokal

    /// Dipanggil layar detail saat foto keluar dari perpustakaan di sana.
    ///
    /// Tanpa ini petaknya masih terpampang setelah layar detail ditutup, dan
    /// mengetuknya berujung "not found".
    func removeLocally(_ ids: [String]) {
        let gone = Set(ids)
        let before = loadedResults.count
        loadedResults.removeAll { gone.contains($0.id) }
        // Totalnya ikut turun sebanyak yang benar-benar hilang dari daftar ini.
        // Mengurangi `ids.count` mentah-mentah akan salah kalau sebagiannya
        // memang belum pernah dimuat.
        totalResults = max(0, totalResults - (before - loadedResults.count))
    }

    func patchFavorite(_ id: String, to value: Bool) {
        guard let index = loadedResults.firstIndex(where: { $0.id == id }) else { return }
        loadedResults[index].isFavorite = value
    }

    /// `fallback` sudah berupa `String` yang dilokalkan di titik panggilnya,
    /// bukan `LocalizationValue` yang dilokalkan di sini: alat ekstraksi string
    /// hanya melihat literal yang berada langsung di dalam `String(localized:)`.
    private func message(_ error: Error, fallback: String) -> String {
        (error as? APIError)?.errorDescription ?? fallback
    }

    private static func makeAssetLite(_ asset: AssetResponseDTO) -> AssetLite {
        var ratio = 1.0
        if let w = asset.exifInfo?.exifImageWidth, let h = asset.exifInfo?.exifImageHeight,
           w > 0, h > 0 {
            ratio = Double(w) / Double(h)
        }
        return AssetLite(
            id: asset.id,
            isVideo: asset.isVideo,
            ratio: ratio,
            thumbhash: asset.thumbhash,
            createdAt: asset.fileCreatedAt,
            isFavorite: asset.isFavorite,
            duration: asset.duration
        )
    }
}
