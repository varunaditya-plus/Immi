import Foundation
import Observation

@MainActor
@Observable
final class SearchViewModel {
    var searchText = ""
    private var loadedResults: [AssetLite] = []
    var results: [AssetLite] {
        get {
            guard snapshotGeneration == LocalSnapshot.generation else { return [] }
            return AssetVisibilityPolicy(scope: .timeline, dataManager: dataManager).filter(loadedResults)
        }
        set { loadedResults = newValue }
    }
    /// Lower bound while more pages remain; Immich v3 totals can be page-local.
    private var fetchedTotal = 0
    var totalResults: Int {
        guard snapshotGeneration == LocalSnapshot.generation else { return 0 }
        return max(0, fetchedTotal - (loadedResults.count - results.count))
    }
    var phase: LoadingPhase<Void> = .idle
    private(set) var currentPage = 1
    private(set) var nextPage: String?
    private(set) var isLoadingMore = false
    private(set) var paginationError: String?
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

    private let snapshotGeneration = LocalSnapshot.generation
    private let repo: SearchRepository
    private let peopleRepo: PeopleRepository?
    private let assetRepo: AssetDetailRepository
    private let albumRepo: AlbumRepository
    private let dataManager: SwiftDataManager
    // Every criteria change invalidates outstanding responses before debounce.
    private var generation = 0
    private var searchTask: Task<Void, Never>?
    private var activeRequest: SearchRequestDTO?
    private var removedResultIDs = Set<String>()

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

    func scheduleSearch() {
        guard let request = beginSearch() else { return }
        let startedAt = generation
        searchTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(300))
            } catch { return }
            await self?.performSearch(request, generation: startedAt)
        }
    }

    func search() async {
        guard let request = beginSearch() else { return }
        await performSearch(request, generation: generation)
    }

    private func beginSearch() -> SearchRequestDTO? {
        searchTask?.cancel()
        searchTask = nil
        generation &+= 1
        activeRequest = nil
        removedResultIDs.removeAll()
        results = []
        fetchedTotal = 0
        currentPage = 1
        nextPage = nil
        isLoadingMore = false
        paginationError = nil
        guard snapshotGeneration == LocalSnapshot.generation, hasCriteria else {
            phase = .idle
            return nil
        }
        phase = .loading
        var request = SearchRequestDTO(page: 1, size: 100, visibility: "timeline")
        let query = searchText.trimmingCharacters(in: .whitespaces)
        request.query = query.isEmpty ? nil : query
        filters.apply(to: &request)
        return request
    }

    private func performSearch(_ request: SearchRequestDTO, generation startedAt: Int) async {
        guard startedAt == generation, snapshotGeneration == LocalSnapshot.generation else { return }
        defer { if startedAt == generation { searchTask = nil } }
        do {
            try Task.checkCancellation()
            let response = try await fetch(request)
            try Task.checkCancellation()
            guard startedAt == generation, snapshotGeneration == LocalSnapshot.generation else { return }
            try validate(response.assets, after: 1)
            var seen = Set<String>()
            results = response.assets.items.filter {
                $0.isTimelineVisible && !removedResultIDs.contains($0.id) && seen.insert($0.id).inserted
            }
                .map(Self.makeAssetLite)
            fetchedTotal = response.assets.nextPage == nil
                ? loadedResults.count : max(response.assets.total, loadedResults.count)
            activeRequest = request
            nextPage = response.assets.nextPage
            phase = .loaded(())
        } catch {
            guard startedAt == generation, snapshotGeneration == LocalSnapshot.generation else { return }
            if Task.isCancelled || error is CancellationError {
                phase = .idle
            } else {
                phase = .failed(message(error, fallback: String(localized: "Search failed")))
            }
        }
    }

    func loadMore() async {
        guard case .loaded = phase, let activeRequest, let nextPage,
              !isLoadingMore, paginationError == nil else { return }
        guard let page = Int(nextPage), page > currentPage else {
            paginationError = SearchPageError.incomplete.errorDescription
            return
        }
        isLoadingMore = true
        let startedAt = generation
        defer { if startedAt == generation { isLoadingMore = false } }
        var request = activeRequest
        request.page = page
        do {
            try Task.checkCancellation()
            let response = try await fetch(request)
            try Task.checkCancellation()
            guard startedAt == generation, snapshotGeneration == LocalSnapshot.generation else { return }
            try validate(response.assets, after: page)
            var seen = Set(loadedResults.map(\.id))
            let newAssets = response.assets.items.filter {
                $0.isTimelineVisible && !removedResultIDs.contains($0.id) && seen.insert($0.id).inserted
            }
                .map(Self.makeAssetLite)
            loadedResults.append(contentsOf: newAssets)
            fetchedTotal = response.assets.nextPage == nil
                ? loadedResults.count : max(fetchedTotal, response.assets.total, loadedResults.count)
            currentPage = page
            self.nextPage = response.assets.nextPage
        } catch {
            guard startedAt == generation, snapshotGeneration == LocalSnapshot.generation else { return }
            guard !Task.isCancelled, !(error is CancellationError) else { return }
            paginationError = message(error, fallback: String(localized: "Failed to load more photos"))
        }
    }

    func retryLoadMore() async {
        guard !isLoadingMore else { return }
        paginationError = nil
        await loadMore()
    }

    private func fetch(_ request: SearchRequestDTO) async throws -> SearchResponseDTO {
        if request.query == nil {
            return try await repo.metadataSearch(request)
        }
        return try await repo.smartSearch(request)
    }

    private func validate(_ page: SearchResponseDTO.AssetsPage, after currentPage: Int) throws {
        guard let nextPage = page.nextPage else { return }
        guard let next = Int(nextPage), next > currentPage, !page.items.isEmpty else {
            throw SearchPageError.incomplete
        }
    }

    private enum SearchPageError: LocalizedError {
        case incomplete

        var errorDescription: String? {
            String(localized: "Search returned an incomplete page. Please try again.")
        }
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
        actionError = nil
        do {
            for id in ids {
                try await assetRepo.toggleFavorite(id, to: value)
                guard snapshotGeneration == LocalSnapshot.generation else { return false }
                patchFavorite(id, to: value)
                if let cached = dataManager.getCachedAsset(id: id), cached.isFavorite != value {
                    try? dataManager.patchCachedAsset(id, isFavorite: value)
                }
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
        actionError = nil
        do {
            for id in ids {
                try await assetRepo.setVisibility(id, to: .archive)
                guard snapshotGeneration == LocalSnapshot.generation else { return false }
                removeLocally([id])
                if !dataManager.nonTimelineAssetIDs.contains(id)
                    || !dataManager.archivedAssetIDs.contains(id)
                    || dataManager.getCachedAsset(id: id)?.isArchived == false {
                    try? dataManager.setAssetVisibility([id], to: "archive")
                }
            }
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
        actionError = nil
        do {
            try await assetRepo.delete(ids)
            guard snapshotGeneration == LocalSnapshot.generation else { return false }
            removeLocally(ids)
            return true
        } catch {
            actionError = message(error, fallback: String(localized: "Failed to delete photos"))
            return false
        }
    }

    @discardableResult
    func addToAlbum(_ ids: [String], album: AlbumResponseDTO) async -> Bool {
        guard !ids.isEmpty else { return false }
        actionError = nil
        do {
            let duplicates = try await albumRepo.addAssets(ids, to: album.id)
            guard snapshotGeneration == LocalSnapshot.generation else { return false }
            if !duplicates.isEmpty {
                // "Sudah ada di album" bukan kegagalan, tapi tetap harus
                // terdengar — tanpa itu aksinya tidak menghasilkan apa pun
                // yang terlihat.
                actionError = String(localized: "Already in this album")
            }
            return true
        } catch {
            actionError = message(error, fallback: String(localized: "Failed to add to album"))
            return false
        }
    }

    /// Yang gagal diunduh dilewati, bukan membatalkan seluruh operasi.
    func shareURLs(for ids: [String]) async -> [URL] {
        let policy = AssetVisibilityPolicy(scope: .timeline, dataManager: dataManager)
        guard snapshotGeneration == LocalSnapshot.generation, !Task.isCancelled,
              ids.allSatisfy({ policy.allows(id: $0) }) else { return [] }
        let urls = await assetRepo.shareFiles(ids)
        guard snapshotGeneration == LocalSnapshot.generation, !Task.isCancelled,
              ids.allSatisfy({ policy.allows(id: $0) }) else {
            TemporaryMediaStore.remove(urls)
            return []
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
        removedResultIDs.formUnion(gone)
        let before = loadedResults.count
        loadedResults.removeAll { gone.contains($0.id) }
        // Totalnya ikut turun sebanyak yang benar-benar hilang dari daftar ini.
        // Mengurangi `ids.count` mentah-mentah akan salah kalau sebagiannya
        // memang belum pernah dimuat.
        fetchedTotal = max(0, fetchedTotal - (before - loadedResults.count))
    }

    func patchFavorite(_ id: String, to value: Bool) {
        guard snapshotGeneration == LocalSnapshot.generation else { return }
        guard let index = loadedResults.firstIndex(where: { $0.id == id }) else { return }
        loadedResults[index].isFavorite = value
    }

    /// `fallback` sudah berupa `String` yang dilokalkan di titik panggilnya,
    /// bukan `LocalizationValue` yang dilokalkan di sini: alat ekstraksi string
    /// hanya melihat literal yang berada langsung di dalam `String(localized:)`.
    private func message(_ error: Error, fallback: String) -> String {
        (error as? LocalizedError)?.errorDescription ?? fallback
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
