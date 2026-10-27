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
    func albumAssets(
        _ albumId: String,
        expectedCount: Int? = nil
    ) async throws -> [AssetLite] {
        let visibility = await AssetVisibilityRequest(api: api, dataManager: dataManager)
        let pageSize = 1_000
        var page = 1
        var response = try await albumPage(albumId, page: page, size: pageSize, visibility: visibility)
        var assets = response.assets.items.filter(\.isVisibleInAlbum).map(AssetLite.init)
        var seenIDs = Set(assets.map(\.id))

        // `nextPage` adalah continuation resmi dan tidak boleh diturunkan dari
        // `total`. Beberapa server membatasi nilai total ke ukuran halaman
        // (misalnya 1.000) tetapi tetap mengirim nextPage="2". Menghitung
        // pageCount dari total membuat sisa album tidak pernah diminta.
        //
        // `total` tetap menjadi fallback untuk server lama yang tidak mengirim
        // nextPage. Permintaan dibuat berurutan karena baru halaman saat ini
        // yang dapat memastikan halaman berikutnya memang ada.
        let knownTotal = max(response.assets.total, expectedCount ?? 0)
        var pageCountFallback = max(1, (knownTotal + pageSize - 1) / pageSize)
        while response.assets.nextPage != nil || page < pageCountFallback {
            page += 1
            response = try await albumPage(albumId, page: page, size: pageSize, visibility: visibility)
            pageCountFallback = max(
                pageCountFallback,
                (response.assets.total + pageSize - 1) / pageSize)

            // Perubahan album saat pagination berjalan dapat membuat batas dua
            // halaman tumpang tindih. Deduplikasi menjaga grid dan count tetap
            // konsisten tanpa membuang item baru pada halaman berikutnya.
            for item in response.assets.items where item.isVisibleInAlbum {
                let asset = AssetLite(item)
                if seenIDs.insert(asset.id).inserted {
                    assets.append(asset)
                }
            }

            // Lindungi dari server bermasalah yang terus memberi nextPage pada
            // halaman kosong; tanpa ini satu album bisa membuat loop permanen.
            if response.assets.items.isEmpty { break }
        }
        return assets
    }

    private func albumPage(_ albumId: String, page: Int, size: Int,
                           visibility: AssetVisibilityRequest) async throws -> SearchResponseDTO {
        var request = SearchRequestDTO(page: page)
        request.albumIds = [albumId]
        request.visibility = nil
        request.order = "desc"
        request.size = size
        request.withExif = true
        let response: SearchResponseDTO = try await api.send(.json("/search/metadata", method: .post, body: request))
        await visibility.record(response.assets.items)
        return response
    }
}
