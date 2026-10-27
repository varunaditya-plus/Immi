import CoreLocation
import LinkPresentation
import SwiftUI

struct AssetDetailView: View {
    @State var currentAsset: AssetLite
    let assets: [AssetLite]
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
    /// true selama file asli masih diunduh, sebelum share sheet dibuka.
    @State private var isPreparingShare = false
    @State private var isDownloadingToDevice = false
    @State private var isUploadingLocalAsset = false
    @State private var isSettingProfilePhoto = false
    @State private var downloadedFileURL: URL?
    /// Pratinjau untuk header share sheet, diambil dari cache preview.
    @State private var sharePreviewImage: UIImage?
    @State private var showToolbar = true
    @State private var isZoomed = false
    @State private var showDeleteConfirm = false
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
    /// Kotak card terakhir saat chrome masih utuh. Navigation bar menghilang
    /// ketika panel dibuka; memakai GeometryReader live pada saat itu mengubah
    /// titik awal interpolasi di tengah gesture dan membuat foto tersentak.
    @State private var cardViewport: AssetCardViewport?

    @State private var descriptionDraft = ""
    @FocusState private var descriptionFocused: Bool
    /// Cermin dari `descriptionFocused`. Toolbar builder tidak andal membaca
    /// @FocusState langsung, jadi disalin seperti status toolbar lainnya.
    @State private var isEditingDescription = false
    @State private var isEditingDate = false
    @State private var isEditingLocation = false
    @State private var isPickingAlbum = false
    @State private var isEditingPhoto = false
    @State private var isPreparingEditor = false
    @State private var existingPhotoEdits: [AssetEditRecord] = []
    @State private var showRemoveDeviceConfirm = false
    @State private var deviceRemoval: Task<Void, Never>?
    /// Salinan kerja dari `assets`, milik layar ini.
    ///
    /// `assets` dimiliki pemanggil dan tidak bisa diubah dari sini. Dulu
    /// penghapusan disimpan sebagai kumpulan id lalu disaring ulang setiap kali
    /// dibaca — pada puluhan ribu foto itu penyalinan array penuh, berkali-kali
    /// per frame. Sekarang daftarnya diubah langsung.
    @State private var pages: [AssetLite] = []
    /// Posisi `currentAsset` di `pages`, dipelihara alih-alih dicari ulang.
    @State private var currentIndex = 0
    /// Panel tetap terpasang sampai animasi menutup benar-benar selesai.
    ///
    /// Tanpa ini, `panelHeight` menyentuh 0 di awal `withAnimation` sehingga
    /// view-nya langsung dilepas dan animasi mengecilnya tidak pernah terlihat
    /// — yang tampak hanya kedipan.
    @State private var isPanelMounted = false
    /// Pegangan ke strip, supaya pager bisa menggesernya langsung tiap frame.
    @State private var filmstripController: PhotoFilmstripController?
    /// Pegangan ke pager, supaya bar kontrol video bisa menyambung langsung.
    @State private var pagerController: PhotoPagerController?
    /// Salinan eksplisit metadata Live Photo. Membacanya langsung dari objek
    /// observable di dalam representable dapat melewatkan update ketika detail
    /// cache dan detail jaringan mempunyai ID aset yang sama.
    @State private var currentLivePhotoVideoID: String? = nil
    @State private var currentLivePhotoHint: LocalLivePhotoMatchHint? = nil
    /// Menjaga metadata async tidak pernah dipasang ke halaman yang berbeda
    /// selama satu frame transisi pager.
    @State private var currentLivePhotoContextAssetID: String? = nil

    /// Daftar yang benar-benar dipakai untuk menggambar.
    ///
    /// `pages` baru terisi di `start()`, yang berjalan SETELAH body pertama.
    /// Membiarkan strip menunggu sampai saat itu membuatnya muncul terlambat —
    /// dan karena strip mengubah safe area, fotonya sempat tergambar lebih tinggi
    /// lalu tersentak naik begitu strip datang.
    private var visibleAssets: [AssetLite] { pages.isEmpty ? assets : pages }

    private var isPanelDragging: Bool { panelDragStart != nil }
    private var isPanelAtMax: Bool { panelHeight >= panelMaxHeight - 1 }

    /// Chrome mengikuti umur panel, bukan nilai target animasinya.
    ///
    /// Saat `panelHeight` dianimasikan ke 0, SwiftUI langsung menyimpan nilai
    /// target 0 walaupun panel masih tampak bergerak selama beberapa frame.
    /// Kalau chrome membaca `panelHeight > 0`, navigation bar dan filmstrip
    /// muncul di frame pertama penutupan lalu bertabrakan dengan panel yang
    /// belum selesai turun. `isPanelMounted` baru false di completion, sehingga
    /// seluruh chrome berpindah tepat setelah transisi selesai.
    private var showInfo: Bool { isPanelMounted }

    // Body sengaja dipecah berlapis. Sebagai satu rantai modifier utuh,
    // ekspresinya terlalu besar untuk type-checker Swift ("unable to
    // type-check this expression in reasonable time"). Tiap lapis punya
    // anotasi `some View` eksplisit, jadi type-checking-nya selesai per bagian.
    var body: some View {
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
            .onAppear { OfflineBannerSuppression.shared.begin() }
            .onDisappear {
                OfflineBannerSuppression.shared.end()
            }
            .cancelDeviceCopyRemoval { deviceRemoval?.cancel() }
            .task { await start() }
            // Memaksa toolbar mengevaluasi ulang keberadaan salinan lokal saat
            // PhotoKit berubah. Sekaligus tutup dialog yang keburu terbuka bila
            // asetnya dihapus dari tempat lain.
            .onChange(of: LocalPhotoLibrary.shared.revision) { _, _ in
                if !DeviceCopyDeletion.hasDeviceCopy(for: currentAsset) {
                    showRemoveDeviceConfirm = false
                }
            }
            // Untuk pemanggil yang mendorong lewat navigationDestination
            // (People, Album) — jalur fullScreenCover menolaknya di akar scene
            // yang dipresentasikan, lihat TimelineView dan SearchResultsGrid.
            .ignoresSafeArea(.keyboard, edges: .bottom)
            .onChange(of: currentAsset) { oldAsset, newAsset in
                deviceRemoval?.cancel()
                onAssetChange?(newAsset)
                currentLivePhotoContextAssetID = newAsset.id
                currentLivePhotoVideoID = newAsset.livePhotoVideoID
                currentLivePhotoHint = nil
                // Foto lain = metadata lain = tinggi isi lain. Nilai maksimum
                // yang tersimpan harus dilupakan, bukan dibawa-bawa.
                panelContentHeight = 0
                // Deskripsi milik foto sebelumnya: simpan dulu, lalu lepas
                // fokusnya. Tanpa ini keyboard dan toolbar mode edit bertahan
                // di foto baru sambil menyunting teks milik foto lama.
                if isEditingDescription {
                    saveDescriptionEdit(for: serverAssetID(for: oldAsset))
                }
                Task {
                    let detailAssetID = serverAssetID(for: newAsset) ?? newAsset.id
                    await vm?.load(detailAssetID)
                    syncLivePhotoContextFromDetail()
                    if let serverID = serverAssetID(for: newAsset) {
                        await vm?.loadContainingAlbums(serverID)
                    }
                }
            }
    }

    private var navigationTitleText: String {
        currentAsset.createdAt.formatted(date: .abbreviated, time: .omitted)
    }

    private var isStatusBarHidden: Bool {
        (!showToolbar || showInfo) && !isEditingDescription
    }

    private var toolbarChrome: ToolbarChrome {
        ToolbarChrome(
            showToolbar: showToolbar,
            showInfo: showInfo,
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
            .sheet(item: $sharedLink) { ShareSheet(url: $0.url) }
            .sheet(isPresented: $isEditingDate) { dateEditor }
            .sheet(isPresented: $isEditingLocation) { locationEditor }
            .sheet(isPresented: $isPickingAlbum) { albumPicker }
            .fullScreenCover(isPresented: $isEditingPhoto) { photoEditor }
            .confirmationDialog(
                currentAsset.needsUpload ? "Remove This Photo?" : "Remove from Device",
                isPresented: $showRemoveDeviceConfirm,
                titleVisibility: .visible
            ) {
                Button("Remove from Device", role: .destructive) {
                    removeFromDevice()
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                if currentAsset.needsUpload {
                    Text("This is the only copy and it has not been uploaded yet.")
                } else {
                    Text("The local copy will be removed. The photo stays on your server.")
                }
            }
    }

    @ViewBuilder
    private var photoEditor: some View {
        if let serverID = currentServerAssetID,
           let pixelSize = editablePixelSize {
            PhotoCropEditor(
                assetID: serverID,
                originalPixelSize: pixelSize,
                existingEdits: existingPhotoEdits,
                onSave: { edits in
                    guard await vm?.applyEdits(edits, to: serverID) == true else { return false }
                    await pagerController?.reloadCurrentImage()
                    onAssetUpdated?(serverID)
                    return true
                })
        }
    }

    private var albumPicker: some View {
        AlbumPickerSheet(albums: albums) { album in
            guard let serverID = currentServerAssetID else { return }
            Task { await vm?.addToAlbum(serverID, album: album) }
        }
    }

    @ViewBuilder
    private var dateEditor: some View {
        if let detail = vm?.detail {
            AssetDateEditor(initialDate: detail.fileCreatedAt) { newDate in
                guard let id = currentServerAssetID else { return }
                Task {
                    await vm?.updateDate(id, to: newDate)
                    onAssetUpdated?(id)
                }
            }
        }
    }

    @ViewBuilder
    private var locationEditor: some View {
        AssetLocationEditor(initialCoordinate: currentCoordinate) { coordinate in
            guard let id = currentServerAssetID else { return }
            Task {
                await vm?.updateLocation(
                    id,
                    latitude: coordinate.latitude,
                    longitude: coordinate.longitude)
                onAssetUpdated?(id)
            }
        }
    }

    private var currentCoordinate: CLLocationCoordinate2D? {
        guard let exif = vm?.detail?.exifInfo,
              let lat = exif.latitude,
              let lon = exif.longitude,
              lat != 0 || lon != 0 else { return nil }
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
            .onChange(of: favoriteValue) { _, newValue in
                isFavorite = newValue == true
            }
            .onChange(of: detailID, initial: true) { _, newValue in
                hasDetail = newValue != nil
            }
    }

    private var favoriteValue: Bool? { vm?.detail?.isFavorite }
    private var detailID: String? { vm?.detail?.id }

    private var favoriteHaptic: SensoryFeedback {
        isFavorite ? .success : .impact(flexibility: .soft)
    }

    @ViewBuilder
    private var shareSheet: some View {
        if let url = downloadedFileURL {
            ShareSheet(url: url, previewImage: sharePreviewImage)
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
                        .frame(height: 46)
                        .padding(.horizontal, 12)
                }

                PhotoFilmstripView(
                    assets: visibleAssets,
                    currentAssetID: currentAsset.id,
                    onSelect: { asset in currentAsset = asset },
                    onControllerReady: { filmstripController = $0 },
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
        if isPanelMounted, let detail = vm?.detail {
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
        AssetInfoPanel(
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
                panelContentHeight = max(panelContentHeight, newHeight)
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
            onAdjustDate: { isEditingDate = true },
            onAdjustLocation: { isEditingLocation = true },
            containingAlbums: vm?.containingAlbums ?? [])
    }

    // MARK: - Detent panel

    /// Dihitung sekali, bukan setiap kali dibaca.
    ///
    /// Nilainya mengalir ke `expandProgress`, yang dibaca oleh SETIAP halaman
    /// pager pada setiap evaluasi body. Menelusuri daftar scene sebanyak itu —
    /// hanya untuk tinggi layar yang tidak berubah — biaya yang tidak perlu ada.
    private var screenHeight: CGFloat { Self.screenHeightValue }

    private static let screenHeightValue: CGFloat = {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first?
            .screen.bounds.height ?? 800
    }()

    /// Tinggi standar saat panel dibuka — SELALU proporsi layar, tidak pernah
    /// bergantung pada tinggi isi.
    ///
    /// Dulu nilai ini ikut di-clamp oleh `panelContentHeight`, sehingga bukaan
    /// pertama (saat isi belum terukur) berbeda dari bukaan berikutnya.
    private var panelMediumHeight: CGFloat {
        screenHeight * 0.55
    }

    /// Batas atas tarikan: menyisakan seperempat layar teratas untuk foto, dan
    /// tidak melebihi tinggi alami isi panel — konten yang sedikit tidak boleh
    /// ditarik lebih tinggi dari isinya. Tidak pernah lebih pendek dari tinggi
    /// standar, supaya bukaan normal selalu bisa dicapai.
    private var panelMaxHeight: CGFloat {
        let ceiling = screenHeight * 0.75
        guard panelContentHeight > 0 else { return ceiling }
        return min(ceiling, max(panelMediumHeight, panelContentHeight))
    }

    /// Tertutup, standar, dan penuh — panel di-snap ke salah satunya saat jari
    /// dilepas. Detent penuh dilewati kalau isinya memang tidak setinggi itu.
    private var panelDetents: [CGFloat] {
        var detents: [CGFloat] = [0, panelMediumHeight]
        if panelMaxHeight > panelMediumHeight + 24 {
            detents.append(panelMaxHeight)
        }
        return detents
    }

    /// Satu-satunya gesture untuk panel — berlaku di area foto maupun di badan
    /// panel. Aturan arah dan siapa yang mengalah diputuskan di dalam
    /// recognizer-nya, bukan di sini.
    private var infoDragGesture: PanelPanGesture {
        PanelPanGesture(
            panelHeight: panelHeight,
            panelScrollEnabled: isPanelAtMax,
            panelScrollAtTop: panelScrollOffset <= 0.5,
            onChanged: { translationY in
                guard !isZoomed else { return }
                // Menarik ke atas dari layar detail yang belum punya info hanya
                // menyeret panel kosong; gerakannya dibiarkan lewat kalau
                // panelnya memang sudah terbuka, supaya tetap bisa ditutup.
                guard hasDetail || panelHeight > 0 else { return }
                dragChanged(translationY)
            },
            onEnded: { translationY, velocityY in
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
        vm?.detail?.exifInfo?.description ?? ""
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
        guard trimmed != savedDescription else { return }
        guard let id = assetID ?? currentServerAssetID else { return }
        Task { await vm?.updateDescription(id, to: trimmed) }
    }

    private func setInfo(_ open: Bool) {
        animatePanel(to: open ? panelDetents[1] : 0)
    }

    /// Pesannya sendiri yang dijadikan binding, bukan bool + teks terpisah.
    /// Toast-nya mengosongkannya sendiri setelah beberapa detik.
    private var actionErrorBinding: Binding<ErrorEvent?> {
        Binding(
            get: { vm?.actionError },
            set: { vm?.actionError = $0 }
        )
    }

    // MARK: - Jendela halaman

    private func start() async {
        if pages.isEmpty {
            pages = assets
            currentIndex = assets.firstIndex(of: currentAsset) ?? 0
        }
        if vm == nil {
            let api = APIClient(session: session)
            let repo = AssetDetailRepository(api: api)
            vm = AssetDetailViewModel(repo: repo, albumRepo: AlbumRepository(api: api))
        }
        let detailAssetID = currentServerAssetID ?? currentAsset.id
        await vm?.load(detailAssetID)
        syncLivePhotoContextFromDetail()
        if let serverID = currentServerAssetID {
            await vm?.loadContainingAlbums(serverID)
        }
        await vm?.loadAlbumsIfNeeded()
    }

    /// Menyalin metadata hasil fetch ke state view dan menyiapkan fallback
    /// PhotoKit. Nama file + waktu + dimensi dipakai bersama supaya pencocokan
    /// tidak salah memilih Live Photo lain yang kebetulan berdekatan waktunya.
    private func syncLivePhotoContextFromDetail() {
        guard let detail = vm?.detail,
              detail.id == currentServerAssetID
        else { return }

        currentLivePhotoVideoID = detail.livePhotoVideoId
            ?? currentAsset.livePhotoVideoID
        currentLivePhotoHint = LocalLivePhotoMatchHint(
            createdAt: detail.fileCreatedAt,
            pixelWidth: detail.exifInfo?.exifImageWidth,
            pixelHeight: detail.exifInfo?.exifImageHeight,
            originalFileName: detail.originalFileName)
        currentLivePhotoContextAssetID = currentAsset.id
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
                // `assets` dipakai sampai salinan kerjanya terisi.
                //
                // `pages` baru diisi di `start()`, yang berjalan SETELAH body
                // pertama. Artinya pada evaluasi pertama pagernya kosong — dan
                // animator transisi membaca kotak foto tujuan tepat di saat itu,
                // lalu menemukan tidak ada apa-apa. Itulah kenapa membukanya tidak
                // berangkat dari sel yang ditekan.
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
                    currentIndex = pages.firstIndex(of: asset) ?? currentIndex
                },
                onZoomChanged: { handleZoomChange($0) },
                onTap: { toggleToolbar() },
                // Strip digeser LANGSUNG dari pager, tanpa melewati `@State`.
                //
                // Nilainya berubah tiap frame selama usapan; menyalurkannya lewat
                // SwiftUI berarti membangun ulang body sebanyak itu juga.
                onScrollProgress: { filmstripController?.track(page: $0) },
                onControllerReady: { pagerController = $0 },
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
        if isEditingDescription {
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
                } else {
                    // Urutannya mengikuti Photos iPad: edit, info, hapus,
                    // kemudian menu tindakan tambahan.
                    if !currentAsset.isVideo { editPhotoButton }
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
            if let serverID = currentServerAssetID {
                Button {
                    createSharedLink(for: serverID)
                } label: {
                    Label("Share Link", systemImage: "link")
                }
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

            if currentServerAssetID != nil {
                Section("Move to") {
                    Button {
                        moveAsset(to: .locked)
                    } label: {
                        Label("Locked Folder", systemImage: "lock")
                    }

                    Button {
                        moveAsset(to: .archive)
                    } label: {
                        Label("Archive", systemImage: "archivebox")
                    }
                }

                Section("Add to") {
                    Button {
                        isPickingAlbum = true
                    } label: {
                        Label("Album", systemImage: "rectangle.stack.badge.plus")
                    }
                }
            }

            // Jangan percaya `origin` saja. Foto bisa sudah dihapus lewat
            // Photos/aplikasi lain sementara halaman detail masih memegang
            // snapshot `.both` yang lama.
            if DeviceCopyDeletion.hasDeviceCopy(for: currentAsset) {
                Divider()
                Button(role: .destructive) {
                    showRemoveDeviceConfirm = true
                } label: {
                    Label("Remove from Device", systemImage: "iphone.slash")
                }
                .disabled(deviceRemoval != nil)
            }
        } label: {
            if isDownloadingToDevice || isSettingProfilePhoto {
                ProgressView()
            } else {
                Image(systemName: "ellipsis")
            }
        }
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
        if currentAsset.needsUpload {
            // Aset yang hanya ada di perangkat belum punya aksi server. Toolbar
            // sengaja hanya menawarkan dua hal yang benar-benar bisa dilakukan.
            ToolbarItem(placement: .bottomBar) { shareButton }
            ToolbarSpacer(.flexible, placement: .bottomBar)
            ToolbarItem(placement: .bottomBar) { uploadButton }
        } else {
            ToolbarItem(placement: .bottomBar) { shareButton }
            ToolbarSpacer(.flexible, placement: .bottomBar)

            ToolbarItemGroup(placement: .bottomBar) {
                favoriteButton
                infoButton
                // Editor hanya untuk image; video tidak menyisakan placeholder.
                if !currentAsset.isVideo { editPhotoButton }
            }

            ToolbarSpacer(.flexible, placement: .bottomBar)
            ToolbarItem(placement: .bottomBar) { deleteButton }
        }
    }

    private var shareButton: some View {
        Button {
            Task { await shareFile() }
        } label: {
            shareIcon
        }
        .disabled(isPreparingShare)
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
            guard let id = currentServerAssetID else { return }
            Task {
                if await vm?.toggleFavorite(id) == true {
                    favoriteFeedback += 1
                    onFavoriteChanged?(id, vm?.detail?.isFavorite == true)
                }
            }
        } label: {
            favoriteIcon
        }
        .disabled(currentServerAssetID == nil)

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
            Image(systemName: showInfo ? "info.circle.fill" : "info.circle")
        }
        .disabled(!hasDetail)
    }

    private var editPhotoButton: some View {
        Button {
            preparePhotoEditor()
        } label: {
            if isPreparingEditor {
                ProgressView()
            } else {
                Image(systemName: "crop.rotate")
            }
        }
        .disabled(currentServerAssetID == nil || editablePixelSize == nil || isPreparingEditor)
        .accessibilityLabel("Edit Photo")
    }

    private func preparePhotoEditor() {
        guard let serverID = currentServerAssetID, !isPreparingEditor else { return }
        isPreparingEditor = true
        Task {
            defer { isPreparingEditor = false }
            guard let edits = await vm?.edits(for: serverID) else { return }
            existingPhotoEdits = edits
            isEditingPhoto = true
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
        guard let serverID = currentServerAssetID else { return }
        Task {
            if await vm?.move(serverID, to: visibility) == true {
                removeCurrentAsset()
            }
        }
    }

    /// Aset yang dipindah keluar dari timeline tidak lagi ada di daftar ini.
    /// Lanjut ke foto berikutnya; kalau sudah di ujung, mundur ke sebelumnya;
    /// kalau memang tidak ada sisa, tutup layarnya.
    private func removeCurrentAsset() {
        guard pages.indices.contains(currentIndex),
              pages[currentIndex].id == currentAsset.id
        else {
            dismiss()
            return
        }

        onAssetRemoved?(currentAsset.id)
        pages.remove(at: currentIndex)

        guard !pages.isEmpty else {
            dismiss()
            return
        }

        // Lanjut ke foto berikutnya; kalau tadi yang terakhir, mundur satu.
        currentIndex = min(currentIndex, pages.count - 1)
        currentAsset = pages[currentIndex]
    }

    private var albums: [AlbumResponseDTO] {
        vm?.albums ?? []
    }

    /// Trash dengan konfirmasi yang menempel ke tombolnya.
    private var deleteButton: some View {
        Button(role: .destructive) {
            showDeleteConfirm = true
        } label: {
            Image(systemName: "trash")
        }
        .confirmationDialog(
            "Delete Photo",
            isPresented: $showDeleteConfirm,
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) { performDelete() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Are you sure you want to delete this photo?")
        }
    }

    private func performDelete() {
        guard let serverID = currentServerAssetID else { return }
        Task {
            if await vm?.delete(serverID) == true {
                deleteFeedback += 1
                removeCurrentAsset()
            }
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

    private func shareFile() async {
        guard !isPreparingShare else { return }

        isPreparingShare = true
        defer { isPreparingShare = false }

        guard let file = await currentFileURL() else { return }
        downloadedFileURL = file
        sharePreviewImage = currentAsset.isVideo ? nil : UIImage(contentsOfFile: file.path)
        isSharePresented = true
    }

    private var currentServerAssetID: String? {
        serverAssetID(for: currentAsset)
    }

    private func serverAssetID(for asset: AssetLite) -> String? {
        guard LocalPhotoLibrary.isLocal(asset.id) else {
            return asset.origin == .device ? nil : asset.id
        }
        let localID = LocalPhotoLibrary.localIdentifier(from: asset.id)
        return SwiftDataManager.shared.serverAssetIDsByLocalIdentifier()[localID]
    }

    private var editablePixelSize: CGSize? {
        guard let exif = vm?.detail?.exifInfo,
              let width = exif.exifImageWidth,
              let height = exif.exifImageHeight,
              width > 0, height > 0
        else { return nil }

        // Samakan dengan `getDimensions()` milik server Immich. Crop endpoint
        // memvalidasi terhadap dimensi yang sudah memperhitungkan EXIF rotate.
        let orientation = Int(exif.orientation ?? "")
        let swapsDimensions = orientation.map { [5, 6, 7, 8, -90, 90].contains($0) } ?? false
        return swapsDimensions
            ? CGSize(width: height, height: width)
            : CGSize(width: width, height: height)
    }

    /// Memilih salinan lokal lebih dulu; server hanya disentuh kalau aset belum
    /// ada di perangkat. Ini membuat Share pada foto lokal benar-benar lokal.
    private func currentFileURL() async -> URL? {
        if currentAsset.isOnDevice {
            let localIdentifier: String?
            if LocalPhotoLibrary.isLocal(currentAsset.id) {
                localIdentifier = LocalPhotoLibrary.localIdentifier(from: currentAsset.id)
            } else {
                localIdentifier = SwiftDataManager.shared.localIdentifier(
                    forServerAsset: currentAsset.id)
            }

            if let localIdentifier,
               let file = await LocalPhotoLibrary.shared.originalFile(
                   for: LocalPhotoLibrary.assetID(for: localIdentifier)) {
                return file.url
            }
        }

        guard let serverID = currentServerAssetID, let vm else { return nil }
        let filename = vm.detail?.originalFileName
            ?? (currentAsset.isVideo ? "video.mov" : "photo.jpg")
        return await vm.downloadOriginalFile(serverID, filename: filename)
    }

    private func createSharedLink(for serverID: String) {
        let repo = SharedLinkRepository(api: APIClient(session: session))
        Task {
            do {
                let link = try await repo.create(assetIds: [serverID])
                guard let url = link.publicURL(base: session.baseURL) else {
                    throw APIError.invalidURL
                }
                sharedLink = SharedLinkPresentation(url: url)
            } catch {
                vm?.actionError = ErrorEvent(error.localizedDescription)
            }
        }
    }

    private func uploadLocalAsset() {
        guard currentAsset.needsUpload else { return }
        isUploadingLocalAsset = true
        let id = currentAsset.id
        Task {
            await BackupService.shared.uploadNow([id])
            isUploadingLocalAsset = false
        }
    }

    private func downloadToDevice() {
        guard currentAsset.origin == .server,
              let serverID = currentServerAssetID,
              let vm,
              !isDownloadingToDevice
        else { return }

        let accountGeneration = LocalSnapshot.generation
        isDownloadingToDevice = true
        let filename = vm.detail?.originalFileName
            ?? (currentAsset.isVideo ? "video.mov" : "photo.jpg")
        let isVideo = currentAsset.isVideo
        Task {
            defer { isDownloadingToDevice = false }
            guard let file = await vm.downloadOriginalFile(serverID, filename: filename)
            else { return }
            defer { try? FileManager.default.removeItem(at: file) }

            guard let localID = await LocalPhotoLibrary.shared.saveDownloadedFile(
                file, isVideo: isVideo)
            else {
                vm.actionError = ErrorEvent(String(localized: "Could not save to Photos."))
                return
            }
            guard accountGeneration == LocalSnapshot.generation else { return }
            try? SwiftDataManager.shared.linkDeviceAsset(
                localIdentifier: localID, to: serverID)
            updateCurrentOrigin(.both)
        }
    }

    private func setAsProfilePhoto() {
        guard !currentAsset.isVideo, !isSettingProfilePhoto, let vm else { return }
        isSettingProfilePhoto = true
        Task {
            defer { isSettingProfilePhoto = false }
            guard let file = await currentFileURL() else {
                vm.actionError = ErrorEvent(String(localized: "Could not prepare the profile photo."))
                return
            }
            defer { try? FileManager.default.removeItem(at: file) }
            guard let jpeg = await Self.profileJPEG(from: file) else {
                vm.actionError = ErrorEvent(String(localized: "Could not prepare the profile photo."))
                return
            }
            guard await vm.setProfileImage(jpeg, filename: "profile.jpg") else { return }
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

    private func removeFromDevice() {
        guard deviceRemoval == nil else { return }
        let asset = currentAsset
        let service = FreeUpSpaceService(session: session)
        deviceRemoval = Task {
            defer { deviceRemoval = nil }
            do {
                try Task.checkCancellation()
                if asset.origin == .both {
                    guard try await DeviceCopyDeletion.perform(asset.id, using: service) else { return }
                    guard !Task.isCancelled, currentAsset.id == asset.id else { return }
                    // Device-album pages use PhotoKit IDs and leave this list
                    // when removed. A server page stays with a server-only badge.
                    if LocalPhotoLibrary.isLocal(asset.id) {
                        removeCurrentAsset()
                    } else {
                        updateCurrentOrigin(.server)
                    }
                } else if asset.origin == .device {
                    guard await LocalPhotoLibrary.shared.delete([asset.id]) else { return }
                    guard !Task.isCancelled, currentAsset.id == asset.id else { return }
                    removeCurrentAsset()
                }
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled, currentAsset.id == asset.id else { return }
                vm?.actionError = ErrorEvent(error.localizedDescription)
            }
        }
    }

    private func updateCurrentOrigin(_ origin: AssetOrigin) {
        currentAsset.origin = origin
        if pages.indices.contains(currentIndex), pages[currentIndex].id == currentAsset.id {
            pages[currentIndex] = currentAsset
        }
    }

    private func cleanupSharedFile() {
        if let downloadedFileURL { try? FileManager.default.removeItem(at: downloadedFileURL) }
        downloadedFileURL = nil
        sharePreviewImage = nil
    }
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

    func makeCoordinator() -> CleanupCoordinator {
        CleanupCoordinator(urls: urls)
    }

    func makeUIViewController(context: Context) -> UIActivityViewController {
        let controller = UIActivityViewController(activityItems: urls, applicationActivities: nil)
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

/// `dismantleUIViewController` menjadi pengaman bila sheet ditutup oleh SwiftUI
/// tanpa memanggil completion handler (mis. view induk ikut hilang).
final class CleanupCoordinator {
    private var urls: [URL]

    init(urls: [URL]) {
        self.urls = urls
    }

    func cleanup() {
        guard !urls.isEmpty else { return }
        TemporaryMediaStore.remove(urls)
        urls.removeAll()
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

struct VideoPlayerView: View {
    let assetId: String
    @Environment(SessionManager.self) private var session

    var body: some View {
        VStack {
            Text("Video - Coming Soon")
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.black)
    }
}


#Preview {
    let asset = AssetLite(id: "test-123", isVideo: false, ratio: 1.0, thumbhash: nil, createdAt: Date())
    AssetDetailView(currentAsset: asset, assets: [asset])
        .environment(SessionManager())
}
