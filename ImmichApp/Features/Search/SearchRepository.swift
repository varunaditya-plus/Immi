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

    /// Metadata search returns a page-number continuation on supported servers.
    /// A terminal response wins over counts, which can be stale or page-local.
    func allMetadata(_ initialRequest: SearchRequestDTO) async throws -> [AssetResponseDTO] {
        try await allMetadata(initialRequest, includingRepeatedIDs: false)
    }

    func allMetadata(
        _ initialRequest: SearchRequestDTO, includingRepeatedIDs: Bool
    ) async throws -> [AssetResponseDTO] {
        let visibility = recordsVisibility ? await AssetVisibilityRequest(api: api, dataManager: dataManager) : nil
        var request = initialRequest
        var page = request.page ?? 1
        var items: [AssetResponseDTO] = []
        var seenIDs: Set<String> = []

        while true {
            try Task.checkCancellation()
            request.page = page
            let response = try await metadataPage(request)
            try Task.checkCancellation()
            await visibility?.record(response.assets.items)

            let previousCount = seenIDs.count
            for item in response.assets.items {
                let isNew = seenIDs.insert(item.id).inserted
                if isNew || includingRepeatedIDs { items.append(item) }
            }
            try Task.checkCancellation()
            guard let nextPage = response.assets.nextPage else { return items }
            // Count raw IDs: a private-only page can still make progress, while
            // endlessly repeated IDs must not publish a partial collection.
            guard seenIDs.count > previousCount,
                  let next = Int(nextPage), next > page else {
                throw URLError(.badServerResponse)
            }
            page = next
        }
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
