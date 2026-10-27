import AVFoundation
import SwiftUI

/// Lama satu foto tampil sebelum berpindah sendiri.
private let storyPhotoDuration: Double = 5

/// Kenangan sebagai story layar penuh.
///
/// Dua arah gerak yang berbeda arti: menggeser MENDATAR berpindah foto di dalam
/// satu kenangan, menggeser TEGAK berpindah tahun. Keduanya scroll view bawaan
/// dengan `scrollTargetBehavior(.paging)` yang saling bersarang tegak lurus —
/// bukan `TabView` bersarang, yang gesturnya saling merebut dan membuat salah
/// satu arah berhenti bekerja.
struct MemoryStoryView: View {
    private let sourceStories: [MemoryStory]
    @State private var snapshotGeneration = LocalSnapshot.generation
    private var stories: [MemoryStory] {
        guard snapshotGeneration == LocalSnapshot.generation else { return [] }
        let policy = AssetVisibilityPolicy(scope: .timeline)
        return sourceStories.compactMap { $0.filteringAssets(using: policy) }
    }
    /// Kenangan yang dibuka lebih dulu; nil berarti mulai dari yang terbaru.
    var initialStoryID: String? = nil
    /// Menyiapkan berkas untuk dibagikan.
    ///
    /// Dititipkan pemanggil supaya viewer ini tidak perlu memegang repository
    /// sendiri — pemanggilnya sudah punya satu.
    var prepareShare: (AssetLite) async -> URL?

    init(stories: [MemoryStory], initialStoryID: String? = nil,
         prepareShare: @escaping (AssetLite) async -> URL?) {
        sourceStories = stories
        self.initialStoryID = initialStoryID
        self.prepareShare = prepareShare
    }

    @Environment(\.dismiss) private var dismiss

    @State private var currentStoryID: String?
    /// Foto yang sedang tampil di TIAP kenangan.
    ///
    /// Disimpan per kenangan, bukan satu angka bersama: menggeser ke tahun lain
    /// lalu kembali harus mengembalikan posisi yang tadi ditinggalkan, bukan
    /// melempar balik ke foto pertama.
    @State private var assetIDByStory: [String: String] = [:]
    /// Jari sedang menyentuh layar — story berhenti berjalan selama itu.
    @State private var isPressing = false
    @State private var shareItem: SharedLinkPresentation?
    @State private var sharedAssetID: String?
    @State private var isPreparingShare = false

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            VStack(spacing: 14) {
                progressBar
                pager
                footer
            }
            .padding(.horizontal, 12)
            .padding(.top, 6)
            .padding(.bottom, 4)
        }
        .sheet(item: $shareItem, onDismiss: { sharedAssetID = nil }) { ShareSheet(url: $0.url) }
        .onAppear {
            currentStoryID = initialStoryID ?? stories.first?.id
        }
        .onChange(of: stories.map { $0.assets.map(\.id) }) { _, _ in
            if let sharedAssetID, !AssetVisibilityPolicy(scope: .timeline).allows(id: sharedAssetID) {
                shareItem = nil
                self.sharedAssetID = nil
            }
            if stories.isEmpty {
                dismiss()
            } else if !stories.contains(where: { $0.id == currentStoryID }) {
                currentStoryID = stories.first?.id
            }
        }
    }

    // MARK: - Bar kemajuan

    private var progressBar: some View {
        MemoryStoryProgress(
            storyID: currentStory?.id ?? "",
            count: currentStory?.assets.count ?? 0,
            index: currentAssetIndex,
            // Menyiapkan berkas share juga menahannya: sheet-nya akan muncul di
            // atas story yang diam-diam sudah berpindah foto kalau tidak.
            isPaused: isPressing || isPreparingShare || shareItem != nil,
            duration: currentDuration,
            onFinish: advance)
    }

    /// Video ditampilkan SELAMA durasinya, bukan lima detik seperti foto —
    /// kalau tidak, klip 20 detik akan terpotong di detik kelima.
    private var currentDuration: Double {
        guard let asset = currentAsset, asset.isVideo,
              let duration = asset.duration, duration > 0
        else { return storyPhotoDuration }
        return duration
    }

    // MARK: - Pager tegak: antar kenangan

    private var pager: some View {
        ScrollView(.vertical) {
            LazyVStack(spacing: 0) {
                ForEach(stories) { story in
                    horizontalPager(for: story)
                        .containerRelativeFrame([.horizontal, .vertical])
                        .id(story.id)
                }
            }
            .scrollTargetLayout()
        }
        .scrollTargetBehavior(.paging)
        .scrollPosition(id: $currentStoryID)
        .scrollIndicators(.hidden)
        // `simultaneousGesture`, bukan `gesture`: yang ini hanya IKUT mendengar
        // sentuhan, tidak merebutnya dari scroll view. Dipasang sebagai gestur
        // biasa, menggeser antar foto berhenti bekerja sama sekali.
        .simultaneousGesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in isPressing = true }
                .onEnded { _ in isPressing = false })
        .overlay(alignment: .topLeading) { closeButton }
    }

    // MARK: - Pager mendatar: antar foto dalam satu kenangan

    private func horizontalPager(for story: MemoryStory) -> some View {
        ScrollView(.horizontal) {
            LazyHStack(spacing: 0) {
                ForEach(story.assets) { asset in
                    MemoryStorySlide(
                        asset: asset,
                        isActive: isActive(asset, in: story),
                        isPaused: isPressing)
                        .containerRelativeFrame([.horizontal, .vertical])
                        .id(asset.id)
                }
            }
            .scrollTargetLayout()
        }
        .scrollTargetBehavior(.paging)
        .scrollPosition(id: assetBinding(for: story))
        .scrollIndicators(.hidden)
        // Judulnya milik KENANGAN, bukan milik tiap foto.
        //
        // Sebelumnya ia digambar di dalam tiap halaman, jadi tiap halaman yang
        // dibangun malas oleh `LazyHStack` menata ulang judulnya sendiri —
        // halaman yang dibangun di tengah usapan cepat sempat menerima tawaran
        // lebar yang belum berarti, dan judulnya terpotong di situ saja. Sebagai
        // satu overlay milik kenangan, ia ditata sekali dengan lebar yang sudah
        // pasti.
        // `allowsHitTesting(false)` WAJIB di sini.
        //
        // Sebagai overlay, judulnya berada di LUAR scroll view mendatar —
        // berbeda dari waktu ia masih di dalam halaman. Teks dan gradiennya
        // menangkap sentuhan, dan pita selebar layar setinggi ±130 titik di
        // bagian bawah kartu berhenti bisa diusap antar foto.
        .overlay(alignment: .bottom) { caption(story.title).allowsHitTesting(false) }
        .clipShape(RoundedRectangle(cornerRadius: 28))
    }

    private func caption(_ title: String) -> some View {
        Text(title)
            .font(.largeTitle.bold())
            // Nama seperti "10 years ago" pada ukuran teks besar tidak muat satu
            // baris; dikecilkan sedikit jauh lebih baik daripada dipotong.
            .lineLimit(1)
            .minimumScaleFactor(0.6)
            .foregroundStyle(.white)
            .shadow(radius: 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            // Sudut kartunya membulat 28; teks yang terlalu mepet kiri-bawah
            // akan tersenggol lengkung itu.
            .padding(.horizontal, 28)
            .padding(.bottom, 32)
            .padding(.top, 60)
            .background(
                LinearGradient(
                    colors: [.clear, .black.opacity(0.45)],
                    startPoint: .top,
                    endPoint: .bottom))
    }

    /// Halaman yang benar-benar sedang dilihat — hanya ini yang boleh memutar
    /// video; sisanya dibangun `LazyHStack` tapi harus diam.
    private func isActive(_ asset: AssetLite, in story: MemoryStory) -> Bool {
        story.id == currentStory?.id && asset.id == currentAsset?.id
    }

    /// Posisi foto milik satu kenangan, dibungkus jadi binding tersendiri.
    private func assetBinding(for story: MemoryStory) -> Binding<String?> {
        Binding(
            get: { assetIDByStory[story.id] ?? story.assets.first?.id },
            set: { assetIDByStory[story.id] = $0 })
    }

    // MARK: - Chrome

    private var closeButton: some View {
        Button {
            dismiss()
        } label: {
            Image(systemName: "xmark")
                .font(.headline)
                .foregroundStyle(.white)
                .frame(width: 40, height: 40)
                .background(.black.opacity(0.35), in: .circle)
        }
        .padding(16)
    }

    private var footer: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(currentStory?.title ?? "")
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.7))
                Text(currentStory?.subtitle ?? "")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.white)
            }
            .lineLimit(1)

            Spacer(minLength: 8)

            shareButton
        }
        .padding(.horizontal, 8)
    }

    private var shareButton: some View {
        Button {
            share()
        } label: {
            ZStack {
                // Ikonnya TIDAK diganti spinner, hanya disamarkan.
                //
                // Menukar isi tombol mengubah ukurannya, dan tombol yang
                // berkedut ukurannya saat ditekan terlihat seperti salah gambar.
                Image(systemName: "square.and.arrow.up")
                    .font(.headline)
                    .opacity(isPreparingShare ? 0 : 1)
                if isPreparingShare {
                    ProgressView().tint(.white)
                }
            }
            .foregroundStyle(.white)
            .frame(width: 44, height: 44)
            .background(.white.opacity(0.15), in: .circle)
        }
        .disabled(currentAsset == nil)
    }

    // MARK: - Keadaan sekarang

    private var currentStory: MemoryStory? {
        guard let currentStoryID else { return stories.first }
        return stories.first { $0.id == currentStoryID } ?? stories.first
    }

    private var currentAssetIndex: Int {
        guard let story = currentStory,
              let id = assetIDByStory[story.id],
              let index = story.assets.firstIndex(where: { $0.id == id })
        else { return 0 }
        return index
    }

    private var currentAsset: AssetLite? {
        guard let story = currentStory, story.assets.indices.contains(currentAssetIndex)
        else { return nil }
        return story.assets[currentAssetIndex]
    }

    // MARK: - Perpindahan

    /// Foto berikutnya; kalau sudah habis, tahun berikutnya; kalau itu pun
    /// habis, story-nya tutup sendiri.
    private func advance() {
        guard let story = currentStory else { return }

        let next = currentAssetIndex + 1
        if next < story.assets.count {
            withAnimation(.easeInOut(duration: 0.28)) {
                assetIDByStory[story.id] = story.assets[next].id
            }
            return
        }

        guard let storyIndex = stories.firstIndex(where: { $0.id == story.id }),
              storyIndex + 1 < stories.count
        else {
            dismiss()
            return
        }

        // Kenangan berikutnya selalu dimulai dari foto pertamanya — ini bukan
        // "kembali ke tahun yang tadi ditinggalkan", melainkan lanjutan.
        let following = stories[storyIndex + 1]
        assetIDByStory[following.id] = following.assets.first?.id
        withAnimation(.easeInOut(duration: 0.32)) {
            currentStoryID = following.id
        }
    }

    private func share() {
        guard let asset = currentAsset, !isPreparingShare else { return }
        isPreparingShare = true
        Task {
            let url = await prepareShare(asset)
            isPreparingShare = false
            guard let url else { return }
            guard !Task.isCancelled, snapshotGeneration == LocalSnapshot.generation,
                  AssetVisibilityPolicy(scope: .timeline).allows(id: asset.id) else {
                TemporaryMediaStore.remove(url)
                return
            }
            sharedAssetID = asset.id
            shareItem = SharedLinkPresentation(url: url)
        }
    }
}

// MARK: - Satu halaman

private struct MemoryStorySlide: View {
    let asset: AssetLite
    /// Halaman ini yang sedang dilihat.
    let isActive: Bool
    /// Jari sedang menahan layar.
    let isPaused: Bool

    @Environment(SessionManager.self) private var session

    var body: some View {
        ZStack {
            // TIGA lapis, tapi hanya DUA permintaan jaringan.
            //
            // Sebelumnya latar buram meminta `preview` dengan ukuran decode
            // sendiri (400px). Kunci cache memori memuat ukuran decode-nya, jadi
            // itu bukan permintaan yang sama dengan `preview` di depannya — tiap
            // slide mengunduh preview 2048px DUA KALI. `LazyHStack` menyiapkan
            // beberapa slide sekaligus dan pager tegak menyiapkan beberapa
            // kenangan sekaligus, sementara jatah kerja berat cuma empat: yang
            // sedang dilihat mengantre di belakang belasan unduhan besar untuk
            // halaman yang belum tentu dibuka. Itulah "buram lama"; pada
            // pembukaan kedua semuanya sudah di cache, jadi terlihat normal.
            //
            // Sekarang latar dan lapis cepat memakai THUMBNAIL — kecil, cepat,
            // dan kunci cache-nya sama persis untuk keduanya sehingga hanya satu
            // unduhan yang benar-benar jalan.
            AuthImage(assetId: asset.id, thumbhash: asset.thumbhash)
                .blur(radius: 40)
                .overlay(Color.black.opacity(0.25))

            // Lapis cepat: foto sungguhan muncul dalam sekejap, meski belum
            // tajam. Tanpa ini yang terlihat cuma buram thumbhash sampai preview
            // penuh selesai diunduh.
            AuthImage(
                assetId: asset.id,
                thumbhash: asset.thumbhash,
                contentMode: .fit)

            // Lapis tajam, menimpa yang cepat begitu datang.
            //
            // Bingkai video pun tetap menumpang di atasnya: frame pertama baru
            // datang setelah beberapa ratus milidetik, dan tanpa gambar di
            // belakangnya yang terlihat adalah kotak hitam yang berkedip di
            // setiap perpindahan halaman.
            AuthImage(
                assetId: asset.id,
                size: "preview",
                thumbhash: asset.thumbhash,
                contentMode: .fit,
                // Kartunya tidak pernah lebih lebar dari layar; 1400px sudah
                // melampaui itu di layar 3x, sementara membongkar 2048px berarti
                // beberapa kali lipat memori dan waktu decode untuk ketajaman
                // yang tidak bisa dilihat.
                pixelSize: 1400)

            if asset.isVideo {
                MemoryStoryVideo(
                    assetID: asset.id,
                    isActive: isActive,
                    isPaused: isPaused,
                    session: session)
            }
        }
    }
}

// MARK: - Video

/// Pemutar video story.
///
/// `AVPlayerLayer` sendiri, bukan `VideoPlayer` bawaan SwiftUI: byte videonya
/// diambil `AVPlayer` di luar `APIClient`, jadi header autentikasinya harus
/// dititipkan ke `AVURLAsset` — dan `VideoPlayer` tidak menyediakan celah untuk
/// itu. Kontrol bawaannya pun tidak diinginkan di sini; story dikendalikan
/// dengan tahan dan usap, bukan tombol.
private struct MemoryStoryVideo: UIViewRepresentable {
    let assetID: String
    let isActive: Bool
    let isPaused: Bool
    let session: SessionManager

    func makeUIView(context: Context) -> MemoryStoryVideoView {
        MemoryStoryVideoView()
    }

    func updateUIView(_ view: MemoryStoryVideoView, context: Context) {
        view.update(
            assetID: assetID,
            session: session,
            isActive: isActive,
            isPaused: isPaused)
    }

    static func dismantleUIView(_ view: MemoryStoryVideoView, coordinator: ()) {
        view.teardown()
    }
}

final class MemoryStoryVideoView: UIView {
    override class var layerClass: AnyClass { AVPlayerLayer.self }

    private var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
    private var player: AVPlayer?
    private var loadedAssetID: String?
    private var endObserver: NSObjectProtocol?
    /// Halaman ini sedang aktif pada pembaruan sebelumnya.
    ///
    /// Dipakai untuk membedakan "lanjutkan setelah jeda" dari "masuk lagi ke
    /// halaman ini". Tanpa itu, kembali ke slide video melanjutkan klip dari
    /// tengah sementara bar kemajuannya mulai lagi dari nol — keduanya berjalan
    /// sendiri-sendiri.
    private var wasActive = false

    @MainActor
    func update(assetID: String, session: SessionManager, isActive: Bool, isPaused: Bool) {
        // Pemutar baru dibuat saat halamannya benar-benar dilihat.
        //
        // `LazyHStack` membangun beberapa halaman sekaligus di kiri dan kanan;
        // menyiapkan pemutar untuk semuanya berarti beberapa unduhan video
        // berjalan bersamaan demi satu yang ditonton.
        guard isActive else {
            teardown()
            return
        }

        if loadedAssetID != assetID {
            teardown()
            loadedAssetID = assetID
            makePlayer(assetID: assetID, session: session)
        }

        guard let player else { return }
        if isPaused {
            player.pause()
        } else if player.timeControlStatus != .playing {
            // Baru masuk lagi ke halaman ini: klipnya diulang dari awal supaya
            // sejalan dengan bar kemajuan, yang juga dimulai dari nol.
            if !wasActive { player.seek(to: .zero) }
            player.play()
        }
        wasActive = true
    }

    func teardown() {
        VideoPlaybackLifecycle.stop(player)
        if let endObserver {
            NotificationCenter.default.removeObserver(endObserver)
            self.endObserver = nil
        }
        playerLayer.player = nil
        player = nil
        loadedAssetID = nil
        wasActive = false
    }

    @MainActor
    private func makePlayer(assetID: String, session: SessionManager) {
        guard let source = PhotoPreviewLoader(session: session).videoSource(for: assetID)
        else { return }

        let urlAsset = AVURLAsset(
            url: source.url,
            options: ["AVURLAssetHTTPHeaderFieldsKey": source.headers])
        let item = AVPlayerItem(asset: urlAsset)
        item.preferredForwardBufferDuration = 2
        let newPlayer = AVPlayer(playerItem: item)
        // Bisu: story berpindah sendiri, dan suara yang menyala tiba-tiba saat
        // baris kenangan disentuh bukan yang diharapkan siapa pun.
        newPlayer.isMuted = true

        // Klip yang lebih pendek dari perkiraan durasinya diulang, bukan
        // dibiarkan berhenti di frame terakhir sampai bar kemajuannya habis.
        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: newPlayer.currentItem,
            queue: .main
        ) { [weak newPlayer] _ in
            newPlayer?.seek(to: .zero)
            newPlayer?.play()
        }

        playerLayer.videoGravity = .resizeAspect
        playerLayer.player = newPlayer
        player = newPlayer
    }
}

// MARK: - Bar kemajuan

/// Deret segmen di puncak story.
///
/// View TERSENDIRI, dan itu yang menentukan: isinya diperbarui puluhan kali per
/// detik supaya segmennya terisi mulus. Kalau kemajuannya disimpan di viewer,
/// seluruh story — dua pager bersarang dan semua fotonya — ikut dibangun ulang
/// sesering itu juga.
private struct MemoryStoryProgress: View {
    /// Kenangan mana yang sedang dihitung — BUKAN cuma nomor fotonya.
    ///
    /// Berpindah tahun hampir selalu mendarat di foto nomor 0, sama seperti
    /// sebelumnya. Kalau yang dibandingkan hanya nomornya, hitungan lama
    /// dianggap masih berjalan: kenangan berisi satu foto langsung terlewat
    /// karena `elapsed` sudah penuh, dan dua kenangan satu-foto berturut-turut
    /// membuat story berhenti sama sekali — kuncinya tidak berubah, jadi
    /// hitungannya tidak pernah dimulai lagi.
    let storyID: String
    let count: Int
    let index: Int
    let isPaused: Bool
    let duration: Double
    let onFinish: () -> Void

    @State private var elapsed: Double = 0
    /// Foto yang sedang dihitung mundur, untuk tahu kapan hitungannya harus
    /// dimulai dari nol dan kapan hanya dilanjutkan setelah jeda.
    @State private var running: Position?

    /// 1/30 detik: cukup mulus untuk mata, dan jauh lebih murah daripada
    /// mengikuti kecepatan layar.
    private let tick: Double = 1.0 / 30.0

    var body: some View {
        HStack(spacing: 4) {
            ForEach(0..<max(count, 0), id: \.self) { segment in
                Capsule()
                    .fill(.white.opacity(0.3))
                    .frame(height: 3)
                    .overlay(alignment: .leading) {
                        GeometryReader { proxy in
                            Capsule()
                                .fill(.white)
                                .frame(width: proxy.size.width * fill(for: segment))
                        }
                    }
            }
        }
        .frame(height: 3)
        .padding(.horizontal, 8)
        .task(id: TickKey(storyID: storyID, index: index, paused: isPaused, count: count)) {
            await run()
        }
    }

    private func fill(for segment: Int) -> Double {
        if segment < index { return 1 }
        if segment > index { return 0 }
        guard duration > 0 else { return 1 }
        return min(max(elapsed / duration, 0), 1)
    }

    private func run() async {
        let position = Position(storyID: storyID, index: index)
        if running != position {
            running = position
            elapsed = 0
        }
        // Dijeda: task dibiarkan selesai dan `elapsed` tetap tersimpan, jadi
        // saat jari dilepas hitungannya menyambung, bukan mulai dari awal.
        guard !isPaused, count > 0 else { return }

        while elapsed < duration {
            try? await Task.sleep(for: .seconds(tick))
            guard !Task.isCancelled else { return }
            elapsed += tick
        }
        onFinish()
    }

    /// Kunci gabungan supaya `task` dimulai ulang saat foto berganti, saat
    /// kenangannya berganti, MAUPUN saat jeda berubah — ketiganya sama-sama
    /// harus menghentikan hitungan lama.
    private struct TickKey: Equatable {
        let storyID: String
        let index: Int
        let paused: Bool
        let count: Int
    }

    /// Foto keberapa di kenangan yang mana — inilah satuan yang menentukan
    /// hitungan harus dimulai dari nol.
    private struct Position: Equatable {
        let storyID: String
        let index: Int
    }
}
