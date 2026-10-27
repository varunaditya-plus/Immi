import Foundation

struct BackupNetworkPolicy {
    let isOnline: Bool
    let isExpensive: Bool
    let cellularPhotos: Bool
    let cellularVideos: Bool

    var allowsAutomaticDiscovery: Bool {
        isOnline && (!isExpensive || cellularPhotos || cellularVideos)
    }
}

/// Applies persisted request intent to queue selection and upload preparation.
@MainActor
final class BackupUploadRequests {
    private let queue: BackupQueueStore

    init(queue: BackupQueueStore) { self.queue = queue }

    func requestUploads(_ ids: [String], uploadedIDs: Set<String>) throws {
        let requested = ids.map(LocalPhotoLibrary.localIdentifier(from:))
            .filter { !uploadedIDs.contains($0) }
        try queue.enqueue(requested, intent: .manualUpload)
    }

    func retry(_ id: String) throws {
        try queue.retryFailed(id, userRequested: true)
    }

    func retryFailed() throws {
        try queue.retryFailed(userRequested: true)
    }

    func readyItems(automaticEnabled: Bool, now: Date = .now, limit: Int = 100) -> [BackupQueueItem] {
        queue.readyItems(now: now, limit: limit, userRequestedOnly: !automaticEnabled)
    }

    func retryWakeDelay(automaticEnabled: Bool, now: Date = .now) -> TimeInterval? {
        // Explicit actions and slot completions refill immediately. If due
        // work cannot progress, avoid repeatedly scheduling a zero-delay wake.
        queue.items
            .filter({ (automaticEnabled || $0.isUserRequested) && $0.state.isWaiting })
            .compactMap { item -> TimeInterval? in
                guard let date = item.nextAttemptAt else { return nil }
                let delay = date.timeIntervalSince(now)
                return delay > 0 ? delay : 30
            }.min()
    }

    func allowsCellular(for photo: LocalPhoto, policy: BackupNetworkPolicy) -> Bool {
        if queue.item(id: photo.id)?.allowsCellularOverride == true { return true }
        if photo.isLivePhoto { return policy.cellularPhotos && policy.cellularVideos }
        return photo.isVideo ? policy.cellularVideos : policy.cellularPhotos
    }

    func allowsNetwork(for photo: LocalPhoto, policy: BackupNetworkPolicy) -> Bool {
        policy.isOnline && (!policy.isExpensive || allowsCellular(for: photo, policy: policy))
    }

    /// Only matching requests receive an immediate wake; unrelated backoff and
    /// automatic items stay untouched when automatic backup is disabled.
    /// Returns active upload IDs whose submitted network policy can be upgraded.
    func releaseNetworkWaits(
        automaticEnabled: Bool,
        policy: BackupNetworkPolicy,
        canProcess: @MainActor () -> Bool = { true },
        metadata: @MainActor (String) async -> LocalPhoto?
    ) async throws -> Set<String> {
        guard policy.isOnline, canProcess() else { return [] }
        var releasable: Set<String> = []
        var cellularEligible: Set<String> = []
        for item in queue.items where automaticEnabled || item.isUserRequested {
            guard !Task.isCancelled, canProcess() else { return [] }
            guard item.state == .waitingForNetwork || item.state == .uploading else { continue }
            let photo = await metadata(item.id)
            guard !Task.isCancelled, canProcess() else { return [] }
            guard let photo, let current = queue.item(id: item.id),
                  automaticEnabled || current.isUserRequested,
                  current.state == .waitingForNetwork || current.state == .uploading else { continue }
            if allowsNetwork(for: photo, policy: policy) { releasable.insert(item.id) }
            if current.state == .uploading, policy.isExpensive,
               allowsCellular(for: photo, policy: policy) {
                cellularEligible.insert(item.id)
            }
        }
        guard !Task.isCancelled, canProcess() else { return [] }
        try queue.releaseNetworkWaits(releasable)
        return cellularEligible
    }

    func process(
        automaticEnabled: @MainActor () -> Bool,
        policy: @MainActor () -> BackupNetworkPolicy,
        canProcess: @MainActor () -> Bool,
        hasFullPhotoAccess: @MainActor () -> Bool,
        metadata: @MainActor (String) async -> LocalPhoto?,
        staging: @MainActor () async -> (activeTasks: Int, bytes: Int),
        unavailable: @MainActor (String) -> Void,
        prepare: @MainActor (LocalPhoto, Bool) async -> Void,
        didChange: @MainActor () -> Void
    ) async throws {
        let ready = readyItems(automaticEnabled: automaticEnabled())
        for item in ready {
            guard !Task.isCancelled, canProcess() else { return }
            let usage = await staging()
            guard !Task.isCancelled, canProcess(),
                  BackupStagingPolicy.canPrepare(
                    activeCount: max(queue.snapshot.active, usage.activeTasks), stagedBytes: usage.bytes)
            else { return }
            guard isReady(item.id, automaticEnabled: automaticEnabled()) else { continue }
            if shouldYieldToUserRequest(item.id) { return }
            let couldConfirmMissing = hasFullPhotoAccess()
            guard let photo = await metadata(item.id) else {
                guard !Task.isCancelled, canProcess() else { return }
                guard isReady(item.id, automaticEnabled: automaticEnabled()) else { continue }
                if shouldYieldToUserRequest(item.id) { return }
                guard couldConfirmMissing, hasFullPhotoAccess() else { continue }
                unavailable(item.id)
                didChange()
                continue
            }
            guard !Task.isCancelled, canProcess(),
                  isReady(item.id, automaticEnabled: automaticEnabled()) else { continue }
            if shouldYieldToUserRequest(item.id) { return }
            let currentPolicy = policy()
            guard allowsNetwork(for: photo, policy: currentPolicy) else {
                try queue.markRetry(photo.id, state: .waitingForNetwork,
                    error: currentPolicy.isOnline
                        ? String(localized: "Waiting for Wi-Fi.")
                        : String(localized: "Waiting for a network connection."),
                    retryAt: Date(timeIntervalSinceNow: 15 * 60))
                didChange()
                continue
            }
            let cellular = allowsCellular(for: photo, policy: currentPolicy)
            await prepare(photo, !currentPolicy.isExpensive || cellular)
            guard !Task.isCancelled, canProcess() else { return }
            didChange()
        }
    }

    /// Limited access cannot distinguish a deleted original from one outside
    /// the selected Photos scope. Failed items also may change during the scan.
    func pruneUnavailableFailures(
        canProcess: @MainActor () -> Bool,
        hasFullPhotoAccess: @MainActor () -> Bool,
        existingIdentifiers: @MainActor ([String]) async -> Set<String>,
        preservedIdentifiers: @MainActor () -> Set<String>
    ) async throws -> Bool {
        guard !Task.isCancelled, canProcess(), hasFullPhotoAccess() else { return false }
        let failed = queue.items.filter { $0.state == .failed }
        guard !failed.isEmpty else { return false }
        let existing = await existingIdentifiers(failed.map(\.id))
        guard !Task.isCancelled, canProcess(), hasFullPhotoAccess() else { return false }
        let preserved = preservedIdentifiers()
        let missing = Set(failed.filter {
            !existing.contains($0.id) && !preserved.contains($0.id)
                && queue.item(id: $0.id) == $0
        }.map(\.id))
        guard !missing.isEmpty else { return false }
        try queue.discard(missing)
        return true
    }

    func markFailedOrDiscard(
        _ id: String, error: String,
        hasFullPhotoAccess: @MainActor () -> Bool,
        sourceExists: @MainActor () -> Bool
    ) throws {
        if hasFullPhotoAccess(), !sourceExists(), hasFullPhotoAccess() {
            try queue.discard(id)
        } else {
            try queue.markFailed(id, error: error)
        }
    }

    /// The motion transfer succeeded even if Photos access disappeared before
    /// the still could be read. Persist that handoff before waiting for access.
    func retainCompletedMotion(_ id: String, motionAssetID: String) throws {
        guard let current = queue.item(id: id), current.state == .uploading,
              current.phase == .livePhotoMotion else { return }
        try queue.markPreparing(id, phase: .primaryAsset, motionAssetID: motionAssetID)
        try queue.markQueued(id)
    }

    private func isReady(_ id: String, automaticEnabled: Bool) -> Bool {
        guard let item = queue.item(id: id), automaticEnabled || item.isUserRequested else { return false }
        return item.isReady()
    }

    private func shouldYieldToUserRequest(_ id: String) -> Bool {
        guard queue.item(id: id)?.isUserRequested == false else { return false }
        return queue.items.contains { $0.isUserRequested && $0.isReady() }
    }
}
