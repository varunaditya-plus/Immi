import Foundation
import Observation

@MainActor
@Observable
final class DuplicatesViewModel {
    private let accountGeneration = LocalSnapshot.generation

    private var loadedGroups: [DuplicateGroupDTO] = []
    var groups: [DuplicateGroupDTO] {
        get {
            guard accountGeneration == LocalSnapshot.generation else { return [] }
            let policy = AssetVisibilityPolicy(scope: .collection, dataManager: dataManager)
            return loadedGroups.compactMap { group in
                let assets = group.assets.filter { $0.isVisibleInAlbum && policy.allows(id: $0.id) }
                guard assets.count > 1 else { return nil }
                return DuplicateGroupDTO(duplicateId: group.id, assets: assets,
                                         suggestedKeepAssetIds: group.suggestedKeepAssetIds)
            }
        }
        set { loadedGroups = newValue }
    }
    var phase: LoadingPhase<Void> = .idle
    var actionError: String?
    private(set) var workingGroupIDs: Set<String> = []

    private let repository: DuplicateRepository
    private let assetRepository: AssetDetailRepository
    private let usesResolveEndpoint: Bool
    private let dataManager: SwiftDataManager
    private var loadRevision = UUID()

    init(
        repository: DuplicateRepository,
        assetRepository: AssetDetailRepository,
        usesResolveEndpoint: Bool,
        dataManager: SwiftDataManager? = nil
    ) {
        self.repository = repository
        self.assetRepository = assetRepository
        self.usesResolveEndpoint = usesResolveEndpoint
        self.dataManager = dataManager ?? .shared
    }

    func load() async {
        let revision = UUID()
        loadRevision = revision
        if groups.isEmpty { phase = .loading }
        do {
            let loaded = try await repository.all()
            try Task.checkCancellation()
            guard revision == loadRevision, accountGeneration == LocalSnapshot.generation else { return }
            loadedGroups = loaded
            phase = .loaded(())
        } catch {
            guard revision == loadRevision, accountGeneration == LocalSnapshot.generation else { return }
            if Task.isCancelled || error is CancellationError {
                if groups.isEmpty { phase = .idle }
                return
            }
            let message = Self.message(for: error, fallback: "Failed to load duplicates")
            if groups.isEmpty {
                phase = .failed(message)
            } else {
                actionError = message
            }
        }
    }

    func resolve(_ group: DuplicateGroupDTO, keeping keepIDs: Set<String>) async {
        guard !workingGroupIDs.contains(group.id) else { return }

        let allIDs = Set(group.assets.map(\.id))
        let kept = keepIDs.intersection(allIDs)
        let trashed = allIDs.subtracting(kept)
        guard !kept.isEmpty, !trashed.isEmpty else { return }

        workingGroupIDs.insert(group.id)
        defer { workingGroupIDs.remove(group.id) }

        do {
            if usesResolveEndpoint {
                try await repository.resolve(.init(
                    duplicateId: group.id,
                    keepAssetIds: kept.sorted(),
                    trashAssetIds: trashed.sorted()))
            } else {
                // API v2 belum punya /duplicates/resolve. Perilaku yang paling
                // dekat adalah memindahkan pilihan ke Trash lalu melepas grup.
                try await assetRepository.delete(Array(trashed))
                // Pemindahan asetnya sudah final pada titik ini. Kegagalan
                // melepas label grup tidak boleh dilaporkan sebagai kegagalan
                // seluruh aksi (dan membuat pengguna menghapusnya lagi); GET
                // berikutnya juga membersihkan grup yang tinggal satu aset.
                try? await repository.dismiss(group.id)
            }
            guard accountGeneration == LocalSnapshot.generation else { return }
            remove(group.id)
        } catch {
            actionError = Self.message(for: error, fallback: "Failed to resolve duplicates")
        }
    }

    func keepAll(_ group: DuplicateGroupDTO) async {
        guard !workingGroupIDs.contains(group.id) else { return }
        workingGroupIDs.insert(group.id)
        defer { workingGroupIDs.remove(group.id) }

        do {
            try await repository.dismiss(group.id)
            guard accountGeneration == LocalSnapshot.generation else { return }
            remove(group.id)
        } catch {
            actionError = Self.message(for: error, fallback: "Failed to keep all items")
        }
    }

    private func remove(_ id: String) {
        loadRevision = UUID()
        loadedGroups.removeAll { $0.id == id }
        phase = .loaded(())
    }

    private static func message(for error: Error, fallback: String.LocalizationValue) -> String {
        (error as? APIError)?.errorDescription ?? String(localized: fallback)
    }
}
