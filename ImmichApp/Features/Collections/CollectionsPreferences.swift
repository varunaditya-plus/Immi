import CryptoKit
import Foundation

enum CollectionsSection: String, CaseIterable, Codable, Identifiable {
    case memories, pinned, albums, recentDays, people, featured, sharedAlbums, mediaTypes, utilities

    var id: String { rawValue }

    var title: String {
        switch self {
        case .pinned: String(localized: "Pinned")
        case .memories: String(localized: "Memories")
        case .albums: String(localized: "Albums")
        case .people: String(localized: "People & Pets")
        case .featured: String(localized: "Featured Photos")
        case .sharedAlbums: String(localized: "Shared Albums")
        case .recentDays: String(localized: "Recent Days")
        case .mediaTypes: String(localized: "Media Types")
        case .utilities: String(localized: "Utilities")
        }
    }
}

enum CollectionsLayout: String, CaseIterable, Codable, Identifiable {
    case mixed, small, large

    var id: String { rawValue }
    var title: String {
        switch self {
        case .mixed: String(localized: "Mixed Grid")
        case .small: String(localized: "Small Grid")
        case .large: String(localized: "Large Grid")
        }
    }

    func cardWidth(for section: CollectionsSection) -> CGFloat {
        switch self {
        case .small: 120
        case .large: 256
        case .mixed:
            switch section {
            case .memories, .recentDays, .featured: 256
            default: 120
            }
        }
    }
}

enum PinnedCollectionReference: Hashable, Identifiable {
    case favorites, map, videos, recentlyDeleted, albums, people, memories
    case album(String)

    static let suggestions: [Self] = [.favorites, .map, .videos, .recentlyDeleted, .albums, .people, .memories]
    static let defaults: [Self] = [.favorites, .map, .videos, .recentlyDeleted]

    var id: String {
        switch self {
        case .favorites: "favorites"
        case .map: "map"
        case .videos: "videos"
        case .recentlyDeleted: "recentlyDeleted"
        case .albums: "albums"
        case .people: "people"
        case .memories: "memories"
        case .album(let id): "album:\(id)"
        }
    }

    init?(id: String) {
        if let reference = Self.suggestions.first(where: { $0.id == id }) {
            self = reference
        } else if id.hasPrefix("album:"), id.count > 6 {
            self = .album(String(id.dropFirst(6)))
        } else {
            return nil
        }
    }
}

struct CollectionsPreferences: Codable, Equatable {
    var sectionOrder = CollectionsSection.allCases
    var collapsedSections: Set<CollectionsSection> = []
    var pinnedCollections = PinnedCollectionReference.defaults
    var layout = CollectionsLayout.mixed

    init() {}

    private enum CodingKeys: String, CodingKey {
        case sectionOrder, collapsedSections, pinnedCollections, layout
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let order = try values.decodeIfPresent([String].self, forKey: .sectionOrder) ?? []
        sectionOrder = Self.unique(order.compactMap(CollectionsSection.init(rawValue:)))
        sectionOrder += CollectionsSection.allCases.filter { !sectionOrder.contains($0) }
        collapsedSections = Set((try values.decodeIfPresent([String].self, forKey: .collapsedSections) ?? [])
            .compactMap(CollectionsSection.init(rawValue:)))
        if let pins = try values.decodeIfPresent([String].self, forKey: .pinnedCollections) {
            pinnedCollections = Self.unique(pins.compactMap(PinnedCollectionReference.init(id:)))
        }
        layout = CollectionsLayout(rawValue: try values.decodeIfPresent(String.self, forKey: .layout) ?? "") ?? .mixed
    }

    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(sectionOrder.map(\.rawValue), forKey: .sectionOrder)
        try values.encode(CollectionsSection.allCases.filter(collapsedSections.contains).map(\.rawValue), forKey: .collapsedSections)
        try values.encode(pinnedCollections.map(\.id), forKey: .pinnedCollections)
        try values.encode(layout.rawValue, forKey: .layout)
    }

    mutating func showAll() { collapsedSections = [] }
    mutating func collapseAll() { collapsedSections = Set(CollectionsSection.allCases) }

    mutating func removeMissingAlbums(_ validIDs: Set<String>) {
        pinnedCollections.removeAll {
            if case .album(let id) = $0 { return !validIDs.contains(id) }
            return false
        }
    }

    private static func unique<T: Hashable>(_ values: [T]) -> [T] {
        var seen = Set<T>()
        return values.filter { seen.insert($0).inserted }
    }
}

@MainActor
final class CollectionsPreferencesStore {
    let owner: BackupQueueOwner?
    private let defaults: UserDefaults
    private let generation: UUID
    private let key: String?

    init(owner: BackupQueueOwner?, defaults: UserDefaults = .standard) {
        self.owner = owner
        self.defaults = defaults
        generation = LocalSnapshot.generation
        if let owner {
            let identity = (try? JSONEncoder().encode([owner.server, owner.userID])) ?? Data()
            let digest = SHA256.hash(data: identity).map { String(format: "%02x", $0) }.joined()
            key = "collections.preferences.v1.\(digest)"
        } else {
            key = nil
        }
    }

    func load() -> CollectionsPreferences {
        guard generation == LocalSnapshot.generation, let key else { return CollectionsPreferences() }
        if let data = defaults.data(forKey: key) {
            return (try? JSONDecoder().decode(CollectionsPreferences.self, from: data)) ?? CollectionsPreferences()
        }
        var preferences = CollectionsPreferences()
        if let legacy = defaults.string(forKey: "library.expandedRows") {
            let expanded = Set(legacy.split(separator: ",").map(String.init))
            let oldSections: [(String, CollectionsSection)] = [
                ("albums", .albums), ("people", .people), ("favorites", .featured)
            ]
            preferences.collapsedSections = Set(oldSections.compactMap { expanded.contains($0.0) ? nil : $0.1 })
            save(preferences)
            // Consume the old global setting once, so another account cannot inherit it.
            defaults.removeObject(forKey: "library.expandedRows")
        }
        return preferences
    }

    func save(_ preferences: CollectionsPreferences) {
        guard generation == LocalSnapshot.generation, let key,
              let data = try? JSONEncoder().encode(preferences) else { return }
        defaults.set(data, forKey: key)
    }
}
