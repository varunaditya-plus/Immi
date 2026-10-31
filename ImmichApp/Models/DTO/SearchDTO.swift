struct SearchRequestDTO: Encodable, Equatable {
    var query: String? = nil
    var page: Int? = 1
    /// Filter album resmi pada `POST /search/metadata`.
    var albumIds: [String]? = nil
    /// Urutan aset menurut waktu pengambilan (`asc` atau `desc`).
    var order: String? = nil
    var type: String? = nil
    var isMotion: Bool? = nil
    var isFavorite: Bool? = nil
    var isNotInAlbum: Bool? = nil
    var takenAfter: String? = nil
    var takenBefore: String? = nil
    var city: String? = nil
    var state: String? = nil
    var country: String? = nil
    var personIds: [String]? = nil
    var description: String? = nil
    var originalFileName: String? = nil
    var ocr: String? = nil
    var withPeople: Bool? = nil
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
    // Calendar ranges are half-open locally; the legacy server's takenBefore is inclusive.
    var exclusiveTakenBefore: String? = nil

    private enum CodingKeys: String, CodingKey {
        case query, page, albumIds, order, type, isMotion, isFavorite, isNotInAlbum
        case takenAfter, takenBefore, city, state, country, personIds
        case description, originalFileName, ocr, withPeople, size, visibility
        case withDeleted, trashedAfter, withExif
    }
}

struct SearchResponseDTO: Decodable {
    struct AssetsPage: Decodable {
        let items: [AssetResponseDTO]
        let total: Int
        let nextPage: String?
    }
    let assets: AssetsPage
    var incompleteSources: [String]? = nil
}

struct AlbumSmartSearchRequestDTO: Encodable {
    struct Equal<Value: Encodable>: Encodable { let eq: Value }
    struct IDs: Encodable { let all: [String] }
    struct TextMatch: Encodable { let matches: String }
    struct DateFilter: Encodable {
        var gte: String? = nil
        var lte: String? = nil
        var lt: String? = nil
        var isNull = false

        private enum CodingKeys: String, CodingKey { case gte, lte, lt, eq }

        func encode(to encoder: Encoder) throws {
            var values = encoder.container(keyedBy: CodingKeys.self)
            try values.encodeIfPresent(gte, forKey: .gte)
            try values.encodeIfPresent(lte, forKey: .lte)
            try values.encodeIfPresent(lt, forKey: .lt)
            if isNull { try values.encodeNil(forKey: .eq) }
        }
    }
    struct Filter: Encodable {
        let albumIds: IDs
        let personIds: IDs?
        let type: Equal<String>?
        let isMotion: Equal<Bool>?
        let isFavorite: Equal<Bool>?
        let visibility: Equal<String>?
        let city: Equal<String>?
        let state: Equal<String>?
        let country: Equal<String>?
        let ocr: TextMatch?
        let takenAt: DateFilter?
        let trashedAt: DateFilter?
    }

    let query: String?
    let size: Int?
    let withExif: Bool?
    let filter: Filter

    init(_ request: SearchRequestDTO) {
        query = request.query
        size = request.size
        withExif = request.withExif
        let before = request.exclusiveTakenBefore ?? request.takenBefore
        let taken = request.takenAfter == nil && before == nil ? nil : DateFilter(
            gte: request.takenAfter, lte: request.exclusiveTakenBefore == nil ? before : nil,
            lt: request.exclusiveTakenBefore)
        let trashed = request.trashedAfter.map { DateFilter(gte: $0) }
            ?? (request.withDeleted == true ? nil : DateFilter(isNull: true))
        filter = Filter(albumIds: IDs(all: request.albumIds ?? []),
            personIds: request.personIds.flatMap { $0.isEmpty ? nil : IDs(all: $0) },
            type: request.type.map { Equal(eq: $0) }, isMotion: request.isMotion.map { Equal(eq: $0) },
            isFavorite: request.isFavorite.map { Equal(eq: $0) },
            visibility: request.visibility.map { Equal(eq: $0) },
            city: request.city.map { Equal(eq: $0) }, state: request.state.map { Equal(eq: $0) },
            country: request.country.map { Equal(eq: $0) },
            ocr: request.ocr.flatMap { $0.isEmpty ? nil : TextMatch(matches: $0) },
            takenAt: taken, trashedAt: trashed)
    }
}
