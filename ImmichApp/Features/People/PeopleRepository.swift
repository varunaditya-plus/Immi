import Foundation

class PeopleRepository {
    private let api: APIClient

    init(api: APIClient) {
        self.api = api
    }

    /// - Parameter size: batas dari SERVER, bukan dipotong setelah diterima.
    ///   Baris di Library cuma menampilkan belasan orang; menarik seluruhnya
    ///   lalu membuang sisanya hanya membuang waktu dan memori.
    func all(size: Int? = nil) async throws -> [PersonDTO] {
        struct Response: Decodable {
            let people: [PersonDTO]
            let hasNextPage: Bool?
        }
        let pageSize = size ?? 500
        var page = 1
        var people: [PersonDTO] = []
        var seenIDs: Set<String> = []
        while true {
            try Task.checkCancellation()
            let query: [URLQueryItem] = [
                .init(name: "withHidden", value: "false"),
                .init(name: "size", value: String(pageSize)),
                .init(name: "page", value: String(page)),
            ]
            let response: Response = try await api.send(.init(path: "/people", query: query))
            try Task.checkCancellation()
            if size != nil { return response.people }

            let previousCount = people.count
            for person in response.people where seenIDs.insert(person.id).inserted {
                people.append(person)
            }
            let hasNextPage = response.hasNextPage ?? (response.people.count == pageSize)
            guard hasNextPage else { return people }
            guard people.count > previousCount else { throw URLError(.badServerResponse) }
            page += 1
        }
    }

    /// GET /people/{id} hanya mengembalikan data orangnya; asetnya
    /// diambil terpisah lewat POST /search/metadata.
    func detail(_ id: String) async throws -> PersonDTO {
        try await api.send(.init(path: "/people/\(id)"))
    }

    func assets(personId: String) async throws -> [AssetResponseDTO] {
        var request = SearchRequestDTO(page: 1)
        request.personIds = [personId]
        request.size = 100
        request.order = "desc"
        return try await SearchRepository(api: api).allMetadata(request)
    }

    func rename(_ id: String, to name: String) async throws {
        try await update(.init(id: id, name: name))
    }

    func setHidden(_ id: String, to value: Bool) async throws {
        try await update(.init(id: id, isHidden: value))
    }

    /// `PUT /people/{id}` deprecated sejak Immich API v3. Endpoint bulk ini
    /// adalah pengganti stabilnya, termasuk untuk perubahan satu orang.
    private func update(_ item: PeopleUpdateRequestDTO.Item) async throws {
        let response: [BulkIDResponseDTO] = try await api.send(.json(
            "/people", method: .put,
            body: PeopleUpdateRequestDTO(people: [item])))

        guard let result = response.first(where: { $0.id == item.id }), result.success else {
            let failure = response.first(where: { $0.id == item.id })
            throw APIError.server(
                status: 422,
                message: failure?.errorMessage ?? failure?.error ?? "Failed to update person")
        }
    }
}
