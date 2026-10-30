import SwiftUI

struct PeopleView: View {
    @Environment(SessionManager.self) private var session
    @State private var vm: PeopleListViewModel?
    @State private var query = ""
    /// Namespace zoom transition. Dideklarasikan di layar daftar, bukan di
    /// selnya: sumber dan tujuan transisi harus berbagi namespace yang SAMA,
    /// sedangkan tiap sel akan punya `@Namespace`-nya sendiri.
    @Namespace private var personNamespace
    private let columns = [
        GridItem(.adaptive(minimum: 100), spacing: 12)
    ]

    var body: some View {
        content
            .navigationTitle("People")
            .searchable(text: $query, prompt: "Search People")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    if case .loading = vm?.phase {
                        ProgressView()
                    }
                }
            }
        .task {
            if vm == nil {
                let api = APIClient(session: session)
                let repo = PeopleRepository(api: api)
                vm = PeopleListViewModel(repo: repo)
            }
            await vm?.loadPeople()
        }
    }

    @ViewBuilder
    private var content: some View {
        if let vm {
            switch vm.phase {
            case .idle, .loading:
            // Spinner HANYA kalau memang belum ada apa-apa.
            //
            // Potret lokal dibaca di `task`, yaitu setelah render pertama, jadi
            // tanpa gerbang ini layar berkedip spinner satu frame sebelum isi
            // yang sebenarnya sudah tersedia tergambar.
                if vm.people.isEmpty {
                    ProgressView()
                } else {
                    loadedContent(vm)
                }

            case .loaded:
                loadedContent(vm)

            case .failed(let error):
                errorState(error, vm)
            }
        } else {
            ProgressView()
        }
    }

    @ViewBuilder
    private func loadedContent(_ vm: PeopleListViewModel) -> some View {
        let people = visiblePeople(vm)

        if people.isEmpty {
            // Dibedakan: belum ada orang sama sekali vs. pencarian tanpa hasil.
            // Pesan "Faces will appear here" akan menyesatkan kalau sebenarnya
            // datanya ada, hanya tidak cocok dengan yang diketik.
            if query.isEmpty {
                emptyState
            } else {
                ContentUnavailableView.search(text: query)
            }
        } else {
            peopleGrid(people, vm)
        }
    }

    /// Pencarian dilakukan DI KLIEN, bukan lewat endpoint.
    ///
    /// Daftar orang sudah dimuat seluruhnya sejak awal dan jumlahnya kecil, jadi
    /// menyaringnya di tempat jauh lebih cepat daripada bolak-balik ke server
    /// tiap ketukan huruf.
    private func visiblePeople(_ vm: PeopleListViewModel) -> [PersonDTO] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return vm.people }
        return vm.people.filter {
            $0.name.localizedCaseInsensitiveContains(trimmed)
        }
    }

    /// Tautan memakai TUJUAN LANGSUNG, bukan `NavigationLink(value:)` +
    /// `navigationDestination(for:)`.
    ///
    /// Layar ini sendiri sudah didorong ke dalam stack milik Collections.
    /// Mendaftarkan tujuan berbasis nilai dari posisi itu membuat SwiftUI
    /// mendorong dua entri sekaligus — halaman yang sama muncul di atas, dan
    /// detailnya baru terlihat setelah ditekan back. Jalur dari Collections
    /// tidak pernah bermasalah justru karena memakai tujuan langsung.
    @ViewBuilder
    private func peopleGrid(
        _ people: [PersonDTO],
        _ vm: PeopleListViewModel
    ) -> some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 12) {
                ForEach(people) { person in
                    NavigationLink {
                        PersonDetailView(
                            person: person,
                            repo: PeopleRepository(api: APIClient(session: session)),
                            listVM: vm)
                        .navigationTransition(
                            .zoom(sourceID: person.id, in: personNamespace))
                    } label: {
                        VStack(spacing: 8) {
                            ZStack(alignment: .topTrailing) {
                                Circle()
                                    .fill(.gray.opacity(0.2))

                                if person.thumbnailPath?.isEmpty == false {
                                    // thumbnailPath adalah path filesystem server;
                                    // gambarnya harus diambil lewat endpoint terautentikasi.
                                    AuthImage(assetId: person.id,
                                              path: "/people/\(person.id)/thumbnail")
                                } else {
                                    Image(systemName: "person.crop.circle.fill")
                                        .resizable()
                                        .scaledToFit()
                                        .foregroundStyle(.gray.opacity(0.5))
                                }

                                if person.isHidden {
                                    Image(systemName: "eye.slash.fill")
                                        .font(.caption)
                                        .foregroundStyle(.red)
                                        .padding(4)
                                        .background(Circle().fill(.white))
                                }
                            }
                            .frame(height: 100)
                            .clipShape(Circle())

                            Text(person.name)
                                .font(.subheadline)
                                .lineLimit(2)
                                .multilineTextAlignment(.center)
                        }
                        .matchedTransitionSource(id: person.id, in: personNamespace)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(12)
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "person.2.circle.fill")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)
            Text("No People")
                .font(.headline)
            Text("Faces will appear here when detected")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private func errorState(_ error: String, _ vm: PeopleListViewModel) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 48))
                .foregroundStyle(.orange)
            Text("Failed to Load")
                .font(.headline)
            Text(error)
                .font(.caption)
                .foregroundStyle(.secondary)
            Button("Retry") {
                Task { await vm.retry() }
            }
            .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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
    var listVM: PeopleListViewModel?
    var onPersonUpdated: ((PersonUpdate) -> Void)? = nil

    @Environment(SessionManager.self) private var session
    @Environment(\.dismiss) private var dismiss
    @State private var vm: AssetGridViewModel?
    @State private var albumPickerAsset: AssetLite?
    @State private var albumPickerSelection: SelectedAssetIDs?
    @State private var sharedLink: SharedLinkPresentation?
    @State private var showRenameSheet = false
    /// Kabar singkat dari aksi — mis. "sudah ada di album ini". Toast, bukan
    /// alert: ini bukan kegagalan yang menuntut jawaban.
    @State private var actionMessage: ErrorEvent?

    init(
        person: PersonDTO, repo: PeopleRepository, listVM: PeopleListViewModel? = nil,
        onPersonUpdated: ((PersonUpdate) -> Void)? = nil
    ) {
        _detail = State(initialValue: PersonDetailState(person: person))
        self.repo = repo
        self.listVM = listVM
        self.onPersonUpdated = onPersonUpdated
    }

    private var person: PersonDTO { detail.person }

    var body: some View {
        screen
            .sheet(isPresented: $showRenameSheet) {
                PersonIdentityEditor(person: person, repository: repo, detailState: detail, onUpdated: publish)
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
            .sheet(item: $sharedLink) { ShareSheet(url: $0.url) }
            .errorToast($actionMessage)
            .onChange(of: session.accountGeneration) { _, _ in dismiss() }
            .task { await start() }
    }

    private var isPresentingSheet: Bool {
        showRenameSheet || albumPickerAsset != nil || albumPickerSelection != nil
            || sharedLink != nil
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
        return actions
    }

    private func createSharedLink(for ids: [String]) {
        guard !ids.isEmpty else { return }
        let repo = SharedLinkRepository(api: APIClient(session: session))
        Task {
            vm?.actionError = nil
            do {
                let link = try await repo.create(assetIds: ids)
                guard let url = link.publicURL(base: session.baseURL) else {
                    vm?.actionError = String(localized: "Failed to create shared link")
                    return
                }
                sharedLink = SharedLinkPresentation(url: url)
            } catch {
                vm?.actionError = (error as? APIError)?.errorDescription
                    ?? String(localized: "Failed to create shared link")
            }
        }
    }

    @ViewBuilder
    private var personMenu: some View {
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
