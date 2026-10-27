import AVFoundation
import PhotosUI
import UIKit

/// Aturan tata letak foto di layar detail, dikirim dari sisi SwiftUI.
///
/// Nilainya berubah saat panel info ditarik, jadi ia harus bisa diteruskan ke
/// semua sel yang sedang terlihat tanpa menyusun ulang apa pun.
struct PhotoPagerLayout: Equatable {
    /// Satu sumber timing untuk panel SwiftUI dan refit konten UIKit.
    static let panelTransitionDuration: TimeInterval = 0.38
    static let chromeTransitionDuration: TimeInterval = 0.2

    /// Batas tinggi konten dalam poin (tinggi area aman). 0 = tanpa batas.
    var maxContentHeight: CGFloat = 0
    /// Titik pusat vertikal konten dalam koordinat layar. 0 = pusat bounds.
    var contentCenterY: CGFloat = 0
    /// 0 = layout card apa adanya, 1 = full width menempel di tepi atas.
    var expandProgress: CGFloat = 0
    /// Sudut membulat pada gambar (mode card); 0 = tanpa radius.
    var cornerRadius: CGFloat = 0
    /// false mematikan pinch dan double tap.
    var isZoomEnabled: Bool = true
    /// Badge LIVE mengikuti chrome layar: false pada mode full-view.
    var showsLivePhotoBadge: Bool = true
    /// false saat perubahan berasal dari drag — layout harus mengikuti jari
    /// seketika, dan menganimasikannya justru membuatnya tertinggal.
    var animates: Bool = true
}

/// Satu halaman foto: scroll view untuk zoom, berisi satu `UIImageView`.
///
/// Sebelumnya tiap halaman menghosting view SwiftUI di `UIHostingController`
/// sendiri. Dengan jendela 25 halaman itu 25 hosting controller sekali buka —
/// masing-masing dengan pohon SwiftUI, pemuat gambar, dan siklus layoutnya
/// sendiri. Di sini isinya `UIImageView` biasa, dan selnya didaur ulang.
final class PhotoPagerCell: UICollectionViewCell {
    static let reuseID = "PhotoPagerCell"

    private let scrollView = LayoutReportingScrollView()
    private let imageView = UIImageView()

    private var loadTask: Task<Void, Never>?
    private var currentAssetID: String?
    private var isVideo = false
    /// Disimpan supaya tombol putar bisa meminta URL videonya belakangan.
    private weak var loader: PhotoPreviewLoader?
    private var playbackNotifications = NotificationCenter.default

    /// Pemutar dibuat SAAT tombol putar ditekan, bukan saat sel dikonfigurasi.
    ///
    /// Sel tetangga ikut hidup di pager; membuat pemutar untuk semuanya berarti
    /// beberapa koneksi video terbuka sekaligus padahal cuma satu yang akan
    /// ditonton.
    private var player: AVPlayer?
    private var videoView: PhotoVideoSurfaceView?
    private var videoLoadTask: Task<Void, Never>?
    private var endObserver: NSObjectProtocol?
    /// Mengikuti status buffering dari AVPlayer. Pengamat ini wajib dilepas
    /// bersama pemutar supaya callback video lama tidak mengubah sel daur ulang.
    private var playbackStatusObserver: NSKeyValueObservation?
    /// AVPlayer kadang tetap berstatus menunggu meski item sudah siap meneruskan.
    /// Perubahan ini dipakai untuk menendangnya kembali ke `play()`.
    private var playbackKeepUpObserver: NSKeyValueObservation?
    /// Setiap kemajuan range buffer dipakai untuk memperbarui bar unduhan dan
    /// melanjutkan playback yang sempat kehabisan data.
    private var playbackLoadedRangesObserver: NSKeyValueObservation?
    private var playbackStalledObserver: NSObjectProtocol?
    /// Pengamat waktu berkala, untuk menggerakkan slider di bar kontrol.
    private var timeObserver: Any?
    private let playButton = UIButton(type: .system)
    private let loadingIndicator = UIActivityIndicatorView(style: .large)
    /// Intent pengguna, terpisah dari `timeControlStatus`. Status AVPlayer dapat
    /// menjadi paused/waiting ketika buffer habis tanpa berarti pengguna pause.
    private var wantsVideoPlayback = false

    /// Id video pasangan Live Photo; nil untuk foto biasa.
    private var livePhotoVideoID: String?
    /// Pemutar Live Photo dipisah dari pemutar video biasa.
    ///
    /// Keduanya punya siklus hidup yang sama sekali berbeda — yang ini hidup
    /// hanya selama jari menekan — dan menumpangkan keduanya pada satu pemutar
    /// membuat bar kontrol video ikut bereaksi terhadap sesuatu yang bukan
    /// urusannya.
    private var livePlayer: AVPlayer?
    private var liveLayer: AVPlayerLayer?
    private var livePhotoView: PHLivePhotoView?
    private var liveLoadTask: Task<Void, Never>?
    private var livePhotoDetectionTask: Task<Void, Never>?
    private var livePhotoHint: LocalLivePhotoMatchHint?
    private var liveEndObserver: NSObjectProtocol?
    private var livePlaybackStatusObserver: NSKeyValueObservation?
    private var livePlaybackKeepUpObserver: NSKeyValueObservation?
    /// Hasil pemuatan boleh datang setelah jari dilepas. State ini memastikan
    /// video tidak tiba-tiba mulai sendiri ketika pengguna sudah berpindah.
    private var isLivePhotoPressed = false
    /// True bila pasangan still + motion tersedia langsung dari PhotoKit.
    /// Jalur ini tetap bekerja walau cache/server belum punya video ID.
    private var localLivePhotoAssetID: String?
    private let liveBadge = UIView()
    /// Tinggi lencana LIVE; dipakai bersama oleh constraint dan radiusnya.
    private let liveBadgeHeight: CGFloat = 28
    /// Durasi dari metadata, dipakai sebelum pemutar dibuat — supaya bar
    /// kontrolnya sudah punya panjang yang benar sejak sebelum diputar.
    private var metadataDuration: Double = 0

    var onPlaybackChanged: ((PhotoPlaybackState) -> Void)?

    /// Pilihan bisu, DIBAGI seluruh halaman dan bertahan selama aplikasi hidup.
    ///
    /// Video dibuka dalam keadaan bisu — membuka galeri di tempat umum tidak
    /// seharusnya mengejutkan. Tapi begitu pengguna menyalakan suaranya, pilihan
    /// itu berlaku untuk video berikutnya juga; sel didaur ulang, jadi menyimpan
    /// pilihan itu di instance berarti ia hilang setiap ganti halaman.
    private static var prefersMuted = true
    private var imageAspect: CGFloat = 1
    private var layoutRules = PhotoPagerLayout()

    /// Ukuran konten hasil perhitungan terakhir, untuk tahu kapan frame benar-
    /// benar perlu ditulis ulang.
    private var fittedSize: CGSize = .zero
    /// Cache inset mencegah setter UIScrollView dipanggil kembali oleh layout
    /// pass yang dipicu setter itu sendiri.
    private var fittedInsets = UIEdgeInsets(
        top: .greatestFiniteMagnitude,
        left: .greatestFiniteMagnitude,
        bottom: .greatestFiniteMagnitude,
        right: .greatestFiniteMagnitude)
    private var isZoomed = false
    private var isPagingLockedForZoom = false
    /// true selama refit mengubah `zoomScale` secara programatik; laporan zoom
    /// diabaikan supaya tidak memicu loop layout.
    private var isRefitting = false
    /// Ditandai saat perubahan datang dari SwiftUI (buka/tutup panel info),
    /// bukan dari bounds yang bergeser.
    private var animateNextFit = false
    private var needsOffsetReset = false
    /// Sudah pernah diukur sejak sel ini dipakai untuk foto sekarang.
    ///
    /// Pengukuran PERTAMA tidak boleh dianimasikan. Sel yang baru didaur ulang
    /// mulai dari frame nol, jadi menganimasikannya berarti gambar tumbuh dari
    /// pojok kiri atas sampai memenuhi tempatnya — persis yang terlihat setiap
    /// kali berpindah foto lewat strip thumbnail.
    private var hasFitted = false

    var onZoomChanged: ((Bool, Bool) -> Void)?
    var onTap: (() -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)

        scrollView.delegate = self
        scrollView.minimumZoomScale = 1
        scrollView.maximumZoomScale = 4
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.showsVerticalScrollIndicator = false
        scrollView.contentInsetAdjustmentBehavior = .never
        scrollView.backgroundColor = .clear
        // Konten yang di-zoom dipotong di batas halaman supaya tidak menembus ke
        // belakang toolbar atas/bawah.
        scrollView.clipsToBounds = true
        // Penanda untuk animator transisi: ia perlu kotak akhir fotonya, dan
        // aturan ukurannya hidup di berkas ini — bukan di ukuran layar.
        scrollView.accessibilityIdentifier = photoZoomContentIdentifier
        scrollView.frame = contentView.bounds
        scrollView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        contentView.addSubview(scrollView)

        // `.fit`, bukan `.fill`: rasio dari metadata bisa sedikit meleset dari
        // rasio berkas preview, dan dengan `.fill` selisih sekecil apa pun
        // memotong tepi gambar — paling terasa di sisi kanan.
        imageView.contentMode = .scaleAspectFit
        imageView.layer.masksToBounds = true
        scrollView.addSubview(imageView)

        let doubleTap = UITapGestureRecognizer(
            target: self, action: #selector(handleDoubleTap(_:)))
        doubleTap.numberOfTapsRequired = 2
        scrollView.addGestureRecognizer(doubleTap)
        self.doubleTap = doubleTap

        let singleTap = UITapGestureRecognizer(
            target: self, action: #selector(handleSingleTap))
        singleTap.numberOfTapsRequired = 1
        // Ketukan tunggal menunggu ketukan ganda gagal; tanpa ini toolbar
        // berkedip setiap kali foto di-zoom lewat dua ketukan.
        singleTap.require(toFail: doubleTap)
        scrollView.addGestureRecognizer(singleTap)

        var config = UIButton.Configuration.filled()
        config.image = UIImage(
            systemName: "play.fill",
            withConfiguration: UIImage.SymbolConfiguration(pointSize: 26, weight: .semibold))
        config.baseForegroundColor = .white
        config.baseBackgroundColor = UIColor.black.withAlphaComponent(0.45)
        config.cornerStyle = .capsule
        config.contentInsets = NSDirectionalEdgeInsets(
            top: 18, leading: 20, bottom: 18, trailing: 16)
        playButton.configuration = config
        playButton.isHidden = true
        playButton.addTarget(self, action: #selector(togglePlayback), for: .touchUpInside)
        playButton.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(playButton)
        NSLayoutConstraint.activate([
            playButton.centerXAnchor.constraint(equalTo: contentView.centerXAnchor),
            playButton.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
        ])

        loadingIndicator.color = .white
        loadingIndicator.backgroundColor = UIColor.black.withAlphaComponent(0.42)
        loadingIndicator.layer.cornerRadius = 27
        loadingIndicator.hidesWhenStopped = true
        loadingIndicator.isUserInteractionEnabled = false
        loadingIndicator.accessibilityLabel = String(localized: "Loading video")
        loadingIndicator.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(loadingIndicator)
        NSLayoutConstraint.activate([
            loadingIndicator.centerXAnchor.constraint(equalTo: contentView.centerXAnchor),
            loadingIndicator.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            loadingIndicator.widthAnchor.constraint(equalToConstant: 54),
            loadingIndicator.heightAnchor.constraint(equalToConstant: 54),
        ])

        buildLiveBadge()

        let longPress = UILongPressGestureRecognizer(
            target: self, action: #selector(handleLongPress(_:)))
        longPress.minimumPressDuration = 0.22
        // Sedikit gerakan alami jari tidak boleh langsung membatalkan Live
        // Photo, tetapi swipe pager yang nyata tetap menang.
        longPress.allowableMovement = 24
        longPress.cancelsTouchesInView = false
        longPress.delegate = self
        scrollView.addGestureRecognizer(longPress)
        // Single tap baru boleh bekerja kalau gesture hold benar-benar gagal.
        // Tanpa dependency ini, melepas jari setelah Live Photo selesai masih
        // mengirim tap dan ikut menyembunyikan/menampilkan toolbar.
        singleTap.require(toFail: longPress)

        scrollView.onLayout = { [weak self] in self?.fitContent() }
    }

    /// Lencana "LIVE" di kiri atas, bergaya kapsul material seperti di Photos.
    private func buildLiveBadge() {
        let effect = UIVisualEffectView(effect: UIBlurEffect(style: .systemThinMaterial))
        effect.translatesAutoresizingMaskIntoConstraints = false
        effect.isUserInteractionEnabled = false

        let icon = UIImageView(image: UIImage(systemName: "livephoto"))
        icon.tintColor = .label
        icon.preferredSymbolConfiguration = UIImage.SymbolConfiguration(
            pointSize: 13, weight: .semibold)

        let label = UILabel()
        label.text = "LIVE"
        label.font = .systemFont(ofSize: 12, weight: .semibold)
        label.textColor = .label

        let stack = UIStackView(arrangedSubviews: [icon, label])
        stack.spacing = 4
        stack.alignment = .center
        stack.translatesAutoresizingMaskIntoConstraints = false
        effect.contentView.addSubview(stack)

        liveBadge.addSubview(effect)
        liveBadge.isHidden = true
        liveBadge.alpha = 0
        liveBadge.isUserInteractionEnabled = false
        liveBadge.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(liveBadge)

        NSLayoutConstraint.activate([
            effect.leadingAnchor.constraint(equalTo: liveBadge.leadingAnchor),
            effect.trailingAnchor.constraint(equalTo: liveBadge.trailingAnchor),
            effect.topAnchor.constraint(equalTo: liveBadge.topAnchor),
            effect.bottomAnchor.constraint(equalTo: liveBadge.bottomAnchor),

            stack.leadingAnchor.constraint(equalTo: effect.contentView.leadingAnchor, constant: 10),
            stack.trailingAnchor.constraint(equalTo: effect.contentView.trailingAnchor, constant: -10),
            stack.centerYAnchor.constraint(equalTo: effect.contentView.centerYAnchor),

            // Tinggi DIPATOK, bukan mengikuti isinya.
            //
            // Radius kapsulnya harus setengah tinggi, dan tinggi yang dihitung
            // dari isi baru diketahui setelah `contentView` menata anak-anaknya —
            // yaitu SETELAH `layoutSubviews` sel ini berjalan. Dulu radiusnya
            // disetel di sana, jadi pada pembukaan pertama ia dihitung dari
            // tinggi yang masih nol dan lencananya tampil bersudut siku. Baru
            // setelah ada layout pass lain (membuka panel info, misalnya) angkanya
            // benar. Dengan tinggi tetap, radiusnya diketahui sejak awal.
            liveBadge.heightAnchor.constraint(equalToConstant: liveBadgeHeight),

            liveBadge.leadingAnchor.constraint(
                equalTo: contentView.safeAreaLayoutGuide.leadingAnchor, constant: 16),
            liveBadge.topAnchor.constraint(
                equalTo: contentView.safeAreaLayoutGuide.topAnchor, constant: 8),
        ])

        effect.clipsToBounds = true
        effect.layer.cornerRadius = liveBadgeHeight / 2
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) tidak dipakai") }

    convenience init(frame: CGRect, playbackNotifications: NotificationCenter) {
        self.init(frame: frame)
        self.playbackNotifications = playbackNotifications
    }

    private weak var doubleTap: UITapGestureRecognizer?

    override func prepareForReuse() {
        super.prepareForReuse()
        loadTask?.cancel()
        loadTask = nil
        livePhotoDetectionTask?.cancel()
        livePhotoDetectionTask = nil
        livePhotoHint = nil
        stopPlayback()
        livePhotoVideoID = nil
        localLivePhotoAssetID = nil
        liveBadge.isHidden = true
        liveBadge.alpha = 0
        currentAssetID = nil
        isVideo = false
        playButton.isHidden = true
        imageView.image = nil
        fittedSize = .zero
        fittedInsets = UIEdgeInsets(
            top: .greatestFiniteMagnitude,
            left: .greatestFiniteMagnitude,
            bottom: .greatestFiniteMagnitude,
            right: .greatestFiniteMagnitude)
        hasFitted = false
        animateNextFit = false
        isZoomed = false
        isPagingLockedForZoom = false
        scrollView.setZoomScale(1, animated: false)
    }

    // MARK: - Isi

    func configure(with asset: AssetLite, loader: PhotoPreviewLoader) {
        loadTask?.cancel()
        loadTask = nil
        if currentAssetID != nil, currentAssetID != asset.id {
            // Pertahanan tambahan di luar prepareForReuse: UICollectionView dapat
            // mengonfigurasi ulang sel terlihat tanpa reuse saat datanya ditambal.
            // Tidak satu pun konteks Live Photo lama boleh ikut ke aset baru.
            livePhotoDetectionTask?.cancel()
            livePhotoDetectionTask = nil
            livePhotoHint = nil
            stopPlayback()
            livePhotoVideoID = nil
            localLivePhotoAssetID = nil
        }
        currentAssetID = asset.id
        imageAspect = asset.ratio > 0 ? CGFloat(asset.ratio) : 1
        isVideo = asset.isVideo
        livePhotoVideoID = asset.livePhotoVideoID
        localLivePhotoAssetID = loader.localLivePhotoAssetID(for: asset.id)
        updateLiveBadgeVisibility(animated: false)
        metadataDuration = asset.duration ?? 0
        playButton.isHidden = !asset.isVideo
        self.loader = loader
        reportPlayback()

        // Yang sudah ada di memori dipasang seketika — termasuk thumbnail
        // seukuran grid kalau versi tajamnya belum datang.
        setImage(loader.cachedImage(for: asset.id)
            ?? ThumbHash.placeholder(for: asset.thumbhash))

        guard !loader.hasPreview(for: asset.id) else { return }
        startLoad(asset.id, loader: loader)
    }

    /// Detail lengkap kadang tiba setelah daftar pager. Pasangan Live Photo
    /// boleh ditambal tanpa me-reload gambar atau mengubah posisi halaman.
    func updateLivePhotoContext(
        videoID: String?,
        localHint: LocalLivePhotoMatchHint?,
        loader: PhotoPreviewLoader
    ) {
        if livePhotoHint != localHint {
            livePhotoDetectionTask?.cancel()
            livePhotoDetectionTask = nil
            livePhotoHint = localHint
            let nativeAssetID = currentAssetID.flatMap(loader.localLivePhotoAssetID(for:))
            if localLivePhotoAssetID != nativeAssetID {
                isLivePhotoPressed = false
                stopLivePhoto()
                localLivePhotoAssetID = nativeAssetID
            }
        }
        if livePhotoVideoID != videoID {
            // Video pasangan berubah/nil berarti konteks lama tidak valid lagi.
            // Hentikan sebelum ID diganti agar hasil async lama tidak tampil.
            isLivePhotoPressed = false
            stopLivePhoto()
        }
        livePhotoVideoID = videoID
        updateLiveBadgeVisibility(animated: true)

        guard localLivePhotoAssetID == nil,
              livePhotoDetectionTask == nil,
              let localHint,
              let assetID = currentAssetID
        else { return }

        livePhotoDetectionTask = Task { [weak self] in
            let matchedID = await loader.matchingLocalLivePhoto(for: localHint)
            guard let self, !Task.isCancelled,
                  self.currentAssetID == assetID,
                  self.livePhotoHint == localHint
            else { return }
            self.livePhotoDetectionTask = nil
            guard let matchedID else { return }
            self.localLivePhotoAssetID = matchedID
            self.updateLiveBadgeVisibility(animated: true)
        }
    }

    private var shouldShowLiveBadge: Bool {
        layoutRules.showsLivePhotoBadge
            && (livePhotoVideoID != nil || localLivePhotoAssetID != nil)
    }

    private func updateLiveBadgeVisibility(animated: Bool) {
        let visible = shouldShowLiveBadge
        liveBadge.layer.removeAllAnimations()

        guard animated else {
            liveBadge.alpha = visible ? 1 : 0
            liveBadge.isHidden = !visible
            return
        }

        if visible { liveBadge.isHidden = false }
        UIView.animate(
            withDuration: 0.22,
            delay: 0,
            options: [.beginFromCurrentState, .curveEaseInOut]
        ) {
            self.liveBadge.alpha = visible ? 1 : 0
        } completion: { [weak self] _ in
            guard let self else { return }
            self.liveBadge.isHidden = !self.shouldShowLiveBadge
        }
    }

    /// Mencoba lagi kalau versi tajamnya belum ada dan tidak ada pemuatan yang
    /// sedang berjalan.
    ///
    /// Menggulir cepat membatalkan pemuatan halaman yang dilewati — itu memang
    /// yang diinginkan. Tapi halaman tempat jari akhirnya berhenti bisa ikut
    /// terbatalkan, dan tanpa ini ia berhenti di placeholder selamanya. Tidak ada
    /// ongkos kalau gambarnya sudah ada: pertanyaannya dijawab dari memori.
    func retryIfNeeded(loader: PhotoPreviewLoader) {
        guard let id = currentAssetID, loadTask == nil, !loader.hasPreview(for: id)
        else { return }
        startLoad(id, loader: loader)
    }

    private func startLoad(_ assetID: String, loader: PhotoPreviewLoader) {
        loadTask = Task { [weak self] in
            let image = await loader.image(for: assetID)
            guard let self, !Task.isCancelled, self.currentAssetID == assetID
            else { return }
            self.loadTask = nil
            guard let image else { return }
            self.setImage(image)
        }
    }

    /// Satu-satunya jalan memasang gambar — dan sekaligus tempat rasio aslinya
    /// diambil.
    ///
    /// Rasio TIDAK boleh cuma datang dari metadata. `asset.ratio` dihitung dari
    /// `exifInfo`, dan `/search/metadata` tidak mengirim exif kecuali diminta —
    /// jadi untuk semua layar yang sumbernya pencarian (Favorites, People,
    /// Search, Archived, Trash) rasionya jatuh ke nilai cadangan 1.0. Sel ini
    /// lalu menata setiap foto sebagai PERSEGI: foto tegak digambar lebih sempit
    /// dari lebar layar dan terlihat mengecil, sementara di linimasa — yang
    /// rasionya datang dari kolom `ratio` server — semuanya benar.
    ///
    /// Gambarnya sendiri selalu tahu rasionya. Metadata cukup jadi tebakan awal
    /// sebelum gambar apa pun ada.
    private func setImage(_ image: UIImage?) {
        imageView.image = image
        if let image, image.size.width > 0, image.size.height > 0 {
            imageAspect = image.size.width / image.size.height
        }
        setNeedsLayoutFit()
    }

    func apply(_ rules: PhotoPagerLayout) {
        guard layoutRules != rules else { return }

        let progressChanged = layoutRules.expandProgress != rules.expandProgress
        let badgeVisibilityChanged = layoutRules.showsLivePhotoBadge
            != rules.showsLivePhotoBadge
        animateNextFit = rules.animates
        // Posisi konten diluruskan SEKALI per perubahan progress, bukan di setiap
        // layout pass — umpan balik itulah sumber getarannya.
        if progressChanged { needsOffsetReset = true }

        layoutRules = rules
        if badgeVisibilityChanged {
            updateLiveBadgeVisibility(animated: rules.animates)
        }
        scrollView.pinchGestureRecognizer?.isEnabled = rules.isZoomEnabled
        doubleTap?.isEnabled = rules.isZoomEnabled
        setNeedsLayoutFit()
    }

    private func setNeedsLayoutFit() {
        scrollView.setNeedsLayout()
    }

    // MARK: - Tata letak

    /// Mengukur ulang konten agar pas dengan bounds.
    ///
    /// Dipanggil dari `layoutSubviews` scroll view, karena bounds-nya berubah
    /// setiap toolbar tampil atau menghilang.
    private func fitContent() {
        // Jangan utak-atik zoomScale saat pinch masih berlangsung atau saat refit
        // lain sedang jalan — itu sumber crash.
        guard !isRefitting, !scrollView.isZooming else { return }

        let bounds = scrollView.bounds.size
        guard bounds.width > 0, bounds.height > 0 else { return }

        // Selama foto masih ter-zoom, ukuran dasarnya tidak dihitung ulang;
        // mengubah frame di tengah keadaan zoom membuat foto melompat saat
        // toolbar sembunyi atau muncul.
        guard scrollView.zoomScale <= 1.01 else {
            centerContent()
            return
        }

        let aspect = imageAspect > 0 ? imageAspect : bounds.width / bounds.height

        // Batas tinggi datang dari SwiftUI (tinggi area aman), bukan dari bounds
        // scroll view yang selalu selayar penuh. Tanpa batas (0) = layar penuh.
        // Tidak ada batas lebar: foto yang tidak tinggi tetap memenuhi lebar.
        let limit = layoutRules.maxContentHeight > 0
            ? min(layoutRules.maxContentHeight, bounds.height)
            : bounds.height

        // Dua layout dihitung lalu di-interpolasi memakai `expandProgress`:
        // `full` = lebar penuh pada rasio aslinya, `card` = dikecilkan agar muat
        // di batas tinggi. Foto yang tidak tinggi sama saja di keduanya, jadi ia
        // hanya terdorong naik tanpa berubah ukuran.
        let full = CGSize(width: bounds.width, height: bounds.width / aspect)
        var card = full
        if card.height > limit {
            card = CGSize(width: limit * aspect, height: limit)
        }

        let t = min(max(0, layoutRules.expandProgress), 1)
        let fitted = CGSize(
            width: card.width + (full.width - card.width) * t,
            height: card.height + (full.height - card.height) * t)

        // Foto yang tampil kecil butuh ruang zoom ekstra: minimal cukup untuk
        // mencapai lebar layar, lalu 4x dari sana.
        let widthFactor = fitted.width > 0 ? bounds.width / fitted.width : 1
        scrollView.maximumZoomScale = max(4, widthFactor * 4)

        // Radius dan garis tepi hanya untuk foto yang benar-benar dikecilkan;
        // yang tampil full width dibiarkan polos. Radiusnya ikut memudar seiring
        // foto melebar.
        let isShrunk = fitted.width < bounds.width - 0.5
        let effectiveRadius = isShrunk ? layoutRules.cornerRadius * (1 - t) : 0

        // Pengukuran pertama selalu seketika; lihat catatan di `hasFitted`.
        let shouldAnimate = animateNextFit && hasFitted
        animateNextFit = false
        hasFitted = true

        let apply = { [self] in
            if fitted != fittedSize {
                fittedSize = fitted
                imageView.frame = CGRect(origin: .zero, size: fitted)
                scrollView.contentSize = fitted
            }
            // Backing layer UIView mengikuti animasi refit yang sama, termasuk
            // beginFromCurrentState saat pengguna mengetuk lagi di tengah transisi.
            // Sublayer dengan disableActions langsung melompat ke ukuran akhir
            // sementara imageView masih bergerak, sehingga video terpotong.
            videoView?.frame = CGRect(origin: .zero, size: fitted)
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            liveLayer?.frame = CGRect(origin: .zero, size: fitted)
            CATransaction.commit()
            imageView.layer.cornerRadius = effectiveRadius
            imageView.layer.borderWidth = effectiveRadius > 0 ? 1 : 0
            imageView.layer.borderColor = UIColor.systemGray
                .withAlphaComponent(0.35).cgColor
            centerContent()
        }

        if shouldAnimate {
            UIView.animate(
                withDuration: PhotoPagerLayout.panelTransitionDuration,
                delay: 0,
                options: [.curveEaseInOut, .beginFromCurrentState],
                animations: apply)
        } else {
            apply()
        }
    }

    /// Menempatkan konten lewat `contentInset`, di-interpolasi antara "terpusat
    /// di kotak aman" (card) dan "menempel tepi atas" (expanded).
    private func centerContent() {
        let bounds = scrollView.bounds.size
        let content = scrollView.contentSize
        let insetX = max(0, (bounds.width - content.width) / 2)

        let cardCenterY = layoutRules.contentCenterY > 0
            ? layoutRules.contentCenterY
            : bounds.height / 2
        let topAlignedCenterY = content.height / 2

        let t = min(max(0, layoutRules.expandProgress), 1)
        let centerY = cardCenterY + (topAlignedCenterY - cardCenterY) * t

        let insetTop = max(0, centerY - content.height / 2)
        let insetBottom = max(0, bounds.height - centerY - content.height / 2)

        let newInsets = UIEdgeInsets(
            top: insetTop, left: insetX, bottom: insetBottom, right: insetX)
        if !fittedInsets.isApproximatelyEqual(to: newInsets) {
            fittedInsets = newInsets
            scrollView.contentInset = newInsets
        }

        // Menyetel offset di setiap layout pass memicu layoutSubviews lagi →
        // fitContent → setel offset → berulang. Umpan balik itulah getarannya,
        // jadi ini hanya dijalankan saat ditandai, dan tidak selagi jari atau
        // deselerasi masih memegang scroll view.
        guard needsOffsetReset,
              scrollView.zoomScale <= 1.01,
              !scrollView.isDragging,
              !scrollView.isDecelerating
        else { return }
        needsOffsetReset = false

        let target = CGPoint(x: -insetX, y: -insetTop)
        let dx = abs(scrollView.contentOffset.x - target.x)
        let dy = abs(scrollView.contentOffset.y - target.y)
        if dx > 0.5 || dy > 0.5 {
            scrollView.setContentOffset(target, animated: false)
        }
    }

    private func reportZoom() {
        let zoomed = scrollView.zoomScale > 1.01
        // Kalau konten belum lebih lebar dari viewport, UIScrollView belum punya
        // ruang pan horizontal. Swipe mendatar pada kondisi itu tetap milik pager.
        let blocksPaging = zoomed
            && fittedSize.width * scrollView.zoomScale > scrollView.bounds.width + 0.5
        guard zoomed != isZoomed || blocksPaging != isPagingLockedForZoom else { return }
        isZoomed = zoomed
        isPagingLockedForZoom = blocksPaging
        onZoomChanged?(zoomed, blocksPaging)
    }

    /// true selama foto ini sedang di-zoom; pager memakainya untuk mengunci
    /// perpindahan halaman.
    var isCurrentlyZoomed: Bool { scrollView.zoomScale > 1.01 }

    /// Pager hanya dikunci jika foto yang diperbesar memang dapat digeser
    /// horizontal. Nilai dihitung langsung agar akurat sebelum callback state.
    var blocksPagingForZoom: Bool {
        scrollView.zoomScale > 1.01
            && fittedSize.width * scrollView.zoomScale > scrollView.bounds.width + 0.5
    }

    func resetZoom() {
        guard scrollView.zoomScale > 1.01 else { return }
        scrollView.setZoomScale(1, animated: false)
        reportZoom()
    }

    /// Boleh ditarik ke bawah untuk menutup?
    ///
    /// Tarikan vertikal di layar ini punya tiga arti tergantung keadaan: menggeser
    /// foto yang sedang di-zoom, membuka panel info, atau menutup layar. Sel ini
    /// sudah tahu dua yang pertama — `isZoomEnabled` bernilai false persis saat
    /// panel info terbuka — jadi tidak perlu jalur kabar terpisah dari SwiftUI.
    var allowsInteractiveDismiss: Bool {
        layoutRules.isZoomEnabled && !isCurrentlyZoomed
    }

    // MARK: - Gestur

    @objc private func handleSingleTap() {
        // Saat video sedang berputar, ketukan berarti jeda — bukan
        // menyembunyikan toolbar. Di luar itu perilakunya seperti foto biasa.
        guard let player, wantsVideoPlayback else {
            onTap?()
            return
        }
        wantsVideoPlayback = false
        player.pause()
        playButton.isHidden = false
        loadingIndicator.stopAnimating()
        reportPlayback()
    }

    // MARK: - Video

    @objc private func togglePlayback() {
        if let player {
            wantsVideoPlayback = true
            player.play()
            playButton.isHidden = true
            updateLoadingIndicator(for: player)
            reportPlayback()
            return
        }

        guard videoLoadTask == nil,
              let id = currentAssetID,
              let loader
        else { return }

        playButton.isHidden = true
        loadingIndicator.accessibilityLabel = String(localized: "Loading video")
        loadingIndicator.startAnimating()
        videoLoadTask = Task { [weak self] in
            let asset = await loader.playbackAsset(for: id)
            guard !Task.isCancelled, let self else {
                asset?.cancelLoading()
                return
            }
            self.videoLoadTask = nil
            guard !Task.isCancelled,
                  self.currentAssetID == id,
                  let asset
            else {
                asset?.cancelLoading()
                self.loadingIndicator.stopAnimating()
                self.playButton.isHidden = !self.isVideo
                return
            }
            self.startPlayback(with: asset)
        }
    }

    private func startPlayback(with asset: AVAsset) {
        // Suara tetap terdengar walau sakelar senyap aktif — sama seperti Photos
        // saat video diputar dengan sengaja.
        try? AVAudioSession.sharedInstance().setCategory(.playback)
        try? AVAudioSession.sharedInstance().setActive(true)

        let item = AVPlayerItem(asset: asset)
        // Buffer pendek menjaga start tetap cepat, tetapi cukup panjang agar
        // video tidak berhenti setiap satu detik pada koneksi lambat.
        item.preferredForwardBufferDuration = 2
        let player = AVPlayer(playerItem: item)
        // AVPlayer mempertahankan rate yang diminta dan otomatis melanjutkan
        // setelah buffer maju. Intent pengguna tetap dilacak terpisah di bawah.
        player.automaticallyWaitsToMinimizeStalling = true
        player.isMuted = Self.prefersMuted
        let surface = PhotoVideoSurfaceView(frame: imageView.bounds)
        surface.isUserInteractionEnabled = false
        surface.playerLayer.player = player
        surface.playerLayer.videoGravity = .resizeAspect
        imageView.addSubview(surface)

        // Selesai diputar: kembali ke awal dan tombolnya muncul lagi, seperti
        // Photos — bukan berhenti di frame terakhir tanpa jalan keluar.
        endObserver = playbackNotifications.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: player.currentItem,
            queue: .main
        ) { [weak self, weak player] _ in
            MainActor.assumeIsolated {
                guard let self, let player, self.player === player else { return }
                self.wantsVideoPlayback = false
                player.seek(to: .zero)
                self.playButton.isHidden = false
                self.loadingIndicator.stopAnimating()
                self.reportPlayback()
            }
        }

        // Melapor beberapa kali per detik supaya slider bergerak halus tanpa
        // menuntut pembaruan tiap frame.
        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.25, preferredTimescale: 600),
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.reportPlayback() }
        }

        self.player = player
        self.videoView = surface
        wantsVideoPlayback = true
        playbackStatusObserver = player.observe(
            \.timeControlStatus,
            options: [.initial, .new]
        ) { [weak self] observedPlayer, _ in
            DispatchQueue.main.async { [weak self, weak observedPlayer] in
                guard let self, let observedPlayer,
                      self.player === observedPlayer
                else { return }
                self.updateLoadingIndicator(for: observedPlayer)
                self.reportPlayback()
            }
        }
        playbackKeepUpObserver = item.observe(
            \.isPlaybackLikelyToKeepUp,
            options: [.initial, .new]
        ) { [weak self, weak item] observedItem, _ in
            DispatchQueue.main.async { [weak self, weak item] in
                guard let self, let item,
                      observedItem === item,
                      self.player?.currentItem === item,
                      item.isPlaybackLikelyToKeepUp
                else { return }
                self.resumeVideoPlaybackIfPossible()
            }
        }
        playbackLoadedRangesObserver = item.observe(
            \.loadedTimeRanges,
            options: [.initial, .new]
        ) { [weak self, weak item] observedItem, _ in
            DispatchQueue.main.async { [weak self, weak item] in
                guard let self, let item,
                      observedItem === item,
                      self.player?.currentItem === item
                else { return }
                self.resumeVideoPlaybackIfPossible()
                self.reportPlayback()
            }
        }
        playbackStalledObserver = playbackNotifications.addObserver(
            forName: .AVPlayerItemPlaybackStalled,
            object: item,
            queue: .main
        ) { [weak self, weak item] _ in
            MainActor.assumeIsolated {
                guard let self, let item,
                      self.player?.currentItem === item,
                      self.wantsVideoPlayback
                else { return }
                self.loadingIndicator.startAnimating()
                // Kalau range berikutnya sudah tiba bersamaan dengan notifikasi,
                // lanjutkan sekarang; selain itu observer loadedTimeRanges yang
                // akan menendangnya begitu unduhan bergerak.
                self.resumeVideoPlaybackIfPossible()
                self.reportPlayback()
            }
        }
        playButton.isHidden = true
        player.play()
        reportPlayback()
    }

    private func resumeVideoPlaybackIfPossible() {
        guard wantsVideoPlayback,
              let player,
              let item = player.currentItem,
              item.status == .readyToPlay
        else { return }

        let bufferedAhead = bufferedSecondsAhead(in: item, at: player.currentTime().seconds)
        guard item.isPlaybackLikelyToKeepUp || bufferedAhead > 0.25 else { return }
        player.play()
        playButton.isHidden = true
    }

    private func bufferedSecondsAhead(in item: AVPlayerItem, at time: Double) -> Double {
        guard time.isFinite else { return 0 }
        return item.loadedTimeRanges.reduce(0) { result, value in
            let range = value.timeRangeValue
            let start = range.start.seconds
            let end = CMTimeRangeGetEnd(range).seconds
            guard start.isFinite, end.isFinite,
                  start <= time + 0.05, end > time
            else { return result }
            return max(result, end - time)
        }
    }

    /// `waitingToPlayAtSpecifiedRate` mencakup pemuatan awal dan rebuffering.
    /// Status ini lebih akurat daripada menebak dari durasi atau frame pertama.
    private func updateLoadingIndicator(for player: AVPlayer) {
        if wantsVideoPlayback && player.timeControlStatus != .playing {
            playButton.isHidden = true
            loadingIndicator.startAnimating()
        } else {
            loadingIndicator.stopAnimating()
        }
    }

    /// Menghentikan dan membongkar pemutarnya.
    ///
    /// Dipanggil saat sel didaur ulang DAN saat halaman berpindah: video yang
    /// terus berjalan di halaman yang sudah lewat tetap memakan jaringan dan
    /// menahan sesi audio.
    func stopPlayback() {
        isLivePhotoPressed = false
        wantsVideoPlayback = false
        stopLivePhoto()
        videoLoadTask?.cancel()
        videoLoadTask = nil
        playbackKeepUpObserver?.invalidate()
        playbackKeepUpObserver = nil
        playbackLoadedRangesObserver?.invalidate()
        playbackLoadedRangesObserver = nil
        playbackStatusObserver?.invalidate()
        playbackStatusObserver = nil
        if let playbackStalledObserver {
            playbackNotifications.removeObserver(playbackStalledObserver)
            self.playbackStalledObserver = nil
        }
        loadingIndicator.stopAnimating()
        if let timeObserver, let player {
            player.removeTimeObserver(timeObserver)
        }
        timeObserver = nil
        VideoPlaybackLifecycle.stop(player)
        videoView?.playerLayer.player = nil
        videoView?.removeFromSuperview()
        videoView = nil
        player = nil
        if let endObserver {
            playbackNotifications.removeObserver(endObserver)
            self.endObserver = nil
        }
        playButton.isHidden = !isVideo
        reportPlayback()
    }

    // MARK: Kendali dari bar kontrol

    /// Memutar kalau berhenti, menjeda kalau sedang berjalan.
    func togglePlayPause() {
        guard let player else {
            togglePlayback()
            return
        }
        if wantsVideoPlayback {
            wantsVideoPlayback = false
            player.pause()
            loadingIndicator.stopAnimating()
            playButton.isHidden = false
        } else {
            wantsVideoPlayback = true
            player.play()
            playButton.isHidden = true
            updateLoadingIndicator(for: player)
        }
        reportPlayback()
    }

    /// Bisa ditekan SEBELUM videonya diputar.
    ///
    /// Dulu ini menunggu pemutarnya ada, jadi menekan tombol bisu di video yang
    /// belum dijalankan tidak melakukan apa pun. Pilihannya sekarang disimpan
    /// terpisah dari pemutar, lalu diterapkan begitu pemutarnya dibuat.
    func toggleMute() {
        Self.prefersMuted.toggle()
        player?.isMuted = Self.prefersMuted
        reportPlayback()
    }

    // MARK: - Live Photo

    /// Ditekan-tahan: bagian bergeraknya diputar selama jari menempel.
    @objc private func handleLongPress(_ recognizer: UILongPressGestureRecognizer) {
        switch recognizer.state {
        case .began:
            isLivePhotoPressed = true
            startLivePhoto()
        case .ended, .cancelled, .failed:
            isLivePhotoPressed = false
            stopLivePhoto()
        default: break
        }
    }

    private func startLivePhoto() {
        guard livePlayer == nil,
              livePhotoView == nil,
              liveLoadTask == nil,
              let assetID = currentAssetID,
              let loader
        else { return }

        loadingIndicator.accessibilityLabel = String(localized: "Loading Live Photo")
        loadingIndicator.startAnimating()

        // PhotoKit adalah jalur utama bila salinan perangkat masih ada. Ia
        // merakit pasangan foto + motion dengan timing asli dan juga menangani
        // resource yang sementara berada di iCloud.
        if let localLivePhotoAssetID {
            let scale = max(1, traitCollection.displayScale)
            let points = imageView.bounds.size
            let targetSize = CGSize(
                width: max(1, points.width * scale),
                height: max(1, points.height * scale))
            liveLoadTask = Task { [weak self] in
                let livePhoto = await loader.localLivePhoto(
                    forLocalAssetID: localLivePhotoAssetID,
                    targetSize: targetSize)
                guard !Task.isCancelled, let self else { return }
                self.liveLoadTask = nil
                guard !Task.isCancelled,
                      self.isLivePhotoPressed,
                      self.currentAssetID == assetID,
                      let livePhoto
                else {
                    self.loadingIndicator.stopAnimating()
                    return
                }
                self.startLocalLivePlayback(livePhoto)
            }
            return
        }

        guard let videoID = livePhotoVideoID else {
            loadingIndicator.stopAnimating()
            return
        }
        liveLoadTask = Task { [weak self] in
            // Jalur ini memilih resource PhotoKit bila masih ada di perangkat;
            // URL server hanya fallback. Live Photo lokal jadi terasa instan.
            let asset = await loader.playbackAsset(for: videoID)
            guard !Task.isCancelled, let self else {
                asset?.cancelLoading()
                return
            }
            self.liveLoadTask = nil
            guard !Task.isCancelled,
                  self.isLivePhotoPressed,
                  self.livePhotoVideoID == videoID,
                  let asset
            else {
                asset?.cancelLoading()
                self.loadingIndicator.stopAnimating()
                return
            }
            self.startLivePlayback(with: asset)
        }
    }

    private func startLocalLivePlayback(_ livePhoto: PHLivePhoto) {
        let view = PHLivePhotoView(frame: imageView.bounds)
        view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.isUserInteractionEnabled = false
        view.isMuted = true
        view.livePhoto = livePhoto
        view.alpha = 0
        imageView.addSubview(view)
        livePhotoView = view
        loadingIndicator.stopAnimating()
        view.startPlayback(with: .full)

        UIView.animate(
            withDuration: 0.16,
            delay: 0,
            options: [.beginFromCurrentState, .curveEaseOut]
        ) {
            view.alpha = 1
        }
    }

    private func startLivePlayback(with asset: AVAsset) {
        let item = AVPlayerItem(asset: asset)
        // Klip Live Photo pendek; menunggu buffer besar membuat hold terasa
        // seperti tidak bekerja pada koneksi lambat.
        item.preferredForwardBufferDuration = 0.5
        let player = AVPlayer(playerItem: item)
        player.automaticallyWaitsToMinimizeStalling = false
        // Live Photo selalu senyap — bagian bergeraknya cuma sekejap, dan
        // suaranya justru mengagetkan.
        player.isMuted = true

        let layer = AVPlayerLayer(player: player)
        layer.videoGravity = .resizeAspect
        layer.frame = imageView.bounds
        layer.opacity = 0
        imageView.layer.addSublayer(layer)

        // Selesai berputar, kembali ke fotonya walau jari masih menempel —
        // sama seperti Photos, yang tidak mengulang.
        liveEndObserver = playbackNotifications.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: player.currentItem,
            queue: .main
        ) { [weak self, weak player] _ in
            MainActor.assumeIsolated {
                guard let self, let player, self.livePlayer === player else { return }
                self.stopLivePhoto()
            }
        }

        livePlayer = player
        liveLayer = layer
        livePlaybackStatusObserver = player.observe(
            \.timeControlStatus,
            options: [.initial, .new]
        ) { [weak self, weak player] observedPlayer, _ in
            DispatchQueue.main.async { [weak self, weak player] in
                guard let self, let player,
                      observedPlayer === player,
                      self.livePlayer === player
                else { return }
                self.updateLivePhotoLoading(for: player)
            }
        }
        livePlaybackKeepUpObserver = item.observe(
            \.isPlaybackLikelyToKeepUp,
            options: [.initial, .new]
        ) { [weak self, weak item] observedItem, _ in
            DispatchQueue.main.async { [weak self, weak item] in
                guard let self, let item,
                      observedItem === item,
                      self.isLivePhotoPressed,
                      self.livePlayer?.currentItem === item,
                      item.isPlaybackLikelyToKeepUp,
                      self.livePlayer?.timeControlStatus == .waitingToPlayAtSpecifiedRate
                else { return }
                self.livePlayer?.play()
            }
        }
        player.play()
    }

    private func updateLivePhotoLoading(for player: AVPlayer) {
        guard isLivePhotoPressed else {
            loadingIndicator.stopAnimating()
            return
        }

        switch player.timeControlStatus {
        case .playing:
            loadingIndicator.stopAnimating()
            guard let layer = liveLayer, layer.opacity < 1 else { return }
            // Frame bergerak masuk dengan cross-fade singkat, bukan mengganti
            // foto diam secara mendadak begitu byte pertama tiba.
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = layer.presentation()?.opacity ?? 0
            fade.toValue = 1
            fade.duration = 0.16
            fade.timingFunction = CAMediaTimingFunction(name: .easeOut)
            layer.opacity = 1
            layer.add(fade, forKey: "livePhotoFadeIn")
        case .waitingToPlayAtSpecifiedRate, .paused:
            loadingIndicator.startAnimating()
        @unknown default:
            loadingIndicator.startAnimating()
        }
    }

    private func stopLivePhoto() {
        liveLoadTask?.cancel()
        liveLoadTask = nil
        livePlaybackKeepUpObserver?.invalidate()
        livePlaybackKeepUpObserver = nil
        livePlaybackStatusObserver?.invalidate()
        livePlaybackStatusObserver = nil
        loadingIndicator.stopAnimating()
        if let oldView = livePhotoView {
            oldView.stopPlayback()
            livePhotoView = nil
            UIView.animate(
                withDuration: 0.12,
                delay: 0,
                options: [.beginFromCurrentState, .curveEaseOut]
            ) {
                oldView.alpha = 0
            } completion: { _ in
                oldView.removeFromSuperview()
            }
        }
        VideoPlaybackLifecycle.stop(livePlayer)
        if let oldLayer = liveLayer {
            oldLayer.removeAllAnimations()
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = oldLayer.presentation()?.opacity ?? oldLayer.opacity
            fade.toValue = 0
            fade.duration = 0.12
            fade.timingFunction = CAMediaTimingFunction(name: .easeOut)
            oldLayer.opacity = 0
            oldLayer.add(fade, forKey: "livePhotoFadeOut")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
                oldLayer.removeFromSuperlayer()
            }
        }
        liveLayer = nil
        livePlayer = nil
        if let liveEndObserver {
            playbackNotifications.removeObserver(liveEndObserver)
            self.liveEndObserver = nil
        }
    }

    /// Melompat ke bagian tertentu, 0…1.
    func seek(toFraction fraction: Double) {
        guard let player, let item = player.currentItem else { return }
        let duration = item.duration.seconds
        guard duration.isFinite, duration > 0 else { return }
        let target = CMTime(seconds: duration * min(max(fraction, 0), 1), preferredTimescale: 600)
        player.seek(
            to: target,
            toleranceBefore: .zero,
            toleranceAfter: .zero
        ) { [weak self, weak player] _ in
            DispatchQueue.main.async { [weak self, weak player] in
                guard let self, let player, self.player === player else { return }
                self.resumeVideoPlaybackIfPossible()
                self.reportPlayback()
            }
        }
    }

    /// Keadaan sekarang, untuk digambar bar kontrol.
    var playbackState: PhotoPlaybackState {
        var state = PhotoPlaybackState()
        state.isVideo = isVideo
        state.isMuted = Self.prefersMuted
        // Tombol tetap menunjukkan pause selama rebuffering karena intent user
        // masih play; status waiting bukan permintaan pause.
        state.isPlaying = wantsVideoPlayback
        let itemDuration = player?.currentItem?.duration.seconds ?? .nan
        state.duration = itemDuration.isFinite && itemDuration > 0 ? itemDuration : metadataDuration
        state.time = player?.currentTime().seconds ?? 0
        if let item = player?.currentItem, state.duration > 0 {
            let bufferedEnd = item.loadedTimeRanges.reduce(0.0) { result, value in
                let end = CMTimeRangeGetEnd(value.timeRangeValue).seconds
                return end.isFinite ? max(result, end) : result
            }
            state.bufferedFraction = Float(min(max(bufferedEnd / state.duration, 0), 1))
        }
        return state
    }

    private func reportPlayback() {
        onPlaybackChanged?(playbackState)
    }

    @objc private func handleDoubleTap(_ recognizer: UITapGestureRecognizer) {
        if scrollView.zoomScale > 1 {
            scrollView.setZoomScale(1, animated: true)
            return
        }

        let point = recognizer.location(in: imageView)
        let width = scrollView.bounds.width / 2
        let height = scrollView.bounds.height / 2
        scrollView.zoom(
            to: CGRect(
                x: point.x - width / 2,
                y: point.y - height / 2,
                width: width,
                height: height),
            animated: true)
    }
}

// MARK: - Zoom

extension PhotoPagerCell: UIScrollViewDelegate {
    func viewForZooming(in scrollView: UIScrollView) -> UIView? {
        imageView
    }

    func scrollViewDidZoom(_ scrollView: UIScrollView) {
        guard !isRefitting else { return }
        centerContent()
        reportZoom()
    }

    func scrollViewDidEndZooming(
        _ scrollView: UIScrollView, with view: UIView?, atScale scale: CGFloat
    ) {
        reportZoom()
        // Kalau bounds sempat berubah di tengah pinch (toolbar sembunyi), refit
        // yang tertunda dijalankan sekarang.
        scrollView.setNeedsLayout()
    }
}

// MARK: - Koordinasi gesture

extension PhotoPagerCell: UIGestureRecognizerDelegate {
    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
    ) -> Bool {
        // Long press harus boleh hidup bersama pan recognizer milik pager dan
        // panel info. Swipe nyata tetap membatalkannya lewat allowableMovement.
        true
    }
}

private extension UIEdgeInsets {
    func isApproximatelyEqual(
        to other: UIEdgeInsets,
        tolerance: CGFloat = 0.25
    ) -> Bool {
        abs(top - other.top) <= tolerance
            && abs(left - other.left) <= tolerance
            && abs(bottom - other.bottom) <= tolerance
            && abs(right - other.right) <= tolerance
    }
}

/// `UIScrollView` yang melaporkan `layoutSubviews`, dipakai untuk menghitung
/// ulang ukuran konten saat bounds berubah.
private final class LayoutReportingScrollView: UIScrollView {
    var onLayout: (() -> Void)?

    override func layoutSubviews() {
        super.layoutSubviews()
        onLayout?()
    }
}

/// Memakai AVPlayerLayer sebagai backing layer agar geometri video ikut
/// transaksi animasi UIKit yang mengubah bingkai kontennya.
private final class PhotoVideoSurfaceView: UIView {
    override class var layerClass: AnyClass { AVPlayerLayer.self }

    var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
}
