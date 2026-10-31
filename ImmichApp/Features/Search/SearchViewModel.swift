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
        if let activeRequest,
           let exact = repo.exactResultCount(for: activeRequest, options: activeOptions, excluding: removedResultIDs) { return exact }
        return max(0, fetchedTotal - (loadedResults.count - results.count))
    }
    var phase: LoadingPhase<Void> = .idle
    private(set) var currentPage = 1
    private(set) var nextPage: String?
    private(set) var isLoadingMore = false
    private(set) var paginationError: String?
    /// Penyaring yang sedang berlaku.
    var filters = SearchFilters()
    var options = PhotoSearchOptions()
    /// Bahan pilihan untuk sheet penyaring; dimuat sekali.
    var people: [PersonDTO] = []
    var cities: [String] = []
    var states: [String] = []
    var countries: [String] = []
    var albums: [AlbumResponseDTO] = []
    private(set) var incompleteSources: [String] = []

    var hasLoadedOptions: Bool { loadedOptionSources.count == OptionSource.allCases.count }
    var isLoadingOptions: Bool { !optionRequests.isEmpty }
    var optionsError: String? { optionErrors.isEmpty ? nil : String(localized: "Some search suggestions could not be loaded.") }
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
    private let recentlyViewedStore: RecentlyViewedStore?
    // Every criteria change invalidates outstanding responses before debounce.
    private var generation = 0
    private var searchTask: Task<Void, Never>?
    private var activeRequest: SearchRequestDTO?
    private var activeOptions = PhotoSearchOptions()
    private var removedResultIDs = Set<String>()
    private enum OptionSource: CaseIterable, Hashable {
        case people, cities, states, countries, albums
        var isLocation: Bool { self == .cities || self == .states || self == .countries }
    }
    private var loadedOptionSources: Set<OptionSource> = []
    private var optionRequests: [OptionSource: UUID] = [:]
    private var optionErrors: Set<OptionSource> = []
    private var hiddenPeopleIDs: Set<String> = []
    private var knownPeopleIDs: Set<String> = []
    private var confirmedPeopleRevisions: [String: UInt64] = [:]
    private var peopleDirectoryRevision = LocalSnapshot.invalidationRevision(for: LocalSnapshot.Key.peopleList)

    init(
        repo: SearchRepository,
        assetRepo: AssetDetailRepository,
        albumRepo: AlbumRepository,
        peopleRepo: PeopleRepository? = nil,
        dataManager: SwiftDataManager? = nil,
        recentlyViewedStore: RecentlyViewedStore? = nil
    ) {
        self.repo = repo
        self.assetRepo = assetRepo
        self.albumRepo = albumRepo
        self.peopleRepo = peopleRepo
        self.dataManager = dataManager ?? .shared
        self.recentlyViewedStore = recentlyViewedStore
    }

    /// Ada sesuatu untuk dicari: kata kunci, penyaring, atau keduanya.
    ///
    /// Inilah yang membuat penyaring berguna untuk MENJELAJAH, bukan cuma
    /// menyempitkan hasil ketikan — memilih "Last 3 Months" dan "Videos" saja
    /// sudah menghasilkan sesuatu.
    var hasCriteria: Bool {
        !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || filters.isActive
            || options.favoritesOnly || options.editedOnly
    }

    func scheduleSearch() {
        guard let request = beginSearch() else { return }
        let startedAt = generation
        let options = options
        searchTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(300))
            } catch { return }
            await self?.performSearch(request, options: options, generation: startedAt)
        }
    }

    func search() async {
        guard let request = beginSearch() else { return }
        await performSearch(request, options: options, generation: generation)
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
        incompleteSources = []
        guard snapshotGeneration == LocalSnapshot.generation, hasCriteria else {
            phase = .idle
            return nil
        }
        phase = .loading
        var request = SearchRequestDTO(page: 1, size: 100, visibility: "timeline")
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        request.query = query.isEmpty ? nil : query
        filters.apply(to: &request)
        return request
    }

    private func performSearch(_ request: SearchRequestDTO, options: PhotoSearchOptions, generation startedAt: Int) async {
        guard startedAt == generation, snapshotGeneration == LocalSnapshot.generation else { return }
        defer { if startedAt == generation { searchTask = nil } }
        do {
            try Task.checkCancellation()
            let response = try await repo.search(request, options: options)
            try Task.checkCancellation()
            guard startedAt == generation, snapshotGeneration == LocalSnapshot.generation else { return }
            try validate(response.assets, after: 1)
            var seen = Set<String>()
            results = response.assets.items.filter {
                $0.isTimelineVisible && !removedResultIDs.contains($0.id) && seen.insert($0.id).inserted
            }
                .map(AssetLite.init)
            fetchedTotal = response.assets.nextPage == nil
                ? loadedResults.count : max(response.assets.total, loadedResults.count)
            activeRequest = request
            activeOptions = options
            incompleteSources = response.incompleteSources ?? []
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
        let options = activeOptions
        request.page = page
        do {
            try Task.checkCancellation()
            let response = try await repo.search(request, options: options)
            try Task.checkCancellation()
            guard startedAt == generation, snapshotGeneration == LocalSnapshot.generation else { return }
            try validate(response.assets, after: page)
            var seen = Set(loadedResults.map(\.id))
            let newAssets = response.assets.items.filter {
                $0.isTimelineVisible && !removedResultIDs.contains($0.id) && seen.insert($0.id).inserted
            }
                .map(AssetLite.init)
            loadedResults.append(contentsOf: newAssets)
            fetchedTotal = response.assets.nextPage == nil
                ? loadedResults.count : max(fetchedTotal, response.assets.total, loadedResults.count)
            currentPage = page
            self.nextPage = response.assets.nextPage
            incompleteSources = response.incompleteSources ?? []
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

    var isCurrent: Bool { snapshotGeneration == LocalSnapshot.generation }

    var tokens: [SearchToken] {
        get {
            guard isCurrent else { return [] }
            var tokens = filters.people.map(SearchToken.person)
            if let city = filters.city { tokens.append(.city(city)) }
            if let state = filters.state { tokens.append(.state(state)) }
            if let country = filters.country { tokens.append(.country(country)) }
            if let date = filters.dateRange { tokens.append(.date(date)) }
            if filters.mediaType != .all { tokens.append(.media(filters.mediaType)) }
            if let album = filters.album { tokens.append(.album(album)) }
            return tokens
        }
        set { setTokens(newValue) }
    }

    var matchingPeople: [PersonDTO] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isCurrent, !query.isEmpty else { return [] }
        return people.filter { !$0.isHidden && !$0.name.isEmpty && SearchSuggestions.matches(query, title: $0.name) }
    }

    var matchingAlbums: [AlbumResponseDTO] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isCurrent, !query.isEmpty else { return [] }
        return albums.filter { SearchSuggestions.matches(query, title: $0.albumName)
            || $0.description.map { SearchSuggestions.matches(query, title: $0) } == true }
    }

    func suggestedTokens(for query: String) -> [SearchToken] {
        guard isCurrent else { return [] }
        return SearchSuggestions.tokens(for: query, people: people, cities: cities, states: states,
            countries: countries, albums: albums, selected: tokens)
    }

    func setTokens(_ tokens: [SearchToken]) {
        guard isCurrent else { return }
        var updated = SearchFilters()
        for token in tokens { _ = apply(token, to: &updated) }
        guard updated != filters else { filters = updated; return }
        filters = updated
        scheduleSearch()
    }

    @discardableResult
    func applySuggestion(_ token: SearchToken, consuming query: String, now: Date = .now,
                         calendar: Calendar = .current, locale: Locale = .current) -> String {
        guard isCurrent else { return searchText }
        var updated = filters
        guard apply(token, to: &updated) else { return searchText }
        filters = updated
        if searchText == query {
            searchText = SearchSuggestions.remainingQuery(query, after: token, now: now, calendar: calendar, locale: locale)
        }
        scheduleSearch()
        return searchText
    }

    @discardableResult
    func commitSearchText(_ text: String, now: Date = .now, calendar: Calendar = .current,
                          locale: Locale = .current) -> String {
        guard isCurrent else { return searchText }
        searchText = text
        let query = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let names = people.map(\.name) + filters.people.map(\.name) + albums.map(\.albumName)
            + (filters.album.map { [$0.albumName] } ?? []) + cities + states + countries
        guard !names.contains(where: { SearchSuggestions.exactlyMatches(query, title: $0, locale: locale) }),
              let token = SearchSuggestions.committedToken(for: query, now: now, calendar: calendar, locale: locale) else { return text }
        return applySuggestion(token, consuming: text, now: now, calendar: calendar, locale: locale)
    }

    private func apply(_ token: SearchToken, to filters: inout SearchFilters) -> Bool {
        switch token {
        case .person(let candidate):
            let person = people.first { $0.id == candidate.id } ?? self.filters.people.first { $0.id == candidate.id }
            guard let person, !person.isHidden else { return false }
            if !filters.people.contains(where: { $0.id == person.id }) { filters.people.append(person) }
        case .city(let city): filters.city = city
        case .state(let state): filters.state = state
        case .country(let country): filters.country = country
        case .date(let date): filters.dateRange = date
        case .media(let media): filters.mediaType = media
        case .album(let candidate):
            guard let album = albums.first(where: { $0.id == candidate.id })
                ?? (self.filters.album?.id == candidate.id ? self.filters.album : nil) else { return false }
            filters.album = album
        }
        return true
    }

    func loadFilterOptions(force: Bool = false) async {
        reconcilePeopleSnapshot()
        async let people: Void = loadOption(.people, force: force, fetch: { try await self.peopleRepo?.all() ?? [] }) {
            self.acceptPeople($0, authoritative: true)
        }
        async let cities: Void = loadOption(.cities, force: force, fetch: { try await self.repo.suggestions(type: "city") }) {
            self.cities = Self.uniqueSuggestions($0)
        }
        async let states: Void = loadOption(.states, force: force, fetch: { try await self.repo.suggestions(type: "state") }) {
            self.states = Self.uniqueSuggestions($0)
        }
        async let countries: Void = loadOption(.countries, force: force, fetch: { try await self.repo.suggestions(type: "country") }) {
            self.countries = Self.uniqueSuggestions($0)
        }
        async let albums: Void = loadOption(.albums, force: force, fetch: { try await self.albumRepo.all() }) {
            self.albums = $0
            if let selected = self.filters.album { self.filters.album = $0.first { $0.id == selected.id } }
        }
        _ = await (people, cities, states, countries, albums)
    }

    func invalidateLocationOptions() {
        guard isCurrent else { return }
        cities = []
        states = []
        countries = []
        for source in [OptionSource.cities, .states, .countries] {
            loadedOptionSources.remove(source)
            optionRequests[source] = nil
            optionErrors.remove(source)
        }
    }

    private func loadOption<Value>(_ source: OptionSource, force: Bool,
                                   fetch: @MainActor () async throws -> Value, accept: @MainActor (Value) -> Void) async {
        guard isCurrent, !Task.isCancelled, force || (!loadedOptionSources.contains(source) && optionRequests[source] == nil) else { return }
        let request = UUID()
        let peopleRevision = LocalSnapshot.invalidationRevision(for: LocalSnapshot.Key.peopleList)
        let visibilityState = AssetVisibilityPolicy(scope: .timeline, dataManager: dataManager).state
        optionRequests[source] = request
        loadedOptionSources.remove(source)
        optionErrors.remove(source)
        defer { if optionRequests[source] == request { optionRequests[source] = nil } }
        do {
            let value = try await fetch()
            guard isCurrent, !Task.isCancelled, optionRequests[source] == request,
                  source != .people || peopleRevision == LocalSnapshot.invalidationRevision(for: LocalSnapshot.Key.peopleList),
                  !source.isLocation || visibilityState == AssetVisibilityPolicy(scope: .timeline, dataManager: dataManager).state else { return }
            let previous = filters
            accept(value)
            loadedOptionSources.insert(source)
            if previous != filters { scheduleSearch() }
        } catch {
            guard isCurrent, !Task.isCancelled, !(error is CancellationError), optionRequests[source] == request,
                  !source.isLocation || visibilityState == AssetVisibilityPolicy(scope: .timeline, dataManager: dataManager).state else { return }
            if source == .people { reconcilePeopleSnapshot() }
            optionErrors.insert(source)
        }
    }

    private func reconcilePeopleSnapshot() {
        guard isCurrent, !Task.isCancelled,
              peopleDirectoryRevision != LocalSnapshot.invalidationRevision(for: LocalSnapshot.Key.peopleList) else { return }
        guard let current = LocalSnapshot.load([PersonDTO].self, for: LocalSnapshot.Key.peopleList) else {
            let revision = LocalSnapshot.invalidationRevision(for: LocalSnapshot.Key.peopleList)
            let confirmed = people.filter { confirmedPeopleRevisions[$0.id] == revision }
            people = confirmed
            loadedOptionSources.remove(.people)
            // Missing cache data cannot justify dropping a selected criterion,
            // but its old identity label is no longer confirmed for suggestions.
            filters.people = filters.people.map { person in
                if let current = confirmed.first(where: { $0.id == person.id }) { return current }
                var pending = person
                pending.name = String(localized: "1 Person")
                return pending
            }
            return
        }
        let previous = filters
        acceptPeople(current, authoritative: true)
        if previous != filters { scheduleSearch() }
    }

    private func acceptPeople(_ directory: [PersonDTO], authoritative: Bool = false) {
        if authoritative {
            peopleDirectoryRevision = LocalSnapshot.invalidationRevision(for: LocalSnapshot.Key.peopleList)
            confirmedPeopleRevisions.removeAll()
            let previousIDs = knownPeopleIDs.union(people.map(\.id)).union(filters.people.map(\.id))
            knownPeopleIDs = Set(directory.map(\.id))
            hiddenPeopleIDs.formUnion(previousIDs.subtracting(knownPeopleIDs))
            hiddenPeopleIDs.subtract(directory.filter { !$0.isHidden }.map(\.id))
            hiddenPeopleIDs.formUnion(directory.filter(\.isHidden).map(\.id))
        }
        var seen = Set<String>()
        people = directory.filter { !$0.isHidden && !hiddenPeopleIDs.contains($0.id) && seen.insert($0.id).inserted }
        let available = Dictionary(people.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        filters.people = filters.people.compactMap { available[$0.id] }
    }

    func applyPersonUpdate(_ update: PersonUpdate) {
        guard isCurrent else { return }
        if update.fields.contains(.hidden) {
            if update.person.isHidden { hiddenPeopleIDs.insert(update.person.id) }
            else { hiddenPeopleIDs.remove(update.person.id) }
        } else if hiddenPeopleIDs.contains(update.person.id) { return }
        optionRequests[.people] = nil
        let revision = LocalSnapshot.invalidationRevision(for: LocalSnapshot.Key.peopleList)
        confirmedPeopleRevisions = confirmedPeopleRevisions.filter { $0.value == revision }
        confirmedPeopleRevisions[update.person.id] = revision
        knownPeopleIDs.insert(update.person.id)
        let previous = filters
        if let index = people.firstIndex(where: { $0.id == update.person.id }) {
            people[index] = update.applying(to: people[index])
        } else if !update.person.isHidden { people.append(update.person) }
        acceptPeople(people)
        if previous != filters { scheduleSearch() }
    }

    func applyAlbumUpdate(_ album: AlbumResponseDTO) {
        guard isCurrent else { return }
        optionRequests[.albums] = nil
        if let index = albums.firstIndex(where: { $0.id == album.id }) { albums[index] = album }
        else { albums.append(album) }
        if filters.album?.id == album.id { filters.album = album }
    }

    func removeAlbum(_ id: String) {
        guard isCurrent else { return }
        optionRequests[.albums] = nil
        albums.removeAll { $0.id == id }
        if filters.album?.id == id { filters.album = nil; scheduleSearch() }
    }

    private static func uniqueSuggestions(_ values: [String]) -> [String] {
        Array(Set(values.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })).sorted {
            $0.localizedStandardCompare($1) == .orderedAscending
        }
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
        recentlyViewedStore?.updateFavorite(id, to: value)
        if activeOptions.favoritesOnly, !value { removeLocally([id]); return }
        if activeOptions.favoritesOnly, value, removedResultIDs.contains(id) { scheduleSearch(); return }
        guard let index = loadedResults.firstIndex(where: { $0.id == id }) else { return }
        loadedResults[index].isFavorite = value
    }

    /// `fallback` sudah berupa `String` yang dilokalkan di titik panggilnya,
    /// bukan `LocalizationValue` yang dilokalkan di sini: alat ekstraksi string
    /// hanya melihat literal yang berada langsung di dalam `String(localized:)`.
    private func message(_ error: Error, fallback: String) -> String {
        (error as? LocalizedError)?.errorDescription ?? fallback
    }

}
