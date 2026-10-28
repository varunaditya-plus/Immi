import Foundation

struct AlbumResponseDTO: Decodable, Identifiable, Hashable {
    let id: String
    /// var supaya hasil ganti nama bisa ditambal di tempat, tanpa memuat ulang
    /// seluruh daftar album.
    var albumName: String
    /// var dengan alasan yang sama seperti `albumName` — hasil sunting ditambal
    /// di tempat supaya langsung terlihat di sampul.
    var description: String?
    /// `var` supaya layar induk dapat menambal jumlah dan cover segera setelah
    /// isi album berubah, tanpa menunggu request daftar album selesai.
    var assetCount: Int
    var albumThumbnailAssetId: String?
    let shared: Bool
    let createdAt: Date
    let assets: [AssetResponseDTO]?

    // Semua opsional supaya decoding tetap jalan di server versi lama yang
    // belum mengirim field-field ini. Dipakai oleh menu urutkan.
    //
    // Ditulis `var ... = nil`, bukan `let`, dengan dua alasan sekaligus:
    // memberwise init jadi punya nilai bawaan sehingga pemanggil lama tidak
    // perlu diubah, dan sintesis Decodable tetap membacanya. `let` dengan nilai
    // awal justru dilewati saat decoding karena sudah terisi dan tak bisa
    // diubah lagi.
    /// Terakhir album diubah (nama, deskripsi, isi).
    var updatedAt: Date? = nil
    /// Tanggal foto TERTUA di album.
    var startDate: Date? = nil
    /// Tanggal foto TERBARU di album.
    var endDate: Date? = nil
    /// v2 supplies ownerId; v3 identifies the owner in albumUsers.
    var ownerId: String? = nil

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    static func == (lhs: AlbumResponseDTO, rhs: AlbumResponseDTO) -> Bool {
        lhs.id == rhs.id
    }
}

extension AlbumResponseDTO {
    private enum CodingKeys: String, CodingKey {
        case id, albumName, description, assetCount, albumThumbnailAssetId
        case shared, createdAt, assets, updatedAt, startDate, endDate
        case ownerId, albumUsers
    }

    private struct AlbumUserIdentity: Decodable {
        struct UserIdentity: Decodable {
            let id: String
        }

        let user: UserIdentity
        let role: String
    }

    /// Respons daftar dan detail album memuat seluruh field, tetapi beberapa
    /// versi server mengembalikan representasi yang lebih ringkas tepat setelah
    /// `POST /albums`. Album sudah tersimpan pada saat respons 2xx diterima;
    /// mewajibkan field presentasional seperti `shared` dan `assetCount` membuat
    /// client melaporkan "gagal" untuk operasi yang sebenarnya berhasil.
    ///
    /// Identitas dan nama tetap wajib. Field lain mendapat nilai aman sampai
    /// refresh/detail berikutnya membawa representasi lengkap dari server.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        albumName = try container.decode(String.self, forKey: .albumName)
        description = try container.decodeIfPresent(String.self, forKey: .description)
        assetCount = try container.decodeIfPresent(Int.self, forKey: .assetCount) ?? 0
        albumThumbnailAssetId = try container.decodeIfPresent(
            String.self, forKey: .albumThumbnailAssetId)
        shared = try container.decodeIfPresent(Bool.self, forKey: .shared) ?? false
        ownerId = try container.decodeIfPresent(String.self, forKey: .ownerId)
        if ownerId == nil {
            let albumUsers = try container.decodeIfPresent([AlbumUserIdentity].self, forKey: .albumUsers)
            ownerId = albumUsers?.first(where: { $0.role == "owner" })?.user.id
        }

        updatedAt = try? container.decode(Date.self, forKey: .updatedAt)
        createdAt = (try? container.decode(Date.self, forKey: .createdAt))
            ?? updatedAt
            ?? Date()
        startDate = try? container.decode(Date.self, forKey: .startDate)
        endDate = try? container.decode(Date.self, forKey: .endDate)
        // Daftar album tidak membutuhkan aset tertanam. Kalau satu server lama
        // mengirim bentuk aset yang sudah berubah, metadata albumnya tetap sah
        // dan detail aset akan dimuat lewat jalurnya sendiri.
        assets = try? container.decode([AssetResponseDTO].self, forKey: .assets)
    }
}

/// PATCH /albums/{id}. Optional berlapis pada description mengikuti kontrak
/// nullable v3: nil berarti field tidak dikirim, `.some(nil)` berarti dihapus.
struct AlbumUpdateDTO: Encodable {
    let albumName: String?
    let description: String??
}
