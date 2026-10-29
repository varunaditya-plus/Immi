import SwiftUI

/// Foto profil pengguna, dengan inisial sebagai dasarnya.
///
/// Inisial SELALU digambar lebih dulu dan fotonya menimpa begitu ada. Immich
/// tidak mewajibkan pengguna punya foto profil, dan yang punya pun tidak selalu
/// fotonya sudah ada di perangkat ini — jadi tidak pernah ada petak abu-abu atau
/// ikon rusak di toolbar, cukup huruf yang berganti jadi foto.
///
/// Fotonya lewat `ImageCache` yang sama dengan seluruh gambar lain: sekali
/// diunduh, ia dijawab dari memori atau disk sampai penggunanya benar-benar
/// menggantinya di server (lihat `UserResponseDTO.profileImageCacheKey`).
@MainActor
struct ProfileAvatar: View {
    enum Style {
        /// Tombol kecil di toolbar Library.
        case toolbar
        /// Kepala besar di sheet pengaturan.
        case header
    }

    var style: Style = .toolbar

    /// Ikut menunjukkan keadaan pencadangan.
    ///
    /// **Kenapa menumpang di sini, bukan tombol tersendiri.** Toolbar Photos dan
    /// Library hanya punya beberapa titik singgah, dan pencadangan bukan sesuatu
    /// yang ditekan tiap hari — ia sesuatu yang ingin dilihat sekilas. Ikon
    /// kedua di sebelah avatar mengambil ruang permanen untuk kabar yang
    /// biasanya berbunyi "semuanya beres".
    ///
    /// Aksinya TIDAK berubah: menekannya tetap membuka pengaturan. Yang berubah
    /// hanya rupanya.
    var showsBackupState = false
    /// Coach mark login pertama memakai avatar sebagai jangkar visual. Cincin
    /// ini sengaja terpisah dari indikator upload: journey hanya aktif sebelum
    /// backup disetel, jadi kedua animasi tidak saling berebut perhatian.
    var isJourneyHighlighted = false

    @Environment(SessionManager.self) private var session
    @State private var backup = BackupService.shared
    @State private var isRingRotating = false
    @State private var isJourneyPulsing = false
    /// Alasannya sama seperti di `AuthImage`: bitmap-nya milik cache, view ini
    /// hanya perlu digambar ulang saat pemuatannya selesai. Nilainya HARUS ikut
    /// dibaca di `body` supaya ketergantungannya benar-benar terbentuk.
    @State private var revision = 0

    var body: some View {
        avatarCircle
            .overlay { uploadingRing }
            .overlay { journeyRing }
            .animation(.smooth(duration: 0.3), value: isUploading)
            .task(id: cacheKey) { await load() }
    }

    private var avatarCircle: some View {
        let shown = cachedImage(revision: revision)

        return initialsCircle
            .overlay {
                if let shown {
                    Image(uiImage: shown)
                        .resizable()
                        .scaledToFill()
                }
            }
            .clipShape(.circle)
            .overlay(alignment: .bottomTrailing) { backupIndicator }
    }

    /// Foto profil tetap menjadi jangkar visual selama backup. Gerakan hanya
    /// hidup di tepinya, sehingga status upload terlihat tanpa mengganti wajah
    /// pengguna dengan ikon lain.
    @ViewBuilder
    private var uploadingRing: some View {
        if isUploading {
            Circle()
                .trim(from: 0.06, to: 0.78)
                .stroke(
                    AngularGradient(
                        colors: [
                            Color.orange.opacity(0.12),
                            Color.orange,
                            Color.orange.opacity(0.12)
                        ],
                        center: .center),
                    style: StrokeStyle(
                        lineWidth: style == .toolbar ? 3 : 5,
                        lineCap: .round))
                .padding(style == .toolbar ? 1.5 : 2.5)
                .rotationEffect(.degrees(isRingRotating ? 360 : 0))
                .animation(
                    .linear(duration: 1.05).repeatForever(autoreverses: false),
                    value: isRingRotating)
                .transition(.opacity)
                .onAppear { isRingRotating = true }
                .onDisappear { isRingRotating = false }
        }
    }

    /// Titik kecil di sudut avatar; nil kalau tidak ada yang perlu dikabarkan.
    ///
    /// Sengaja hanya TITIK, bukan ikon. Ia duduk di atas foto wajah seseorang —
    /// apa pun yang lebih besar dari ini akan menutupi bagian yang justru jadi
    /// alasan avatarnya ada.
    @ViewBuilder
    private var backupIndicator: some View {
        if showsBackupState, !backup.isUploading,
           backup.isEnabled, backup.remainder > 0 {
            Circle()
                .fill(.orange)
                .frame(width: side * 0.28, height: side * 0.28)
                // Cincin sewarna latar memisahkannya dari foto di belakangnya;
                // tanpa itu titik oranye di atas foto oranye lenyap.
                .overlay(Circle().strokeBorder(Color(.systemBackground), lineWidth: 1.5))
        }
    }

    private var isUploading: Bool {
        showsBackupState && backup.isUploading
    }

    @ViewBuilder
    private var journeyRing: some View {
        if isJourneyHighlighted {
            Circle()
                .stroke(Color.accentColor, lineWidth: 3)
                .padding(-3)
                .scaleEffect(isJourneyPulsing ? 1.18 : 1)
                .opacity(isJourneyPulsing ? 0.18 : 0.95)
                .animation(
                    .easeInOut(duration: 0.9).repeatForever(autoreverses: true),
                    value: isJourneyPulsing)
                .onAppear { isJourneyPulsing = true }
                .onDisappear { isJourneyPulsing = false }
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }

    private var side: CGFloat {
        style == .toolbar ? Self.toolbarSide : 116
    }

    // MARK: - Inisial

    /// Latarnya dipasang SESUDAH padding/frame, bukan langsung di teksnya:
    /// lingkarannya harus selebar bidang yang sudah diberi ruang, bukan selebar
    /// hurufnya.
    @ViewBuilder
    private var initialsCircle: some View {
        switch style {
        case .toolbar:
            // Ukuran TETAP, bukan `padding()` mengikuti hurufnya: dengan padding,
            // pengguna berinisial satu huruf mendapat lingkaran yang lebih sempit
            // daripada yang berinisial dua — bulatnya tidak pernah sama.
            Text(initials)
                .font(.title3.weight(.semibold))
                .foregroundStyle(.white)
                .frame(width: Self.toolbarSide, height: Self.toolbarSide)
                .background(Self.gradient, in: .circle)
        case .header:
            Text(initials)
                .font(.system(size: 48, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 116, height: 116)
                .background(Self.gradient, in: .circle)
        }
    }

    private static let toolbarSide: CGFloat = 42

    private static let gradient = LinearGradient(
        colors: [.cyan, .blue, .indigo],
        startPoint: .topLeading,
        endPoint: .bottomTrailing)

    private var initials: String {
        let name = session.currentUser?.name ?? "?"
        let parts = name.split(separator: " ").prefix(2)
        let letters = parts.compactMap { $0.first }.map(String.init)
        return letters.isEmpty ? "?" : letters.joined().uppercased()
    }

    // MARK: - Foto

    /// nil kalau penggunanya memang tidak punya foto profil — dan itu juga yang
    /// membuat `task` di bawah tidak mengunduh apa pun.
    private var cacheKey: String? {
        guard let user = session.currentUser, user.hasProfileImage else { return nil }
        return user.profileImageCacheKey
    }

    /// Sisi terpanjang yang benar-benar dibutuhkan di layar; avatar toolbar tidak
    /// perlu bitmap seukuran kepala di sheet pengaturan.
    private var pixelSize: Int {
        switch style {
        case .toolbar: 180
        case .header: 400
        }
    }

    /// Selalu dari cache, tidak pernah dari state view.
    ///
    /// - Parameter revision: isinya TIDAK dipakai — ia parameter supaya
    ///   pembacaannya terjadi di `body` dan tidak bisa hilang.
    private func cachedImage(revision: Int) -> UIImage? {
        guard let cacheKey else { return nil }
        return ImageMemoryCache.shared.image(
            for: ImageCache.memoryKey(cacheKey, pixelSize))
    }

    private func load() async {
        guard let user = session.currentUser, user.hasProfileImage else { return }

        let key = user.profileImageCacheKey
        // Sudah tergambar dari cache di `body`; tidak ada yang perlu dikerjakan.
        if ImageMemoryCache.shared.image(for: ImageCache.memoryKey(key, pixelSize)) != nil {
            return
        }

        let api = session.imageAPI
        let endpoint = Endpoint(path: "/users/\(user.id)/profile-image")

        _ = try? await ImageCache.shared.image(
            key: key,
            maxPixelSize: pixelSize,
            fetch: { try await api.rawData(endpoint) })

        // Gagal pun tidak apa-apa: inisialnya sudah di layar, dan menaikkan
        // penanda hanya menggambar ulang hal yang sama.
        revision &+= 1
    }
}

#Preview {
    VStack(spacing: 24) {
        ProfileAvatar(style: .toolbar)
        ProfileAvatar(style: .header)
    }
    .environment(SessionManager())
}
