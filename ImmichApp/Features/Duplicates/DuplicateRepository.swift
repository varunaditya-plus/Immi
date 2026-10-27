import Foundation

final class DuplicateRepository {
    private let api: APIClient
    private let dataManager: SwiftDataManager?

    init(api: APIClient, dataManager: SwiftDataManager? = nil) {
        self.api = api
        self.dataManager = dataManager
    }

    /// GET /duplicates mengembalikan array grup secara langsung.
    func all() async throws -> [DuplicateGroupDTO] {
        let visibility = await AssetVisibilityRequest(api: api, dataManager: dataManager)
        let groups: [DuplicateGroupDTO] = try await api.send(.init(path: "/duplicates"))
        await visibility.record(groups.flatMap(\.assets))
        return groups
    }

    /// Menyatukan metadata grup dan memindahkan aset yang tidak dipertahankan
    /// ke Trash. Responsnya tetap perlu diperiksa: operasi bulk dapat berstatus
    /// HTTP 200 sementara satu grup di dalamnya gagal.
    @MainActor
    func resolve(_ group: DuplicateResolveGroupDTO) async throws {
        let context = api.session.snapshot
        let snapshotGeneration = LocalSnapshot.generation
        let results: [BulkIDResponseDTO] = try await api.send(.json(
            "/duplicates/resolve",
            method: .post,
            body: DuplicateResolveRequestDTO(groups: [group])))

        guard let result = results.first(where: { $0.id == group.duplicateId }),
              result.success
        else {
            let failure = results.first(where: { $0.id == group.duplicateId })
            throw APIError.server(
                status: 200,
                message: failure?.errorMessage ?? String(localized: "Failed to resolve duplicates"))
        }
        try api.checkCurrent(context)
        guard snapshotGeneration == LocalSnapshot.generation else { throw CancellationError() }
        DeletedServerAssetRegistry.shared.record(group.trashAssetIds, permanently: false)
        try? (dataManager ?? .shared).purgeAssets(group.trashAssetIds, reason: .trashed)
        for id in group.trashAssetIds {
            LocalSnapshot.remove(LocalSnapshot.Key.assetDetail(id), expectedGeneration: snapshotGeneration)
        }
    }

    /// Menghapus *penanda grup*, bukan asetnya. Ini adalah aksi "Keep All".
    func dismiss(_ duplicateId: String) async throws {
        try await api.sendVoid(.init(
            path: "/duplicates/\(duplicateId)", method: .delete))
    }
}
