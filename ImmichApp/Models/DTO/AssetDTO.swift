import Foundation

/// `Codable`, bukan `Decodable` saja.
///
/// Detail yang sudah pernah dimuat dipotret ke disk supaya panel info tetap
/// berisi saat offline — lihat `LocalSnapshot`. Sisi encode-nya DISINTESIS:
/// `CodingKeys` di bawah sudah memuat seluruh properti tersimpan, jadi tidak ada
/// yang hilang di perjalanan pulang.
///
/// Yang perlu diperhatikan cuma `duration`. API lama dapat mengirim teks jam,
/// sedangkan kontrak API baru mengirim angka milidetik. Snapshot offline milik
/// aplikasi tetap menyimpannya sebagai angka detik. `userInfo` pada decoder
/// membedakan kedua sumber itu supaya pembaruan kontrak API tidak merusak
/// snapshot yang sudah ada di perangkat.
struct AssetResponseDTO: Codable, Identifiable {
    let id: String
    let type: String
    let originalFileName: String
    let fileCreatedAt: Date
    var isFavorite: Bool
    var isArchived: Bool
    /// Missing only in older API responses and existing offline snapshots.
    var visibility: String?
    let isTrashed: Bool
    /// Durasi video dalam detik (null/0 untuk foto).
    ///
    /// Di dalam aplikasi nilainya selalu detik. Decoder menormalisasi string
    /// jam lama maupun angka milidetik dari API sebelum nilai ini dipakai UI.
    let duration: Double?
    let thumbhash: String?
    let localDateTime: Date
    /// var supaya deskripsi bisa diperbarui lokal setelah disimpan ke server.
    var exifInfo: ExifDTO?
    let people: [PersonDTO]?
    /// Id aset video pasangan sebuah Live Photo; nil untuk foto biasa.
    let livePhotoVideoId: String?

    var isTimelineVisible: Bool {
        !isArchived && !isTrashed && (visibility == nil || visibility == "timeline")
    }

    var isVideo: Bool { type == "VIDEO" }
    var isLivePhoto: Bool { livePhotoVideoId != nil }

    var durationText: String? {
        guard let duration, duration > 0 else { return nil }
        let totalSeconds = Int(duration.rounded())
        return String(format: "%d:%02d", totalSeconds / 60, totalSeconds % 60)
    }

    private enum CodingKeys: String, CodingKey {
        case id, type, originalFileName, fileCreatedAt, isFavorite, isArchived, visibility
        case isTrashed, duration, thumbhash, localDateTime, exifInfo, people
        case livePhotoVideoId
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        type = try c.decode(String.self, forKey: .type)
        originalFileName = try c.decode(String.self, forKey: .originalFileName)
        fileCreatedAt = try c.decode(Date.self, forKey: .fileCreatedAt)
        isFavorite = try c.decode(Bool.self, forKey: .isFavorite)
        isArchived = try c.decode(Bool.self, forKey: .isArchived)
        visibility = try c.decodeIfPresent(String.self, forKey: .visibility)
        isTrashed = try c.decode(Bool.self, forKey: .isTrashed)
        thumbhash = try c.decodeIfPresent(String.self, forKey: .thumbhash)
        localDateTime = try c.decode(Date.self, forKey: .localDateTime)
        exifInfo = try c.decodeIfPresent(ExifDTO.self, forKey: .exifInfo)
        people = try c.decodeIfPresent([PersonDTO].self, forKey: .people)
        livePhotoVideoId = try c.decodeIfPresent(String.self, forKey: .livePhotoVideoId)

        // Terima string "H:MM:SS.sss" maupun angka, supaya perubahan format di
        // sisi server tidak lagi menjatuhkan seluruh decoding. JSON API Immich
        // menandai angka sebagai milidetik; decoder snapshot tidak memasang
        // tanda itu karena snapshot Codable lama memang menyimpan detik.
        if let text = try? c.decodeIfPresent(String.self, forKey: .duration) {
            duration = ClockDuration.seconds(fromClock: text)
        } else {
            let numeric = try c.decodeIfPresent(Double.self, forKey: .duration)
            if decoder.userInfo[.immichAssetDurationIsMilliseconds] as? Bool == true {
                duration = numeric.map { $0 / 1_000 }
            } else {
                duration = numeric
            }
        }
    }

}

extension CodingUserInfoKey {
    /// Hanya dipasang oleh decoder respons API. Decoder snapshot lokal sengaja
    /// tidak memasangnya karena snapshot versi lama menyimpan angka detik.
    static let immichAssetDurationIsMilliseconds = CodingUserInfoKey(
        rawValue: "xyz.0xmwehehe.ImmichApp.assetDurationMilliseconds")!
}

/// Init nilai, DI EXTENSION — bukan di dalam struct.
///
/// `AssetResponseDTO` punya `init(from:)` sendiri, dan mendeklarasikan init apa
/// pun di dalam badan struct membuat Swift berhenti membangkitkan memberwise
/// init. Menaruhnya di extension mengembalikan keduanya.
extension AssetResponseDTO {
    init(
        id: String,
        type: String,
        originalFileName: String,
        fileCreatedAt: Date,
        isFavorite: Bool,
        isArchived: Bool,
        isTrashed: Bool,
        duration: Double?,
        thumbhash: String?,
        localDateTime: Date,
        exifInfo: ExifDTO?,
        people: [PersonDTO]?,
        livePhotoVideoId: String? = nil,
        visibility: String? = nil
    ) {
        self.id = id
        self.type = type
        self.originalFileName = originalFileName
        self.fileCreatedAt = fileCreatedAt
        self.isFavorite = isFavorite
        self.isArchived = isArchived
        self.visibility = visibility
        self.isTrashed = isTrashed
        self.duration = duration
        self.thumbhash = thumbhash
        self.localDateTime = localDateTime
        self.exifInfo = exifInfo
        self.people = people
        self.livePhotoVideoId = livePhotoVideoId
    }
}

/// `Codable` karena ikut terbawa potret `AssetResponseDTO`; seluruh fieldnya
/// primitif, jadi sintesisnya cukup.
struct ExifDTO: Codable {
    let make: String?
    let model: String?
    let exifImageWidth: Int?
    let exifImageHeight: Int?
    /// Nilai EXIF orientation disimpan Immich sebagai string numerik.
    /// Orientation 5...8 berarti dimensi tampilan harus ditukar.
    let orientation: String?
    let fileSizeInByte: Int?
    let dateTimeOriginal: Date?
    let latitude: Double?
    let longitude: Double?
    let city: String?
    let state: String?
    let country: String?
    let lensModel: String?
    let fNumber: Double?
    let focalLength: Double?
    let iso: Int?
    let exposureTime: String?
    /// Immich menyimpan keterangan foto di `exifInfo.description`.
    var description: String?
}
