import SwiftUI

/// Layar pencarian: kolom cari yang langsung siap diketik, deret penyaring di
/// bawahnya, lalu hasilnya.
struct SearchView: View {
    let isActive: Bool

    @State private var searchText = ""
    @Environment(SessionManager.self) private var session
    @State private var vm: SearchViewModel?
    @FocusState private var isSearchFocused: Bool
    @State private var didRequestInitialFocus = false

    // MARK: Mode pilih
    @State private var isSelecting = false
    @State private var selectedIDs: Set<String> = []
    @State private var isPreparingShare = false
    @State private var isPerformingAction = false
    @State private var shareURLs: [URL] = []
    @State private var isSharePresented = false
    @State private var albumPicker: SelectedAssets?
    @State private var selectionLink: SharedLinkPresentation?
    /// Foto yang menunggu konfirmasi hapus — dari seleksi maupun context menu.
    @State private var pendingDelete: SelectedAssets?
    /// Naik satu setiap penghapusan yang dikonfirmasi server.
    @State private var deleteFeedback = 0
    /// Naik satu setiap toggle favorit yang dikonfirmasi server.
    @State private var favoriteFeedback = 0

    var body: some View {
        NavigationStack {
            content
                // Judulnya toolbar item, bukan `navigationTitle` — sama seperti
                // Photos dan Library. Item toolbar tidak menyusut atau pindah ke
                // tengah saat isinya digulir.
                //
                // Navigation bar tetap ada, tanpa latar di belakang judul dan
                // aksi saat hasil pencarian digulir.
                .toolbar { searchToolbar }
                .toolbarBackground(.hidden, for: .navigationBar)
                // Tab bar diganti bottom bar selama memilih, supaya aksi
                // seleksi menempati tempat yang sama — persis seperti Photos.
                //
                // PERHATIAN: tab bar di layar ini juga rumah bagi kolom cari.
                // Kalau suatu saat kolomnya ikut pindah ke atas dan tidak
                // kembali turun setelah keluar dari mode pilih, BARIS INI
                // tersangkanya; gantinya cukup membiarkan tab bar tetap terlihat
                // dan menerima bottom bar bertumpuk di atasnya.
                .toolbar(isSelecting ? .hidden : .automatic, for: .tabBar)
                .toolbar(isSelecting ? .visible : .hidden, for: .bottomBar)
                .overlay { presentations }
                .onChange(of: searchText) { _, newValue in
                    vm?.searchText = newValue
                    vm?.scheduleSearch()
                }
                // Hasil berganti sementara mode pilih menyala: yang terpilih
                // tapi sudah tidak ada di daftar harus ikut gugur, kalau tidak
                // aksinya menyasar foto yang tidak terlihat siapa pun.
                .onChange(of: vm?.results ?? []) { _, newResults in
                    guard isSelecting else { return }
                    // Hasilnya habis — tidak ada lagi yang bisa dipilih, jadi
                    // mode pilihnya ikut ditutup alih-alih menyisakan bar penuh
                    // tombol mati.
                    guard !newResults.isEmpty else {
                        exitSelection()
                        return
                    }
                    // Yang terpilih tapi sudah tidak ada di daftar harus gugur,
                    // kalau tidak aksinya menyasar foto yang tidak terlihat
                    // siapa pun.
                    selectedIDs.formIntersection(Set(newResults.map(\.id)))
                }
                .task {
                    if vm == nil {
                        let api = APIClient(session: session)
                        vm = SearchViewModel(
                            repo: SearchRepository(api: api),
                            assetRepo: AssetDetailRepository(api: api),
                            albumRepo: AlbumRepository(api: api),
                            peopleRepo: PeopleRepository(api: api))
                    }
                    // Teks yang sempat diketik sebelum view model ada tidak
                    // hilang: `onChange` tidak berjalan untuk nilai yang sudah
                    // terpasang sejak awal.
                    vm?.searchText = searchText
                    // Hanya kalau belum pernah mencari sama sekali. `task`
                    // berjalan ulang setiap tab dibuka, dan menembakkan
                    // pencarian di sini tanpa syarat berarti mengulangi
                    // permintaan yang sama tiap kali pengguna kembali.
                    if let vm, case .idle = vm.phase { vm.scheduleSearch() }
                    await vm?.loadFilterOptions()
                }
        }
        .sensoryFeedback(.impact(weight: .heavy), trigger: deleteFeedback)
        .sensoryFeedback(.success, trigger: favoriteFeedback)
        // Menempel pada `NavigationStack`, BUKAN pada `content` di dalamnya, dan
        // bukan pula pada `TabView` di luar sana. Tiga penempatan itu memberi
        // tiga hasil berbeda:
        //
        // - di `content`  → kolom cari kedua muncul di bar ATAS layar ini,
        //                   sementara tab bar tetap punya kolomnya sendiri
        // - di `TabView`  → kolomnya menyebar ke SEMUA tab; Photos dan Library
        //                   ikut kebagian kolom cari yang tidak diminta
        // - di sini       → sistem menyatukannya dengan tab ber-role `.search`:
        //                   satu kolom saja, di bar bawah, mengembang saat
        //                   tab-nya dipilih
        //
        .searchable(text: $searchText, prompt: "Search photos")
        .searchFocused($isSearchFocused)
        // SearchView bisa sudah dibangun ketika tab lain masih aktif. Menunggu
        // `isActive` mencegah keyboard mencuri fokus dari Photos/Library, dan
        // penanda sekali-jalan menjaga keyboard tidak dipaksa muncul lagi saat
        // pengguna kembali ke Search pada sesi tab yang sama.
        .task(id: isActive) {
            // iOS 27 mengaktifkan search dari pemilihan tab lewat TabView.
            // Fokus manual ini hanya diperlukan untuk perilaku iOS 26.
            if #available(iOS 27.0, *) { return }
            guard isActive, !didRequestInitialFocus else {
                if !isActive { isSearchFocused = false }
                return
            }

            // Beri tab role `.search` waktu menyelesaikan ekspansi kolom di bar
            // bawah sebelum meminta first responder.
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled, isActive else { return }
            didRequestInitialFocus = true
            isSearchFocused = true
        }
        // Bar atas TETAP ada selama mencari.
        //
        // Bawaannya iOS menyembunyikan isi toolbar begitu pencarian aktif —
        // "untuk memusatkan perhatian pada pencarian", kata dokumentasinya — dan
        // aktif di sini berarti selama masih ada teks di kolomnya, bukan cuma
        // selama papan ketik terbuka. Akibatnya judul DAN tombol Select lenyap
        // justru pada satu-satunya keadaan yang menghasilkan foto untuk dipilih.
        .searchPresentationToolbarBehavior(.avoidHidingContent)
    }

    private var filtersBinding: Binding<SearchFilters> {
        Binding(
            get: { vm?.filters ?? SearchFilters() },
            set: { newValue in
                vm?.filters = newValue
                vm?.scheduleSearch()
            })
    }

    @ViewBuilder
    private var content: some View {
        if let vm {
            VStack(spacing: 0) {
                SearchFilterBar(
                    filters: filtersBinding,
                    people: vm.people,
                    cities: vm.cities)

                Divider()

                results(vm)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        } else {
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ViewBuilder
    private func results(_ vm: SearchViewModel) -> some View {
        if !vm.hasCriteria {
            suggestionsView(vm)
        } else {
            switch vm.phase {
            case .idle, .loading:
                ProgressView()

            case .loaded:
                if vm.results.isEmpty {
                    noResultsState
                } else {
                    SearchResultsGrid(
                        assets: vm.results,
                        isSelecting: $isSelecting,
                        selectedIDs: $selectedIDs,
                        actions: assetActions,
                        onReachEnd: { Task { await vm.loadMore() } })
                }

            case .failed(let error):
                errorState(error, vm)
            }
        }
    }

    /// Saran tempat, sekaligus pengisi layar sebelum ada yang diketik.
    ///
    /// Ini juga yang menggantikan tombol Explore: isinya sama-sama "apa yang ada
    /// di perpustakaanmu", hanya tidak lagi disembunyikan di balik satu ketukan.
    @ViewBuilder
    private func suggestionsView(_ vm: SearchViewModel) -> some View {
        if vm.cities.isEmpty {
            ContentUnavailableView(
                "Search Your Photos",
                systemImage: "magnifyingglass",
                description: Text(
                    "Type what you remember, or narrow it down with the filters above."))
        } else {
            List {
                Section("Places") {
                    ForEach(vm.cities.prefix(20), id: \.self) { city in
                        Button {
                            vm.filters.city = city
                            vm.scheduleSearch()
                        } label: {
                            Label(city, systemImage: "mappin.and.ellipse")
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .listStyle(.plain)
        }
    }

    private var noResultsState: some View {
        ContentUnavailableView(
            "No Results",
            systemImage: "magnifyingglass",
            description: Text("Try different keywords, or loosen the filters."))
    }

    private func errorState(_ error: String, _ vm: SearchViewModel) -> some View {
        ContentUnavailableView {
            Label("Search Failed", systemImage: "exclamationmark.triangle")
        } description: {
            Text(error)
        } actions: {
            Button("Retry") { Task { await vm.search() } }
                .buttonStyle(.borderedProminent)
        }
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var searchToolbar: some ToolbarContent {
        if !isSelecting {
            ToolbarItem(placement: .topBarLeading) { titleStack }
                // Judul tidak boleh dapat latar kapsul seperti tombol.
                .sharedBackgroundVisibility(.hidden)
        }

        // Tidak ada hasil, tidak ada yang bisa dipilih — tombolnya pun tidak
        // perlu ada di layar saran maupun layar kosong.
        //
        // `|| isSelecting` bukan hiasan: selama memilih, tab bar disembunyikan
        // dan tombol ini SATU-SATUNYA jalan keluar. Tanpa itu, mengubah
        // penyaring sampai hasilnya kosong akan menghapus tombolnya sekaligus —
        // dan layarnya terkunci di mode pilih tanpa apa pun yang bisa ditekan.
        if hasResults || isSelecting {
            ToolbarItem(placement: .topBarTrailing) { selectButton }
        }

        if isSelecting {
            ToolbarItem(placement: .principal) { selectionCountLabel }
                .sharedBackgroundVisibility(.hidden)
            SelectionToolbar(actions: selectionActions)
        }
    }

    private var hasResults: Bool {
        !(vm?.results.isEmpty ?? true)
    }

    /// Judul besar dengan subjudul opsional, sama seperti Photos.
    private var titleStack: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Search")
                .font(.largeTitle.bold())

            // Subjudulnya HANYA ada saat ada hasil. Baris "0 Results" yang
            // menetap di bawah judul saat layar masih kosong hanya menyita
            // tinggi bar untuk mengabarkan sesuatu yang sudah terlihat.
            if let resultSubtitle {
                Text(resultSubtitle)
                    .font(.headline.bold())
            }
        }
        .lineLimit(1)
        // WAJIB: tanpa ini toolbar menyempitkan item sampai selebar ikon dan
        // judulnya tersisa jadi "…".
        .fixedSize()
    }

    private var resultSubtitle: String? {
        guard let vm, vm.hasCriteria, vm.totalResults > 0 else { return nil }
        return vm.totalResults == 1
            ? String(localized: "1 Result")
            : String(localized: "\(vm.totalResults) Results")
    }

    private var selectButton: some View {
        Button {
            if isSelecting {
                exitSelection()
            } else {
                isSelecting = true
            }
        } label: {
            if isSelecting {
                Image(systemName: "xmark")
                    .font(.body.weight(.semibold))
            } else {
                Text("Select")
            }
        }
    }

    private var selectionCountLabel: some View {
        Text(selectionTitle)
            .font(.headline.bold())
            .foregroundStyle(selectedIDs.isEmpty ? .secondary : .primary)
            .lineLimit(1)
            // Tanpa fixedSize, toolbar menyempitkan teksnya sampai terpotong.
            .fixedSize()
    }

    /// Sengaja dirakit manual, bukan `^[...](inflect:)` — markup itu hanya
    /// diproses untuk literal yang menjadi `LocalizedStringKey`.
    private var selectionTitle: String {
        let count = selectedIDs.count
        guard count > 0 else { return String(localized: "Select Items") }
        return count == 1 ? "1 Item Selected" : "\(count) Items Selected"
    }

    // MARK: - Aksi

    private var selectionActions: SelectionActions {
        let ids = Array(selectedIDs)
        var actions = SelectionActions()
        actions.isBusy = isPreparingShare || isPerformingAction || selectedIDs.isEmpty
        actions.share = { share(ids) }
        actions.favorite = {
            runSelection {
                // Getarnya HANYA setelah server menerimanya.
                let succeeded = await vm?.setFavorite(ids, to: true) ?? false
                if succeeded { favoriteFeedback += 1 }
                return succeeded
            }
        }
        actions.archive = { runSelection { await vm?.archive(ids) ?? false } }
        actions.trash = { pendingDelete = SelectedAssets(ids: ids) }
        actions.menu = [
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

    /// Aksi satu foto untuk context menu, plus kabar balik dari layar detail.
    private var assetActions: SearchAssetActions {
        SearchAssetActions(
            share: { share([$0.id]) },
            toggleFavorite: { asset in
                Task {
                    if await vm?.toggleFavorite(asset) == true { favoriteFeedback += 1 }
                }
            },
            archive: { asset in Task { await vm?.archive([asset.id]) } },
            addToAlbum: { albumPicker = SelectedAssets(ids: [$0.id]) },
            delete: { pendingDelete = SelectedAssets(ids: [$0.id]) },
            assetRemoved: { vm?.removeLocally([$0]) },
            favoriteChanged: { vm?.patchFavorite($0, to: $1) })
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
        isSelecting = false
        selectedIDs.removeAll()
    }

    private func share(_ ids: [String]) {
        guard !ids.isEmpty else { return }
        isPreparingShare = true
        Task {
            let urls = await vm?.shareURLs(for: ids) ?? []
            isPreparingShare = false
            guard !urls.isEmpty else { return }
            shareURLs = urls
            isSharePresented = true
        }
    }

    private func createSharedLink(for ids: [String]) {
        guard !ids.isEmpty else { return }
        let repo = SharedLinkRepository(api: APIClient(session: session))
        Task {
            // Kegagalannya BERSUARA. Ditelan `try?` tanpa kabar, mengetuk
            // "Share Link" pada server yang menolak tidak menghasilkan apa-apa
            // di layar — dan tidak ada cara membedakannya dari ketukan yang
            // tidak terbaca.
            guard let link = try? await repo.create(assetIds: ids),
                  let url = link.publicURL(base: session.baseURL)
            else {
                vm?.actionError = String(localized: "Failed to create shared link")
                return
            }
            selectionLink = SharedLinkPresentation(url: url)
        }
    }

    private func performDelete(_ ids: [String]) {
        pendingDelete = nil
        runSelection {
            let succeeded = await vm?.delete(ids) ?? false
            if succeeded { deleteFeedback += 1 }
            return succeeded
        }
    }

    private func deleteTitle(_ count: Int) -> String {
        count == 1
            ? String(localized: "Delete 1 Item")
            : String(localized: "Delete \(count) Items")
    }

    // MARK: - Sheet & dialog

    /// Ditempelkan pada overlay setipis nol, bukan langsung di `body`.
    ///
    /// Empat sheet, satu dialog, dan satu alert berjejer di satu rantai modifier
    /// rutin membuat pengecek tipe Swift menyerah dengan "unable to type-check
    /// this expression" — dan pesannya menunjuk ke `body`, bukan ke penyebabnya.
    private var presentations: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .sheet(isPresented: $isSharePresented) {
                MultiShareSheet(urls: shareURLs)
            }
            .sheet(item: $albumPicker) { selection in
                AlbumPickerLoader { album in
                    runSelection {
                        await vm?.addToAlbum(selection.ids, album: album) ?? false
                    }
                }
            }
            .sheet(item: $selectionLink) { ShareSheet(url: $0.url) }
            // Dialognya menempel di sini, bukan di tombol sampahnya: tombol itu
            // hidup di dalam `SelectionToolbar`, dan modifier presentasi pada
            // item toolbar tidak selalu punya tempat untuk menampilkannya.
            //
            // `presenting:` — id-nya diserahkan ke dialog, bukan dibaca ulang
            // dari `pendingDelete` saat tombolnya ditekan. Penutupan dialog
            // mengosongkan state itu, dan membacanya belakangan berarti
            // bertaruh pada urutan antara "tutup" dan "jalankan aksi".
            // Jumlahnya ada di TOMBOL, bukan di judul. Judul dialog bukan closure
            // — ia dibaca ulang dari `pendingDelete` yang sudah dikosongkan saat
            // dialognya menutup, jadi selama animasi tutup tulisannya sempat
            // berubah jadi "Delete 0 Items".
            .confirmationDialog(
                "This cannot be undone.",
                isPresented: Binding(
                    get: { pendingDelete != nil },
                    set: { if !$0 { pendingDelete = nil } }),
                titleVisibility: .visible,
                presenting: pendingDelete
            ) { selection in
                Button(deleteTitle(selection.ids.count), role: .destructive) {
                    performDelete(selection.ids)
                }
                Button("Cancel", role: .cancel) {}
            }
            .alert("Action Failed", isPresented: Binding(
                get: { vm?.actionError != nil },
                set: { if !$0 { vm?.actionError = nil } })
            ) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(vm?.actionError ?? "")
            }
    }
}

/// Pembungkus supaya sekumpulan id bisa dipakai `sheet(item:)` dan sebagai
/// penanda "ada yang menunggu konfirmasi".
private struct SelectedAssets: Identifiable {
    let id = UUID()
    let ids: [String]
}

#Preview {
    SearchView(isActive: true)
        .environment(SessionManager())
}
