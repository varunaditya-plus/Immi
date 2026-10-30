import Foundation

@MainActor
enum PhotoMapNavigation {
    static func allowsNavigation(to asset: AssetResponseDTO, dataManager: SwiftDataManager? = nil) -> Bool {
        asset.isTimelineVisible && AssetVisibilityPolicy(scope: .timeline, dataManager: dataManager).allows(id: asset.id)
    }

    static func libraryIDs(for assets: [AssetLite], options: LibraryBrowseOptions) -> Set<String>? {
        guard !options.filters.isEmpty || !options.showsScreenshots else { return nil }
        return ids(for: assets)
    }

    static func ids(for assets: [AssetLite], dataManager: SwiftDataManager? = nil) -> Set<String> {
        let manager = dataManager ?? .shared
        let mappings = manager.serverAssetIDsByLocalIdentifier()
        return Set(AssetVisibilityPolicy(scope: .timeline, dataManager: manager).filter(assets).map {
            PhotoMapSources.canonicalID($0.id, mappings: mappings)
        })
    }
}
