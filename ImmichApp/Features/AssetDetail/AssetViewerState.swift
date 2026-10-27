import Foundation
import Observation

@MainActor
@Observable
final class AssetViewerState {
    struct Target: Identifiable {
        let asset: AssetLite
        let serverID: String?
        let detail: AssetResponseDTO?
        let visit: UUID
        var id: UUID { visit }
    }

    enum Preparation: Hashable { case share, editor, sharedLink }

    // AssetLite equality deliberately compares IDs only. A non-Equatable
    // container makes changes to origin/favorite observable without changing
    // the equality contract used by the pager and other app screens.
    private struct PageStorage { var assets: [AssetLite] }
    private struct Selection {
        var index: Int
        var fallback: AssetLite
        var visit = UUID()
    }

    private var storage: PageStorage
    private var selection: Selection
    private var isActive = true
    private var preparations: [Preparation: Set<UUID>] = [:]
    private var downloadingIDs: Set<String> = []
    private var uploadingIDs: Set<String> = []
    private var removingIDs: Set<String> = []

    var pages: [AssetLite] { storage.assets }
    var currentIndex: Int { selection.index }
    var currentAsset: AssetLite {
        storage.assets.indices.contains(selection.index) ? storage.assets[selection.index] : selection.fallback
    }
    var visit: UUID { selection.visit }
    var isEmpty: Bool { storage.assets.isEmpty }

    init(currentAsset: AssetLite, assets: [AssetLite]) {
        var pages = assets
        if let index = pages.firstIndex(where: { $0.id == currentAsset.id }) {
            pages[index] = currentAsset
        } else {
            pages.insert(currentAsset, at: 0)
        }
        storage = PageStorage(assets: pages)
        selection = Selection(index: pages.firstIndex(where: { $0.id == currentAsset.id }) ?? 0, fallback: currentAsset)
    }

    func target(serverID: String?, detail: AssetResponseDTO?) -> Target {
        Target(asset: currentAsset, serverID: serverID,
            detail: detail?.id == serverID ? detail : nil, visit: selection.visit)
    }

    func isCurrent(_ target: Target) -> Bool {
        isActive && target.visit == selection.visit && target.asset.id == currentAsset.id
            && storage.assets.contains(where: { $0.id == target.asset.id })
    }

    @discardableResult
    func select(_ id: String) -> Bool {
        guard let index = storage.assets.firstIndex(where: { $0.id == id }) else { return false }
        guard currentAsset.id != id else { return true }
        selection = Selection(index: index, fallback: storage.assets[index])
        return true
    }

    func activate() { isActive = true }

    func deactivate() {
        isActive = false
        selection.visit = UUID()
    }

    func isPreparing(_ kind: Preparation) -> Bool {
        preparations[kind]?.contains(selection.visit) == true
    }

    @discardableResult
    func prepare<Value>(
        _ target: Target, kind: Preparation,
        operation: @escaping @MainActor () async -> Value?,
        discard: @escaping @MainActor (Value) -> Void = { _ in },
        completion: @escaping @MainActor (Value) async -> Void
    ) -> Task<Void, Never>? {
        guard isCurrent(target), preparations[kind]?.contains(target.visit) != true else { return nil }
        preparations[kind, default: []].insert(target.visit)
        return Task {
            defer { preparations[kind]?.remove(target.visit) }
            guard isCurrent(target), !Task.isCancelled else { return }
            guard let value = await operation() else { return }
            guard isCurrent(target), !Task.isCancelled else {
                discard(value)
                return
            }
            await completion(value)
        }
    }

    @discardableResult
    func prepareEditor<Value>(
        _ target: Target,
        operation: @escaping @MainActor () async -> Value?,
        completion: @escaping @MainActor (Value) async -> Void
    ) -> Task<Void, Never>? {
        prepare(target, kind: .editor, operation: operation) { value in
            self.deactivate()
            await completion(value)
        }
    }

    @discardableResult
    func remove(
        _ target: Target,
        operation: @escaping @MainActor () async -> Bool,
        completion: @escaping @MainActor (_ isPresented: Bool) -> Void
    ) -> Task<Void, Never>? {
        guard storage.assets.contains(where: { $0.id == target.asset.id }),
              removingIDs.insert(target.asset.id).inserted else { return nil }
        return Task {
            defer { removingIDs.remove(target.asset.id) }
            guard !Task.isCancelled, await operation() else { return }
            removePage(target.asset.id)
            completion(isActive)
        }
    }

    @discardableResult
    func removePage(_ id: String) -> Bool {
        guard let removedIndex = storage.assets.firstIndex(where: { $0.id == id }) else { return false }
        let selected = currentAsset
        storage.assets.removeAll { $0.id == id }
        if storage.assets.isEmpty {
            selection = Selection(index: 0, fallback: selected)
        } else if selected.id == id {
            let next = min(removedIndex, storage.assets.count - 1)
            selection = Selection(index: next, fallback: storage.assets[next])
        } else if let selectedIndex = storage.assets.firstIndex(where: { $0.id == selected.id }) {
            selection.index = selectedIndex
        }
        return true
    }

    func setFavorite(_ value: Bool, for id: String) {
        guard let index = storage.assets.firstIndex(where: { $0.id == id }) else { return }
        storage.assets[index].isFavorite = value
    }

    func setOrigin(_ origin: AssetOrigin, for id: String) {
        guard let index = storage.assets.firstIndex(where: { $0.id == id }) else { return }
        storage.assets[index].origin = origin
    }

    func isDownloading(_ id: String) -> Bool { downloadingIDs.contains(id) }

    @discardableResult
    func download(
        _ target: Target,
        operation: @escaping @MainActor () async -> Bool
    ) -> Task<Void, Never>? {
        guard storage.assets.contains(where: { $0.id == target.asset.id }),
              downloadingIDs.insert(target.asset.id).inserted else { return nil }
        return Task {
            defer { downloadingIDs.remove(target.asset.id) }
            guard !Task.isCancelled, await operation() else { return }
            setOrigin(.both, for: target.asset.id)
        }
    }

    func isUploading(_ id: String) -> Bool { uploadingIDs.contains(id) }
    func beginUpload(_ id: String) -> Bool { uploadingIDs.insert(id).inserted }
    func finishUpload(_ id: String) { uploadingIDs.remove(id) }

    /// Mapping commits, rather than enqueue completion, determine whether a
    /// device page has become backed up. Keep display IDs stable while changing
    /// the available actions and the server ID used for metadata requests.
    func refreshUploadedCopies(
        using manager: SwiftDataManager,
        existingLocalIDs: ([String]) -> Set<String> = LocalPhotoLibrary.existingLocalIdentifiers
    ) {
        let localIDs = storage.assets.compactMap { asset -> String? in
            guard asset.origin == .device, LocalPhotoLibrary.isLocal(asset.id) else { return nil }
            return LocalPhotoLibrary.localIdentifier(from: asset.id)
        }
        guard !localIDs.isEmpty else { return }
        let mappings = manager.serverAssetIDsByLocalIdentifier()
        let mappedLocalIDs = localIDs.filter { mappings[$0]?.isEmpty == false }
        guard !mappedLocalIDs.isEmpty else { return }
        let existing = existingLocalIDs(mappedLocalIDs)

        for index in storage.assets.indices {
            let asset = storage.assets[index]
            guard LocalPhotoLibrary.isLocal(asset.id) else { continue }
            let localID = LocalPhotoLibrary.localIdentifier(from: asset.id)
            guard existing.contains(localID), mappings[localID]?.isEmpty == false else { continue }
            if asset.origin != .both { storage.assets[index].origin = .both }
            uploadingIDs.remove(asset.id)
        }
    }
}
