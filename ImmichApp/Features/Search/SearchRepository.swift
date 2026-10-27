import Foundation

class SearchRepository {
    private let api: APIClient
    private let dataManager: SwiftDataManager?
    private let recordsVisibility: Bool

    init(api: APIClient, dataManager: SwiftDataManager? = nil, recordsVisibility: Bool = true) {
        self.api = api
        self.dataManager = dataManager
        self.recordsVisibility = recordsVisibility
    }

    /// Menerima permintaan UTUH, bukan sekadar kata kuncinya.
    ///
    /// Penyaring — orang, kota, tanggal, jenis media — dikirim di badan yang sama
    /// dengan kata kuncinya; menyaringnya di klien setelah hasil datang berarti
    /// halaman kedua bisa habis tersaring dan daftarnya berhenti tanpa alasan.
    func smartSearch(_ request: SearchRequestDTO) async throws -> SearchResponseDTO {
        let visibility = recordsVisibility ? await AssetVisibilityRequest(api: api, dataManager: dataManager) : nil
        let response: SearchResponseDTO = try await api.send(.json("/search/smart", method: .post, body: request))
        await visibility?.record(response.assets.items)
        return response
    }

    func metadataSearch(_ request: SearchRequestDTO) async throws -> SearchResponseDTO {
        let visibility = recordsVisibility ? await AssetVisibilityRequest(api: api, dataManager: dataManager) : nil
        let response = try await metadataPage(request)
        await visibility?.record(response.assets.items)
        return response
    }

    func metadataPage(_ request: SearchRequestDTO) async throws -> SearchResponseDTO {
        try await api.send(.json("/search/metadata", method: .post, body: request))
    }

    /// Mengambil seluruh halaman metadata search.
    ///
    /// Server dapat membatasi halaman lebih kecil daripada `size` yang diminta
    /// (contohnya Trash mengembalikan 5 dari total 24). Karena itu kelanjutan
    /// mengikuti `nextPage` DAN `total`, bukan menebak dari request size.
    func allMetadata(_ initialRequest: SearchRequestDTO) async throws -> [AssetResponseDTO] {
        let visibility = recordsVisibility ? await AssetVisibilityRequest(api: api, dataManager: dataManager) : nil
        var request = initialRequest
        var page = request.page ?? 1
        request.page = page

        try Task.checkCancellation()
        var response = try await metadataPage(request)
        try Task.checkCancellation()
        await visibility?.record(response.assets.items)
        var items = response.assets.items
        var seenIDs = Set(items.map(\.id))
        var knownTotal = response.assets.total

        while response.assets.nextPage != nil || items.count < knownTotal {
            page += 1
            request.page = page
            try Task.checkCancellation()
            response = try await metadataPage(request)
            try Task.checkCancellation()
            await visibility?.record(response.assets.items)
            knownTotal = max(knownTotal, response.assets.total)

            let countBeforePage = items.count
            for item in response.assets.items where seenIDs.insert(item.id).inserted {
                items.append(item)
            }

            // A continuation that makes no progress must not turn a truncated
            // collection into a successful result or overwrite its snapshot.
            guard !response.assets.items.isEmpty, items.count > countBeforePage else {
                throw URLError(.badServerResponse)
            }
        }

        try Task.checkCancellation()
        return items
    }

    /// GET /search/suggestions wajib menyertakan `type` dan mengembalikan [String] polos.
    func suggestions(type: String = "city") async throws -> [String] {
        try await api.send(.init(
            path: "/search/suggestions",
            query: [.init(name: "type", value: type)]))
    }
}

/// GET /search/explore mengembalikan array {fieldName, items: [{value, data}]}.
struct SearchExploreItemDTO: Decodable {
    struct Item: Decodable {
        let value: String
        let data: AssetResponseDTO
    }
    let fieldName: String
    let items: [Item]
}
