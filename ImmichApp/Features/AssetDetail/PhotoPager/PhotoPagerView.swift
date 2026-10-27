import SwiftUI
import UIKit

/// Pager foto layar detail, ditopang `UICollectionView`.
///
/// Versi SwiftUI-nya harus membangun `ForEach` atas seluruh perpustakaan supaya
/// `scrollPosition(id:)` bisa menemukan halaman tujuan — pada puluhan ribu foto
/// itu mustahil, jadi dulu diakali dengan jendela 25 halaman yang digeser sendiri
/// setiap kali mendekati tepinya. Jendela itulah sumber sebagian besar keanehan
/// pagernya: indeks, `windowStart`, dan `scrollPosition` harus tetap sepakat
/// padahal ketiganya diperbarui di saat yang berbeda.
///
/// `UICollectionView` memaging seluruh daftar tanpa jendela apa pun, dan seperti
/// di grid, sel yang hidup hanya sebanyak yang terlihat.
struct PhotoPagerView: UIViewControllerRepresentable {
    let assets: [AssetLite]
    /// Foto yang sedang tampil. Dua arah: pager melapor saat diusap, dan ikut
    /// berpindah kalau dipilih dari strip thumbnail.
    let currentAssetID: String
    /// Nilai dari detail lengkap bila sudah tersedia. Daftar timeline lama bisa
    /// belum membawa pasangan Live Photo, jadi halaman aktif ditambal langsung.
    var livePhotoVideoID: String? = nil
    /// Fallback untuk aset server lama yang belum menyimpan relasi Live Photo.
    var localLivePhotoHint: LocalLivePhotoMatchHint? = nil
    var layout = PhotoPagerLayout()
    /// false saat panel info terbuka atau sedang menyunting deskripsi.
    var isPagingEnabled = true

    var onPageChanged: (AssetLite) -> Void
    var onZoomChanged: (Bool) -> Void
    var onTap: () -> Void
    /// Posisi halaman sebagai pecahan (mis. 12,37) SELAMA pager bergerak.
    ///
    /// Terpisah dari `onPageChanged` dengan sengaja: yang itu mengubah foto yang
    /// sedang dilihat, jadi ia harus menunggu sampai berhenti — kalau tidak,
    /// setiap foto yang cuma terlewat ikut memuat metadata. Yang ini murni untuk
    /// menggeser strip supaya ikut bergerak bersama jari.
    var onScrollProgress: ((Double) -> Void)? = nil
    /// Menyerahkan controller-nya, supaya bar kontrol video bisa menyambung
    /// langsung tanpa melewati `@State`.
    var onControllerReady: ((PhotoPagerController) -> Void)? = nil

    let session: SessionManager

    func makeUIViewController(context: Context) -> PhotoPagerController {
        let controller = PhotoPagerController(loader: PhotoPreviewLoader(session: session))
        bind(controller)
        controller.apply(assets: assets, currentAssetID: currentAssetID)
        controller.applyLivePhotoContext(
            videoID: livePhotoVideoID,
            localHint: localLivePhotoHint,
            for: currentAssetID)
        controller.apply(layout: layout, isPagingEnabled: isPagingEnabled)
        if let onControllerReady {
            // Di luar siklus pembaruan: menulis `@State` selagi SwiftUI sedang
            // membangun view memicu peringatan "modifying state during update".
            DispatchQueue.main.async { onControllerReady(controller) }
        }
        return controller
    }

    func updateUIViewController(_ controller: PhotoPagerController, context: Context) {
        bind(controller)
        controller.apply(assets: assets, currentAssetID: currentAssetID)
        controller.applyLivePhotoContext(
            videoID: livePhotoVideoID,
            localHint: localLivePhotoHint,
            for: currentAssetID)
        controller.apply(layout: layout, isPagingEnabled: isPagingEnabled)
    }

    static func dismantleUIViewController(
        _ controller: PhotoPagerController,
        coordinator: ()
    ) {
        // SwiftUI dapat tetap menahan controller selama animasi dismiss selesai.
        // Pemutar tidak boleh menunggu sel dilepas dari memori karena audionya
        // akan terus terdengar di layar sebelumnya selama jeda itu.
        controller.stopAllPlayback()
    }

    private func bind(_ controller: PhotoPagerController) {
        controller.onPageChanged = onPageChanged
        controller.onZoomChanged = onZoomChanged
        controller.onTap = onTap
        controller.onScrollProgress = onScrollProgress
    }
}

@MainActor
final class PhotoPagerController: UIViewController {
    private let loader: PhotoPreviewLoader

    private var collectionView: UICollectionView!
    private var assets: [AssetLite] = []
    private var assetIndex: [String: Int] = [:]
    private var currentIndex = 0
    private var imageReloadRequests: [String: UUID] = [:]
    private var layoutRules = PhotoPagerLayout()
    /// Izin dari layar induk (panel info/edit/keadaan SwiftUI). Status zoom
    /// digabungkan terpisah supaya pager dapat dikunci langsung di UIKit tanpa
    /// menunggu satu siklus render SwiftUI.
    private var requestedPagingEnabled = true
    private var isCurrentPageZoomed = false

    /// Penjaga supaya lompatan ke halaman awal hanya sekali, dan hanya setelah
    /// ukurannya nyata.
    private var hasPositioned = false
    /// true selagi kita sendiri yang menggeser halaman, supaya perpindahan itu
    /// tidak dilaporkan balik sebagai usapan pengguna.
    private var isProgrammaticScroll = false

    var onPageChanged: ((AssetLite) -> Void)?
    var onZoomChanged: ((Bool) -> Void)?
    var onTap: (() -> Void)?
    var onScrollProgress: ((Double) -> Void)?
    /// Bar kontrol video; dipegang lemah karena ia hidup di sisi SwiftUI.
    weak var playbackObserver: (any PhotoPlaybackObserver)?

    init(loader: PhotoPreviewLoader) {
        self.loader = loader
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) tidak dipakai") }

    override func viewDidLoad() {
        super.viewDidLoad()

        let flow = UICollectionViewFlowLayout()
        flow.scrollDirection = .horizontal
        flow.minimumLineSpacing = 0
        flow.minimumInteritemSpacing = 0
        flow.sectionInset = .zero

        let pagingView = HorizontalPagingCollectionView(
            frame: view.bounds, collectionViewLayout: flow)
        pagingView.shouldAllowPagingGesture = { [weak self] in
            // Pager hanya kalah bila foto benar-benar punya ruang pan mendatar.
            // Portrait yang masih lebih sempit dari layar tetap dapat di-swipe.
            self?.currentCell?.blocksPagingForZoom != true
        }
        collectionView = pagingView
        collectionView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        collectionView.backgroundColor = .clear
        collectionView.isPagingEnabled = true
        collectionView.showsHorizontalScrollIndicator = false
        collectionView.showsVerticalScrollIndicator = false
        collectionView.contentInsetAdjustmentBehavior = .never
        // Halaman tidak boleh ikut memantul secara vertikal; sumbu itu milik
        // scroll view di dalam sel saat fotonya di-zoom.
        collectionView.alwaysBounceVertical = false
        collectionView.alwaysBounceHorizontal = true
        collectionView.register(
            PhotoPagerCell.self, forCellWithReuseIdentifier: PhotoPagerCell.reuseID)
        collectionView.dataSource = self
        collectionView.delegate = self
        collectionView.prefetchDataSource = self
        view.addSubview(collectionView)
        updatePagingAvailability()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        // `dismantleUIViewController` adalah pagar terakhir saat representable
        // dibuang. Ini menghentikan audio lebih awal, tepat ketika layar detail
        // mulai meninggalkan layar selama transisi dismiss.
        stopAllPlayback()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()

        // Ukuran halaman selalu sebesar bounds — inilah syarat `isPagingEnabled`
        // berhenti tepat di batas foto.
        if let flow = collectionView.collectionViewLayout as? UICollectionViewFlowLayout,
           flow.itemSize != collectionView.bounds.size,
           collectionView.bounds.width > 0 {
            flow.itemSize = collectionView.bounds.size
            flow.invalidateLayout()
            // Bounds berubah (rotasi, toolbar tampil) menggeser halaman kalau
            // offsetnya dibiarkan; posisinya dikunci ulang ke halaman sekarang.
            scrollToCurrent(animated: false)
        }

        positionAtStartIfNeeded()
    }

    // MARK: - Data

    func apply(assets newAssets: [AssetLite], currentAssetID: String) {
        if !isSameContent(as: newAssets) {
            assets = newAssets
            assetIndex = [:]
            assetIndex.reserveCapacity(newAssets.count)
            for (offset, asset) in newAssets.enumerated() {
                assetIndex[asset.id] = offset
            }
            if isViewLoaded {
                collectionView.reloadData()
                // Ukuran kontennya harus sudah pasti sebelum offset disetel;
                // tanpa ini `setContentOffset` menembak ke luar batas yang masih
                // nol dan langsung dijepit kembali ke awal.
                collectionView.layoutIfNeeded()
            }
        }

        guard let index = assetIndex[currentAssetID] else { return }
        let movedElsewhere = index != currentIndex
        if movedElsewhere, hasPositioned, isViewLoaded {
            // Pilihan dari filmstrip dapat mengganti halaman tanpa gesture pager.
            // Pemutar lama harus dibongkar sebelum indeks aktif berubah.
            stopAllPlayback()
        }
        currentIndex = index
        guard isViewLoaded else { return }

        // Penempatan awal dicoba DI SINI, bukan hanya di `viewDidLayoutSubviews`.
        //
        // Daftarnya baru terisi setelah layar detail menjalankan `task`-nya, dan
        // kedatangan data itu tidak selalu memicu layout pass baru pada view
        // controller. Kalau penempatan awal cuma menunggu di sana, pagernya
        // tertinggal di offset nol — dan karena daftarnya menaik, nol itu foto
        // PALING LAMA, bukan yang ditekan.
        if !hasPositioned {
            positionAtStartIfNeeded()
        } else if movedElsewhere {
            // Dipilih dari strip thumbnail, bukan diusap: pagernya yang menyusul.
            scrollToCurrent(animated: false)
        }
    }

    func apply(layout newLayout: PhotoPagerLayout, isPagingEnabled: Bool) {
        layoutRules = newLayout
        requestedPagingEnabled = isPagingEnabled
        guard isViewLoaded else { return }

        updatePagingAvailability()
        for case let cell as PhotoPagerCell in collectionView.visibleCells {
            cell.apply(newLayout)
        }
    }

    private func updatePagingAvailability() {
        guard isViewLoaded else { return }
        collectionView.isScrollEnabled = requestedPagingEnabled && !isCurrentPageZoomed
    }

    private func handleZoomChanged(
        _ zoomed: Bool,
        blocksPaging: Bool,
        from index: Int
    ) {
        // Sel tetangga ikut hidup dan bisa menyelesaikan animasi zoom lama;
        // hanya halaman aktif yang boleh mengunci atau membuka pager.
        guard index == currentIndex else { return }
        isCurrentPageZoomed = blocksPaging
        // Kunci UIKit lebih dulu, baru teruskan ke SwiftUI untuk toolbar/status.
        updatePagingAvailability()
        onZoomChanged?(zoomed)
    }

    /// Memperbarui hanya metadata Live Photo halaman terkait. Ini sengaja tidak
    /// memakai `reloadData()`: detail server tiba sesudah layar tampil dan
    /// reload seluruh pager akan memutus gesture atau menggeser offset.
    func applyLivePhotoContext(
        videoID: String?,
        localHint: LocalLivePhotoMatchHint?,
        for assetID: String
    ) {
        guard let index = assetIndex[assetID], assets.indices.contains(index)
        else { return }

        if assets[index].livePhotoVideoID != videoID {
            assets[index].livePhotoVideoID = videoID
        }
        let path = IndexPath(item: index, section: 0)
        (collectionView?.cellForItem(at: path) as? PhotoPagerCell)?
            .updateLivePhotoContext(
                videoID: videoID,
                localHint: localHint,
                loader: loader)
    }

    /// Pembanding murah: jumlah plus kedua ujungnya.
    private func isSameContent(as other: [AssetLite]) -> Bool {
        assets.count == other.count
            && assets.first?.id == other.first?.id
            && assets.last?.id == other.last?.id
    }

    // MARK: - Posisi

    private func positionAtStartIfNeeded() {
        guard !hasPositioned, isViewLoaded,
              collectionView.bounds.width > 0,
              !assets.isEmpty
        else { return }

        hasPositioned = true
        scrollToCurrent(animated: false)
    }

    private func scrollToCurrent(animated: Bool) {
        guard assets.indices.contains(currentIndex),
              collectionView.bounds.width > 0
        else { return }

        // `setContentOffset`, bukan `scrollToItem`: yang kedua bisa mendarat di
        // tengah halaman kalau layoutnya belum sempat diperbarui, dan pada pager
        // itu berarti dua foto terlihat separuh-separuh.
        isProgrammaticScroll = true
        let offset = CGPoint(
            x: CGFloat(currentIndex) * collectionView.bounds.width, y: 0)
        collectionView.setContentOffset(offset, animated: animated)
        if !animated { isProgrammaticScroll = false }
    }

    private func reportPageIfChanged() {
        guard collectionView.bounds.width > 0 else { return }
        let page = Int(round(collectionView.contentOffset.x / collectionView.bounds.width))
        guard assets.indices.contains(page), page != currentIndex else { return }

        let previousCell = currentCell
        currentIndex = page
        // Kasus portrait sempit boleh berpindah walau scale > 1. Halaman lama
        // harus kembali ke 1x dan state chrome halaman baru harus normal.
        previousCell?.resetZoom()
        isCurrentPageZoomed = false
        updatePagingAvailability()
        onZoomChanged?(false)
        stopPlaybackOnOtherPages()
        reportPlaybackState()
        onPageChanged?(assets[page])
    }

    /// Menghentikan video di halaman yang sudah bukan halaman sekarang.
    ///
    /// Sel tetangga tetap hidup di pager, jadi tanpa ini videonya terus berjalan
    /// di halaman yang sudah lewat — tetap memakan jaringan dan menahan sesi
    /// audio, sementara layarnya sendiri sudah tidak terlihat.
    private func stopPlaybackOnOtherPages() {
        for case let cell as PhotoPagerCell in collectionView.visibleCells {
            guard let path = collectionView.indexPath(for: cell),
                  path.item != currentIndex
            else { continue }
            cell.stopPlayback()
        }
    }

    /// Menghentikan seluruh pemutar milik pager saat layar detail ditutup.
    ///
    /// Sel-selnya masih dapat hidup selama animasi transisi atau karena controller
    /// disimpan sementara oleh SwiftUI, jadi cleanup tidak boleh bergantung pada
    /// `prepareForReuse()`.
    func stopAllPlayback() {
        guard isViewLoaded else { return }
        for case let cell as PhotoPagerCell in collectionView.visibleCells {
            cell.stopPlayback()
        }
        reportPlaybackState()
    }

    // MARK: - Kendali video

    /// Sel halaman yang sedang dilihat.
    private var currentCell: PhotoPagerCell? {
        collectionView.cellForItem(at: IndexPath(item: currentIndex, section: 0))
            as? PhotoPagerCell
    }

    func togglePlayback() { currentCell?.togglePlayPause() }
    func toggleMute() { currentCell?.toggleMute() }
    func seek(toFraction fraction: Double) { currentCell?.seek(toFraction: fraction) }

    /// Hasil edit tetap milik aset asal walau pengguna sudah berganti halaman.
    func reloadImage(for assetID: String) async {
        let request = UUID()
        imageReloadRequests[assetID] = request
        defer {
            if imageReloadRequests[assetID] == request {
                imageReloadRequests[assetID] = nil
            }
        }
        await loader.invalidate(assetID)
        guard !Task.isCancelled,
              imageReloadRequests[assetID] == request,
              assets.indices.contains(currentIndex),
              assets[currentIndex].id == assetID
        else { return }
        currentCell?.configure(with: assets[currentIndex], loader: loader)
        currentCell?.apply(layoutRules)
    }

    /// Mengabarkan keadaan sekarang — dipakai bar kontrol saat baru menyambung
    /// atau setelah halaman berpindah.
    func reportPlaybackState() {
        playbackObserver?.playbackDidUpdate(currentCell?.playbackState ?? PhotoPlaybackState())
    }

    /// Halaman yang sedang di tengah layar; -1 kalau belum bisa dihitung.
    private var visiblePage: Int {
        guard collectionView.bounds.width > 0 else { return -1 }
        return Int(round(collectionView.contentOffset.x / collectionView.bounds.width))
    }

    /// Setelah berhenti, pastikan halaman ini dan tetangganya punya gambar.
    ///
    /// Prefetch bawaan `UICollectionView` bekerja dengan jendela yang sempit pada
    /// pager, dan gulir cepat membatalkan pemuatan di tengah jalan. Ini murah:
    /// yang sudah ada di memori dijawab seketika, dan permintaan yang sedang
    /// berjalan digabungkan oleh `ImageCache`, bukan diulang.
    private func settleVisiblePages() {
        for case let cell as PhotoPagerCell in collectionView.visibleCells {
            cell.retryIfNeeded(loader: loader)
        }

        let page = visiblePage
        guard page >= 0 else { return }
        let neighbours = [page - 2, page - 1, page + 1, page + 2]
            .filter { assets.indices.contains($0) }
            .map { assets[$0].id }
        guard !neighbours.isEmpty else { return }
        loader.prefetch(neighbours)
    }
}

// MARK: - Sumber data

extension PhotoPagerController: UICollectionViewDataSource {
    func collectionView(
        _ collectionView: UICollectionView, numberOfItemsInSection section: Int
    ) -> Int {
        assets.count
    }

    func collectionView(
        _ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath
    ) -> UICollectionViewCell {
        let cell = collectionView.dequeueReusableCell(
            withReuseIdentifier: PhotoPagerCell.reuseID, for: indexPath)
        guard let pageCell = cell as? PhotoPagerCell,
              assets.indices.contains(indexPath.item)
        else { return cell }

        pageCell.configure(with: assets[indexPath.item], loader: loader)
        pageCell.apply(layoutRules)
        pageCell.onZoomChanged = { [weak self] zoomed, blocksPaging in
            self?.handleZoomChanged(
                zoomed,
                blocksPaging: blocksPaging,
                from: indexPath.item)
        }
        pageCell.onTap = { [weak self] in self?.onTap?() }
        // Hanya halaman yang sedang dilihat yang boleh melapor; sel tetangga
        // ikut hidup dan laporannya akan menimpa keadaan yang benar.
        pageCell.onPlaybackChanged = { [weak self] state in
            guard let self, indexPath.item == self.currentIndex else { return }
            self.playbackObserver?.playbackDidUpdate(state)
        }
        return pageCell
    }
}

// MARK: - Delegate

extension PhotoPagerController: UICollectionViewDelegate {
    func collectionView(
        _ collectionView: UICollectionView, didEndDisplaying cell: UICollectionViewCell,
        forItemAt indexPath: IndexPath
    ) {
        // Offscreen cells can remain retained without prepareForReuse, and
        // visibleCells no longer includes them during the final dismiss pass.
        (cell as? PhotoPagerCell)?.stopPlayback()
    }

    // Pager sengaja TIDAK berdetak: ketukan haptic hanya milik strip thumbnail,
    // supaya satu usapan tidak menghasilkan dua getaran yang saling menimpa.

    /// Melaporkan posisi selama bergerak, bukan hanya saat berhenti.
    ///
    /// Dibatasi pada gerakan yang berasal dari jari. Penggeseran yang kita
    /// lakukan sendiri — mis. saat sebuah thumbnail ditekan — tidak boleh
    /// dilaporkan balik, karena itu justru akan menarik stripnya melawan
    /// perpindahan yang baru saja dimintanya.
    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        guard scrollView.isDragging || scrollView.isDecelerating,
              collectionView.bounds.width > 0
        else { return }
        onScrollProgress?(Double(collectionView.contentOffset.x / collectionView.bounds.width))
    }

    func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
        // Hentikan sejak jari mulai menggeser, bukan setelah deselerasi selesai.
        // Dengan membongkar item, kembali ke video ini selalu mulai dari awal.
        stopAllPlayback()
    }

    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
        reportPageIfChanged()
        settleVisiblePages()
    }

    func scrollViewDidEndScrollingAnimation(_ scrollView: UIScrollView) {
        isProgrammaticScroll = false
        reportPageIfChanged()
        settleVisiblePages()
    }

    /// Usapan yang berhenti tanpa deselerasi tetap berpindah halaman.
    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        guard !decelerate else { return }
        reportPageIfChanged()
        settleVisiblePages()
    }
}

// MARK: - Prefetching

extension PhotoPagerController: UICollectionViewDataSourcePrefetching {
    func collectionView(
        _ collectionView: UICollectionView, prefetchItemsAt indexPaths: [IndexPath]
    ) {
        let ids = indexPaths
            .filter { assets.indices.contains($0.item) }
            .map { assets[$0.item].id }
        guard !ids.isEmpty else { return }
        loader.prefetch(ids)
    }
}


/// Collection view yang hanya mau digulir MENDATAR.
///
/// Usapan ke atas di layar detail artinya membuka panel info, dan usapan ke
/// bawah artinya menutup layar. Keduanya jarang benar-benar tegak lurus — selalu
/// ada sedikit komponen mendatar, dan itu sudah cukup membuat pager ikut
/// berpindah foto di tengah gerakan. Menolak gestur yang lebih tegak daripada
/// mendatar sejak awal membuat ketiganya tidak pernah berebut.
private final class HorizontalPagingCollectionView: UICollectionView {
    var shouldAllowPagingGesture: (() -> Bool)?

    override func gestureRecognizerShouldBegin(_ recognizer: UIGestureRecognizer) -> Bool {
        if recognizer === panGestureRecognizer {
            guard shouldAllowPagingGesture?() ?? true else { return false }
            let velocity = panGestureRecognizer.velocity(in: self)
            if abs(velocity.y) > abs(velocity.x) { return false }
        }
        return super.gestureRecognizerShouldBegin(recognizer)
    }
}
