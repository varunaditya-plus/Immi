import SwiftUI

struct PeopleView: View {
    @Environment(SessionManager.self) private var session
    @State private var vm: PeopleListViewModel?
    @State private var organization: PeopleOrganizationStore?
    @State private var groupsStore: PeopleGroupsStore?
    @State private var query = ""
    @State private var isFavoriting = false
    @State private var isEditing = false
    @State private var selectedIDs: Set<String> = []
    @State private var editedPerson: PersonDTO?
    @State private var mergePerson: PersonDTO?
    @State private var showMergeConfirmation = false
    @State private var showAddPeople = false
    @State private var showHiddenPeople = false
    @State private var showReorder = false
    @State private var contentWidth: CGFloat = 390
    @Namespace private var personNamespace
    private let providedRepository: PeopleRepository?
    var onPersonUpdated: ((PersonUpdate) -> Void)? = nil
    var onPeopleMerged: ((Set<String>, String) -> Void)? = nil

    init(viewModel: PeopleListViewModel? = nil, organizationStore: PeopleOrganizationStore? = nil,
         repository: PeopleRepository? = nil,
         onPersonUpdated: ((PersonUpdate) -> Void)? = nil,
         onPeopleMerged: ((Set<String>, String) -> Void)? = nil) {
        _vm = State(initialValue: viewModel)
        _organization = State(initialValue: organizationStore)
        providedRepository = repository
        self.onPersonUpdated = onPersonUpdated
        self.onPeopleMerged = onPeopleMerged
    }

    var body: some View {
        content
            .navigationTitle("People")
            .searchable(text: $query, prompt: "Search People")
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { contentWidth = $0 }
            .toolbar { toolbar }
            .toolbar(isEditing ? .visible : .hidden, for: .bottomBar)
            .sheet(item: $editedPerson) { person in
                PersonIdentityEditor(person: person, repository: repository, onUpdated: publish)
            }
            .sheet(item: $mergePerson) { person in
                PeopleMergePicker(person: person, people: vm?.people ?? []) { sources, target in
                    await merge(sources, into: target, reportsFailure: false)
                }
            }
            .sheet(isPresented: $showAddPeople) {
                PeopleDiscoveryView(repository: repository, mode: .unnamed, onUpdated: publish)
            }
            .sheet(isPresented: $showHiddenPeople) {
                PeopleDiscoveryView(repository: repository, mode: .hidden, onUpdated: publish)
            }
            .sheet(isPresented: $showReorder) {
                PeopleReorderSheet(people: { fullOrderedPeople }) { organization?.setOrder($0) }
            }
            .alert("Action Failed", isPresented: Binding(
                get: { vm?.actionError != nil && !isPresentingSheet }, set: { if !$0 { vm?.actionError = nil } })) {
                Button("OK", role: .cancel) { vm?.actionError = nil }
            } message: { Text(vm?.actionError ?? "") }
            .onChange(of: vm?.people) { _, _ in
                selectedIDs.formIntersection(Set(orderedPeople.map(\.id)))
            }
            .onChange(of: query) { _, _ in
                selectedIDs.formIntersection(Set(orderedPeople.map(\.id)))
            }
            .task(id: session.accountGeneration) {
                if organization?.isCurrent != true { organization = PeopleOrganizationStore(owner: session.accountOwner) }
                if groupsStore?.isCurrent != true { groupsStore = PeopleGroupsStore(owner: session.accountOwner) }
                if vm?.isCurrent != true { vm = PeopleListViewModel(repo: repository) }
                await vm?.loadPeople()
            }
    }

    private var isPresentingSheet: Bool {
        editedPerson != nil || mergePerson != nil || showAddPeople || showHiddenPeople || showReorder
    }

    private var repository: PeopleRepository { providedRepository ?? PeopleRepository(api: APIClient(session: session)) }
    private var fullOrderedPeople: [PersonDTO] {
        guard vm?.isCurrent == true else { return [] }
        return (organization?.value ?? PeopleOrganization()).ordered((vm?.people ?? []).filter { !$0.isHidden })
    }
    private var orderedPeople: [PersonDTO] {
        let sorted = fullOrderedPeople
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? sorted : sorted.filter { $0.name.localizedStandardContains(trimmed) }
    }

    @ViewBuilder
    private var content: some View {
        if let vm, case .failed(let error) = vm.phase, vm.people.isEmpty {
            ContentUnavailableView {
                Label("Failed to Load", systemImage: "exclamationmark.triangle")
            } description: { Text(error) } actions: {
                Button("Retry") { Task { await vm.retry() } }
            }
        } else if vm == nil || vm?.phase.isLoading == true && vm?.people.isEmpty == true {
            ProgressView()
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    if !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        if orderedPeople.isEmpty { ContentUnavailableView.search(text: query) }
                        else { peopleGrid(orderedPeople) }
                    } else {
                        let favorites = orderedPeople.filter { $0.isFavorite == true }
                        if !favorites.isEmpty {
                            sectionTitle("Favorites")
                            peopleGrid(favorites)
                        }
                        if !isEditing, let groupsStore { PeopleGroupsSection(people: vm?.people ?? [], store: groupsStore) }
                        let others = orderedPeople.filter { $0.isFavorite != true }
                        if !others.isEmpty {
                            sectionTitle("People")
                            peopleGrid(others)
                        } else if orderedPeople.isEmpty {
                            ContentUnavailableView("No People", systemImage: "person.2.fill",
                                description: Text("Faces will appear here when detected"))
                        }
                        Button("Add People") { showAddPeople = true }
                            .font(.headline)
                            .frame(maxWidth: .infinity, minHeight: 44)
                    }
                }
                .padding(20)
            }
            .refreshable { await vm?.loadPeople() }
        }
    }

    private func sectionTitle(_ title: LocalizedStringKey) -> some View {
        Text(title).font(.title2.bold()).accessibilityAddTraits(.isHeader)
    }

    private func peopleGrid(_ people: [PersonDTO]) -> some View {
        LazyVGrid(columns: [GridItem(.flexible(), spacing: 20), GridItem(.flexible(), spacing: 20)], spacing: 24) {
            ForEach(people) { person in
                if isEditing {
                    Button {
                        if !selectedIDs.insert(person.id).inserted { selectedIDs.remove(person.id) }
                    } label: { tile(person, selected: selectedIDs.contains(person.id)) }
                    .buttonStyle(.plain)
                    .accessibilityLabel(person.displayName)
                    .accessibilityAddTraits(selectedIDs.contains(person.id) ? .isSelected : [])
                } else {
                    NavigationLink {
                        PersonDetailView(person: person, repo: repository, listVM: vm,
                            onPersonUpdated: { onPersonUpdated?($0) })
                            .navigationTransition(.zoom(sourceID: person.id, in: personNamespace))
                    } label: {
                        tile(person)
                            .matchedTransitionSource(id: person.id, in: personNamespace)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(person.displayName)
                    .accessibilityValue(person.isFavorite == true ? String(localized: "Favorite") : "")
                    .contextMenu { personActions(person) }
                    .draggable("people:\(person.id)")
                    .dropDestination(for: String.self) { values, _ in
                        guard values.count == 1, let value = values.first, value.hasPrefix("people:") else { return false }
                        return organization?.move(String(value.dropFirst(7)), before: person.id, people: vm?.people ?? []) == true
                    }
                }
            }
        }
    }

    private func tile(_ person: PersonDTO, selected: Bool? = nil) -> some View {
        VStack(spacing: 8) {
            PeoplePortrait(person: person, side: max(80, (contentWidth - 60) / 2), selected: selected)
            Text(person.displayName).font(.headline).lineLimit(2).multilineTextAlignment(.center)
        }
    }

    @ViewBuilder
    private func personActions(_ person: PersonDTO) -> some View {
        if person.isFavorite != nil {
            Button(person.isFavorite == true ? "Unfavorite" : "Favorite", systemImage: "heart") {
                Task { await setFavorite([person.id], to: person.isFavorite != true) }
            }
        }
        Button("Edit Name and Photos", systemImage: "pencil") { editedPerson = person }
        Button("Merge", systemImage: "person.2.fill") { mergePerson = person }
        Button("Hide", systemImage: "eye.slash") {
            Task {
                await vm?.setHidden(person.id, to: true)
                if let updated = vm?.people.first(where: { $0.id == person.id }), updated.isHidden { onPersonUpdated?(PersonUpdate(person: updated, fields: [.hidden])) }
            }
        }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .topBarTrailing) {
            if !isEditing {
                Menu {
                    ForEach(PeopleSort.allCases, id: \.self) { sort in
                        Button { organization?.setSort(sort) } label: {
                            if organization?.value.sort == sort { Label(sort.title, systemImage: "checkmark") }
                            else { Text(sort.title) }
                        }
                    }
                    Button("Reorder", systemImage: "arrow.up.arrow.down") { showReorder = true }
                    Button("Hidden People", systemImage: "eye.slash") { showHiddenPeople = true }
                } label: { Image(systemName: "arrow.up.arrow.down") }
                .accessibilityLabel("Sort")
            }
            Button(isEditing ? "Done" : "Edit") {
                isEditing.toggle()
                selectedIDs = []
            }
            .disabled(vm?.isMerging == true)
        }
        if isEditing {
            ToolbarItemGroup(placement: .bottomBar) {
                Button(allSelectedFavorites ? "Unfavorite" : "Favorite", systemImage: allSelectedFavorites ? "heart.slash" : "heart") {
                    let ids = Array(selectedIDs)
                    let value = !allSelectedFavorites
                    Task { await setFavorite(ids, to: value) }
                }
                .disabled(selectedIDs.isEmpty || !selectedPeople.allSatisfy { $0.isFavorite != nil }
                    || isFavoriting || vm?.isMerging == true)
                Spacer()
                Text("\(selectedIDs.count) Selected").font(.subheadline)
                Spacer()
                Button("Merge", systemImage: "person.2.fill") { showMergeConfirmation = true }
                    .disabled(selectedIDs.count < 2 || vm?.isMerging == true || isFavoriting)
                    .confirmationDialog("Merge These People?", isPresented: $showMergeConfirmation,
                        titleVisibility: .visible) {
                        Button("Merge Photos") {
                            let people = orderedPeople.filter { selectedIDs.contains($0.id) }
                            guard let target = people.first(where: { !$0.name.isEmpty }) ?? people.first else { return }
                            Task {
                                if await merge(people.map(\.id), into: target.id) {
                                    isEditing = false
                                    selectedIDs = []
                                }
                            }
                        }
                        Button("Cancel", role: .cancel) {}
                    } message: { Text("The photos will be combined into one person.") }
            }
        }
    }

    private func publish(_ update: PersonUpdate) {
        vm?.applyPersonUpdate(update)
        onPersonUpdated?(update)
    }

    private var selectedPeople: [PersonDTO] { fullOrderedPeople.filter { selectedIDs.contains($0.id) } }
    private var allSelectedFavorites: Bool { !selectedPeople.isEmpty && selectedPeople.allSatisfy { $0.isFavorite == true } }

    private func setFavorite(_ ids: [String], to value: Bool) async {
        guard !isFavoriting, !ids.isEmpty, vm?.isCurrent == true else { return }
        isFavoriting = true
        defer { isFavoriting = false }
        for id in ids {
            guard !Task.isCancelled, vm?.isCurrent == true else { break }
            let accepted = await vm?.setFavorite(id, to: value) == true
            if accepted, let person = vm?.people.first(where: { $0.id == id }) {
                onPersonUpdated?(PersonUpdate(person: person, fields: [.favorite]))
            }
            if vm?.actionError != nil { break }
        }
    }

    private func merge(_ ids: [String], into target: String, reportsFailure: Bool = true) async -> Bool {
        guard let result = await vm?.merge(ids, into: target, reportsFailure: reportsFailure) else { return false }
        if let person = vm?.people.first(where: { $0.id == target }) {
            onPersonUpdated?(PersonUpdate(person: person, fields: [.name, .thumbnail]))
        }
        if !result.acceptedIDs.isEmpty {
            groupsStore?.remapMergedPeople(result.acceptedIDs, into: target)
            onPeopleMerged?(result.acceptedIDs, target)
        }
        return result.failedIDs.isEmpty
    }
}

struct PeoplePortrait: View {
    let person: PersonDTO
    var side: CGFloat = 140
    var selected: Bool? = nil

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            Group {
                if person.thumbnailPath?.isEmpty == false {
                    AuthImage(assetId: person.id, path: "/people/\(person.id)/thumbnail")
                        .id(person.updatedAt)
                } else {
                    Circle().fill(.fill.tertiary)
                        .overlay { Image(systemName: "person.fill").font(.largeTitle).foregroundStyle(.secondary) }
                }
            }
            .frame(width: side, height: side)
            .clipShape(.circle)
            if let selected {
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .font(.title2).symbolRenderingMode(.palette).foregroundStyle(.white, .blue)
                    .padding(4).background(.regularMaterial, in: .circle)
            } else if person.isFavorite == true {
                Image(systemName: "heart.fill").font(.caption.bold()).foregroundStyle(.white)
                    .padding(8).background(.black.opacity(0.5), in: .circle)
            }
        }
        .accessibilityHidden(true)
    }
}

@MainActor
struct PersonDetailView: View {
    @State private var detail: PersonDetailState
    let repo: PeopleRepository
    private let sharedLinkRepository: SharedLinkRepository?
    var listVM: PeopleListViewModel?
    var onPersonUpdated: ((PersonUpdate) -> Void)? = nil

    @Environment(SessionManager.self) private var session
    @Environment(\.dismiss) private var dismiss
    @State private var vm: AssetGridViewModel?
    @State private var albumPickerAsset: AssetLite?
    @State private var albumPickerSelection: SelectedAssetIDs?
    @State private var sharedLink: SharedLinkPresentation?
    @State private var linkedAssetIDs: [String] = []
    @State private var reassignmentSelection: SelectedAssetIDs?
    @State private var showRenameSheet = false
    @State private var showsSearch = false
    /// Kabar singkat dari aksi — mis. "sudah ada di album ini". Toast, bukan
    /// alert: ini bukan kegagalan yang menuntut jawaban.
    @State private var actionMessage: ErrorEvent?

    init(
        person: PersonDTO, repo: PeopleRepository, listVM: PeopleListViewModel? = nil,
        onPersonUpdated: ((PersonUpdate) -> Void)? = nil, sharedLinkRepository: SharedLinkRepository? = nil
    ) {
        _detail = State(initialValue: PersonDetailState(person: person))
        self.repo = repo
        self.listVM = listVM
        self.onPersonUpdated = onPersonUpdated
        self.sharedLinkRepository = sharedLinkRepository
    }

    private var person: PersonDTO { detail.person }

    var body: some View {
        screen
            .sheet(isPresented: $showRenameSheet) {
                PersonIdentityEditor(person: person, repository: repo, detailState: detail, onUpdated: publish)
            }
            .sheet(isPresented: $showsSearch) {
                SearchView(isActive: true, initialTokens: [.person(person)], onClose: { showsSearch = false })
            }
            .sheet(item: $albumPickerAsset) { asset in
                AlbumPickerLoader { album in
                    Task {
                        if let message = await vm?.addToAlbum([asset.id], album: album) {
                            actionMessage = ErrorEvent(message)
                        }
                    }
                }
            }
            .alert("Action Failed", isPresented: .init(
                get: { detail.actionError != nil && !isPresentingSheet },
                set: { if !$0 { detail.actionError = nil } }
            )) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(detail.actionError ?? "")
            }
            .sheet(item: $albumPickerSelection) { selection in
                AlbumPickerLoader { album in
                    Task {
                        if let message = await vm?.addToAlbum(selection.ids, album: album) {
                            actionMessage = ErrorEvent(message)
                        }
                    }
                }
            }
            .sheet(item: $sharedLink, onDismiss: { linkedAssetIDs.removeAll() }) { ShareSheet(url: $0.url) }
            .sheet(item: $reassignmentSelection) { selection in
                PersonFaceReassignmentView(person: person, assetIDs: selection.ids, repository: repo,
                    assets: { vm?.assets ?? [] }) {
                    await vm?.load()
                    await listVM?.loadPeople()
                }
            }
            .errorToast($actionMessage)
            .onChange(of: visibilityPolicy.state) { _, _ in
                if !linkedAssetIDs.allSatisfy({ visibilityPolicy.allows(id: $0) }) {
                    sharedLink = nil
                    linkedAssetIDs.removeAll()
                }
            }
            .onChange(of: session.snapshot) { _, _ in
                sharedLink = nil
                linkedAssetIDs.removeAll()
            }
            .onChange(of: session.accountGeneration) { _, _ in dismiss() }
            .task { await start() }
    }

    private var isPresentingSheet: Bool {
        showRenameSheet || showsSearch || albumPickerAsset != nil || albumPickerSelection != nil
            || sharedLink != nil || reassignmentSelection != nil
    }

    @ViewBuilder
    private var screen: some View {
        if detail.isCurrent {
        PhotoCollectionScreen(
            title: LocalizedStringKey(person.displayName),
            assets: vm?.assets ?? [],
            phase: vm?.phase ?? .loading,
            actionError: Binding(
                get: { vm?.actionError },
                set: { vm?.actionError = $0 }),
            onRetry: { Task { await vm?.load() } },
            onToggleFavorite: { await vm?.toggleFavorite($0) },
            onDelete: { await vm?.delete($0) },
            shareURLs: { await vm?.shareURLs(for: $0) ?? [] },
            onAddToAlbum: { albumPickerAsset = $0 },
            onFavoriteSelection: { await vm?.setFavorite($0, to: true) },
            onArchiveSelection: { await vm?.setArchived($0, to: true) },
            onMoveToLocked: { await vm?.setLocked($0) },
            onShareLink: { createSharedLink(for: $0) },
            visibilityScope: .timeline,
            facePersonID: person.id,
            selectionMenu: selectionMenu,
            options: { personMenu })
        } else { ProgressView() }
    }

    /// Menu elipsis mode pilih — isinya sama dengan Photos.
    ///
    /// "Move to Locked Folder" tidak ikut di sini: `PhotoCollectionScreen`
    /// menambahkannya sendiri dari `onMoveToLocked`, supaya semua layar yang
    /// punya aksi itu memakai satu susunan yang sama.
    private func selectionMenu(_ ids: Set<String>) -> [SelectionMenuAction] {
        var actions: [SelectionMenuAction] = [
            SelectionMenuAction(title: "Share Link", systemImage: "link") {
                createSharedLink(for: Array(ids))
            },
            SelectionMenuAction(
                title: "Add to Album",
                systemImage: "rectangle.stack.badge.plus"
            ) {
                albumPickerSelection = SelectedAssetIDs(ids: Array(ids))
            },
        ]
        if ids.count == 1, let id = ids.first {
            actions.append(SelectionMenuAction(title: "Make Key Photo", systemImage: "person.crop.square") {
                Task {
                    if let error = await detail.chooseKeyPhoto(id, from: vm?.assets ?? [], using: repo, onUpdated: publish) {
                        detail.actionError = error
                    }
                }
            })
        }
        actions.append(SelectionMenuAction(title: "This is Not \(person.displayName)", systemImage: "person.crop.circle.badge.xmark") {
            reassignmentSelection = SelectedAssetIDs(ids: Array(ids))
        })
        return actions
    }

    private func createSharedLink(for ids: [String]) {
        guard !ids.isEmpty else { return }
        let generation = LocalSnapshot.generation
        let context = session.snapshot
        let repo = sharedLinkRepository ?? SharedLinkRepository(api: APIClient(session: session))
        let isAllowed = {
            !Task.isCancelled && detail.isCurrent && generation == LocalSnapshot.generation
                && session.snapshot == context && ids.allSatisfy { visibilityPolicy.allows(id: $0) }
        }
        Task {
            guard isAllowed() else { return }
            vm?.actionError = nil
            do {
                let link = try await repo.create(assetIds: ids)
                guard isAllowed() else { return }
                guard let url = link.publicURL(base: context.baseURL) else {
                    vm?.actionError = String(localized: "Failed to create shared link")
                    return
                }
                linkedAssetIDs = ids
                sharedLink = SharedLinkPresentation(url: url)
            } catch {
                guard isAllowed() else { return }
                vm?.actionError = (error as? APIError)?.errorDescription
                    ?? String(localized: "Failed to create shared link")
            }
        }
    }

    private var visibilityPolicy: AssetVisibilityPolicy { AssetVisibilityPolicy(scope: .timeline) }

    @ViewBuilder
    private var personMenu: some View {
        if !person.isHidden {
            Button("Search", systemImage: "magnifyingglass") { showsSearch = true }
        }
        Button {
            detail.renameDraft = person.name
            showRenameSheet = true
        } label: {
            Label("Edit Name and Photos", systemImage: "pencil")
        }

        if person.isFavorite != nil {
            Button {
                Task { await detail.setFavorite(person.isFavorite != true, using: repo, onUpdated: publish) }
            } label: {
                Label(person.isFavorite == true ? "Unfavorite" : "Favorite", systemImage: "heart")
            }
        }

        Button {
            Task {
                await detail.toggleHidden(using: repo) { id, hidden in
                    listVM?.applyHidden(id, to: hidden)
                    onPersonUpdated?(PersonUpdate(person: detail.person, fields: [.hidden]))
                }
            }
        } label: {
            Label(
                person.isHidden ? "Show" : "Hide",
                systemImage: person.isHidden ? "eye" : "eye.slash")
        }
    }

    private func publish(_ update: PersonUpdate) {
        listVM?.applyPersonUpdate(update)
        onPersonUpdated?(update)
    }

    private func start() async {
        guard !Task.isCancelled, detail.isCurrent else { return }
        if vm == nil {
            let api = APIClient(session: session)
            let repo = repo
            let personId = person.id
            vm = AssetGridViewModel(
                assetRepo: AssetDetailRepository(api: api),
                albumRepo: AlbumRepository(api: api),
                snapshotKey: LocalSnapshot.Key.person(personId),
                loader: {
                    // /people/{id} tidak lagi menyertakan aset; isinya diambil
                    // lewat search metadata.
                    try await repo.assets(personId: personId).map(AssetLite.init)
                })
        }
        await vm?.load()

        // Nama bisa berubah di server sejak daftar dimuat; diambil ulang supaya
        // judul sampulnya benar.
        await detail.loadDetail(using: repo)
    }
}

#Preview {
    PeopleView()
        .environment(SessionManager())
}


/// Pembungkus supaya sekumpulan id bisa dipakai `sheet(item:)`.
struct SelectedAssetIDs: Identifiable {
    let id = UUID()
    let ids: [String]
}
