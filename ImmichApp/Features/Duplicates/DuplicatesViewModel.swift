import Foundation
import Observation

@MainActor
@Observable
final class DuplicatesViewModel {
    private let accountGeneration = LocalSnapshot.generation

    var groups: [DuplicateGroupDTO] = []
    var phase: LoadingPhase<Void> = .idle
    var actionError: String?
    private(set) var workingGroupIDs: Set<String> = []

    private let repository: DuplicateRepository
    private let assetRepository: AssetDetailRepository
    private let usesResolveEndpoint: Bool

    init(
        repository: DuplicateRepository,
        assetRepository: AssetDetailRepository,
        usesResolveEndpoint: Bool
    ) {
        self.repository = repository
        self.assetRepository = assetRepository
        self.usesResolveEndpoint = usesResolveEndpoint
    }

    func load() async {
        if groups.isEmpty { phase = .loading }
        do {
            groups = try await repository.all().filter { $0.assets.count > 1 }
            phase = .loaded(())
        } catch {
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
                guard accountGeneration == LocalSnapshot.generation else { return }
                // Server memindahkan aset ke Trash di luar AssetDetailRepository,
                // jadi registry lokal harus diberi tahu agar backup tidak segera
                // mengunggah salinan perangkatnya lagi.
                DeletedServerAssetRegistry.shared.record(
                    Array(trashed), permanently: false)
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
            remove(group.id)
        } catch {
            actionError = Self.message(for: error, fallback: "Failed to keep all items")
        }
    }

    private func remove(_ id: String) {
        groups.removeAll { $0.id == id }
        phase = .loaded(())
    }

    private static func message(for error: Error, fallback: String.LocalizationValue) -> String {
        (error as? APIError)?.errorDescription ?? String(localized: fallback)
    }
}
