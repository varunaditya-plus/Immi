import Foundation

@MainActor
enum CollectionsAssetSources {
    static func merge(
        server: [AssetLite], selectedLocal: [LocalPhoto], mappings: [String: String],
        knownServerIDs: Set<String> = [], policy: AssetVisibilityPolicy
    ) -> [AssetLite] {
        var result = server
        let serverOffsets = Dictionary(uniqueKeysWithValues: server.enumerated().map { ($0.element.id, $0.offset) })
        var seenLocal = Set<String>()
        for photo in selectedLocal where seenLocal.insert(photo.id).inserted {
            if let serverID = mappings[photo.id], let offset = serverOffsets[serverID] {
                result[offset].origin = .both
                continue
            }
            if let serverID = mappings[photo.id], knownServerIDs.contains(serverID) { continue }
            result.append(AssetLite(
                id: LocalPhotoLibrary.assetID(for: photo.id), isVideo: photo.isVideo,
                ratio: photo.ratio, thumbhash: nil, createdAt: photo.createdAt,
                duration: photo.duration, origin: mappings[photo.id] == nil ? .device : .both))
        }
        return policy.filter(result)
    }
}

enum FeaturedPhotoSelection {
    // Favorited photos rank first; month/day diversity prevents one photo session
    // filling the entire row. This is app curation, not Apple's private ranking.
    static func select(from assets: [AssetLite], limit: Int = 15, calendar: Calendar = .current) -> [AssetLite] {
        guard limit > 0 else { return [] }
        var seen = Set<String>()
        let ranked = assets.filter { !$0.isVideo && seen.insert($0.id).inserted }.sorted {
            if $0.isFavorite != $1.isFavorite { return $0.isFavorite }
            if $0.createdAt != $1.createdAt { return $0.createdAt > $1.createdAt }
            return $0.id < $1.id
        }
        var selected: [AssetLite] = []
        var selectedIDs = Set<String>()
        var months = Set<Date>()
        var days = Set<Date>()
        for asset in ranked {
            guard let month = calendar.dateInterval(of: .month, for: asset.createdAt)?.start,
                  months.insert(month).inserted else { continue }
            selected.append(asset)
            selectedIDs.insert(asset.id)
            days.insert(calendar.startOfDay(for: asset.createdAt))
            if selected.count == limit { return selected }
        }
        for asset in ranked where !selectedIDs.contains(asset.id) {
            guard days.insert(calendar.startOfDay(for: asset.createdAt)).inserted else { continue }
            selected.append(asset)
            selectedIDs.insert(asset.id)
            if selected.count == limit { return selected }
        }
        for asset in ranked where !selectedIDs.contains(asset.id) {
            selected.append(asset)
            if selected.count == limit { break }
        }
        return selected
    }
}

@MainActor
final class RecentDayRepository {
    private let repository: SearchRepository
    private let dataManager: SwiftDataManager
    private let localPhotos: @MainActor () -> [LocalPhoto]

    init(repository: SearchRepository, dataManager: SwiftDataManager? = nil,
         localPhotos: @escaping @MainActor () -> [LocalPhoto] = { @MainActor in LocalPhotoLibrary.shared.photos }) {
        self.repository = repository
        self.dataManager = dataManager ?? .shared
        self.localPhotos = localPhotos
    }

    func assets(in interval: DateInterval) async throws -> [AssetLite] {
        let generation = LocalSnapshot.generation
        let result = try await repository.allMetadata(SearchRequestDTO(
            takenAfter: interval.start.ISO8601Format(), takenBefore: interval.end.ISO8601Format(), size: 200))
        try Task.checkCancellation()
        guard generation == LocalSnapshot.generation else { throw CancellationError() }
        let remote = CollectionCaptureDateScope.filter(result.filter(\.isTimelineVisible), interval: interval).map(AssetLite.init)
        let merged = CollectionsAssetSources.merge(
            server: remote, selectedLocal: localPhotos(), mappings: dataManager.serverAssetIDsByLocalIdentifier(),
            knownServerIDs: Set(dataManager.timelineAssets().map(\.asset.id)),
            policy: AssetVisibilityPolicy(scope: .timeline, dataManager: dataManager))
        return merged.filter { $0.createdAt >= interval.start && $0.createdAt < interval.end }
            .sorted { $0.createdAt == $1.createdAt ? $0.id < $1.id : $0.createdAt > $1.createdAt }
    }
}


enum CollectionCaptureDateScope {
    static func filter(_ assets: [AssetResponseDTO], interval: DateInterval) -> [AssetResponseDTO] {
        assets.filter { $0.fileCreatedAt >= interval.start && $0.fileCreatedAt < interval.end }
    }
}

struct RecentDayCollection: Identifiable, Sendable {
    let start: Date
    let end: Date
    let assets: [AssetLite]
    var id: Date { start }
    var cover: AssetLite? { assets.first }

    @MainActor
    func filteringAssets(using policy: AssetVisibilityPolicy) -> Self? {
        let visible = policy.filter(assets)
        return visible.isEmpty ? nil : Self(start: start, end: end, assets: visible)
    }

    static func build(from assets: [AssetLite], calendar: Calendar = .current, limit: Int = 15) -> [Self] {
        let days = Dictionary(grouping: assets, by: { calendar.startOfDay(for: $0.createdAt) })
        return days.keys.sorted(by: >).prefix(limit).compactMap { day in
                guard let end = calendar.date(byAdding: .day, value: 1, to: day) else { return nil }
                let members = (days[day] ?? [])
                    .sorted { $0.createdAt > $1.createdAt }
                return Self(start: day, end: end, assets: members)
            }
    }
}
