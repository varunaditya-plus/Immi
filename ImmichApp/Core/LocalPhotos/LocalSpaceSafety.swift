import Foundation
import Photos

struct LocalSpaceRules: Equatable, Sendable {
    var cutoff: Date? = nil
    var keepFavorites = false
    var keepAlbumIDs: Set<String> = []
    var keepPhotos = false
    var keepVideos = false
}

enum LocalSpaceResource: String, Sendable {
    case primary
    case motion
}

struct LocalSpaceResourceDescriptor: Equatable, Sendable {
    let type: Int
    let filename: String
    let contentType: String
}

struct LocalAssetVersion: Equatable, Sendable {
    let createdAt: Date
    let modifiedAt: Date
    let isFavorite: Bool
    let isVideo: Bool
    let isLivePhoto: Bool
    let pixelWidth: Int
    let pixelHeight: Int
    let duration: Double
    let resources: [LocalSpaceResourceDescriptor]
}

/// Fresh PhotoKit bytes, paired with the version which produced them. Stored
/// backup checksums are deliberately not accepted as evidence for deletion.
struct LocalSpaceCandidate: Identifiable, Equatable, Sendable {
    let id: String
    let version: LocalAssetVersion
    let resourceChecksums: [LocalSpaceResource: String]

    var createdAt: Date { version.createdAt }
    var isVideo: Bool { version.isVideo }
}

struct LocalSpaceAssetState: Equatable, Sendable {
    let id: String
    let version: LocalAssetVersion
    let isInKeptAlbum: Bool
}

enum LocalSpaceSafety {
    /// Only complete, unedited originals have a server representation which
    /// this cleanup path can prove. Extra resources may contain edits or RAW.
    static func resourceRoles(for version: LocalAssetVersion) -> [LocalSpaceResource: Int]? {
        let types = version.resources.map(\.type)
        if version.isVideo {
            guard !version.isLivePhoto, types == [PHAssetResourceType.video.rawValue] else { return nil }
            return [.primary: PHAssetResourceType.video.rawValue]
        }
        if version.isLivePhoto {
            guard types.sorted() == [PHAssetResourceType.photo.rawValue, PHAssetResourceType.pairedVideo.rawValue].sorted()
            else { return nil }
            return [.primary: PHAssetResourceType.photo.rawValue, .motion: PHAssetResourceType.pairedVideo.rawValue]
        }
        guard types == [PHAssetResourceType.photo.rawValue] else { return nil }
        return [.primary: PHAssetResourceType.photo.rawValue]
    }

    static func isEligible(_ state: LocalSpaceAssetState, rules: LocalSpaceRules) -> Bool {
        let version = state.version
        guard resourceRoles(for: version) != nil else { return false }
        if let cutoff = rules.cutoff, version.createdAt >= cutoff { return false }
        if rules.keepFavorites && version.isFavorite { return false }
        if state.isInKeptAlbum { return false }
        if rules.keepPhotos && !version.isVideo { return false }
        if rules.keepVideos && version.isVideo { return false }
        return true
    }

    static func canDelete(
        _ candidates: [LocalSpaceCandidate], current: [LocalSpaceAssetState], rules: LocalSpaceRules
    ) -> Bool {
        let ids = Set(candidates.map(\.id))
        guard !ids.isEmpty, ids.count == candidates.count,
              current.count == ids.count, Set(current.map(\.id)) == ids else { return false }
        let currentByID = Dictionary(uniqueKeysWithValues: current.map { ($0.id, $0) })
        return candidates.allSatisfy { candidate in
            guard let state = currentByID[candidate.id], state.version == candidate.version,
                  isEligible(state, rules: rules),
                  let roles = resourceRoles(for: candidate.version),
                  Set(candidate.resourceChecksums.keys) == Set(roles.keys) else { return false }
            return candidate.resourceChecksums.values.allSatisfy { checksum in
                checksum.count == 40 && checksum.allSatisfy { $0.isHexDigit }
            }
        }
    }
}

@MainActor
protocol LocalSpaceLibrary {
    func candidates(from localIDs: Set<String>, rules: LocalSpaceRules) async throws -> [LocalSpaceCandidate]
    func deleteVerified(_ candidates: [LocalSpaceCandidate], rules: LocalSpaceRules) async throws -> Set<String>
}

enum LocalSpaceLibraryError: LocalizedError {
    case accessRequired
    case libraryChanged

    var errorDescription: String? {
        switch self {
        case .accessRequired:
            "Allow Photos access to verify the copies on this device."
        case .libraryChanged:
            "Your photo library changed. Scan again before removing device copies."
        }
    }
}
