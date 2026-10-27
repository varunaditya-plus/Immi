import Foundation

struct FreeUpSpaceReview: Equatable, Sendable {
    let rules: LocalSpaceRules
    let candidates: [LocalSpaceCandidate]
}

enum DeviceCopySafetyError: LocalizedError {
    case signInRequired
    case copiesChanged
    case invalidDeletionResult

    var errorDescription: String? {
        switch self {
        case .signInRequired:
            "Sign in to verify the copies on your server before removing device copies."
        case .copiesChanged:
            "A device or server copy changed or could not be verified. Refresh the photos and try again."
        case .invalidDeletionResult:
            "Photos could not confirm which device copies were removed."
        }
    }
}

/// Coordinates fresh local bytes, current server originals, and the final
/// guarded PhotoKit transaction. Historical mappings only identify candidates.
@MainActor
final class FreeUpSpaceService {
    private struct Account: Equatable {
        let baseURL: URL?
        let headers: [String: String]
        let owner: BackupQueueOwner?
        let isLoggedIn: Bool

        @MainActor
        init(_ session: SessionManager) {
            baseURL = session.baseURL
            headers = session.authHeaders
            owner = session.backupQueueOwner
            isLoggedIn = session.isLoggedIn
        }

        var canVerify: Bool {
            isLoggedIn && baseURL != nil && owner != nil && !headers.isEmpty
        }
    }

    private let session: SessionManager
    private let account: Account
    private let manager: SwiftDataManager
    private let library: any LocalSpaceLibrary
    private let verifier: ServerCopyVerifier
    private let refreshCounts: @MainActor () -> Void

    init(
        session: SessionManager,
        dataManager: SwiftDataManager? = nil,
        library: (any LocalSpaceLibrary)? = nil,
        verifier: ServerCopyVerifier? = nil,
        refreshCounts: (@MainActor () -> Void)? = nil
    ) {
        self.session = session
        account = Account(session)
        manager = dataManager ?? .shared
        self.library = library ?? LocalPhotoLibrary.shared
        self.verifier = verifier ?? ServerCopyVerifier(api: APIClient(session: session))
        self.refreshCounts = refreshCounts ?? { BackupService.shared.refreshCounts() }
    }

    func scan(_ rules: LocalSpaceRules) async throws -> FreeUpSpaceReview {
        try await review(localIDs: nil, rules: rules)
    }

    /// The same verification protects the single-item and bulk device-copy
    /// actions, which do not apply the Free Up Space cutoff or keep rules.
    func review(localIDs: Set<String>, rules: LocalSpaceRules = .init()) async throws -> FreeUpSpaceReview {
        try await review(localIDs: Optional(localIDs), rules: rules)
    }

    private func review(localIDs: Set<String>?, rules: LocalSpaceRules) async throws -> FreeUpSpaceReview {
        try checkAccount()
        let mappings = manager.serverAssetIDsByLocalIdentifier()
        let requested = localIDs ?? Set(mappings.keys)
        let mappedIDs = requested.filter { mappings[$0]?.isEmpty == false }
        let candidates = try await library.candidates(from: Set(mappedIDs), rules: rules)
        try checkAccount()

        var verified: [LocalSpaceCandidate] = []
        var seen = Set<String>()
        for candidate in candidates where mappedIDs.contains(candidate.id) && seen.insert(candidate.id).inserted {
            guard let serverID = mappings[candidate.id] else { continue }
            if try await verify(candidate, serverID: serverID) != nil {
                verified.append(candidate)
            }
            try checkAccount()
        }
        // Mapping changes during a scan require a new review, even when both
        // mappings happen to refer to readable server assets.
        let currentMappings = manager.serverAssetIDsByLocalIdentifier()
        guard verified.allSatisfy({ currentMappings[$0.id] == mappings[$0.id] }) else {
            throw DeviceCopySafetyError.copiesChanged
        }
        return FreeUpSpaceReview(rules: rules, candidates: verified)
    }

    func remove(_ review: FreeUpSpaceReview) async throws -> Int {
        try checkAccount()
        guard !review.candidates.isEmpty else { return 0 }
        let expected = Dictionary(review.candidates.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        guard expected.count == review.candidates.count else { throw DeviceCopySafetyError.copiesChanged }
        let mappings = manager.serverAssetIDsByLocalIdentifier()
        guard expected.keys.allSatisfy({ mappings[$0]?.isEmpty == false }) else {
            throw DeviceCopySafetyError.copiesChanged
        }

        // Review can remain open for minutes. Rehash the current PhotoKit
        // resources and re-download the server originals before deleting.
        let fresh = try await library.candidates(from: Set(expected.keys), rules: review.rules)
        try checkAccount()
        guard fresh.count == expected.count,
              Set(fresh.map(\.id)) == Set(expected.keys),
              fresh.allSatisfy({ expected[$0.id] == $0 }) else {
            throw DeviceCopySafetyError.copiesChanged
        }
        var proofs: [ServerCopyVerifier.Proof] = []
        for candidate in fresh {
            guard let serverID = mappings[candidate.id],
                  let proof = try await verify(candidate, serverID: serverID) else {
                throw DeviceCopySafetyError.copiesChanged
            }
            proofs.append(proof)
            try checkAccount()
        }
        // Earlier originals may have been verified before a long video
        // download. Recheck the complete batch immediately before Photos.
        for proof in proofs {
            guard try await verifier.isCurrent(proof) else { throw DeviceCopySafetyError.copiesChanged }
            try checkAccount()
        }
        let currentMappings = manager.serverAssetIDsByLocalIdentifier()
        guard expected.keys.allSatisfy({ mappings[$0] == currentMappings[$0] }) else {
            throw DeviceCopySafetyError.copiesChanged
        }
        try checkAccount()
        let deleted = try await library.deleteVerified(fresh, rules: review.rules)
        // Cancellation after Photos commits cannot undo deletion. Update the
        // same account's mappings even if its view has since been dismissed.
        guard session.baseURL == account.baseURL, session.backupQueueOwner == account.owner else {
            throw CancellationError()
        }
        guard deleted.isSubset(of: Set(expected.keys)) else { throw DeviceCopySafetyError.invalidDeletionResult }
        for id in deleted { try? manager.unlinkDeviceAsset(localIdentifier: id) }
        if !deleted.isEmpty { refreshCounts() }
        return deleted.count
    }

    private func verify(_ candidate: LocalSpaceCandidate, serverID: String) async throws -> ServerCopyVerifier.Proof? {
        guard let primary = candidate.resourceChecksums[.primary],
              candidate.version.isLivePhoto == (candidate.resourceChecksums[.motion] != nil) else { return nil }
        do {
            return try await verifier.verify(
                assetID: serverID, primaryChecksum: primary,
                motionChecksum: candidate.resourceChecksums[.motion], primaryIsVideo: candidate.isVideo)
        } catch APIError.server(let status, _) where [400, 403, 404].contains(status) {
            return nil
        }
    }

    private func checkAccount() throws {
        try Task.checkCancellation()
        guard account.canVerify else { throw DeviceCopySafetyError.signInRequired }
        guard account == Account(session) else { throw CancellationError() }
    }
}
