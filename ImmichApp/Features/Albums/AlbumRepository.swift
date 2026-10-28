import Foundation

struct AlbumMutationError: LocalizedError {
    let succeededIDs: Set<String>
    let duplicateIDs: Set<String>
    let failedIDs: Set<String>

    var errorDescription: String? {
        String(localized: "Some photos could not be updated in the album.")
    }
}

struct AlbumOwnershipUnavailableError: LocalizedError {
    var errorDescription: String? {
        String(localized: "The server did not identify the owner of a matching album.")
    }
}

class AlbumRepository {
    private let api: APIClient
    private let dataManager: SwiftDataManager?
    private let recordsVisibility: Bool

    init(api: APIClient, dataManager: SwiftDataManager? = nil, recordsVisibility: Bool = true) {
        self.api = api
        self.dataManager = dataManager
        self.recordsVisibility = recordsVisibility
    }

    func all() async throws -> [AlbumResponseDTO] {
        try await api.send(.init(path: "/albums"))
    }

    /// Backup may reuse an owned album, including one shared with other users.
    /// A same-name album with unknown ownership does not establish absence.
    func ownedAlbum(named name: String, ownerID: String) async throws -> AlbumResponseDTO? {
        let matches = try await all().filter { $0.albumName == name }
        if let owned = matches.first(where: { $0.ownerId == ownerID }) { return owned }
        guard !matches.contains(where: { $0.ownerId == nil }) else {
            throw AlbumOwnershipUnavailableError()
        }
        return nil
    }

    /// Album yang MEMUAT sebuah foto.
    ///
    /// Endpoint yang sama dengan daftar album, disaring server lewat `assetId` —
    /// jauh lebih murah daripada menarik seluruh album lalu memeriksa isinya satu
    /// per satu di klien.
    func albums(containing assetId: String) async throws -> [AlbumResponseDTO] {
        try await api.send(.init(
            path: "/albums",
            query: [.init(name: "assetId", value: assetId)]))
    }

    func detail(_ id: String) async throws -> AlbumResponseDTO {
        try await api.send(.init(path: "/albums/\(id)"))
    }

    /// Album responses no longer embed assets in Immich v3. Covers and widgets
    /// only need a few recent IDs, so let the server order and limit them.
    func recentAssetIDs(
        in albumID: String, limit: Int, includeArchived: Bool = true
    ) async throws -> [String] {
        let visibility = recordsVisibility ? await AssetVisibilityRequest(api: api, dataManager: dataManager) : nil
        var request = SearchRequestDTO(
            page: 1, albumIds: [albumID], order: "desc", size: limit,
            visibility: includeArchived ? nil : "timeline", withExif: false)
        var ids: [String] = []
        var seenIDs: Set<String> = []
        var page = 1
        while ids.count < limit {
            try Task.checkCancellation()
            request.page = page
            let response: SearchResponseDTO = try await api.send(
                .json("/search/metadata", method: .post, body: request))
            try Task.checkCancellation()
            await visibility?.record(response.assets.items)
            let previousCount = seenIDs.count
            for item in response.assets.items where seenIDs.insert(item.id).inserted {
                guard includeArchived ? item.isVisibleInAlbum : item.isTimelineVisible else { continue }
                ids.append(item.id)
                if ids.count == limit { return ids }
            }
            guard let nextPage = response.assets.nextPage else { return ids }
            guard seenIDs.count > previousCount,
                  let next = Int(nextPage), next > page else {
                throw URLError(.badServerResponse)
            }
            page = next
        }
        return ids
    }

    /// Deskripsi ikut di permintaan yang SAMA, bukan lewat PATCH menyusul.
    ///
    /// `POST /albums` sudah menerimanya; mengirimnya terpisah berarti album bisa
    /// tercipta lalu deskripsinya gagal tersimpan, dan yang tertinggal adalah
    /// album setengah jadi tanpa cara memberi tahu pengguna bagian mana yang
    /// gagal.
    func create(
        name: String,
        description: String? = nil,
        assetIds: [String] = []
    ) async throws -> AlbumResponseDTO {
        struct Body: Encodable {
            let albumName: String
            let description: String?
            let assetIds: [String]
        }
        let data = try await api.rawData(.json(
            "/albums",
            method: .post,
            body: Body(albumName: name, description: description, assetIds: assetIds)))

        do {
            return try JSONDecoder.immich.decode(AlbumResponseDTO.self, from: data)
        } catch {
            // Respons 2xx berarti server sudah membuat albumnya. Kalau bentuk
            // ringkasnya setidaknya membawa id, ambil representasi kanonis lewat
            // endpoint detail alih-alih mengubah keberhasilan menjadi alert
            // "Failed to Create Album".
            struct CreatedAlbumIdentity: Decodable { let id: String }
            guard let identity = try? JSONDecoder().decode(
                CreatedAlbumIdentity.self, from: data)
            else { throw APIError.decoding(error) }
            return try await detail(identity.id)
        }
    }

    func rename(_ id: String, to name: String) async throws {
        try await update(id, name: name, description: nil)
    }

    /// `description` opsional supaya field yang tidak diisi tidak ikut terkirim
    /// dan menimpa nilai yang sudah ada dengan string kosong.
    func update(_ id: String, name: String?, description: String??) async throws {
        try await api.sendVoid(.json(
            "/albums/\(id)",
            method: .patch,
            body: AlbumUpdateDTO(albumName: name, description: description)))
    }

    /// Peran "editor" mengikuti bawaan Immich saat menambahkan lewat UI.
    func addUsers(_ userIds: [String], to albumId: String) async throws {
        struct AlbumUser: Encodable {
            let userId: String
            let role: String
        }
        struct Body: Encodable {
            let albumUsers: [AlbumUser]
        }
        let users = userIds.map { AlbumUser(userId: $0, role: "editor") }
        try await api.sendVoid(.json(
            "/albums/\(albumId)/users",
            method: .put,
            body: Body(albumUsers: users)))
    }

    func users() async throws -> [UserResponseDTO] {
        try await api.send(.init(path: "/users"))
    }

    func createSharedLink(albumId: String) async throws -> SharedLinkDTO {
        struct Body: Encodable {
            let type: String
            let albumId: String
        }
        return try await api.send(.json(
            "/shared-links",
            method: .post,
            body: Body(type: "ALBUM", albumId: albumId)))
    }

    /// Menambahkan aset ke album.
    ///
    /// - Returns: id yang DITOLAK karena sudah ada di album itu.
    ///
    /// Server menjawab per-id, bukan sekadar berhasil atau gagal: menambahkan
    /// lima foto yang tiga di antaranya sudah ada tetap 200, dengan tiga entri
    /// bertanda `duplicate` di dalamnya. Dulu jawaban itu dibuang lewat
    /// `sendVoid`, jadi "sudah ada di album" tidak bisa dibedakan dari
    /// "berhasil ditambahkan" — dan pengguna tidak pernah diberi tahu.
    @discardableResult
    func addAssets(_ ids: [String], to albumId: String) async throws -> [String] {
        struct Body: Encodable {
            let ids: [String]
        }
        guard !ids.isEmpty else { return [] }
        let results: [BulkIDResponseDTO] = try await api.send(
            .json("/albums/\(albumId)/assets", method: .put, body: Body(ids: ids)))
        let outcome = mutationResult(for: ids, results: results, allowDuplicates: true)
        guard outcome.failedIDs.isEmpty else { throw outcome }
        var seen = Set<String>()
        return ids.filter { outcome.duplicateIDs.contains($0) && seen.insert($0).inserted }
    }

    func removeAssets(_ ids: [String], from albumId: String) async throws {
        struct Body: Encodable {
            let ids: [String]
        }
        guard !ids.isEmpty else { return }
        let results: [BulkIDResponseDTO] = try await api.send(
            .json("/albums/\(albumId)/assets", method: .delete, body: Body(ids: ids)))
        let outcome = mutationResult(for: ids, results: results, allowDuplicates: false)
        guard outcome.failedIDs.isEmpty else { throw outcome }
    }

    private func mutationResult(
        for ids: [String], results: [BulkIDResponseDTO], allowDuplicates: Bool
    ) -> AlbumMutationError {
        let responses = Dictionary(grouping: results, by: \.id)
        var succeeded = Set<String>()
        var duplicates = Set<String>()
        var failed = Set<String>()
        for id in Set(ids) {
            guard let entries = responses[id], entries.count == 1,
                  let entry = entries.first else {
                failed.insert(id)
                continue
            }
            if entry.success {
                succeeded.insert(id)
            } else if allowDuplicates && entry.error == "duplicate" {
                duplicates.insert(id)
            } else {
                failed.insert(id)
            }
        }
        return AlbumMutationError(
            succeededIDs: succeeded, duplicateIDs: duplicates, failedIDs: failed)
    }

    func delete(_ id: String) async throws {
        try await api.sendVoid(.init(path: "/albums/\(id)", method: .delete))
    }
}
