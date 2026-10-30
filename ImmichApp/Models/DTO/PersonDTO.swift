import Foundation

/// `Encodable` ada DI SINI, bukan di `LocalSnapshot` yang memakainya: Swift
/// hanya mensintesisnya pada deklarasi tipe atau extension di berkas yang sama.
struct PersonDTO: Codable, Identifiable, Hashable, Sendable {
    let id: String
    var name: String
    let birthDate: Date?
    var thumbnailPath: String?
    var isHidden: Bool
    var isFavorite: Bool? = nil
    var updatedAt: Date? = nil

    var displayName: String { name.isEmpty ? String(localized: "Name This Person") : name }
}

struct PersonUpdate: Sendable {
    enum Field: Hashable, Sendable { case name, hidden, favorite, thumbnail }
    let person: PersonDTO
    let fields: Set<Field>

    func applying(to existing: PersonDTO) -> PersonDTO {
        guard existing.id == person.id else { return existing }
        var updated = existing
        if fields.contains(.name) { updated.name = person.name }
        if fields.contains(.hidden) { updated.isHidden = person.isHidden }
        if fields.contains(.favorite) { updated.isFavorite = person.isFavorite }
        if fields.contains(.thumbnail) {
            updated.thumbnailPath = person.thumbnailPath
            updated.updatedAt = person.updatedAt
        }
        return updated
    }
}

struct PeopleMergeResult: Sendable {
    let acceptedIDs: Set<String>
    let failedIDs: Set<String>
}

/// Kontrak bulk update stabil Immich (`PUT /people`).
struct PeopleUpdateRequestDTO: Encodable {
    struct Item: Encodable {
        let id: String
        var name: String? = nil
        var isHidden: Bool? = nil
        var isFavorite: Bool? = nil
        var featureFaceAssetId: String? = nil
    }

    let people: [Item]
}

/// Respons per item dari operasi bulk Immich.
struct BulkIDResponseDTO: Decodable {
    let id: String
    let success: Bool
    let error: String?
    let errorMessage: String?
}
