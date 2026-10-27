import Foundation

/// Satu operasi editor yang dipahami endpoint Immich `/assets/{id}/edits`.
struct AssetEditCommand: Encodable, Sendable {
    enum Payload: Sendable {
        case crop(x: Int, y: Int, width: Int, height: Int)
        case rotate(angle: Double)
        case mirror(axis: String)
    }

    let payload: Payload

    private enum CodingKeys: String, CodingKey { case action, parameters }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch payload {
        case .crop(let x, let y, let width, let height):
            struct Parameters: Encodable { let x: Int; let y: Int; let width: Int; let height: Int }
            try container.encode("crop", forKey: .action)
            try container.encode(
                Parameters(x: x, y: y, width: width, height: height),
                forKey: .parameters)
        case .rotate(let angle):
            struct Parameters: Encodable { let angle: Double }
            try container.encode("rotate", forKey: .action)
            try container.encode(Parameters(angle: angle), forKey: .parameters)
        case .mirror(let axis):
            struct Parameters: Encodable { let axis: String }
            try container.encode("mirror", forKey: .action)
            try container.encode(Parameters(axis: axis), forKey: .parameters)
        }
    }
}

struct AssetEditRecord: Decodable, Sendable {
    struct Parameters: Decodable, Sendable {
        let x: Int?
        let y: Int?
        let width: Int?
        let height: Int?
        let angle: Double?
        let axis: String?
    }

    let action: String
    let parameters: Parameters
}

class AssetDetailRepository {
    private let api: APIClient
    private let dataManager: SwiftDataManager?

    init(api: APIClient, dataManager: SwiftDataManager? = nil) {
        self.api = api
        self.dataManager = dataManager
    }

    func fetchAsset(_ id: String) async throws -> AssetResponseDTO {
        try await api.send(.init(path: "/assets/\(id)"))
    }

    func toggleFavorite(_ id: String, to value: Bool) async throws {
        try await update(id, with: AssetMutation(isFavorite: value))
    }

    /// Immich menerima `description` di level atas UpdateAssetDto, walau
    /// membacanya kembali lewat `exifInfo.description`.
    func updateDescription(_ id: String, to text: String) async throws {
        try await update(id, with: AssetMutation(description: text))
    }

    func updateDate(_ id: String, to date: Date) async throws {
        let text = ISO8601DateFormatter.immichFractional.string(from: date)
        try await update(id, with: AssetMutation(dateTimeOriginal: text))
    }

    func updateLocation(_ id: String, latitude: Double, longitude: Double) async throws {
        try await update(id, with: AssetMutation(latitude: latitude, longitude: longitude))
    }

    func toggleArchive(_ id: String, to value: Bool) async throws {
        try await setVisibility(id, to: value ? .archive : .timeline)
    }

    /// Nilai yang diterima Immich untuk `visibility` pada UpdateAssetDto.
    enum Visibility: String {
        case timeline
        case archive
        case locked
    }

    @MainActor
    func setVisibility(_ id: String, to value: Visibility) async throws {
        try await update(id, with: AssetMutation(visibility: value.rawValue))
    }

    /// Compatibility shim untuk satu-satunya kontrak mutasi asset yang tersedia
    /// pada OpenAPI Immich v3.1.0. Route ini ditandai deprecated, tetapi
    /// `replacementId` resmi masih menunjuk kembali ke operation yang sama dan
    /// belum ada endpoint stabil untuk favorite/description/date/location/
    /// visibility. Disatukan di sini agar penggantian berikutnya hanya satu edit.
    @MainActor
    private func update(_ id: String, with mutation: AssetMutation) async throws {
        let context = api.session.snapshot
        let snapshotGeneration = LocalSnapshot.generation
        try await api.sendVoid(.json("/assets/\(id)", method: .put, body: mutation))
        try api.checkCurrent(context)
        guard snapshotGeneration == LocalSnapshot.generation else { throw CancellationError() }
        try cacheMutation(mutation, for: id, expectedGeneration: snapshotGeneration)
    }

    @MainActor
    private func cacheMutation(_ mutation: AssetMutation, for id: String, expectedGeneration: UUID) throws {
        let cache = dataManager ?? .shared
        if let visibility = mutation.visibility {
            try cache.setTimelineVisibility([id], inTimeline: visibility == Visibility.timeline.rawValue)
        } else {
            try? cache.patchCachedAsset(id,
                isFavorite: mutation.isFavorite,
                createdAt: mutation.dateTimeOriginal.flatMap(ISO8601DateFormatter.immichFractional.date(from:)),
                description: mutation.description,
                latitude: mutation.latitude,
                longitude: mutation.longitude)
        }

        let key = LocalSnapshot.Key.assetDetail(id)
        guard var cached = LocalSnapshot.load(AssetResponseDTO.self, for: key), cached.id == id else { return }
        if let favorite = mutation.isFavorite {
            cached.isFavorite = favorite
        } else if let description = mutation.description {
            cached.setDescription(description)
        } else if let visibility = mutation.visibility, visibility != Visibility.locked.rawValue {
            cached.isArchived = visibility == Visibility.archive.rawValue
            cached.visibility = visibility
        } else {
            // Derived metadata is refreshed by the detail view. Other callers
            // must not leave an obsolete detail snapshot behind.
            LocalSnapshot.remove(key, expectedGeneration: expectedGeneration)
            return
        }
        LocalSnapshot.save(cached, for: key, expectedGeneration: expectedGeneration)
    }

    private struct AssetMutation: Encodable {
        var isFavorite: Bool? = nil
        var description: String? = nil
        var dateTimeOriginal: String? = nil
        var latitude: Double? = nil
        var longitude: Double? = nil
        var visibility: String? = nil
    }

    func delete(_ id: String) async throws {
        try await delete([id])
    }

    /// Endpoint-nya memang menerima banyak id sekaligus, jadi seleksi tidak
    /// perlu mengirim satu request per foto.
    ///
    /// - Parameter force: `false` memindahkan ke tong sampah, `true` menghapus
    ///   permanen. Layar tong sampah memakai `true` — di sana "hapus" memang
    ///   tidak punya tempat lain untuk dituju.
    @MainActor
    func delete(_ ids: [String], force: Bool = false) async throws {
        let context = api.session.snapshot
        let snapshotGeneration = LocalSnapshot.generation
        struct Body: Encodable { let ids: [String]; let force: Bool }
        try await api.sendVoid(.json("/assets", method: .delete, body: Body(ids: ids, force: force)))
        try api.checkCurrent(context)
        guard snapshotGeneration == LocalSnapshot.generation else { throw CancellationError() }
        // Mapping backup tetap diperlukan agar foto lokal tidak di-upload ulang.
        // Penanda terpisah ini mencegah mapping tersebut membuat foto yang baru
        // dihapus muncul kembali sebagai petak lokal setelah app restart.
        DeletedServerAssetRegistry.shared.record(ids, permanently: force)
        cacheDeletedAssets(ids, permanently: force, expectedGeneration: snapshotGeneration)
    }

    @MainActor
    private func cacheDeletedAssets(_ ids: [String], permanently: Bool, expectedGeneration: UUID) {
        try? (dataManager ?? .shared).purgeAssets(ids, reason: permanently ? .unavailable : .trashed)
        for id in ids {
            LocalSnapshot.remove(LocalSnapshot.Key.assetDetail(id), expectedGeneration: expectedGeneration)
        }
    }

    func downloadOriginal(_ id: String) async throws -> Data {
        try await api.rawData(.init(path: "/assets/\(id)/original"))
    }

    /// Original/hasil edit diunduh sebagai file agar video tidak masuk RAM.
    func downloadOriginalFile(_ id: String, filename: String) async throws -> URL {
        let temporary = try await api.rawFile(.init(
            path: "/assets/\(id)/original",
            query: [.init(name: "edited", value: "true")]))
        let safeName = URL(fileURLWithPath: filename).lastPathComponent
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("asset-\(UUID().uuidString)-\(safeName)")
        try FileManager.default.moveItem(at: temporary, to: destination)
        return destination
    }

    @MainActor
    func applyEdits(_ edits: [AssetEditCommand], to id: String) async throws {
        let context = api.session.snapshot
        let snapshotGeneration = LocalSnapshot.generation
        struct Body: Encodable { let edits: [AssetEditCommand] }
        struct Response: Decodable { let assetId: String }
        let _: Response = try await api.send(.json(
            "/assets/\(id)/edits", method: .put, body: Body(edits: edits)))
        try api.checkCurrent(context)
        LocalSnapshot.remove(LocalSnapshot.Key.assetDetail(id), expectedGeneration: snapshotGeneration)
    }

    @MainActor
    func removeEdits(from id: String) async throws {
        let context = api.session.snapshot
        let snapshotGeneration = LocalSnapshot.generation
        try await api.sendVoid(.init(path: "/assets/\(id)/edits", method: .delete))
        try api.checkCurrent(context)
        LocalSnapshot.remove(LocalSnapshot.Key.assetDetail(id), expectedGeneration: snapshotGeneration)
    }

    func edits(for id: String) async throws -> [AssetEditRecord] {
        struct Response: Decodable { let edits: [AssetEditRecord] }
        let response: Response = try await api.send(.init(path: "/assets/\(id)/edits"))
        return response.edits
    }

    /// Immich menerima avatar sebagai multipart dengan nama field `file`.
    func setProfileImage(_ data: Data, filename: String) async throws {
        struct Response: Decodable { let profileImagePath: String }

        let boundary = "Profile-\(UUID().uuidString)"
        var body = Data()
        func append(_ text: String) {
            if let bytes = text.data(using: .utf8) { body.append(bytes) }
        }
        append("--\(boundary)\r\n")
        append("Content-Disposition: form-data; name=\"file\"; filename=\"\(filename)\"\r\n")
        append("Content-Type: image/jpeg\r\n\r\n")
        body.append(data)
        append("\r\n--\(boundary)--\r\n")

        let _: Response = try await api.send(.init(
            path: "/users/profile-image",
            method: .post,
            body: body,
            extraHeaders: ["Content-Type": "multipart/form-data; boundary=\(boundary)"]))
    }
}
