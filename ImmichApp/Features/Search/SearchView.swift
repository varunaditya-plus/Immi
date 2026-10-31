import SwiftUI

struct SearchView: View {
    let isActive: Bool
    private let initialTokens: [SearchToken]
    private let onClose: (() -> Void)?
    @Environment(SessionManager.self) private var session
    @State private var vm: SearchViewModel?
    @State private var searchText = ""
    @FocusState private var isSearchFocused: Bool
    @State private var didRequestInitialFocus = false
    @State private var resultKind = SearchResultKind.photos
    @State private var querySubmitted = false
    @State private var destination: SearchCollectionDestination?
    @State private var recentlyViewedStore: RecentlyViewedStore?
    @State private var groups: PeopleGroupsStore?
    @State private var organization: AlbumsOrganizationStore?
    @State private var showsIncompleteSearch = false
    @State private var isSelecting = false
    @State private var selectedIDs: Set<String> = []
    @State private var sharePreparation = SharePreparation()
    @State private var copyPreparation = MediaCopyPreparation()
    @State private var slideshow: PhotoSlideshowPresentation?
    private var isPreparingShare: Bool { sharePreparation.isPreparing }
    @State private var isPerformingAction = false
    @State private var shareURLs: [URL] = []
    @State private var sharedAssetIDs: [String] = []
    @State private var sharedSourceIDs: [String] = []
    @State private var sharedRequestContext: SessionRequestContext?
    @State private var isSharePresented = false
    @State private var albumPicker: SelectedAssets?
    @State private var selectionLink: SharedLinkPresentation?
    @State private var linkedAssetIDs: [String] = []
    @State private var pendingDelete: SelectedAssets?
    @State private var deleteFeedback = 0
    @State private var favoriteFeedback = 0

    init(isActive: Bool, viewModel: SearchViewModel? = nil, recentlyViewedStore: RecentlyViewedStore? = nil,
         initialTokens: [SearchToken] = [], onClose: (() -> Void)? = nil) {
        self.isActive = isActive
        self.initialTokens = initialTokens
        self.onClose = onClose
        _vm = State(initialValue: viewModel)
        _searchText = State(initialValue: viewModel?.searchText ?? "")
        _recentlyViewedStore = State(initialValue: recentlyViewedStore)
    }

    var body: some View {
        NavigationStack {
            content
                .toolbar { searchToolbar }
                .toolbarBackground(.hidden, for: .navigationBar)
                .toolbar(isSelecting ? .hidden : .automatic, for: .tabBar)
                .toolbar(isSelecting ? .visible : .hidden, for: .bottomBar)
                .overlay { presentations }
                .sheet(item: $destination, onDismiss: refreshAfterCollection) { collectionDestination($0) }
                // UIKit caches native search/dialog callbacks after unmount; capture only weak models and needed bindings.
                .alert("Some Results May Not Appear", isPresented: $showsIncompleteSearch) { [weak model = vm] in
                    Button("Retry") {
                        Task {
                            await model?.loadFilterOptions(force: true)
                            await model?.search()
                        }
                    }
                    Button("OK", role: .cancel) {}
                } message: {
                    Text("Some search services could not complete. Retry to include all available matches.")
                }
                .onChange(of: visibilityPolicy.state) { _, _ in
                    vm?.invalidateLocationOptions()
                    if isActive { Task { await vm?.loadFilterOptions() } }
                    if !sharedAssetIDs.allSatisfy({ visibilityPolicy.allows(id: $0) }) {
                        isSharePresented = false
                        cleanupPreparedShare()
                    }
                    if !linkedAssetIDs.allSatisfy({ visibilityPolicy.allows(id: $0) }) {
                        selectionLink = nil
                        linkedAssetIDs.removeAll()
                    }
                }
                .onChange(of: resultKind) { _, kind in
                    if kind == .collections { isSearchFocused = false }
                }
                .onChange(of: vm?.hasCriteria ?? false) { _, hasCriteria in
                    if !hasCriteria { resultKind = .photos }
                }
                .onChange(of: searchText) { _, text in
                    guard let vm, vm.searchText != text else { return }
                    querySubmitted = false
                    vm.searchText = text
                    vm.scheduleSearch()
                }
                .onChange(of: vm?.results ?? []) { _, results in
                    guard isSelecting else { return }
                    guard !results.isEmpty else { exitSelection(); return }
                    selectedIDs.formIntersection(Set(results.map(\.id)))
                }
                .task(id: SearchOptionsRefreshKey(isActive: isActive,
                    peopleRevision: LocalSnapshot.invalidationRevision(for: LocalSnapshot.Key.peopleList))) {
                    guard isActive else { return }
                    configure()
                    await vm?.loadFilterOptions(force: true)
                }
        }
        .sensoryFeedback(.impact(weight: .heavy), trigger: deleteFeedback)
        .sensoryFeedback(.success, trigger: favoriteFeedback)
        .onDisappear {
            isSearchFocused = false
            sharePreparation.cancel()
            copyPreparation.cancel()
        }
        // Keep searchable on the stack so the Search tab owns one bottom field,
        // including after the modal photo viewer returns.
        .searchable(text: $searchText, tokens: tokensBinding, prompt: "Search your library…") { token in
            Label(token.title, systemImage: token.systemImage)
        }
        .searchSuggestions {
            if let vm, isSearchFocused, resultKind == .photos {
                ForEach(Array(vm.suggestedTokens(for: searchText).prefix(12))) { token in
                    Button {
                        searchText = vm.applySuggestion(token, consuming: searchText)
                    } label: {
                        Label(token.title, systemImage: token.systemImage)
                    }
                }
            }
        }
        .searchFocused($isSearchFocused)
        .onSubmit(of: .search) { [weak model = vm, query = $searchText,
            submitted = $querySubmitted, focused = $isSearchFocused] in
            if let model { query.wrappedValue = model.commitSearchText(query.wrappedValue) }
            submitted.wrappedValue = true
            focused.wrappedValue = false
            Task { await model?.search() }
        }
        .task(id: isActive) {
            if #available(iOS 27.0, *) { return }
            guard isActive, !didRequestInitialFocus else {
                if !isActive { isSearchFocused = false }
                return
            }
            // The Search tab must finish expanding before becoming first responder.
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled, isActive else { return }
            didRequestInitialFocus = true
            isSearchFocused = true
        }
        .searchPresentationToolbarBehavior(.avoidHidingContent)
    }

    private func configure() {
        if recentlyViewedStore == nil { recentlyViewedStore = RecentlyViewedStore.forAccount(session.accountOwner) }
        if vm == nil {
            let api = APIClient(session: session)
            vm = SearchViewModel(repo: PhotoSearchRepository(api: api),
                assetRepo: AssetDetailRepository(api: api), albumRepo: AlbumRepository(api: api),
                peopleRepo: PeopleRepository(api: api), recentlyViewedStore: recentlyViewedStore)
            vm?.searchText = searchText
            vm?.people = initialTokens.compactMap { if case .person(let person) = $0 { person } else { nil } }
            vm?.albums = initialTokens.compactMap { if case .album(let album) = $0 { album } else { nil } }
            if !initialTokens.isEmpty { vm?.setTokens(initialTokens) }
            else if vm?.hasCriteria == true { vm?.scheduleSearch() }
        }
        groups = PeopleGroupsStore(owner: session.accountOwner)
        organization = AlbumsOrganizationStore(owner: session.accountOwner)
    }

    private var tokensBinding: Binding<[SearchToken]> {
        Binding(get: { [weak model = vm] in model?.tokens ?? [] }, set: { [weak model = vm] in model?.tokens = $0 })
    }

    private var filtersBinding: Binding<SearchFilters> {
        Binding(get: { [weak model = vm] in model?.filters ?? .init() }, set: { [weak model = vm] in
            model?.filters = $0
            model?.scheduleSearch()
        })
    }

    private var matchingGroups: [PeopleGroup] {
        guard let vm, vm.isCurrent, !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [] }
        return (groups?.groups ?? []).filter {
            $0.isAvailable(in: vm.people) && SearchSuggestions.matches(searchText, title: $0.title(in: vm.people))
        }
    }

    private var matchingFolders: [AlbumFolder] {
        guard let vm, vm.isCurrent, organization?.isCurrent == true,
              !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [] }
        return (organization?.value.folders ?? []).filter { SearchSuggestions.matches(searchText, title: $0.name) }
    }

    private var collectionCount: Int {
        (vm?.matchingPeople.count ?? 0) + (vm?.matchingAlbums.count ?? 0) + matchingGroups.count + matchingFolders.count
    }

    @ViewBuilder private var content: some View {
        if let vm {
            VStack(spacing: 0) {
                if !vm.incompleteSources.isEmpty || (resultKind == .collections && vm.optionsError != nil) {
                    Button { showsIncompleteSearch = true } label: {
                        HStack(spacing: 5) {
                            Text("Some Results May Not Appear").font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
                            Image(systemName: "info.circle")
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(.plain).padding(.horizontal, 16).padding(.bottom, 12)
                }
                if vm.hasCriteria {
                    if !isSelecting {
                        Picker("Search Results", selection: $resultKind) {
                            Group {
                                if case .loaded = vm.phase { Text("Photos (\(vm.totalResults))") }
                                else { Text("Photos") }
                            }.tag(SearchResultKind.photos)
                            Group {
                                if vm.isLoadingOptions { Text("Collections") }
                                else { Text("Collections (\(collectionCount))") }
                            }.tag(SearchResultKind.collections)
                        }
                        .pickerStyle(.segmented)
                        .padding(6)
                        .background(.regularMaterial, in: .capsule)
                        .padding(.horizontal, 16).padding(.bottom, 10)
                    }
                    if resultKind == .collections {
                        SearchCollectionResultsView(people: vm.matchingPeople, albums: vm.matchingAlbums,
                            groups: matchingGroups, folders: matchingFolders, allPeople: vm.people,
                            isLoading: vm.isLoadingOptions, error: vm.optionsError,
                            onRetry: { Task { await vm.loadFilterOptions() } }, onOpen: { destination = $0 })
                    } else {
                        if !querySubmitted, !vm.results.isEmpty {
                            Text("Top Results").font(.headline).frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 16).padding(.bottom, 8)
                        }
                        results(vm, isSelecting: $isSelecting, selectedIDs: $selectedIDs)
                    }
                } else {
                    results(vm, isSelecting: $isSelecting, selectedIDs: $selectedIDs)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ViewBuilder
    func results(_ vm: SearchViewModel, isSelecting: Binding<Bool>, selectedIDs: Binding<Set<String>>) -> some View {
        if !vm.hasCriteria {
            SearchDiscoveryView(people: vm.people, cities: vm.cities, recentStore: recentlyViewedStore,
                isLoading: vm.isLoadingOptions, error: vm.optionsError,
                onSuggestion: { token in searchText = vm.applySuggestion(token, consuming: searchText) },
                onRecent: { destination = .recentlyViewed }, onRetry: { Task { await vm.loadFilterOptions() } })
        } else {
            switch vm.phase {
            case .idle, .loading: ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            case .loaded:
                Group {
                    if vm.results.isEmpty, vm.nextPage == nil { noResultsState }
                    else {
                        SearchResultsGrid(assets: vm.results, isSelecting: isSelecting, selectedIDs: selectedIDs,
                            actions: assetActions, onReachEnd: { Task { await vm.loadMore() } },
                            onOpen: { _ in sharePreparation.cancel(); copyPreparation.cancel() })
                    }
                }
                .safeAreaInset(edge: .bottom, spacing: 0) { paginationFooter(vm) }
            case .failed(let error): errorState(error, vm)
            }
        }
    }

    @ViewBuilder private func paginationFooter(_ vm: SearchViewModel) -> some View {
        if vm.nextPage != nil {
            VStack(spacing: 6) {
                if vm.isLoadingMore { HStack(spacing: 8) { ProgressView(); Text("Loading More…").font(.footnote) } }
                else if let error = vm.paginationError {
                    Text(error).font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center).lineLimit(2)
                    Button("Retry") { Task { await vm.retryLoadMore() } }
                } else { Button("Load More") { Task { await vm.loadMore() } } }
            }
            .frame(maxWidth: .infinity).padding(.horizontal, 16).padding(.vertical, 10).background(.bar)
        }
    }

    private var noResultsState: some View {
        ContentUnavailableView("No Results", systemImage: "magnifyingglass",
            description: Text("Try a different search."))
    }

    private func errorState(_ error: String, _ vm: SearchViewModel) -> some View {
        ContentUnavailableView {
            Label("Search Failed", systemImage: "exclamationmark.triangle")
        } description: { Text(error) } actions: {
            Button("Retry") { Task { await vm.search() } }.buttonStyle(.borderedProminent)
        }
    }

    @ToolbarContentBuilder private var searchToolbar: some ToolbarContent {
        if !isSelecting {
            if let onClose {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close", systemImage: "xmark", action: onClose).labelStyle(.iconOnly)
                }
            }
            ToolbarItem(placement: .topBarLeading) {
                Text("Search").font(.largeTitle.bold()).fixedSize().accessibilityAddTraits(.isHeader)
            }.sharedBackgroundVisibility(.hidden)
            if let vm, vm.hasCriteria {
                ToolbarItem(placement: .topBarTrailing) { searchMenu(vm) }
                ToolbarItem(placement: .topBarTrailing) { selectButton.disabled(!hasResults || resultKind != .photos) }
            }
        } else {
            ToolbarItem(placement: .topBarTrailing) { selectButton }
            ToolbarItem(placement: .principal) { Text(selectionTitle).font(.headline).fixedSize() }
                .sharedBackgroundVisibility(.hidden)
            SelectionToolbar(actions: selectionActions)
        }
    }

    private func searchMenu(_ vm: SearchViewModel) -> some View {
        Menu {
            Picker("Sort", selection: Binding(get: { vm.options.sortOrder }, set: { updateOptions(vm, sort: $0) })) {
                Text("Sort by Recently Added").tag(LibrarySort.recentlyAdded)
                Text("Sort by Date Captured").tag(LibrarySort.dateCaptured)
            }
            Menu("Filter", systemImage: "line.3.horizontal.decrease") {
                Button { updateOptions(vm, favorites: false, edited: false) } label: {
                    if !vm.options.favoritesOnly && !vm.options.editedOnly { Label("All", systemImage: "checkmark") }
                    else { Text("All") }
                }
                Toggle("Favorites", isOn: Binding(get: { vm.options.favoritesOnly }, set: { updateOptions(vm, favorites: $0) }))
                Toggle("Edited", isOn: Binding(get: { vm.options.editedOnly }, set: { updateOptions(vm, edited: $0) }))
            }
            SearchFilterMenu(filters: filtersBinding, people: vm.people, cities: vm.cities)
            if vm.filters.isActive || vm.options.favoritesOnly || vm.options.editedOnly {
                Button("Clear Filters", systemImage: "xmark") {
                    vm.filters = .init()
                    let old = vm.options
                    vm.options = .init(sortOrder: old.sortOrder)
                    vm.scheduleSearch()
                }
            }
        } label: { Image(systemName: "ellipsis") }
        .accessibilityLabel("More")
    }

    private func updateOptions(_ vm: SearchViewModel, sort: LibrarySort? = nil, favorites: Bool? = nil, edited: Bool? = nil) {
        let old = vm.options
        vm.options = .init(sortOrder: sort ?? old.sortOrder,
            favoritesOnly: favorites ?? old.favoritesOnly, editedOnly: edited ?? old.editedOnly)
        vm.scheduleSearch()
    }

    private var hasResults: Bool {
        guard let vm, case .loaded = vm.phase else { return false }
        return !vm.results.isEmpty
    }

    private var selectButton: some View {
        Button {
            if isSelecting { exitSelection() } else { isSelecting = true; isSearchFocused = false }
        } label: {
            if isSelecting { Image(systemName: "xmark").font(.body.weight(.semibold)) }
            else { Text("Select") }
        }
        .accessibilityLabel(isSelecting ? Text("Close") : Text("Select"))
    }

    private var selectionTitle: String {
        let count = selectedIDs.count
        if count == 0 { return String(localized: "Select Items") }
        if count == 1 { return String(localized: "1 Item Selected") }
        return String(localized: "\(count) Items Selected")
    }

    private func refreshAfterCollection() {
        groups = PeopleGroupsStore(owner: session.accountOwner)
        organization = AlbumsOrganizationStore(owner: session.accountOwner)
        Task { await vm?.loadFilterOptions(force: true) }
    }

    @ViewBuilder private func collectionDestination(_ destination: SearchCollectionDestination) -> some View {
        NavigationStack {
            Group {
                switch destination {
                case .album(let album):
                    AlbumDetailView(album: album, onAlbumChanged: { vm?.applyAlbumUpdate($0) },
                        onDeleted: { vm?.removeAlbum(album.id) })
                case .person(let person):
                    PersonDetailView(person: person, repo: PeopleRepository(api: APIClient(session: session)),
                        onPersonUpdated: { vm?.applyPersonUpdate($0) })
                case .group(let group):
                    if let groups, let vm { PeopleGroupDetailView(groupID: group.id, people: vm.people, store: groups) }
                case .folder(let folder):
                    AlbumsListView(onAlbumUpdated: { vm?.applyAlbumUpdate($0) },
                        onAlbumDeleted: { vm?.removeAlbum($0) }, organizationStore: organization, folderID: folder.id)
                case .recentlyViewed:
                    if let recentlyViewedStore { RecentlyViewedCollectionView(store: recentlyViewedStore) }
                }
            }
            .toolbar { ToolbarItem(placement: .topBarLeading) { Button("Close", systemImage: "xmark") { self.destination = nil } } }
        }
    }

    private var selectionActions: SelectionActions {
        let ids = (vm?.results ?? []).filter { selectedIDs.contains($0.id) }.map(\.id)
        var actions = SelectionActions()
        actions.isBusy = isPreparingShare || copyPreparation.isPreparing || isPerformingAction || selectedIDs.isEmpty
        actions.share = { share(ids) }
        actions.favorite = {
            runSelection {
                let succeeded = await vm?.setFavorite(ids, to: true) ?? false
                if succeeded { favoriteFeedback += 1 }
                return succeeded
            }
        }
        actions.archive = { runSelection { await vm?.archive(ids) ?? false } }
        actions.trash = { pendingDelete = SelectedAssets(ids: ids) }
        actions.menu = [
            SelectionMenuAction(title: "Copy", systemImage: "document.on.document") { copyAssets(ids) },
            SelectionMenuAction(title: "Slideshow", systemImage: "play.rectangle") {
                slideshow = PhotoSlideshowPresentation(assets: (vm?.results ?? []).filter { ids.contains($0.id) })
            },
            SelectionMenuAction(title: "Share Link", systemImage: "link") {
                createSharedLink(for: ids)
            },
            SelectionMenuAction(
                title: "Add to Album",
                systemImage: "rectangle.stack.badge.plus"
            ) {
                albumPicker = SelectedAssets(ids: ids)
            },
        ]
        return actions
    }

    private var assetActions: SearchAssetActions {
        SearchAssetActions(
            share: { share([$0.id]) },
            copy: { copyAssets([$0.id]) },
            slideshow: { slideshow = PhotoSlideshowPresentation(assets: vm?.results ?? [], initialAssetID: $0.id) },
            toggleFavorite: { asset in
                Task {
                    if await vm?.toggleFavorite(asset) == true { favoriteFeedback += 1 }
                }
            },
            archive: { asset in Task { await vm?.archive([asset.id]) } },
            addToAlbum: { albumPicker = SelectedAssets(ids: [$0.id]) },
            delete: { pendingDelete = SelectedAssets(ids: [$0.id]) },
            assetRemoved: { vm?.removeLocally([$0]) },
            favoriteChanged: { vm?.patchFavorite($0, to: $1) },
            assetUpdated: { _ in Task { await vm?.search() } })
    }

    private func runSelection(_ work: @escaping () async -> Bool) {
        guard !isPerformingAction else { return }
        isPerformingAction = true
        Task {
            defer { isPerformingAction = false }
            if await work() {
                exitSelection()
            } else {
                selectedIDs.formIntersection(Set(vm?.results.map(\.id) ?? []))
            }
        }
    }

    private func exitSelection() {
        sharePreparation.cancel()
        copyPreparation.cancel()
        isSelecting = false
        selectedIDs.removeAll()
    }

    private var visibilityPolicy: AssetVisibilityPolicy { AssetVisibilityPolicy(scope: .timeline) }

    private func share(_ ids: [String]) {
        guard !isSharePresented else { return }
        sharePreparation.start(ids: ids, session: session, prepare: { await vm?.shareURLs(for: $0) ?? [] },
            isAllowed: { visibilityPolicy.allows(id: $0) },
            onError: { vm?.actionError = $0 }) { urls in
            shareURLs = urls
            sharedAssetIDs = ids
            sharedSourceIDs = sharePreparation.preparedSourceIDs
            sharedRequestContext = sharePreparation.preparedContext
            isSharePresented = true
        }
    }

    private func copyAssets(_ ids: [String]) {
        let api = APIClient(session: session), context = session.snapshot
        let assets = vm?.results.filter { ids.contains($0.id) } ?? []
        let media = Dictionary(assets.map { ($0.id, $0.isVideo) }, uniquingKeysWith: { _, value in value })
        guard media.count == ids.count else { return }
        copyPreparation.start(ids: ids, prepare: { ids in
            let urls = await vm?.shareURLs(for: ids) ?? []
            guard urls.count == ids.count else { TemporaryMediaStore.remove(urls); return [] }
            return zip(ids, urls).map { MediaCopy.Source(url: $0.1, isVideo: media[$0.0] == true) }
        }, isAllowed: { (try? api.checkCurrent(context)) != nil && visibilityPolicy.allows(id: $0) },
            onError: { vm?.actionError = $0 })
    }

    private func cleanupPreparedShare() {
        TemporaryMediaStore.remove(shareURLs)
        shareURLs.removeAll()
        sharedAssetIDs.removeAll()
        sharedSourceIDs.removeAll()
        sharedRequestContext = nil
    }

    private func createSharedLink(for ids: [String]) {
        guard !ids.isEmpty, ids.allSatisfy({ visibilityPolicy.allows(id: $0) }) else { return }
        let generation = LocalSnapshot.generation
        let repo = SharedLinkRepository(api: APIClient(session: session))
        Task {
            guard !Task.isCancelled, generation == LocalSnapshot.generation,
                  ids.allSatisfy({ visibilityPolicy.allows(id: $0) }) else { return }
            guard let link = try? await repo.create(assetIds: ids),
                  let url = link.publicURL(base: session.baseURL)
            else {
                vm?.actionError = String(localized: "Failed to create shared link")
                return
            }
            guard !Task.isCancelled, generation == LocalSnapshot.generation,
                  ids.allSatisfy({ visibilityPolicy.allows(id: $0) }) else { return }
            linkedAssetIDs = ids
            selectionLink = SharedLinkPresentation(url: url)
        }
    }

    private static func deleteTitle(_ count: Int) -> String {
        count == 1
            ? String(localized: "Delete 1 Item")
            : String(localized: "Delete \(count) Items")
    }

    // Keep the modal modifiers separate to bound SwiftUI type-checking complexity.
    private var presentations: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .sheet(isPresented: $isSharePresented, onDismiss: cleanupPreparedShare) {
                PhotoShareSheet(urls: shareURLs, assetIDs: sharedAssetIDs,
                    sourceIDs: sharedSourceIDs, requestContext: sharedRequestContext,
                    isAllowed: { [policy = visibilityPolicy] in policy.allows(id: $0) })
            }
            .fullScreenCover(item: $slideshow) { selection in
                PhotoSlideshowView(assets: selection.assets, initialAssetID: selection.initialAssetID) { asset in
                    (await vm?.shareURLs(for: [asset.id]))?.first
                }
            }
            .sheet(item: $albumPicker) { selection in
                AlbumPickerLoader { album in
                    runSelection {
                        await vm?.addToAlbum(selection.ids, album: album) ?? false
                    }
                }
            }
            .sheet(item: $selectionLink, onDismiss: { linkedAssetIDs.removeAll() }) {
                ShareSheet(url: $0.url)
            }
            .confirmationDialog(
                "Move to Trash",
                isPresented: Binding(
                    get: { [pending = $pendingDelete] in pending.wrappedValue != nil },
                    set: { [pending = $pendingDelete] in if !$0 { pending.wrappedValue = nil } }),
                titleVisibility: .visible,
                presenting: pendingDelete
            ) { [weak model = vm, pending = $pendingDelete, busy = $isPerformingAction,
                selecting = $isSelecting, selected = $selectedIDs, feedback = $deleteFeedback] selection in
                Button(Self.deleteTitle(selection.ids.count), role: .destructive) {
                    pending.wrappedValue = nil
                    guard !busy.wrappedValue else { return }
                    busy.wrappedValue = true
                    Task {
                        defer { busy.wrappedValue = false }
                        if await model?.delete(selection.ids) == true {
                            feedback.wrappedValue += 1
                            selecting.wrappedValue = false
                            selected.wrappedValue.removeAll()
                        } else {
                            selected.wrappedValue.formIntersection(Set(model?.results.map(\.id) ?? []))
                        }
                    }
                }
                Button("Cancel", role: .cancel) {}
            } message: { _ in
                Text("You can restore these items from Trash.")
            }
            .alert("Action Failed", isPresented: Binding(
                get: { [weak model = vm] in model?.actionError != nil },
                set: { [weak model = vm] in if !$0 { model?.actionError = nil } })
            ) {
                Button("OK", role: .cancel) {}
            } message: { [weak model = vm] in
                Text(model?.actionError ?? "")
            }
    }
}

private struct SearchOptionsRefreshKey: Equatable {
    let isActive: Bool
    let peopleRevision: UInt64
}

private struct SelectedAssets: Identifiable {
    let id = UUID()
    let ids: [String]
}

#Preview {
    SearchView(isActive: true)
        .environment(SessionManager())
}
