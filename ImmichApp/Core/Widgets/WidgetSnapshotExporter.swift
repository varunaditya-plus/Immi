import Foundation
import WidgetKit

/// Menyiapkan data aman yang boleh dibaca extension widget.
///
/// Extension tidak menerima token Immich. Aplikasi utama mengunduh thumbnail
/// dengan sesi yang sudah terautentikasi, lalu hanya membagikan nama album,
/// label kenangan, id untuk deep link, dan byte gambar melalui App Group.
@MainActor
enum WidgetSnapshotExporter {
    static let appGroup = "group.xyz.0xmwehehe.ImmichApp"
    static let favoritesID = "__favorites__"
    static let selectedAlbumsKey = "widget.album.selectedIDs"
    private static let photosPerAlbum = 8
    private static var visibilityRevision = UUID()

    private struct Snapshot: Encodable {
        let generatedAt: Date
        let albums: [Album]
        let memories: [WidgetMemory]
    }

    private struct Album: Encodable {
        let id: String
        let name: String
        let assetCount: Int
        let imageNames: [String]
    }

    /// Penyegaran mandiri saat aplikasi dibuka. Widget tidak bergantung pada
    /// pengguna pernah masuk ke tab Library pada sesi ini.
    static func refresh(session: SessionManager) async {
        guard session.isLoggedIn else { return }
        guard let container = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: appGroup) else { return }
        let selectedIDs = Set(UserDefaults(suiteName: appGroup)?
            .stringArray(forKey: selectedAlbumsKey) ?? [])
        await refresh(api: APIClient(session: session), imageAPI: session.imageAPI,
            container: container, selectedAlbumIDs: selectedIDs)
    }

    static func refresh(
        api: APIClient, imageAPI: APIClient, container: URL, selectedAlbumIDs: Set<String>,
        dataManager: SwiftDataManager? = nil
    ) async {
        let dataManager = dataManager ?? .shared
        guard dataManager.isVisibilityStateAvailable else {
            clear(container: container)
            return
        }
        let isEligible: (String) -> Bool = { id in
            !dataManager.nonTimelineAssetIDs.contains(id)
                && !RemovedAssets.shared.ids.contains(id)
                && !DeletedServerAssetRegistry.shared.isTrashed(id)
                && !DeletedServerAssetRegistry.shared.isPermanentlyDeleted(id)
        }
        let expectedRevision = visibilityRevision
        let context = api.session.snapshot
        async let fetchedAlbums = try? AlbumRepository(api: api, recordsVisibility: false).all()
        async let fetchedMemories = try? MemoriesRepository(api: api, recordsVisibility: false).getMemories()
        async let fetchedFavorites = try? SearchRepository(api: api, recordsVisibility: false).metadataSearch(
            SearchRequestDTO(
                page: 1,
                isFavorite: true,
                size: Self.photosPerAlbum,
                visibility: "timeline"))
        let (allAlbums, allMemories, favoritesResponse) = await (
            fetchedAlbums, fetchedMemories, fetchedFavorites)
        guard expectedRevision == visibilityRevision,
              (try? api.checkCurrent(context)) != nil else { return }

        let albums = (allAlbums ?? LocalSnapshot.load(
            [AlbumResponseDTO].self,
            for: LocalSnapshot.Key.libraryAlbums) ?? [])
            .sorted { lhs, rhs in
                (lhs.updatedAt ?? lhs.createdAt) > (rhs.updatedAt ?? rhs.createdAt)
            }
        let memories = allMemories.map { entries in
            MemoryStory.build(from: entries.map { memory in
                MemoryDTO(id: memory.id, type: memory.type, memoryAt: memory.memoryAt,
                    assets: memory.assets.filter {
                        isEligible($0.id)
                    }, data: memory.data)
            }, limit: 15)
        } ?? []

        let albumRepo = AlbumRepository(api: api, recordsVisibility: false)
        let albumAssetIDs = await albumAssetIDs(
            for: selectedAlbumIDs, repository: albumRepo,
            isCurrent: {
                expectedRevision == visibilityRevision && (try? api.checkCurrent(context)) != nil
            })
            .mapValues { $0.filter(isEligible) }

        guard expectedRevision == visibilityRevision,
              (try? api.checkCurrent(context)) != nil else { return }
        let favoriteAssetIDs = favoritesResponse?.assets.items.filter {
            $0.isTimelineVisible && isEligible($0.id)
        }.map(\.id) ?? []
        let favoriteCount = favoritesResponse?.assets.total ?? favoriteAssetIDs.count

        await refresh(
            albums: albums,
            albumAssetIDs: albumAssetIDs,
            favoriteAssetIDs: favoriteAssetIDs,
            favoriteCount: favoriteCount,
            memories: memories,
            imageAPI: imageAPI,
            container: container,
            expectedRevision: expectedRevision,
            isCurrentAccount: { (try? api.checkCurrent(context)) != nil })
    }

    static func albumAssetIDs(
        for selectedIDs: Set<String>, repository: AlbumRepository,
        isCurrent: () -> Bool = { true }
    ) async -> [String: [String]] {
        var ids: [String: [String]] = [:]
        for albumID in selectedIDs where albumID != favoritesID {
            guard isCurrent(), !Task.isCancelled else { return [:] }
            guard let recent = try? await repository.recentAssetIDs(
                in: albumID, limit: photosPerAlbum, includeArchived: false) else { continue }
            guard isCurrent(), !Task.isCancelled else { return [:] }
            ids[albumID] = recent
        }
        return ids
    }

    private static func refresh(
        albums: [AlbumResponseDTO],
        albumAssetIDs: [String: [String]],
        favoriteAssetIDs: [String],
        favoriteCount: Int,
        memories: [MemoryStory],
        imageAPI: APIClient,
        container: URL,
        expectedRevision: UUID,
        isCurrentAccount: () -> Bool
    ) async {
        guard expectedRevision == visibilityRevision, isCurrentAccount() else { return }

        let root = container.appendingPathComponent("Widgets", isDirectory: true)
        let generation = UUID().uuidString
        let images = root.appendingPathComponent(generation, isDirectory: true)
        var published = false
        defer {
            if !published { try? FileManager.default.removeItem(at: images) }
        }
        do {
            try FileManager.default.createDirectory(
                at: images, withIntermediateDirectories: true)
        } catch {
            return
        }

        var requested: [String: String] = [:]

        for (index, assetID) in favoriteAssetIDs.enumerated() {
            requested["favorites-\(index).image"] = assetID
        }
        for album in albums {
            for (index, assetID) in (albumAssetIDs[album.id] ?? []).enumerated() {
                requested["album-\(album.id)-\(index).image"] = assetID
            }
        }
        for memory in memories {
            if let id = memory.cover?.id {
                requested["memory-\(memory.id).image"] = id
            }
        }

        var written = Set<String>()
        await withTaskGroup(of: (String, Data?).self) { group in
            for (name, assetID) in requested {
                group.addTask {
                    let endpoint = Endpoint(
                        path: "/assets/\(assetID)/thumbnail",
                        query: [.init(name: "size", value: "thumbnail")])
                    return (name, try? await imageAPI.rawData(endpoint))
                }
            }

            for await (name, data) in group {
                guard expectedRevision == visibilityRevision, isCurrentAccount() else {
                    group.cancelAll()
                    return
                }
                guard let data else { continue }
                let url = images.appendingPathComponent(name)
                if (try? data.write(to: url, options: .atomic)) != nil {
                    written.insert(name)
                }
            }
        }
        guard expectedRevision == visibilityRevision, isCurrentAccount() else { return }

        // Saat offline jangan mengganti widget bergambar yang masih valid
        // dengan snapshot baru yang seluruh gambarnya kosong.
        if !requested.isEmpty, written.isEmpty {
            return
        }

        let favoriteImageNames = favoriteAssetIDs.indices.compactMap { index in
            let name = "favorites-\(index).image"
            return written.contains(name) ? "\(generation)/\(name)" : nil
        }
        let favorites = Album(
            id: favoritesID,
            name: String(localized: "Favorites"),
            assetCount: favoriteCount,
            imageNames: favoriteImageNames)

        let wireAlbums = albums.map { album in
            let imageNames = (albumAssetIDs[album.id] ?? []).indices.compactMap { index in
                let name = "album-\(album.id)-\(index).image"
                return written.contains(name) ? "\(generation)/\(name)" : nil
            }
            return Album(
                id: album.id,
                name: album.albumName,
                assetCount: album.assetCount,
                imageNames: imageNames)
        }
        let wireMemories = memories.map { memory in
            let name = "memory-\(memory.id).image"
            return WidgetMemory(
                id: memory.id,
                title: memory.title,
                subtitle: memory.subtitle,
                imageName: written.contains(name) ? "\(generation)/\(name)" : nil,
                memoryAt: memory.memoryAt, yearsAgo: memory.yearsAgo)
        }

        let snapshot = Snapshot(
            generatedAt: Date(), albums: [favorites] + wireAlbums, memories: wireMemories)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(snapshot) else { return }

        let snapshotURL = root.appendingPathComponent("snapshot.json")
        do {
            try data.write(to: snapshotURL, options: .atomic)
            published = true
        } catch {
            return
        }

        // Simpan dua generasi terbaru. Extension dapat saja sudah membaca JSON
        // lama tepat sebelum penggantian atomik; mempertahankan satu generasi
        // sebelumnya mencegah gambarnya hilang di tengah render.
        if let contents = try? FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: [.contentModificationDateKey]) {
            let generations = contents
                .filter(\.hasDirectoryPath)
                .sorted {
                    let lhsValues = try? $0.resourceValues(
                        forKeys: [.contentModificationDateKey])
                    let rhsValues = try? $1.resourceValues(
                        forKeys: [.contentModificationDateKey])
                    let lhs = lhsValues?.contentModificationDate ?? .distantPast
                    let rhs = rhsValues?.contentModificationDate ?? .distantPast
                    return lhs > rhs
                }
            for url in generations.dropFirst(2) {
                try? FileManager.default.removeItem(at: url)
            }
        }

        WidgetCenter.shared.reloadAllTimelines()
    }

    static func clear(container: URL? = nil) {
        visibilityRevision = UUID()
        guard let container = container ?? FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: appGroup)
        else { return }
        try? FileManager.default.removeItem(
            at: container.appendingPathComponent("Widgets", isDirectory: true))
        WidgetCenter.shared.reloadAllTimelines()
    }
}
