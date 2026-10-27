import Foundation
import SwiftData

/// Schema pertama yang pernah dikirim aplikasi (commit `e0db687`).
///
/// Tipe historis sengaja disimpan apa adanya. Mengubahnya setelah rilis akan
/// mengubah model checksum SwiftData dan membuat store lama tidak lagi dapat
/// dikenali sebagai sumber migrasi.
enum LocalStoreSchemaV1: VersionedSchema {
    static let versionIdentifier = Schema.Version(1, 0, 0)
    static var models: [any PersistentModel.Type] {
        [CachedAsset.self, BackupRecord.self, SyncState.self]
    }

    @Model
    final class CachedAsset {
        @Attribute(.unique) var id: String
        var assetId: String
        var type: String
        var thumbnailPath: String?
        var previewPath: String?
        var isFavorite: Bool
        var isArchived: Bool
        var createdAt: Date
        var updatedAt: Date
        var exifData: String?
        var ratio: Double?

        init(
            id: String,
            assetId: String,
            type: String,
            thumbnailPath: String? = nil,
            previewPath: String? = nil,
            isFavorite: Bool = false,
            isArchived: Bool = false,
            createdAt: Date = Date(),
            updatedAt: Date = Date(),
            exifData: String? = nil,
            ratio: Double? = nil
        ) {
            self.id = id
            self.assetId = assetId
            self.type = type
            self.thumbnailPath = thumbnailPath
            self.previewPath = previewPath
            self.isFavorite = isFavorite
            self.isArchived = isArchived
            self.createdAt = createdAt
            self.updatedAt = updatedAt
            self.exifData = exifData
            self.ratio = ratio
        }
    }

    @Model
    final class BackupRecord {
        @Attribute(.unique) var id: String
        var assetId: String
        var deviceAssetId: String
        var createdAt: Date

        init(
            id: String,
            assetId: String,
            deviceAssetId: String,
            createdAt: Date = Date()
        ) {
            self.id = id
            self.assetId = assetId
            self.deviceAssetId = deviceAssetId
            self.createdAt = createdAt
        }
    }

    @Model
    final class SyncState {
        @Attribute(.unique) var id: String = "sync-state"
        var lastFullSyncAt: Date?
        var lastDeltaSyncAt: Date?
        var ackToken: String?
        var totalAssets: Int = 0

        init() {}
    }
}

/// Schema yang menambahkan metadata grid, durasi, thumbhash, dan pasangan Live
/// Photo tetapi belum menyimpan hubungan PhotoKit pada `BackupRecord`.
enum LocalStoreSchemaV2: VersionedSchema {
    static let versionIdentifier = Schema.Version(2, 0, 0)
    static var models: [any PersistentModel.Type] {
        [CachedAsset.self, BackupRecord.self, SyncState.self]
    }

    @Model
    final class CachedAsset {
        @Attribute(.unique) var id: String
        var assetId: String
        var type: String
        var thumbnailPath: String?
        var previewPath: String?
        var isFavorite: Bool
        var isArchived: Bool
        var createdAt: Date
        var updatedAt: Date
        var exifData: String?
        var ratio: Double?
        var thumbhash: String?
        var monthKey: String = ""
        var duration: Double?
        var livePhotoVideoId: String?

        init(
            id: String,
            assetId: String,
            type: String,
            thumbnailPath: String? = nil,
            previewPath: String? = nil,
            isFavorite: Bool = false,
            isArchived: Bool = false,
            duration: Double? = nil,
            livePhotoVideoId: String? = nil,
            createdAt: Date = Date(),
            updatedAt: Date = Date(),
            exifData: String? = nil,
            ratio: Double? = nil,
            thumbhash: String? = nil,
            monthKey: String = ""
        ) {
            self.id = id
            self.assetId = assetId
            self.type = type
            self.thumbnailPath = thumbnailPath
            self.previewPath = previewPath
            self.isFavorite = isFavorite
            self.isArchived = isArchived
            self.duration = duration
            self.livePhotoVideoId = livePhotoVideoId
            self.createdAt = createdAt
            self.updatedAt = updatedAt
            self.exifData = exifData
            self.ratio = ratio
            self.thumbhash = thumbhash
            self.monthKey = monthKey
        }
    }

    @Model
    final class BackupRecord {
        @Attribute(.unique) var id: String
        var assetId: String
        var deviceAssetId: String
        var createdAt: Date

        init(
            id: String,
            assetId: String,
            deviceAssetId: String,
            createdAt: Date = Date()
        ) {
            self.id = id
            self.assetId = assetId
            self.deviceAssetId = deviceAssetId
            self.createdAt = createdAt
        }
    }

    @Model
    final class SyncState {
        @Attribute(.unique) var id: String = "sync-state"
        var lastFullSyncAt: Date?
        var lastDeltaSyncAt: Date?
        var ackToken: String?
        var totalAssets: Int = 0

        init() {}
    }
}

/// Schema V3. Modelnya tetap top-level supaya seluruh call
/// site yang sudah ada tidak perlu mengenal versi penyimpanan.
enum LocalStoreSchemaV3: VersionedSchema {
    static let versionIdentifier = Schema.Version(3, 0, 0)
    static var models: [any PersistentModel.Type] {
        [CachedAsset.self, BackupRecord.self, SyncState.self, LocalAssetChecksum.self]
    }
}

enum LocalStoreSchemaV4: VersionedSchema {
    static let versionIdentifier = Schema.Version(4, 0, 0)
    static var models: [any PersistentModel.Type] {
        [CachedAsset.self, BackupRecord.self, SyncState.self, LocalAssetChecksum.self,
         PrivateAssetRecord.self]
    }
}

enum LocalStoreMigrationPlan: SchemaMigrationPlan {
    static var schemas: [any VersionedSchema.Type] {
        [LocalStoreSchemaV1.self, LocalStoreSchemaV2.self, LocalStoreSchemaV3.self,
         LocalStoreSchemaV4.self]
    }

    static var stages: [MigrationStage] {
        [
            .lightweight(fromVersion: LocalStoreSchemaV1.self, toVersion: LocalStoreSchemaV2.self),
            .lightweight(fromVersion: LocalStoreSchemaV2.self, toVersion: LocalStoreSchemaV3.self),
            .lightweight(fromVersion: LocalStoreSchemaV3.self, toVersion: LocalStoreSchemaV4.self),
        ]
    }
}
