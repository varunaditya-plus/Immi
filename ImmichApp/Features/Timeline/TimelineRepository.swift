import Foundation

/// Satu baris hasil bacaan cache: aset plus bulan tempatnya berada.
///
/// `Sendable` karena penyusunan sectionnya dilakukan di luar main actor.
struct TimelineRow: Sendable {
    let asset: AssetLite
    let monthKey: String
}

struct TimelineSection: Identifiable, Sendable {
    let id: String
    let title: String
    var assets: [AssetLite]
    /// Jumlah foto menurut bucket, tersedia sebelum asetnya dimuat.
    ///
    /// Dipakai untuk mengetahui posisi section tanpa memindai daftarnya.
    var count: Int = 0

    /// Posisi sel pertama section ini dalam deret sel gabungan.
    ///
    /// Semua section berbagi satu grid, jadi indeks 0,1,2… per section akan
    /// bertabrakan. Offset ini membuat rentangnya tidak pernah beririsan tanpa
    /// perlu merakit string apa pun, dan sekaligus jadi penanda urutan yang bisa
    /// dibandingkan langsung.
    var startIndex: Int = 0
}

class TimelineRepository {
    private let api: APIClient
    private let dataManager: SwiftDataManager?

    init(api: APIClient, dataManager: SwiftDataManager? = nil) {
        self.api = api
        self.dataManager = dataManager
    }

    /// Mengambil seluruh isi album lewat endpoint publik stabil.
    ///
    /// `/timeline/bucket*` berstatus **Internal** di OpenAPI Immich. Selain bisa
    /// berubah tanpa masa deprecation, jalur itu memerlukan satu request per
    /// bulan. Metadata search memberi hingga 1.000 aset per halaman dan punya
    /// kontrak pagination stabil.
    func albumAssets(_ albumId: String) async throws -> [AssetLite] {
        var request = SearchRequestDTO(page: 1)
        request.albumIds = [albumId]
        request.visibility = nil
        request.order = "desc"
        request.size = 1_000
        request.withExif = true
        return try await SearchRepository(api: api, dataManager: dataManager)
            .allMetadata(request).filter(\.isVisibleInAlbum).map(AssetLite.init)
    }
}
