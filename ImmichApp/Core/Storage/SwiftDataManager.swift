import Foundation
import SQLite3
import SwiftData
import Observation

enum LocalDatabaseMaintenanceError: LocalizedError {
    case exportFailed
    case persistentStoreUnavailable

    var errorDescription: String? {
        switch self {
        case .exportFailed:
            "The local sync database could not be exported."
        case .persistentStoreUnavailable:
            "The local sync database is temporarily unavailable."
        }
    }
}

enum LocalStoreStartupState: Equatable {
    case ready
    case recovered(
        quarantinedStore: URL?,
        restoredBackupRecords: Int,
        warning: String?
    )
    case protectionUnavailable(String)
    case persistentStoreUnavailable(String)

    var isPersistentStoreAvailable: Bool {
        switch self {
        case .ready, .recovered, .protectionUnavailable:
            true
        case .persistentStoreUnavailable:
            false
        }
    }
}

private struct BackupRecordSnapshot: Codable, Equatable {
    let id: String
    let assetId: String
    let deviceAssetId: String
    let localIdentifier: String
    let createdAt: Date
}

private struct BackupRecordJournal: Codable {
    let version: Int
    let records: [BackupRecordSnapshot]
    var nonTimelineAssetIDs: [String]? = nil
    var archivedAssetIDs: [String]? = nil
}

@MainActor
@Observable
final class SwiftDataManager {
    static let shared = SwiftDataManager()

    let modelContainer: ModelContainer
    let modelContext: ModelContext
    private let storeURL: URL
    private let backupJournalURL: URL
    private let fileManager: FileManager
    private(set) var startupState: LocalStoreStartupState
    /// Kept with backup mappings because clearing the rebuildable cache must
    /// not make a locked or archived device copy appear in Photos.
    private(set) var nonTimelineAssetIDs: Set<String> = []
    private(set) var archivedAssetIDs: Set<String> = []
    @ObservationIgnored private var visibilityNeedsPersistence = false
    var privateAssetIDs: Set<String> {
        nonTimelineAssetIDs.subtracting(archivedAssetIDs)
    }
    private(set) var visibilityMutationRevision = UUID()
    /// Upload preparation can finish before its background transfer. Viewers
    /// refresh device/server actions only after a mapping has actually saved.
    private(set) var backupMappingRevision = UUID()
    /// Local actions can change the timeline without a sync completing.
    private(set) var assetMutationRevision = UUID()

    var isPersistentStoreAvailable: Bool {
        startupState.isPersistentStoreAvailable
    }

    init(
        storeURL requestedStoreURL: URL? = nil,
        backupJournalURL requestedJournalURL: URL? = nil,
        fileManager: FileManager = .default
    ) {
        let schema = Schema(versionedSchema: LocalStoreSchemaV4.self)
        let configuration: ModelConfiguration
        if let requestedStoreURL {
            configuration = ModelConfiguration(
                schema: schema,
                url: requestedStoreURL,
                cloudKitDatabase: .none)
        } else {
            configuration = ModelConfiguration(
                schema: schema,
                isStoredInMemoryOnly: false,
                cloudKitDatabase: .none)
        }

        let resolvedStoreURL = configuration.url
        let resolvedJournalURL = requestedJournalURL
            ?? resolvedStoreURL.deletingLastPathComponent()
                .appendingPathComponent("ImmichBackupRecords-v1.json")
        let bootstrap = Self.bootstrapContainer(
            schema: schema,
            configuration: configuration,
            storeURL: resolvedStoreURL,
            fileManager: fileManager)

        self.storeURL = resolvedStoreURL
        self.backupJournalURL = resolvedJournalURL
        self.fileManager = fileManager
        self.modelContainer = bootstrap.container
        self.modelContext = ModelContext(bootstrap.container)
        self.startupState = bootstrap.state

        reconcileBackupRecordJournalAfterStartup()
    }

    private struct ContainerBootstrap {
        let container: ModelContainer
        let state: LocalStoreStartupState
    }

    private static func bootstrapContainer(
        schema: Schema,
        configuration: ModelConfiguration,
        storeURL: URL,
        fileManager: FileManager
    ) -> ContainerBootstrap {
        do {
            let container = try ModelContainer(
                for: schema,
                migrationPlan: LocalStoreMigrationPlan.self,
                configurations: [configuration])
            return ContainerBootstrap(container: container, state: .ready)
        } catch {
            let openingError = error.localizedDescription
            let quarantinedStore = try? quarantineStoreFiles(
                at: storeURL,
                fileManager: fileManager)

            do {
                let recoveredConfiguration = ModelConfiguration(
                    schema: schema,
                    url: storeURL,
                    cloudKitDatabase: .none)
                let container = try ModelContainer(
                    for: schema,
                    migrationPlan: LocalStoreMigrationPlan.self,
                    configurations: [recoveredConfiguration])
                return ContainerBootstrap(
                    container: container,
                    state: .recovered(
                        quarantinedStore: quarantinedStore,
                        restoredBackupRecords: 0,
                        warning: "The previous local cache could not be opened: \(openingError)"))
            } catch {
                // A broken disk store must not crash application launch. The
                // in-memory container keeps read-only/cache UI usable, while
                // backup is explicitly disabled through `startupState` so an
                // empty mapping can never be mistaken for a clean database.
                let fallbackConfiguration = ModelConfiguration(
                    schema: schema,
                    isStoredInMemoryOnly: true,
                    cloudKitDatabase: .none)
                do {
                    let container = try ModelContainer(
                        for: schema,
                        configurations: [fallbackConfiguration])
                    return ContainerBootstrap(
                        container: container,
                        state: .persistentStoreUnavailable(error.localizedDescription))
                } catch {
                    // If SwiftData cannot even construct the current schema in
                    // memory, no storage-backed feature can run safely.
                    fatalError("Unable to create the SwiftData model: \(error)")
                }
            }
        }
    }

    private static func quarantineStoreFiles(
        at storeURL: URL,
        fileManager: FileManager
    ) throws -> URL? {
        let candidates = [
            storeURL,
            URL(fileURLWithPath: storeURL.path + "-shm"),
            URL(fileURLWithPath: storeURL.path + "-wal"),
        ].filter { fileManager.fileExists(atPath: $0.path) }
        guard !candidates.isEmpty else { return nil }

        let quarantineDirectory = storeURL.deletingLastPathComponent()
            .appendingPathComponent("RecoveredStores", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fileManager.createDirectory(
            at: quarantineDirectory,
            withIntermediateDirectories: true)

        for source in candidates {
            try fileManager.moveItem(
                at: source,
                to: quarantineDirectory.appendingPathComponent(source.lastPathComponent))
        }
        return quarantineDirectory
    }

    func getCachedAsset(id: String) -> CachedAsset? {
        var descriptor = FetchDescriptor<CachedAsset>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        return try? modelContext.fetch(descriptor).first
    }

    /// Aset linimasa sebagai nilai ringan, dibaca PER HALAMAN.
    ///
    /// Aset arsip disaring di kueri, bukan di pemanggil — menyaring setelahnya
    /// berarti sempat memuat yang tidak dipakai.
    ///
    ///
    /// Objek `@Model` bukan struct ringan: tiap satunya terikat context, punya
    /// penyimpanan balik sendiri, dan ikut dilacak perubahannya. Mengambil
    /// puluhan ribu sekaligus berarti puluhan ribu objek itu hidup BERSAMAAN —
    /// ratusan megabyte pada puncaknya, dan itu terjadi tepat saat aplikasi baru
    /// dibuka.
    ///
    /// Dengan halaman dua ribu dan context yang mati di akhir tiap halaman, yang
    /// hidup bersamaan tidak pernah lebih dari satu halaman. Yang tersisa cuma
    /// struct hasil salinannya.
    func timelineAssets() -> [TimelineRow] {
        let pageSize = 2000
        var result: [TimelineRow] = []
        var offset = 0

        while true {
            let page: [TimelineRow] = autoreleasepool {
                var descriptor = FetchDescriptor<CachedAsset>(
                    predicate: #Predicate { !$0.isArchived },
                    sortBy: [.init(\.createdAt, order: .forward)])
                descriptor.includePendingChanges = false
                descriptor.fetchOffset = offset
                descriptor.fetchLimit = pageSize

                let context = ModelContext(modelContainer)
                let rows = (try? context.fetch(descriptor)) ?? []

                return rows.map { row in
                    TimelineRow(
                        asset: AssetLite(
                            id: row.assetId,
                            isVideo: row.type == "VIDEO",
                            ratio: row.ratio ?? 1,
                            thumbhash: row.thumbhash,
                            createdAt: row.createdAt,
                            isFavorite: row.isFavorite,
                            duration: row.duration,
                            livePhotoVideoID: row.livePhotoVideoId),
                        // Sudah dihitung saat sync; tidak ada pemformatan tanggal
                        // di jalur ini sama sekali.
                        monthKey: row.monthKey.isEmpty
                            ? MonthKey.of(row.createdAt)
                            : row.monthKey)
                }
            }

            result.append(contentsOf: page)
            offset += page.count
            if page.count < pageSize { break }
        }

        return result
    }

    func insertOrUpdateCachedAsset(_ asset: CachedAsset) throws {
        upsert(asset)
        try saveWithTimelineVisibility([asset], in: modelContext) {
            try modelContext.save()
        }
    }

    /// Terapkan hasil satu putaran sync dalam SATU save, bukan save per aset.
    ///
    /// Dua hal yang penting di sini:
    ///
    /// 1. Aset yang sudah ada dicari lewat SATU query untuk seluruh batch, bukan
    ///    satu query per aset. Versi lama memanggil `getCachedAsset(id:)` di
    ///    dalam loop — pada sync penuh berisi ribuan aset itu ribuan query
    ///    berurutan, semuanya di main actor, dan antarmuka membeku selama itu.
    /// 2. Ditulis lewat context SEKALI PAKAI, sama seperti jalur bacanya.
    ///    `ModelContext` menahan setiap objek yang lewat, jadi dengan context
    ///    bersama satu sync penuh meninggalkan puluhan ribu objek `@Model`
    ///    tersangkut di memori selama aplikasi hidup. Context ini mati bersama
    ///    fungsinya — datanya sudah aman di penyimpanan.
    func applySyncBatch(
        upserts: [CachedAsset],
        deletedIds: [String],
        expectedVisibilityRevision: UUID? = nil,
        visibilityByID: [String: String] = [:],
        removalReason: RemovedAssets.Reason? = nil
    ) throws {
        if let expectedVisibilityRevision,
           expectedVisibilityRevision != visibilityMutationRevision {
            throw CancellationError()
        }
        publishRemovals(deletedIds, reason: removalReason)
        let context = ModelContext(modelContainer)

        let existing = fetchAssets(ids: upserts.map(\.id) + deletedIds, in: context)
        for asset in upserts {
            if let current = existing[asset.id] { apply(asset, to: current) }
            else { context.insert(asset) }
        }
        for id in deletedIds {
            if let current = existing[id] { context.delete(current) }
        }

        try saveWithTimelineVisibility(upserts, visibilityByID: visibilityByID, in: context) {
            try context.save()
        }

        let deleted = Set(deletedIds)
        RemovedAssets.shared.restore(upserts.map(\.id).filter { !deleted.contains($0) })
        // Upsert-only deltas must also invalidate older in-flight snapshots.
        if !upserts.isEmpty, deletedIds.isEmpty {
            assetMutationRevision = UUID()
        }
    }

    /// Promotion is one synchronous save on the shared context, so existing UI
    /// references see updates and deletions immediately. Download staging is
    /// bounded; this final transaction still tracks the snapshot's changed models.
    func replaceSyncCache(
        with staging: FullSyncStaging,
        expectedVisibilityRevision: UUID,
        expectedAssetRevision: UUID
    ) throws {
        try Task.checkCancellation()
        guard expectedVisibilityRevision == visibilityMutationRevision,
              expectedAssetRevision == assetMutationRevision else {
            throw CancellationError()
        }
        // Preserve unrelated pending edits before establishing our rollback point.
        try modelContext.save()
        let previousNonTimeline = nonTimelineAssetIDs
        let previousArchived = archivedAssetIDs
        let previousNeedsPersistence = visibilityNeedsPersistence
        let backupRecords = try currentBackupRecordSnapshots()
        var activeIDs: Set<String> = []
        var visibilityByID: [String: String] = [:]
        var trashedIDs: Set<String> = []
        var permanentlyDeletedIDs: Set<String> = []
        var removedIDs: Set<String> = []
        var nonTimeline = previousNonTimeline
        var archived = previousArchived
        var journalWritten = false
        do {
            try staging.forEachBatch { entries in
                try Task.checkCancellation()
                let ids = Array(Set(entries.map(\.id)))
                var existing: [String: CachedAsset] = [:]
                for offset in stride(from: 0, to: ids.count, by: 400) {
                    let slice = Array(ids[offset..<min(offset + 400, ids.count)])
                    for asset in try modelContext.fetch(FetchDescriptor<CachedAsset>(
                        predicate: #Predicate { slice.contains($0.id) })) {
                        existing[asset.id] = asset
                    }
                }
                for entry in entries {
                    if let asset = entry.asset, let visibility = entry.visibility {
                        let replacement = asset.cachedAsset(visibility: visibility)
                        if let current = existing[entry.id] { apply(replacement, to: current) }
                        else {
                            modelContext.insert(replacement)
                            existing[entry.id] = replacement
                        }
                        activeIDs.insert(entry.id)
                        visibilityByID[entry.id] = visibility
                        trashedIDs.remove(entry.id)
                        permanentlyDeletedIDs.remove(entry.id)
                    } else {
                        activeIDs.remove(entry.id)
                        visibilityByID.removeValue(forKey: entry.id)
                        removedIDs.insert(entry.id)
                        if entry.permanentlyDeleted {
                            permanentlyDeletedIDs.insert(entry.id)
                            trashedIDs.remove(entry.id)
                        } else {
                            permanentlyDeletedIDs.remove(entry.id)
                            trashedIDs.insert(entry.id)
                        }
                    }
                }
            }
            // SwiftData's store enumeration omits unsaved inserts. Remove a new
            // row whose last streamed event deleted it before sweeping old rows.
            for case let asset as CachedAsset in modelContext.insertedModelsArray {
                if !activeIDs.contains(asset.id) { modelContext.delete(asset) }
            }
            try modelContext.enumerate(FetchDescriptor<CachedAsset>(),
                batchSize: 500, allowEscapingMutations: true) { asset in
                try Task.checkCancellation()
                if !activeIDs.contains(asset.id) {
                    removedIDs.insert(asset.id)
                    modelContext.delete(asset)
                }
            }
            removedIDs.subtract(activeIDs)
            for (id, visibility) in visibilityByID {
                if visibility == "timeline" { nonTimeline.remove(id) }
                else { nonTimeline.insert(id) }
                if visibility == "archive" { archived.insert(id) }
                else { archived.remove(id) }
            }
            var storageUpdates = visibilityByID
            if previousNeedsPersistence {
                for id in nonTimeline {
                    storageUpdates[id] = archived.contains(id) ? "archive" : "unknown"
                }
            }
            try stagePrivateVisibility(storageUpdates, in: modelContext)
            try Task.checkCancellation()
            // A journal failure must leave the working cache untouched. Unlike
            // delta privacy writes, full replacement must not save after failure.
            try writeBackupRecordJournal(backupRecords,
                nonTimelineAssetIDs: nonTimeline, archivedAssetIDs: archived)
            journalWritten = true
            try Task.checkCancellation()
            try modelContext.save()
        } catch {
            modelContext.rollback()
            if journalWritten {
                do {
                    try writeBackupRecordJournal(backupRecords,
                        nonTimelineAssetIDs: previousNonTimeline,
                        archivedAssetIDs: previousArchived)
                } catch {
                    // If restoring the journal also fails, keep every known
                    // restriction until both durable copies can be reconciled.
                    nonTimelineAssetIDs.formUnion(nonTimeline)
                    archivedAssetIDs.formIntersection(archived)
                    visibilityNeedsPersistence = true
                    WidgetSnapshotExporter.clear()
                }
            }
            throw error
        }
        nonTimelineAssetIDs = nonTimeline
        archivedAssetIDs = archived
        visibilityNeedsPersistence = false
        DeletedServerAssetRegistry.shared.restore(Array(activeIDs))
        DeletedServerAssetRegistry.shared.record(Array(trashedIDs), permanently: false)
        DeletedServerAssetRegistry.shared.record(Array(permanentlyDeletedIDs), permanently: true)
        publishRemovals(Array(removedIDs))
        RemovedAssets.shared.restore(Array(activeIDs))
        assetMutationRevision = UUID()
        WidgetSnapshotExporter.clear()
    }

    private func saveWithTimelineVisibility(
        _ assets: [CachedAsset], visibilityByID: [String: String] = [:],
        in context: ModelContext, save: () throws -> Void
    ) throws {
        var updates: [String: String] = [:]
        for asset in assets {
            updates[asset.id] = visibilityByID[asset.id]
                ?? (asset.isArchived ? "unknown" : "timeline")
        }
        try saveVisibility(updates, in: context, save: save)
    }

    private func saveVisibility(
        _ updates: [String: String], in context: ModelContext, save: () throws -> Void
    ) throws {
        var nonTimeline = nonTimelineAssetIDs
        var archived = archivedAssetIDs
        for (id, visibility) in updates {
            if visibility == "timeline" {
                nonTimeline.remove(id)
            } else {
                nonTimeline.insert(id)
            }
            if visibility == "archive" { archived.insert(id) }
            else { archived.remove(id) }
        }
        let changed = nonTimeline != nonTimelineAssetIDs || archived != archivedAssetIDs
        let retryingProtection = visibilityNeedsPersistence
        let needsPersistence = changed || retryingProtection
        let newlySuppressed = nonTimeline.subtracting(nonTimelineAssetIDs)
            .union(nonTimeline.subtracting(archived).subtracting(privateAssetIDs))
        // Restrictions apply immediately. Releasing an old restriction requires
        // both durable copies to agree, even when the server action succeeded.
        nonTimelineAssetIDs.formUnion(nonTimeline)
        archivedAssetIDs.formIntersection(archived)
        if !newlySuppressed.isEmpty { WidgetSnapshotExporter.clear() }
        visibilityNeedsPersistence = needsPersistence

        var storageError: Error?
        do {
            if needsPersistence {
                try writeBackupRecordJournal(currentBackupRecordSnapshots(),
                    nonTimelineAssetIDs: nonTimeline, archivedAssetIDs: archived)
            }
        } catch { storageError = error }
        do {
            var storageUpdates = updates
            if retryingProtection {
                // Retry all conservative protections after either durable copy
                // failed, even if this response repeats an unchanged class.
                for id in nonTimeline {
                    storageUpdates[id] = archived.contains(id) ? "archive" : "unknown"
                }
            }
            try stagePrivateVisibility(storageUpdates, in: context)
            try save()
        } catch {
            if storageError == nil { storageError = error }
        }
        if let storageError { throw storageError }
        nonTimelineAssetIDs = nonTimeline
        archivedAssetIDs = archived
        visibilityNeedsPersistence = false
    }

    private func stagePrivateVisibility(_ updates: [String: String], in context: ModelContext) throws {
        let ids = Array(updates.keys)
        for offset in stride(from: 0, to: ids.count, by: 400) {
            let slice = Array(ids[offset..<min(offset + 400, ids.count)])
            let records = try context.fetch(FetchDescriptor<PrivateAssetRecord>(
                predicate: #Predicate { slice.contains($0.id) }))
            let existing = Dictionary(uniqueKeysWithValues: records.map { ($0.id, $0) })
            for id in slice {
                if updates[id] == "timeline" || updates[id] == "archive" {
                    if let record = existing[id] { context.delete(record) }
                } else if existing[id] == nil {
                    context.insert(PrivateAssetRecord(id: id))
                }
            }
        }
    }

    private func publishRemovals(_ ids: [String], reason: RemovedAssets.Reason? = nil) {
        guard !ids.isEmpty else { return }
        if let reason {
            RemovedAssets.shared.remove(ids, reason: reason)
        } else {
            let trashed = ids.filter { DeletedServerAssetRegistry.shared.isTrashed($0) }
            RemovedAssets.shared.remove(trashed, reason: .trashed)
            RemovedAssets.shared.remove(ids.filter { !DeletedServerAssetRegistry.shared.isTrashed($0) })
        }
        assetMutationRevision = UUID()
        WidgetSnapshotExporter.clear()
    }

    /// Membuang aset dari cache lokal tanpa lewat sync.
    ///
    /// Dipakai untuk aset yang ditolak server ("Not found or no asset.read
    /// access"): entri itu tidak akan pernah datang lagi lewat delta sync —
    /// stream hanya membawa yang BERUBAH, dan dari sudut pandang server tidak ada
    /// yang berubah — jadi kalau tidak dibuang di sini ia menetap sampai ada
    /// sync penuh.
    func purgeAssets(_ ids: [String], reason: RemovedAssets.Reason = .unavailable) throws {
        guard !ids.isEmpty else { return }
        visibilityMutationRevision = UUID()
        // Satu titik cegat untuk SEMUA jalur yang membuang aset.
        //
        // Cache linimasa bukan satu-satunya tempat foto itu berdiri: album,
        // Favorites, dan foto per orang punya potretnya masing-masing. Mencatat
        // pembuangannya di sini berarti setiap layar bisa menyaring miliknya
        // sendiri tanpa ada yang perlu diberi tahu satu per satu.
        try applySyncBatch(upserts: [], deletedIds: ids, removalReason: reason)
    }

    /// Dipecah per potongan: SQLite membatasi jumlah pengikat dalam satu klausa
    /// `IN`, dan daftar id sepanjang ribuan akan melewatinya.
    private func fetchAssets(
        ids: [String],
        in context: ModelContext
    ) -> [String: CachedAsset] {
        var result: [String: CachedAsset] = [:]
        for chunk in stride(from: 0, to: ids.count, by: 400) {
            let slice = Array(ids[chunk..<min(chunk + 400, ids.count)])
            let descriptor = FetchDescriptor<CachedAsset>(
                predicate: #Predicate { slice.contains($0.id) })
            for asset in (try? context.fetch(descriptor)) ?? [] {
                result[asset.id] = asset
            }
        }
        return result
    }

    private func apply(_ asset: CachedAsset, to existing: CachedAsset) {
        existing.type = asset.type
        existing.isFavorite = asset.isFavorite
        existing.isArchived = asset.isArchived
        existing.createdAt = asset.createdAt
        existing.monthKey = asset.monthKey
        existing.updatedAt = asset.updatedAt
        existing.exifData = asset.exifData
        existing.ratio = asset.ratio
        existing.thumbhash = asset.thumbhash
        existing.duration = asset.duration
        existing.livePhotoVideoId = asset.livePhotoVideoId
    }

    private func upsert(_ asset: CachedAsset) {
        if let existing = getCachedAsset(id: asset.id) {
            apply(asset, to: existing)
        } else {
            modelContext.insert(asset)
        }
    }

    // MARK: - Tambalan dari layar lain

    /// Patch only the fields accepted by an asset action. The cache can contain
    /// visibility and media metadata that the detail response does not include.
    func patchCachedAsset(
        _ id: String,
        isFavorite: Bool? = nil,
        createdAt: Date? = nil,
        description: String? = nil,
        latitude: Double? = nil,
        longitude: Double? = nil
    ) throws {
        guard let asset = getCachedAsset(id: id) else {
            // A collection may show a server asset before its first sync. Its
            // observers still need the accepted action, without inventing a row.
            assetMutationRevision = UUID()
            return
        }
        if let isFavorite { asset.isFavorite = isFavorite }
        if let createdAt {
            asset.createdAt = createdAt
            asset.monthKey = MonthKey.of(createdAt)
        }
        if description != nil || createdAt != nil || latitude != nil || longitude != nil {
            var exif = asset.exifData
                .flatMap { $0.data(using: .utf8) }
                .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
            if let description { exif["description"] = description }
            if let createdAt {
                exif["dateTimeOriginal"] = ISO8601DateFormatter.immichFractional.string(from: createdAt)
            }
            if let latitude { exif["latitude"] = latitude }
            if let longitude { exif["longitude"] = longitude }
            asset.exifData = String(data: try JSONSerialization.data(withJSONObject: exif), encoding: .utf8)
        }
        try modelContext.save()
        assetMutationRevision = UUID()
    }

    /// Track whether a server asset and its mapped device copy may appear in
    /// Photos, even when the server row is absent from the rebuildable cache.

    func setTimelineVisibility(_ ids: [String], inTimeline: Bool) throws {
        try setAssetVisibility(ids, to: inTimeline ? "timeline" : "unknown")
    }

    func setAssetVisibility(_ ids: [String], to visibility: String) throws {
        guard !ids.isEmpty else { return }
        visibilityMutationRevision = UUID()
        assetMutationRevision = UUID()
        for asset in fetchAssets(ids: ids, in: modelContext).values {
            asset.isArchived = visibility != "timeline"
        }
        try saveVisibility(Dictionary(ids.map { ($0, visibility) }, uniquingKeysWith: { _, new in new }),
            in: modelContext) {
            try modelContext.save()
        }
    }

    /// Only current network responses may refine legacy unknown visibility.
    /// Metadata reads never restore deletions or publish an asset-action revision.
    func recordServerVisibility(_ assets: [AssetResponseDTO]) throws {
        let previousNonTimeline = nonTimelineAssetIDs
        let privateIDs = privateAssetIDs
        var classifications: [String: String] = [:]
        var observedPrivate = false
        for asset in assets where !asset.isTrashed {
            let visibility = asset.visibility ?? (asset.isArchived ? "archive" : "timeline")
            let isPrivate = visibility != "timeline" && visibility != "archive"
            if isPrivate { observedPrivate = true }
            if let previous = classifications[asset.id], previous != "timeline", previous != "archive" {
                continue
            }
            classifications[asset.id] = visibility
        }
        var updates: [String: String] = [:]
        for (id, visibility) in classifications {
            if visibility == "archive" {
                if !archivedAssetIDs.contains(id) { updates[id] = visibility }
            } else if visibility == "timeline" {
                if nonTimelineAssetIDs.contains(id) { updates[id] = visibility }
            } else {
                if !privateIDs.contains(id) { updates[id] = visibility }
            }
        }
        defer {
            // Even unchanged private evidence must invalidate an older request
            // that could otherwise relax the same legacy unknown restriction.
            if observedPrivate || !nonTimelineAssetIDs.subtracting(previousNonTimeline).isEmpty {
                visibilityMutationRevision = UUID()
            }
        }
        guard !updates.isEmpty || visibilityNeedsPersistence else { return }
        for asset in fetchAssets(ids: Array(updates.keys), in: modelContext).values {
            asset.isArchived = updates[asset.id] != "timeline"
        }
        try saveVisibility(updates, in: modelContext) {
            try modelContext.save()
        }
    }

    /// Mengembalikan aset ke cache linimasa dari data seadanya.
    ///
    /// Untuk restore dari tong sampah: aset yang dibuang sudah TIDAK ADA di
    /// cache, jadi tidak ada yang bisa ditambal — ia harus ditulis ulang. Yang
    /// tersedia cuma yang dibawa layar sampah (`AssetLite`), dan itu cukup:
    /// petak grid hanya butuh rasio, thumbhash, tanggal, dan durasi. Sisanya
    /// menyusul saat sync berikutnya menimpanya.
    func restoreToTimeline(_ assets: [AssetLite]) throws {
        guard !assets.isEmpty else { return }
        for asset in assets {
            let cached = CachedAsset(
                id: asset.id,
                assetId: asset.id,
                type: asset.isVideo ? "VIDEO" : "IMAGE",
                isFavorite: asset.isFavorite,
                isArchived: nonTimelineAssetIDs.contains(asset.id),
                duration: asset.duration,
                livePhotoVideoId: asset.livePhotoVideoID,
                createdAt: asset.createdAt,
                updatedAt: Date(),
                ratio: asset.ratio,
                thumbhash: asset.thumbhash)
            upsert(cached)
        }
        try modelContext.save()
        assetMutationRevision = UUID()
    }

    func cachedAssetCount() -> Int {
        (try? modelContext.fetchCount(FetchDescriptor<CachedAsset>())) ?? 0
    }

    /// Jumlah aset yang benar-benar MASUK LINIMASA.
    ///
    /// Berbeda dari `cachedAssetCount`, yang menghitung semuanya termasuk arsip
    /// — angka itu benar untuk pembukuan sync, tapi salah untuk menjawab "apakah
    /// ada yang bisa digambar sekarang". Cache yang isinya arsip semua akan
    /// menjawab "ada", lalu linimasanya ternyata kosong.
    func timelineAssetCount() -> Int {
        (try? modelContext.fetchCount(
            FetchDescriptor<CachedAsset>(predicate: #Predicate { !$0.isArchived }))) ?? 0
    }

    func deleteCachedAsset(id: String) throws {
        if let asset = getCachedAsset(id: id) {
            modelContext.delete(asset)
            try modelContext.save()
        }
    }

    /// Snapshot SQLite yang konsisten untuk dibagikan lewat Sync Status.
    ///
    /// Menyalin file `.store` biasa tidak cukup karena perubahan terbaru bisa
    /// masih berada di WAL. SQLite backup API membaca keduanya sebagai satu
    /// snapshot tanpa menutup database yang sedang dipakai aplikasi.
    func exportDatabase() async throws -> URL {
        guard startupState.isPersistentStoreAvailable else {
            throw LocalDatabaseMaintenanceError.persistentStoreUnavailable
        }

        try modelContext.save()
        let sourceURL = storeURL
        let destinationURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "Immich-Sync-\(Int(Date.now.timeIntervalSince1970)).sqlite")

        return try await Task.detached(priority: .utility) {
            try Self.createDatabaseSnapshot(
                from: sourceURL,
                to: destinationURL)
            return destinationURL
        }.value
    }

    /// Menghapus database/index sinkronisasi yang dapat dibangun ulang.
    ///
    /// `BackupRecord` sengaja dipertahankan. Menghapus pasangan unggahan akan
    /// membuat aset yang sudah aman di server dianggap belum pernah diunggah dan
    /// berpotensi masuk antrean lagi. Foto perangkat dan server juga tidak
    /// disentuh.
    func resetSyncDatabase() throws {
        try modelContext.delete(model: CachedAsset.self)
        try modelContext.delete(model: SyncState.self)
        try modelContext.delete(model: LocalAssetChecksum.self)
        try modelContext.save()
    }

    // MARK: - Backup-record protection

    /// `BackupRecord` bukan cache: kehilangan tabel ini membuat foto yang sudah
    /// ada di server tampak belum pernah diunggah. Karena itu ia dicerminkan ke
    /// journal JSON kecil di luar SQLite. Jika cache SQLite rusak, store boleh
    /// dibangun ulang dan mapping upload dipulihkan dari journal ini.
    private func reconcileBackupRecordJournalAfterStartup() {
        guard startupState.isPersistentStoreAvailable else { return }

        do {
            let hiddenRows = try modelContext.fetch(FetchDescriptor<CachedAsset>(
                predicate: #Predicate { $0.isArchived }))
            nonTimelineAssetIDs = Set(hiddenRows.map(\.id))
            let privateIDs = Set(try modelContext.fetch(FetchDescriptor<PrivateAssetRecord>()).map(\.id))
            nonTimelineAssetIDs.formUnion(privateIDs)
            let journal = try readBackupRecordJournal()
            let protectedIDs = Set(journal.nonTimelineAssetIDs ?? [])
            nonTimelineAssetIDs.formUnion(protectedIDs)
            archivedAssetIDs = Set(journal.archivedAssetIDs ?? [])
                .intersection(nonTimelineAssetIDs).subtracting(privateIDs)
            if !nonTimelineAssetIDs.subtracting(protectedIDs).isEmpty {
                WidgetSnapshotExporter.clear()
            }
            let restoredCount = try restoreMissingBackupRecords(journal.records)
            try writeBackupRecordJournal(currentBackupRecordSnapshots())

            if case let .recovered(quarantinedStore, _, warning) = startupState {
                startupState = .recovered(
                    quarantinedStore: quarantinedStore,
                    restoredBackupRecords: restoredCount,
                    warning: warning)
            }
        } catch {
            visibilityNeedsPersistence = true
            // Unknown visibility must not turn mapped device copies into public
            // fallbacks. A fresh timeline sync can release these conservative IDs.
            if let records = try? currentBackupRecordSnapshots() {
                let mappedIDs = Set(records.map(\.assetId))
                let newlyHidden = mappedIDs.subtracting(nonTimelineAssetIDs)
                nonTimelineAssetIDs.formUnion(mappedIDs)
                if !newlyHidden.isEmpty { WidgetSnapshotExporter.clear() }
            }
            let message = "Backup mapping protection is unavailable: \(error.localizedDescription)"
            if case let .recovered(quarantinedStore, restoredCount, warning) = startupState {
                startupState = .recovered(
                    quarantinedStore: quarantinedStore,
                    restoredBackupRecords: restoredCount,
                    warning: [warning, message].compactMap { $0 }.joined(separator: " "))
            } else {
                startupState = .protectionUnavailable(message)
            }
        }
    }

    private func readBackupRecordJournal() throws -> BackupRecordJournal {
        guard fileManager.fileExists(atPath: backupJournalURL.path) else {
            return BackupRecordJournal(version: 1, records: [])
        }
        let data = try Data(contentsOf: backupJournalURL)
        let journal = try JSONDecoder().decode(BackupRecordJournal.self, from: data)
        guard journal.version == 1 else {
            throw CocoaError(.coderReadCorrupt)
        }
        return journal
    }

    private func currentBackupRecordSnapshots() throws -> [BackupRecordSnapshot] {
        try modelContext.fetch(FetchDescriptor<BackupRecord>())
            .map {
                BackupRecordSnapshot(
                    id: $0.id,
                    assetId: $0.assetId,
                    deviceAssetId: $0.deviceAssetId,
                    localIdentifier: $0.localIdentifier,
                    createdAt: $0.createdAt)
            }
            .sorted { $0.id < $1.id }
    }

    @discardableResult
    private func restoreMissingBackupRecords(
        _ snapshots: [BackupRecordSnapshot]
    ) throws -> Int {
        guard !snapshots.isEmpty else { return 0 }
        let existingIDs = Set(
            try modelContext.fetch(FetchDescriptor<BackupRecord>()).map(\.id))
        var restoredCount = 0

        for snapshot in snapshots where !existingIDs.contains(snapshot.id) {
            modelContext.insert(BackupRecord(
                id: snapshot.id,
                assetId: snapshot.assetId,
                deviceAssetId: snapshot.deviceAssetId,
                localIdentifier: snapshot.localIdentifier,
                createdAt: snapshot.createdAt))
            restoredCount += 1
        }
        if restoredCount > 0 { try modelContext.save() }
        return restoredCount
    }

    private func writeBackupRecordJournal(
        _ snapshots: [BackupRecordSnapshot],
        nonTimelineAssetIDs: Set<String>? = nil,
        archivedAssetIDs: Set<String>? = nil
    ) throws {
        let directory = backupJournalURL.deletingLastPathComponent()
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(BackupRecordJournal(
            version: 1, records: snapshots,
            nonTimelineAssetIDs: (nonTimelineAssetIDs ?? self.nonTimelineAssetIDs).sorted(),
            archivedAssetIDs: (archivedAssetIDs ?? self.archivedAssetIDs).sorted()))
        try data.write(to: backupJournalURL, options: [.atomic])

        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var mutableURL = backupJournalURL
        try? mutableURL.setResourceValues(values)

        #if os(iOS)
        try? fileManager.setAttributes(
            [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
            ofItemAtPath: backupJournalURL.path)
        #endif
    }

    private func refreshBackupRecordJournal() {
        guard startupState.isPersistentStoreAvailable else { return }
        do {
            try writeBackupRecordJournal(currentBackupRecordSnapshots())
        } catch {
            startupState = .protectionUnavailable(
                "Backup mapping protection is unavailable: \(error.localizedDescription)")
        }
        backupMappingRevision = UUID()
    }

    private nonisolated static func createDatabaseSnapshot(
        from sourceURL: URL,
        to destinationURL: URL
    ) throws {
        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: destinationURL.path) {
            try fileManager.removeItem(at: destinationURL)
        }

        var source: OpaquePointer?
        var destination: OpaquePointer?

        guard sqlite3_open_v2(
            sourceURL.path,
            &source,
            SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX,
            nil) == SQLITE_OK
        else {
            if source != nil { sqlite3_close(source) }
            throw LocalDatabaseMaintenanceError.exportFailed
        }
        defer { sqlite3_close(source) }

        guard sqlite3_open_v2(
            destinationURL.path,
            &destination,
            SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX,
            nil) == SQLITE_OK
        else {
            if destination != nil { sqlite3_close(destination) }
            throw LocalDatabaseMaintenanceError.exportFailed
        }
        defer { sqlite3_close(destination) }

        guard let backup = sqlite3_backup_init(destination, "main", source, "main") else {
            throw LocalDatabaseMaintenanceError.exportFailed
        }
        let stepResult = sqlite3_backup_step(backup, -1)
        let finishResult = sqlite3_backup_finish(backup)
        guard stepResult == SQLITE_DONE, finishResult == SQLITE_OK else {
            throw LocalDatabaseMaintenanceError.exportFailed
        }
    }

    /// Menghapus seluruh data yang terikat akun dari penyimpanan lokal.
    ///
    /// Logout juga harus menghapus checkpoint sync, pasangan backup,
    /// dan checksum lokal agar akun berikutnya tidak mewarisi keadaan akun lama.
    func clearAllAccountData() throws {
        visibilityMutationRevision = UUID()
        let previousMappings = try currentBackupRecordSnapshots()
        // Kosongkan journal lebih dahulu agar mapping akun lama tidak dapat
        // dipulihkan ke akun baru bila proses dihentikan tepat setelah logout.
        try writeBackupRecordJournal([], nonTimelineAssetIDs: [], archivedAssetIDs: [])
        do {
            try modelContext.delete(model: CachedAsset.self)
            try modelContext.delete(model: BackupRecord.self)
            try modelContext.delete(model: SyncState.self)
            try modelContext.delete(model: LocalAssetChecksum.self)
            try modelContext.delete(model: PrivateAssetRecord.self)
            try modelContext.save()
            nonTimelineAssetIDs.removeAll()
            archivedAssetIDs.removeAll()
            visibilityNeedsPersistence = false
        } catch {
            modelContext.rollback()
            // Logout yang gagal tidak boleh sekaligus menghapus salinan
            // perlindungan mapping akun yang masih ada di database.
            try? writeBackupRecordJournal(previousMappings)
            throw error
        }
        backupMappingRevision = UUID()
    }

    func getBackupRecord(deviceAssetId: String) -> BackupRecord? {
        var descriptor = FetchDescriptor<BackupRecord>(predicate: #Predicate { $0.deviceAssetId == deviceAssetId })
        descriptor.fetchLimit = 1
        return try? modelContext.fetch(descriptor).first
    }

    func getBackupRecord(localIdentifier: String) -> BackupRecord? {
        var descriptor = FetchDescriptor<BackupRecord>(
            predicate: #Predicate { $0.localIdentifier == localIdentifier })
        descriptor.fetchLimit = 1
        return try? modelContext.fetch(descriptor).first
    }

    /// Semua `localIdentifier` yang pernah diunggah lewat aplikasi ini.
    ///
    /// Inilah satu-satunya cara murah menjawab "foto di perangkat ini sudah ada
    /// di server atau belum". Yang TIDAK terjawab olehnya: foto yang diunggah
    /// dari web atau perangkat lain — ia akan terbaca "hanya di perangkat"
    /// sampai diunggah dari sini. Alternatifnya mencocokkan checksum, dan itu
    /// berarti membaca byte penuh setiap foto di pustaka.
    func uploadedLocalIdentifiers() -> Set<String> {
        let descriptor = FetchDescriptor<BackupRecord>(
            predicate: #Predicate { $0.localIdentifier != "" })
        let records = (try? modelContext.fetch(descriptor)) ?? []
        return Set(records.map(\.localIdentifier))
    }

    /// Id ASET SERVER yang salinan perangkatnya diketahui.
    ///
    /// Pasangan dari `uploadedLocalIdentifiers`, dibaca dari arah sebaliknya:
    /// yang satu menjawab "petak lokal ini perlu ditampilkan?", yang ini
    /// menjawab "petak server ini juga ada di perangkat?".
    func uploadedServerAssetIDs() -> Set<String> {
        let descriptor = FetchDescriptor<BackupRecord>(
            predicate: #Predicate { $0.localIdentifier != "" })
        let records = (try? modelContext.fetch(descriptor)) ?? []
        return Set(records.map(\.assetId))
    }

    /// Pasangan lengkapnya: `localIdentifier` → id aset server.
    ///
    /// Dua kerabatnya di atas masing-masing hanya mengembalikan satu sisi, dan
    /// itu cukup untuk menjawab "sudah ada?". Yang ini diperlukan saat sisi
    /// SEBERANGNYA yang dibutuhkan — menyusun aset server ke dalam album
    /// berdasarkan album perangkat asalnya.
    func serverAssetIDsByLocalIdentifier() -> [String: String] {
        let descriptor = FetchDescriptor<BackupRecord>(
            predicate: #Predicate { $0.localIdentifier != "" })
        let records = (try? modelContext.fetch(descriptor)) ?? []
        return Dictionary(records.map { ($0.localIdentifier, $0.assetId) },
                          uniquingKeysWith: { first, _ in first })
    }

    /// `PHAsset.localIdentifier` milik sebuah aset server, kalau salinan
    /// perangkatnya diketahui.
    func localIdentifier(forServerAsset id: String) -> String? {
        var descriptor = FetchDescriptor<BackupRecord>(
            predicate: #Predicate { $0.assetId == id && $0.localIdentifier != "" })
        descriptor.fetchLimit = 1
        return try? modelContext.fetch(descriptor).first?.localIdentifier
    }

    /// Melupakan salinan perangkat, TANPA melupakan unggahannya.
    ///
    /// Dipakai setelah foto dihapus dari pustaka perangkat: asetnya tetap ada di
    /// server, jadi catatannya harus bertahan supaya tidak terunggah dua kali.
    /// Yang tidak berlaku lagi hanya kaitannya ke berkas yang sudah tidak ada.
    func unlinkDeviceAsset(localIdentifier: String) throws {
        guard startupState.isPersistentStoreAvailable else {
            throw LocalDatabaseMaintenanceError.persistentStoreUnavailable
        }
        let descriptor = FetchDescriptor<BackupRecord>(
            predicate: #Predicate { $0.localIdentifier == localIdentifier })
        for record in (try? modelContext.fetch(descriptor)) ?? [] {
            record.localIdentifier = ""
        }
        try modelContext.save()
        refreshBackupRecordJournal()
    }

    // MARK: - Checksum foto perangkat

    /// Checksum yang sudah pernah dihitung, dipetakan dari `localIdentifier`.
    func storedChecksums() -> [String: String] {
        let records = (try? modelContext.fetch(FetchDescriptor<LocalAssetChecksum>())) ?? []
        return Dictionary(records.map { ($0.localIdentifier, $0.checksum) },
                          uniquingKeysWith: { first, _ in first })
    }

    func storeChecksums(_ entries: [(localIdentifier: String, checksum: String)]) throws {
        guard !entries.isEmpty else { return }
        for entry in entries {
            modelContext.insert(LocalAssetChecksum(
                localIdentifier: entry.localIdentifier, checksum: entry.checksum))
        }
        try modelContext.save()
    }

    /// Menandai satu foto perangkat sebagai "sudah ada di server".
    ///
    /// Memakai `BackupRecord` yang sama dengan jalur unggah, bukan tabel baru:
    /// yang dicatat memang hal yang sama — foto perangkat ini berpasangan dengan
    /// aset server itu — dan yang membedakan cuma siapa yang mengunggahnya.
    func linkDeviceAsset(localIdentifier: String, to serverAssetID: String) throws {
        guard startupState.isPersistentStoreAvailable else {
            throw LocalDatabaseMaintenanceError.persistentStoreUnavailable
        }
        let descriptor = FetchDescriptor<BackupRecord>(
            predicate: #Predicate { $0.localIdentifier == localIdentifier })
        // Fetch yang GAGAL menghasilkan nil, dan nil tidak boleh dibaca sebagai
        // "belum ada" — itu menyisipkan catatan kembar setiap kali.
        guard let existing = try? modelContext.fetch(descriptor), existing.isEmpty
        else { return }

        modelContext.insert(BackupRecord(
            id: UUID().uuidString,
            assetId: serverAssetID,
            deviceAssetId: "",
            localIdentifier: localIdentifier))
        try modelContext.save()
        refreshBackupRecordJournal()
    }

    func insertBackupRecord(_ record: BackupRecord) throws {
        guard startupState.isPersistentStoreAvailable else {
            throw LocalDatabaseMaintenanceError.persistentStoreUnavailable
        }
        modelContext.insert(record)
        try modelContext.save()
        refreshBackupRecordJournal()
    }

    /// Menulis hasil upload secara idempotent. Background URLSession dapat
    /// menyampaikan ulang completion setelah reconnect, dan server dapat sudah
    /// menerima byte sebelum koneksi putus. Satu localIdentifier tetap harus
    /// menghasilkan satu mapping, bukan satu record setiap callback.
    func upsertBackupRecord(
        assetID: String,
        checksum: String,
        localIdentifier: String
    ) throws {
        guard startupState.isPersistentStoreAvailable else {
            throw LocalDatabaseMaintenanceError.persistentStoreUnavailable
        }
        let descriptor = FetchDescriptor<BackupRecord>(
            predicate: #Predicate { $0.localIdentifier == localIdentifier })
        if let existing = try modelContext.fetch(descriptor).first {
            existing.assetId = assetID
            existing.deviceAssetId = checksum
        } else {
            modelContext.insert(BackupRecord(
                id: UUID().uuidString,
                assetId: assetID,
                deviceAssetId: checksum,
                localIdentifier: localIdentifier))
        }
        try modelContext.save()
        refreshBackupRecordJournal()
    }

    func getSyncState() -> SyncState {
        if let state = try? modelContext.fetch(FetchDescriptor<SyncState>()).first {
            return state
        }
        let state = SyncState()
        modelContext.insert(state)
        try? modelContext.save()
        return state
    }

    func updateSyncState(_ state: SyncState) throws {
        try modelContext.save()
    }
}
