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
    private static var accountGeneration = UUID()

    private struct Snapshot: Encodable {
        let generatedAt: Date
        let albums: [Album]
        let memories: [Memory]
    }

    private struct Album: Encodable {
        let id: String
        let name: String
        let assetCount: Int
        let imageNames: [String]
    }

    private struct Memory: Encodable {
        let id: String
        let title: String
        let subtitle: String
        let imageName: String?
    }

    /// Penyegaran mandiri saat aplikasi dibuka. Widget tidak bergantung pada
    /// pengguna pernah masuk ke tab Library pada sesi ini.
    static func refresh(session: SessionManager) async {
        guard session.isLoggedIn else { return }
        let context = session.snapshot
        let expectedGeneration = accountGeneration
        let api = APIClient(session: session)
        async let fetchedAlbums = try? AlbumRepository(api: api).all()
        async let fetchedMemories = try? MemoriesRepository(api: api).getMemories()
        async let fetchedFavorites = try? SearchRepository(api: api).metadataSearch(
            SearchRequestDTO(
                page: 1,
                isFavorite: true,
                size: Self.photosPerAlbum))
        let (allAlbums, allMemories, favoritesResponse) = await (
            fetchedAlbums, fetchedMemories, fetchedFavorites)

        guard expectedGeneration == accountGeneration,
              (try? session.checkCurrent(context)) != nil else { return }
        let albums = (allAlbums ?? LocalSnapshot.load(
            [AlbumResponseDTO].self,
            for: LocalSnapshot.Key.libraryAlbums) ?? [])
            .sorted { lhs, rhs in
                (lhs.updatedAt ?? lhs.createdAt) > (rhs.updatedAt ?? rhs.createdAt)
            }
        let memories = allMemories.map {
            MemoryStory.build(from: $0, limit: 15)
        } ?? []

        // Extension mencatat album yang dipilih tiap instance widget. Dengan
        // begitu startup berikutnya hanya perlu mengambil isi album yang benar-
        // benar dipakai, bukan ratusan thumbnail dari setiap album di server.
        let selectedIDs = Set(
            UserDefaults(suiteName: appGroup)?
                .stringArray(forKey: selectedAlbumsKey) ?? [])
        let albumRepo = AlbumRepository(api: api)
        var albumAssetIDs: [String: [String]] = [:]
        for id in selectedIDs where id != favoritesID {
            guard let detail = try? await albumRepo.detail(id) else { continue }
            albumAssetIDs[id] = Array(
                (detail.assets ?? [])
                    .sorted { $0.fileCreatedAt > $1.fileCreatedAt }
                    .prefix(Self.photosPerAlbum)
                    .map(\.id))
        }

        guard expectedGeneration == accountGeneration,
              (try? session.checkCurrent(context)) != nil else { return }
        let favoriteAssetIDs = favoritesResponse?.assets.items.map(\.id) ?? []
        let favoriteCount = favoritesResponse?.assets.total ?? favoriteAssetIDs.count

        await refresh(
            albums: albums,
            albumAssetIDs: albumAssetIDs,
            favoriteAssetIDs: favoriteAssetIDs,
            favoriteCount: favoriteCount,
            memories: memories,
            session: session)
    }

    static func refresh(
        albums: [AlbumResponseDTO],
        albumAssetIDs: [String: [String]],
        favoriteAssetIDs: [String],
        favoriteCount: Int,
        memories: [MemoryStory],
        session: SessionManager
    ) async {
        guard session.isLoggedIn else { return }
        let context = session.snapshot
        let expectedGeneration = accountGeneration
        guard let container = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: appGroup)
        else { return }

        let root = container.appendingPathComponent("Widgets", isDirectory: true)
        let generation = UUID().uuidString
        let images = root.appendingPathComponent(generation, isDirectory: true)
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

        let api = session.imageAPI
        var written = Set<String>()
        await withTaskGroup(of: (String, Data?).self) { group in
            for (name, assetID) in requested {
                group.addTask {
                    let endpoint = Endpoint(
                        path: "/assets/\(assetID)/thumbnail",
                        query: [.init(name: "size", value: "thumbnail")])
                    return (name, try? await api.rawData(endpoint))
                }
            }

            for await (name, data) in group {
                guard expectedGeneration == accountGeneration,
                      (try? session.checkCurrent(context)) != nil else {
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

        guard expectedGeneration == accountGeneration,
              (try? session.checkCurrent(context)) != nil else { return }

        // Saat offline jangan mengganti widget bergambar yang masih valid
        // dengan snapshot baru yang seluruh gambarnya kosong.
        if !requested.isEmpty, written.isEmpty {
            try? FileManager.default.removeItem(at: images)
            return
        }

        let favoriteImageNames = favoriteAssetIDs.indices.compactMap { index in
            let name = "favorites-\(index).image"
            return written.contains(name) ? "\(generation)/\(name)" : nil
        }
        let favorites = Album(
            id: favoritesID,
            name: "Favorites",
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
            return Memory(
                id: memory.id,
                title: memory.title,
                subtitle: memory.subtitle,
                imageName: written.contains(name) ? "\(generation)/\(name)" : nil)
        }

        let snapshot = Snapshot(
            generatedAt: Date(), albums: [favorites] + wireAlbums, memories: wireMemories)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(snapshot) else { return }

        let snapshotURL = root.appendingPathComponent("snapshot.json")
        do {
            try data.write(to: snapshotURL, options: .atomic)
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

    static func clear() {
        accountGeneration = UUID()
        guard let container = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: appGroup)
        else { return }
        try? FileManager.default.removeItem(
            at: container.appendingPathComponent("Widgets", isDirectory: true))
        WidgetCenter.shared.reloadAllTimelines()
    }
}
