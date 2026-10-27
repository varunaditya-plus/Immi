import Foundation

/// Simpanan potret terakhir sebuah layar, supaya isinya bisa langsung tergambar
/// sebelum jaringan menjawab — dan tetap tergambar kalau jaringan tidak pernah
/// menjawab.
///
/// **Kenapa JSON di berkas, bukan SwiftData.** Linimasa memang di SwiftData, dan
/// itu tepat: puluhan ribu foto yang perlu di-query per bulan, diperbarui
/// sebagian, dan dihitung tanpa dimuat. Yang disimpan di sini bukan itu. Album,
/// orang, favorit, arsip, sampah — semuanya "daftar terakhir yang kulihat untuk
/// layar ini", dibaca utuh dan ditulis utuh. Tidak ada satu pun query yang perlu
/// dijawab basis data.
///
/// Dan ada ongkos yang tidak sepadan: setiap entitas SwiftData harus dipelihara
/// sepanjang `VersionedSchema` dan migration plan. Store utama sekarang punya
/// recovery startup, tetapi potret layar tetap lebih tepat sebagai berkas yang
/// bisa dibuang sendiri: kerusakannya cukup membuat satu layar kembali kosong,
/// bukan memaksa pemulihan seluruh database sinkronisasi.
///
/// **Kenapa Application Support, bukan Caches.** `.cachesDirectory` boleh
/// dikosongkan sistem kapan saja saat penyimpanan menipis. Thumbnail memang di
/// sana, dan itu sengaja — hilangnya cuma membuat petaknya kembali jadi
/// thumbhash buram. Kehilangan potret ini berarti kembali ke layar kosong, dan
/// itu persis keadaan yang sedang diperbaiki.
@MainActor
enum LocalSnapshot {
    private(set) static var generation = UUID()
    // MARK: - Kunci

    enum Key {
        static let albumsList = "albums.list"
        static let peopleList = "people.list"
        static let libraryAlbums = "library.albums"
        static let libraryPeople = "library.people"
        static let libraryFavorites = "library.favorites"
        static let favorites = "collection.favorites"
        static let archived = "collection.archived"
        static let trash = "collection.trash"
        static let locked = "collection.locked"
        static let places = "places.markers"

        static func person(_ id: String) -> String { "collection.person.\(id)" }
        static func album(_ id: String) -> String { "collection.album.\(id)" }
        /// Detail penuh satu foto — sumber panel info saat offline.
        static func assetDetail(_ id: String) -> String { "asset.detail.\(id)" }
    }

    // MARK: - Baca & tulis

    static func load<T: Decodable>(_ type: T.Type, for key: String) -> T? {
        guard let data = try? Data(contentsOf: url(for: key)) else { return nil }
        return try? decoder.decode(T.self, from: data)
    }

    /// - Returns: true kalau isinya BERBEDA dari yang tersimpan.
    ///
    /// Nilai baliknya yang membuat penyegaran tidak terasa. Layar sudah
    /// menggambar potret lama; kalau server menjawab hal yang sama persis,
    /// memasangnya ulang hanya menyuruh SwiftUI membangun ulang daftar yang
    /// tidak berubah — dan di grid, itu terlihat sebagai kedipan.
    @discardableResult
    static func save<T: Encodable>(
        _ value: T, for key: String, expectedGeneration: UUID? = nil
    ) -> Bool {
        if let expectedGeneration, expectedGeneration != generation { return false }
        // Gagal mengodekan dilaporkan sebagai BERUBAH, bukan sebagai sama.
        //
        // Nilai balik ini dipakai pemanggil untuk memutuskan apakah data segar
        // dari server perlu dipasang. "Sama" berarti tidak perlu — dan menjawab
        // itu untuk sesuatu yang bahkan tidak berhasil dibandingkan berarti
        // membuang jawaban server dan membiarkan potret basi di layar.
        guard let data = try? encoder.encode(value) else { return true }
        let destination = url(for: key)
        let existing = try? Data(contentsOf: destination)
        guard existing != data else { return false }

        try? FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)
        try? data.write(to: destination, options: .atomic)
        return true
    }

    /// Membuang satu potret — untuk hal yang memang sudah tidak ada lagi.
    static func remove(_ key: String, expectedGeneration: UUID? = nil) {
        if let expectedGeneration, expectedGeneration != generation { return }
        try? FileManager.default.removeItem(at: url(for: key))
    }

    /// Dipanggil saat keluar akun: potret milik server lain bukan sekadar basi,
    /// ia menampilkan foto orang lain.
    static func clearAll() {
        generation = UUID()
        try? FileManager.default.removeItem(at: directory)
    }

    // MARK: - Berkas

    private static let directory: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("immich-snapshots", isDirectory: true)
    }()

    /// Kuncinya dijadikan nama berkas apa adanya, jadi karakter yang tidak sah
    /// di nama berkas dibuang. Id album dan orang berupa UUID, tapi kunci masa
    /// depan belum tentu.
    private static func url(for key: String) -> URL {
        let safe = key.replacingOccurrences(
            of: "[^A-Za-z0-9._-]", with: "_", options: .regularExpression)
        return directory.appendingPathComponent("\(safe).json")
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        // Tanggal harus dikodekan DETERMINISTIK: perbandingan "berubah atau
        // tidak" di `save` membandingkan byte, dan format yang berbeda untuk
        // tanggal yang sama akan selalu terbaca sebagai perubahan.
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}

// MARK: - Konformansi untuk yang disimpan

// `AssetLite: Codable` dan `PersonDTO: Encodable` dideklarasikan di BERKAS
// masing-masing, bukan di sini. Swift menolak mensintesis Codable pada extension
// yang berada di berkas lain dari deklarasi tipenya — pengecualian lintas-berkas
// hanya berlaku untuk Equatable/Hashable pada enum sederhana.
//
// Yang di bawah ini bisa tinggal karena witness-nya ditulis tangan, jadi tidak
// ada yang perlu disintesis.

/// `Encodable` ditulis TANGAN, bukan disintesis.
///
/// Sintesis akan menuntut `AssetResponseDTO` ikut `Encodable` — dan tipe itu
/// punya `init(from:)` kustom yang menerima durasi dalam dua bentuk (teks jam
/// maupun angka detik), sehingga pasangan encode-nya harus ditulis tangan juga
/// agar tidak menghasilkan sesuatu yang tidak bisa dibaca kembali.
///
/// Lagi pula `assets` memang tidak perlu disimpan di sini: daftar album tidak
/// membacanya, dan layar detail album mengambil asetnya lewat bucket linimasa
/// yang punya potretnya sendiri.
extension AlbumResponseDTO: Encodable {
    /// SENGAJA tidak bernama `CodingKeys`.
    ///
    /// Nama itu akan diambil alih juga oleh sintesis `Decodable` di deklarasi
    /// aslinya — dan karena daftar ini tidak memuat `assets`, album dari server
    /// diam-diam berhenti membawa asetnya. Bug yang tidak mengeluh apa pun.
    private enum SnapshotKeys: String, CodingKey {
        case id, albumName, description, assetCount, albumThumbnailAssetId
        case shared, createdAt, updatedAt, startDate, endDate
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: SnapshotKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(albumName, forKey: .albumName)
        try container.encodeIfPresent(description, forKey: .description)
        try container.encode(assetCount, forKey: .assetCount)
        try container.encodeIfPresent(albumThumbnailAssetId, forKey: .albumThumbnailAssetId)
        try container.encode(shared, forKey: .shared)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encodeIfPresent(updatedAt, forKey: .updatedAt)
        try container.encodeIfPresent(startDate, forKey: .startDate)
        try container.encodeIfPresent(endDate, forKey: .endDate)
    }
}
