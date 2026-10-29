import MapKit
import SwiftUI

/// Panel metadata inline ala Photos: caption, header tanggal, kartu kamera
/// dengan baris EXIF, lalu kartu peta lokasi.
///
/// Panel ini TIDAK punya gesture drag sendiri.
///
/// Seluruh tarikan — di area foto maupun di badan panel — ditangani satu
/// `PanelPanGesture` milik `AssetDetailView`. Panel hanya melaporkan posisi
/// scroll-nya supaya recognizer itu tahu kapan harus mengalah ke daftar.
struct AssetInfoPanel: View {
    let detail: AssetResponseDTO
    /// Daftar hanya boleh di-scroll saat panel berada di detent tertinggi;
    /// di bawah itu seluruh panel inert supaya tarikan mengubah tingginya.
    var isScrollEnabled = true
    /// Tinggi alami seluruh isi panel. Pemanggil memakainya sebagai batas atas
    /// tarikan, supaya panel tidak bisa ditarik melewati isinya dan menyisakan
    /// ruang kosong di bawah.
    var onIntrinsicHeightChange: ((CGFloat) -> Void)?
    /// contentOffset.y daftar; <= 0 berarti sudah di paling atas.
    var onScrollOffsetChange: ((CGFloat) -> Void)?
    /// Teks yang sedang diedit. Dimiliki pemanggil supaya tombol simpan/batal
    /// di toolbar atas bisa membaca dan mengembalikannya.
    @Binding var descriptionDraft: String
    /// Fokus juga dimiliki pemanggil, karena toolbar atas yang menutupnya.
    var descriptionFocus: FocusState<Bool>.Binding
    var onAdjustDate: (() -> Void)?
    var onAdjustLocation: (() -> Void)?
    /// Album yang memuat foto ini; kosong berarti barisnya tidak digambar.
    var containingAlbums: [AlbumResponseDTO] = []
    var onAlbumContentsChanged: ((String, [AssetLite]) -> Void)?
    var onAlbumChanged: ((AlbumResponseDTO) -> Void)?
    var onAlbumDeleted: ((String) -> Void)?
    var onAlbumShared: ((String) -> Void)?

    /// Dipakai membangun repository untuk tautan ke layar seseorang.
    @Environment(SessionManager.self) private var session
    @State private var headerHeight: CGFloat = 0
    @State private var contentHeight: CGFloat = 0
    @State private var mapPosition: MapCameraPosition = .automatic

    var body: some View {
        VStack(spacing: 0) {
            descriptionRow
            scrollArea
        }
        .background(Color(.systemGroupedBackground))
        // Baru dilaporkan setelah KEDUA bagian terukur. Melaporkan saat salah
        // satunya masih 0 menghasilkan tinggi setengah jadi yang, di sisi
        // pemanggil, terbaca sebagai panel yang sangat pendek.
        .onChange(of: headerHeight + contentHeight) { _, newValue in
            guard headerHeight > 0, contentHeight > 0 else { return }
            onIntrinsicHeightChange?(newValue)
        }
    }

    private var scrollArea: some View {
        ScrollView {
            VStack(spacing: 16) {
                headerSection
                cameraCard
                mapCard
                peopleCard
                albumsCard
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
            // Panel kini menembus safe area bawah, jadi isinya butuh jarak
            // sendiri agar tidak tertutup home indicator / bottom toolbar.
            .padding(.bottom, 80)
            .onGeometryChange(for: CGFloat.self) { proxy in
                proxy.size.height
            } action: { newValue in
                contentHeight = newValue
            }
        }
        .scrollBounceBehavior(.basedOnSize)
        // scrollDisabled memakai modifier yang sama di kedua keadaan, jadi
        // identitas view-nya stabil. Ini penting: memasang/melepas gesture
        // lewat cabang `if` justru membangun ulang ScrollView di tengah drag.
        .scrollDisabled(!isScrollEnabled)
        .onScrollGeometryChange(for: CGFloat.self) { geometry in
            geometry.contentOffset.y
        } action: { _, newValue in
            onScrollOffsetChange?(newValue)
        }
    }

    // MARK: - Description

    /// Immich menyebut field ini "description", bukan "caption".
    private var descriptionRow: some View {
        VStack(spacing: 0) {
            TextField(
                "Add a Description",
                text: $descriptionDraft,
                axis: .vertical
            )
            .lineLimit(1...4)
            .focused(descriptionFocus)
            .padding(.horizontal, 16)
            .padding(.vertical, 14)

            Divider()
        }
        .background(Color(.secondarySystemGroupedBackground))
        // Area penuh harus bisa ditarik, bukan hanya teksnya.
        .contentShape(Rectangle())
        .onGeometryChange(for: CGFloat.self) { proxy in
            proxy.size.height
        } action: { newValue in
            headerHeight = newValue
        }
        .onAppear { descriptionDraft = savedDescription }
        // Berpindah foto saat panel terbuka: muat ulang teksnya.
        .onChange(of: detail.id) { _, _ in
            descriptionDraft = savedDescription
        }
        // Nilai dari server menang selama user tidak sedang mengetik.
        .onChange(of: savedDescription) { _, newValue in
            guard !descriptionFocus.wrappedValue else { return }
            descriptionDraft = newValue
        }
    }

    private var savedDescription: String {
        detail.exifInfo?.description ?? ""
    }

    // MARK: - Header tanggal + nama file

    private var headerSection: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline) {
                Text(dateText)
                    .font(.subheadline.weight(.medium))
                Spacer()
                Button("Adjust") { onAdjustDate?() }
                    .font(.subheadline)
                    .buttonStyle(.plain)
                    .foregroundStyle(.tint)
            }
            Text(detail.originalFileName)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }

    private var dateText: String {
        detail.fileCreatedAt.formatted(
            .dateTime.weekday(.wide).day().month(.abbreviated).year()
                .hour().minute())
    }

    // MARK: - Kartu kamera

    private var cameraCard: some View {
        VStack(spacing: 0) {
            cameraHeader
            Divider().padding(.leading, 12)
            cameraBody
            if !exifChips.isEmpty {
                Divider().padding(.leading, 12)
                exifRow
            }
        }
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private var cameraHeader: some View {
        HStack(spacing: 8) {
            Text(cameraName)
                .font(.subheadline.weight(.semibold))
            Spacer()
            if let format = fileFormat {
                Text(format)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color(.tertiarySystemFill))
                    .clipShape(RoundedRectangle(cornerRadius: 4))
            }
            Image(systemName: "camera.aperture")
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    private var cameraBody: some View {
        VStack(alignment: .leading, spacing: 2) {
            if let lensLine {
                Text(lensLine)
            }
            Text(resolutionLine)
        }
        .font(.footnote)
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    /// Baris chip EXIF dengan pemisah vertikal, seperti di Photos.
    private var exifRow: some View {
        HStack(spacing: 0) {
            ForEach(Array(exifChips.enumerated()), id: \.offset) { index, chip in
                if index > 0 {
                    Divider().frame(height: 14)
                }
                Text(chip)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
            }
        }
        .padding(.vertical, 8)
    }

    // MARK: - Orang & album

    /// Orang yang dikenali di foto ini.
    ///
    /// Yang disembunyikan namanya TIDAK ikut ditampilkan: pengguna sudah pernah
    /// menyatakan tidak ingin melihatnya, dan panel info bukan pengecualian.
    private var visiblePeople: [PersonDTO] {
        guard let people = detail.people else { return [] }
        return people.filter { !$0.isHidden }
    }

    @ViewBuilder
    private var peopleCard: some View {
        if !visiblePeople.isEmpty {
            infoCard("People") {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(alignment: .top, spacing: 14) {
                        ForEach(visiblePeople) { person in
                            NavigationLink {
                                PersonDetailView(
                                    person: person,
                                    repo: PeopleRepository(api: APIClient(session: session)))
                            } label: {
                                // Lebih kecil daripada di baris People: panel ini
                                // cuma selebar layar dikurangi dua sisi kartu,
                                // dan lingkaran 110pt membuatnya cuma muat dua
                                // setengah orang.
                                PersonCard(person: person, side: 64)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 14)
                }
            }
        }
    }

    @ViewBuilder
    private var albumsCard: some View {
        if !containingAlbums.isEmpty {
            infoCard("Albums") {
                VStack(spacing: 0) {
                    ForEach(containingAlbums) { album in
                        NavigationLink {
                            albumDestination(for: album)
                        } label: {
                            AlbumRowView(album: album)
                                .padding(.horizontal, 16)
                                .padding(.vertical, 8)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)

                        if album.id != containingAlbums.last?.id {
                            Divider().padding(.leading, 88)
                        }
                    }
                }
                .padding(.bottom, 6)
            }
        }
    }

    func albumDestination(for album: AlbumResponseDTO) -> AlbumDetailView {
        AlbumDetailView(
            album: album,
            onContentsChanged: { onAlbumContentsChanged?(album.id, $0) },
            onAlbumChanged: { onAlbumChanged?($0) },
            onDeleted: { onAlbumDeleted?(album.id) },
            onShared: { onAlbumShared?(album.id) })
    }

    /// Kartu berjudul dengan bentuk yang sama seperti kartu kamera dan peta.
    private func infoCard<Content: View>(
        _ title: LocalizedStringKey,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.headline)
                .padding(.horizontal, 16)
                .padding(.top, 14)

            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 12))
    }

    // MARK: - Kartu peta

    @ViewBuilder
    private var mapCard: some View {
        if coordinate == nil {
            // Tanpa baris ini, foto tanpa koordinat tidak punya jalan sama
            // sekali untuk menambahkan lokasi.
            addLocationRow
        } else {
            locationCard
        }
    }

    private var addLocationRow: some View {
        Button {
            onAdjustLocation?()
        } label: {
            HStack {
                Label("Add Location", systemImage: "mappin.and.ellipse")
                    .font(.subheadline)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption2.weight(.semibold))
            }
            .foregroundStyle(.tint)
            .padding(.horizontal, 12)
            .padding(.vertical, 12)
            .background(Color(.secondarySystemGroupedBackground))
            .clipShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var locationCard: some View {
        if let coordinate {
            VStack(spacing: 0) {
                Map(position: $mapPosition, interactionModes: isScrollEnabled ? [.pan, .zoom] : []) {
                    Annotation("", coordinate: coordinate) {
                        AuthImage(assetId: detail.id, thumbhash: detail.thumbhash)
                            .frame(width: 44, height: 44)
                            .clipShape(RoundedRectangle(cornerRadius: 4))
                            .overlay {
                                RoundedRectangle(cornerRadius: 4)
                                    .stroke(.white, lineWidth: 3)
                            }
                            .shadow(radius: 2)
                    }
                }
                .id(detail.id)
                .frame(height: 160)
                .allowsHitTesting(isScrollEnabled)
                // Foto/lokasi baru mengatur kamera; perubahan metadata lain
                // tidak menghapus area yang sedang dijelajahi pengguna.
                .onChange(of: mapLocation, initial: true) { _, location in
                    guard let location else { return }
                    mapPosition = .region(region(around: location.coordinate))
                }

                Divider()

                HStack(spacing: 4) {
                    Text(placeName)
                        .font(.subheadline)
                        .foregroundStyle(.tint)
                    Image(systemName: "chevron.right")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.tint)
                    Spacer()
                    Button("Adjust") { onAdjustLocation?() }
                        .font(.subheadline)
                        .buttonStyle(.plain)
                        .foregroundStyle(.tint)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(Color(.secondarySystemGroupedBackground))
            }
            .clipShape(RoundedRectangle(cornerRadius: 12))
        }
    }

    private struct MapLocation: Equatable {
        let assetID: String
        let latitude: Double
        let longitude: Double

        var coordinate: CLLocationCoordinate2D {
            CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
        }
    }

    private var mapLocation: MapLocation? {
        guard let lat = detail.exifInfo?.latitude,
              let lon = detail.exifInfo?.longitude else { return nil }
        return MapLocation(assetID: detail.id, latitude: lat, longitude: lon)
    }

    private var coordinate: CLLocationCoordinate2D? {
        mapLocation?.coordinate
    }

    private func region(around coordinate: CLLocationCoordinate2D) -> MKCoordinateRegion {
        MKCoordinateRegion(
            center: coordinate,
            span: MKCoordinateSpan(latitudeDelta: 0.01, longitudeDelta: 0.01))
    }

    private var placeName: String {
        let parts = [detail.exifInfo?.city, detail.exifInfo?.state]
            .compactMap { $0 }
            .filter { !$0.isEmpty }
        return parts.isEmpty
            ? (detail.exifInfo?.country ?? "Unknown Location")
            : parts.joined(separator: " - ")
    }

    // MARK: - Teks turunan

    private var cameraName: String {
        let exif = detail.exifInfo
        let parts = [exif?.make, exif?.model].compactMap { $0 }.filter { !$0.isEmpty }
        return parts.isEmpty ? detail.originalFileName : parts.joined(separator: " ")
    }

    private var fileFormat: String? {
        let ext = (detail.originalFileName as NSString).pathExtension
        return ext.isEmpty ? nil : ext.uppercased()
    }

    private var lensLine: String? {
        let exif = detail.exifInfo
        var parts: [String] = []
        if let lens = exif?.lensModel, !lens.isEmpty { parts.append(lens) }
        var optics: [String] = []
        if let focal = exif?.focalLength {
            optics.append("\(Int(focal.rounded())) mm")
        }
        if let f = exif?.fNumber {
            optics.append(String(format: "ƒ%.1f", f))
        }
        if !optics.isEmpty { parts.append(optics.joined(separator: " ")) }
        return parts.isEmpty ? nil : parts.joined(separator: " — ")
    }

    private var resolutionLine: String {
        let exif = detail.exifInfo
        var parts: [String] = []
        if let w = exif?.exifImageWidth, let h = exif?.exifImageHeight {
            let megapixels = Double(w * h) / 1_000_000
            parts.append(String(format: "%.0f MP", megapixels))
            parts.append("\(w) × \(h)")
        }
        if let bytes = exif?.fileSizeInByte {
            parts.append(ByteCountFormatter.string(
                fromByteCount: Int64(bytes), countStyle: .file))
        }
        return parts.joined(separator: " • ")
    }

    private var exifChips: [String] {
        guard let exif = detail.exifInfo else { return [] }
        var chips: [String] = []
        if let iso = exif.iso { chips.append("ISO \(iso)") }
        if let focal = exif.focalLength { chips.append("\(Int(focal.rounded())) mm") }
        if let f = exif.fNumber { chips.append(String(format: "ƒ%.1f", f)) }
        if let shutter = exif.exposureTime, !shutter.isEmpty { chips.append("\(shutter) s") }
        return chips
    }
}
