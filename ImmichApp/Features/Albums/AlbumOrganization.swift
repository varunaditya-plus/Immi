import CryptoKit
import Foundation
import Observation

struct AlbumFolder: Codable, Identifiable, Hashable {
    let id: String
    var name: String
    var parentID: String?
}

enum AlbumPhotoSort: String, Codable {
    case custom, oldestFirst, newestFirst
}

enum AlbumPhotoFilter: String, Codable {
    case all, favorites, photos, videos
}

struct AlbumOrganization: Codable, Equatable {
    var folders: [AlbumFolder] = []
    var albumFolders: [String: String] = [:]
    var containerOrders: [String: [String]] = [:]
    var photoOrders: [String: [String]] = [:]
    var photoSorts: [String: AlbumPhotoSort] = [:]
    var photoFilters: [String: AlbumPhotoFilter] = [:]

    static func albumEntry(_ id: String) -> String { "album:\(id)" }
    static func folderEntry(_ id: String) -> String { "folder:\(id)" }
    static func container(_ id: String?) -> String { id ?? "root" }
    static let sharedContainer = "shared"

    func childFolders(of parentID: String?) -> [AlbumFolder] {
        let children = folders.filter { $0.parentID == parentID }
        let ranks = ranks(for: containerOrders[Self.container(parentID)] ?? [])
        return children.sorted {
            let a = ranks[Self.folderEntry($0.id)] ?? Int.max
            let b = ranks[Self.folderEntry($1.id)] ?? Int.max
            return a == b ? $0.name.localizedStandardCompare($1.name) == .orderedAscending : a < b
        }
    }

    func albums(_ albums: [AlbumResponseDTO], in folderID: String?) -> [AlbumResponseDTO] {
        let validFolderIDs = Set(folders.map(\.id))
        return albums.filter {
            let parent = albumFolders[$0.id].flatMap { validFolderIDs.contains($0) ? $0 : nil }
            return parent == folderID
        }
    }

    func orderedAlbums(_ albums: [AlbumResponseDTO], in folderID: String? = nil,
                       ignoringFolders: Bool = false) -> [AlbumResponseDTO] {
        let ranks = ranks(for: containerOrders[ignoringFolders ? Self.sharedContainer : Self.container(folderID)] ?? [])
        return (ignoringFolders ? albums : self.albums(albums, in: folderID)).sorted {
            let a = ranks[Self.albumEntry($0.id)] ?? Int.max
            let b = ranks[Self.albumEntry($1.id)] ?? Int.max
            if a != b { return a < b }
            if $0.createdAt != $1.createdAt { return $0.createdAt > $1.createdAt }
            return $0.id < $1.id
        }
    }

    func orderedPhotos(_ assets: [AssetLite], albumID: String) -> [AssetLite] {
        let sorted: [AssetLite]
        switch photoSorts[albumID] ?? .oldestFirst {
        case .custom:
            let positions = ranks(for: photoOrders[albumID] ?? [])
            sorted = assets.sorted {
                let a = positions[$0.id] ?? Int.max
                let b = positions[$1.id] ?? Int.max
                return a == b ? chronological($0, $1) : a < b
            }
        case .oldestFirst:
            sorted = assets.sorted(by: chronological)
        case .newestFirst:
            sorted = assets.sorted { chronological($1, $0) }
        }
        switch photoFilters[albumID] ?? .all {
        case .all: return sorted
        case .favorites: return sorted.filter(\.isFavorite)
        case .photos: return sorted.filter { !$0.isVideo }
        case .videos: return sorted.filter(\.isVideo)
        }
    }

    private func chronological(_ a: AssetLite, _ b: AssetLite) -> Bool {
        a.createdAt == b.createdAt ? a.id < b.id : a.createdAt < b.createdAt
    }

    private func ranks(for ids: [String]) -> [String: Int] {
        var result: [String: Int] = [:]
        for (index, id) in ids.enumerated() where result[id] == nil { result[id] = index }
        return result
    }
}

@MainActor
@Observable
final class AlbumsOrganizationStore {
    private(set) var value: AlbumOrganization
    private let generation = LocalSnapshot.generation
    private let defaults: UserDefaults
    private let key: String?

    init(owner: BackupQueueOwner?, defaults: UserDefaults = .standard) {
        self.defaults = defaults
        key = owner.map {
            let identity = "\($0.server)\n\($0.userID)"
            let digest = SHA256.hash(data: Data(identity.utf8)).map { String(format: "%02x", $0) }.joined()
            return "albums.organization.v1.\(digest)"
        }
        value = key.flatMap { defaults.data(forKey: $0) }
            .flatMap { try? JSONDecoder().decode(AlbumOrganization.self, from: $0) } ?? AlbumOrganization()
    }

    var isCurrent: Bool { generation == LocalSnapshot.generation }

    func orderedAlbums(_ albums: [AlbumResponseDTO], in folderID: String? = nil) -> [AlbumResponseDTO] {
        value.orderedAlbums(albums, in: folderID)
    }

    @discardableResult
    func createFolder(name: String, parentID: String?) -> AlbumFolder? {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isCurrent, !name.isEmpty else { return nil }
        var created: AlbumFolder?
        change { state in
            guard parentID == nil || state.folders.contains(where: { $0.id == parentID }) else { return }
            let folder = AlbumFolder(id: UUID().uuidString, name: name, parentID: parentID)
            state.folders.append(folder)
            created = folder
        }
        return created
    }

    func renameFolder(_ id: String, to name: String) {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        change {
            guard let index = $0.folders.firstIndex(where: { $0.id == id }) else { return }
            $0.folders[index].name = name
        }
    }

    func removeFolder(_ id: String) {
        change { state in
            guard let folder = state.folders.first(where: { $0.id == id }) else { return }
            state.folders.removeAll { $0.id == id }
            for index in state.folders.indices where state.folders[index].parentID == id {
                state.folders[index].parentID = folder.parentID
            }
            for (album, parent) in state.albumFolders where parent == id {
                state.albumFolders[album] = folder.parentID
            }
            state.containerOrders.removeValue(forKey: AlbumOrganization.container(id))
            for container in Array(state.containerOrders.keys) {
                state.containerOrders[container]?.removeAll { $0 == AlbumOrganization.folderEntry(id) }
            }
        }
    }

    func moveAlbum(_ id: String, to folderID: String?) {
        change {
            guard folderID == nil || $0.folders.contains(where: { $0.id == folderID }) else { return }
            $0.albumFolders[id] = folderID
            for container in Array($0.containerOrders.keys) where container != AlbumOrganization.sharedContainer {
                $0.containerOrders[container]?.removeAll { $0 == AlbumOrganization.albumEntry(id) }
            }
        }
    }

    func setContainerOrder(_ ids: [String], in folderID: String?) {
        change { $0.containerOrders[AlbumOrganization.container(folderID)] = unique(ids) }
    }

    func removeAlbum(_ id: String) {
        change {
            $0.albumFolders.removeValue(forKey: id)
            $0.photoOrders.removeValue(forKey: id)
            $0.photoSorts.removeValue(forKey: id)
            $0.photoFilters.removeValue(forKey: id)
            for container in Array($0.containerOrders.keys) {
                $0.containerOrders[container]?.removeAll { $0 == AlbumOrganization.albumEntry(id) }
            }
        }
    }

    func reconcileAlbums(_ validIDs: Set<String>) {
        change { state in
            state.albumFolders = state.albumFolders.filter { validIDs.contains($0.key) }
            state.photoOrders = state.photoOrders.filter { validIDs.contains($0.key) }
            state.photoSorts = state.photoSorts.filter { validIDs.contains($0.key) }
            state.photoFilters = state.photoFilters.filter { validIDs.contains($0.key) }
            for key in Array(state.containerOrders.keys) {
                state.containerOrders[key]?.removeAll {
                    $0.hasPrefix("album:") && !validIDs.contains(String($0.dropFirst(6)))
                }
            }
        }
    }

    func setPhotoOrder(_ ids: [String], albumID: String) {
        change {
            $0.photoOrders[albumID] = unique(ids)
            $0.photoSorts[albumID] = .custom
        }
    }

    func setPhotoSort(_ sort: AlbumPhotoSort, albumID: String) {
        change { $0.photoSorts[albumID] = sort }
    }

    func setPhotoFilter(_ filter: AlbumPhotoFilter, albumID: String) {
        change { $0.photoFilters[albumID] = filter }
    }

    private func unique(_ ids: [String]) -> [String] {
        var seen = Set<String>()
        return ids.filter { seen.insert($0).inserted }
    }

    private func change(_ operation: (inout AlbumOrganization) -> Void) {
        guard isCurrent else { return }
        // Separate entry points can own stores for the same account. Merge
        // each mutation into the latest saved state instead of an old copy.
        let saved = key.flatMap { defaults.data(forKey: $0) }
            .flatMap { try? JSONDecoder().decode(AlbumOrganization.self, from: $0) } ?? value
        var updated = saved
        operation(&updated)
        if updated != value { value = updated }
        guard updated != saved else { return }
        if let key, let data = try? JSONEncoder().encode(value) { defaults.set(data, forKey: key) }
    }
}
