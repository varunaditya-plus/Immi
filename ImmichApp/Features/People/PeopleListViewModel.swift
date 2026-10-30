import Foundation
import Observation

@MainActor
@Observable
final class PeopleListViewModel {
    private let snapshotGeneration = LocalSnapshot.generation
    private var loadID = UUID()
    private var phaseBeforeLoad: LoadingPhase<Void> = .idle
    private var hiddenRequests: [String: UUID] = [:]
    private var favoriteRequests: [String: UUID] = [:]
    private var mergeID = UUID()
    private var mergedSourceIDs: Set<String> = []
    private var restoredSnapshot = false

    var people: [PersonDTO] = []
    var phase: LoadingPhase<Void> = .idle
    var actionError: String?
    private(set) var isMerging = false

    private let repo: PeopleRepository
    var isCurrent: Bool { snapshotGeneration == LocalSnapshot.generation }
    private let includesHidden: Bool
    private var snapshotKey: String { includesHidden ? "people.hidden" : LocalSnapshot.Key.peopleList }

    init(repo: PeopleRepository, includesHidden: Bool = false) {
        self.repo = repo
        self.includesHidden = includesHidden
    }

    /// Potret lokal dulu, jaringan menyusul — lihat `LocalSnapshot`.
    func loadPeople() async {
        guard !Task.isCancelled, snapshotGeneration == LocalSnapshot.generation else { return }
        let requestID = UUID()
        loadID = requestID
        if !phase.isLoading { phaseBeforeLoad = phase }
        if !restoredSnapshot {
            restoredSnapshot = true
            if people.isEmpty, let cached = LocalSnapshot.load(
                [PersonDTO].self, for: snapshotKey) {
                people = cached
                phase = .loaded(())
            }
        }
        if people.isEmpty, phase.value == nil { phase = .loading }

        do {
            let fetched = try await (includesHidden ? repo.allIncludingHidden() : repo.all())
            guard isCurrentLoad(requestID) else { return }
            guard !Task.isCancelled else {
                if phase.isLoading { phase = phaseBeforeLoad }
                return
            }
            LocalSnapshot.save(fetched, for: snapshotKey, expectedGeneration: snapshotGeneration)
            people = fetched
            phase = .loaded(())
        } catch {
            guard isCurrentLoad(requestID) else { return }
            guard !Task.isCancelled, !(error is CancellationError) else {
                if phase.isLoading { phase = phaseBeforeLoad }
                return
            }
            // Sudah ada jawaban yang SAH di layar — entah dari potret, entah
            // dari muatan sebelumnya — jadi kegagalannya diam.
            //
            // Diperiksa lewat `phase`, bukan lewat "daftarnya kosong": potret
            // `[]` juga jawaban yang sah — server yang memang belum mengenali
            // wajah siapa pun. Menukarnya dengan "Failed to Load" begitu offline
            // adalah kebohongan yang persis hendak dihindari cache ini.
            if case .loaded = phase { return }
            phase = .failed((error as? APIError)?.errorDescription ?? String(localized: "Failed to load people"))
        }
    }

    func setHidden(_ personId: String, to value: Bool) async {
        guard !Task.isCancelled, snapshotGeneration == LocalSnapshot.generation else { return }
        let requestID = UUID()
        hiddenRequests[personId] = requestID
        actionError = nil
        defer {
            if hiddenRequests[personId] == requestID { hiddenRequests[personId] = nil }
        }
        do {
            try await repo.setHidden(personId, to: value)
            guard !Task.isCancelled, snapshotGeneration == LocalSnapshot.generation,
                  hiddenRequests[personId] == requestID else { return }
            applyHidden(personId, to: value)
        } catch {
            guard !Task.isCancelled, !(error is CancellationError),
                  snapshotGeneration == LocalSnapshot.generation,
                  hiddenRequests[personId] == requestID else { return }
            actionError = (error as? APIError)?.errorDescription ?? String(localized: "Failed to update person")
        }
    }

    @discardableResult
    func setFavorite(_ personID: String, to value: Bool) async -> Bool {
        guard !Task.isCancelled, snapshotGeneration == LocalSnapshot.generation,
              people.contains(where: { $0.id == personID && !$0.isHidden }) else { return false }
        let request = UUID()
        favoriteRequests[personID] = request
        actionError = nil
        defer { if favoriteRequests[personID] == request { favoriteRequests[personID] = nil } }
        do {
            try await repo.setFavorite(personID, to: value)
            guard !Task.isCancelled, snapshotGeneration == LocalSnapshot.generation,
                  favoriteRequests[personID] == request,
                  let index = people.firstIndex(where: { $0.id == personID }) else { return false }
            invalidateLoads()
            people[index].isFavorite = value
            persist()
            return true
        } catch {
            guard !Task.isCancelled, !(error is CancellationError),
                  snapshotGeneration == LocalSnapshot.generation,
                  favoriteRequests[personID] == request else { return false }
            actionError = (error as? APIError)?.errorDescription ?? String(localized: "Failed to update person")
            return false
        }
    }

    @discardableResult
    func merge(_ sourceIDs: [String], into targetID: String, reportsFailure: Bool = true) async -> PeopleMergeResult? {
        let admitted = Set(people.filter { !$0.isHidden }.map(\.id))
        let sources = Set(sourceIDs).subtracting([targetID])
        guard !Task.isCancelled, snapshotGeneration == LocalSnapshot.generation, !isMerging,
              admitted.contains(targetID), !sources.isEmpty, sources.isSubset(of: admitted) else { return nil }
        let request = UUID()
        mergeID = request
        isMerging = true
        if reportsFailure { actionError = nil }
        defer { if mergeID == request { isMerging = false } }
        do {
            let results = try await repo.merge(sources.sorted(), into: targetID)
            guard !Task.isCancelled, snapshotGeneration == LocalSnapshot.generation,
                  mergeID == request else { return nil }
            let accepted = Set(results.filter(\.success).map(\.id)).intersection(sources)
            invalidateLoads()
            mergedSourceIDs.formUnion(accepted)
            people.removeAll { accepted.contains($0.id) }
            for id in accepted.union([targetID]) {
                LocalSnapshot.remove(LocalSnapshot.Key.person(id), expectedGeneration: snapshotGeneration)
            }
            persist()
            let revision = loadID
            if let target = try? await repo.detail(targetID), !Task.isCancelled,
               snapshotGeneration == LocalSnapshot.generation, loadID == revision,
               target.id == targetID, let index = people.firstIndex(where: { $0.id == targetID }) {
                people[index] = target
                persist()
            }
            guard snapshotGeneration == LocalSnapshot.generation, !Task.isCancelled else { return nil }
            if accepted != sources, reportsFailure {
                actionError = String(localized: "Some people could not be merged. Try again.")
            }
            return PeopleMergeResult(acceptedIDs: accepted, failedIDs: sources.subtracting(accepted))
        } catch {
            guard !Task.isCancelled, !(error is CancellationError),
                  snapshotGeneration == LocalSnapshot.generation, mergeID == request else { return nil }
            if reportsFailure {
                actionError = (error as? APIError)?.errorDescription ?? String(localized: "Failed to merge people")
            }
            return nil
        }
    }

    func applyPersonUpdate(_ update: PersonUpdate) {
        guard !Task.isCancelled, snapshotGeneration == LocalSnapshot.generation,
              !mergedSourceIDs.contains(update.person.id) else { return }
        invalidateLoads()
        if update.fields.contains(.hidden) { hiddenRequests[update.person.id] = nil }
        if update.fields.contains(.favorite) { favoriteRequests[update.person.id] = nil }
        if let index = people.firstIndex(where: { $0.id == update.person.id }) {
            people[index] = update.applying(to: people[index])
        } else { people.append(update.person) }
        persist()
    }

    private func persist() {
        LocalSnapshot.save(people, for: snapshotKey, expectedGeneration: snapshotGeneration)
    }

    func retry() async {
        await loadPeople()
    }

    func applyHidden(_ personId: String, to value: Bool) {
        guard !Task.isCancelled, snapshotGeneration == LocalSnapshot.generation else { return }
        invalidateLoads()
        hiddenRequests[personId] = nil
        if let index = people.firstIndex(where: { $0.id == personId }) {
            var updated = people[index]
            updated.isHidden = value
            people[index] = updated
            persist()
        }
    }

    private func isCurrentLoad(_ requestID: UUID) -> Bool {
        snapshotGeneration == LocalSnapshot.generation && loadID == requestID
    }

    private func invalidateLoads() {
        loadID = UUID()
        if phase.isLoading { phase = phaseBeforeLoad }
    }
}
