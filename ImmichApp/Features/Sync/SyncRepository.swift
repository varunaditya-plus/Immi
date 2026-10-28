import Foundation

class SyncRepository {
    private let api: APIClient
    private let dataManager: SwiftDataManager

    init(api: APIClient, dataManager: SwiftDataManager) {
        self.api = api
        self.dataManager = dataManager
    }

    @MainActor
    func fullSync() async throws {
        try await sync(reset: true)
    }

    @MainActor
    func deltaSync() async throws {
        try await sync(reset: false)
    }

    /// Delta batches become visible as they arrive. Full snapshots stay in a
    /// disposable file until the server confirms that the stream is complete.
    @MainActor
    private func sync(reset: Bool, isRetryAfterReset: Bool = false) async throws {
        let context = api.session.snapshot
        let visibilityRevision = dataManager.visibilityMutationRevision
        let assetRevision = dataManager.assetMutationRevision
        var staging = reset ? try FullSyncStaging() : nil
        try api.checkCurrent(context)
        try checkVisibility(visibilityRevision)
        let outcome = try await streamAndApply(reset: reset, staging: staging,
            context: context, visibilityRevision: visibilityRevision)
        try api.checkCurrent(context)
        try checkVisibility(visibilityRevision)

        if outcome.serverRequestedReset {
            guard !isRetryAfterReset else {
                throw APIError.server(status: 409, message: "Server terus meminta sync reset")
            }
            staging = nil
            return try await sync(reset: true, isRetryAfterReset: true)
        }

        if let staging {
            guard outcome.completed else {
                throw APIError.server(status: 502, message: "Sync berakhir sebelum snapshot lengkap")
            }
            guard assetRevision == dataManager.assetMutationRevision else {
                throw CancellationError()
            }
            try dataManager.replaceSyncCache(with: staging,
                expectedVisibilityRevision: visibilityRevision,
                expectedAssetRevision: assetRevision)
        }

        // Acknowledge only after the complete snapshot is durable. A failed ack
        // can be retried without discarding the usable cache or its old checkpoint.
        try api.checkCurrent(context)
        try checkVisibility(visibilityRevision)
        if !outcome.latestAcks.isEmpty {
            try await api.sendVoid(.json("/sync/ack", method: .post,
                                         body: SyncAckSetDTO(acks: Array(outcome.latestAcks.values))))
        }

        try api.checkCurrent(context)
        try checkVisibility(visibilityRevision)
        let state = dataManager.getSyncState()
        let now = Date()
        if reset || state.lastFullSyncAt == nil { state.lastFullSyncAt = now }
        state.lastDeltaSyncAt = now
        state.totalAssets = dataManager.cachedAssetCount()
        try dataManager.updateSyncState(state)
    }

    /// Yang tersisa setelah seluruh stream lewat — sengaja TIDAK berisi asetnya.
    private struct StreamOutcome {
        /// Ack terakhir per tipe entitas (format "type|updateId[|extraId]").
        var latestAcks: [String: String] = [:]
        var serverRequestedReset = false
        var completed = false
    }

    private static let chunkSize = 500

    @MainActor
    private func streamAndApply(reset: Bool, staging: FullSyncStaging?, context: SessionRequestContext, visibilityRevision: UUID) async throws -> StreamOutcome {
        // Immich v3 mempertahankan nama request AssetsV1 di enum, tetapi
        // handler server-nya sengaja selalu membalas 400 karena sudah
        // deprecated. Aplikasi sebelumnya tetap memintanya, lalu background
        // sync menelan error tersebut sehingga cache tampak sekadar tidak
        // berubah. Untuk sesi cold-start versi server belum tentu selesai
        // dipulihkan, jadi baca endpoint versi sebagai fallback.
        let serverMajor: Int
        if let compatibility = api.session.serverCompatibility {
            serverMajor = compatibility.version.major
        } else {
            serverMajor = try await api.session.serverVersion().major
        }

        try api.checkCurrent(context)
        try checkVisibility(visibilityRevision)
        let requestType = serverMajor >= 3 ? "AssetsV2" : "AssetsV1"
        var request = SyncStreamRequestDTO(types: [requestType])
        if reset { request.reset = true }

        var outcome = StreamOutcome()
        var upserts: [CachedAsset] = []
        var deletes: [String] = []
        var visibilityByID: [String: String] = [:]
        var stagedLineCount = 0

        let lines = try await api.streamLines(.json("/sync/stream", method: .post, body: request))

        for try await line in lines {
            try api.checkCurrent(context)
            try checkVisibility(visibilityRevision)
            guard !line.isEmpty, let data = line.data(using: .utf8) else { continue }
            let envelope = try JSONDecoder.immich.decode(SyncLineEnvelopeDTO.self, from: data)
            if staging != nil, outcome.completed {
                throw APIError.server(status: 502, message: "Sync mengirim data setelah snapshot lengkap")
            }

            switch envelope.type {
            case "AssetV1":
                let asset = try JSONDecoder.immich.decode(
                    SyncLineDataDTO<SyncAssetV1DTO>.self, from: data).data
                if asset.deletedAt != nil {
                    if let staging { try staging.appendDeletion(asset.id, permanently: false) }
                    else {
                        DeletedServerAssetRegistry.shared.record([asset.id], permanently: false)
                        deletes.append(asset.id)
                    }
                } else if let staging {
                    try staging.append(makeCachedAsset(asset), visibility: asset.visibility)
                } else {
                    DeletedServerAssetRegistry.shared.restore([asset.id])
                    upserts.append(makeCachedAsset(asset))
                    visibilityByID[asset.id] = asset.visibility
                }
            case "AssetV2":
                let asset = try JSONDecoder.immich.decode(
                    SyncLineDataDTO<SyncAssetV2DTO>.self, from: data).data
                if asset.deletedAt != nil {
                    if let staging { try staging.appendDeletion(asset.id, permanently: false) }
                    else {
                        DeletedServerAssetRegistry.shared.record([asset.id], permanently: false)
                        deletes.append(asset.id)
                    }
                } else if let staging {
                    try staging.append(makeCachedAsset(asset), visibility: asset.visibility)
                } else {
                    DeletedServerAssetRegistry.shared.restore([asset.id])
                    upserts.append(makeCachedAsset(asset))
                    visibilityByID[asset.id] = asset.visibility
                }
            case "AssetDeleteV1":
                let payload = try JSONDecoder.immich.decode(
                    SyncLineDataDTO<SyncAssetDeleteV1DTO>.self, from: data).data
                if let staging { try staging.appendDeletion(payload.assetId, permanently: true) }
                else {
                    DeletedServerAssetRegistry.shared.record([payload.assetId], permanently: true)
                    deletes.append(payload.assetId)
                }
            case "SyncCompleteV1":
                outcome.completed = true
            case "SyncResetV1":
                outcome.serverRequestedReset = true
                return outcome
            default:
                break // Other entity markers only carry acknowledgments.
            }

            if let ackType = envelope.ack.split(separator: "|").first {
                outcome.latestAcks[String(ackType)] = envelope.ack
            }

            if upserts.count >= Self.chunkSize || deletes.count >= Self.chunkSize {
                try await flush(&upserts, &deletes, &visibilityByID,
                    context: context, visibilityRevision: visibilityRevision)
            }
            if staging != nil {
                stagedLineCount += 1
                if stagedLineCount == Self.chunkSize {
                    stagedLineCount = 0
                    await Task.yield()
                }
            }
        }

        try await flush(&upserts, &deletes, &visibilityByID,
            context: context, visibilityRevision: visibilityRevision)
        return outcome
    }

    @MainActor
    private func flush(
        _ upserts: inout [CachedAsset],
        _ deletes: inout [String],
        _ visibilityByID: inout [String: String],
        context: SessionRequestContext,
        visibilityRevision: UUID
    ) async throws {
        try api.checkCurrent(context)
        try checkVisibility(visibilityRevision)
        guard !upserts.isEmpty || !deletes.isEmpty else { return }

        try dataManager.applySyncBatch(
            upserts: upserts,
            deletedIds: deletes,
            expectedVisibilityRevision: visibilityRevision,
            visibilityByID: visibilityByID)

        upserts.removeAll(keepingCapacity: true)
        deletes.removeAll(keepingCapacity: true)
        visibilityByID.removeAll(keepingCapacity: true)
        await Task.yield()
    }

    @MainActor
    private func checkVisibility(_ expectedRevision: UUID) throws {
        try Task.checkCancellation()
        guard expectedRevision == dataManager.visibilityMutationRevision else {
            throw CancellationError()
        }
    }

    @MainActor
    private func makeCachedAsset(_ dto: SyncAssetV1DTO) -> CachedAsset {
        makeCachedAsset(
            id: dto.id,
            type: dto.type,
            visibility: dto.visibility,
            isFavorite: dto.isFavorite,
            duration: ClockDuration.seconds(fromClock: dto.duration),
            livePhotoVideoId: dto.livePhotoVideoId,
            fileCreatedAt: dto.fileCreatedAt,
            localDateTime: dto.localDateTime,
            fileModifiedAt: dto.fileModifiedAt,
            width: dto.width,
            height: dto.height,
            thumbhash: dto.thumbhash)
    }

    @MainActor
    private func makeCachedAsset(_ dto: SyncAssetV2DTO) -> CachedAsset {
        makeCachedAsset(
            id: dto.id,
            type: dto.type,
            visibility: dto.visibility,
            isFavorite: dto.isFavorite,
            duration: dto.duration.map { Double($0) / 1_000 },
            livePhotoVideoId: dto.livePhotoVideoId,
            fileCreatedAt: dto.fileCreatedAt,
            localDateTime: dto.localDateTime,
            fileModifiedAt: dto.fileModifiedAt,
            width: dto.width,
            height: dto.height,
            thumbhash: dto.thumbhash)
    }

    @MainActor
    private func makeCachedAsset(
        id: String,
        type: String,
        visibility: String,
        isFavorite: Bool,
        duration: Double?,
        livePhotoVideoId: String?,
        fileCreatedAt: Date?,
        localDateTime: Date?,
        fileModifiedAt: Date?,
        width: Int?,
        height: Int?,
        thumbhash: String?
    ) -> CachedAsset {
        var ratio: Double?
        if let w = width, let h = height, w > 0, h > 0 {
            ratio = Double(w) / Double(h)
        }
        return CachedAsset(
            id: id,
            assetId: id,
            type: type,
            isFavorite: isFavorite,
            // Yang boleh tampil di linimasa HANYA `timeline`.
            //
            // Immich punya empat nilai visibility: `timeline`, `archive`,
            // `hidden`, dan `locked`. Sebelumnya cuma `archive` yang disaring,
            // jadi isi Locked Folder dan aset tersembunyi ikut masuk ke grid
            // utama. Membukanya berarti meminta `/assets/{id}` untuk sesuatu
            // yang memang tidak boleh dibaca sesi ini — dan itulah "Not found or
            // no asset.read access" yang muncul sebagai Action Failed.
            //
            // Nama fieldnya tetap `isArchived` karena artinya memang sudah itu
            // di sisi kita: "jangan tampilkan di linimasa". Layar Archived dan
            // Locked Folder tidak membacanya — keduanya bertanya langsung ke
            // endpoint pencarian dengan visibility masing-masing.
            isArchived: visibility != "timeline",
            duration: duration,
            livePhotoVideoId: livePhotoVideoId,
            createdAt: fileCreatedAt ?? localDateTime ?? Date(),
            updatedAt: fileModifiedAt ?? Date(),
            ratio: ratio,
            thumbhash: thumbhash
        )
    }
}
