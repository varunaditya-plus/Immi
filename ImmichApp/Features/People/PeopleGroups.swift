import CryptoKit
import Foundation
import Observation

struct PeopleGroup: Codable, Identifiable, Equatable, Sendable {
    let id: String
    var name: String
    var personIDs: [String]
    var keyPhotoID: String?

    func isAvailable(in people: [PersonDTO]) -> Bool {
        let available = Set(people.filter { !$0.isHidden }.map(\.id))
        return !personIDs.isEmpty && Set(personIDs).isSubset(of: available)
    }

    func title(in people: [PersonDTO]) -> String {
        guard isAvailable(in: people) else { return String(localized: "Group Unavailable") }
        if !name.isEmpty { return name }
        let byID = Dictionary(people.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return personIDs.compactMap { byID[$0] }.map {
            $0.name.isEmpty ? String(localized: "Unnamed Person") : $0.name
        }.formatted(.list(type: .and))
    }
}

@MainActor
@Observable
final class PeopleGroupsStore {
    private var savedGroups: [PeopleGroup]
    private let generation = LocalSnapshot.generation
    private let defaults: UserDefaults
    private let key: String?

    var isCurrent: Bool { generation == LocalSnapshot.generation }
    var groups: [PeopleGroup] { isCurrent ? savedGroups : [] }

    init(owner: BackupQueueOwner?, defaults: UserDefaults = .standard) {
        self.defaults = defaults
        key = owner.map {
            let identity = "\($0.server)\n\($0.userID)"
            let digest = SHA256.hash(data: Data(identity.utf8)).map { String(format: "%02x", $0) }.joined()
            return "people.groups.v1.\(digest)"
        }
        savedGroups = key.flatMap { defaults.data(forKey: $0) }
            .flatMap { try? JSONDecoder().decode([PeopleGroup].self, from: $0) } ?? []
    }

    func group(_ id: String) -> PeopleGroup? { groups.first { $0.id == id } }

    @discardableResult
    func save(id: String? = nil, name: String, personIDs: [String], keyPhotoID: String? = nil,
              expectedPeople: [String]? = nil) -> PeopleGroup? {
        let ids = unique(personIDs.filter { !$0.isEmpty })
        guard ids.count >= (id == nil ? 2 : 1) else { return nil }
        var result: PeopleGroup?
        change { state in
            let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
            if let id {
                guard let index = state.firstIndex(where: { $0.id == id }) else { return }
                if let expectedPeople, Set(state[index].personIDs) != Set(expectedPeople) { return }
                state[index] = PeopleGroup(id: id, name: name, personIDs: ids, keyPhotoID: keyPhotoID)
                result = state[index]
            } else {
                let group = PeopleGroup(id: UUID().uuidString, name: name, personIDs: ids, keyPhotoID: keyPhotoID)
                state.append(group)
                result = group
            }
        }
        return result
    }

    @discardableResult
    func setKeyPhoto(_ assetID: String?, in groupID: String, expectedPeople: [String]) -> Bool {
        var accepted = false
        change { state in
            guard let index = state.firstIndex(where: { $0.id == groupID }),
                  Set(state[index].personIDs) == Set(expectedPeople) else { return }
            state[index].keyPhotoID = assetID
            accepted = true
        }
        return accepted
    }

    func remove(_ id: String) { change { $0.removeAll { $0.id == id } } }

    func remapMergedPeople(_ acceptedSourceIDs: Set<String>, into targetID: String) {
        let sources = acceptedSourceIDs.subtracting([targetID])
        guard !sources.isEmpty, !targetID.isEmpty else { return }
        change { groups in
            for index in groups.indices {
                let people = unique(groups[index].personIDs.map { sources.contains($0) ? targetID : $0 })
                guard people != groups[index].personIDs else { continue }
                groups[index].personIDs = people
                groups[index].keyPhotoID = nil
            }
        }
    }

    func setOrder(_ ids: [String]) {
        let ids = unique(ids)
        change { state in
            let byID = Dictionary(state.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            let ordered = ids.compactMap { byID[$0] }
            let included = Set(ordered.map(\.id))
            state = ordered + state.filter { !included.contains($0.id) }
        }
    }

    @discardableResult
    func move(_ id: String, to targetID: String) -> Bool {
        var accepted = false
        change { state in
            guard id != targetID, let source = state.firstIndex(where: { $0.id == id }),
                  let target = state.firstIndex(where: { $0.id == targetID }) else { return }
            let group = state.remove(at: source)
            state.insert(group, at: min(target, state.count))
            accepted = true
        }
        return accepted
    }

    private func unique(_ ids: [String]) -> [String] {
        var seen = Set<String>()
        return ids.filter { seen.insert($0).inserted }
    }

    private func change(_ operation: (inout [PeopleGroup]) -> Void) {
        guard isCurrent else { return }
        // Multiple People screens can own stores for the same account.
        var updated = key.flatMap { defaults.data(forKey: $0) }
            .flatMap { try? JSONDecoder().decode([PeopleGroup].self, from: $0) } ?? savedGroups
        let previous = updated
        operation(&updated)
        if updated != savedGroups { savedGroups = updated }
        guard updated != previous, let key, let data = try? JSONEncoder().encode(updated) else { return }
        defaults.set(data, forKey: key)
    }
}
