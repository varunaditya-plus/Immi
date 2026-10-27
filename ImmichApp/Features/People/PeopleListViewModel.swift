import Foundation
import Observation

@MainActor
@Observable
final class PeopleListViewModel {
    private let snapshotGeneration = LocalSnapshot.generation

    var people: [PersonDTO] = []
    var phase: LoadingPhase<Void> = .idle

    private let repo: PeopleRepository

    init(repo: PeopleRepository) {
        self.repo = repo
    }

    /// Potret lokal dulu, jaringan menyusul — lihat `LocalSnapshot`.
    func loadPeople() async {
        guard snapshotGeneration == LocalSnapshot.generation else { return }
        if people.isEmpty {
            if let cached = LocalSnapshot.load(
                [PersonDTO].self, for: LocalSnapshot.Key.peopleList) {
                people = cached
                phase = .loaded(())
            } else {
                phase = .loading
            }
        }

        do {
            let fetched = try await repo.all()
            guard snapshotGeneration == LocalSnapshot.generation else { return }
            if LocalSnapshot.save(fetched, for: LocalSnapshot.Key.peopleList, expectedGeneration: snapshotGeneration) || people.isEmpty {
                people = fetched
            }
            phase = .loaded(())
        } catch {
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
        do {
            try await repo.setHidden(personId, to: value)
            if let index = people.firstIndex(where: { $0.id == personId }) {
                people[index].isHidden = value
            }
            persist()
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
        if let index = people.firstIndex(where: { $0.id == personId }) {
            people[index].name = name
            persist()
        }
    }

    func applyHidden(_ personId: String, to value: Bool) {
        if let index = people.firstIndex(where: { $0.id == personId }) {
            people[index].isHidden = value
            persist()
        }
    }
}
