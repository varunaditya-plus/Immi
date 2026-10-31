import Foundation

/// Display IDs identify grid tiles; only the current mapping identifies a server asset.
@MainActor
enum AssetServerIdentity {
    static func exportIDs(for ids: [String], using manager: SwiftDataManager? = nil) -> [String] {
        let mappings = ids.contains(where: LocalPhotoLibrary.isLocal)
            ? (manager ?? .shared).serverAssetIDsByLocalIdentifier() : [:]
        return ids.map { id in
            guard LocalPhotoLibrary.isLocal(id),
                  let serverID = mappings[LocalPhotoLibrary.localIdentifier(from: id)],
                  !serverID.isEmpty, !LocalPhotoLibrary.isLocal(serverID) else { return id }
            return serverID
        }
    }

    /// Supply a snapshot for synchronous scans; omit it when revalidating after an await.
    static func resolve(
        _ asset: AssetLite, using manager: SwiftDataManager? = nil,
        localMappings: [String: String]? = nil
    ) -> String? {
        let serverID: String?
        if LocalPhotoLibrary.isLocal(asset.id) {
            let localID = LocalPhotoLibrary.localIdentifier(from: asset.id)
            if let localMappings { serverID = localMappings[localID] }
            else { serverID = (manager ?? .shared).getBackupRecord(localIdentifier: localID)?.assetId }
        } else {
            serverID = asset.origin == .device ? nil : asset.id
        }
        guard let serverID, !serverID.isEmpty, !LocalPhotoLibrary.isLocal(serverID) else { return nil }
        return serverID
    }
}
