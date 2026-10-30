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
    private var favoriteID = UUID()
    private var keyPhotoID = UUID()
    private let snapshotGeneration = LocalSnapshot.generation
    var isCurrent: Bool { snapshotGeneration == LocalSnapshot.generation }

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

    func setFavorite(
        _ value: Bool, using repository: PeopleRepository,
        onUpdated: ((PersonUpdate) -> Void)? = nil
    ) async {
        guard !Task.isCancelled, snapshotGeneration == LocalSnapshot.generation else { return }
        let request = UUID()
        favoriteID = request
        actionError = nil
        do {
            try await repository.setFavorite(person.id, to: value)
            guard !Task.isCancelled, snapshotGeneration == LocalSnapshot.generation,
                  favoriteID == request else { return }
            detailID = UUID()
            var updated = person
            updated.isFavorite = value
            person = updated
            onUpdated?(PersonUpdate(person: updated, fields: [.favorite]))
        } catch {
            guard !Task.isCancelled, !(error is CancellationError),
                  snapshotGeneration == LocalSnapshot.generation, favoriteID == request else { return }
            actionError = (error as? APIError)?.errorDescription ?? String(localized: "Failed to update person")
        }
    }

    func chooseKeyPhoto(
        _ assetID: String, from assets: [AssetLite], using repository: PeopleRepository,
        onUpdated: ((PersonUpdate) -> Void)? = nil
    ) async -> String? {
        let policy = AssetVisibilityPolicy(scope: .timeline)
        guard !Task.isCancelled, snapshotGeneration == LocalSnapshot.generation,
              assets.contains(where: { $0.id == assetID }), policy.allows(id: assetID),
              !LocalPhotoLibrary.isLocal(assetID) else { return String(localized: "This photo is no longer available.") }
        let request = UUID()
        keyPhotoID = request
        do {
            try await repository.setKeyPhoto(person.id, assetID: assetID)
            guard !Task.isCancelled, snapshotGeneration == LocalSnapshot.generation,
                  keyPhotoID == request, policy.allows(id: assetID) else { return String(localized: "This photo is no longer available.") }
            detailID = UUID()
            var updated = person
            updated.updatedAt = Date()
            person = updated
            onUpdated?(PersonUpdate(person: updated, fields: [.thumbnail]))
            return nil
        } catch {
            guard !Task.isCancelled, !(error is CancellationError),
                  snapshotGeneration == LocalSnapshot.generation, keyPhotoID == request else { return nil }
            return (error as? APIError)?.errorDescription ?? String(localized: "Failed to update person")
        }
    }

    private func isCurrent(_ request: RenameRequest) -> Bool {
        !Task.isCancelled && request.operationID == renameID
            && request.personID == person.id && request.generation == LocalSnapshot.generation
    }
}
