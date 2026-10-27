import Foundation
import Observation

enum BackupQueueItemState: String, Codable, Sendable {
    case queued
    case preparing
    case uploading
    case cancelling
    case waitingForNetwork
    case waitingForICloud
    case waitingForAuthentication
    case retryScheduled
    case failed

    var isWaiting: Bool {
        switch self {
        case .waitingForNetwork, .waitingForICloud, .waitingForAuthentication,
             .retryScheduled:
            true
        default:
            false
        }
    }

    var isActive: Bool {
        self == .preparing || self == .uploading || self == .cancelling
    }
}

struct BackupQueueItem: Codable, Equatable, Identifiable, Sendable {
    let id: String
    var phase: BackupUploadPhase
    var state: BackupQueueItemState
    var attemptCount: Int
    var nextAttemptAt: Date?
    var lastError: String?
    var checksum: String?
    var taskIdentifier: Int?
    var motionAssetID: String?
    let createdAt: Date
    var updatedAt: Date
}

struct BackupQueueOwner: Codable, Equatable, Sendable {
    let server: String
    let userID: String
}

struct BackupUploadOwnership: Codable, Equatable, Sendable {
    let owner: BackupQueueOwner
    let generation: UUID
}

struct BackupActiveTask: Equatable, Sendable {
    let taskIdentifier: Int
    let context: BackupUploadTaskContext
    let isSuspended: Bool
}

struct BackupQueueSnapshot: Equatable, Sendable {
    let total: Int
    let completed: Int
    let queued: Int
    let active: Int
    let waitingForNetwork: Int
    let waitingForICloud: Int
    let waitingForAuthentication: Int
    let retryScheduled: Int
    let failed: Int
    /// True only until the terminal notification for this batch is consumed.
    /// Persisting it prevents a completed queue from looking new after launch.
    let completionNotificationPending: Bool
    let nextAttemptAt: Date?
    let lastError: String?

    var waiting: Int {
        waitingForNetwork + waitingForICloud + waitingForAuthentication + retryScheduled
    }

    var unfinished: Int { queued + active + waiting }
    var hasWork: Bool { unfinished > 0 }
    var isUploading: Bool { active > 0 }

    var presentation: BackupQueuePresentation? {
        guard total > 0 else { return nil }
        if unfinished == 0 {
            return BackupQueuePresentation(
                key: "complete:\(completed):\(failed)",
                title: failed == 0
                    ? String(localized: "Backup Complete")
                    : String(localized: "Backup Finished with Errors"),
                body: failed == 0
                    ? (completed == 1
                        ? String(localized: "1 item backed up")
                        : String(localized: "\(completed) items backed up"))
                    : (failed == 1
                        ? String(localized: "\(completed) uploaded, 1 failed")
                        : String(localized: "\(completed) uploaded, \(failed) failed")))
        }
        if waitingForAuthentication > 0 {
            return BackupQueuePresentation(
                key: "auth:\(waitingForAuthentication)",
                title: String(localized: "Backup Needs Sign In"),
                body: String(localized: "Sign in to Immich to resume \(waitingForAuthentication) queued items."))
        }
        if active > 0 {
            return BackupQueuePresentation(
                key: "active:\(completed):\(total)",
                title: String(localized: "Backing Up"),
                body: String(localized: "\(completed) of \(total) uploaded"))
        }
        if waitingForNetwork > 0 {
            return BackupQueuePresentation(
                key: "network:\(waitingForNetwork)",
                title: String(localized: "Backup Waiting for Network"),
                body: String(localized: "\(waitingForNetwork) items will resume when the network is available."))
        }
        if waitingForICloud > 0 {
            return BackupQueuePresentation(
                key: "icloud:\(waitingForICloud)",
                title: String(localized: "Backup Waiting for iCloud"),
                body: String(localized: "\(waitingForICloud) originals are not available on this device yet."))
        }
        if retryScheduled > 0 {
            return BackupQueuePresentation(
                key: "retry:\(retryScheduled)",
                title: String(localized: "Backup Will Retry"),
                body: String(localized: "\(retryScheduled) items are queued for another attempt."))
        }
        return BackupQueuePresentation(
            key: "queued:\(unfinished)",
            title: String(localized: "Backup Queued"),
            body: String(localized: "\(unfinished) items are waiting to upload."))
    }
}

struct BackupQueuePresentation: Equatable, Sendable {
    let key: String
    let title: String
    let body: String
}

enum BackupQueueStoreError: LocalizedError {
    case unavailable(String)
    case invalidTransition

    var errorDescription: String? {
        switch self {
        case .unavailable(let reason):
            String(localized: "The background backup queue could not be saved: \(reason)")
        case .invalidTransition:
            String(localized: "The upload changed state before this action could finish.")
        }
    }
}

/// Sumber kebenaran untuk lifecycle upload lintas proses.
///
/// URLSession latar menyimpan transfer yang sudah diserahkan, tetapi tidak tahu
/// aset mana yang masih menunggu file iCloud, sedang backoff, atau gagal sebelum
/// task sempat dibuat. Queue kecil ini ditulis atomik sebelum setiap transisi,
/// sehingga reboot maupun terminasi proses tidak dapat mengubah state RAM
/// menjadi pekerjaan yang menggantung tanpa pemilik.
@MainActor
@Observable
final class BackupQueueStore {
    static let shared = BackupQueueStore()

    private struct Ledger: Codable {
        var version = 1
        var owner: BackupQueueOwner?
        var generation: UUID?
        var completed = 0
        var items: [BackupQueueItem] = []
        // Optional keeps queues written by older app versions decodable. An
        // absent value is treated as already consumed so an old completion is
        // not replayed immediately after upgrading.
        var completionNotificationPending: Bool?
    }

    private(set) var snapshot: BackupQueueSnapshot
    private(set) var persistenceWarning: String?

    private var ledger: Ledger
    private let fileURL: URL
    private let fileManager: FileManager

    init(fileURL: URL? = nil, fileManager: FileManager = .default) {
        self.fileManager = fileManager
        let defaultURL = URL.applicationSupportDirectory
            .appendingPathComponent("Immich", isDirectory: true)
            .appendingPathComponent("BackgroundBackupQueue-v1.json")
        let resolvedURL = fileURL ?? defaultURL
        self.fileURL = resolvedURL
        let loadedLedger: Ledger
        let loadedWarning: String?

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let data = try? Data(contentsOf: resolvedURL),
           let decoded = try? decoder.decode(Ledger.self, from: data),
           decoded.version == 1 {
            loadedLedger = decoded
            loadedWarning = nil
        } else {
            loadedLedger = Ledger()
            loadedWarning = fileManager.fileExists(atPath: resolvedURL.path)
                ? String(localized: "The previous background queue was unreadable and will be rebuilt.")
                : nil
            if fileManager.fileExists(atPath: resolvedURL.path) {
                let quarantine = resolvedURL.deletingLastPathComponent()
                    .appendingPathComponent(
                        "BackgroundBackupQueue-corrupt-\(UUID().uuidString).json")
                try? fileManager.moveItem(at: resolvedURL, to: quarantine)
            }
        }
        ledger = loadedLedger
        persistenceWarning = loadedWarning
        snapshot = Self.makeSnapshot(from: loadedLedger)
    }

    var owner: BackupQueueOwner? { ledger.owner }
    var ownership: BackupUploadOwnership? {
        guard let owner = ledger.owner, let generation = ledger.generation else { return nil }
        return BackupUploadOwnership(owner: owner, generation: generation)
    }
    var items: [BackupQueueItem] { ledger.items }
    var failedIDs: [String] {
        ledger.items.filter { $0.state == .failed }.map(\.id)
    }

    /// Mengikat queue ke akun. Queue akun lain tidak pernah diteruskan dengan
    /// header sesi baru.
    @discardableResult
    func bind(to owner: BackupQueueOwner) throws -> Bool {
        guard ledger.owner != owner || ledger.generation == nil else { return false }
        if ledger.owner == owner || (ledger.owner == nil && ledger.items.isEmpty && ledger.completed == 0) {
            ledger.owner = owner
            ledger.generation = UUID()
            try persist()
            return false
        }
        let replacedExistingOwner = ledger.owner != nil || !ledger.items.isEmpty
        ledger = Ledger(owner: owner, generation: UUID())
        try persist()
        return replacedExistingOwner
    }

    func enqueue(_ localIdentifiers: [String], now: Date = .now) throws {
        guard !localIdentifiers.isEmpty else { return }
        if ledger.items.isEmpty, ledger.completed > 0 {
            ledger.completed = 0
        }
        var known = Set(ledger.items.map(\.id))
        var insertedNewItem = false
        for id in localIdentifiers where known.insert(id).inserted {
            insertedNewItem = true
            ledger.items.append(BackupQueueItem(
                id: id,
                phase: .primaryAsset,
                state: .queued,
                attemptCount: 0,
                nextAttemptAt: nil,
                lastError: nil,
                checksum: nil,
                taskIdentifier: nil,
                motionAssetID: nil,
                createdAt: now,
                updatedAt: now))
        }
        if insertedNewItem {
            ledger.completionNotificationPending = true
        }
        try persist()
    }

    func readyItems(now: Date = .now, limit: Int = 100) -> [BackupQueueItem] {
        ledger.items.filter { item in
            switch item.state {
            case .queued:
                true
            case .retryScheduled, .waitingForNetwork, .waitingForICloud:
                item.nextAttemptAt.map { $0 <= now } ?? true
            default:
                false
            }
        }
        .sorted { $0.createdAt < $1.createdAt }
        .prefix(limit)
        .map { $0 }
    }

    func markPreparing(
        _ id: String,
        phase: BackupUploadPhase,
        motionAssetID: String? = nil,
        now: Date = .now
    ) throws {
        guard let state = ledger.items.first(where: { $0.id == id })?.state,
              state != .failed, state != .cancelling
        else { throw BackupQueueStoreError.invalidTransition }
        try update(id) { item in
            item.phase = phase
            item.state = .preparing
            item.motionAssetID = motionAssetID
            item.nextAttemptAt = nil
            item.lastError = nil
            item.taskIdentifier = nil
            item.updatedAt = now
        }
    }

    func markQueued(_ id: String, now: Date = .now) throws {
        guard let state = item(id: id)?.state, state != .failed, state != .cancelling else {
            throw BackupQueueStoreError.invalidTransition
        }
        try update(id) { item in
            item.state = .queued
            item.taskIdentifier = nil
            item.nextAttemptAt = nil
            item.lastError = nil
            item.updatedAt = now
        }
    }

    func markUploading(
        _ id: String,
        phase: BackupUploadPhase,
        checksum: String,
        taskIdentifier: Int,
        now: Date = .now
    ) throws {
        guard ledger.items.first(where: { $0.id == id })?.state == .preparing else {
            throw BackupQueueStoreError.invalidTransition
        }
        try update(id) { item in
            item.phase = phase
            item.state = .uploading
            item.attemptCount += 1
            item.checksum = checksum
            item.taskIdentifier = taskIdentifier
            item.nextAttemptAt = nil
            item.lastError = nil
            item.updatedAt = now
        }
    }

    func markCancelling(_ id: String, now: Date = .now) throws {
        guard ledger.items.first(where: { $0.id == id })?.state == .uploading else {
            throw BackupQueueStoreError.invalidTransition
        }
        try update(id) { item in
            item.state = .cancelling
            item.updatedAt = now
        }
    }

    func markRetry(
        _ id: String,
        state: BackupQueueItemState,
        error: String,
        retryAt: Date?,
        now: Date = .now
    ) throws {
        precondition(state.isWaiting)
        guard let current = ledger.items.first(where: { $0.id == id })?.state,
              current != .failed, current != .cancelling
        else { throw BackupQueueStoreError.invalidTransition }
        try update(id) { item in
            item.state = state
            item.lastError = error
            item.nextAttemptAt = retryAt
            item.taskIdentifier = nil
            item.updatedAt = now
        }
    }

    /// The upload is still requested; only its temporary staged copy was
    /// released. Preserve phase/motion mapping and reject stale callbacks.
    @discardableResult
    func requeueAfterStorageRecovery(
        _ id: String, taskIdentifier: Int, now: Date = .now
    ) throws -> Bool {
        guard let item = item(id: id), item.taskIdentifier == taskIdentifier else { return false }
        if item.state == .cancelling {
            try markFailed(id, error: String(localized: "Upload canceled."), now: now)
            return true
        }
        guard item.state == .uploading else { return false }
        try update(id) { item in
            item.state = .queued
            item.taskIdentifier = nil
            item.nextAttemptAt = nil
            item.lastError = nil
            item.updatedAt = now
        }
        return true
    }

    func markFailed(_ id: String, error: String, now: Date = .now) throws {
        try update(id) { item in
            item.state = .failed
            item.lastError = error
            item.nextAttemptAt = nil
            item.taskIdentifier = nil
            item.updatedAt = now
        }
        // Also arms legacy queues that predate the persisted notification flag.
        ledger.completionNotificationPending = true
        try persist()
    }

    func markCompleted(_ id: String) throws {
        guard let index = ledger.items.firstIndex(where: { $0.id == id }) else { return }
        ledger.items.remove(at: index)
        ledger.completed += 1
        ledger.completionNotificationPending = true
        try persist()
    }

    /// Atomically records that the terminal result for the current batch has
    /// been handed to Notification Center. Repeated cold launches can then
    /// render the completed queue without creating another banner.
    func consumeCompletionNotification() throws {
        guard ledger.completionNotificationPending == true else { return }
        ledger.completionNotificationPending = false
        try persist()
    }

    func discard(_ id: String) throws {
        guard let index = ledger.items.firstIndex(where: { $0.id == id }) else { return }
        ledger.items.remove(at: index)
        try persist()
    }

    /// Menghapus beberapa record sekaligus dengan satu penulisan atomik.
    /// Dipakai saat PhotoKit melaporkan bahwa sekumpulan kegagalan lama sudah
    /// tidak punya aset sumber, supaya daftar dan hitungan notifikasi langsung
    /// bersih tanpa menulis ledger satu kali untuk setiap foto.
    @discardableResult
    func discard(_ ids: Set<String>) throws -> Int {
        guard !ids.isEmpty else { return 0 }
        let previousCount = ledger.items.count
        ledger.items.removeAll { ids.contains($0.id) }
        let removedCount = previousCount - ledger.items.count
        if removedCount > 0 { try persist() }
        return removedCount
    }

    func releaseNetworkWaits(now: Date = .now) throws {
        var changed = false
        for index in ledger.items.indices
        where ledger.items[index].state == .waitingForNetwork {
            ledger.items[index].state = .queued
            ledger.items[index].nextAttemptAt = nil
            ledger.items[index].updatedAt = now
            changed = true
        }
        if changed { try persist() }
    }

    func releaseAuthenticationWaits(now: Date = .now) throws {
        var changed = false
        for index in ledger.items.indices
        where ledger.items[index].state == .waitingForAuthentication {
            ledger.items[index].state = .queued
            ledger.items[index].nextAttemptAt = nil
            ledger.items[index].updatedAt = now
            changed = true
        }
        if changed { try persist() }
    }

    func markAllWaitingForAuthentication(
        error: String,
        now: Date = .now
    ) throws {
        var changed = false
        for index in ledger.items.indices
        where ledger.items[index].state != .failed
            && ledger.items[index].state != .cancelling {
            ledger.items[index].state = .waitingForAuthentication
            ledger.items[index].lastError = error
            ledger.items[index].nextAttemptAt = nil
            ledger.items[index].taskIdentifier = nil
            ledger.items[index].updatedAt = now
            changed = true
        }
        if changed { try persist() }
    }

    func retryFailed(now: Date = .now) throws {
        var changed = false
        for index in ledger.items.indices where ledger.items[index].state == .failed {
            ledger.items[index].state = .queued
            ledger.items[index].lastError = nil
            ledger.items[index].nextAttemptAt = nil
            ledger.items[index].updatedAt = now
            changed = true
        }
        if changed {
            ledger.completionNotificationPending = true
            try persist()
        }
    }

    func retryFailed(_ id: String, now: Date = .now) throws {
        guard ledger.items.first(where: { $0.id == id })?.state == .failed else {
            throw BackupQueueStoreError.invalidTransition
        }
        try update(id) { item in
            item.state = .queued
            item.lastError = nil
            item.nextAttemptAt = nil
            item.updatedAt = now
        }
        ledger.completionNotificationPending = true
        try persist()
    }

    /// Memadankan queue dengan task yang benar-benar masih dimiliki
    /// `nsurlsessiond`. State preparation/upload yang kehilangan task lebih dari
    /// batas stale dilepas kembali ke retry; task lawas tanpa record diadopsi.
    func reconcile(
        activeTasks: [BackupActiveTask],
        now: Date = .now,
        staleAfter: TimeInterval = 10 * 60
    ) throws {
        let activeTasks = activeTasks.filter { accepts($0.context) }
        let activeByID = activeTasks.reduce(into: [String: BackupActiveTask]()) {
            $0[$1.context.localIdentifier] = $1
        }
        var changed = false

        for task in activeTasks {
            if let index = ledger.items.firstIndex(where: { $0.id == task.context.localIdentifier }) {
                if ledger.items[index].state != .cancelling
                    && (ledger.items[index].taskIdentifier != task.taskIdentifier
                    || ledger.items[index].state != .uploading) {
                    ledger.items[index].state = .uploading
                    ledger.items[index].phase = task.context.phase
                    ledger.items[index].checksum = task.context.checksum
                    ledger.items[index].taskIdentifier = task.taskIdentifier
                    ledger.items[index].nextAttemptAt = nil
                    ledger.items[index].updatedAt = now
                    changed = true
                }
            } else {
                ledger.items.append(BackupQueueItem(
                    id: task.context.localIdentifier,
                    phase: task.context.phase,
                    state: .uploading,
                    attemptCount: 1,
                    nextAttemptAt: nil,
                    lastError: nil,
                    checksum: task.context.checksum,
                    taskIdentifier: task.taskIdentifier,
                    motionAssetID: nil,
                    createdAt: now,
                    updatedAt: now))
                ledger.completionNotificationPending = true
                changed = true
            }
        }

        for index in ledger.items.indices {
            let item = ledger.items[index]
            if item.state == .cancelling, activeByID[item.id] == nil {
                ledger.items[index].state = .failed
                ledger.items[index].taskIdentifier = nil
                ledger.items[index].nextAttemptAt = nil
                ledger.items[index].lastError = String(localized: "Upload canceled.")
                ledger.items[index].updatedAt = now
                changed = true
                continue
            }
            guard (item.state == .uploading || item.state == .preparing),
                  activeByID[item.id] == nil,
                  now.timeIntervalSince(item.updatedAt) >= staleAfter
            else { continue }
            ledger.items[index].state = .retryScheduled
            ledger.items[index].taskIdentifier = nil
            ledger.items[index].nextAttemptAt = now
            ledger.items[index].lastError = String(
                localized: "The previous background transfer was interrupted and will resume.")
            ledger.items[index].updatedAt = now
            changed = true
        }

        if changed { try persist() }
    }

    func item(id: String) -> BackupQueueItem? {
        ledger.items.first { $0.id == id }
    }

    private func accepts(_ context: BackupUploadTaskContext) -> Bool {
        guard let ownership else { return false }
        return context.ownership == ownership
    }

    func clear() throws {
        ledger = Ledger()
        try persist()
    }

    private func update(
        _ id: String,
        mutation: (inout BackupQueueItem) -> Void
    ) throws {
        guard let index = ledger.items.firstIndex(where: { $0.id == id }) else { return }
        mutation(&ledger.items[index])
        try persist()
    }

    private func persist() throws {
        do {
            let directory = fileURL.deletingLastPathComponent()
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            var mutableDirectory = directory
            try? mutableDirectory.setResourceValues(values)

            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.sortedKeys]
            let data = try encoder.encode(ledger)
            try data.write(to: fileURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            var mutableFile = fileURL
            try? mutableFile.setResourceValues(values)
            persistenceWarning = nil
            snapshot = Self.makeSnapshot(from: ledger)
        } catch {
            let message = error.localizedDescription
            persistenceWarning = message
            throw BackupQueueStoreError.unavailable(message)
        }
    }

    private static func makeSnapshot(from ledger: Ledger) -> BackupQueueSnapshot {
        func count(_ state: BackupQueueItemState) -> Int {
            ledger.items.count { $0.state == state }
        }
        return BackupQueueSnapshot(
            total: ledger.completed + ledger.items.count,
            completed: ledger.completed,
            queued: count(.queued),
            active: count(.preparing) + count(.uploading) + count(.cancelling),
            waitingForNetwork: count(.waitingForNetwork),
            waitingForICloud: count(.waitingForICloud),
            waitingForAuthentication: count(.waitingForAuthentication),
            retryScheduled: count(.retryScheduled),
            failed: count(.failed),
            completionNotificationPending: ledger.completionNotificationPending ?? false,
            nextAttemptAt: ledger.items.compactMap(\.nextAttemptAt).min(),
            lastError: ledger.items
                .sorted { $0.updatedAt > $1.updatedAt }
                .compactMap(\.lastError)
                .first)
    }
}
