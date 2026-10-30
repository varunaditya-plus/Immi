import CryptoKit
import Foundation
import Observation

enum PeopleSort: String, Codable, CaseIterable {
    case custom, name

    var title: String {
        switch self {
        case .custom: String(localized: "Sort by Custom Order")
        case .name: String(localized: "Sort by Name")
        }
    }
}

struct PeopleOrganization: Codable, Equatable {
    var sort = PeopleSort.custom
    var order: [String] = []

    func ordered(_ people: [PersonDTO]) -> [PersonDTO] {
        var positions: [String: Int] = [:]
        for (index, id) in order.enumerated() where positions[id] == nil { positions[id] = index }
        return people.enumerated().sorted { lhs, rhs in
            if sort == .name {
                let comparison = lhs.element.name.localizedStandardCompare(rhs.element.name)
                if comparison != .orderedSame { return comparison == .orderedAscending }
                return lhs.element.id < rhs.element.id
            }
            let a = positions[lhs.element.id] ?? Int.max
            let b = positions[rhs.element.id] ?? Int.max
            return a == b ? lhs.offset < rhs.offset : a < b
        }.map(\.element)
    }
}

@MainActor
@Observable
final class PeopleOrganizationStore {
    private(set) var value: PeopleOrganization
    private let defaults: UserDefaults
    private let key: String?
    private let generation = LocalSnapshot.generation
    var isCurrent: Bool { generation == LocalSnapshot.generation }

    init(owner: BackupQueueOwner?, defaults: UserDefaults = .standard) {
        self.defaults = defaults
        key = owner.map {
            let data = Data("\($0.server)\n\($0.userID)".utf8)
            let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            return "people.organization.v1.\(digest)"
        }
        value = key.flatMap { defaults.data(forKey: $0) }
            .flatMap { try? JSONDecoder().decode(PeopleOrganization.self, from: $0) } ?? PeopleOrganization()
    }

    func setSort(_ sort: PeopleSort) { change { $0.sort = sort } }

    func setOrder(_ ids: [String]) {
        var seen = Set<String>()
        change {
            $0.order = ids.filter { seen.insert($0).inserted }
            $0.sort = .custom
        }
    }

    @discardableResult
    func move(_ personID: String, before targetID: String, people: [PersonDTO]) -> Bool {
        var moved = false
        change { state in
            let current = state.ordered(people.filter { !$0.isHidden })
            guard state.sort == .custom, personID != targetID,
                  let source = current.first(where: { $0.id == personID }),
                  let target = current.first(where: { $0.id == targetID }),
                  (source.isFavorite == true) == (target.isFavorite == true) else { return }
            var ids = current.map(\.id)
            ids.removeAll { $0 == personID }
            guard let destination = ids.firstIndex(of: targetID) else { return }
            ids.insert(personID, at: destination)
            state.order = ids
            moved = true
        }
        return moved
    }

    private func change(_ operation: (inout PeopleOrganization) -> Void) {
        guard generation == LocalSnapshot.generation else { return }
        var updated = key.flatMap { defaults.data(forKey: $0) }
            .flatMap { try? JSONDecoder().decode(PeopleOrganization.self, from: $0) } ?? value
        operation(&updated)
        value = updated
        if let key, let data = try? JSONEncoder().encode(updated) { defaults.set(data, forKey: key) }
    }
}
