import SwiftUI
import UIKit

private extension View {
    @ViewBuilder
    func activateSearchOnTabSelection() -> some View {
        if #available(iOS 27.0, *) {
            tabViewSearchActivation(.searchTabSelection)
        } else {
            self
        }
    }
}

struct AppRouter: View {
    @Environment(SessionManager.self) private var session
    @AppStorage(SettingsViewModel.themeKey) private var theme = "system"
    @State private var launch = AppLaunchState.shared

    var body: some View {
        Group {
            if session.isLoggedIn {
                MainTabView()
            } else {
                OnboardingView()
            }
        }
        .preferredColorScheme(colorScheme)
        // Splash hanya untuk sesi yang sudah masuk: onboarding tidak membaca
        // cache apa pun, jadi tidak ada yang perlu ditutupi.
        .overlay {
            if session.isLoggedIn, !isReady {
                SplashView()
                    .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.25), value: isReady)
    }

    private var isReady: Bool {
        launch.isReady
    }

    private var colorScheme: ColorScheme? {
        switch theme {
        case "light": .light
        case "dark":  .dark
        default:      nil
        }
    }
}

struct MainTabView: View {
    @Environment(SessionManager.self) private var session
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.scenePhase) private var scenePhase
    @State private var syncVM: SyncViewModel?
    @State private var selectedDestination: Destination = .photos
    @State private var sidebarAlbumsVM: AlbumListViewModel?
    @State private var showNewAlbum = false
    @State private var backupNotifier = BackupNotifier.shared
    @State private var backupSetupJourney = BackupSetupJourney.shared
    @State private var localPhotoLibrary = LocalPhotoLibrary.shared
    @State private var navigation = AppNavigation.shared
    /// Satu state untuk isi tab Photos dan kontrol yang hidup di tab bar.
    @State private var timelineNavigation = TimelineNavigationState()
    /// Naik satu setiap tab Photos ditekan ulang saat sudah aktif.
    @State private var photosResetRequest = 0
    /// Layar detail meminta pita offline menyingkir selama ia tampil.
    ///
    /// Singleton, bukan environment — lihat `OfflineBannerSuppression`.
    private var suppression: OfflineBannerSuppression { .shared }

    /// Sengaja BUKAN bernama `Tab` — nama itu sudah dipakai tipe `Tab` milik
    /// SwiftUI yang dipakai di bawah, dan enum bersarang akan menaunginya.
    private enum TabID: Hashable {
        case photos, library, search
    }

    /// Sidebar iPad punya tujuan lebih banyak daripada tab bar iPhone.
    /// ID album disimpan, bukan DTO lengkap, supaya perubahan nama/count tidak
    /// dianggap sebagai tujuan navigasi yang sama sekali baru.
    private enum Destination: Hashable {
        case photos, library, search, allAlbums, album(String), newAlbum
    }

    /// Binding perantara untuk menangkap penekanan tab yang SUDAH aktif.
    ///
    /// `TabView` tidak menyediakan callback untuk itu — setter binding adalah
    /// satu-satunya tempat kejadian tersebut masih terlihat, karena SwiftUI
    /// tetap memanggilnya walau nilainya tidak berubah.
    private var tabSelection: Binding<TabID> {
        Binding(
            get: {
                switch selectedDestination {
                case .photos: .photos
                case .search: .search
                case .library, .allAlbums, .album, .newAlbum: .library
                }
            },
            set: { newValue in
                if selectedDestination == .photos, newValue == .photos {
                    photosResetRequest += 1
                }
                select(Self.destination(for: newValue))
            })
    }

    /// Binding sidebar juga menjadi satu pintu untuk memilih tujuan utama.
    /// Album individual diperlakukan sebagai bagian Library saat aplikasi
    /// kembali ke tata letak compact.
    private var sidebarSelection: Binding<Destination> {
        Binding(
            get: { selectedDestination },
            set: { destination in
                if selectedDestination == .photos, destination == .photos {
                    photosResetRequest += 1
                }
                select(destination)
            })
    }

    var body: some View {
        // `VStack`, bukan `safeAreaInset`.
        //
        // `safeAreaInset` memang tidak memotong tinggi, tapi harganya lain:
        // pitanya melayang DI ATAS isi yang menembus safe area, dan yang
        // tertutup di situ justru toolbar. VStack membuatnya benar-benar
        // mengambil tempat sendiri, dan itu yang diinginkan.
        VStack(spacing: 0) {
            if let syncVM, !suppression.isSuppressed {
                OfflineBanner(isOnline: syncVM.isOnline)
            }

            if horizontalSizeClass == .regular {
                sidebarTabView
            } else {
                compactTabView
            }
        }
        // Sync disuntikkan ke environment karena linimasa merender DARI hasil
        // sync itu, bukan dari endpoint linimasa. Tanpa akses ke sini, layar
        // Photos tidak punya cara tahu kapan datanya sudah ada.
        .environment(syncVM)
        .environment(timelineNavigation)
        .onChange(of: localPhotoLibrary.selectedAlbumIDs) {
            backupSetupJourney.refreshForAlbumSelection()
        }
        .onChange(of: backupNotifier.shouldSelectLibrary) { _, requested in
            guard requested else { return }
            openBackupTab()
        }
        .onChange(of: navigation.pendingDestination) { _, destination in
            guard let destination else { return }
            openExternalDestination(destination)
        }
        // `.task` di bawah hanya berjalan ketika MainTabView dibuat. Saat app
        // kembali dari background, view yang sama masih hidup sehingga upload
        // dari web/perangkat lain tidak pernah diminta lagi. Jalankan delta
        // sync setiap scene aktif; SyncViewModel sendiri menolak overlap.
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else { return }
            Task { await syncVM?.performBackgroundSync() }
        }
        .task {
            // Quick action cold-start sudah menunggu sebelum view ini dibuat.
            // Pindahkan tab SEKETIKA, jangan menahannya di belakang sync yang
            // bisa lama atau tidak pernah selesai saat server sedang offline.
            if let destination = navigation.pendingDestination {
                openExternalDestination(destination)
            }
            backupSetupJourney.refreshForAlbumSelection()
            if backupNotifier.shouldSelectLibrary { openBackupTab() }
            // Kalau yang terbuka bukan Photos, tidak ada grid pembuka yang akan
            // mengirim callback siap. Tutup splash langsung untuk tab tersebut.
            if selectedDestination != .photos { AppLaunchState.shared.markReady() }

            if syncVM == nil {
                let api = APIClient(session: session)
                let dataManager = SwiftDataManager.shared
                let repo = SyncRepository(api: api, dataManager: dataManager)
                syncVM = SyncViewModel(repo: repo, dataManager: dataManager)
            }
            // Snapshot widget tidak bergantung pada sync linimasa. Mulai lebih
            // dulu agar album yang baru dipilih dari editor widget mendapat
            // foto tanpa menunggu sinkronisasi perpustakaan besar selesai.
            Task { await WidgetSnapshotExporter.refresh(session: session) }
            await syncVM?.performBackgroundSync()
        }
    }

    /// iPhone dan jendela iPad yang sempit tetap memakai tab bar ringkas.
    private var compactTabView: some View {
        TabView(selection: tabSelection) {
            Tab("Photos", systemImage: "photo.fill.on.rectangle.fill", value: TabID.photos) {
                TimelineView(
                    resetScrollRequest: photosResetRequest,
                    isActive: selectedDestination == .photos)
            }

            Tab(value: TabID.library) {
                LibraryView(isActive: selectedDestination == .library)
            } label: {
                Label(
                    "Library",
                    image: "immiches.tortoise.rectangle.stack.fill"
                )
            }

            // Role Search dipertahankan agar transisi ke kolom pencarian dan
            // perilaku sistemnya tetap sama seperti sebelumnya.
            Tab(value: TabID.search, role: .search) {
                SearchView(isActive: selectedDestination == .search)
            }
        }
        .activateSearchOnTabSelection()
        // State minimize dibaca dari tab bar yang benar-benar digambar sistem.
        // Picker di bawah hanya mengisi celah tengah ketika state itu aktif.
        .tabBarMinimizeBehaviorWithUpdate(
            isMinimized: Binding(
                get: { timelineNavigation.isTabBarMinimized },
                set: { timelineNavigation.setTabBarMinimized($0) }),
            behavior: selectedDestination == .photos ? .onScrollUp : .never)
        .overlay(alignment: .bottom) {
            if showsTimelineModePicker {
                TimelineModePicker(navigation: timelineNavigation)
                    .controlSize(.large)
                    .glassEffect(.regular, in: .capsule)
                    .offset(y: 6)
                    .padding(.horizontal, 85)
                    .frame(maxWidth: 620)
            }
        }
    }

    /// Di lebar regular, gaya ini menjadi sidebar sistem. Kalau jendela iPad
    /// dipersempit SwiftUI dapat merapatkannya, sementara cabang compact di atas
    /// memastikan album dinamis tidak membanjiri tab bar.
    private var sidebarTabView: some View {
        TabView(selection: sidebarSelection) {
            Tab("Photos", systemImage: "photo.on.rectangle.angled", value: Destination.photos) {
                TimelineView(
                    resetScrollRequest: photosResetRequest,
                    isActive: selectedDestination == .photos)
            }

            Tab("Library", systemImage: "photo.stack", value: Destination.library) {
                LibraryView(isActive: selectedDestination == .library)
            }

            TabSection("Albums") {
                Tab(
                    "All Albums",
                    systemImage: "rectangle.stack",
                    value: Destination.allAlbums
                ) {
                    NavigationStack {
                        if let sidebarAlbumsVM {
                            AlbumsListView(viewModel: sidebarAlbumsVM)
                        } else {
                            ProgressView()
                        }
                    }
                }

                if let sidebarAlbumsVM {
                    ForEach(sidebarAlbumsVM.albums) { album in
                        Tab(value: Destination.album(album.id)) {
                            NavigationStack {
                                AlbumDetailView(
                                    album: album,
                                    onContentsChanged: { assets in
                                        sidebarAlbumsVM.applyContents(assets, to: album.id)
                                    },
                                    onAlbumChanged: {
                                        sidebarAlbumsVM.applyAlbumUpdate($0)
                                    },
                                    onDeleted: {
                                        sidebarAlbumsVM.removeDeletedAlbum(album.id)
                                        select(.allAlbums)
                                    },
                                    onShared: {
                                        sidebarAlbumsVM.applyAlbumSharing(album.id)
                                    })
                            }
                        } label: {
                            // HStack eksplisit, bukan Label. Style sidebar milik
                            // TabView dapat mengambil ukuran intrinsik icon Label
                            // dari rasio foto dan membuat portrait memanjang.
                            HStack(spacing: 10) {
                                SidebarAlbumIcon(album: album)
                                Text(album.albumName)
                                    .lineLimit(1)
                            }
                        }
                    }
                }

                Tab(
                    "New Album",
                    systemImage: "plus",
                    value: Destination.newAlbum
                ) {
                    EmptyView()
                }
            }

            Tab(value: Destination.search, role: .search) {
                SearchView(isActive: selectedDestination == .search)
            }
        }
        .activateSearchOnTabSelection()
        .tabViewStyle(.sidebarAdaptable)
        .sheet(isPresented: $showNewAlbum) {
            NewAlbumSheet { name, description, assetIDs in
                guard let sidebarAlbumsVM else {
                    return String(localized: "Failed to create album")
                }
                return await sidebarAlbumsVM.createAlbum(
                    name: name,
                    description: description,
                    assetIds: assetIDs)
            }
        }
        .task {
            if sidebarAlbumsVM == nil {
                let api = APIClient(session: session)
                sidebarAlbumsVM = AlbumListViewModel(repo: AlbumRepository(api: api))
            }
            await sidebarAlbumsVM?.loadAlbums()
        }
    }

    private static func destination(for tab: TabID) -> Destination {
        switch tab {
        case .photos: .photos
        case .library: .library
        case .search: .search
        }
    }

    private func select(_ destination: Destination) {
        // New Album adalah aksi di dalam section, bukan halaman. Jangan ubah
        // selection supaya highlight tetap pada tujuan yang sedang terbuka.
        if destination == .newAlbum {
            guard sidebarAlbumsVM != nil else { return }
            showNewAlbum = true
            return
        }

        selectedDestination = destination
        if destination != .photos {
            timelineNavigation.setTabBarMinimized(false)
        }
    }

    private var showsTimelineModePicker: Bool {
        selectedDestination == .photos
            && timelineNavigation.isTabBarMinimized
            && !timelineNavigation.isSelecting
    }

    private func openBackupTab() {
        select(.library)
        backupNotifier.didSelectLibrary()
    }

    /// Search hidup sebagai tab utama; tujuan Library lainnya dibiarkan belum
    /// dikonsumsi agar `LibraryView` dapat mendorong layar detailnya sendiri.
    private func openExternalDestination(_ destination: AppNavigation.Destination) {
        switch destination {
        case .search:
            select(.search)
            navigation.consume(.search)
        case .favorites, .memories, .album:
            select(.library)
        }
    }
}

private extension View {
    /// Membungkus perilaku minimize sistem sambil melaporkan state visual tab
    /// bar yang sebenarnya. Offset scroll tidak cukup karena UIKit sendiri yang
    /// menentukan kapan transisi platter selesai.
    func tabBarMinimizeBehaviorWithUpdate(
        isMinimized: Binding<Bool>,
        behavior: TabBarMinimizeBehavior
    ) -> some View {
        modifier(TabBarMinimizeStateModifier(
            isMinimized: isMinimized,
            behavior: behavior))
    }
}

private struct TabBarMinimizeStateModifier: ViewModifier {
    @Binding var isMinimized: Bool
    let behavior: TabBarMinimizeBehavior

    func body(content: Content) -> some View {
        content
            .background {
                TabBarMinimizeObserver(isMinimized: $isMinimized)
                    .frame(width: 0, height: 0)
            }
            // Menempatkan probe dan TabView dalam grup komposisi yang sama,
            // seperti struktur yang dipakai sistem selama minimization.
            .compositingGroup()
            .tabBarMinimizeBehavior(behavior)
    }
}

private struct TabBarMinimizeObserver: UIViewRepresentable {
    @Binding var isMinimized: Bool

    func makeCoordinator() -> Coordinator {
        Coordinator(isMinimized: $isMinimized)
    }

    func makeUIView(context: Context) -> TabBarProbeView {
        let view = TabBarProbeView()
        view.isUserInteractionEnabled = false
        view.onWindowChanged = { [weak view, weak coordinator = context.coordinator] in
            guard let view else { return }
            coordinator?.attach(from: view)
        }
        DispatchQueue.main.async { [weak view, weak coordinator = context.coordinator] in
            guard let view else { return }
            coordinator?.attach(from: view)
        }
        return view
    }

    func updateUIView(_ uiView: TabBarProbeView, context: Context) {
        context.coordinator.isMinimized = $isMinimized
        context.coordinator.attach(from: uiView)
    }

    static func dismantleUIView(
        _ uiView: TabBarProbeView,
        coordinator: Coordinator
    ) {
        coordinator.invalidate()
    }

    @MainActor
    final class Coordinator: NSObject {
        var isMinimized: Binding<Bool>

        private weak var minimizedPlatter: UIView?
        private weak var expandedPlatter: UIView?
        private var minimizedObservation: NSKeyValueObservation?
        private var expandedObservation: NSKeyValueObservation?
        private var retryWorkItem: DispatchWorkItem?
        private var retriesRemaining = 12

        init(isMinimized: Binding<Bool>) {
            self.isMinimized = isMinimized
        }

        func attach(from probe: UIView) {
            guard let tabBar = tabBarController(from: probe)?.tabBar else {
                scheduleRetry(from: probe)
                return
            }

            tabBar.layoutIfNeeded()
            let platters = tabBar.subviews.filter { view in
                NSStringFromClass(type(of: view)).contains("PlatterView")
            }
            let minimized = platters.first(where: \.isMinimizedPlatter)
            let expanded = platters.first { !$0.isMinimizedPlatter }

            guard let minimized, let expanded else {
                scheduleRetry(from: probe)
                return
            }
            guard minimized !== minimizedPlatter || expanded !== expandedPlatter else {
                return
            }

            invalidateObservations()
            minimizedPlatter = minimized
            expandedPlatter = expanded
            retriesRemaining = 12

            minimizedObservation = minimized.observe(
                \.isHidden,
                options: [.new]
            ) { [weak self] view, change in
                let isHidden = change.newValue ?? view.isHidden
                guard let self else { return }
                DispatchQueue.main.async {
                    self.setMinimized(!isHidden)
                }
            }
            expandedObservation = expanded.observe(
                \.isHidden,
                options: [.new]
            ) { [weak self] view, change in
                let isHidden = change.newValue ?? view.isHidden
                guard !isHidden, let self else { return }
                DispatchQueue.main.async {
                    // Saat expand, bar normal muncul sebelum platter kecil
                    // disembunyikan. Hapus picker pada event paling awal ini.
                    self.setMinimized(false)
                }
            }

            // Inisialisasi hanya ketika kedua representasi sudah berada pada
            // state yang tegas. Jika probe terpasang di tengah animasi dan
            // keduanya terlihat, pertahankan state sampai KVO berikutnya.
            if !minimized.isHidden && expanded.isHidden {
                setMinimized(true)
            } else if minimized.isHidden && !expanded.isHidden {
                setMinimized(false)
            }
        }

        func invalidate() {
            retryWorkItem?.cancel()
            retryWorkItem = nil
            invalidateObservations()
            isMinimized.wrappedValue = false
        }

        private func setMinimized(_ newValue: Bool) {
            if isMinimized.wrappedValue != newValue {
                isMinimized.wrappedValue = newValue
            }
        }

        private func scheduleRetry(from probe: UIView) {
            guard retryWorkItem == nil, retriesRemaining > 0 else { return }
            retriesRemaining -= 1
            let workItem = DispatchWorkItem { [weak self, weak probe] in
                guard let self, let probe else { return }
                self.retryWorkItem = nil
                self.attach(from: probe)
            }
            retryWorkItem = workItem
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1, execute: workItem)
        }

        private func invalidateObservations() {
            minimizedObservation?.invalidate()
            expandedObservation?.invalidate()
            minimizedObservation = nil
            expandedObservation = nil
            minimizedPlatter = nil
            expandedPlatter = nil
        }

        private func tabBarController(from view: UIView) -> UITabBarController? {
            var responder: UIResponder? = view
            while let current = responder {
                if let controller = current as? UITabBarController {
                    return controller
                }
                responder = current.next
            }
            return findTabBarController(in: view.window?.rootViewController)
        }

        private func findTabBarController(
            in controller: UIViewController?
        ) -> UITabBarController? {
            guard let controller else { return nil }
            if let tabBarController = controller as? UITabBarController {
                return tabBarController
            }
            if let presented = findTabBarController(
                in: controller.presentedViewController) {
                return presented
            }
            for child in controller.children {
                if let tabBarController = findTabBarController(in: child) {
                    return tabBarController
                }
            }
            return nil
        }
    }
}

private final class TabBarProbeView: UIView {
    var onWindowChanged: (() -> Void)?

    override func didMoveToWindow() {
        super.didMoveToWindow()
        onWindowChanged?()
    }
}

private extension UIView {
    var isMinimizedPlatter: Bool {
        abs(frame.width - frame.height) < 2
    }
}

/// Ikon album khusus sidebar, mengikuti rupa Apple Photos.
///
/// Bidangnya selalu persegi seukuran SF Symbol. Cover dipotong aspect-fill;
/// album tanpa cover memakai simbol foto di atas fill abu-abu rounded.
private struct SidebarAlbumIcon: View {
    let album: AlbumResponseDTO

    @Environment(SessionManager.self) private var session

    private let side: CGFloat = 24
    private let cornerRadius: CGFloat = 5

    var body: some View {
        // Petak dasar menentukan ukuran layout. Cover ditempatkan sebagai
        // overlay supaya rasio intrinsik bitmap tidak dapat meninggikan baris.
        RoundedRectangle(cornerRadius: cornerRadius)
            .fill(.fill.tertiary)
            .frame(width: side, height: side)
            .overlay {
            if let coverID = AlbumCoverStore.shared.coverID(for: album) {
                AuthImage(
                    assetId: coverID,
                    pixelSize: 64,
                    squareCropPointSize: side)
                    .frame(width: side, height: side)
                    .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
            } else {
                Image(systemName: "photo.on.rectangle")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            }
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
            // Mencegah style TabView menawarkan ulang ukuran berdasarkan rasio
            // bitmap; ukuran icon harus tetap 24×24 untuk portrait maupun landscape.
            .fixedSize(horizontal: true, vertical: true)
            .task(id: "\(album.id)|\(album.assetCount)|\(album.albumThumbnailAssetId ?? "")") {
                await AlbumCoverStore.shared.resolveCover(for: album, session: session)
            }
    }
}
