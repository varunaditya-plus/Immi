import Foundation
import Observation

@MainActor
@Observable
final class PersonDetailState {
    struct RenameRequest: Sendable {
        let personID: String
        let name: String
        fileprivate let generation: UUID
        fileprivate let operationID: UUID
    }

    private(set) var person: PersonDTO
    var renameDraft: String
    var actionError: String?
    private var renameID = UUID()
    private var hiddenID = UUID()
    private var detailID = UUID()
    private let snapshotGeneration = LocalSnapshot.generation

    init(person: PersonDTO) {
        self.person = person
        renameDraft = person.name
    }

    /// Admission happens in the Save action, before its task can be delayed.
    func prepareRename() -> RenameRequest? {
        guard !Task.isCancelled, !renameDraft.isEmpty,
              snapshotGeneration == LocalSnapshot.generation else { return nil }
        renameID = UUID()
        actionError = nil
        return RenameRequest(personID: person.id, name: renameDraft,
            generation: LocalSnapshot.generation, operationID: renameID)
    }

    func saveRename(
        _ request: RenameRequest, using repository: PeopleRepository,
        onRenamed: ((String, String) -> Void)? = nil
    ) async {
        guard isCurrent(request) else { return }
        do {
            try await repository.rename(request.personID, to: request.name)
            guard isCurrent(request) else { return }
            detailID = UUID()
            var updated = person
            updated.name = request.name
            person = updated
            onRenamed?(request.personID, request.name)
        } catch {
            guard isCurrent(request), !(error is CancellationError) else { return }
            actionError = (error as? APIError)?.errorDescription ?? error.localizedDescription
        }
    }

    func loadDetail(using repository: PeopleRepository) async {
        guard !Task.isCancelled, snapshotGeneration == LocalSnapshot.generation else { return }
        let requestID = UUID()
        detailID = requestID
        let personID = person.id
        let generation = LocalSnapshot.generation
        guard let detail = try? await repository.detail(personID),
              !Task.isCancelled, detailID == requestID,
              person.id == personID, detail.id == personID,
              generation == LocalSnapshot.generation else { return }
        person = detail
    }

    func toggleHidden(
        using repository: PeopleRepository, onHidden: ((String, Bool) -> Void)? = nil
    ) async {
        guard !Task.isCancelled, snapshotGeneration == LocalSnapshot.generation else { return }
        let requestID = UUID()
        hiddenID = requestID
        let personID = person.id
        let value = !person.isHidden
        let generation = LocalSnapshot.generation
        do {
            try await repository.setHidden(personID, to: value)
            guard !Task.isCancelled, hiddenID == requestID,
                  person.id == personID, generation == LocalSnapshot.generation else { return }
            detailID = UUID()
            var updated = person
            updated.isHidden = value
            person = updated
            onHidden?(personID, value)
        } catch {
            guard !Task.isCancelled, !(error is CancellationError), hiddenID == requestID,
                  person.id == personID, generation == LocalSnapshot.generation else { return }
            actionError = (error as? APIError)?.errorDescription ?? error.localizedDescription
        }
    }

    private func isCurrent(_ request: RenameRequest) -> Bool {
        !Task.isCancelled && request.operationID == renameID
            && request.personID == person.id && request.generation == LocalSnapshot.generation
    }
}
