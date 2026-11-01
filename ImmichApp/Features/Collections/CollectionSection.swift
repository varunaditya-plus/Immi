import SwiftUI

/// Konstanta di level file, bukan `static let` di dalam `CollectionSection`:
/// tipe itu generik, dan Swift tidak mengizinkan properti tersimpan statis di
/// tipe generik.
private let collectionSectionCollapseDuration: Double = 0.32

/// Satu baris koleksi yang bisa dilipat.
///
/// Judulnya punya DUA aksi terpisah, seperti di Photos: menekan judulnya
/// mendorong ke layar lengkapnya, sedangkan tombol bulat di kanan hanya
/// membuka/menutup isinya di tempat.
struct CollectionSection<Destination: View, Content: View>: View {
    let title: LocalizedStringKey
    @Binding var isExpanded: Bool
    let isEmpty: Bool
    /// Tinggi isi saat terbuka. Harus diberikan eksplisit — lihat catatan di
    /// `contentArea`.
    let contentHeight: CGFloat
    var emptyMessage: LocalizedStringKey? = nil
    var isLoading = false
    var showsLoadError = false
    var onRetry: (() -> Void)? = nil
    @ViewBuilder let destination: () -> Destination
    @ViewBuilder let content: () -> Content

    /// Klip hanya dipasang selama tingginya belum sesuai isinya.
    ///
    /// Klip permanen memotong animasi zoom context menu saat kartu ditekan
    /// lama — pratinjaunya membesar melewati batas baris dan terpangkas. Klipnya
    /// sendiri cuma dibutuhkan sewaktu melipat, jadi dilepas setelah baris
    /// selesai terbuka.
    @State private var clipsContent = true

    /// Penahan sementara supaya isi baris tidak dilepas SEBELUM animasi lipatnya
    /// selesai.
    ///
    /// `nil` berarti "ikut `isExpanded`" — dan itulah nilai awalnya, supaya
    /// baris yang memang terbuka sudah terisi sejak gambar pertama, bukan
    /// menunggu `onAppear` dan berkedip kosong sekejap.
    @State private var buildsContentOverride: Bool?

    /// Penomor lipatan, supaya timer milik lipatan LAMA tidak melepas penahan
    /// milik lipatan yang baru.
    ///
    /// Tanpa ini, buka-tutup cepat bisa membuat timer dari tutupan pertama bangun
    /// di tengah animasi tutupan kedua — dan kartunya lenyap seketika, persis
    /// yang mau dicegah penahan ini.
    @State private var collapseGeneration = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.layoutDirection) private var layoutDirection

    /// Isi hanya dibangun untuk baris yang terbuka.
    ///
    /// Inilah pengganti `LazyHStack`: baris yang tertutup tidak membangun apa
    /// pun — tidak ada thumbnail yang diunduh atau didecode untuk sesuatu yang
    /// tidak terlihat — sementara baris yang terbuka membangun SEMUA kartunya,
    /// jadi tidak ada lagi kartu yang tertinggal tak pernah dibangun.
    ///
    /// Jumlahnya dibatasi 15 per baris di view model, jadi "semua" di sini
    /// memang cuma belasan kartu.
    private var buildsContent: Bool {
        buildsContentOverride ?? isExpanded
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            // Section kosong tetap menjadi pintu ke layar lengkapnya, tetapi
            // tidak menawarkan aksi lipat untuk isi yang memang tidak ada.
            if isExpanded, showsLoadError {
                HStack {
                    Label("Failed to Load", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.secondary)
                    Spacer()
                    if let onRetry {
                        Button("Retry", action: onRetry)
                            .accessibilityLabel(Text("Retry \(Text(title))"))
                    }
                }
                .font(.subheadline)
                .padding(.horizontal, 20)
                .padding(.top, 12)
            } else if isExpanded, isLoading {
                ProgressView("Loading…")
                    .padding(.horizontal, 20)
                    .padding(.top, 12)
            } else if isEmpty, isExpanded, let emptyMessage {
                Text(emptyMessage)
                    .foregroundStyle(.secondary)
                    .font(.subheadline)
                    .padding(.horizontal, 20)
                    .padding(.top, 12)
            } else if !isEmpty {
                contentArea
            }
        }
    }

    /// Isi TIDAK dilepas dari hierarki saat tertutup, hanya tingginya
    /// dianimasikan ke nol lalu dipotong.
    ///
    /// Dengan `if isExpanded` + `.transition`, SwiftUI menyisipkan dan melepas
    /// view-nya: tinggi baris melompat seketika sementara isinya memudar, dan
    /// baris-baris di bawahnya ikut tersentak. Menganimasikan tinggi ke angka
    /// yang pasti membuat semuanya bergerak serempak — dan itulah sebabnya
    /// tingginya perlu diketahui di muka, bukan diserahkan ke layout.
    private var contentArea: some View {
        // Isi baris digulung mendatar; scroll indicator dimatikan supaya tidak
        // menumpuk dengan baris di bawahnya.
        ScrollView(.horizontal, showsIndicators: false) {
            // `HStack`, BUKAN `LazyHStack`.
            //
            // Versi lazy pernah dipakai di sini untuk satu tujuan yang
            // benar: baris yang terlipat tidak boleh ikut mengunduh dan
            // mendecode belasan thumbnail untuk sesuatu yang tidak
            // terlihat sama sekali.
            //
            // Tapi cara kerjanya salah untuk baris ini. Lazy stack hanya
            // membangun apa yang masuk kotak terlihat, dan kotak itu ia
            // hitung dari ukuran scroll view-nya. Di sini ukuran itu
            // datang dari `frame` yang sedang DIANIMASIKAN — baris ini
            // muncul bertahap lalu tingginya tumbuh dari nol — jadi saat
            // isinya dibangun kotaknya masih belum berarti apa-apa.
            // Hasilnya cuma satu-dua kartu yang pernah dibangun, dan
            // sisanya tidak pernah menyusul. Itulah kenapa sampul album
            // muncul di layar Albums tapi tidak di baris ini: di sana
            // gridnya ada di scroll view biasa yang ukurannya pasti.
            //
            // Yang mau dihindari sebenarnya bukan "kartu di luar layar",
            // melainkan "baris yang tertutup". Jadi itu yang dijadikan
            // syarat — lihat `buildsContent`.
            HStack(alignment: .top, spacing: 12) {
                if buildsContent {
                    content()
                }
            }
            .padding(.horizontal, 20)
        }
        // ScrollView SELALU memotong isinya, dan itulah yang memangkas
        // pratinjau context menu saat kartu ditekan lama — pratinjaunya
        // membesar melewati tepi baris lalu terpotong rata.
        //
        // Mematikan klipnya aman di sini: isinya setinggi baris, jadi
        // yang bisa meluber hanya ke samping — dan di sana sudah ada
        // tepi layar.
        .scrollClipDisabled()
        .frame(height: isExpanded ? contentHeight : 0, alignment: .top)
        .opacity(isExpanded ? 1 : 0)
        // Satu modifier yang selalu terpasang, hanya bentuknya yang berubah —
        // membungkusnya dengan `if` akan mengganti identitas view dan membuat
        // animasi lipatnya patah.
        .clipShape(Rectangle().inset(by: clipsContent ? 0 : -600))
        // Sentuhan dimatikan saat tertutup supaya sisa area setinggi nol tidak
        // menangkap ketukan.
        .allowsHitTesting(isExpanded)
        .padding(.top, isExpanded ? 12 : 0)
        .onAppear { clipsContent = !isExpanded }
        .onChange(of: isExpanded) { _, expanded in
            // Menutup: klip dipasang seketika, karena isinya langsung lebih
            // tinggi dari framenya yang menyusut.
            if reduceMotion {
                clipsContent = !expanded
                buildsContentOverride = nil
                return
            }
            guard expanded else {
                clipsContent = true
                // Isinya DITAHAN dulu. Melepasnya sekarang berarti kartunya
                // lenyap seketika sementara tinggi barisnya baru menyusut —
                // yang terlihat baris kosong yang mengempis, bukan isi yang
                // ikut tergulung.
                buildsContentOverride = true
                collapseGeneration += 1
                let generation = collapseGeneration
                Task {
                    try? await Task.sleep(
                        for: .seconds(collectionSectionCollapseDuration + 0.1))
                    // Kalau sudah dibuka lagi sebelum waktunya habis, atau sudah
                    // ada lipatan yang lebih baru, penahannya dibiarkan —
                    // `isExpanded` yang berlaku.
                    guard !isExpanded, generation == collapseGeneration else { return }
                    buildsContentOverride = nil
                }
                return
            }
            // Membuka: penahan dilepas supaya `buildsContent` kembali mengikuti
            // `isExpanded`, dan klipnya dilepas setelah frame-nya selesai
            // tumbuh.
            buildsContentOverride = nil
            clipsContent = true
            Task {
                try? await Task.sleep(for: .seconds(collectionSectionCollapseDuration + 0.1))
                if isExpanded { clipsContent = false }
            }
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            NavigationLink {
                destination()
            } label: {
                HStack(spacing: 4) {
                    Text(title)
                        .font(.title2.bold()).lineLimit(1).minimumScaleFactor(0.5)
                    // Hanya tampil saat barisnya terbuka — sewaktu tertutup
                    // tidak ada isi yang bisa "dilihat selengkapnya", jadi
                    // panah itu cuma mengundang salah tekan.
                    if !isEmpty {
                        Image(systemName: "chevron.forward")
                            .font(.subheadline.weight(.bold))
                            .foregroundStyle(.secondary)
                    }

                    // Spacer ada DI DALAM tautan, bukan di sebelahnya: dengan
                    // begitu seluruh sisa lebar baris ikut jadi area tekan,
                    // bukan hanya seluas tulisannya.
                    Spacer(minLength: 8)

                    if isEmpty {
                        Image(systemName: "chevron.forward")
                            .font(.footnote.weight(.bold))
                            .foregroundStyle(.secondary)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if !isEmpty && !isLoading && !showsLoadError {
                Button {
                    // `.smooth` meredam sisa gerakan di ujung animasi, jadi baris
                    // di bawahnya tidak berhenti mendadak seperti pada easeInOut.
                    withAnimation(reduceMotion ? nil : .smooth(duration: collectionSectionCollapseDuration)) {
                        isExpanded.toggle()
                    }
                } label: {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(.blue)
                        // Ikon yang sama diputar, bukan diganti: perputarannya bisa
                        // dianimasikan, sedangkan pergantian simbol akan berkedip.
                        .rotationEffect(.degrees(isExpanded ? 0 : (layoutDirection == .rightToLeft ? 90 : -90)))
                        .frame(width: 28, height: 28)
                        .background(.fill.tertiary, in: .circle)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(isExpanded ? Text("Collapse \(Text(title))") : Text("Expand \(Text(title))"))
                .accessibilityValue(isExpanded ? Text("Expanded") : Text("Collapsed"))
            }
        }
        .padding(.horizontal, 20)
    }
}

// MARK: - Kartu isi

struct MemoryCard: View {
    let story: MemoryStory
    /// nil berarti mengisi lebar yang tersedia — dipakai grid, yang lebar
    /// kolomnya ditentukan layar. Angka tetap 180 untuk baris mendatar di
    /// Library, yang memang tidak punya lebar untuk diikuti.
    var width: CGFloat? = 180
    var height: CGFloat = 240
    let onOpen: () -> Void

    var body: some View {
        Button(action: onOpen) {
            ZStack(alignment: .bottomLeading) {
                cover
                caption
            }
            .frame(width: width, height: height)
            .clipShape(RoundedRectangle(cornerRadius: 28))
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var cover: some View {
        if let asset = story.cover {
            // `Color.clear.overlay`, bukan `AuthImage` langsung.
            //
            // `AuthImage` mengisi framenya (`contentMode: .fill`), dan view yang
            // mengisi boleh melaporkan ukuran LEBIH BESAR dari yang ditawarkan
            // padanya. Di baris mendatar lebarnya dipatok 180 jadi tidak
            // kelihatan, tapi di grid — yang lebarnya ditawarkan kolom — kartu
            // dengan foto berasio tertentu jadi lebih lebar dari tetangganya dan
            // barisnya terlihat tidak rata. `Color.clear` mengambil tawaran itu
            // apa adanya, lalu fotonya menyesuaikan.
            Color.clear
                .overlay {
                    // 240pt pada layar 3x = 720px. Bawaan "preview" adalah
                    // 2048px, yaitu bitmap ~12 MB untuk kartu sekecil ini.
                    AuthImage(
                        assetId: asset.id,
                        size: "preview",
                        thumbhash: asset.thumbhash,
                        pixelSize: 800)
                }
                .frame(width: width, height: height)
                .clipped()
        } else {
            Rectangle().fill(.fill.tertiary)
        }
    }

    private var caption: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(story.title)
                .font(.headline).lineLimit(2).minimumScaleFactor(0.65)
            Text(story.subtitle)
                .font(.caption).lineLimit(1).minimumScaleFactor(0.65)
        }
        .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
        .foregroundStyle(.white)
        .shadow(radius: 3)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        // Judul putih di atas foto seterang apa pun tetap terbaca.
        .background(
            LinearGradient(
                colors: [.clear, .black.opacity(0.55)],
                startPoint: .top,
                endPoint: .bottom))
    }
}

struct AlbumCard: View {
    let album: AlbumResponseDTO
    var width: CGFloat = 150

    var body: some View {
        Color.clear
            .overlay { AlbumCoverImage(album: album) }
            .overlay(alignment: .bottomLeading) {
                Text(album.albumName)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.65), radius: 2, y: 1)
                    .lineLimit(2).minimumScaleFactor(0.65)
                    .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                    .background(LinearGradient(colors: [.clear, .black.opacity(0.6)], startPoint: .top, endPoint: .bottom))
            }
            .frame(width: width, height: width)
            .clipShape(RoundedRectangle(cornerRadius: 18))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(album.albumName))
            .accessibilityValue(Text("^[\(album.assetCount) item](inflect: true)"))
    }
}

struct PersonCard: View {
    let person: PersonDTO
    /// Sisi lingkarannya. Baris People di Library memakai bawaannya; panel info
    /// jauh lebih sempit dan memakai ukuran yang lebih kecil.
    var side: CGFloat = 110

    var body: some View {
        VStack(spacing: 6) {
            PeoplePortrait(person: person, side: side)

            Text(person.displayName)
                .font(.caption)
                .lineLimit(1)
                .frame(width: side)
        }
        .accessibilityValue(person.isFavorite == true ? String(localized: "Favorite") : "")
    }
}
