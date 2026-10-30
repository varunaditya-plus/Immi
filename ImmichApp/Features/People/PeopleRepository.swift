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
        try await directory(size: size, withHidden: false)
    }

    func allIncludingHidden() async throws -> [PersonDTO] {
        try await directory(size: nil, withHidden: true)
    }

    private func directory(size: Int?, withHidden: Bool) async throws -> [PersonDTO] {
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
                .init(name: "withHidden", value: String(withHidden)),
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
        return try await SearchRepository(api: api).allMetadata(request).filter(\.isTimelineVisible)
    }

    func rename(_ id: String, to name: String) async throws {
        try await update(.init(id: id, name: name))
    }

    func setHidden(_ id: String, to value: Bool) async throws {
        try await update(.init(id: id, isHidden: value))
    }

    func setFavorite(_ id: String, to value: Bool) async throws {
        try await update(.init(id: id, isFavorite: value))
    }

    func setKeyPhoto(_ id: String, assetID: String) async throws {
        let context = await api.session.snapshot
        let previous = try? await thumbnailData(id)
        try Task.checkCancellation()
        try await update(.init(id: id, featureFaceAssetId: assetID))
        let key = "/people/\(id)/thumbnail"
        try await api.checkCurrent(context)
        await ImageCache.shared.remove(key: key, maxPixelSize: 600)
        // Immich queues face generation after accepting the update. Do not
        // immediately cache the old face again while that worker is running.
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        for attempt in 0..<6 {
            try Task.checkCancellation()
            try await api.checkCurrent(context)
            guard ContinuousClock.now < deadline else { break }
            if attempt > 0 { try await Task.sleep(for: .milliseconds(250)) }
            guard let data = try? await thumbnailData(id), data != previous else { continue }
            try await api.checkCurrent(context)
            await ImageCache.shared.remove(key: key, maxPixelSize: 600)
            _ = try? await ImageCache.shared.image(key: key, maxPixelSize: 600) {
                try await self.api.checkCurrent(context)
                return data
            }
            return
        }
        try await api.checkCurrent(context)
        await ImageCache.shared.remove(key: key, maxPixelSize: 600)
    }

    private func thumbnailData(_ personID: String) async throws -> Data {
        try await withThrowingTaskGroup(of: Data.self) { group in
            group.addTask { try await self.api.rawData(.init(path: "/people/\(personID)/thumbnail")) }
            group.addTask {
                try await Task.sleep(for: .milliseconds(750))
                throw URLError(.timedOut)
            }
            defer { group.cancelAll() }
            guard let result = try await group.next() else { throw CancellationError() }
            return result
        }
    }

    func merge(_ sourceIDs: [String], into targetID: String) async throws -> [BulkIDResponseDTO] {
        struct Body: Encodable { let ids: [String] }
        var seen: Set<String> = [targetID]
        let sources = sourceIDs.filter { seen.insert($0).inserted }
        guard !sources.isEmpty else { throw URLError(.badURL) }
        return try await api.send(.json("/people/\(targetID)/merge", method: .post, body: Body(ids: sources)))
    }

    func faces(in assetID: String) async throws -> [PersonFaceDTO] {
        try await api.send(.init(path: "/faces", query: [.init(name: "id", value: assetID)]))
    }

    func reassign(faceID: String, to personID: String) async throws -> PersonDTO {
        struct Body: Encodable { let id: String }
        return try await api.send(.json("/faces/\(personID)", method: .put, body: Body(id: faceID)))
    }

    func createUnnamedPerson() async throws -> PersonDTO {
        struct Body: Encodable { let name = "" }
        return try await api.send(.json("/people", method: .post, body: Body()))
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
