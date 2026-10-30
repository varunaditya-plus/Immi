import Foundation
import Photos

/// Filter choices intersect, so Photos + Favorites means favorite still images.
enum LibraryFilter: String, CaseIterable, Identifiable, Sendable {
    case favorites, edited, photos, videos, screenshots, notInAlbum

    var id: Self { self }
    var title: String {
        switch self {
        case .favorites: String(localized: "Favorites")
        case .edited: String(localized: "Edited")
        case .photos: String(localized: "Photos")
        case .videos: String(localized: "Videos")
        case .screenshots: String(localized: "Screenshots")
        case .notInAlbum: String(localized: "Not in an Album")
        }
    }
    var symbol: String {
        switch self {
        case .favorites: "heart"
        case .edited: "slider.horizontal.3"
        case .photos: "photo"
        case .videos: "video"
        case .screenshots: "viewfinder"
        case .notInAlbum: "rectangle.stack.badge.minus"
        }
    }
}

enum LibrarySort: String, CaseIterable, Sendable {
    case dateCaptured, recentlyAdded
    var title: String {
        switch self {
        case .dateCaptured: String(localized: "Date Captured")
        case .recentlyAdded: String(localized: "Recently Added")
        }
    }
}

struct LibraryBrowseOptions: Equatable, Sendable {
    var sort: LibrarySort = .dateCaptured
    var filters: Set<LibraryFilter> = []
    var showsScreenshots = true

    var needsServerMetadata: Bool {
        sort == .recentlyAdded || !filters.isDisjoint(with: [.edited, .notInAlbum])
    }

    mutating func toggle(_ filter: LibraryFilter) {
        if filters.contains(filter) {
            filters.remove(filter)
        } else {
            if filter == .photos { filters.remove(.videos) }
            if filter == .videos { filters.remove(.photos) }
            filters.insert(filter)
        }
    }
}

struct LibraryAssetMetadata: Sendable {
    var addedAt: Date?
    var isEdited: Bool?
    var isScreenshot: Bool?
    var isFavorite: Bool?
    var isNotInAlbum: Bool?
}

struct LibraryMetadataIndex: Sendable {
    var assets: [AssetLite]
    var metadata: [String: LibraryAssetMetadata]
}

@MainActor
protocol LibraryMetadataProviding {
    func load(includingAlbumMembership: Bool) async throws -> LibraryMetadataIndex
}

@MainActor
final class LibraryMetadataRepository: LibraryMetadataProviding {
    private let repository: SearchRepository
    private let api: APIClient

    init(api: APIClient, dataManager: SwiftDataManager? = nil) {
        self.api = api
        self.repository = SearchRepository(api: api, dataManager: dataManager)
    }

    func load(includingAlbumMembership: Bool) async throws -> LibraryMetadataIndex {
        let context = api.session.snapshot
        let generation = LocalSnapshot.generation
        var request = SearchRequestDTO(order: "asc", size: 1_000)
        let assets = try await repository.allMetadata(request).filter(\.isTimelineVisible)
        var notInAlbum: Set<String>?
        if includingAlbumMembership {
            request.isNotInAlbum = true
            notInAlbum = Set(try await repository.allMetadata(request).filter(\.isTimelineVisible).map(\.id))
        }
        try Task.checkCancellation()
        try api.checkCurrent(context)
        guard generation == LocalSnapshot.generation else { throw CancellationError() }
        return LibraryMetadataIndex(
            assets: assets.map(AssetLite.init),
            metadata: Dictionary(uniqueKeysWithValues: assets.map { asset in
                (asset.id, LibraryAssetMetadata(addedAt: asset.addedAt, isEdited: asset.isEdited,
                    isFavorite: asset.isFavorite, isNotInAlbum: notInAlbum.map { $0.contains(asset.id) }))
            }))
    }
}

enum LibraryPresentation {
    static func assets(_ assets: [AssetLite], options: LibraryBrowseOptions,
                       metadata: [String: LibraryAssetMetadata]) -> [AssetLite] {
        assets.filter { asset in
            let values = metadata[asset.id]
            if !options.showsScreenshots, values?.isScreenshot == true { return false }
            for filter in options.filters {
                let included: Bool
                switch filter {
                case .photos: included = !asset.isVideo
                case .videos: included = asset.isVideo
                case .favorites: included = values?.isFavorite ?? asset.isFavorite
                case .edited: included = values?.isEdited == true
                case .screenshots: included = values?.isScreenshot == true
                case .notInAlbum: included = values?.isNotInAlbum == true
                }
                if !included { return false }
            }
            return true
        }.map { asset in
            guard let isFavorite = metadata[asset.id]?.isFavorite else { return asset }
            var asset = asset
            asset.isFavorite = isFavorite
            return asset
        }.sorted { lhs, rhs in
            if options.sort == .recentlyAdded {
                let left = metadata[lhs.id]?.addedAt, right = metadata[rhs.id]?.addedAt
                if left != right {
                    if let left, let right { return left < right }
                    return left == nil
                }
            }
            if lhs.createdAt != rhs.createdAt { return lhs.createdAt < rhs.createdAt }
            return lhs.id < rhs.id
        }
    }

    static func sections(_ assets: [AssetLite], sort: LibrarySort) -> [TimelineSection] {
        if sort == .recentlyAdded {
            return assets.isEmpty ? [] : [TimelineSection(id: "library.added", title: String(localized: "Recently Added"),
                assets: assets, count: assets.count)]
        }
        var sections: [TimelineSection] = []
        for asset in assets {
            let month = MonthKey.of(asset.createdAt)
            if sections.last?.id != month {
                sections.append(TimelineSection(id: month, title: TimelineViewModel.formatBucketTitle(month),
                    assets: [], startIndex: sections.reduce(0) { $0 + $1.count }))
            }
            sections[sections.count - 1].assets.append(asset)
            sections[sections.count - 1].count += 1
        }
        return sections
    }

    @MainActor
    static func deviceMetadata(for assets: [AssetLite]) -> [String: LibraryAssetMetadata] {
        let identifiers = assets.filter { LocalPhotoLibrary.isLocal($0.id) }.map { LocalPhotoLibrary.localIdentifier(from: $0.id) }
        guard !identifiers.isEmpty else { return [:] }
        var values: [String: LibraryAssetMetadata] = [:]
        PHAsset.fetchAssets(withLocalIdentifiers: identifiers, options: nil).enumerateObjects { asset, _, _ in
            let albumCount = PHAssetCollection.fetchAssetCollectionsContaining(asset, with: .album, options: nil).count
            values[LocalPhotoLibrary.assetID(for: asset.localIdentifier)] = LibraryAssetMetadata(
                isEdited: asset.hasAdjustments, isScreenshot: asset.mediaSubtypes.contains(.photoScreenshot),
                isFavorite: asset.isFavorite, isNotInAlbum: albumCount == 0)
        }
        return values
    }
}
