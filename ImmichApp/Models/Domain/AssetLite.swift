import Foundation

/// Di mana sebuah foto berada.
///
/// Bukan sekadar keterangan: ia menentukan lencana di petak grid, tombol apa
/// yang masuk akal di layar detail, dan apakah "hapus dari perangkat" berarti
/// sesuatu. Yang paling penting dibedakan adalah `.device` — foto yang hanya
/// ada di satu tempat, dan tempat itu bisa hilang bersama ponselnya.
enum AssetOrigin: String, Codable, Sendable {
    /// Hanya di server. Mayoritas isi linimasa; tanpa lencana.
    case server
    /// Hanya di perangkat, belum pernah diunggah.
    case device
    /// Ada di keduanya.
    case both
}

/// `Codable` ada DI SINI, bukan di `LocalSnapshot` yang memakainya: Swift hanya
/// mensintesisnya pada deklarasi tipe atau extension di berkas yang sama.
/// Dipakai untuk memotret isi layar ke disk supaya tetap tergambar saat offline.
struct AssetLite: Identifiable, Hashable, Sendable, Codable {
    let id: String
    let isVideo: Bool
    let ratio: Double
    let thumbhash: String?
    let createdAt: Date
    /// var supaya grid bisa menampilkan status favorit tanpa memuat detail
    /// penuh, dan memperbaruinya di tempat setelah aksi context menu.
    var isFavorite: Bool = false
    /// Durasi video dalam detik; nil untuk foto.
    ///
    /// Ikut dibawa sampai ke grid supaya petak video bisa menuliskan lamanya
    /// tanpa memuat detail penuh satu per satu.
    var duration: Double? = nil
    /// Id aset video pasangan sebuah Live Photo; nil untuk foto biasa.
    ///
    /// Ikut dibawa ke grid dan pager supaya lencana LIVE dan tekan-tahannya
    /// tidak perlu memuat detail penuh satu per satu.
    var livePhotoVideoID: String? = nil
    /// Di mana foto ini berada.
    ///
    /// Nilai bawaannya TIDAK cukup untuk menyelamatkan potret lama — lihat
    /// `init(from:)` di bawah. Sintesis `Decodable` mengabaikan nilai bawaan
    /// untuk properti non-Optional dan tetap menuntut kuncinya ada.
    var origin: AssetOrigin = .server

    /// Ada di perangkat, jadi bisa dihapus dari sana.
    var isOnDevice: Bool { origin != .server }
    /// Belum ada di server, jadi belum aman kalau perangkatnya hilang.
    var needsUpload: Bool { origin == .device }

    var isLivePhoto: Bool { livePhotoVideoID != nil }

    /// "1:35" — nil kalau bukan video atau durasinya tidak diketahui.
    var durationText: String? {
        guard let duration, duration > 0 else { return nil }
        let total = Int(duration.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    // Identitas ditentukan HANYA oleh id.
    //
    // Kalau `isFavorite` ikut dibandingkan, satu foto yang status favoritnya
    // berubah akan dianggap objek berbeda — `firstIndex(of:)` meleset dan
    // `onChange(of: currentAsset)` di layar detail ikut terpicu tanpa foto
    // yang sebenarnya berpindah.
    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    static func == (lhs: AssetLite, rhs: AssetLite) -> Bool {
        lhs.id == rhs.id
    }

    /// Identity stays stable while these values change the displayed content.
    func hasSameContent(as other: AssetLite) -> Bool {
        id == other.id
            && isVideo == other.isVideo
            && ratio == other.ratio
            && thumbhash == other.thumbhash
            && createdAt == other.createdAt
            && isFavorite == other.isFavorite
            && duration == other.duration
            && livePhotoVideoID == other.livePhotoVideoID
            && origin == other.origin
    }
}

/// Init tambahan HARUS di extension.
///
/// Mendeklarasikannya di dalam struct membuat Swift berhenti membangkitkan
/// memberwise init — dan seluruh pemanggil `AssetLite(id:isVideo:...)` ikut
/// gagal kompilasi.
extension AssetLite {
    /// Konversi dari DTO lengkap; dipakai semua layar yang sumbernya
    /// `/search/metadata` (favorit, video, arsip, trash, orang).
    init(_ asset: AssetResponseDTO) {
        var ratio = 1.0
        if let width = asset.exifInfo?.exifImageWidth,
           let height = asset.exifInfo?.exifImageHeight,
           width > 0, height > 0 {
            ratio = Double(width) / Double(height)
        }

        self.init(
            id: asset.id,
            isVideo: asset.isVideo,
            ratio: ratio,
            thumbhash: asset.thumbhash,
            createdAt: asset.fileCreatedAt,
            isFavorite: asset.isFavorite,
            duration: asset.duration,
            livePhotoVideoID: asset.livePhotoVideoId)
    }
}


// MARK: - Codable

/// Decode ditulis TANGAN, dan itu bukan kerapian melainkan keharusan.
///
/// `AssetLite` dipotret ke disk oleh `LocalSnapshot`. Sintesis `Decodable`
/// mengabaikan nilai bawaan untuk properti non-Optional: ia memanggil
/// `decode(_:forKey:)` dan melempar `keyNotFound` kalau kuncinya tidak ada.
/// Menambahkan `origin` dengan cara itu berarti SETIAP potret yang ditulis versi
/// sebelumnya gagal dibaca — dan kegagalannya senyap, karena `LocalSnapshot`
/// membacanya dengan `try?`. Yang terlihat pengguna: Favorites, album, orang,
/// dan tong sampah tiba-tiba kembali kosong saat offline.
///
/// Di extension, bukan di dalam struct: init apa pun di badan struct membuat
/// Swift berhenti membangkitkan memberwise init, dan seluruh pemanggilnya mati.
extension AssetLite {
    private enum CodingKeys: String, CodingKey {
        case id, isVideo, ratio, thumbhash, createdAt
        case isFavorite, duration, livePhotoVideoID, origin
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try c.decode(String.self, forKey: .id),
            isVideo: try c.decode(Bool.self, forKey: .isVideo),
            ratio: try c.decode(Double.self, forKey: .ratio),
            thumbhash: try c.decodeIfPresent(String.self, forKey: .thumbhash),
            createdAt: try c.decode(Date.self, forKey: .createdAt),
            isFavorite: try c.decodeIfPresent(Bool.self, forKey: .isFavorite) ?? false,
            duration: try c.decodeIfPresent(Double.self, forKey: .duration),
            livePhotoVideoID: try c.decodeIfPresent(String.self, forKey: .livePhotoVideoID),
            origin: try c.decodeIfPresent(AssetOrigin.self, forKey: .origin) ?? .server)
    }
}
