import Foundation
import Observation

@MainActor
@Observable
final class PeopleListViewModel {
    private let snapshotGeneration = LocalSnapshot.generation
    private var loadID = UUID()
    private var phaseBeforeLoad: LoadingPhase<Void> = .idle
    private var hiddenRequests: [String: UUID] = [:]
    private var restoredSnapshot = false

    var people: [PersonDTO] = []
    var phase: LoadingPhase<Void> = .idle

    private let repo: PeopleRepository

    init(repo: PeopleRepository) {
        self.repo = repo
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
                [PersonDTO].self, for: LocalSnapshot.Key.peopleList) {
                people = cached
                phase = .loaded(())
            }
        }
        if people.isEmpty, phase.value == nil { phase = .loading }

        do {
            let fetched = try await repo.all()
            guard isCurrentLoad(requestID) else { return }
            guard !Task.isCancelled else {
                if phase.isLoading { phase = phaseBeforeLoad }
                return
            }
            LocalSnapshot.save(fetched, for: LocalSnapshot.Key.peopleList, expectedGeneration: snapshotGeneration)
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
        defer {
            if hiddenRequests[personId] == requestID { hiddenRequests[personId] = nil }
        }
        do {
            try await repo.setHidden(personId, to: value)
            guard !Task.isCancelled, snapshotGeneration == LocalSnapshot.generation,
                  hiddenRequests[personId] == requestID else { return }
            applyHidden(personId, to: value)
        } catch {
            // Handle silently
        }
    }

    private func persist() {
        LocalSnapshot.save(people, for: LocalSnapshot.Key.peopleList, expectedGeneration: snapshotGeneration)
    }

    func retry() async {
        await loadPeople()
    }

    func applyRename(_ personId: String, to name: String) {
        guard !Task.isCancelled, snapshotGeneration == LocalSnapshot.generation else { return }
        invalidateLoads()
        if let index = people.firstIndex(where: { $0.id == personId }) {
            var updated = people[index]
            updated.name = name
            people[index] = updated
            persist()
        }
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
