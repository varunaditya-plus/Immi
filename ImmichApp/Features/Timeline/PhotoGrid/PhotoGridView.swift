import SwiftUI
import UIKit

/// Perbedaan antar layar yang memakai grid ini.
///
/// Semua layar foto — linimasa, album, Favorites, orang, Archived, Trash —
/// sebenarnya grid yang sama; yang berbeda cuma hal-hal di bawah ini. Menjadikan
/// perbedaannya data, bukan kelas turunan, membuat perbaikan performa cukup
/// dikerjakan sekali.
/// Bentuk petaknya.
enum PhotoGridLayoutStyle: Equatable {
    /// Persegi, n kolom seragam — linimasa dan seluruh koleksi.
    case square
    /// Tinggi seragam per baris, lebar tiap petak mengikuti rasio fotonya, dan
    /// barisnya rata penuh ke kedua tepi. Dipakai hasil pencarian.
    case justified
}

struct PhotoGridConfiguration: Equatable {
    var layoutStyle: PhotoGridLayoutStyle = .square
    var columns: Int = 3
    /// Judul bulan yang menempel di tepi atas.
    ///
    /// Sekaligus menentukan apakah gridnya DIPECAH per bulan. Batas section-lah
    /// yang memaksa baris terakhir sebuah bulan berhenti di tengah jalan: Januari
    /// berisi 5 foto menyisakan satu petak kosong, lalu Februari mulai dari baris
    /// baru. Itu harga yang wajar kalau ada judul bulan yang memisahkan keduanya
    /// — tapi tanpa judul, yang tersisa cuma lubang tanpa alasan.
    ///
    /// Karena itu saat judulnya dimatikan, seluruh foto disatukan ke satu section
    /// dan barisnya mengalir terus melewati pergantian bulan. Bulan yang sedang
    /// tampil tetap dilaporkan — dihitung dari posisi foto, bukan dari section.
    var showsSectionHeaders: Bool = true
    /// Membuka tampilan di foto TERBARU, yaitu paling bawah. Hanya linimasa.
    var startsAtNewest: Bool = false
    /// Tinggi sampul yang ikut tergulir di atas grid; 0 berarti tidak ada.
    var heroHeight: CGFloat = 0
    /// Petak "+" di ujung baris terakhir.
    var showsAddTile: Bool = false
    /// Isi digulir sampai ke belakang nav bar — untuk layar bersampul, di mana
    /// gambarnya memang harus terlihat penuh di balik tombol-tombolnya.
    var extendsUnderTopBar: Bool = false
    /// Sisa baris yang tidak genap dikumpulkan di ATAS, bukan di bawah.
    ///
    /// Linimasa dibaca dari bawah — foto terbaru ada di sana, dan di sanalah
    /// tampilannya terbuka. Baris terbawah yang bolong berarti lubang justru di
    /// tempat yang paling sering dilihat. Menggeser sisanya ke puncak membuat
    /// setiap baris penuh kecuali yang paling atas, yang hampir tidak pernah
    /// terlihat.
    var padsFirstRow: Bool = false
}

/// Grid foto, ditopang `UICollectionView`.
///
/// Alasannya bukan selera, melainkan sifat dasar keduanya:
///
/// - `LazyVGrid` membangun deskriptor view untuk SELURUH isi grid supaya bisa
///   menata dirinya. Pada perpustakaan puluhan ribu foto itu puluhan ribu nilai
///   view — masing-masing membawa context menu, sumber transisi, dan pemuat
///   gambar sendiri — dialokasikan sekali di layout pertama dan tidak pernah
///   dilepas. Itulah ratusan megabyte yang terlihat rata di grafik memori.
/// - `UICollectionView` hanya pernah membuat sel sebanyak yang muat di layar
///   plus sedikit cadangan, lalu MENDAUR ULANG-nya. Berapa pun panjang
///   perpustakaannya, jumlah objek yang hidup tetap sama.
///
/// Yang ikut hilang bersama perpindahan ini cuma gestur seret-pilih kustom
/// beserta auto-scroll-nya, digantikan seleksi banyak bawaan UIKit. Zoom
/// transition ke layar detail, yang menuntut sumber berupa view SwiftUI.
struct PhotoGridView: UIViewControllerRepresentable {
    let sections: [TimelineSection]
    var configuration = PhotoGridConfiguration()
    /// Sampul yang tergulir bersama grid, bukan menempel di atasnya.
    ///
    /// Dititipkan sebagai `AnyView` dan dihosting di sel paling atas. Isinya
    /// tetap SwiftUI — hanya tempat tinggalnya yang pindah, supaya ia berada di
    /// dalam scroll view yang sama dengan fotonya.
    var hero: AnyView? = nil

    @Binding var isSelecting: Bool
    @Binding var selectedIDs: Set<String>

    /// Menerima ID, bukan `AssetLite`.
    ///
    /// Salinan aset yang dipegang controller dibekukan saat snapshot terakhir
    /// disusun, dan snapshot itu sengaja TIDAK disusun ulang kalau daftarnya
    /// tidak berubah — termasuk saat yang berubah cuma status favorit sebuah
    /// foto. Dengan menyerahkan id, sisi SwiftUI selalu membaca nilai terbaru
    /// dan tidak ada yang bisa basi.
    var onOpen: ((String) -> Void)? = nil
    /// Layar detail untuk sebuah foto, dibangun saat dibutuhkan.
    ///
    /// Presentasinya dipegang UIKit, bukan `fullScreenCover`: animator transisi
    /// harus tahu kotak sel asal dan kotak foto tujuan, dan `fullScreenCover`
    /// tidak menyediakan celah untuk menyisipkan animator. Isinya tetap SwiftUI
    /// — hanya cara membukanya yang pindah.
    var detailScreen: ((String) -> AnyView)? = nil
    var onAddTapped: (() -> Void)? = nil
    var onVisibleSectionChanged: ((TimelineSection) -> Void)? = nil
    /// Posisi judul sampul dalam koordinat isi; lihat catatan di controller.
    var titleDockContentY: CGFloat = .infinity
    /// Judul sampul sudah/belum menyentuh toolbar.
    var onTitleDockedChanged: ((Bool) -> Void)? = nil
    /// Isi context menu untuk sebuah foto. Dibangun saat ditekan, bukan
    /// dipasang di setiap sel.
    var menuActions: (String) -> [PhotoGridMenuAction]
    /// Ujung daftar sudah terlihat — pemanggil boleh mengambil halaman
    /// berikutnya. Hanya berarti untuk isi yang dipaginasi (hasil pencarian).
    var onReachEnd: (() -> Void)? = nil
    /// Snapshot pembuka sudah final dan boleh diperlihatkan.
    ///
    /// Hanya timeline yang menahannya sampai sync pembuka selesai. Grid lain
    /// memakai nilai bawaan dan tetap tampil seketika.
    var initialContentReady = true
    /// Dipanggil setelah snapshot final benar-benar terlihat di posisi newest.
    var onInitialContentDisplayed: (() -> Void)? = nil
    /// Menyerahkan controller-nya ke pemanggil, untuk perintah yang datang dari
    /// luar (mis. "kembali ke foto terbaru" saat tab ditekan ulang).
    var onControllerReady: ((PhotoGridController) -> Void)? = nil

    let session: SessionManager

    func makeUIViewController(context: Context) -> PhotoGridController {
        let controller = PhotoGridController(
            loader: PhotoThumbnailLoader(session: session),
            session: session)
        bind(controller)
        controller.apply(sections: sections, configuration: configuration, hero: hero)
        // Diserahkan di luar siklus pembaruan: menulis `@State` selagi SwiftUI
        // sedang membangun view akan memicu peringatan "modifying state during
        // view update".
        if let onControllerReady {
            DispatchQueue.main.async { onControllerReady(controller) }
        }
        return controller
    }

    func updateUIViewController(_ controller: PhotoGridController, context: Context) {
        bind(controller)
        controller.apply(sections: sections, configuration: configuration, hero: hero)
        controller.setSelecting(isSelecting)
        controller.setSelection(selectedIDs)
    }

    private func bind(_ controller: PhotoGridController) {
        controller.onOpen = onOpen
        controller.makeDetail = detailScreen.map { build in
            { id in UIHostingController(rootView: build(id)) }
        }
        controller.onAddTapped = onAddTapped
        controller.onVisibleSectionChanged = onVisibleSectionChanged
        controller.titleDockContentY = titleDockContentY
        controller.onTitleDockedChanged = onTitleDockedChanged
        controller.menuActions = menuActions
        controller.onReachEnd = onReachEnd
        controller.onInitialContentDisplayed = onInitialContentDisplayed
        controller.setInitialContentReady(initialContentReady)
        controller.onSelectionChanged = { selectedIDs = $0 }
        controller.onSelectingChanged = { isSelecting = $0 }
    }
}

/// Satu tindakan di context menu foto.
/// Di mana sebuah aksi duduk di dalam context menu.
enum PhotoGridMenuGroup {
    /// Baris ikon mendatar di puncak menu — hanya ikonnya, tanpa tulisan.
    ///
    /// Untuk aksi yang paling sering dipakai dan sudah terbaca dari gambarnya
    /// saja. Menaruh lebih dari tiga atau empat di sini justru merusaknya:
    /// barisnya menyempit dan ikonnya berhenti bisa dibedakan.
    case quick
    /// Baris biasa dengan tulisan, di bawah baris ikon.
    case list
}

struct PhotoGridMenuAction {
    let title: String
    let systemImage: String
    var isDestructive = false
    /// Ditaruh SETELAH `isDestructive` supaya urutan memberwise init yang lama
    /// tetap sah — pemanggil yang belum mengenal grup tidak perlu diubah.
    var group: PhotoGridMenuGroup = .list
    let handler: () -> Void
}

/// Penyelesai cubic bezier — kurva yang sama dengan yang dipakai
/// `CAMediaTimingFunction`, tapi bisa dievaluasi sendiri per frame.
struct UnitBezier {
    private let ax, bx, cx, ay, by, cy: Double

    init(_ p1x: Double, _ p1y: Double, _ p2x: Double, _ p2y: Double) {
        cx = 3 * p1x
        bx = 3 * (p2x - p1x) - cx
        ax = 1 - cx - bx
        cy = 3 * p1y
        by = 3 * (p2y - p1y) - cy
        ay = 1 - cy - by
    }

    private func x(_ t: Double) -> Double { ((ax * t + bx) * t + cx) * t }
    private func dx(_ t: Double) -> Double { (3 * ax * t + 2 * bx) * t + cx }
    private func y(_ t: Double) -> Double { ((ay * t + by) * t + cy) * t }

    /// Newton-Raphson: kurvanya diberi waktu, bukan parameter — jadi `t` harus
    /// dicari lebih dulu. Delapan iterasi sudah jauh lebih teliti daripada satu
    /// piksel.
    func value(for progress: Double) -> Double {
        var t = progress
        for _ in 0..<8 {
            let error = x(t) - progress
            if abs(error) < 1e-4 { break }
            let slope = dx(t)
            if abs(slope) < 1e-6 { break }
            t -= error / slope
        }
        return y(t)
    }
}

/// Id semu untuk sel yang bukan foto.
///
/// Diberi awalan yang tidak mungkin bertabrakan dengan id aset dari server,
/// sehingga satu snapshot bisa memuat ketiganya tanpa tipe item tambahan.
private let heroItemID = "__photogrid.hero__"
private let addItemID = "__photogrid.add__"
/// Awalan id petak kosong perata baris pertama. Tiap petak butuh id sendiri —
/// snapshot diffable menuntut identitas yang unik.
private let padItemPrefix = "__photogrid.pad."
/// Satu-satunya section saat gridnya diratakan.
private let flatSectionID = "__photogrid.flat__"
private let gridSpacing: CGFloat = 2

/// Kotak isi yang dibagi antara controller dan closure layout.
///
/// Layout persegi cukup tahu jumlah kolomnya — itu ada di konfigurasi, dan
/// karena itu `makeLayout` bisa menangkap SALINAN konfigurasi saja. Tata letak
/// justified tidak bisa: lebar tiap petak diturunkan dari rasio fotonya, jadi
/// closure-nya harus melihat daftar fotonya sendiri, dan daftar itu berganti
/// jauh lebih sering daripada konfigurasi.
///
/// Kotak inilah jalan tengahnya. Layout menangkap kotaknya, bukan controller —
/// jadi tidak ada jalur kepemilikan baru yang harus dijaga — dan controller
/// cukup mengisinya lalu meminta layout mengukur ulang.
final class JustifiedLayoutStore {
    var assets: [AssetLite] = []
}

@MainActor
final class PhotoGridController: UIViewController {
    private enum SectionID: Hashable {
        case hero
        case month(String)
    }

    private let loader: PhotoThumbnailLoader
    private let session: SessionManager

    private var collectionView: UICollectionView!
    private var dataSource: UICollectionViewDiffableDataSource<SectionID, String>!
    /// Aset seperti yang TERAKHIR digambar, diindeks id.
    ///
    /// Pembanding untuk `reconfigureChangedItems`: snapshot hanya menyimpan id,
    /// jadi tanpa salinan ini tidak ada cara mengetahui isi sel mana yang
    /// berubah tanpa mengubah identitasnya.
    private var renderedAssets: [String: AssetLite] = [:]

    private var sections: [TimelineSection] = []
    private var assetsByID: [String: AssetLite] = [:]
    private var sectionTitles: [SectionID: String] = [:]
    private var configuration = PhotoGridConfiguration()
    private var hero: AnyView?
    /// Isi untuk tata letak justified; dibaca closure layout, ditulis di sini.
    private let justifiedStore = JustifiedLayoutStore()

    /// Selama masih true, tampilan dikembalikan ke foto terbaru setiap kali
    /// isinya berganti.
    ///
    /// Sebelumnya ini penanda sekali-jalan, dan itu tidak cukup: `dataSource
    /// .apply` dengan perubahan besar berarti `reloadData` di dalamnya, yang
    /// MENGEMBALIKAN posisi gulir ke puncak. Sync pertama biasanya selesai
    /// sesaat setelah linimasa tergambar, jadi urutannya jadi "mendarat di foto
    /// terbaru, lalu tersentak ke atas" — dan karena penandanya sudah terpakai,
    /// tidak ada lagi yang mengembalikannya.
    ///
    /// Sebagai jangkar, ia bertahan sampai penggunanya sendiri yang menggulir.
    private var isAnchoredToNewest = true
    /// Snapshot pertama dapat terpasang sebelum collection view mempunyai tinggi
    /// final. Dalam keadaan itu offset masih nol dan bagian lama sempat terlihat
    /// satu frame sebelum `viewDidLayoutSubviews` memindahkannya ke bawah.
    /// Grid tetap dilayout, tetapi baru diperlihatkan setelah pin pertama sukses.
    private var isWaitingForInitialNewestPosition = false
    /// Nilai dari pemilik grid. Timeline menahannya selama snapshot cache masih
    /// mungkin segera diganti hasil sync pembuka.
    private var initialContentReady = true
    /// Revisi snapshot yang sedang dipasang. Verifikasi tampilan awal hanya sah
    /// kalau tidak ada snapshot lebih baru yang masuk di sela dua layout pass.
    private var contentRevision = 0
    private var applyingSnapshotRevision: Int?
    /// Bulan terakhir yang dilaporkan, supaya tidak melapor berulang tiap frame.
    private var lastReportedSection: String?
    /// Snapshot yang sudah disusun tapi belum bisa dipasang.
    ///
    /// SwiftUI memanggil `apply` dari `makeUIViewController`, yaitu SEBELUM
    /// `viewDidLoad` — pada saat itu `dataSource` masih nil dan memanggilnya
    /// berarti crash. Snapshot-nya dititipkan di sini dan dipasang begitu
    /// view-nya benar-benar ada.
    /// Isi berikutnya beserta model turunannya — dipasang sekaligus, tidak
    /// sepotong-sepotong.
    private struct PendingContent {
        let sections: [TimelineSection]
        let assetsByID: [String: AssetLite]
        let sectionTitles: [SectionID: String]
        let flatPadCount: Int
        let snapshot: NSDiffableDataSourceSnapshot<SectionID, String>
    }
    private var pending: PendingContent?
    /// Jari sedang menggulir, atau lemparannya masih meluncur.
    private var isScrolling = false
    /// Animasi "kembali ke foto terbaru" sedang berjalan.
    private var isReturningToNewest = false
    /// Penggerak animasi "kembali ke terbaru", satu langkah per frame layar.
    ///
    /// BUKAN `UIView.animate` maupun `UIViewPropertyAnimator`. Menyetel
    /// `contentOffset` di dalam blok animasi hanya menulis nilai MODEL-nya sekali
    /// jalan; yang diinterpolasi cuma presentation layer. Akibatnya
    /// `layoutSubviews` collection view berjalan satu kali untuk posisi tujuan —
    /// tidak ada satu pun sel di antaranya yang pernah dibangun, dan yang
    /// terlihat bukan gulir melainkan isi lama menggeser keluar lalu isi baru
    /// menggeser masuk melewati pita kosong.
    ///
    /// Menulis offsetnya sendiri tiap frame membuat gulirannya sungguhan: sel
    /// didaur ulang, `scrollViewDidScroll` berjalan, dan judul bulan di toolbar
    /// ikut berganti sepanjang jalan — persis seperti di Photos.
    private var returnLink: CADisplayLink?
    private var returnFrom: CGFloat = 0
    private var returnStartedAt: CFTimeInterval = 0
    /// 0,35 detik — diukur dari rekaman Photos: sepuluh frame pada 30fps.
    private static let returnDuration: CFTimeInterval = 0.35
    /// Kepala landai supaya berangkatnya tidak menyentak, ekor panjang supaya
    /// mendaratnya meredam — diukur dari rekaman Photos: dua frame pertama pelan,
    /// tengahnya beberapa layar per frame, tiga frame terakhir melandai.
    private static let returnCurve = UnitBezier(0.3, 0, 0.22, 1)
    /// Konfigurasi yang sudah tergambar, untuk tahu kapan layout perlu disusun
    /// ulang.
    private var appliedConfiguration: PhotoGridConfiguration?

    var onOpen: ((String) -> Void)?
    var onAddTapped: (() -> Void)?
    var onVisibleSectionChanged: ((TimelineSection) -> Void)?
    var onSelectionChanged: ((Set<String>) -> Void)?
    /// Seret dua jari boleh MASUK ke mode pilih sendiri, seperti di Photos;
    /// SwiftUI perlu tahu supaya toolbar-nya ikut berubah.
    var onSelectingChanged: ((Bool) -> Void)?
    var menuActions: ((String) -> [PhotoGridMenuAction])?
    var onReachEnd: (() -> Void)?
    var onInitialContentDisplayed: (() -> Void)?
    /// Pembangun layar detail. Kalau nil, ketukan hanya diteruskan ke `onOpen`.
    var makeDetail: ((String) -> UIViewController)?

    /// Posisi (dalam koordinat isi) yang kalau tersentuh tepi bawah toolbar
    /// dianggap "judulnya sudah merapat".
    ///
    /// Angkanya datang dari sisi SwiftUI, diukur dari judul sungguhan di dalam
    /// sampul — bukan ditebak dari tinggi sampul. Judul album bisa satu sampai
    /// tiga baris tergantung panjang namanya dan ukuran teks pilihan pengguna,
    /// dan tebakan apa pun akan meleset persis di kasus-kasus itu.
    var titleDockContentY: CGFloat = .infinity

    /// Dipanggil HANYA saat keadaannya berganti, bukan tiap frame gulir.
    ///
    /// Ini yang membuatnya aman: menyalurkan offset mentah ke `@State` berarti
    /// seluruh body layar dibangun ulang puluhan kali per detik selama menggulir,
    /// dan bersamanya seluruh grid ikut di-`apply` ulang.
    var onTitleDockedChanged: ((Bool) -> Void)?
    private var isTitleDocked = false

    /// Penyambung transisi, disimpan selama layar detail tampil — UIKit hanya
    /// memegangnya lewat referensi lemah.
    private var zoomTransition: PhotoZoomTransitioningDelegate?
    /// Tarik-ke-bawah untuk menutup, dipasang setelah layar detail tampil.
    private var dismissGesture: PhotoZoomDismissGesture?
    /// Sel yang disembunyikan selagi fotonya "terbang".
    private var hiddenZoomID: String?
    /// Berapa petak kosong yang mendahului foto pertama di grid yang diratakan.
    ///
    /// Indeks item di collection view karena itu bergeser sebanyak ini terhadap
    /// indeks foto yang sebenarnya.
    private var flatPadCount = 0

    init(loader: PhotoThumbnailLoader, session: SessionManager) {
        self.loader = loader
        self.session = session
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) tidak dipakai") }

    override func viewDidLoad() {
        super.viewDidLoad()
        configureCollectionView()
        configureDataSource()
        // Data mungkin sudah datang sebelum view ini ada; pasang sekarang.
        flushPendingSnapshot()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        scrollToNewestIfNeeded()
        // Terbang yang tidak pernah selesai — aplikasi masuk latar di tengah
        // jalan, misalnya — akan meninggalkan penahanan dan penghentian pemuat
        // menyala selamanya: grid berhenti diperbarui dan setiap thumbnail
        // mengembalikan nil. Titik ini yang membereskannya.
        if isReturningToNewest, returnLink == nil {
            finishReturningToNewest()
        }
        // Jaring pengaman untuk isi yang tertahan.
        //
        // Penahanan dilepas oleh callback akhir-gulir, dan ada gulir yang
        // dipotong tanpa callback apa pun — misalnya `scrollToItem` yang
        // memotong lemparan yang masih meluncur. Tanpa titik coba-lagi ini,
        // isinya bisa tertahan selamanya dan grid berhenti diperbarui sampai
        // pengguna menggulir lagi.
        flushPendingSnapshot()
    }

    // MARK: - Penyusunan

    private func configureCollectionView() {
        collectionView = UICollectionView(
            frame: view.bounds, collectionViewLayout: makeLayout())
        collectionView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        collectionView.backgroundColor = .systemBackground
        collectionView.alwaysBounceVertical = true
        view.backgroundColor = .systemBackground

        isWaitingForInitialNewestPosition = configuration.startsAtNewest
        collectionView.alpha = isWaitingForInitialNewestPosition ? 0 : 1

        collectionView.register(
            PhotoGridCell.self, forCellWithReuseIdentifier: PhotoGridCell.reuseID)
        collectionView.register(
            PhotoGridAddCell.self, forCellWithReuseIdentifier: PhotoGridAddCell.reuseID)
        collectionView.register(
            PhotoGridPadCell.self, forCellWithReuseIdentifier: PhotoGridPadCell.reuseID)
        collectionView.register(
            PhotoGridHostCell.self, forCellWithReuseIdentifier: PhotoGridHostCell.reuseID)
        collectionView.register(
            PhotoGridHeaderView.self,
            forSupplementaryViewOfKind: UICollectionView.elementKindSectionHeader,
            withReuseIdentifier: PhotoGridHeaderView.reuseID)

        collectionView.delegate = self
        // Prefetch bawaan: UIKit sendiri yang memberi tahu foto mana yang sebentar
        // lagi dibutuhkan, dan membatalkannya kalau ternyata terlewati.
        collectionView.prefetchDataSource = self
        collectionView.isPrefetchingEnabled = true

        // Seleksi banyak BAWAAN — termasuk seret dua jari untuk memilih rentang.
        // Ini menggantikan seluruh recognizer kustom kita beserta auto-scroll-nya.
        collectionView.allowsMultipleSelectionDuringEditing = true

        view.addSubview(collectionView)
        applyContentInsets()
    }

    override func viewSafeAreaInsetsDidChange() {
        super.viewSafeAreaInsetsDidChange()
        applyContentInsets()
        // Tab bar/safe area sering selesai dihitung SETELAH snapshot pertama
        // sudah diposisikan. Ulangi di run loop berikutnya dengan inset final;
        // kalau tidak, baris terbaru berhenti di balik tab bar sampai pengguna
        // menyentuh scroll view.
        guard configuration.startsAtNewest, isAnchoredToNewest else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, self.isAnchoredToNewest else { return }
            _ = self.scrollToNewestIfNeeded()
        }
    }

    /// Layar bersampul menolak penyesuaian inset otomatis.
    ///
    /// Dengan `.automatic`, UIKit menambahkan inset setinggi nav bar dan
    /// sampulnya berhenti tepat di bawahnya — padahal justru gambar itulah yang
    /// harus terlihat penuh sampai ke belakang tombol-tombolnya. Karena
    /// penyesuaian dimatikan, inset bawah dipasang sendiri agar foto terakhir
    /// tidak tertutup home indicator.
    private func applyContentInsets() {
        guard isViewLoaded else { return }
        guard configuration.extendsUnderTopBar else {
            collectionView.contentInsetAdjustmentBehavior = .automatic
            collectionView.contentInset = .zero
            collectionView.verticalScrollIndicatorInsets = .zero
            return
        }

        collectionView.contentInsetAdjustmentBehavior = .never
        let insets = UIEdgeInsets(
            top: 0, left: 0, bottom: view.safeAreaInsets.bottom, right: 0)
        collectionView.contentInset = insets
        collectionView.verticalScrollIndicatorInsets = insets
    }

    // MARK: - Tata letak

    /// Layout dibangun dari SALINAN konfigurasi, bukan dari `self`.
    ///
    /// `sectionProvider` dipanggil oleh UIKit kapan saja ia perlu mengukur
    /// ulang, dan closure-nya ditahan oleh layout selama layout itu hidup.
    /// Menangkap controller di dalamnya berarti satu lagi jalur kepemilikan yang
    /// harus dijaga; menangkap nilai konfigurasinya cukup, karena setiap
    /// perubahan konfigurasi memang sudah menyusun layout baru.
    private func makeLayout() -> UICollectionViewCompositionalLayout {
        appliedConfiguration = configuration
        let config = configuration

        let layoutConfiguration = UICollectionViewCompositionalLayoutConfiguration()
        layoutConfiguration.interSectionSpacing = gridSpacing

        let store = justifiedStore

        return UICollectionViewCompositionalLayout(
            sectionProvider: { index, environment in
                // Sampul selalu section pertama kalau ada — lihat `apply`.
                if config.heroHeight > 0 && index == 0 {
                    return heroLayoutSection(config)
                }
                switch config.layoutStyle {
                case .square:
                    return photoLayoutSection(config, environment)
                case .justified:
                    return justifiedLayoutSection(config, environment, store)
                }
            },
            configuration: layoutConfiguration)
    }

    // MARK: - Sumber data

    private func configureDataSource() {
        dataSource = UICollectionViewDiffableDataSource<SectionID, String>(
            collectionView: collectionView
        ) { [weak self] collectionView, indexPath, itemID in
            guard let self else {
                return collectionView.dequeueReusableCell(
                    withReuseIdentifier: PhotoGridCell.reuseID, for: indexPath)
            }
            return self.cell(collectionView, indexPath, itemID)
        }

        dataSource.supplementaryViewProvider = { [weak self] collectionView, kind, indexPath in
            let view = collectionView.dequeueReusableSupplementaryView(
                ofKind: kind,
                withReuseIdentifier: PhotoGridHeaderView.reuseID,
                for: indexPath)
            guard let self, let header = view as? PhotoGridHeaderView,
                  let sectionID = self.dataSource.sectionIdentifier(for: indexPath.section)
            else { return view }

            header.configure(title: self.sectionTitles[sectionID] ?? "")
            return header
        }
    }

    private func cell(
        _ collectionView: UICollectionView,
        _ indexPath: IndexPath,
        _ itemID: String
    ) -> UICollectionViewCell {
        if itemID == heroItemID {
            let cell = collectionView.dequeueReusableCell(
                withReuseIdentifier: PhotoGridHostCell.reuseID, for: indexPath)
            (cell as? PhotoGridHostCell)?.host(hero ?? AnyView(EmptyView()))
            return cell
        }

        if itemID == addItemID {
            return collectionView.dequeueReusableCell(
                withReuseIdentifier: PhotoGridAddCell.reuseID, for: indexPath)
        }

        if itemID.hasPrefix(padItemPrefix) {
            return collectionView.dequeueReusableCell(
                withReuseIdentifier: PhotoGridPadCell.reuseID, for: indexPath)
        }

        let cell = collectionView.dequeueReusableCell(
            withReuseIdentifier: PhotoGridCell.reuseID, for: indexPath)
        guard let photoCell = cell as? PhotoGridCell, let asset = assetsByID[itemID]
        else { return cell }

        photoCell.configure(with: asset, loader: loader)
        photoCell.contentView.isHidden = (itemID == hiddenZoomID)
        photoCell.setSelectionState(
            showsSelection: collectionView.isEditing,
            isPicked: collectionView.indexPathsForSelectedItems?.contains(indexPath) ?? false)
        return photoCell
    }

    // MARK: - Data

    func apply(
        sections newSections: [TimelineSection],
        configuration newConfiguration: PhotoGridConfiguration,
        hero newHero: AnyView?
    ) {
        // Sampulnya SwiftUI dan boleh berubah tiap frame (animasi zoom lambat di
        // dalamnya); yang penting hanya sel hosting-nya membaca nilai terbaru.
        hero = newHero
        if let hostCell = heroCell() {
            hostCell.host(newHero ?? AnyView(EmptyView()))
        }

        let configurationChanged = configuration != newConfiguration
        configuration = newConfiguration
        if isViewLoaded, appliedConfiguration != newConfiguration {
            collectionView.setCollectionViewLayout(makeLayout(), animated: false)
            applyContentInsets()
        }

        // Isi yang sama tidak perlu diterapkan ulang: snapshot diffable pun tetap
        // membandingkan seluruh identitas, dan pada puluhan ribu item itu bukan
        // pekerjaan gratis.
        guard configurationChanged || !isSameContent(as: newSections) else { return }

        // Model turunannya dibangun ke variabel LOKAL, bukan langsung ke properti.
        //
        // Snapshot-nya bisa ditahan sampai gulirannya berhenti, dan selama
        // penahanan itu yang tergambar masih daftar yang lama. Kalau modelnya
        // sudah terlanjur diganti, keduanya tidak sejalan: sel yang masih tampil
        // tidak lagi punya asetnya, jadi petaknya berubah jadi kotak abu-abu dan
        // ketukan di atasnya tidak melakukan apa-apa. Keduanya dipasang bersama
        // di `flushPendingSnapshot`.
        let assetCount = newSections.reduce(0) { $0 + $1.assets.count }
        var assetsByID: [String: AssetLite] = [:]
        assetsByID.reserveCapacity(assetCount)
        var sectionTitles: [SectionID: String] = [:]
        var flatPadCount = 0

        var snapshot = NSDiffableDataSourceSnapshot<SectionID, String>()

        // Kedua syaratnya harus sejalan dengan `makeLayout`, yang memberi tinggi
        // sampul hanya pada section pertama dan hanya kalau tingginya > 0.
        if newHero != nil, configuration.heroHeight > 0 {
            snapshot.appendSections([.hero])
            snapshot.appendItems([heroItemID], toSection: .hero)
        }

        var lastSectionID: SectionID?

        if configuration.showsSectionHeaders {
            for section in newSections {
                let id = SectionID.month(section.id)
                sectionTitles[id] = section.title
                snapshot.appendSections([id])
                snapshot.appendItems(section.assets.map(\.id), toSection: id)
                for asset in section.assets { assetsByID[asset.id] = asset }
                lastSectionID = id
            }
        } else if !newSections.isEmpty {
            let id = SectionID.month(flatSectionID)
            snapshot.appendSections([id])

            // Petak kosong perata, kalau diminta: sisanya ditaruh di depan supaya
            // baris TERAKHIR selalu genap.
            let columns = max(configuration.columns, 1)
            let remainder = assetCount % columns
            flatPadCount = configuration.padsFirstRow && remainder != 0
                ? columns - remainder
                : 0

            var itemIDs: [String] = []
            itemIDs.reserveCapacity(assetCount + flatPadCount)
            for index in 0..<flatPadCount {
                itemIDs.append("\(padItemPrefix)\(index)__")
            }
            for section in newSections {
                for asset in section.assets {
                    itemIDs.append(asset.id)
                    assetsByID[asset.id] = asset
                }
            }
            snapshot.appendItems(itemIDs, toSection: id)
            lastSectionID = id
        }

        // Petak "+" menutup baris terakhir, bukan berdiri sendiri di baris baru —
        // karena itu ia ikut ke section terakhir, bukan jadi section sendiri.
        if configuration.showsAddTile, let lastSectionID {
            snapshot.appendItems([addItemID], toSection: lastSectionID)
        }

        pending = PendingContent(
            sections: newSections,
            assetsByID: assetsByID,
            sectionTitles: sectionTitles,
            flatPadCount: flatPadCount,
            snapshot: snapshot)
        flushPendingSnapshot()
    }

    private func heroCell() -> PhotoGridHostCell? {
        guard isViewLoaded, let indexPath = dataSource?.indexPath(for: heroItemID)
        else { return nil }
        return collectionView.cellForItem(at: indexPath) as? PhotoGridHostCell
    }

    private func flushPendingSnapshot() {
        guard isViewLoaded, let pending else { return }

        // Grid TIDAK disusun ulang selagi jari masih menggulir atau lemparannya
        // masih meluncur.
        //
        // Memasang snapshot berarti mengembalikan posisi gulir dengan
        // `setContentOffset`, dan itu MEMATIKAN momentum seketika — gerakannya
        // berhenti mendadak di tengah lemparan. Snapshot-nya ditahan; ia dipasang
        // begitu gulirannya berhenti sendiri, saat tidak ada gerakan yang bisa
        // diputus. Ini yang membuat pembuangan aset mati tidak lagi terasa
        // menyentak.
        //
        // Terbang ke foto terbaru termasuk di dalamnya. `apply` untuk puluhan
        // ribu item adalah kerja main thread yang panjang; menjalankannya di
        // tengah animasi menghasilkan gerakan yang macet lalu lanjut lagi.
        guard !isScrolling else { return }

        self.pending = nil
        sections = pending.sections
        assetsByID = pending.assetsByID
        sectionTitles = pending.sectionTitles
        flatPadCount = pending.flatPadCount

        // Posisi yang sedang dilihat, DICATAT SEBELUM snapshot dipasang.
        //
        // Setelahnya posisi gulirnya sudah telanjur pulang ke puncak, dan tidak
        // ada lagi cara mengetahui pengguna tadi sedang di mana. Tanpa ini,
        // setiap sync yang datang saat pengguna sedang menyusuri foto lama
        // melemparkannya kembali ke awal.
        let animates = shouldAnimate(pending.snapshot)

        // Penambatan foto tertentu hanya untuk pemasangan tanpa animasi.
        // Pembaruan beranimasi menjaga posisi lama, tetapi kalau layar memang
        // masih berjangkar ke newest, posisi lama itu justru harus digeser ke
        // dasar baru setelah aset auto-backup disisipkan.
        let anchor = animates ? nil : currentAnchor()

        // SESUDAH jangkarnya dicatat, sebelum snapshotnya dipasang.
        //
        // Urutannya menentukan. `currentAnchor` membaca atribut tata letak untuk
        // mengetahui foto mana yang sedang di puncak layar; melakukan invalidasi
        // lebih dulu berarti ia mengukur geometri yang sudah dihitung ulang dari
        // daftar BARU sementara collection view masih memegang jumlah item lama
        // — jangkarnya jadi menunjuk tempat yang salah, dan setiap paginasi
        // terasa menyentak.
        refreshJustifiedLayoutIfNeeded()

        var snapshot = pending.snapshot
        reconfigureChangedItems(in: &snapshot)

        contentRevision &+= 1
        let revision = contentRevision
        applyingSnapshotRevision = revision
        dataSource.apply(snapshot, animatingDifferences: animates) { [weak self] in
            guard let self else { return }
            guard self.contentRevision == revision else { return }
            self.applyingSnapshotRevision = nil
            self.refreshVisibleHeaders()
            if let anchor {
                self.restorePosition(anchor)
            } else if self.isAnchoredToNewest {
                // Jalur inilah yang hilang: diff kecil dari auto-backup memakai
                // animasi, `anchor` nil, lalu completion lama langsung pulang.
                // Hasilnya baris baru ada di bawah tetapi belum terlihat sampai
                // pengguna menggeser grid sendiri.
                _ = self.scrollToNewestIfNeeded()
            }
        }
    }

    private func refreshVisibleHeaders() {
        let kind = UICollectionView.elementKindSectionHeader
        for path in collectionView.indexPathsForVisibleSupplementaryElements(ofKind: kind) {
            guard let sectionID = dataSource.sectionIdentifier(for: path.section),
                  let header = collectionView.supplementaryView(forElementKind: kind, at: path) as? PhotoGridHeaderView
            else { continue }
            header.configure(title: sectionTitles[sectionID] ?? "")
        }
    }

    /// Menandai petak yang ID-nya SAMA tapi isinya berubah.
    ///
    /// Item snapshot di sini berupa `String` id, dan diffable data source hanya
    /// menggambar ulang sel kalau identifier-nya berbeda. Foto yang baru selesai
    /// diunggah tetap foto yang sama dengan id yang sama — yang berubah cuma
    /// lencananya, dari "belum aman" jadi "ada di keduanya". Tanpa penandaan ini
    /// perubahan itu tidak pernah sampai ke layar: selnya tidak dianggap perlu
    /// digambar ulang, dan lencana lama bertahan sampai grid-nya dibangun ulang
    /// dari nol.
    ///
    /// Berlaku sama untuk favorit, durasi, dan apa pun yang hidup di dalam sel
    /// tanpa mengubah identitas fotonya.
    private func reconfigureChangedItems(
        in snapshot: inout NSDiffableDataSourceSnapshot<SectionID, String>
    ) {
        let current = sections.flatMap(\.assets)
        defer { renderedAssets = Dictionary(current.map { ($0.id, $0) },
                                            uniquingKeysWith: { first, _ in first }) }

        // Pemasangan pertama tidak punya pembanding, dan seluruh selnya memang
        // baru digambar — tidak ada yang perlu ditandai.
        guard !renderedAssets.isEmpty else { return }

        let existing = Set(snapshot.itemIdentifiers)
        let changed = current.compactMap { asset -> String? in
            guard existing.contains(asset.id),
                  let previous = renderedAssets[asset.id],
                  !previous.hasSameContent(as: asset)
            else { return nil }
            return asset.id
        }
        guard !changed.isEmpty else { return }
        snapshot.reconfigureItems(changed)
    }

    /// Meminta halaman berikutnya kalau yang tersentuh sudah dekat ujung.
    ///
    /// Ambangnya sebaris penuh, bukan satu item: pada grid berkolom banyak,
    /// "item terakhir" tersentuh hampir bersamaan dengan beberapa tetangganya,
    /// dan menunggu tepat yang paling akhir berarti permintaannya terlambat
    /// selebar satu baris.
    fileprivate func requestNextPageIfNeeded(_ indexPaths: [IndexPath]) {
        guard let onReachEnd,
              let deepest = indexPaths.max(by: { ($0.section, $0.item) < ($1.section, $1.item) }),
              deepest.section == collectionView.numberOfSections - 1
        else { return }

        let total = collectionView.numberOfItems(inSection: deepest.section)
        guard total > 0, deepest.item >= total - max(configuration.columns, 1) * 3 else { return }
        onReachEnd()
    }

    /// Mengisi kotak isi milik layout justified, lalu meminta ukur ulang.
    ///
    /// Tata letak persegi tidak butuh ini: lebar petaknya hanya bergantung pada
    /// jumlah kolom, jadi layoutnya tetap benar berapa pun fotonya. Yang
    /// justified berubah SETIAP kali daftarnya berubah — satu foto tegak yang
    /// masuk menggeser seluruh baris sesudahnya.
    private func refreshJustifiedLayoutIfNeeded() {
        guard configuration.layoutStyle == .justified else { return }
        justifiedStore.assets = sections.flatMap(\.assets)
        collectionView.collectionViewLayout.invalidateLayout()
    }

    /// Perubahan KECIL dianimasikan; perubahan besar tidak.
    ///
    /// Menghapus foto, mengarsipkan, atau satu foto baru datang — itu beberapa
    /// petak, dan merapikannya dengan animasi persis yang membuat grid terasa
    /// hidup. Sedangkan sync pertama, ganti jumlah kolom, atau pembuangan massal
    /// mengubah puluhan ribu petak sekaligus: menganimasikannya berarti
    /// puluhan ribu sel dianimasikan berbarengan, dan yang terlihat cuma
    /// tersendat.
    ///
    /// Ambangnya dari selisih JUMLAH, bukan hasil diff sungguhan: diff-nya baru
    /// dihitung `apply` belakangan, dan menghitungnya dua kali hanya membayar
    /// pekerjaan yang sama dua kali.
    private func shouldAnimate(
        _ new: NSDiffableDataSourceSnapshot<SectionID, String>
    ) -> Bool {
        // Tata letak justified TIDAK PERNAH dianimasikan.
        //
        // Batch update beranimasi memindahkan petak dari posisi lamanya ke
        // posisi barunya, dan itu mengandaikan tata letak yang stabil. Di sini
        // satu foto yang hilang mengubah lebar SETIAP petak sesudahnya —
        // barisnya disusun ulang dari awal — jadi yang dianimasikan bukan
        // perapian beberapa petak melainkan seluruh isi grid sekaligus,
        // berbarengan dengan invalidasi layoutnya sendiri.
        guard configuration.layoutStyle != .justified else { return false }

        // Pemasangan pertama tidak punya "sebelum"; menganimasikan kemunculan
        // seluruh isi grid bukan perapian, melainkan tumpahan.
        let old = dataSource.snapshot()
        guard old.numberOfItems > 0 else { return false }

        return abs(old.numberOfItems - new.numberOfItems) <= Self.animatedDiffLimit
    }

    /// Sekitar dua layar penuh pada tiga kolom — cukup untuk seleksi banyak yang
    /// masuk akal, jauh di bawah perubahan yang berasal dari sync.
    private static let animatedDiffLimit = 60

    /// Beberapa foto teratas yang terlihat, masing-masing dengan jaraknya dari
    /// tepi atas layar.
    ///
    /// Jaraknya ikut dicatat, bukan hanya id-nya. Menambatkan dengan
    /// `scrollToItem(at: .top)` memaksa foto acuan menempel PERSIS di tepi atas,
    /// padahal tadi ia biasanya tergulir sebagian — dan selisih itu, sampai
    /// setinggi satu baris, terlihat sebagai sentakan setiap kali daftarnya
    /// berubah.
    ///
    /// Beberapa calon, bukan satu, karena foto acuannya sendiri bisa termasuk
    /// yang dibuang — dan itu justru kejadian yang paling sering: aset yang tidak
    /// bisa dibaca dihapus tepat saat barisnya sedang dilihat.
    private struct ScrollAnchor {
        let candidates: [(id: String, offsetFromTop: CGFloat)]
    }

    private func currentAnchor() -> ScrollAnchor? {
        let visible = collectionView.indexPathsForVisibleItems.sorted()
        guard !visible.isEmpty else { return nil }

        let top = collectionView.contentOffset.y
        let candidates: [(id: String, offsetFromTop: CGFloat)] = visible.compactMap { path in
            guard let id = dataSource.itemIdentifier(for: path),
                  let attributes = collectionView.layoutAttributesForItem(at: path)
            else { return nil }
            return (id, attributes.frame.minY - top)
        }

        return candidates.isEmpty ? nil : ScrollAnchor(candidates: candidates)
    }

    private func restorePosition(_ anchor: ScrollAnchor?) {
        if scrollToNewestIfNeeded() { return }
        guard let anchor else { return }

        // Tata letaknya dituntut sudah pasti dulu. Tanpa ini `contentSize` bisa
        // masih nilai lama — atau nol — dan penjepitnya runtuh jadi "pulang ke
        // puncak", persis sentakan yang sedang dihindari.
        collectionView.layoutIfNeeded()

        for candidate in anchor.candidates {
            guard let path = dataSource.indexPath(for: candidate.id),
                  let attributes = collectionView.layoutAttributesForItem(at: path)
            else { continue }

            // Foto acuan dikembalikan ke tempatnya yang PERSIS sama di layar,
            // bukan ke tepi atas.
            let lowest = -collectionView.adjustedContentInset.top
            let target = min(
                max(attributes.frame.minY - candidate.offsetFromTop, lowest),
                maxContentOffsetY())

            collectionView.setContentOffset(CGPoint(x: 0, y: target), animated: false)
            return
        }
    }

    private func isSameContent(as other: [TimelineSection]) -> Bool {
        (pending?.sections ?? sections).elementsEqual(other) { lhs, rhs in
            lhs.id == rhs.id && lhs.title == rhs.title
                && lhs.count == rhs.count && lhs.startIndex == rhs.startIndex
                && lhs.assets.elementsEqual(rhs.assets) { $0.hasSameContent(as: $1) }
        }
    }

    // MARK: - Posisi

    /// Foto terbaru ada di paling bawah, jadi di situlah tampilan dibuka.
    ///
    /// `scrollToItem` bekerja dari tata letak yang sudah pasti — tidak seperti
    /// "gulir ke tepi bawah" di SwiftUI, yang bergantung pada tinggi konten yang
    /// baru sebagian terukur dan karena itu mendarat di tempat acak.
    /// - Returns: true kalau tampilannya benar-benar dipindahkan ke foto terbaru.
    @discardableResult
    private func scrollToNewestIfNeeded() -> Bool {
        // Menuntut tinggi yang sudah nyata: menggulir di dalam kotak setinggi nol
        // tidak memindahkan apa pun, dan data hampir selalu sampai sebelum SwiftUI
        // memberi view ini ukuran. Karena jangkarnya bertahan, `viewDidLayoutSubviews`
        // akan mencoba lagi begitu ukurannya ada.
        // `!isReturningToNewest` WAJIB ada di sini.
        //
        // `scrollToNewest` memasang jangkarnya di awal terbang, dan setiap
        // layout pass selama itu — muat ulang yang dipicu ketukan tab yang sama,
        // rotasi, perubahan safe area — akan sampai ke sini dan melompat keras
        // ke dasar, memotong animasinya di tengah jalan.
        guard configuration.startsAtNewest, isAnchoredToNewest, !isReturningToNewest,
              isViewLoaded, collectionView.bounds.height > 0,
              lastItemIndexPath() != nil
        else { return false }

        pinToNewestOffset()
        scheduleInitialNewestRevealIfNeeded()
        return true
    }

    /// Menentukan kapan snapshot pembuka boleh terlihat.
    ///
    /// Satu `layoutIfNeeded` belum cukup: diffable data source dapat selesai,
    /// kemudian safe-area/tab bar mengubah tinggi efektif pada run loop
    /// berikutnya. Karena itu posisi dan ukuran diverifikasi dua kali. Snapshot
    /// baru membatalkan verifikasi lama lewat `contentRevision`.
    private func scheduleInitialNewestRevealIfNeeded() {
        guard isWaitingForInitialNewestPosition, initialContentReady,
              pending == nil, applyingSnapshotRevision == nil
        else { return }

        let revision = contentRevision
        DispatchQueue.main.async { [weak self] in
            guard let self,
                  self.isWaitingForInitialNewestPosition,
                  self.initialContentReady,
                  self.contentRevision == revision,
                  self.pending == nil,
                  self.applyingSnapshotRevision == nil
            else { return }

            self.pinToNewestOffset()
            let stableContentSize = self.collectionView.contentSize

            DispatchQueue.main.async { [weak self] in
                guard let self,
                      self.isWaitingForInitialNewestPosition,
                      self.initialContentReady,
                      self.contentRevision == revision,
                      self.pending == nil,
                      self.applyingSnapshotRevision == nil
                else { return }

                self.collectionView.layoutIfNeeded()
                let destination = self.maxContentOffsetY()
                let isAtNewest = abs(self.collectionView.contentOffset.y - destination) < 1.5
                guard self.collectionView.contentSize == stableContentSize, isAtNewest
                else {
                    _ = self.scrollToNewestIfNeeded()
                    return
                }

                self.isWaitingForInitialNewestPosition = false
                UIView.performWithoutAnimation {
                    self.collectionView.alpha = 1
                }
                self.onInitialContentDisplayed?()
            }
        }
    }

    /// Dipanggil representable setiap pembaruan. Ketika gerbang dibuka,
    /// snapshot yang saat itu sedang dipasang tetap harus selesai lebih dulu;
    /// completion `flushPendingSnapshot` akan mencoba lagi.
    func setInitialContentReady(_ isReady: Bool) {
        initialContentReady = isReady
        guard isReady else { return }
        DispatchQueue.main.async { [weak self] in
            _ = self?.scrollToNewestIfNeeded()
        }
    }

    /// Menetapkan offset maksimum secara eksplisit. `scrollToItem(.bottom)`
    /// dapat memakai inset lama ketika tab bar baru muncul, sehingga item
    /// terakhir memang terpilih tetapi sebagian barisnya masih tenggelam.
    private func pinToNewestOffset() {
        collectionView.layoutIfNeeded()
        collectionView.setContentOffset(
            CGPoint(x: 0, y: maxContentOffsetY()),
            animated: false)
    }

    /// Aset terdekat dengan tengah area foto yang benar-benar terlihat.
    /// Membaca posisi saat ini tanpa mengubah offset atau jangkar terbaru.
    func visibleAssetForTimelineNavigation() -> AssetLite? {
        guard isViewLoaded, let dataSource else { return nil }

        let visible = collectionView.bounds.inset(by: collectionView.adjustedContentInset)
        guard visible.width > 0, visible.height > 0 else { return nil }

        var nearestAsset: AssetLite?
        var nearestDistance = CGFloat.greatestFiniteMagnitude
        for path in collectionView.indexPathsForVisibleItems.sorted() {
            guard let id = dataSource.itemIdentifier(for: path),
                  let asset = assetsByID[id],
                  let attributes = collectionView.layoutAttributesForItem(at: path),
                  attributes.frame.intersects(visible)
            else { continue }

            let dx = attributes.frame.midX - visible.midX
            let dy = attributes.frame.midY - visible.midY
            let distance = dx * dx + dy * dy
            if distance < nearestDistance {
                nearestDistance = distance
                nearestAsset = asset
            }
        }
        return nearestAsset
    }

    /// Melompat langsung ke sebuah aset tanpa melewati setiap thumbnail di
    /// antaranya. Dipakai kartu Months dan Years untuk membuka foto pertama
    /// periodenya di mode All.
    @discardableResult
    func scrollToAsset(id: String, animated: Bool) -> Bool {
        guard isViewLoaded else { return false }

        // Hentikan deselerasi/animasi lama sebelum membaca index path. Snapshot
        // yang tertahan selama gulir juga harus dipasang lebih dulu agar tujuan
        // dicari pada daftar terbaru.
        collectionView.setContentOffset(collectionView.contentOffset, animated: false)
        endReturnLink()
        finishReturningToNewest(settle: false)
        isScrolling = false
        flushPendingSnapshot()

        guard let path = dataSource?.indexPath(for: id) else { return false }

        isAnchoredToNewest = false
        lastReportedSection = nil
        collectionView.layoutIfNeeded()

        guard let attributes = collectionView.layoutAttributesForItem(at: path)
        else { return false }

        let lowest = -collectionView.adjustedContentInset.top
        let destination = min(
            max(attributes.frame.minY - collectionView.adjustedContentInset.top, lowest),
            maxContentOffsetY())

        isScrolling = animated
        collectionView.setContentOffset(
            CGPoint(x: collectionView.contentOffset.x, y: destination),
            animated: animated)
        if !animated { settleScrolling() }
        return true
    }

    /// Ketukan kedua pada tab: kembali ke foto terbaru sekaligus memasang lagi
    /// jangkarnya, supaya muat ulang yang menyusul tidak menariknya ke atas.
    func scrollToNewest(animated: Bool) {
        guard isViewLoaded else {
            isAnchoredToNewest = true
            return
        }

        // Isi yang masih tertahan dipasang DULU, dan sebelum jangkarnya dipasang.
        //
        // Selama menggulir snapshot ditahan, jadi sync yang selesai di sela itu
        // belum terpasang — dan terbang yang berangkat sekarang akan menuju dasar
        // yang sudah kedaluwarsa. Urutannya penting: kalau jangkarnya sudah
        // menyala, pemulihan posisi di dalam `flush` akan melompat ke dasar dan
        // terbangnya tidak pernah sempat terlihat.
        isScrolling = false
        flushPendingSnapshot()

        isAnchoredToNewest = true
        guard lastItemIndexPath() != nil else { return }
        guard animated else {
            pinToNewestOffset()
            // Gulir tanpa animasi MEMOTONG lemparan yang masih meluncur, dan
            // UIKit tidak mengirim callback akhir-gulir untuk pemotongan itu.
            // Tanpa baris ini, menekan ulang tab di tengah lemparan meninggalkan
            // penandanya menyala dan grid berhenti diperbarui.
            settleScrolling()
            return
        }

        // Penahanan dipasang lebih dulu: snapshot yang datang di tengah animasi
        // akan memanggil `setContentOffset` dan memotong gerakannya.
        isScrolling = true
        isReturningToNewest = true
        // Puluhan layar penuh sel akan dibangun dan dibuang selama terbang;
        // tidak satu pun perlu mengunduh apa-apa.
        loader.isSuspended = true

        // Lemparan yang masih meluncur DIHENTIKAN dulu.
        //
        // Ketukan tab hampir selalu datang selagi gridnya masih meluncur dari
        // usapan terakhir. Deselerasi UIScrollView tidak peduli pada animasi
        // kita — ia terus berjalan dan menang, jadi yang terlihat justru
        // meluncur terus ke arah usapan tadi (ke foto lama), dan baru ketukan
        // KEDUA yang benar-benar turun karena waktu itu sudah tidak ada
        // deselerasi yang tersisa. Itulah "ketukan pertama malah ke atas".
        //
        // Menyetel offset ke nilainya sendiri adalah cara bawaan menghentikan
        // deselerasi seketika, tanpa memindahkan apa pun. Callback akhir-gulir
        // yang mungkin ikut terpicu ditahan `isReturningToNewest`.
        collectionView.setContentOffset(collectionView.contentOffset, animated: false)

        // TANPA lompatan pendekat. Seluruh jaraknya benar-benar ditempuh.
        //
        // Versi sebelumnya melompat ke satu setengah layar dari tujuan lalu
        // menganimasikan sisanya. Itu murah, tapi yang terlihat bukan gulir
        // melainkan POTONGAN: isinya hilang, lalu tiba-tiba sudah hampir di
        // ujung. Photos milik Apple tidak melompat sedikit pun — dan seluruh
        // isinya benar-benar lewat di depan mata. Ongkosnya dibayar dengan
        // menghentikan permintaan thumbnail selama terbang, bukan dengan
        // memotong jaraknya.
        collectionView.layoutIfNeeded()
        returnFrom = collectionView.contentOffset.y
        returnStartedAt = CACurrentMediaTime()

        endReturnLink()
        let link = CADisplayLink(target: self, selector: #selector(stepReturnToNewest))
        link.add(to: .main, forMode: .common)
        returnLink = link
    }

    @objc private func stepReturnToNewest() {
        let elapsed = CACurrentMediaTime() - returnStartedAt
        let progress = min(1, elapsed / Self.returnDuration)

        // Tujuannya dihitung ULANG tiap frame — murah, dan menjaga pendaratan
        // tetap tepat kalau tinggi kontennya sempat diukur ulang.
        let destination = maxContentOffsetY()
        let eased = CGFloat(Self.returnCurve.value(for: progress))
        collectionView.contentOffset = CGPoint(
            x: 0, y: returnFrom + (destination - returnFrom) * eased)

        guard progress >= 1 else { return }
        endReturnLink()
        finishReturningToNewest()
    }

    private func endReturnLink() {
        // WAJIB: `CADisplayLink` memegang target-nya KUAT. Tanpa `invalidate`,
        // controller ini tidak pernah dilepas.
        returnLink?.invalidate()
        returnLink = nil
    }

    /// Membereskan keadaan setelah terbang, entah sampai tujuan atau dipotong
    /// jari pengguna.
    ///
    /// - Parameter settle: false saat dipotong jari — pelepasan penahanan
    ///   diserahkan ke callback akhir-gulir. Dilepas di sini, `isScrolling` mati
    ///   selagi jari masih menempel dan snapshot berikutnya memotong seretan
    ///   yang baru saja dimulai.
    private func finishReturningToNewest(settle: Bool = true) {
        guard isReturningToNewest else { return }
        isReturningToNewest = false
        loader.isSuspended = false
        // Sel yang mendarat di layar dibangun saat pemuatan masih dihentikan,
        // jadi sebagian belum punya gambar. Sekarang barulah mereka boleh
        // memintanya.
        reloadVisibleThumbnails()

        guard settle, !collectionView.isDragging, !collectionView.isDecelerating
        else { return }
        settleScrolling()
    }

    private func reloadVisibleThumbnails() {
        for indexPath in collectionView.indexPathsForVisibleItems {
            guard let itemID = dataSource.itemIdentifier(for: indexPath),
                  let asset = assetsByID[itemID],
                  let cell = collectionView.cellForItem(at: indexPath) as? PhotoGridCell
            else { continue }
            cell.configure(with: asset, loader: loader)
        }
    }

    /// Posisi gulir paling bawah yang sah.
    private func maxContentOffsetY() -> CGFloat {
        let inset = collectionView.adjustedContentInset
        let lowest = -inset.top
        return max(
            lowest,
            collectionView.contentSize.height + inset.bottom - collectionView.bounds.height)
    }

    // MARK: - Membuka layar detail

    /// Membuka foto lewat presentasi UIKit, supaya transisinya bisa berangkat
    /// dari sel yang sebenarnya.
    private func presentDetail(for id: String) {
        onOpen?(id)
        guard let makeDetail else { return }

        let detail = makeDetail(id)
        // `.overFullScreen`, BUKAN `.fullScreen`.
        //
        // `.fullScreen` melepas view di belakangnya begitu presentasi selesai,
        // jadi saat menutup tidak ada apa pun untuk dituju — yang terlihat cuma
        // layar hitam sampai UIKit memasangnya kembali.
        detail.modalPresentationStyle = .overFullScreen

        let transition = PhotoZoomTransitioningDelegate(
            source: self,
            assetID: id,
            aspectRatio: CGFloat(assetsByID[id]?.ratio ?? 1))
        detail.transitioningDelegate = transition
        zoomTransition = transition

        present(detail, animated: true)

        // Dipasang SETELAH present: `detail.view` baru punya window setelah itu,
        // dan gestur ini mengangkat fotonya ke window saat jari mulai menarik.
        dismissGesture = PhotoZoomDismissGesture(
            presented: detail,
            source: self,
            assetID: { [weak transition] in transition?.assetID ?? id })
    }

    /// Dipanggil layar detail saat foto yang tampil berganti karena diusap.
    ///
    /// Tanpa ini, menutupnya selalu mengecil kembali ke foto yang PERTAMA dibuka.
    func detailDidChangeAsset(to id: String) {
        zoomTransition?.assetID = id
        // Grid menyusul SEKARANG, bukan nanti saat transisi menutup dimulai.
        //
        // Kalau penggulirannya baru terjadi di detik penutupan, gridnya melompat
        // di belakang latar yang sedang memudar — dan lompatan itu terlihat jelas
        // selama tarik-untuk-menutup, karena gridnya sudah tersingkap.
        revealCell(for: id)
        // Rasionya ikut, bukan cuma id-nya: kotak cadangan saat layar detail
        // belum terukur dihitung dari rasio, dan memakai rasio foto lama berarti
        // mendarat di kotak yang salah bentuk.
        zoomTransition?.aspectRatio = CGFloat(assetsByID[id]?.ratio ?? 1)
    }

    private func lastItemIndexPath() -> IndexPath? {
        let lastSection = collectionView.numberOfSections - 1
        guard lastSection >= 0 else { return nil }
        let lastItem = collectionView.numberOfItems(inSection: lastSection) - 1
        guard lastItem >= 0 else { return nil }
        return IndexPath(item: lastItem, section: lastSection)
    }

    // MARK: - Seleksi

    func setSelecting(_ selecting: Bool) {
        guard isViewLoaded, collectionView.isEditing != selecting else { return }
        collectionView.isEditing = selecting

        if !selecting {
            collectionView.indexPathsForSelectedItems?.forEach {
                collectionView.deselectItem(at: $0, animated: false)
            }
        }
        refreshVisibleSelectionState()
    }

    func setSelection(_ ids: Set<String>) {
        guard isViewLoaded, collectionView.isEditing else { return }

        let current = Set((collectionView.indexPathsForSelectedItems ?? [])
            .compactMap { dataSource.itemIdentifier(for: $0) })
        guard current != ids else { return }

        for id in current.subtracting(ids) {
            if let path = dataSource.indexPath(for: id) {
                collectionView.deselectItem(at: path, animated: false)
            }
        }
        for id in ids.subtracting(current) {
            if let path = dataSource.indexPath(for: id) {
                collectionView.selectItem(at: path, animated: false, scrollPosition: [])
            }
        }
        refreshVisibleSelectionState()
    }

    private func refreshVisibleSelectionState() {
        let selected = Set(collectionView.indexPathsForSelectedItems ?? [])
        for path in collectionView.indexPathsForVisibleItems {
            guard let cell = collectionView.cellForItem(at: path) as? PhotoGridCell
            else { continue }
            cell.setSelectionState(
                showsSelection: collectionView.isEditing,
                isPicked: selected.contains(path))
        }
    }

    private func reportSelection() {
        let ids = Set((collectionView.indexPathsForSelectedItems ?? [])
            .compactMap { dataSource.itemIdentifier(for: $0) }
            .filter { assetsByID[$0] != nil })
        onSelectionChanged?(ids)
    }
}

// MARK: - Sumber transisi zoom

extension PhotoGridController: PhotoZoomTransitionSource {
    /// Gambar dan kotak sel, dalam koordinat window.
    ///
    /// Grid ikut digulir kalau selnya sedang di luar layar — kalau tidak, foto
    /// yang ditutup tidak punya tempat untuk pulang.
    func zoomSource(for id: String) -> (image: UIImage?, frame: CGRect)? {
        guard let path = revealCell(for: id),
              let attributes = collectionView.layoutAttributesForItem(at: path)
        else { return nil }

        let frame = collectionView.convert(attributes.frame, to: nil)
        let cell = collectionView.cellForItem(at: path) as? PhotoGridCell
        let image = cell?.displayedImage ?? loader.cachedImage(for: id)
        return (image, frame)
    }

    /// Memastikan sel sebuah foto benar-benar terlihat, menggulirkan grid kalau
    /// perlu.
    ///
    /// Syaratnya "sel muat UTUH di kotak yang terlihat", bukan "terdaftar sebagai
    /// visible". `indexPathsForVisibleItems` ikut memuat sel yang cuma tersenggol
    /// tepi layar — dan yang lebih penting, ia tidak tahu apa-apa soal sel yang
    /// memang jauh di luar.
    @discardableResult
    func revealCell(for id: String) -> IndexPath? {
        guard isViewLoaded, let path = dataSource?.indexPath(for: id),
              let attributes = collectionView.layoutAttributesForItem(at: path)
        else { return nil }

        let visible = collectionView.bounds.inset(by: collectionView.adjustedContentInset)
        guard !visible.contains(attributes.frame) else { return path }

        // Posisi grid sekarang ditentukan oleh foto yang dilihat, jadi jangkar
        // "buka di foto terbaru" harus dilepas — kalau tidak, layout pass
        // berikutnya menariknya kembali ke dasar.
        isAnchoredToNewest = false
        collectionView.scrollToItem(at: path, at: .centeredVertically, animated: false)
        collectionView.layoutIfNeeded()
        return path
    }

    func setZoomSourceHidden(_ hidden: Bool, for id: String) {
        hiddenZoomID = hidden ? id : nil
        guard let path = dataSource?.indexPath(for: id),
              let cell = collectionView.cellForItem(at: path)
        else { return }
        cell.contentView.isHidden = hidden
    }
}

// MARK: - Delegate

extension PhotoGridController: UICollectionViewDelegate {
    /// Sampul bukan sesuatu yang bisa dipilih, dan mengizinkannya berarti ia ikut
    /// tersorot saat "Select All".
    func collectionView(
        _ collectionView: UICollectionView,
        shouldSelectItemAt indexPath: IndexPath
    ) -> Bool {
        guard let id = dataSource.itemIdentifier(for: indexPath) else { return false }
        return id != heroItemID && !id.hasPrefix(padItemPrefix)
    }

    func collectionView(
        _ collectionView: UICollectionView,
        didSelectItemAt indexPath: IndexPath
    ) {
        guard let id = dataSource.itemIdentifier(for: indexPath) else { return }

        if id == addItemID {
            collectionView.deselectItem(at: indexPath, animated: false)
            onAddTapped?()
            return
        }

        guard assetsByID[id] != nil else {
            collectionView.deselectItem(at: indexPath, animated: false)
            return
        }

        guard collectionView.isEditing else {
            collectionView.deselectItem(at: indexPath, animated: false)
            presentDetail(for: id)
            return
        }

        (collectionView.cellForItem(at: indexPath) as? PhotoGridCell)?
            .setSelectionState(showsSelection: true, isPicked: true)
        reportSelection()
    }

    func collectionView(
        _ collectionView: UICollectionView,
        didDeselectItemAt indexPath: IndexPath
    ) {
        guard collectionView.isEditing else { return }
        (collectionView.cellForItem(at: indexPath) as? PhotoGridCell)?
            .setSelectionState(showsSelection: true, isPicked: false)
        reportSelection()
    }

    /// Seret dua jari untuk memilih rentang — bawaan UIKit, tanpa recognizer
    /// kustom, tanpa auto-scroll buatan sendiri.
    ///
    /// Diizinkan juga saat BELUM memilih: di Photos, seretan itulah yang memulai
    /// mode pilih. Tekan-lama satu jari tetap milik context menu, jadi keduanya
    /// tidak berebut.
    func collectionView(
        _ collectionView: UICollectionView,
        shouldBeginMultipleSelectionInteractionAt indexPath: IndexPath
    ) -> Bool {
        assetsByID[dataSource.itemIdentifier(for: indexPath) ?? ""] != nil
    }

    func collectionView(
        _ collectionView: UICollectionView,
        didBeginMultipleSelectionInteractionAt indexPath: IndexPath
    ) {
        guard !collectionView.isEditing else { return }
        collectionView.isEditing = true
        onSelectingChanged?(true)
    }

    /// Sentuhan pengguna melepas jangkar — sejak titik ini posisinyalah yang
    /// dipertahankan, bukan dasar linimasa.
    func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
        isAnchoredToNewest = false
        isScrolling = true

        // Jari selalu menang atas animasi. `stopAnimation(true)` meninggalkan
        // posisinya di tempat gerakannya terpotong, jadi seretannya menyambung
        // dari situ alih-alih melompat.
        endReturnLink()
        finishReturningToNewest(settle: false)
    }

    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        guard !decelerate else { return }
        settleScrolling()
    }

    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
        settleScrolling()
    }

    func scrollViewDidEndScrollingAnimation(_ scrollView: UIScrollView) {
        settleScrolling()
    }

    /// Gulirannya berhenti: snapshot yang tertahan boleh dipasang sekarang.
    ///
    /// Diabaikan selama animasi "kembali ke terbaru": menghentikan deselerasi di
    /// awal animasi itu bisa ikut memicu callback akhir-gulir, dan melayaninya
    /// berarti memasang snapshot tepat di tengah gerakan yang baru saja dimulai.
    private func settleScrolling() {
        guard !isReturningToNewest else { return }
        isScrolling = false
        flushPendingSnapshot()
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        updateTitleDock()

        guard onVisibleSectionChanged != nil,
              let first = collectionView.indexPathsForVisibleItems.min(),
              let sectionID = dataSource.sectionIdentifier(for: first.section),
              case .month(let key) = sectionID
        else { return }

        // Grid rata: sectionnya cuma satu, jadi bulannya dicari dari posisi foto
        // teratas yang terlihat.
        guard key != flatSectionID else {
            // Indeks item bergeser sebanyak petak kosong perata di depannya.
            guard let month = month(containing: first.item - flatPadCount),
                  month.id != lastReportedSection
            else { return }
            lastReportedSection = month.id
            onVisibleSectionChanged?(month)
            return
        }

        guard key != lastReportedSection,
              let section = sections.first(where: { $0.id == key })
        else { return }

        lastReportedSection = key
        onVisibleSectionChanged?(section)
    }

    /// Apakah judul sampul sudah tergulir sampai menyentuh toolbar.
    ///
    /// Tepi bawah bar DIBACA dari bar-nya sendiri, bukan dihitung dari safe
    /// area. Inset atas yang diwarisi grid ini belum tentu memuat tinggi
    /// nav bar — di mode sampul grid-nya sengaja menembus ke belakang bar,
    /// sehingga yang diwarisi bisa cuma setinggi status bar. Menebaknya berarti
    /// judulnya sudah lama tenggelam sebelum yang di toolbar muncul.
    ///
    /// `convert(_:from:)` pada scroll view menghasilkan koordinat ISI, jadi
    /// hasilnya langsung sebanding dengan `titleDockContentY` tanpa perlu
    /// menambahkan `contentOffset` lagi.
    private func updateTitleDock() {
        guard isViewLoaded, onTitleDockedChanged != nil,
              titleDockContentY.isFinite
        else { return }

        let barBottom: CGFloat
        if let bar = navigationController?.navigationBar, bar.window != nil {
            barBottom = collectionView.convert(bar.bounds, from: bar).maxY
        } else {
            barBottom = collectionView.contentOffset.y + view.safeAreaInsets.top
        }

        let docked = barBottom >= titleDockContentY
        guard docked != isTitleDocked else { return }

        isTitleDocked = docked

        // Ditunda satu putaran.
        //
        // `apply(...)` berjalan di tengah pembaruan view SwiftUI dan bisa
        // memasang layout baru, dan pemasangan itu memanggil balik
        // `scrollViewDidScroll` seketika. Mengabari langsung dari sana berarti
        // menulis `@State` selagi SwiftUI sedang membangun view — peringatan
        // "modifying state during view update". Satu frame tidak terlihat pada
        // pelarutan 0,22 detik.
        let notify = onTitleDockedChanged
        DispatchQueue.main.async { notify?(docked) }
    }

    /// Bulan yang memuat foto ke-`index` dalam urutan datar.
    ///
    /// Pencarian biner atas `startIndex`, bukan penelusuran: ini dipanggil pada
    /// setiap peristiwa gulir, dan menyusuri ratusan bulan puluhan kali per detik
    /// adalah pekerjaan yang persis ingin dihindari di jalur gulir.
    private func month(containing index: Int) -> TimelineSection? {
        var low = 0
        var high = sections.count - 1
        while low <= high {
            let mid = (low + high) / 2
            let candidate = sections[mid]
            if index < candidate.startIndex {
                high = mid - 1
            } else if index >= candidate.startIndex + candidate.assets.count {
                low = mid + 1
            } else {
                return candidate
            }
        }
        return nil
    }

    // MARK: Context menu

    func collectionView(
        _ collectionView: UICollectionView,
        contextMenuConfigurationForItemsAt indexPaths: [IndexPath],
        point: CGPoint
    ) -> UIContextMenuConfiguration? {
        guard !collectionView.isEditing,
              let indexPath = indexPaths.first,
              let id = dataSource.itemIdentifier(for: indexPath),
              let asset = assetsByID[id],
              let actions = menuActions?(id), !actions.isEmpty
        else { return nil }

        return UIContextMenuConfiguration(
            identifier: id as NSString,
            previewProvider: { [session] in
                // Pratinjau memakai rasio asli foto; sel grid sengaja persegi.
                let host = UIHostingController(
                    rootView: AssetContextPreview(asset: asset, session: session))
                host.preferredContentSize = host.sizeThatFits(
                    in: CGSize(width: 320, height: 460))
                return host
            },
            actionProvider: { _ in
                Self.makeMenu(actions)
            })
    }
}

// MARK: - Perakitan menu

extension PhotoGridController {
    /// Baris aksi di puncak, daftar bertulisan di bawahnya.
    ///
    /// Barisnya sebuah `UIMenu` bersarang ber-`displayInline` — itu yang
    /// membuatnya menyatu dengan menu induknya alih-alih jadi submenu yang
    /// harus dibuka lebih dulu.
    ///
    /// `preferredElementSize` = `.medium`, BUKAN `.small`. Keduanya sama-sama
    /// menyusun aksi berdampingan; bedanya `.small` hanya menggambar ikonnya,
    /// sedangkan `.medium` menaruh judulnya di bawah ikon — bentuk yang sama
    /// dengan baris Copy / Move / Share di Files. Tanpa tulisan, "hati" dan
    /// "kotak arsip" harus ditebak dari gambarnya saja.
    fileprivate static func makeMenu(_ actions: [PhotoGridMenuAction]) -> UIMenu {
        var children: [UIMenuElement] = []

        let quick = actions.filter { $0.group == .quick }.map(makeAction)
        if !quick.isEmpty {
            let row = UIMenu(title: "", options: .displayInline, children: quick)
            row.preferredElementSize = .medium
            children.append(row)
        }

        children.append(contentsOf: actions.filter { $0.group == .list }.map(makeAction))
        return UIMenu(children: children)
    }

    private static func makeAction(_ action: PhotoGridMenuAction) -> UIAction {
        UIAction(
            title: action.title,
            image: UIImage(systemName: action.systemImage),
            attributes: action.isDestructive ? .destructive : []
        ) { _ in action.handler() }
    }
}

// MARK: - Prefetching

extension PhotoGridController: UICollectionViewDataSourcePrefetching {
    func collectionView(
        _ collectionView: UICollectionView,
        prefetchItemsAt indexPaths: [IndexPath]
    ) {
        let ids = indexPaths
            .compactMap { dataSource.itemIdentifier(for: $0) }
            .filter { assetsByID[$0] != nil }
        guard !ids.isEmpty else { return }
        loader.prefetch(ids)

        // Paginasi menumpang di sini, bukan di `willDisplay`.
        //
        // Prefetch memang sudah berjalan MENDAHULUI apa yang terlihat — itu
        // pekerjaannya — jadi ia menyentuh ujung daftar lebih awal daripada sel
        // yang benar-benar tampil. Halaman berikutnya jadi mulai diambil
        // sebelum pengguna sampai ke dasar, dan itu yang membuat gulirnya tidak
        // pernah berhenti menunggu.
        requestNextPageIfNeeded(indexPaths)
    }
}

// MARK: - Sel bukan-foto

/// Sel yang isinya view SwiftUI — dipakai sampul album/Favorites/orang.
final class PhotoGridHostCell: UICollectionViewCell {
    static let reuseID = "PhotoGridHostCell"

    func host(_ view: AnyView) {
        // `ignoresSafeArea` DI SINI, bukan di view yang dititipkan.
        //
        // Sel sampul duduk paling atas di grid yang sengaja menembus sampai ke
        // belakang status bar dan nav bar. UIKit menurunkan safe area jendela ke
        // SETIAP view yang menimpanya — termasuk sel ini — dan
        // `UIHostingConfiguration` menghormatinya: isi SwiftUI-nya digeser
        // sekitar 59pt ke bawah, lalu ujung bawahnya sepanjang itu juga terdorong
        // keluar dari sel dan tertutup baris foto pertama. Yang hilang persis
        // baris paling bawah sampul — jumlah item dan deskripsinya — padahal
        // sampulnya sendiri sudah dipatok setinggi selnya.
        //
        // Sel grid bukan wadah setepi layar; tidak ada alasan ia menyisakan ruang
        // untuk status bar. Aturannya dipasang di sini, bukan di sampulnya,
        // supaya berlaku untuk apa pun yang dititipkan ke sel ini.
        contentConfiguration = UIHostingConfiguration { view.ignoresSafeArea() }
            .margins(.all, 0)
    }
}

// MARK: - Tata letak section

private func heroLayoutSection(
    _ configuration: PhotoGridConfiguration
) -> NSCollectionLayoutSection {
    let size = NSCollectionLayoutSize(
        widthDimension: .fractionalWidth(1),
        heightDimension: .absolute(max(configuration.heroHeight, 1)))
    let item = NSCollectionLayoutItem(layoutSize: size)
    let group = NSCollectionLayoutGroup.horizontal(
        layoutSize: size, repeatingSubitem: item, count: 1)
    return NSCollectionLayoutSection(group: group)
}

/// Tata letak justified: tinggi seragam per baris, lebar mengikuti rasio foto.
///
/// `NSCollectionLayoutGroup.custom` — satu-satunya bentuk group yang menerima
/// frame eksplisit. Yang lain (`horizontal`/`vertical`) menuntut ukuran subitem
/// yang seragam atau pecahan, sedangkan di sini tiap petak punya lebarnya
/// sendiri dan jumlah petak per baris berubah-ubah.
///
/// Perhitungannya dilakukan SEKALI di luar `itemProvider`, bukan di dalamnya:
/// tinggi total group harus sudah diketahui saat `layoutSize` dibentuk,
/// sedangkan tinggi itu baru muncul setelah seluruh barisnya ditata. Lebarnya
/// sama untuk keduanya, jadi menghitung dua kali hanya membuang kerja.
private func justifiedLayoutSection(
    _ configuration: PhotoGridConfiguration,
    _ environment: NSCollectionLayoutEnvironment,
    _ store: JustifiedLayoutStore
) -> NSCollectionLayoutSection {
    let width = environment.container.effectiveContentSize.width
    let rows = JustifiedGrid.layout(
        assets: store.assets,
        containerWidth: width,
        rowHeight: JustifiedGrid.targetHeight(
            containerWidth: width,
            columns: max(configuration.columns, 1),
            spacing: gridSpacing),
        spacing: gridSpacing)

    var frames: [NSCollectionLayoutGroupCustomItem] = []
    frames.reserveCapacity(store.assets.count)
    var y: CGFloat = 0
    for row in rows {
        var x: CGFloat = 0
        for tile in row.tiles {
            frames.append(NSCollectionLayoutGroupCustomItem(
                frame: CGRect(x: x, y: y, width: tile.width, height: row.height)))
            x += tile.width + gridSpacing
        }
        y += row.height + gridSpacing
    }
    // Sela sesudah baris terakhir tidak ikut dihitung; kalau ikut, ada ruang
    // kosong menggantung di dasar yang tidak pernah diminta siapa pun.
    let totalHeight = max(1, y - gridSpacing)

    // Grup TIDAK BOLEH kosong.
    //
    // `flushPendingSnapshot` bisa berjalan dari `viewDidLoad`, sebelum layout
    // pass pertama — dan di situ lebar containernya masih nol, sehingga
    // `JustifiedGrid.layout` mengembalikan daftar kosong. Section yang punya
    // item tapi grupnya tidak punya tempat untuk satu pun dari mereka membuat
    // compositional layout tidak pernah selesai menempatkan apa pun. Jalur
    // persegi tidak pernah kena karena sisi petaknya selalu `max(1, …)`.
    if frames.isEmpty {
        frames = [NSCollectionLayoutGroupCustomItem(
            frame: CGRect(x: 0, y: 0, width: max(width, 1), height: 1))]
    }

    let group = NSCollectionLayoutGroup.custom(
        layoutSize: .init(
            widthDimension: .fractionalWidth(1),
            heightDimension: .absolute(totalHeight))
    ) { _ in frames }

    return NSCollectionLayoutSection(group: group)
}

/// Sisi petak dihitung SENDIRI dari lebar yang tersedia, bukan diserahkan ke
/// pecahan.
///
/// `repeatingSubitem:count:` tidak selalu menimpa ukuran subitem-nya. Dengan
/// subitem `.fractionalWidth(1)`, tiap petak tetap selebar seluruh baris — dan
/// itulah kenapa gridnya tampil satu kolom berapa pun angka di Settings.
///
/// Ukuran absolut tidak punya celah tafsir: n petak plus (n-1) sela harus persis
/// sama dengan lebar container, jadi hasilnya rata penuh sampai kedua tepi.
private func photoLayoutSection(
    _ configuration: PhotoGridConfiguration,
    _ environment: NSCollectionLayoutEnvironment
) -> NSCollectionLayoutSection {
    let columns = max(configuration.columns, 1)
    let available = environment.container.effectiveContentSize.width
    let side = max(
        1, (available - gridSpacing * CGFloat(columns - 1)) / CGFloat(columns))

    let item = NSCollectionLayoutItem(layoutSize: .init(
        widthDimension: .absolute(side),
        heightDimension: .absolute(side)))

    let group = NSCollectionLayoutGroup.horizontal(
        layoutSize: .init(
            widthDimension: .fractionalWidth(1),
            heightDimension: .absolute(side)),
        repeatingSubitem: item,
        count: columns)
    group.interItemSpacing = .fixed(gridSpacing)

    let section = NSCollectionLayoutSection(group: group)
    section.interGroupSpacing = gridSpacing

    guard configuration.showsSectionHeaders else { return section }

    let header = NSCollectionLayoutBoundarySupplementaryItem(
        layoutSize: .init(
            widthDimension: .fractionalWidth(1),
            heightDimension: .absolute(38)),
        elementKind: UICollectionView.elementKindSectionHeader,
        alignment: .top)
    header.pinToVisibleBounds = true
    section.boundarySupplementaryItems = [header]
    return section
}

/// Petak kosong perata baris pertama — tidak menggambar apa pun.
final class PhotoGridPadCell: UICollectionViewCell {
    static let reuseID = "PhotoGridPadCell"
}

/// Petak "+" di ujung baris terakhir, jalan pintas menambah foto ke album.
final class PhotoGridAddCell: UICollectionViewCell {
    static let reuseID = "PhotoGridAddCell"

    override init(frame: CGRect) {
        super.init(frame: frame)

        let background = UIView()
        background.backgroundColor = .tertiarySystemFill
        background.frame = contentView.bounds
        background.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        contentView.addSubview(background)

        let icon = UIImageView(image: UIImage(systemName: "plus"))
        icon.tintColor = .tintColor
        icon.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 24)
        icon.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(icon)
        NSLayoutConstraint.activate([
            icon.centerXAnchor.constraint(equalTo: contentView.centerXAnchor),
            icon.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) tidak dipakai") }
}
