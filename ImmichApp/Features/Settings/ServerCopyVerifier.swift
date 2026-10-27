import Foundation

/// A backup mapping only identifies a possible server copy. Deletion requires
/// its current metadata and the actual original bytes to match the local file.
@MainActor
class ServerCopyVerifier {
    struct Proof: Equatable, Sendable {
        fileprivate let primary: Asset
        fileprivate let motion: Asset?
    }

    fileprivate struct Asset: Decodable, Equatable, Sendable {
        let id: String
        let type: String
        let isTrashed: Bool
        let isOffline: Bool
        let checksum: String
        let livePhotoVideoId: String?

        var sha1: String? {
            guard let bytes = Data(base64Encoded: checksum), bytes.count == 20 else { return nil }
            return bytes.map { String(format: "%02x", $0) }.joined()
        }

        func matches(id: String, sha1: String) -> Bool {
            self.id == id && !isTrashed && !isOffline && self.sha1 == sha1
        }
    }

    private let api: APIClient
    private let backup: BackupRepository
    private let headers = ["Cache-Control": "no-cache", "Pragma": "no-cache"]

    init(api: APIClient) {
        self.api = api
        backup = BackupRepository(api: api)
    }

    func verify(
        assetID: String,
        primaryChecksum: String,
        motionChecksum: String? = nil,
        primaryIsVideo: Bool = false
    ) async throws -> Proof? {
        try Task.checkCancellation()
        let motionSHA1 = motionChecksum.flatMap { normalizedSHA1($0) }
        guard let primarySHA1 = normalizedSHA1(primaryChecksum),
              motionChecksum == nil || motionSHA1 != nil else { return nil }

        let primary = try await metadata(assetID)
        guard primary.matches(id: assetID, sha1: primarySHA1),
              primary.type == (primaryIsVideo ? "VIDEO" : "IMAGE") else { return nil }

        var motion: Asset?
        if let motionSHA1 {
            guard primary.type == "IMAGE", let motionID = primary.livePhotoVideoId,
                  motionID != assetID else { return nil }
            let linked = try await metadata(motionID)
            guard linked.type == "VIDEO", linked.matches(id: motionID, sha1: motionSHA1) else { return nil }
            motion = linked
        }

        guard try await originalMatches(assetID, sha1: primarySHA1) else { return nil }
        if let motion, let motionSHA1 {
            guard try await originalMatches(motion.id, sha1: motionSHA1) else { return nil }
        }

        // The server copy can be trashed or replaced during a long video
        // download. Recheck both records before returning proof to the caller.
        let proof = Proof(primary: primary, motion: motion)
        guard try await isCurrent(proof) else { return nil }
        return proof
    }

    /// Lightweight final check after the rest of a deletion batch has finished
    /// downloading. The proof can only be created by a verified original read.
    func isCurrent(_ proof: Proof) async throws -> Bool {
        try Task.checkCancellation()
        guard try await metadata(proof.primary.id) == proof.primary else { return false }
        if let motion = proof.motion, try await metadata(motion.id) != motion { return false }
        try Task.checkCancellation()
        return true
    }

    private func metadata(_ id: String) async throws -> Asset {
        let asset: Asset = try await api.send(.init(path: "/assets/\(id)", extraHeaders: headers))
        try Task.checkCancellation()
        return asset
    }

    private func originalMatches(_ id: String, sha1: String) async throws -> Bool {
        let file = try await api.rawFile(.init(
            path: "/assets/\(id)/original",
            query: [.init(name: "edited", value: "false")],
            extraHeaders: headers))
        defer { try? FileManager.default.removeItem(at: file) }
        try Task.checkCancellation()
        guard let size = try file.resourceValues(forKeys: [.fileSizeKey]).fileSize, size > 0 else { return false }
        let actual = try await backup.checksum(forFile: file)
        try Task.checkCancellation()
        return actual == sha1
    }

    private func normalizedSHA1(_ value: String) -> String? {
        guard value.count == 40, value.utf8.allSatisfy({
            (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0)
        }) else { return nil }
        return value.lowercased()
    }
}
