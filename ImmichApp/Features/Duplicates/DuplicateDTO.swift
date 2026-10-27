import Foundation

/// Satu kelompok foto yang dinilai mirip oleh Immich.
///
/// `suggestedKeepAssetIds` baru ditambahkan pada kontrak API v3. Server v2
/// tetap didukung dengan menganggap rekomendasinya kosong; layar akan memilih
/// aset terbesar sebagai titik awal supaya pengguna tidak memulai dari keadaan
/// yang akan membuang semuanya.
struct DuplicateGroupDTO: Decodable, Identifiable {
    let duplicateId: String
    let assets: [AssetResponseDTO]
    let suggestedKeepAssetIds: [String]

    var id: String { duplicateId }

    private enum CodingKeys: String, CodingKey {
        case duplicateId, assets, suggestedKeepAssetIds
    }

    init(duplicateId: String, assets: [AssetResponseDTO], suggestedKeepAssetIds: [String] = []) {
        self.duplicateId = duplicateId
        self.assets = assets
        self.suggestedKeepAssetIds = suggestedKeepAssetIds
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        duplicateId = try container.decode(String.self, forKey: .duplicateId)
        assets = try container.decode([AssetResponseDTO].self, forKey: .assets)
        suggestedKeepAssetIds = try container.decodeIfPresent(
            [String].self, forKey: .suggestedKeepAssetIds) ?? []
    }

    /// Rekomendasi server menang. Pada server lama, file terbesar menjadi
    /// fallback yang masuk akal dan tetap bisa diubah sebelum diselesaikan.
    var initialKeepAssetIDs: Set<String> {
        let available = Set(assets.map(\.id))
        let suggested = Set(suggestedKeepAssetIds).intersection(available)
        if !suggested.isEmpty { return suggested }

        guard let fallback = assets.max(by: {
            ($0.exifInfo?.fileSizeInByte ?? 0) < ($1.exifInfo?.fileSizeInByte ?? 0)
        }) else { return [] }
        return [fallback.id]
    }
}

struct DuplicateResolveGroupDTO: Encodable {
    let duplicateId: String
    let keepAssetIds: [String]
    let trashAssetIds: [String]
}

struct DuplicateResolveRequestDTO: Encodable {
    let groups: [DuplicateResolveGroupDTO]
}
