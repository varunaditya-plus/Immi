import Foundation

struct SearchRequestDTO: Encodable {
    var query: String? = nil
    var page: Int? = 1
    /// Filter album resmi pada `POST /search/metadata`.
    var albumIds: [String]? = nil
    /// Urutan aset menurut waktu pengambilan (`asc` atau `desc`).
    var order: String? = nil
    var type: String? = nil
    var isFavorite: Bool? = nil
    var takenAfter: String? = nil
    var takenBefore: String? = nil
    var city: String? = nil
    var personIds: [String]? = nil
    var size: Int? = nil
    /// Explicitly preserve timeline-only browsing on both Immich v2 and v3.
    /// Archived and Locked Folder pass their own visibility.
    var visibility: String? = "timeline"
    /// Menyertakan aset yang sudah dibuang ke trash.
    ///
    /// TIDAK berarti "hanya yang di trash" — namanya `with`, dan itu memang
    /// harfiah: yang di trash ikut serta DI SAMPING yang biasa. Untuk daftar
    /// trash, ia harus dipasangkan dengan `trashedAfter`.
    var withDeleted: Bool? = nil
    /// Hanya aset yang dibuang setelah tanggal ini.
    ///
    /// Inilah yang menyaringnya jadi "trash saja": aset yang tidak pernah
    /// dibuang tidak punya tanggal buang, jadi tidak ada satu pun dari mereka
    /// yang lolos. Diisi tanggal yang jauh di masa lalu untuk mendapat seluruh
    /// isi trash.
    var trashedAfter: String? = nil
    /// Exif ikut dikirim server.
    ///
    /// Bawaannya di server adalah TIDAK, dan tanpa exif `AssetLite.ratio` jatuh
    /// ke nilai cadangan 1.0 untuk setiap aset dari layar berbasis pencarian —
    /// Favorites, People, Search, Archived, Trash. Rasio itulah yang dipakai
    /// sebagai tebakan awal tata letak foto, dan tebakan "semua persegi" membuat
    /// foto tegak tergambar lebih sempit dari lebar layar.
    ///
    /// Exif juga yang mengisi panel info (kamera, lensa, lokasi), jadi ini bukan
    /// tambahan demi satu angka saja.
    var withExif: Bool? = true
}

struct SearchResponseDTO: Decodable {
    struct AssetsPage: Decodable {
        let items: [AssetResponseDTO]
        let total: Int
        let nextPage: String?
    }
    let assets: AssetsPage
}
