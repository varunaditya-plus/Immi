import AVFoundation
import ImageIO
import UniformTypeIdentifiers
import CoreLocation
import LinkPresentation
import SwiftUI

struct AssetDetailView: View {
    @State private var viewer: AssetViewerState
    let visibilityPolicy: AssetVisibilityPolicy
    let trashActions: TrashViewerActions?
    // true saat ditampilkan sebagai fullScreenCover (perlu tombol tutup sendiri).
    var isModal = false
    // Memberi tahu pemanggil foto mana yang sedang tampil, supaya
    // sourceID zoom transition ikut berpindah saat user swipe.
    var onAssetChange: ((AssetLite) -> Void)? = nil
    /// Aset keluar dari daftar: dipindah ke arsip/locked folder atau dihapus.
    var onAssetRemoved: ((String) -> Void)? = nil
    /// Metadata aset berubah (tanggal, lokasi, deskripsi).
    var onAssetUpdated: ((String) -> Void)? = nil
    /// Dipisah dari `onAssetUpdated` karena cukup ditambal di tempat — status
    /// favorit tidak memengaruhi pengelompokan bucket, jadi tidak perlu
    /// memuat ulang timeline.
    var onFavoriteChanged: ((String, Bool) -> Void)? = nil

    @Environment(SessionManager.self) private var session
    @Environment(\.dismiss) private var dismiss
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var vm: AssetDetailViewModel?
    @State private var isSharePresented = false
    @State private var sharedLink: SharedLinkPresentation?
    @State private var isSettingProfilePhoto = false
    @State private var downloadedFileURL: URL?
    @State private var sharedAssetIDs: [String] = []
    @State private var sharedSourceIDs: [String] = []
    @State private var sharedRequestContext: SessionRequestContext?
    @State private var showToolbar = true
    @State private var isZoomed = false
    @State private var showDeleteConfirm = false
    @State private var deleteTarget: AssetViewerState.Target?
    @State private var trashActionError: ErrorEvent?
    /// Naik satu setiap toggle favorit yang berhasil; dipakai sebagai pemicu
    /// animasi simbol dan haptic.
    @State private var favoriteFeedback = 0
    /// Naik satu setiap penghapusan yang dikonfirmasi server.
    @State private var deleteFeedback = 0
    /// Cermin dari `vm.detail.isFavorite`.
    ///
    /// Toolbar SwiftUI tidak andal ikut ter-invalidate oleh perubahan objek
    /// `@Observable`, jadi statusnya disalin ke `@State` milik view ini —
    /// perubahan `@State` pasti membangun ulang body beserta toolbar-nya.
    @State private var isFavorite = false
    /// Cermin dari `vm.detail != nil` — ADA INFO untuk ditampilkan.
    ///
    /// Alasan disalin ke `@State` sama seperti `isFavorite`: toolbar SwiftUI
    /// tidak andal ikut ter-invalidate oleh perubahan objek `@Observable`,
    /// sedangkan perubahan `@State` pasti membangun ulang body beserta
    /// toolbar-nya.
    ///
    /// Offline biasanya TETAP true — detail foto yang pernah dibuka tersimpan
    /// sebagai potret lokal. Yang false hanya foto yang memang belum pernah
    /// dimuat sekali pun.
    @State private var hasDetail = false
    /// Tinggi panel info saat ini dalam poin. 0 = tertutup. Nilainya mengikuti
    /// jari selama drag, lalu di-snap ke detent terdekat saat dilepas.
    @State private var panelHeight: CGFloat = 0
    /// Tinggi panel saat drag dimulai, supaya perpindahan bersifat relatif.
    /// Sekaligus penanda bahwa drag sedang berlangsung — hanya ada satu
    /// recognizer sekarang, jadi tidak perlu lagi melacak siapa pemiliknya.
    @State private var panelDragStart: CGFloat?
    /// Tinggi alami isi panel, dilaporkan balik oleh `AssetInfoPanel`.
    @State private var panelContentHeight: CGFloat = 0
    /// Posisi scroll daftar di dalam panel, dipakai recognizer untuk memutuskan
    /// kapan harus mengalah ke daftar.
    @State private var panelScrollOffset: CGFloat = 0
    @State private var viewportSize: CGSize = .zero
    /// Kotak card terakhir saat chrome masih utuh. Navigation bar menghilang
    /// ketika panel dibuka; memakai GeometryReader live pada saat itu mengubah
    /// titik awal interpolasi di tengah gesture dan membuat foto tersentak.
    @State private var cardViewport: AssetCardViewport?

    @State private var descriptionDraft = ""
    @FocusState private var descriptionFocused: Bool
    /// Cermin dari `descriptionFocused`. Toolbar builder tidak andal membaca
    /// @FocusState langsung, jadi disalin seperti status toolbar lainnya.
    @State private var isEditingDescription = false
    @State private var dateTarget: AssetViewerState.Target?
    @State private var locationTarget: AssetViewerState.Target?
    @State private var albumTarget: AssetViewerState.Target?
    @State private var photoEditorTarget: PhotoEditorTarget?
    @State private var changedSourceEditor: PhotoEditorTarget?
    @State private var liveActionID: UUID?
    private var isApplyingLiveAction: Bool { liveActionID != nil }
    @State private var editorOwnedFiles: [URL] = []
    @State private var descriptionTarget: AssetViewerState.Target?
    @State private var removeDeviceTarget: AssetViewerState.Target?
    @State private var showRemoveDeviceConfirm = false
    @State private var deviceRemoval: Task<Void, Never>?
    /// Panel tetap terpasang sampai animasi menutup benar-benar selesai.
    ///
    /// Tanpa ini, `panelHeight` menyentuh 0 di awal `withAnimation` sehingga
    /// view-nya langsung dilepas dan animasi mengecilnya tidak pernah terlihat
    /// — yang tampak hanya kedipan.
    @State private var isPanelMounted = false
    /// Pegangan ke strip, supaya pager bisa menggesernya langsung tiap frame.
    @State private var filmstripController: PhotoFilmstripController?
    /// Pegangan ke pager, supaya bar kontrol video bisa menyambung langsung.
    @State private var slideshow: PhotoSlideshowPresentation?
    @State private var pagerController: PhotoPagerController?
    /// Salinan eksplisit metadata Live Photo. Membacanya langsung dari objek
    /// observable di dalam representable dapat melewatkan update ketika detail
    /// cache dan detail jaringan mempunyai ID aset yang sama.
    @State private var currentLivePhotoVideoID: String? = nil
    @State private var currentLivePhotoHint: LocalLivePhotoMatchHint? = nil
    /// Menjaga metadata async tidak pernah dipasang ke halaman yang berbeda
    /// selama satu frame transisi pager.
    @State private var currentLivePhotoContextAssetID: String? = nil
    @State private var metadataKey: MetadataKey?
    @State private var recentlyViewedStore: RecentlyViewedStore?

    init(
        currentAsset: AssetLite,
        assets: [AssetLite],
        visibilityPolicy: AssetVisibilityPolicy? = nil,
        isModal: Bool = false,
        onAssetChange: ((AssetLite) -> Void)? = nil,
        onAssetRemoved: ((String) -> Void)? = nil,
        onAssetUpdated: ((String) -> Void)? = nil,
        onFavoriteChanged: ((String, Bool) -> Void)? = nil,
        trashActions: TrashViewerActions? = nil,
        viewModel: AssetDetailViewModel? = nil,
        recentlyViewedStore: RecentlyViewedStore? = nil
    ) {
        _viewer = State(initialValue: AssetViewerState(currentAsset: currentAsset, assets: assets))
        _vm = State(initialValue: viewModel)
        _recentlyViewedStore = State(initialValue: recentlyViewedStore)
        self.visibilityPolicy = visibilityPolicy ?? AssetVisibilityPolicy()
        self.isModal = isModal
        self.onAssetChange = onAssetChange
        self.onAssetRemoved = onAssetRemoved
        self.onAssetUpdated = onAssetUpdated
        self.onFavoriteChanged = onFavoriteChanged
        self.trashActions = trashActions
    }

    private var currentAsset: AssetLite {
        get { viewer.currentAsset }
        nonmutating set {
            if viewer.select(newValue.id) { loadCurrentMetadata() }
        }
    }
    private var visibleAssets: [AssetLite] { viewer.pages }
    private var isPreparingShare: Bool { viewer.isPreparing(.share) }
    private var isPreparingEditor: Bool { viewer.isPreparing(.editor) }
    private var isDownloadingToDevice: Bool { viewer.isDownloading(currentAsset.id) }
    private var isUploadingLocalAsset: Bool { viewer.isUploading(currentAsset.id) }
    private var matchingDetail: AssetResponseDTO? {
        guard vm?.detail?.id == currentServerAssetID else { return nil }
        return vm?.detail
    }
    private var currentTarget: AssetViewerState.Target {
        viewer.target(serverID: currentServerAssetID, detail: matchingDetail)
    }

    private var isPanelDragging: Bool { panelDragStart != nil }
    private var isPanelAtMax: Bool { panelHeight >= panelMaxHeight - 1 }

    /// Filmstrip menunggu panel selesai menutup agar tidak bertabrakan.
    /// Navigation bar dan status bar kembali sejak awal penutupan, supaya
    /// foto langsung memakai safe area akhirnya, termasuk setelah resize.
    private var showInfo: Bool { isPanelMounted }

    // Body sengaja dipecah berlapis. Sebagai satu rantai modifier utuh,
    // ekspresinya terlalu besar untuk type-checker Swift ("unable to
    // type-check this expression in reasonable time"). Tiap lapis punya
    // anotasi `some View` eksplisit, jadi type-checking-nya selesai per bagian.
    var body: some View {
        Group {
            if visibilityPolicy.allows(id: currentAsset.id), !viewer.isEmpty {
                detailContent
            } else {
                Color(.systemBackground)
            }
        }
        .disabled(isApplyingLiveAction)
        .overlay {
            if isApplyingLiveAction {
                ProgressView("Applying edits…")
                    .padding(20).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
            }
        }
        .background {
            GeometryReader { _ in
                Color.clear
                    .onGeometryChange(for: CGSize.self) { $0.size } action: { updateViewport($0) }
            }
            .ignoresSafeArea()
            .allowsHitTesting(false)
        }
        .onChange(of: visibilityPolicy.state, initial: true) { _, _ in discardDisallowedPages() }
        .onChange(of: LocalPhotoLibrary.shared.revision, initial: true) { _, _ in
            discardInaccessibleDevicePages()
            if !DeviceCopyDeletion.hasDeviceCopy(for: currentAsset) {
                showRemoveDeviceConfirm = false
            }
        }
    }

    private func discardDisallowedPages() {
        let removesCurrent = !visibilityPolicy.allows(id: currentAsset.id)
        guard viewer.removeDisallowedPages(using: visibilityPolicy) else { return }
        finishPageAccessChange(currentChanged: removesCurrent)
    }

    private func discardInaccessibleDevicePages() {
        guard viewer.pages.contains(where: { LocalPhotoLibrary.isLocal($0.id) }) else { return }
        let visit = viewer.visit
        guard viewer.refreshLocalAccess(
            hasReadAccess: LocalPhotoLibrary.shared.isAuthorized,
            existingLocalIDs: LocalPhotoLibrary.existingLocalIdentifiers,
            serverIDsByLocalIdentifier: SwiftDataManager.shared.serverAssetIDsByLocalIdentifier()) else { return }
        finishPageAccessChange(currentChanged: visit != viewer.visit)
    }

    private func finishPageAccessChange(currentChanged: Bool) {
        if currentChanged {
            pagerController?.stopAllPlayback()
            vm?.invalidateSelection()
            photoEditorTarget = nil
            discardChangedSourceEditor()
            dateTarget = nil
            locationTarget = nil
            albumTarget = nil
            sharedLink = nil
            isSharePresented = false
            showDeleteConfirm = false
            showRemoveDeviceConfirm = false
            cleanupSharedFile()
        }
        if viewer.isEmpty {
            viewer.deactivate()
            dismiss()
        } else if currentChanged {
            loadCurrentMetadata()
        }
    }

    private var detailContent: some View {
        pager
            .safeAreaInset(edge: .bottom, spacing: 0) { bottomAccessory }
            .navigationTitle(navigationTitleText)
            .navigationBarTitleDisplayMode(.inline)
            // Tarik-untuk-menutup dimatikan saat zoom maupun saat panel info
            // terbuka — swipe ke bawah di situ artinya menutup panel.
            .interactiveDismissDisabled(isZoomed || showInfo)
            .statusBarHidden(isStatusBarHidden)
            .modifier(toolbarChrome)
            // TANPA `onTapGesture` di sini.
            //
            // Modifier ini menempel pada SELURUH susunan — termasuk strip
            // thumbnail yang dipasang lewat `safeAreaInset`. Gestur SwiftUI di
            // leluhur itu menelan ketukan sebelum sampai ke collection view strip,
            // jadi menekan thumbnail malah menyembunyikan toolbar alih-alih
            // berpindah foto. Ketukan pada fotonya sendiri sudah ditangani
            // recognizer milik `PhotoPagerCell` lewat `onTap`.
            .overlay(alignment: .bottom) { infoPanel }
            // URUTAN PENTING: gesture dipasang SETELAH overlay panel.
            //
            // `.overlay` membungkus hasil sebelumnya, jadi kalau gesture
            // dipasang lebih dulu, panel jadi view saudara — bukan turunan —
            // dan sentuhan di atas panel tidak pernah sampai ke recognizer.
            // Itulah kenapa swipe ke bawah di panel tidak menutupnya.
            //
            // `.gesture`, bukan `.simultaneousGesture`: representable UIKit
            // bukan `Gesture` sehingga tidak punya overload itu. Berbagi dengan
            // scroll & pinch sudah diatur lewat delegate recognizer-nya.
            .gesture(infoDragGesture)
            .toolbar { detailToolbar }
            .overlay { presentations }
            // Kegagalan aksi lewat sendiri, tidak menunggu ditutup — lihat
            // `ErrorToast`. Yang muncul di sini HANYA kegagalan yang dipicu
            // pengguna; gagal memuat detail sengaja diam (lihat `load`).
            .errorToast(actionErrorBinding)
            // TANPA pita offline, dari jalur mana pun — termasuk saat didorong
            // dari Library, di mana pitanya milik `MainTabView`.
            //
            // Pita itu keterangan tentang keadaan aplikasi, dan di sini ia
            // menyita ruang dari satu-satunya hal yang sedang dilihat. Layar ini
            // punya caranya sendiri untuk berterus terang: aksi yang gagal
            // memunculkan toast, dan panel info tetap terisi dari potret lokal.
            .onAppear {
                viewer.activate()
                OfflineBannerSuppression.shared.begin()
            }
            .onDisappear {
                OfflineBannerSuppression.shared.end()
                if photoEditorTarget == nil {
                    discardChangedSourceEditor()
                    viewer.deactivate()
                    vm?.invalidateSelection()
                }
            }
            .cancelDeviceCopyRemoval { deviceRemoval?.cancel() }
            .task { await start() }
            // Untuk pemanggil yang mendorong lewat navigationDestination
            // (People, Album) — jalur fullScreenCover menolaknya di akar scene
            // yang dipresentasikan, lihat TimelineView dan SearchResultsGrid.
            .ignoresSafeArea(.keyboard, edges: .bottom)
            .onChange(of: currentAsset) { oldAsset, newAsset in
                if isEditingDescription { saveDescriptionEdit(for: serverAssetID(for: oldAsset)) }
                onAssetChange?(newAsset)
                panelContentHeight = 0
                dateTarget = nil
                locationTarget = nil
                albumTarget = nil
                photoEditorTarget = nil
                discardChangedSourceEditor()
                showDeleteConfirm = false
                trashActionError = nil
                showRemoveDeviceConfirm = false
                loadCurrentMetadata()
            }
            .onChange(of: SwiftDataManager.shared.backupMappingRevision) { _, _ in
                refreshUploadedCopies()
            }
    }

    private var navigationTitleText: String {
        (matchingDetail?.fileCreatedAt ?? currentAsset.createdAt)
            .formatted(date: .abbreviated, time: .omitted)
    }

    private var isStatusBarHidden: Bool {
        (!showToolbar || panelHeight > 0) && !isEditingDescription
    }

    private var toolbarChrome: ToolbarChrome {
        ToolbarChrome(
            showToolbar: showToolbar,
            showInfo: panelHeight > 0,
            isEditing: isEditingDescription,
            usesTopToolbarOnly: usesTopToolbarOnly)
    }

    /// Pada iPad seluruh aksi digabung ke navigation bar seperti Photos.
    /// Compact width mempertahankan bottom bar agar tombol tidak berdesakan.
    private var usesTopToolbarOnly: Bool { horizontalSizeClass == .regular }

    private func toggleToolbar() {
        // Saat panel info terbuka, toolbar bawah adalah satu-satunya jalan
        // menutupnya lewat tombol — jangan disembunyikan.
        guard panelHeight <= 0 else { return }
        withAnimation(.easeInOut(duration: 0.28)) {
            showToolbar.toggle()
        }
    }

    /// Semua sheet/alert plus sinkronisasi status toolbar, ditempel lewat
    /// overlay kosong supaya rantai modifier di `body` tetap pendek.
    private var presentations: some View {
        stateSync
            .sheet(isPresented: $isSharePresented, onDismiss: cleanupSharedFile) { shareSheet }
            .fullScreenCover(item: $slideshow, onDismiss: { viewer.activate() }) { selection in
                PhotoSlideshowView(assets: selection.assets, session: session, initialAssetID: selection.initialAssetID,
                    visibilityPolicy: visibilityPolicy, prepareShare: slideshowFile)
            }
            .sheet(item: $sharedLink) { ShareSheet(url: $0.url) }
            .sheet(item: $dateTarget) { dateEditor($0) }
            .sheet(item: $locationTarget) { locationEditor($0) }
            .sheet(item: $albumTarget) { albumPicker($0) }
            .alert("This photo has changed", isPresented: Binding(
                get: { changedSourceEditor != nil },
                set: { if !$0 { changedSourceEditor = nil } }
            )) {
                Button("Start New Edit") {
                    if let prepared = changedSourceEditor, editorIsCurrent(prepared) {
                        photoEditorTarget = prepared
                    } else {
                        TemporaryMediaStore.remove(editorOwnedFiles)
                        editorOwnedFiles.removeAll()
                    }
                    changedSourceEditor = nil
                }
                Button("Cancel", role: .cancel) {
                    changedSourceEditor = nil
                    TemporaryMediaStore.remove(editorOwnedFiles)
                    editorOwnedFiles.removeAll()
                    viewer.activate()
                }
            } message: {
                Text("The source changed after your last edit. Start again with the current photo? Your previous edit will only be replaced when you save.")
            }
            .fullScreenCover(item: $photoEditorTarget, onDismiss: {
                TemporaryMediaStore.remove(editorOwnedFiles)
                editorOwnedFiles.removeAll()
                viewer.activate()
            }) { photoEditor($0) }
            .confirmationDialog(
                (removeDeviceTarget?.asset.needsUpload ?? currentAsset.needsUpload) ? "Remove This Photo?" : "Remove from Device",
                isPresented: $showRemoveDeviceConfirm,
                titleVisibility: .visible
            ) {
                Button("Remove from Device", role: .destructive) {
                    if let target = removeDeviceTarget { removeFromDevice(target) }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                if removeDeviceTarget?.asset.needsUpload == true {
                    Text("This is the only copy and it has not been uploaded yet.")
                } else {
                    Text("The local copy will be removed. The photo stays on your server.")
                }
            }
    }

    @ViewBuilder
    private func photoEditor(_ context: PhotoEditorTarget) -> some View {
        if context.document.kind == .photo {
            PhotoCropEditor(initialRecipe: context.document.photo, requiresSave: context.sourceChanged, loadImage: {
                await Task.detached(priority: .userInitiated) { UIImage(contentsOfFile: context.originalURL.path) }.value
            }, isAllowed: { editorIsCurrent(context) }, onSave: { recipe in
                var document = context.document
                document.photo = recipe.normalized()
                return await saveEditor(document, context: context)
            }, onRevert: { await revertEditor(context) })
        } else {
            MediaVideoEditor(sourceURL: context.motionURL ?? context.originalURL,
                stillURL: context.document.kind == .livePhoto ? context.originalURL : nil,
                isLivePhoto: context.document.kind == .livePhoto,
                video: context.document.video, live: context.document.live, photo: context.document.photo,
                isAllowed: { editorIsCurrent(context) }, onSave: { video, live, photo in
                    var document = context.document
                    document.photo = photo.normalized()
                    document.video = video
                    document.live = live
                    return await saveEditor(document, context: context)
                }, onRevert: { await revertEditor(context) })
        }
    }

    private func discardChangedSourceEditor() {
        guard changedSourceEditor != nil else { return }
        changedSourceEditor = nil
        TemporaryMediaStore.remove(editorOwnedFiles)
        editorOwnedFiles.removeAll()
    }

    private func editorIsCurrent(_ context: PhotoEditorTarget) -> Bool {
        !Task.isCancelled && context.requestContext == session.snapshot
            && context.target.asset.id == currentAsset.id
            && (serverAssetID(for: context.target.asset) ?? context.target.asset.id) == context.sourceID
            && visibilityPolicy.allows(id: context.target.asset.id)
            && visibilityPolicy.allows(id: context.sourceID)
    }

    private func saveEditor(_ document: MediaEditDocument, context: PhotoEditorTarget, readyVisit: UUID? = nil) async -> Bool {
        func isCurrent() -> Bool {
            editorIsCurrent(context) && (readyVisit == nil || readyVisit == viewer.visit)
        }
        guard isCurrent() else { return false }
        vm?.actionError = nil
        do {
            if let deviceID = document.deviceAssetID {
                guard let metadata = await LocalPhotoLibrary.shared.photoMetadata(for: deviceID),
                      MediaEditingPipeline.deviceFingerprint(metadata) == context.token.sourceFingerprint else {
                    throw MediaEditStoreError.sourceChanged
                }
            } else if let metadata = LocalSnapshot.load(AssetResponseDTO.self,
                for: LocalSnapshot.Key.assetDetail(context.sourceID)),
                      MediaEditingPipeline.fingerprint(metadata) != context.token.sourceFingerprint {
                throw MediaEditStoreError.sourceChanged
            }
            guard isCurrent() else { return false }
            let record = try MediaEditRecord(type: MediaEditingPipeline.recordType,
                schemaVersion: MediaEditingPipeline.schemaVersion,
                sourceFingerprint: context.token.sourceFingerprint, value: document)
            try MediaEditStore.shared.save(record, using: context.token, isCurrent: isCurrent)
            await pagerController?.reloadImage(for: context.target.asset.id)
            guard isCurrent() else { return false }
            onAssetUpdated?(context.sourceID)
            Task { await WidgetSnapshotExporter.refresh(session: session) }
            return true
        } catch {
            if isCurrent() { vm?.actionError = ErrorEvent(error.localizedDescription) }
            return false
        }
    }

    private func revertEditor(_ context: PhotoEditorTarget) async -> Bool {
        var original = context.document
        original.photo = PhotoEditRecipe()
        original.video = VideoEditRecipe()
        original.live = LivePhotoEditRecipe()
        return await saveEditor(original, context: context)
    }

    private func albumPicker(_ target: AssetViewerState.Target) -> some View {
        AlbumPickerSheet(albums: albums) { album in
            guard let serverID = target.serverID else { return }
            Task { await vm?.addToAlbum(serverID, album: album) }
        }
    }

    @ViewBuilder
    private func dateEditor(_ target: AssetViewerState.Target) -> some View {
        if let detail = target.detail, let serverID = target.serverID {
            AssetDateEditor(initialDate: detail.fileCreatedAt) { newDate in
                Task {
                    if await vm?.updateDate(serverID, to: newDate) == true {
                        recentlyViewedStore?.updateCaptureDate(serverID, to: newDate)
                        if serverAssetID(for: target.asset) == serverID {
                            viewer.setCaptureDate(newDate, for: target.asset.id)
                        }
                        onAssetUpdated?(serverID)
                    }
                }
            }
        }
    }

    private func locationEditor(_ target: AssetViewerState.Target) -> some View {
        AssetLocationEditor(initialCoordinate: Self.coordinate(for: target.detail)) { coordinate in
            guard let serverID = target.serverID else { return }
            Task {
                if await vm?.updateLocation(serverID, latitude: coordinate.latitude, longitude: coordinate.longitude) == true {
                    onAssetUpdated?(serverID)
                }
            }
        }
    }

    static func coordinate(for detail: AssetResponseDTO?) -> CLLocationCoordinate2D? {
        guard let exif = detail?.exifInfo, let lat = exif.latitude, let lon = exif.longitude else { return nil }
        return CLLocationCoordinate2D(latitude: lat, longitude: lon)
    }

    /// Menyalin status dari view model ke @State milik view ini.
    ///
    /// Nilai yang diamati diekstrak lebih dulu ke properti bertipe eksplisit;
    /// menulis `vm?.detail?.isFavorite` langsung di dalam `onChange` memaksa
    /// type-checker menyelesaikan optional chaining + generic `onChange` +
    /// closure sekaligus, dan itulah yang membuat ekspresinya meledak.
    private var stateSync: some View {
        vmStateSync
            // TANPA withAnimation.
            //
            // `isEditingDescription` dibaca di `body` (status bar, ToolbarChrome,
            // topToolbar), jadi membungkusnya dalam withAnimation menjadikan
            // SELURUH body satu transaksi beranimasi — pager, panel, dan foto
            // ikut bergerak walau tidak ada hubungannya dengan mode edit. Itu
            // yang terlihat sebagai "semuanya beranimasi aneh". Perpindahan
            // toolbar sendiri sudah punya animasi bawaan.
            .onChange(of: descriptionFocused) { _, focused in
                isEditingDescription = focused
                if focused { descriptionTarget = currentTarget }
                // Panel dinaikkan ke detent tertinggi begitu mulai menyunting.
                //
                // Keyboard menutupi bagian bawah layar tanpa menggeser panel —
                // itu memang disengaja (lihat catatan di `infoPanel`). Tapi
                // kalau tingginya dibiarkan, kolom deskripsinya justru berada di
                // balik keyboard: yang terlihat cuma keyboard muncul dan panel
                // diam di tempat.
                guard focused, panelMaxHeight > panelHeight else { return }
                animatePanel(to: panelMaxHeight)
            }
            // Haptic dipasang di luar toolbar builder karena modifier pada
            // tombol di dalamnya tidak selalu ikut aktif. Trigger-nya counter,
            // bukan nilai isFavorite — kalau memakai isFavorite, berpindah foto
            // yang status favoritnya berbeda ikut memicu haptic palsu.
            .sensoryFeedback(favoriteHaptic, trigger: favoriteFeedback)
            // Ketukan tegas sebagai tanda foto benar-benar sudah dihapus di
            // server, bukan sekadar dialog yang tertutup.
            .sensoryFeedback(.impact(weight: .heavy), trigger: deleteFeedback)
    }

    private var vmStateSync: some View {
        Color.clear
            .allowsHitTesting(false)
            .onChange(of: favoriteValue, initial: true) { _, newValue in
                isFavorite = newValue.value
            }
            .onChange(of: detailID, initial: true) { _, newValue in
                hasDetail = newValue.assetID != nil
            }
            .onChange(of: captureDateValue, initial: true) { _, newValue in
                if let date = newValue.date { viewer.setCaptureDate(date, for: newValue.assetID) }
            }
            .onChange(of: livePhotoValue, initial: true) { _, newValue in
                currentLivePhotoVideoID = newValue.videoID
                currentLivePhotoHint = newValue.hint
                currentLivePhotoContextAssetID = newValue.assetID
            }
    }

    private var favoriteValue: FavoriteDisplay {
        FavoriteDisplay(visit: viewer.visit, value: matchingDetail?.isFavorite ?? currentAsset.isFavorite)
    }
    private var detailID: DetailDisplay { DetailDisplay(visit: viewer.visit, assetID: matchingDetail?.id) }
    private var captureDateValue: CaptureDateDisplay {
        CaptureDateDisplay(visit: viewer.visit, assetID: currentAsset.id, date: matchingDetail?.fileCreatedAt)
    }
    private var livePhotoValue: LivePhotoDisplay {
        let detail = matchingDetail
        let hint = detail.map {
            LocalLivePhotoMatchHint(createdAt: $0.fileCreatedAt,
                pixelWidth: $0.exifInfo?.exifImageWidth,
                pixelHeight: $0.exifInfo?.exifImageHeight,
                originalFileName: $0.originalFileName)
        }
        return LivePhotoDisplay(visit: viewer.visit, assetID: currentAsset.id,
            videoID: detail?.livePhotoVideoId ?? currentAsset.livePhotoVideoID, hint: hint)
    }

    private var favoriteHaptic: SensoryFeedback {
        isFavorite ? .success : .impact(flexibility: .soft)
    }

    @ViewBuilder
    private var shareSheet: some View {
        if let url = downloadedFileURL {
            PhotoShareSheet(urls: [url], assetIDs: sharedAssetIDs,
                    sourceIDs: sharedSourceIDs, requestContext: sharedRequestContext,
                isAllowed: { [policy = visibilityPolicy] in policy.allows(id: $0) })
        }
    }

    @ViewBuilder
    private var bottomAccessory: some View {
        if !visibleAssets.isEmpty {
            // Slot safe-area sengaja selalu terpasang. Melepas dan memasangnya
            // bersamaan dengan panel mengubah tinggi GeometryReader secara
            // mendadak, sehingga foto melakukan layout kedua di tengah animasi.
            // Yang berubah selama transisi hanya opacity dan hit testing.
            let isVisible = !showInfo && showToolbar && !isZoomed
            VStack(spacing: 10) {
                // Bar kontrol hanya untuk video, dan letaknya DI ATAS strip —
                // strip tetap dipakai untuk berpindah aset.
                if currentAsset.isVideo, let pagerController {
                    PhotoVideoControlsView(pager: pagerController)
                        .frame(height: 48)
                        .padding(.horizontal, 28)
                }

                PhotoFilmstripView(
                    assets: visibleAssets,
                    currentAssetID: currentAsset.id,
                    onSelect: { asset in currentAsset = asset },
                    onControllerReady: { filmstripController = $0 },
                    visibilityPolicy: visibilityPolicy,
                    session: session)
                    .frame(height: 54)
            }
            .opacity(isVisible ? 1 : 0)
            .allowsHitTesting(isVisible)
            .accessibilityHidden(!isVisible)
            .animation(
                .easeInOut(duration: PhotoPagerLayout.chromeTransitionDuration),
                value: isVisible)
        }
    }

    /// Panel info sebagai OVERLAY, bukan `safeAreaInset`.
    ///
    /// Lewat safe area, munculnya panel mengubah tinggi yang tersedia untuk
    /// foto, sehingga foto dihitung ulang dan diubah ukurannya di UIKit — itu
    /// yang membuat animasinya patah. Sebagai overlay, layout foto tidak
    /// terganggu: foto cukup berpindah ke mode full width dan menempel di atas,
    /// lalu panel menutupinya secara bertahap.
    @ViewBuilder
    private var infoPanel: some View {
        if trashActions == nil, isPanelMounted, let detail = matchingDetail {
            panelBody(for: detail)
                // Tinggi viewport panel TETAP selama drag. Yang bergerak hanya
                // transform layer-nya lewat `offset` di bawah.
                //
                // Mengubah `.frame(height:)` pada setiap event pan memaksa
                // seluruh ScrollView — termasuk Map, kartu metadata, dan
                // pengukuran scroll — layout ulang setiap frame. Itulah sumber
                // patah-patah ketika panel ditarik turun.
                .frame(height: panelMaxHeight, alignment: .top)
                .clipped()
                // Overlay berhenti di batas safe area, jadi tanpa ini area
                // toolbar bawah + home indicator tetap tembus pandang dan foto
                // di belakangnya terlihat menyembul.
                .background(Color(.systemGroupedBackground))
                // INI kuncinya: panel dipatok ke tepi bawah LAYAR, bukan ke
                // safe area.
                //
                // Sebagai overlay bottom-aligned, posisinya dulu mengikuti safe
                // area view induk — dan safe area itu berubah dua kali saat
                // mulai mengedit: keyboard muncul, lalu bottom toolbar
                // disembunyikan. Setiap perubahan menggeser panel, dan
                // mengoreksinya dengan offset hanya menambah gerakan kedua yang
                // tidak pernah sinkron dengan yang pertama.
                //
                // Dengan mengabaikan safe area bawah sepenuhnya, tepi bawah
                // panel selalu di tepi layar: keyboard naik menutupinya tanpa
                // menggesernya, persis seperti di Photos.
                .ignoresSafeArea(.all, edges: .bottom)
                // Panel setinggi `panelMaxHeight` dipatok di bawah. Bagian yang
                // belum terbuka cukup digeser melewati tepi layar; ini hanya
                // compositing transform dan tidak mengukur ulang isi panel.
                .offset(y: max(0, panelMaxHeight - panelHeight))
        }
    }

    private func panelBody(for detail: AssetResponseDTO) -> AssetInfoPanel {
        let selected = vm?.currentSelection(for: detail.id)
        return AssetInfoPanel(
            detail: detail,
            // Daftar baru bisa di-scroll di detent tertinggi; di bawah itu
            // panel inert supaya tarikan mengubah tingginya.
            isScrollEnabled: isPanelAtMax,
            // Hanya diambil nilai terbesar yang pernah terukur.
            //
            // Tinggi isi itu sifatnya intrinsik, tapi laporannya bisa datang
            // dalam keadaan setengah jadi — mis. baris description sudah
            // terukur sementara isi scroll masih 0, atau saat panel mengecil di
            // animasi menutup. Nilai parsial semacam itu dulu tersimpan dan
            // membuat bukaan berikutnya jadi pendek sekali.
            //
            // Juga diabaikan selagi drag: nilai ini menentukan panelMaxHeight
            // yang dipakai clampPanel, jadi perubahannya di tengah tarikan bisa
            // balik menggeser panelHeight dan memicu osilasi.
            onIntrinsicHeightChange: { newHeight in
                guard !isPanelDragging, newHeight > 0 else { return }
                let wasExpanded = isPanelAtMax
                panelContentHeight = max(panelContentHeight, newHeight)
                if wasExpanded { panelHeight = panelMaxHeight }
            },
            onScrollOffsetChange: { newOffset in
                // Perubahan tinggi/posisi panel dapat memicu laporan geometry
                // walaupun ScrollView tidak sedang digulir. Jangan biarkan
                // callback itu menambah invalidasi state di tengah pan.
                guard !isPanelDragging,
                      abs(panelScrollOffset - newOffset) > 0.5
                else { return }
                panelScrollOffset = newOffset
            },
            descriptionDraft: $descriptionDraft,
            descriptionFocus: $descriptionFocused,
            onAdjustDate: { dateTarget = currentTarget },
            onAdjustLocation: { locationTarget = currentTarget },
            containingAlbums: vm?.containingAlbums ?? [],
            onAlbumContentsChanged: { id, assets in
                guard let selected else { return }
                vm?.applyAlbumContents(assets, to: id, for: selected)
            },
            onAlbumChanged: { album in
                guard let selected else { return }
                vm?.applyAlbumUpdate(album, for: selected)
            },
            onAlbumDeleted: { id in
                guard let selected else { return }
                vm?.removeDeletedAlbum(id, for: selected)
            },
            onAlbumShared: { id in
                guard let selected else { return }
                vm?.applyAlbumShared(id, for: selected)
            })
    }

    // MARK: - Detent panel

    private var panelLayout: AssetInfoPanelLayout {
        AssetInfoPanelLayout(viewportHeight: viewportSize.height, contentHeight: panelContentHeight)
    }

    private func updateViewport(_ size: CGSize) {
        guard size.width > 0, size.height > 0, size != viewportSize else { return }
        let next = AssetInfoPanelLayout(viewportHeight: size.height, contentHeight: panelContentHeight)
        let height = next.resizedHeight(panelHeight, from: panelLayout)
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            viewportSize = size
            panelHeight = height
            panelDragStart = nil
            cardViewport = nil
        }
    }

    /// Batas atas tarikan: menyisakan seperempat layar teratas untuk foto, dan
    /// tidak melebihi tinggi alami isi panel — konten yang sedikit tidak boleh
    /// ditarik lebih tinggi dari isinya. Tidak pernah lebih pendek dari tinggi
    /// standar, supaya bukaan normal selalu bisa dicapai.
    private var panelMaxHeight: CGFloat {
        panelLayout.maximumHeight
    }

    /// Tertutup, standar, dan penuh — panel di-snap ke salah satunya saat jari
    /// dilepas. Detent penuh dilewati kalau isinya memang tidak setinggi itu.
    private var panelDetents: [CGFloat] {
        panelLayout.detents
    }

    /// Satu-satunya gesture untuk panel — berlaku di area foto maupun di badan
    /// panel. Aturan arah dan siapa yang mengalah diputuskan di dalam
    /// recognizer-nya, bukan di sini.
    private var infoDragGesture: PanelPanGesture {
        PanelPanGesture(
            panelHeight: panelHeight,
            panelScrollEnabled: isPanelAtMax,
            panelScrollAtTop: panelScrollOffset <= 0.5,
            viewportSize: viewportSize,
            onChanged: { translationY in
                guard trashActions == nil, !isZoomed else { return }
                // Menarik ke atas dari layar detail yang belum punya info hanya
                // menyeret panel kosong; gerakannya dibiarkan lewat kalau
                // panelnya memang sudah terbuka, supaya tetap bisa ditutup.
                guard hasDetail || panelHeight > 0 else { return }
                dragChanged(translationY)
            },
            onEnded: { translationY, velocityY in
                guard trashActions == nil else { return }
                dragEnded(translationY, velocity: velocityY)
            }
        )
    }

    private func dragChanged(_ translationY: CGFloat) {
        let start = panelDragStart ?? panelHeight
        // Tarikan ke BAWAH saat panel sudah tertutup bukan urusan panel — itu
        // gestur menutup layar.
        //
        // Membiarkannya lewat berarti satu peristiwa yang arahnya sempat terbaca
        // ke atas bisa membuka panel sekejap, dan begitu panel terbuka toolbar
        // langsung dilepas dari hierarki — bukan memudar. Itu yang terlihat
        // seperti toolbar hilang seketika saat mulai menarik.
        if start <= 0, translationY > 0 { return }
        // Gesture harus mengikuti jari tanpa mewarisi transaksi animasi dari
        // toolbar, keyboard, atau snap panel yang baru saja selesai.
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            if panelDragStart == nil { panelDragStart = start }
            // Tarik ke atas (translation negatif) = panel membesar.
            panelHeight = clampPanel(start - translationY)
            if panelHeight > 0 { isPanelMounted = true }
        }
    }

    private func dragEnded(_ translationY: CGFloat, velocity velocityY: CGFloat) {
        guard let start = panelDragStart else { return }
        panelDragStart = nil
        settlePanel(from: start, translationY: translationY, velocityY: velocityY)
    }

    private func clampPanel(_ value: CGFloat) -> CGFloat {
        min(max(0, value), panelMaxHeight)
    }

    /// 0 = foto masih dalam mode card, 1 = sudah full width menempel di atas.
    /// Dipakai untuk menginterpolasi layout foto mengikuti jari, bukan
    /// melompat ke mode lain begitu panel mulai ditarik.
    private var expandProgress: CGFloat {
        guard panelDetents[1] > 0 else { return 0 }
        return min(1, panelHeight / panelDetents[1])
    }

    /// Snap ke detent terdekat dengan memperhitungkan kecepatan lemparan.
    private func settlePanel(
        from start: CGFloat,
        translationY: CGFloat,
        velocityY: CGFloat
    ) {
        // Proyeksi posisi akhir ala UIKit decelerate: seperempat detik ke depan.
        let projected = start - (translationY + velocityY * 0.25)
        let target = panelDetents.min {
            abs($0 - projected) < abs($1 - projected)
        } ?? 0

        animatePanel(to: target)
    }

    /// Menganimasikan tinggi panel, lalu melepas view-nya hanya setelah animasi
    /// menutup benar-benar selesai.
    private func animatePanel(to target: CGFloat) {
        // Panel ditutup sementara field deskripsi masih fokus = keyboard dan
        // toolbar mode edit tertinggal di layar tanpa panel yang memilikinya.
        // Perlakukan seperti menekan tombol simpan.
        if target <= 0 && isEditingDescription {
            saveDescriptionEdit()
        }
        if target > 0 { isPanelMounted = true }

        // Panel SwiftUI dan refit foto UIKit memakai durasi + kurva yang sama.
        // Animator berbeda sebelumnya membuat foto mengejar panel, sehingga
        // pergerakan yang sebenarnya lancar tetap tampak tersendat.
        withAnimation(
            .easeInOut(duration: PhotoPagerLayout.panelTransitionDuration)
        ) {
            panelHeight = target
            // Panel terbuka → toolbar atas dan strip thumbnail ikut hilang.
            if target > 0 { showToolbar = true }
        } completion: {
            if panelHeight <= 0 { isPanelMounted = false }
        }
    }

    private var savedDescription: String {
        matchingDetail?.exifInfo?.description ?? ""
    }

    private func cancelDescriptionEdit() {
        descriptionDraft = savedDescription
        descriptionFocused = false
    }

    /// `assetID` harus diberikan eksplisit saat dipanggil dari `onChange(of:
    /// currentAsset)` — di sana `currentAsset` sudah berpindah ke foto baru,
    /// sehingga teks milik foto lama akan tersimpan ke foto yang salah.
    private func saveDescriptionEdit(for assetID: String? = nil) {
        let trimmed = descriptionDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        descriptionDraft = trimmed
        descriptionFocused = false
        let target = descriptionTarget ?? currentTarget
        descriptionTarget = nil
        guard trimmed != (target.detail?.exifInfo?.description ?? "") else { return }
        guard let id = assetID ?? target.serverID else { return }
        Task { await vm?.updateDescription(id, to: trimmed) }
    }

    private func setInfo(_ open: Bool) {
        animatePanel(to: open ? panelDetents[1] : 0)
    }

    /// Pesannya sendiri yang dijadikan binding, bukan bool + teks terpisah.
    /// Toast-nya mengosongkannya sendiri setelah beberapa detik.
    private var actionErrorBinding: Binding<ErrorEvent?> {
        Binding(
            get: { trashActions == nil ? vm?.actionError : trashActionError },
            set: {
                if trashActions == nil { vm?.actionError = $0 }
                else { trashActionError = $0 }
            }
        )
    }

    // MARK: - Jendela halaman

    private func start() async {
        if recentlyViewedStore == nil { recentlyViewedStore = .forAccount(session.accountOwner) }
        if vm == nil {
            let api = APIClient(session: session)
            vm = AssetDetailViewModel(repo: AssetDetailRepository(api: api), albumRepo: AlbumRepository(api: api))
        }
        refreshUploadedCopies(loadMetadata: false)
        await loadCurrentMetadataTask()
        if trashActions == nil { await vm?.loadAlbumsIfNeeded() }
    }

    private func loadCurrentMetadata() {
        guard let vm else { return }
        guard !viewer.isEmpty else {
            metadataKey = nil
            vm.invalidateSelection()
            return
        }
        let target = currentTarget
        let key = MetadataKey(visit: target.visit, assetID: target.serverID ?? target.asset.id)
        guard metadataKey != key else { return }
        metadataKey = key
        let selection = vm.selectAsset(target.serverID ?? target.asset.id)
        Task { await loadMetadata(target, selection: selection, model: vm) }
    }

    private func loadCurrentMetadataTask() async {
        guard let vm else { return }
        let target = currentTarget
        metadataKey = MetadataKey(visit: target.visit, assetID: target.serverID ?? target.asset.id)
        let selection = vm.selectAsset(target.serverID ?? target.asset.id)
        await loadMetadata(target, selection: selection, model: vm)
    }

    private func loadMetadata(_ target: AssetViewerState.Target,
        selection: AssetDetailViewModel.Selection, model: AssetDetailViewModel) async {
        await model.load(selection)
        guard !Task.isCancelled, viewer.isCurrent(target), model.isCurrent(selection) else { return }
        if trashActions == nil, visibilityPolicy.scope != .locked, visibilityPolicy.removalScope != .trash,
           case .loaded = model.phase, let detail = model.detail, detail.id == target.serverID {
            recentlyViewedStore?.record(detail)
        }
        if trashActions == nil, target.serverID != nil { await model.loadContainingAlbums(selection) }
    }

    private func refreshUploadedCopies(loadMetadata: Bool = true) {
        viewer.refreshUploadedCopies(using: SwiftDataManager.shared)
        if loadMetadata, let serverID = currentServerAssetID, matchingDetail?.id != serverID {
            loadCurrentMetadata()
        }
    }

    private var pager: some View {
        // GeometryReader ini SENGAJA tidak ikut mengabaikan safe area:
        // `geo.size` = tinggi area aman sesungguhnya (di bawah navigation bar,
        // di atas strip thumbnail). Nilai itu dikirim ke sel sebagai batas tinggi
        // konten. Mengandalkan bounds scroll view tidak bisa — scroll view-nya
        // memang selalu selayar penuh supaya paging dan zoom memakai seluruh
        // layar.
        GeometryReader { geo in
            // Kotak area aman di koordinat layar: tingginya sudah mengecualikan
            // navigation bar dan strip thumbnail, dan titik tengahnya sedikit di
            // atas titik tengah layar — kalau konten dipusatkan ke tengah layar
            // penuh, bagian bawahnya menabrak strip.
            let box = geo.frame(in: .global)
            let liveViewport = AssetCardViewport(
                height: max(1, box.height - 16),
                centerY: box.midY)
            let stableViewport = cardViewport ?? liveViewport

            PhotoPagerView(
                assets: visibleAssets,
                currentAssetID: currentAsset.id,
                // Detail lengkap adalah sumber paling baru; fallback menjaga
                // Live Photo tetap bekerja saat layar dibuka offline.
                livePhotoVideoID: currentLivePhotoContextAssetID == currentAsset.id
                    ? (currentLivePhotoVideoID ?? currentAsset.livePhotoVideoID)
                    : currentAsset.livePhotoVideoID,
                localLivePhotoHint: currentLivePhotoContextAssetID == currentAsset.id
                    ? currentLivePhotoHint
                    : nil,
                layout: pagerLayout(
                    available: stableViewport.height,
                    centerY: stableViewport.centerY),
                // Zoom yang belum menghasilkan ruang pan horizontal tetap boleh
                // memakai swipe untuk pindah halaman. Penguncian zoom dihitung
                // langsung oleh controller dari lebar konten aktual.
                isPagingEnabled: !showInfo && !isEditingDescription,
                onPageChanged: { asset in
                    currentAsset = asset
                },
                onZoomChanged: { handleZoomChange($0) },
                onTap: { toggleToolbar() },
                // Strip digeser LANGSUNG dari pager, tanpa melewati `@State`.
                //
                // Nilainya berubah tiap frame selama usapan; menyalurkannya lewat
                // SwiftUI berarti membangun ulang body sebanyak itu juga.
                onScrollProgress: { filmstripController?.track(page: $0) },
                onControllerReady: { pagerController = $0 },
                visibilityPolicy: visibilityPolicy,
                session: session)
                // Simpan hanya ketika panel benar-benar tertutup. Saat panel
                // bergerak, perubahan safe area dari toolbar tidak boleh
                // mengganti titik awal interpolasi foto.
                .onChange(of: liveViewport, initial: true) { _, newViewport in
                    guard !showInfo, showToolbar, !isZoomed else { return }
                    cardViewport = newViewport
                }
                // Yang mengabaikan safe area HANYA pagernya, bukan
                // `GeometryReader`-nya.
                //
                // Kalau modifier ini dipasang di luar, `geo.height` ikut menjadi
                // tinggi layar penuh — dan batas tinggi yang dikirim ke sel jadi
                // begitu longgar sehingga tidak ada foto yang pernah dianggap
                // terlalu tinggi. Itu yang membuat foto panjang berhenti mengecil
                // dan kehilangan sudut membulatnya.
                .ignoresSafeArea(.all, edges: .all)
        }
    }

    /// Aturan tata letak foto, dirakit dari keadaan layar ini.
    ///
    /// Nilai `available` dan `centerY` menggambarkan layout CARD; layout expanded
    /// dihitung di sisi UIKit, lalu keduanya di-interpolasi memakai
    /// `expandProgress`.
    private func pagerLayout(available: CGFloat, centerY: CGFloat) -> PhotoPagerLayout {
        PhotoPagerLayout(
            maxContentHeight: cardLayout ? available : 0,
            contentCenterY: cardLayout ? centerY : 0,
            expandProgress: expandProgress,
            cornerRadius: cardLayout ? 24 : 0,
            // Panel terbuka → pinch dan double tap dimatikan; foto sedang jadi
            // latar, bukan objek utama.
            isZoomEnabled: panelHeight <= 0,
            // Badge LIVE adalah bagian dari chrome seperti toolbar: ketukan
            // full-view menyembunyikan semuanya, lalu menampilkannya bersama.
            showsLivePhotoBadge: showToolbar && !showInfo,
            // Drag = ikuti jari tanpa animasi. Tombol info atau snap = animasikan.
            animates: !isPanelDragging)
    }

    private func handleZoomChange(_ zoomed: Bool) {
        // Hanya tulis saat berubah; kalau tidak, parent ikut re-render di
        // setiap frame pinch.
        guard isZoomed != zoomed else { return }
        isZoomed = zoomed
        // Mulai zoom → toolbar langsung sembunyi; kembali ke skala 1 →
        // toolbar (dan indicator) muncul lagi.
        withAnimation(.easeInOut(duration: 0.28)) {
            showToolbar = !zoomed
        }
    }

    @ToolbarContentBuilder
    private var detailToolbar: some ToolbarContent {
        topToolbar
        if !usesTopToolbarOnly {
            bottomToolbar
        }
    }

    @ToolbarContentBuilder
    private var topToolbar: some ToolbarContent {
        // Mode edit deskripsi mengambil alih navigation bar: batal di kiri,
        // simpan di kanan. Aksesori keyboard tidak dipakai karena pendaftaran
        // `placement: .keyboard` dari dalam overlay tidak konsisten.
        if trashActions != nil {
            if isModal {
                ToolbarItem(placement: .topBarLeading) { closeButton }
            }
            if usesTopToolbarOnly {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    restoreButton
                    deleteButton
                }
            }
        } else if isEditingDescription {
            ToolbarItem(placement: .topBarLeading) { cancelEditButton }
            ToolbarItem(placement: .topBarTrailing) { saveEditButton }
        } else if usesTopToolbarOnly {
            ToolbarItemGroup(placement: .topBarLeading) {
                if isModal { closeButton }
                shareButton
                if !currentAsset.needsUpload { favoriteButton }
            }

            ToolbarItemGroup(placement: .topBarTrailing) {
                if currentAsset.needsUpload {
                    uploadButton
                    editPhotoButton
                } else {
                    // Urutannya mengikuti Photos iPad: edit, info, hapus,
                    // kemudian menu tindakan tambahan.
                    editPhotoButton
                    infoButton
                    deleteButton
                }
                detailActionsMenu
            }
        } else {
            if isModal {
                ToolbarItem(placement: .topBarLeading) { closeButton }
            }
            ToolbarItem(placement: .topBarTrailing) { detailActionsMenu }
        }
    }

    private var detailActionsMenu: some View {
        Menu {
            Button("Copy", systemImage: "doc.on.doc") { copyCurrentMedia() }
                .disabled(viewer.isPreparing(.copy))

            if currentAsset.isVideo, let pagerController {
                let options = pagerController.playbackOptions
                Picker(selection: Binding(get: { options.rate }, set: { pagerController.setPlaybackRate($0) })) {
                    ForEach(options.availableRates, id: \.self) { rate in
                        Text(String(format: "%g×", rate)).tag(rate)
                    }
                } label: { Label("Playback Speed", systemImage: "speedometer") }
                .pickerStyle(.menu)
                Toggle(isOn: Binding(get: { options.isLooping }, set: { looping in
                    if looping != options.isLooping { pagerController.toggleLooping() }
                })) { Label("Loop Video", systemImage: "repeat") }
            }

            if currentAsset.isLivePhoto, trashActions == nil {
                Menu("Live Photo", systemImage: "livephoto") {
                    ForEach(LivePhotoEditRecipe.Mode.allCases) { mode in
                        Button(mode.title) { preparePhotoEditor(action: .liveMode(mode)) }
                    }
                }
                .disabled(isPreparingEditor || isApplyingLiveAction)
                Button("Save as Video", systemImage: "video.badge.plus") {
                    preparePhotoEditor(action: .saveLiveVideo)
                }
                .disabled(isPreparingEditor || isApplyingLiveAction)
            }

            if visibilityPolicy.scope != .locked, trashActions == nil {
                Button("Slideshow", systemImage: "play.rectangle") {
                    slideshow = PhotoSlideshowPresentation(assets: visibleAssets, initialAssetID: currentAsset.id)
                }
            }

            if let serverID = currentServerAssetID {
                Button {
                    createSharedLink(for: serverID)
                } label: {
                    Label("Share Link", systemImage: "link")
                }

                Button("Adjust Date & Time", systemImage: "calendar.badge.clock") {
                    dateTarget = currentTarget
                }
                .disabled(matchingDetail == nil)

                Button("Adjust Location", systemImage: "mappin.and.ellipse") {
                    locationTarget = currentTarget
                }
                .disabled(matchingDetail == nil)
            }

            // Aset lokal belum menjadi bagian dari library server, jadi belum
            // boleh dipakai sebagai foto profil. Setelah upload selesai,
            // `currentServerAssetID` tersedia dan aksi ini ikut muncul.
            if !currentAsset.isVideo, currentServerAssetID != nil {
                Button {
                    setAsProfilePhoto()
                } label: {
                    Label("Set as Profile Photo", systemImage: "person.crop.circle")
                }
                .disabled(isSettingProfilePhoto)
            }

            if currentAsset.origin == .server {
                Button {
                    downloadToDevice()
                } label: {
                    Label("Download", systemImage: "arrow.down.circle")
                }
                .disabled(isDownloadingToDevice)
            }

            if let serverID = currentServerAssetID {
                Section("Move to") {
                    Button {
                        moveAsset(to: .locked)
                    } label: {
                        Label("Locked Folder", systemImage: "lock")
                    }

                    Button {
                        guard serverID == currentServerAssetID else { return }
                        moveAsset(to: Self.archiveDestination(for: serverID, detail: matchingDetail))
                    } label: {
                        Label(Self.archiveDestination(for: serverID, detail: matchingDetail) == .timeline
                            ? "Unarchive" : "Archive", systemImage: "archivebox")
                    }
                }

                Button("Add to Album", systemImage: "rectangle.stack.badge.plus") {
                    albumTarget = currentTarget
                }
            }

            // Jangan percaya `origin` saja. Foto bisa sudah dihapus lewat
            // Photos/aplikasi lain sementara halaman detail masih memegang
            // snapshot `.both` yang lama.
            if DeviceCopyDeletion.hasDeviceCopy(for: currentAsset) {
                Divider()
                Button(role: .destructive) {
                    removeDeviceTarget = currentTarget
                    showRemoveDeviceConfirm = true
                } label: {
                    Label("Remove from Device", systemImage: "iphone.slash")
                }
                .disabled(deviceRemoval != nil)
            }

            if currentServerAssetID != nil {
                Divider()
                Button(role: .destructive) {
                    deleteTarget = currentTarget
                    showDeleteConfirm = true
                } label: {
                    Label("Delete", systemImage: "trash")
                }
            }
        } label: {
            if isDownloadingToDevice || isSettingProfilePhoto {
                ProgressView()
            } else {
                Image(systemName: "ellipsis")
            }
        }
        .accessibilityLabel("More")
    }

    private func copyCurrentMedia() {
        let target = currentTarget
        let generation = LocalSnapshot.generation
        let context = session.snapshot
        viewer.prepare(target, kind: .copy, operation: { () async -> [MediaCopy.Item]? in
            guard copyIsCurrent(target, generation: generation, context: context) else { return nil }
            vm?.actionError = nil
            guard let file = await fileURL(for: target) else {
                if copyIsCurrent(target, generation: generation, context: context), vm?.actionError == nil {
                    vm?.actionError = ErrorEvent(MediaCopy.CopyError.unavailable.localizedDescription)
                }
                return nil
            }
            defer { TemporaryMediaStore.remove(file) }
            do {
                return try await MediaCopy.prepare([.init(url: file, isVideo: PhotoExportService.contentType(of: file).conforms(to: .movie))])
            } catch {
                if copyIsCurrent(target, generation: generation, context: context), !(error is CancellationError) {
                    vm?.actionError = ErrorEvent(error.localizedDescription)
                }
                return nil
            }
        }) { items in
            guard copyIsCurrent(target, generation: generation, context: context) else { return }
            MediaCopy.write(items)
        }
    }

    private func copyIsCurrent(_ target: AssetViewerState.Target, generation: UUID, context: SessionRequestContext) -> Bool {
        !Task.isCancelled && generation == LocalSnapshot.generation && viewer.isCurrent(target)
            && (try? APIClient(session: session).checkCurrent(context)) != nil
            && serverAssetID(for: target.asset) == target.serverID
            && visibilityPolicy.allows(id: target.asset.id)
            && (target.serverID.map { visibilityPolicy.allows(id: $0) } ?? true)
    }

    private var cancelEditButton: some View {
        Button {
            cancelDescriptionEdit()
        } label: {
            Image(systemName: "xmark")
        }
    }

    private var saveEditButton: some View {
        Button {
            saveDescriptionEdit()
        } label: {
            Image(systemName: "checkmark")
        }
        .buttonStyle(.borderedProminent)
    }

    private var closeButton: some View {
        Button {
            dismiss()
        } label: {
            Image(systemName: "xmark")
        }
    }

    @ToolbarContentBuilder
    private var bottomToolbar: some ToolbarContent {
        if trashActions != nil {
            ToolbarItem(placement: .bottomBar) { restoreButton }
            ToolbarSpacer(.flexible, placement: .bottomBar)
            ToolbarItem(placement: .bottomBar) { deleteButton }
        } else if currentAsset.needsUpload {
            // Aset yang hanya ada di perangkat belum punya aksi server. Toolbar
            // sengaja hanya menawarkan dua hal yang benar-benar bisa dilakukan.
            ToolbarItem(placement: .bottomBar) { shareButton }
            ToolbarSpacer(.flexible, placement: .bottomBar)
            ToolbarItem(placement: .bottomBar) { editPhotoButton }
            ToolbarSpacer(.flexible, placement: .bottomBar)
            ToolbarItem(placement: .bottomBar) { uploadButton }
        } else {
            ToolbarItem(placement: .bottomBar) { shareButton }
            ToolbarSpacer(.flexible, placement: .bottomBar)

            ToolbarItemGroup(placement: .bottomBar) {
                favoriteButton
                infoButton
                // Editor hanya untuk image; video tidak menyisakan placeholder.
                editPhotoButton
            }

            ToolbarSpacer(.flexible, placement: .bottomBar)
            ToolbarItem(placement: .bottomBar) { deleteButton }
        }
    }

    private var shareButton: some View {
        Button {
            shareFile()
        } label: {
            Label {
                Text("Share")
            } icon: {
                shareIcon
            }
        }
        .labelStyle(.iconOnly)
        .disabled(isPreparingShare || isSharePresented)
    }

    @ViewBuilder
    private var shareIcon: some View {
        if isPreparingShare {
            ProgressView()
        } else {
            Image(systemName: "square.and.arrow.up")
        }
    }

    private var favoriteButton: some View {
        Button {
            let target = currentTarget
            guard let id = target.serverID else { return }
            let value = !(target.detail?.isFavorite ?? target.asset.isFavorite)
            Task {
                if await vm?.toggleFavorite(id, to: value) == true {
                    recentlyViewedStore?.updateFavorite(id, to: value)
                    viewer.setFavorite(value, for: target.asset.id)
                    if viewer.isCurrent(target) {
                        isFavorite = value
                        favoriteFeedback += 1
                    }
                    onFavoriteChanged?(id, value)
                }
            }
        } label: {
            favoriteIcon
        }
        .disabled(currentServerAssetID == nil)
        .accessibilityLabel(isFavorite ? Text("Unfavorite") : Text("Favorite"))

    }

    /// Rantai symbol effect ini mahal untuk type-checker, jadi dipisah sendiri.
    private var favoriteIcon: some View {
        Image(systemName: isFavorite ? "heart.fill" : "heart")
            .foregroundStyle(isFavorite ? Color.red : Color.primary)
            // Morph heart ↔ heart.fill, lalu bounce sekali.
            .contentTransition(.symbolEffect(.replace))
            .symbolEffect(.bounce, value: favoriteFeedback)
    }

    /// Tombol info jadi toggle: menekannya lagi menutup panel.
    /// Satu-satunya tombol yang DIMATIKAN saat tidak ada isinya.
    ///
    /// Yang lain tetap hidup meski offline — mereka mengirim sesuatu ke server,
    /// dan kalau gagal, kegagalannya dikabarkan lewat toast. Tombol ini tidak
    /// mengirim apa pun; ia membuka panel. Membiarkannya bisa ditekan berarti
    /// menjanjikan panel yang tidak punya satu baris pun untuk digambar.
    private var infoButton: some View {
        Button {
            setInfo(!showInfo)
        } label: {
            Label("Info", systemImage: showInfo ? "info.circle.fill" : "info.circle")
        }
        .labelStyle(.iconOnly)
        .disabled(!hasDetail)
    }

    private var editPhotoButton: some View {
        Button {
            preparePhotoEditor()
        } label: {
            if isPreparingEditor {
                ProgressView()
            } else {
                Image(systemName: "slider.horizontal.3")
            }
        }
        .disabled(isPreparingEditor || isApplyingLiveAction)
        .accessibilityLabel(currentAsset.isVideo ? "Edit Video" : "Edit Photo")
    }

    private enum EditorAction { case edit, liveMode(LivePhotoEditRecipe.Mode), saveLiveVideo }

    private func preparePhotoEditor(action: EditorAction = .edit) {
        let target = currentTarget
        let sourceID = target.serverID ?? target.asset.id
        let request = session.snapshot
        guard visibilityPolicy.allows(id: target.asset.id), visibilityPolicy.allows(id: sourceID) else { return }
        viewer.prepareEditor(target, operation: { () async -> PhotoEditorTarget? in
            var owned: [URL] = []
            do {
                let saved = try MediaEditingPipeline.shared.savedEdit(for: target.asset.id, session: session)
                var document = saved?.document ?? MediaEditDocument()
                let recordID = saved?.assetID ?? sourceID
                let sourceDeviceID = document.deviceAssetID ?? (LocalPhotoLibrary.isLocal(sourceID) ? sourceID : nil)
                let source: URL
                let fingerprint: String
                var serverEdits: [AssetEditRecord] = []
                if let deviceID = sourceDeviceID {
                    guard let metadata = await LocalPhotoLibrary.shared.photoMetadata(for: deviceID),
                          let file = await LocalPhotoLibrary.shared.exportFile(for: deviceID) else {
                        throw PhotoEditRenderError.unavailable
                    }
                    defer { try? FileManager.default.removeItem(at: file.url) }
                    source = try TemporaryMediaStore.adoptShareFile(at: file.url, suggestedFilename: file.filename)
                    owned.append(source)
                    fingerprint = MediaEditingPipeline.deviceFingerprint(metadata)
                    document.deviceAssetID = deviceID
                    document.kind = metadata.isVideo ? .video : metadata.isLivePhoto ? .livePhoto : .photo
                } else {
                    let api = APIClient(session: session), repository = AssetDetailRepository(api: api)
                    let detail = try await repository.fetchAsset(sourceID)
                    fingerprint = MediaEditingPipeline.fingerprint(detail)
                    document.kind = detail.isVideo ? .video : detail.isLivePhoto ? .livePhoto : .photo
                    document.motionAssetID = detail.livePhotoVideoId
                    if document.kind == .photo { serverEdits = try await repository.edits(for: sourceID) }
                    source = try await repository.downloadOriginalFile(sourceID, filename: detail.originalFileName)
                    owned.append(source)
                    try await MediaEditingPipeline.validateOriginal(source, checksum: detail.checksum)
                    if saved == nil, document.kind == .photo {
                        let exif = detail.exifInfo
                        var size = CGSize(width: exif?.exifImageWidth ?? 0, height: exif?.exifImageHeight ?? 0)
                        if [5, 6, 7, 8, -90, 90].contains(Int(exif?.orientation ?? "") ?? 1) {
                            size = CGSize(width: size.height, height: size.width)
                        }
                        if size.width <= 0 || size.height <= 0,
                           let image = CGImageSourceCreateWithURL(source as CFURL, nil),
                           let properties = CGImageSourceCopyPropertiesAtIndex(image, 0, nil) as? [String: Any],
                           let width = properties[kCGImagePropertyPixelWidth as String] as? NSNumber,
                           let height = properties[kCGImagePropertyPixelHeight as String] as? NSNumber {
                            size = CGSize(width: width.doubleValue, height: height.doubleValue)
                            if [5, 6, 7, 8].contains((properties[kCGImagePropertyOrientation as String] as? NSNumber)?.intValue ?? 1) {
                                size = CGSize(width: size.height, height: size.width)
                            }
                        }
                        guard size.width > 0, size.height > 0 else { throw PhotoEditRenderError.unavailable }
                        document.photo = PhotoEditRecipe(serverEdits: serverEdits, originalPixelSize: size)
                    }
                }
                guard !Task.isCancelled, request == session.snapshot,
                      (serverAssetID(for: target.asset) ?? target.asset.id) == sourceID,
                      visibilityPolicy.allows(id: target.asset.id), visibilityPolicy.allows(id: sourceID) else {
                    throw CancellationError()
                }
                let sourceChanged = saved.map { $0.record.sourceFingerprint != fingerprint } ?? false
                if sourceChanged {
                    document.photo = PhotoEditRecipe()
                    document.video = VideoEditRecipe()
                    document.live = LivePhotoEditRecipe()
                }
                document.sourceAspectRatio = try await MediaEditingPipeline.sourceAspectRatio(source,
                    isVideo: document.kind == .video)
                if document.kind == .photo {
                    guard let image = CGImageSourceCreateWithURL(source as CFURL, nil),
                          CGImageSourceGetCount(image) == 1,
                          let type = CGImageSourceGetType(image) as String?,
                          UTType(type)?.conforms(to: .rawImage) != true else { throw PhotoEditRenderError.unavailable }
                }
                MediaEditStore.shared.configure(session: session)
                let token = try MediaEditStore.shared.capture(assetID: recordID, sourceFingerprint: fingerprint)
                guard try MediaEditStore.shared.read(using: token) == saved?.record else { throw MediaEditStoreError.editChanged }
                var motion: URL?
                if document.kind == .livePhoto {
                    if let deviceID = document.deviceAssetID {
                        guard let file = await LocalPhotoLibrary.shared.livePhotoMotionFile(for: deviceID) else {
                            throw MediaVideoEditError.unavailableVideo
                        }
                        defer { try? FileManager.default.removeItem(at: file.url) }
                        motion = try TemporaryMediaStore.adoptShareFile(at: file.url, suggestedFilename: file.filename)
                    } else if let id = document.motionAssetID {
                        motion = try await AssetDetailRepository(api: APIClient(session: session)).downloadOriginalFile(id, filename: id)
                    }
                    guard let motion else { throw MediaVideoEditError.unavailableVideo }
                    owned.append(motion)
                }
                guard !Task.isCancelled, request == session.snapshot,
                      (serverAssetID(for: target.asset) ?? target.asset.id) == sourceID,
                      visibilityPolicy.allows(id: target.asset.id), visibilityPolicy.allows(id: sourceID) else { throw CancellationError() }
                return PhotoEditorTarget(target: target, sourceID: sourceID, requestContext: request,
                    originalURL: source, motionURL: motion, document: document, token: token,
                    ownedFiles: owned, sourceChanged: sourceChanged)
            } catch {
                TemporaryMediaStore.remove(owned)
                if !Task.isCancelled, request == session.snapshot, viewer.isCurrent(target), !(error is CancellationError) {
                    vm?.actionError = ErrorEvent(error.localizedDescription)
                }
                return nil
            }
        }, discard: { TemporaryMediaStore.remove($0.ownedFiles) }) { prepared in
            let readyVisit = viewer.visit
            editorOwnedFiles = prepared.ownedFiles
            if prepared.sourceChanged { changedSourceEditor = prepared; return }
            switch action {
            case .edit: photoEditorTarget = prepared
            case .liveMode(let mode):
                guard prepared.document.kind == .livePhoto else {
                    TemporaryMediaStore.remove(prepared.ownedFiles)
                    if editorOwnedFiles == prepared.ownedFiles { editorOwnedFiles.removeAll() }
                    viewer.activate()
                    return
                }
                liveActionID = prepared.id
                var document = prepared.document
                document.live.mode = mode
                _ = await saveEditor(document, context: prepared, readyVisit: readyVisit)
                finishLiveAction(prepared, readyVisit: readyVisit)
            case .saveLiveVideo:
                liveActionID = prepared.id
                await saveLiveVideo(prepared, readyVisit: readyVisit)
                finishLiveAction(prepared, readyVisit: readyVisit)
            }
        }
    }

    private func finishLiveAction(_ context: PhotoEditorTarget, readyVisit: UUID) {
        TemporaryMediaStore.remove(context.ownedFiles)
        if editorOwnedFiles == context.ownedFiles { editorOwnedFiles.removeAll() }
        guard liveActionID == context.id else { return }
        liveActionID = nil
        if editorIsCurrent(context), viewer.visit == readyVisit { viewer.activate() }
    }

    private func saveLiveVideo(_ context: PhotoEditorTarget, readyVisit: UUID) async {
        guard context.document.kind == .livePhoto, let motion = context.motionURL, editorIsCurrent(context), viewer.visit == readyVisit else { return }
        var owned: [URL] = []
        defer { TemporaryMediaStore.remove(owned) }
        do {
            let output: URL
            if [.loop, .bounce].contains(context.document.live.mode) {
                let result = try await MediaLiveRenderer.shared.render(motionURL: motion,
                    stillURL: context.originalURL, video: context.document.video,
                    live: context.document.live, photo: context.document.photo)
                output = result.primaryURL
                owned += result.ownedURLs
            } else {
                output = try await MediaVideoRenderer.shared.renderVideo(sourceURL: motion,
                    video: context.document.video, photo: context.document.photo)
                owned.append(output)
            }
            guard editorIsCurrent(context), viewer.visit == readyVisit else { return }
            guard await LocalPhotoLibrary.shared.saveDownloadedFile(output, isVideo: true) != nil else {
                throw PhotoEditRenderError.unavailable
            }
        } catch {
            if editorIsCurrent(context), viewer.visit == readyVisit { vm?.actionError = ErrorEvent(error.localizedDescription) }
        }
    }

    private var uploadButton: some View {
        Button {
            uploadLocalAsset()
        } label: {
            if isUploadingLocalAsset {
                ProgressView()
            } else {
                Label("Upload", systemImage: "icloud.and.arrow.up")
            }
        }
        .disabled(isUploadingLocalAsset)
    }

    private func moveAsset(to visibility: AssetDetailRepository.Visibility) {
        let target = currentTarget
        guard let serverID = target.serverID else { return }
        viewer.remove(target, operation: { await vm?.move(serverID, to: visibility) == true }) { isPresented in
            onAssetRemoved?(target.asset.id)
            if isPresented {
                loadCurrentMetadata()
                if viewer.isEmpty { dismiss() }
            }
        }
    }

    static func archiveDestination(
        for id: String, detail: AssetResponseDTO?, dataManager: SwiftDataManager? = nil
    ) -> AssetDetailRepository.Visibility {
        let manager = dataManager ?? .shared
        guard !manager.privateAssetIDs.contains(id) else { return .archive }
        if manager.archivedAssetIDs.contains(id) { return .timeline }
        if manager.explicitTimelineAssetIDs.contains(id)
            || manager.getCachedAsset(id: id)?.isArchived == false { return .archive }
        let detailIsArchived = detail?.id == id && (detail?.visibility == "archive"
            || (detail?.visibility == nil && detail?.isArchived == true))
        return detailIsArchived ? .timeline : .archive
    }

    private var albums: [AlbumResponseDTO] {
        vm?.albums ?? []
    }

    private var restoreButton: some View {
        Button("Restore") {
            performTrash(.restore, target: currentTarget)
        }
        .disabled(currentServerAssetID == nil || viewer.isRemoving(currentAsset.id))
        .accessibilityIdentifier("trashViewer.restore")
    }

    private var deleteButton: some View {
        Button(role: .destructive) {
            deleteTarget = currentTarget
            showDeleteConfirm = true
        } label: {
            if trashActions == nil { Image(systemName: "trash") }
            else { Text("Delete Permanently") }
        }
        .disabled(trashActions != nil && (currentServerAssetID == nil || viewer.isRemoving(currentAsset.id)))
        .accessibilityLabel(trashActions == nil ? "Delete" : "Delete Permanently")
        .confirmationDialog(
            deleteConfirmationTitle,
            isPresented: $showDeleteConfirm,
            titleVisibility: .visible
        ) {
            Button(trashActions == nil ? "Delete" : "Delete Permanently", role: .destructive) {
                if let target = deleteTarget { performDelete(target) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            if trashActions == nil {
                Text((deleteTarget?.asset.isVideo ?? currentAsset.isVideo)
                    ? "Are you sure you want to delete this video?" : "Are you sure you want to delete this photo?")
            } else {
                Text("This cannot be undone.")
            }
        }
    }

    private var deleteConfirmationTitle: LocalizedStringKey {
        let isVideo = deleteTarget?.asset.isVideo ?? currentAsset.isVideo
        if trashActions != nil { return isVideo ? "Permanently Delete Video?" : "Permanently Delete Photo?" }
        return isVideo ? "Delete Video" : "Delete Photo"
    }

    private func performDelete(_ target: AssetViewerState.Target) {
        if trashActions != nil {
            performTrash(.deletePermanently, target: target)
            return
        }
        guard let serverID = target.serverID else { return }
        viewer.remove(target, operation: {
            guard await vm?.delete(serverID) == true else { return false }
            if viewer.isCurrent(target) { deleteFeedback += 1 }
            return true
        }) { isPresented in
            onAssetRemoved?(target.asset.id)
            if isPresented {
                loadCurrentMetadata()
                if viewer.isEmpty { dismiss() }
            }
        }
    }

    private func performTrash(_ mutation: TrashViewerActions.Mutation, target: AssetViewerState.Target) {
        guard visibilityPolicy.allows(id: target.asset.id) else { return }
        trashActionError = nil
        trashActions?.perform(mutation, target: target, in: viewer, onError: {
            trashActionError = ErrorEvent($0)
        }) { isPresented in
            onAssetRemoved?(target.asset.id)
            guard isPresented else { return }
            if mutation == .deletePermanently { deleteFeedback += 1 }
            loadCurrentMetadata()
            if viewer.isEmpty { dismiss() }
        }
    }

    /// Mode "card": foto normal (tidak zoom) dengan toolbar tampil — foto
    /// mengecil di tengah dengan sudut membulat.
    /// Layout dasar foto = mode card. Panel info TIDAK lagi mematikan mode ini;
    /// perpindahan ke full width diurus lewat interpolasi `expandProgress`
    /// supaya tidak ada lompatan saat panel mulai ditarik.
    private var cardLayout: Bool {
        showToolbar && !isZoomed
    }

    private func shareFile() {
        guard !isSharePresented else { return }
        let target = currentTarget
        let accountGeneration = LocalSnapshot.generation
        let requestContext = session.snapshot
        viewer.prepare(target, kind: .share,
            operation: {
                vm?.actionError = nil
                let url = await fileURL(for: target)
                if url == nil, viewer.isCurrent(target), accountGeneration == LocalSnapshot.generation,
                   session.snapshot == requestContext,
                   !Task.isCancelled, serverAssetID(for: target.asset) == target.serverID,
                   visibilityPolicy.allows(id: target.asset.id), vm?.actionError == nil {
                    vm?.actionError = ErrorEvent(String(localized: "Failed to prepare share"))
                }
                return url
            },
            discard: { TemporaryMediaStore.remove($0) }) { file in
                guard accountGeneration == LocalSnapshot.generation, session.snapshot == requestContext,
                      serverAssetID(for: target.asset) == target.serverID,
                      visibilityPolicy.allows(id: target.asset.id) else {
                    TemporaryMediaStore.remove(file)
                    return
                }
                cleanupSharedFile()
                downloadedFileURL = file
                sharedAssetIDs = [target.asset.id]
                sharedSourceIDs = [target.serverID ?? target.asset.id]
                sharedRequestContext = requestContext
                isSharePresented = true
            }
    }

    private var currentServerAssetID: String? {
        serverAssetID(for: currentAsset)
    }

    private func serverAssetID(for asset: AssetLite) -> String? {
        AssetServerIdentity.resolve(asset)
    }

    // A backup mapping identifies the original, not whether device and server edits match.
    private func fileURL(for target: AssetViewerState.Target) async -> URL? {
        let accountGeneration = LocalSnapshot.generation
        guard viewer.isCurrent(target), !Task.isCancelled,
              visibilityPolicy.allows(id: target.asset.id) else { return nil }
        if target.serverID == nil, target.asset.isOnDevice {
            let localID = LocalPhotoLibrary.isLocal(target.asset.id)
                ? LocalPhotoLibrary.localIdentifier(from: target.asset.id)
                : SwiftDataManager.shared.localIdentifier(forServerAsset: target.asset.id)
            if let localID {
                do {
                    guard let file = try await MediaEditingPipeline.shared.exportDeviceFile(
                        for: LocalPhotoLibrary.assetID(for: localID), session: session) else { return nil }
                    guard viewer.isCurrent(target), accountGeneration == LocalSnapshot.generation,
                          visibilityPolicy.allows(id: target.asset.id), serverAssetID(for: target.asset) == nil,
                          !Task.isCancelled else { TemporaryMediaStore.remove(file.url); return nil }
                    return file.url
                } catch {
                    if viewer.isCurrent(target), accountGeneration == LocalSnapshot.generation, !Task.isCancelled {
                        vm?.actionError = ErrorEvent(error.localizedDescription)
                    }
                    return nil
                }
            }
        }
        guard viewer.isCurrent(target), accountGeneration == LocalSnapshot.generation,
              visibilityPolicy.allows(id: target.asset.id),
              !Task.isCancelled, let serverID = target.serverID,
              serverAssetID(for: target.asset) == serverID,
              visibilityPolicy.allows(id: serverID), let vm else { return nil }
        let filename = target.detail?.originalFileName ?? serverID
        guard let file = await vm.downloadCurrentFile(serverID, filename: filename) else { return nil }
        guard viewer.isCurrent(target), accountGeneration == LocalSnapshot.generation,
              serverAssetID(for: target.asset) == serverID,
              visibilityPolicy.allows(id: target.asset.id), visibilityPolicy.allows(id: serverID),
              !Task.isCancelled else {
            TemporaryMediaStore.remove(file)
            return nil
        }
        return file
    }

    private func slideshowFile(for asset: AssetLite) async -> URL? {
        let generation = LocalSnapshot.generation
        let context = session.snapshot
        let serverID = serverAssetID(for: asset)
        guard visibilityPolicy.allows(id: asset.id) else { return nil }
        let file: URL?
        if let serverID {
            file = await vm?.downloadCurrentFile(serverID, filename: serverID)
        } else {
            file = try? await MediaEditingPipeline.shared.exportDeviceFile(for: asset.id, session: session)?.url
        }
        guard let file else { return nil }
        guard !Task.isCancelled, generation == LocalSnapshot.generation, session.snapshot == context,
              serverAssetID(for: asset) == serverID, visibilityPolicy.allows(id: asset.id) else {
            TemporaryMediaStore.remove(file)
            return nil
        }
        return file
    }

    private func createSharedLink(for serverID: String) {
        let target = currentTarget
        guard target.serverID == serverID, visibilityPolicy.allows(id: target.asset.id) else { return }
        let repo = SharedLinkRepository(api: APIClient(session: session))
        let baseURL = session.baseURL
        viewer.prepare(target, kind: .sharedLink, operation: {
            do {
                let link = try await repo.create(assetIds: [serverID])
                guard visibilityPolicy.allows(id: target.asset.id) else { return nil }
                guard let url = link.publicURL(base: baseURL) else { throw APIError.invalidURL }
                return url
            } catch {
                if viewer.isCurrent(target) { vm?.actionError = ErrorEvent(error.localizedDescription) }
                return nil
            }
        }) { url in sharedLink = SharedLinkPresentation(url: url) }
    }

    private func uploadLocalAsset() {
        let target = currentTarget
        guard target.asset.needsUpload, viewer.beginUpload(target.asset.id) else { return }
        Task {
            defer { viewer.finishUpload(target.asset.id) }
            await BackupService.shared.uploadNow([target.asset.id])
            refreshUploadedCopies()
        }
    }

    private func downloadToDevice() {
        let target = currentTarget
        guard target.asset.origin == .server, let serverID = target.serverID, let vm else { return }
        let filename = target.detail?.originalFileName ?? serverID
        let accountGeneration = LocalSnapshot.generation
        viewer.download(target, operation: {
            guard let file = await vm.downloadCurrentFile(serverID, filename: filename) else { return false }
            defer { TemporaryMediaStore.remove(file) }
            guard accountGeneration == LocalSnapshot.generation, !Task.isCancelled else { return false }
            guard let localID = await LocalPhotoLibrary.shared.saveDownloadedFile(file, isVideo: PhotoExportService.contentType(of: file).conforms(to: .movie)) else {
                if viewer.isCurrent(target), accountGeneration == LocalSnapshot.generation,
                   !Task.isCancelled { vm.actionError = ErrorEvent(String(localized: "Could not save to Photos.")) }
                return false
            }
            guard accountGeneration == LocalSnapshot.generation, !Task.isCancelled else { return false }
            do {
                try SwiftDataManager.shared.linkDeviceAsset(localIdentifier: localID, to: serverID)
                return true
            } catch {
                if viewer.isCurrent(target), accountGeneration == LocalSnapshot.generation,
                   !Task.isCancelled { vm.actionError = ErrorEvent(error.localizedDescription) }
                return false
            }
        })
    }

    private func setAsProfilePhoto() {
        let target = currentTarget
        guard !target.asset.isVideo, !isSettingProfilePhoto, let vm else { return }
        let accountGeneration = LocalSnapshot.generation
        isSettingProfilePhoto = true
        Task {
            defer { isSettingProfilePhoto = false }
            guard let file = await fileURL(for: target) else {
                if viewer.isCurrent(target), accountGeneration == LocalSnapshot.generation,
                   !Task.isCancelled { vm.actionError = ErrorEvent(String(localized: "Could not prepare the profile photo.")) }
                return
            }
            defer { TemporaryMediaStore.remove(file) }
            guard viewer.isCurrent(target), accountGeneration == LocalSnapshot.generation else { return }
            guard let jpeg = await Self.profileJPEG(from: file) else {
                if viewer.isCurrent(target), accountGeneration == LocalSnapshot.generation,
                   !Task.isCancelled { vm.actionError = ErrorEvent(String(localized: "Could not prepare the profile photo.")) }
                return
            }
            guard viewer.isCurrent(target), accountGeneration == LocalSnapshot.generation else { return }
            guard await vm.setProfileImage(jpeg, filename: "profile.jpg") else { return }
            guard accountGeneration == LocalSnapshot.generation else { return }
            await session.refreshUser()
        }
    }

    private nonisolated static func profileJPEG(from fileURL: URL) async -> Data? {
        await Task.detached(priority: .userInitiated) {
            guard let image = UIImage(contentsOfFile: fileURL.path),
                  image.size.width > 0, image.size.height > 0 else { return nil }
            let side = min(image.size.width, image.size.height)
            let source = CGRect(
                x: (image.size.width - side) / 2,
                y: (image.size.height - side) / 2,
                width: side,
                height: side)
            let outputSide = min(1024, side)
            let renderer = UIGraphicsImageRenderer(
                size: CGSize(width: outputSide, height: outputSide))
            let result = renderer.image { _ in
                image.draw(
                    in: CGRect(
                        x: -source.minX * outputSide / side,
                        y: -source.minY * outputSide / side,
                        width: image.size.width * outputSide / side,
                        height: image.size.height * outputSide / side))
            }
            return result.jpegData(compressionQuality: 0.9)
        }.value
    }

    private func removeFromDevice(_ target: AssetViewerState.Target) {
        guard deviceRemoval == nil else { return }
        let service = FreeUpSpaceService(session: session)
        let accountGeneration = LocalSnapshot.generation
        if target.asset.origin == .both, !LocalPhotoLibrary.isLocal(target.asset.id) {
            deviceRemoval = Task {
                defer { deviceRemoval = nil }
                do {
                    guard try await DeviceCopyDeletion.perform(target.asset.id, using: service),
                          !Task.isCancelled, accountGeneration == LocalSnapshot.generation else { return }
                    viewer.setOrigin(.server, for: target.asset.id)
                } catch is CancellationError {
                    return
                } catch {
                    if accountGeneration == LocalSnapshot.generation, viewer.isCurrent(target) {
                        vm?.actionError = ErrorEvent(error.localizedDescription)
                    }
                }
            }
        } else {
            deviceRemoval = viewer.remove(target, operation: {
                defer { deviceRemoval = nil }
                do {
                    try Task.checkCancellation()
                    let removed: Bool
                    if target.asset.origin == .both {
                        removed = try await DeviceCopyDeletion.perform(target.asset.id, using: service)
                    } else {
                        removed = await LocalPhotoLibrary.shared.delete([target.asset.id])
                    }
                    return removed && !Task.isCancelled && accountGeneration == LocalSnapshot.generation
                } catch is CancellationError {
                    return false
                } catch {
                    if accountGeneration == LocalSnapshot.generation, viewer.isCurrent(target) {
                        vm?.actionError = ErrorEvent(error.localizedDescription)
                    }
                    return false
                }
            }) { isPresented in
                onAssetRemoved?(target.asset.id)
                if isPresented {
                    loadCurrentMetadata()
                    if viewer.isEmpty { dismiss() }
                }
            }
        }
    }

    private func cleanupSharedFile() {
        if let downloadedFileURL { TemporaryMediaStore.remove(downloadedFileURL) }
        downloadedFileURL = nil
        sharedAssetIDs.removeAll()
        sharedSourceIDs.removeAll()
        sharedRequestContext = nil
    }
}

private struct PhotoEditorTarget: Identifiable {
    let target: AssetViewerState.Target
    let sourceID: String
    let requestContext: SessionRequestContext
    let originalURL: URL
    let motionURL: URL?
    let document: MediaEditDocument
    let token: MediaEditStore.Token
    let ownedFiles: [URL]
    let sourceChanged: Bool
    var id: UUID { target.id }
}

private struct MetadataKey: Equatable {
    let visit: UUID
    let assetID: String
}

private struct FavoriteDisplay: Equatable {
    let visit: UUID
    let value: Bool
}

private struct DetailDisplay: Equatable {
    let visit: UUID
    let assetID: String?
}

private struct CaptureDateDisplay: Equatable {
    let visit: UUID
    let assetID: String
    let date: Date?
}

private struct LivePhotoDisplay: Equatable {
    let visit: UUID
    let assetID: String
    let videoID: String?
    let hint: LocalLivePhotoMatchHint?
}

private struct AssetCardViewport: Equatable {
    let height: CGFloat
    let centerY: CGFloat
}

/// Empat modifier visibilitas/latar toolbar dibungkus jadi satu, supaya tidak
/// ikut memperpanjang rantai modifier di `body`.
private struct ToolbarChrome: ViewModifier {
    let showToolbar: Bool
    /// Saat panel info terbuka, hanya bottom bar yang tersisa — navigation bar
    /// ikut disembunyikan supaya foto punya ruang naik.
    let showInfo: Bool
    /// Mode edit deskripsi membalik keadaan itu: navigation bar wajib tampil
    /// (di situ tombol batal & simpan), bottom bar justru disembunyikan.
    let isEditing: Bool
    /// Regular-width iPad tidak punya bottom action bar; seluruh aksi berada di
    /// atas, sehingga navigation bar harus tetap tampil saat panel info terbuka.
    let usesTopToolbarOnly: Bool

    private var topVisibility: Visibility {
        if isEditing { return .visible }
        if usesTopToolbarOnly { return showToolbar ? .visible : .hidden }
        return showToolbar && !showInfo ? .visible : .hidden
    }

    private var bottomVisibility: Visibility {
        if usesTopToolbarOnly { return .hidden }
        if isEditing { return .hidden }
        return showToolbar ? .visible : .hidden
    }

    func body(content: Content) -> some View {
        content
            .toolbar(topVisibility, for: .navigationBar)
            .toolbar(bottomVisibility, for: .bottomBar)
        // TANPA `toolbarBackground(.visible, …)`.
        //
        // Memaksa latar bar jadi "visible" menuntut SwiftUI menyediakan bar
        // dengan latar yang digambar sendiri, dan di iOS 26 itu melawan kaca
        // bawaannya — persis alasan yang sama kenapa latar toolbar di Timeline
        // dilepas. Diserahkan ke sistem, bar-nya jadi kaca yang memburamkan foto
        // di belakangnya, dan tidak ada bar berlatar sendiri yang perlu
        // ditempelkan ke hierarki view.
    }
}

struct ShareSheet: UIViewControllerRepresentable {
    let url: URL
    /// Gambar untuk header share sheet. Tanpa ini iOS hanya menampilkan ikon
    /// tipe file generik (mis. "JPG"), bukan isi fotonya.
    var previewImage: UIImage? = nil

    func makeCoordinator() -> CleanupCoordinator {
        CleanupCoordinator(urls: [url])
    }

    func makeUIViewController(context: Context) -> UIActivityViewController {
        let item = ShareItemSource(url: url, previewImage: previewImage)
        let controller = UIActivityViewController(
            activityItems: [item], applicationActivities: nil)
        controller.completionWithItemsHandler = { [weak coordinator = context.coordinator]
            _, _, _, _ in
            coordinator?.cleanup()
        }
        return controller
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}

    static func dismantleUIViewController(
        _ uiViewController: UIActivityViewController,
        coordinator: CleanupCoordinator
    ) {
        coordinator.cleanup()
    }
}

/// Share sheet untuk banyak file sekaligus.
///
/// Tidak memakai `ShareItemSource`: metadata pratinjau hanya masuk akal untuk
/// satu item, dan iOS sendiri menampilkan ringkasan "N Items" untuk kumpulan.
struct MultiShareSheet: UIViewControllerRepresentable {
    let urls: [URL]
    var onFinish: (() -> Void)? = nil

    func makeCoordinator() -> CleanupCoordinator {
        CleanupCoordinator(urls: urls, onFinish: onFinish)
    }

    func makeUIViewController(context: Context) -> UIActivityViewController {
        activityController(using: context.coordinator)
    }

    func activityController(using coordinator: CleanupCoordinator) -> UIActivityViewController {
        let controller = UIActivityViewController(activityItems: urls, applicationActivities: nil)
        controller.completionWithItemsHandler = { [weak coordinator]
            _, _, _, _ in
            coordinator?.cleanup()
        }
        return controller
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}

    static func dismantleUIViewController(
        _ uiViewController: UIActivityViewController,
        coordinator: CleanupCoordinator
    ) {
        coordinator.cleanup()
    }
}

/// `dismantleUIViewController` menjadi pengaman bila sheet ditutup oleh SwiftUI
/// tanpa memanggil completion handler (mis. view induk ikut hilang).
final class CleanupCoordinator {
    private var urls: [URL]
    private var onFinish: (() -> Void)?

    init(urls: [URL], onFinish: (() -> Void)? = nil) {
        self.urls = urls
        self.onFinish = onFinish
    }

    func cleanup() {
        guard !urls.isEmpty else { return }
        TemporaryMediaStore.remove(urls)
        urls.removeAll()
        let finished = onFinish
        onFinish = nil
        finished?()
    }
}

/// Membungkus URL file supaya share sheet punya metadata pratinjau.
///
/// `UIActivityViewController` hanya menampilkan thumbnail asli kalau item-nya
/// menyediakan `LPLinkMetadata`; kalau cuma diberi `URL` mentah, header-nya
/// jatuh ke ikon ekstensi file.
private final class ShareItemSource: NSObject, UIActivityItemSource {
    private let url: URL
    private let previewImage: UIImage?

    init(url: URL, previewImage: UIImage?) {
        self.url = url
        self.previewImage = previewImage
    }

    // Placeholder harus bertipe sama dengan item aslinya (URL), bukan gambar —
    // kalau beda, sebagian extension salah menebak tipe kontennya.
    func activityViewControllerPlaceholderItem(_ controller: UIActivityViewController) -> Any {
        url
    }

    func activityViewController(
        _ controller: UIActivityViewController,
        itemForActivityType activityType: UIActivity.ActivityType?
    ) -> Any? {
        url
    }

    func activityViewController(
        _ controller: UIActivityViewController,
        subjectForActivityType activityType: UIActivity.ActivityType?
    ) -> String {
        url.lastPathComponent
    }

    func activityViewControllerLinkMetadata(
        _ controller: UIActivityViewController
    ) -> LPLinkMetadata? {
        let metadata = LPLinkMetadata()
        metadata.title = url.lastPathComponent
        metadata.originalURL = url
        if let previewImage {
            metadata.imageProvider = NSItemProvider(object: previewImage)
            metadata.iconProvider = NSItemProvider(object: previewImage)
        }
        return metadata
    }
}

#Preview {
    let asset = AssetLite(id: "test-123", isVideo: false, ratio: 1.0, thumbhash: nil, createdAt: Date())
    AssetDetailView(currentAsset: asset, assets: [asset])
        .environment(SessionManager())
}
