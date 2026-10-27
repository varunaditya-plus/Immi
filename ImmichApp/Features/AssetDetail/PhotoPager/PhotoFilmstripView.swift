import SwiftUI
import UIKit

/// Strip thumbnail di bawah layar detail.
///
/// Versi SwiftUI-nya memakai `LazyHStack` di dalam `ScrollViewReader`, dan
/// `scrollTo(id:)` menuntut SwiftUI menemukan id itu — pada puluhan ribu foto
/// berarti menelusuri semuanya. Karena itu dulu isinya dibatasi jendela kecil di
/// sekitar foto yang sedang tampil, dan jendela itulah yang membuat stripnya
/// terasa "habis" setelah belasan foto lalu tiba-tiba bertambah saat fotonya
/// berpindah.
///
/// Menumbuhkan jendela saat digulir sampai ujung bukan jawabannya: menambah isi
/// array selagi jari sedang menggulirnya menggeser konten di bawah jari — persis
/// kelas bug yang baru saja dibuang dari pager. `UICollectionView` memuat SEMUA
/// foto tanpa jendela sama sekali, dan tetap ringan karena selnya didaur ulang.
struct PhotoFilmstripView: UIViewControllerRepresentable {
    let assets: [AssetLite]
    let currentAssetID: String
    var onSelect: (AssetLite) -> Void
    /// Menyerahkan controller-nya ke pemanggil.
    ///
    /// Pager perlu menggeser strip ini SETIAP FRAME selagi diusap. Menyalurkan
    /// nilai secepat itu lewat `@State` SwiftUI berarti membangun ulang body pada
    /// tiap frame — jadi kedua controller UIKit-nya disambungkan langsung.
    var onControllerReady: ((PhotoFilmstripController) -> Void)? = nil
    let session: SessionManager

    func makeUIViewController(context: Context) -> PhotoFilmstripController {
        let controller = PhotoFilmstripController(
            loader: PhotoThumbnailLoader(session: session))
        controller.onSelect = onSelect
        controller.apply(assets: assets, currentAssetID: currentAssetID)
        if let onControllerReady {
            // Di luar siklus pembaruan: menulis `@State` selagi SwiftUI sedang
            // membangun view memicu peringatan "modifying state during update".
            DispatchQueue.main.async { onControllerReady(controller) }
        }
        return controller
    }

    func updateUIViewController(_ controller: PhotoFilmstripController, context: Context) {
        controller.onSelect = onSelect
        controller.apply(assets: assets, currentAssetID: currentAssetID)
    }
}

/// Ukuran petak strip; disimpan di level berkas supaya sel dan layout tidak bisa
/// berbeda pendapat.
private let filmstripItemSize = CGSize(width: 42, height: 42)
private let filmstripSpacing: CGFloat = 8
private let filmstripSectionInset: CGFloat = 6

@MainActor
final class PhotoFilmstripController: UIViewController {
    private let loader: PhotoThumbnailLoader

    private var collectionView: UICollectionView!
    private var assets: [AssetLite] = []
    private var assetIndex: [String: Int] = [:]
    private var currentIndex = 0
    /// Penempatan awal diulang sampai penggunanya sendiri menyentuh strip.
    ///
    /// Sebelumnya penempatan dikunci setelah SATU percobaan berhasil. Masalahnya,
    /// "berhasil" hanya berarti angkanya sempat ditulis — bukan bahwa lebar dan
    /// ukuran kontennya sudah final. Kalau percobaan itu kebetulan jatuh di layout
    /// pass yang ukurannya belum benar, hasilnya meleset dan tidak ada lagi yang
    /// mengoreksi. Karena itu sekarang ia terus mengoreksi sampai jari atau
    /// pergantian foto mengambil alih.
    private var needsInitialPositioning = true

    /// Petak yang terakhir berada di tengah dan sudah diberi ketukan.
    private var lastHapticIndex = -1
    private let selectionFeedback = UISelectionFeedbackGenerator()

    var onSelect: ((AssetLite) -> Void)?

    init(loader: PhotoThumbnailLoader) {
        self.loader = loader
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) tidak dipakai") }

    override func viewDidLoad() {
        super.viewDidLoad()

        let flow = UICollectionViewFlowLayout()
        flow.scrollDirection = .horizontal
        flow.itemSize = filmstripItemSize
        flow.minimumLineSpacing = filmstripSpacing
        flow.minimumInteritemSpacing = filmstripSpacing
        flow.sectionInset = UIEdgeInsets(
            top: 6, left: filmstripSectionInset,
            bottom: 6, right: filmstripSectionInset)

        collectionView = UICollectionView(frame: view.bounds, collectionViewLayout: flow)
        // Auto Layout, bukan autoresizing.
        //
        // Autoresizing menghitung ukuran baru secara PROPORSIONAL terhadap yang
        // lama — dan kalau yang lama nol, perhitungannya tidak punya arti.
        // Strip ini dibuat sebelum SwiftUI memberinya ukuran, jadi justru itu
        // keadaan awalnya.
        collectionView.translatesAutoresizingMaskIntoConstraints = false
        collectionView.backgroundColor = .clear
        collectionView.showsHorizontalScrollIndicator = false
        collectionView.contentInsetAdjustmentBehavior = .never
        collectionView.register(
            PhotoFilmstripCell.self, forCellWithReuseIdentifier: PhotoFilmstripCell.reuseID)
        collectionView.dataSource = self
        collectionView.delegate = self
        collectionView.prefetchDataSource = self
        view.addSubview(collectionView)

        NSLayoutConstraint.activate([
            collectionView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            collectionView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            collectionView.topAnchor.constraint(equalTo: view.topAnchor),
            collectionView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
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
                collectionView.layoutIfNeeded()
            }
        }

        guard let index = assetIndex[currentAssetID] else { return }
        let moved = index != currentIndex
        let previous = currentIndex
        currentIndex = index
        guard isViewLoaded else { return }

        guard moved else {
            positionAtStartIfNeeded()
            return
        }

        // Foto berpindah: sejak sekarang posisinya ditentukan itu, bukan lagi
        // penempatan awal.
        needsInitialPositioning = false
        refreshHighlight(from: previous)
        scrollToCurrent(animated: true)
    }

    private func isSameContent(as other: [AssetLite]) -> Bool {
        assets.count == other.count
            && assets.first?.id == other.first?.id
            && assets.last?.id == other.last?.id
    }

    /// Menyorot ulang HANYA dua petak yang berubah, bukan seluruh strip.
    private func refreshHighlight(from previous: Int) {
        for index in [previous, currentIndex] where assets.indices.contains(index) {
            let path = IndexPath(item: index, section: 0)
            (collectionView.cellForItem(at: path) as? PhotoFilmstripCell)?
                .setCurrent(index == currentIndex)
        }
    }

    // MARK: - Posisi

    private func positionAtStartIfNeeded() {
        guard needsInitialPositioning, isViewLoaded,
              collectionView.bounds.width > 0,
              assets.indices.contains(currentIndex)
        else { return }

        // Ukuran kontennya harus sudah terhitung sebelum offset dipasang;
        // menggulir di dalam konten selebar nol hanya dijepit kembali ke awal.
        collectionView.layoutIfNeeded()
        guard collectionView.contentSize.width > 0 else { return }

        scrollToCurrent(animated: false)
    }

    /// Offset dihitung sendiri, bukan lewat `scrollToItem`.
    ///
    /// `scrollToItem` bekerja dari atribut layout, yang belum tentu ada saat
    /// pertama kali dibutuhkan — dan kalau tidak ada, ia diam saja tanpa memberi
    /// tahu. Aritmetika ini kebalikan persis dari `centeredIndex`, jadi keduanya
    /// tidak bisa berbeda pendapat.
    private func scrollToCurrent(animated: Bool) {
        guard assets.indices.contains(currentIndex),
              collectionView.bounds.width > 0
        else { return }

        // Perpindahan yang kita sendiri lakukan tidak berdetak.
        lastHapticIndex = currentIndex
        collectionView.setContentOffset(
            CGPoint(x: offset(forPage: CGFloat(currentIndex)), y: 0), animated: animated)
    }

    /// Mengikuti pager selagi diusap, bukan menunggu sampai berhenti.
    ///
    /// `page` boleh pecahan: 12,37 berarti jari sudah 37% dalam perjalanan dari
    /// foto ke-12 ke ke-13, dan stripnya bergeser sejauh itu juga. Inilah yang
    /// membuat keduanya terasa satu benda, bukan dua yang saling menyusul.
    func track(page: Double) {
        guard isViewLoaded, !assets.isEmpty, collectionView.bounds.width > 0 else { return }

        // Jari sudah mengambil alih; penempatan awal berhenti mengoreksi.
        needsInitialPositioning = false

        let clamped = min(max(0, page), Double(assets.count - 1))
        collectionView.setContentOffset(
            CGPoint(x: offset(forPage: CGFloat(clamped)), y: 0), animated: false)

        // Sorotan pindah ke petak terdekat, tanpa menunggu pager berhenti.
        let index = Int(clamped.rounded())
        guard index != currentIndex, assets.indices.contains(index) else { return }
        let previous = currentIndex
        currentIndex = index
        lastHapticIndex = index
        refreshHighlight(from: previous)
    }

    /// Offset yang menempatkan sebuah halaman — utuh atau pecahan — di tengah.
    private func offset(forPage page: CGFloat) -> CGFloat {
        let stride = filmstripItemSize.width + filmstripSpacing
        let center = filmstripSectionInset
            + page * stride
            + filmstripItemSize.width / 2
        // `bounds.width / 2`, BUKAN `bounds.midX`.
        //
        // Pada scroll view, `bounds.origin` ADALAH `contentOffset` — jadi
        // `bounds.midX` sudah mengandung posisi gulir sekarang. Memakainya di
        // sini membuat offset baru dihitung relatif terhadap offset lama, dan
        // kesalahannya menumpuk setiap perpindahan. Itulah kenapa stripnya makin
        // lama makin meleset dan terlihat acak.
        let maxOffset = max(0, collectionView.contentSize.width - collectionView.bounds.width)
        return min(max(0, center - collectionView.bounds.width / 2), maxOffset)
    }

    /// Petak yang sedang berada paling dekat dengan tengah layar.
    private var centeredIndex: Int {
        guard collectionView.bounds.width > 0 else { return -1 }
        // Sama seperti di `scrollToCurrent`: `bounds.midX` akan menghitung
        // `contentOffset` dua kali.
        let centerX = collectionView.contentOffset.x + collectionView.bounds.width / 2
        let stride = filmstripItemSize.width + filmstripSpacing
        guard stride > 0 else { return -1 }
        return Int(round(
            (centerX - filmstripSectionInset - filmstripItemSize.width / 2) / stride))
    }
}

// MARK: - Sumber data

extension PhotoFilmstripController: UICollectionViewDataSource {
    func collectionView(
        _ collectionView: UICollectionView, numberOfItemsInSection section: Int
    ) -> Int {
        assets.count
    }

    func collectionView(
        _ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath
    ) -> UICollectionViewCell {
        let cell = collectionView.dequeueReusableCell(
            withReuseIdentifier: PhotoFilmstripCell.reuseID, for: indexPath)
        guard let stripCell = cell as? PhotoFilmstripCell,
              assets.indices.contains(indexPath.item)
        else { return cell }

        stripCell.configure(with: assets[indexPath.item], loader: loader)
        stripCell.setCurrent(indexPath.item == currentIndex)
        return stripCell
    }
}

// MARK: - Delegate

extension PhotoFilmstripController: UICollectionViewDelegate {
    func collectionView(
        _ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath
    ) {
        guard assets.indices.contains(indexPath.item) else { return }
        onSelect?(assets[indexPath.item])
    }

    func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
        // Jari mengambil alih; penempatan awal berhenti mengoreksi.
        needsInitialPositioning = false
        selectionFeedback.prepare()
    }

    /// Berdetak setiap petak melintasi tengah, seperti roda pemilih.
    ///
    /// Hanya selagi jari benar-benar menggulir: penggeseran yang kita lakukan
    /// sendiri saat foto berpindah tidak boleh ikut berdetak, karena pager sudah
    /// memberi ketukannya sendiri di sana.
    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        guard scrollView.isDragging || scrollView.isDecelerating else { return }
        let index = centeredIndex
        guard index != lastHapticIndex, assets.indices.contains(index) else { return }
        if lastHapticIndex >= 0 { selectionFeedback.selectionChanged() }
        lastHapticIndex = index
    }
}

// MARK: - Prefetching

extension PhotoFilmstripController: UICollectionViewDataSourcePrefetching {
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

// MARK: - Sel

/// Satu petak di strip thumbnail.
///
/// Memakai `PhotoThumbnailLoader` yang sama dengan grid, jadi gambarnya hampir
/// selalu sudah ada di memori — foto ini baru saja dilihat di grid.
final class PhotoFilmstripCell: UICollectionViewCell {
    static let reuseID = "PhotoFilmstripCell"

    private let imageView = UIImageView()
    private var loadTask: Task<Void, Never>?
    private var currentAssetID: String?

    override init(frame: CGRect) {
        super.init(frame: frame)

        imageView.contentMode = .scaleAspectFill
        imageView.clipsToBounds = true
        imageView.backgroundColor = .secondarySystemFill
        imageView.layer.cornerRadius = 4
        imageView.layer.borderColor = UIColor.systemBlue.cgColor
        imageView.frame = contentView.bounds
        imageView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        contentView.addSubview(imageView)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) tidak dipakai") }

    override func prepareForReuse() {
        super.prepareForReuse()
        loadTask?.cancel()
        loadTask = nil
        currentAssetID = nil
        imageView.image = nil
    }

    func configure(with asset: AssetLite, loader: PhotoThumbnailLoader) {
        loadTask?.cancel()
        loadTask = nil
        currentAssetID = asset.id

        if let cached = loader.cachedImage(for: asset.id) {
            imageView.image = cached
            return
        }

        imageView.image = ThumbHash.placeholder(for: asset.thumbhash)
        loadTask = Task { [weak self] in
            let image = await loader.image(for: asset.id)
            guard let self, !Task.isCancelled,
                  self.currentAssetID == asset.id
            else { return }
            self.loadTask = nil
            guard let image else { return }
            self.imageView.image = image
        }
    }

    func setCurrent(_ isCurrent: Bool) {
        imageView.alpha = isCurrent ? 1 : 0.6
        imageView.layer.borderWidth = isCurrent ? 2 : 0
    }
}
