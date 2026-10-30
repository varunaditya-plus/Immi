import Foundation

enum PeopleGroupMembership {
    @MainActor
    static func revisions(for personIDs: [String]) -> [UInt64] {
        Set(personIDs).sorted().map { LocalSnapshot.invalidationRevision(for: LocalSnapshot.Key.person($0)) }
    }

    static func includes(_ asset: AssetResponseDTO, people: Set<String>, includingOtherPeople: Bool) throws -> Bool {
        guard let identities = asset.people else {
            throw APIError.server(status: 200,
                message: String(localized: "The server did not provide people information for group photos."))
        }
        let actual = Set(identities.map(\.id))
        guard people.isSubset(of: actual),
              !identities.contains(where: { people.contains($0.id) && $0.isHidden }) else { return false }
        return includingOtherPeople || actual == people
    }
}

@MainActor
final class PeopleGroupRepository {
    private let repository: SearchRepository
    private let dataManager: SwiftDataManager
    private let generation = LocalSnapshot.generation

    init(repository: SearchRepository, dataManager: SwiftDataManager? = nil) {
        self.repository = repository
        self.dataManager = dataManager ?? .shared
    }

    func assets(personIDs: [String], includingOtherPeople: Bool) async throws -> [AssetLite] {
        let required = Set(personIDs.filter { !$0.isEmpty })
        guard !required.isEmpty else { return [] }
        guard generation == LocalSnapshot.generation else { throw CancellationError() }
        let revisions = PeopleGroupMembership.revisions(for: Array(required))
        var request = SearchRequestDTO(order: "desc", personIds: required.sorted(), size: 100)
        request.withPeople = true
        let fetched = try await repository.allMetadata(request)
        try Task.checkCancellation()
        guard generation == LocalSnapshot.generation,
              revisions == PeopleGroupMembership.revisions(for: Array(required)) else { throw CancellationError() }
        let admitted = try fetched.filter { asset in
            guard asset.isTimelineVisible else { return false }
            return try PeopleGroupMembership.includes(asset, people: required, includingOtherPeople: includingOtherPeople)
        }.map(AssetLite.init)
        return AssetVisibilityPolicy(scope: .timeline, dataManager: dataManager).filter(admitted).sorted {
            $0.createdAt == $1.createdAt ? $0.id < $1.id : $0.createdAt > $1.createdAt
        }
    }
}
