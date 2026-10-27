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

/// Foto seseorang, memakai `PhotoCollectionScreen` yang sama dengan detail
/// album — yang khas di sini hanya menu Rename / Hide.
struct PersonDetailView: View {
    @State var person: PersonDTO
    let repo: PeopleRepository
    var listVM: PeopleListViewModel?

    @Environment(SessionManager.self) private var session
    @State private var vm: AssetGridViewModel?
    @State private var albumPickerAsset: AssetLite?
    @State private var albumPickerSelection: SelectedAssetIDs?
    @State private var sharedLink: SharedLinkPresentation?
    @State private var showRenameSheet = false
    @State private var newName = ""
    @State private var actionError: String?
    /// Kabar singkat dari aksi — mis. "sudah ada di album ini". Toast, bukan
    /// alert: ini bukan kegagalan yang menuntut jawaban.
    @State private var actionMessage: ErrorEvent?

    var body: some View {
        screen
            .sheet(isPresented: $showRenameSheet) {
                RenameSheet(name: $newName, onSave: {
                    Task { await rename() }
                })
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
                get: { actionError != nil },
                set: { if !$0 { actionError = nil } }
            )) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(actionError ?? "")
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
            .task { await start() }
    }

    private var screen: some View {
        PhotoCollectionScreen(
            title: LocalizedStringKey(person.name),
            assets: vm?.assets ?? [],
            phase: vm?.phase ?? .loading,
            onRetry: { Task { await vm?.load() } },
            onToggleFavorite: { await vm?.toggleFavorite($0) },
            onDelete: { await vm?.delete($0) },
            shareURLs: { await vm?.shareURLs(for: $0) ?? [] },
            onAddToAlbum: { albumPickerAsset = $0 },
            onFavoriteSelection: { await vm?.setFavorite($0, to: true) },
            onArchiveSelection: { await vm?.setArchived($0, to: true) },
            onMoveToLocked: { await vm?.setLocked($0) },
            onShareLink: { createSharedLink(for: $0) },
            selectionMenu: selectionMenu,
            options: { personMenu })
    }

    /// Menu elipsis mode pilih — isinya sama dengan Photos.
    ///
    /// "Move to Locked Folder" tidak ikut di sini: `PhotoCollectionScreen`
    /// menambahkannya sendiri dari `onMoveToLocked`, supaya semua layar yang
    /// punya aksi itu memakai satu susunan yang sama.
    private func selectionMenu(_ ids: Set<String>) -> [SelectionMenuAction] {
        [
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
    }

    private func createSharedLink(for ids: [String]) {
        guard !ids.isEmpty else { return }
        let repo = SharedLinkRepository(api: APIClient(session: session))
        Task {
            guard let link = try? await repo.create(assetIds: ids),
                  let url = link.publicURL(base: session.baseURL)
            else { return }
            sharedLink = SharedLinkPresentation(url: url)
        }
    }

    @ViewBuilder
    private var personMenu: some View {
        Button {
            newName = person.name
            showRenameSheet = true
        } label: {
            Label("Rename", systemImage: "pencil")
        }

        Button {
            Task { await toggleHidden() }
        } label: {
            Label(
                person.isHidden ? "Show" : "Hide",
                systemImage: person.isHidden ? "eye" : "eye.slash")
        }
    }

    private func start() async {
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
        if let detail = try? await repo.detail(person.id) { person = detail }
    }

    private func rename() async {
        guard !newName.isEmpty else { return }
        do {
            try await repo.rename(person.id, to: newName)
            person.name = newName
            listVM?.applyRename(person.id, to: newName)
        } catch {
            actionError = (error as? APIError)?.errorDescription ?? error.localizedDescription
        }
    }

    private func toggleHidden() async {
        do {
            let newValue = !person.isHidden
            try await repo.setHidden(person.id, to: newValue)
            person.isHidden = newValue
            listVM?.applyHidden(person.id, to: newValue)
        } catch {
            actionError = (error as? APIError)?.errorDescription ?? error.localizedDescription
        }
    }
}

struct RenameSheet: View {
    @Binding var name: String
    var onSave: () -> Void
    @FocusState private var isFocused: Bool
    @Environment(\.dismiss) var dismiss

    var body: some View {
        NavigationStack {
            Form {
                TextField("Name", text: $name)
                    .focused($isFocused)
            }
            .navigationTitle("Rename Person")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Save") {
                        onSave()
                        dismiss()
                    }
                    .disabled(name.isEmpty)
                }
            }
            .onAppear { isFocused = true }
        }
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
