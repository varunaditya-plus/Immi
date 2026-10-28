import Foundation
import Observation

@MainActor
@Observable
final class SharedLinksViewModel {
    var links: [SharedLinkDTO] = []
    var phase: LoadingPhase<Void> = .idle

    private let repo: SharedLinkRepository
    private let snapshotGeneration = LocalSnapshot.generation
    private var loadID = UUID()
    private var phaseBeforeLoad: LoadingPhase<Void> = .idle
    private var updateIDs: [String: UUID] = [:]

    init(repo: SharedLinkRepository) {
        self.repo = repo
    }

    func load() async {
        guard canPublish else { return }
        let requestID = UUID()
        loadID = requestID
        if !phase.isLoading { phaseBeforeLoad = phase }
        phase = .loading
        do {
            let fetched = try await fetch()
            guard isCurrentLoad(requestID) else { return }
            try Task.checkCancellation()
            links = fetched
            phase = .loaded(())
            phaseBeforeLoad = phase
        } catch {
            guard isCurrentLoad(requestID) else { return }
            guard !Task.isCancelled, !(error is CancellationError) else {
                phase = phaseBeforeLoad
                return
            }
            phase = .failed(message(for: error, fallback: "Failed to load shared links"))
            phaseBeforeLoad = phase
        }
    }

    /// Muat ulang TANPA mengosongkan layar.
    ///
    /// `load()` memasang `.loading`, dan itu menukar daftarnya dengan spinner
    /// selayar penuh — termasuk melenyapkan kontrol tarik-untuk-menyegarkan yang
    /// sedang dipegang jari, di tengah gerakannya. Kegagalannya pun tidak boleh
    /// menghapus daftar yang sudah terlihat.
    ///
    /// - Returns: pesan kesalahan, atau nil kalau berhasil.
    func refresh() async -> String? {
        guard canPublish else { return nil }
        let requestID = UUID()
        loadID = requestID
        if phase.isLoading { phase = phaseBeforeLoad }
        do {
            let fetched = try await fetch()
            guard isCurrentLoad(requestID) else { return nil }
            try Task.checkCancellation()
            links = fetched
            phase = .loaded(())
            phaseBeforeLoad = phase
            return nil
        } catch {
            guard isCurrentLoad(requestID), !Task.isCancelled, !(error is CancellationError) else { return nil }
            return message(for: error, fallback: "Failed to load shared links")
        }
    }

    private var canPublish: Bool {
        !Task.isCancelled && snapshotGeneration == LocalSnapshot.generation
    }

    private func isCurrentLoad(_ id: UUID) -> Bool {
        snapshotGeneration == LocalSnapshot.generation && loadID == id
    }

    private func invalidateLoads() {
        loadID = UUID()
        phase = .loaded(())
        phaseBeforeLoad = phase
    }

    private func finishUpdate(_ id: String, requestID: UUID) {
        if updateIDs[id] == requestID { updateIDs[id] = nil }
    }

    func retry() async {
        await load()
    }

    /// - Returns: pesan kesalahan, atau nil kalau berhasil.
    func update(_ id: String, edit: SharedLinkEditDTO) async -> String? {
        guard canPublish else { return nil }
        let requestID = UUID()
        updateIDs[id] = requestID
        defer { finishUpdate(id, requestID: requestID) }
        do {
            let updated = try await repo.update(id, edit: edit)
            guard canPublish, updateIDs[id] == requestID else { return nil }
            invalidateLoads()
            guard let index = links.firstIndex(where: { $0.id == id }) else { return nil }

            // Ditambal DI TEMPAT, bukan memuat ulang seluruh daftar: hasil PATCH
            // sudah berisi tautan versi barunya, dan memuat ulang membuat
            // daftarnya berkedip kosong sesaat setelah sheet menutup.
            //
            // Album dan asetnya DIPERTAHANKAN kalau respons PATCH tidak
            // menyertakannya — endpoint sunting tidak menjanjikan relasi itu ikut
            // dikirim, dan menimpanya dengan nil membuat barisnya kehilangan
            // thumbnail dan nama tepat setelah disimpan.
            var merged = updated
            if merged.album == nil { merged.album = links[index].album }
            if merged.assets == nil { merged.assets = links[index].assets }
            links[index] = merged
            return nil
        } catch {
            guard canPublish, updateIDs[id] == requestID else { return nil }
            return message(for: error, fallback: "Failed to update link")
        }
    }

    /// - Returns: pesan kesalahan, atau nil kalau berhasil.
    func delete(_ id: String) async -> String? {
        guard canPublish else { return nil }
        do {
            try await repo.delete(id)
            guard canPublish else { return nil }
            invalidateLoads()
            updateIDs[id] = nil
            links.removeAll { $0.id == id }
            return nil
        } catch {
            guard canPublish else { return nil }
            return message(for: error, fallback: "Failed to delete link")
        }
    }

    /// Terbaru dulu. Server tidak menjanjikan urutan apa pun, dan tautan yang
    /// baru dibuat itulah yang paling mungkin sedang dicari.
    private func fetch() async throws -> [SharedLinkDTO] {
        try await repo.all().sorted {
            ($0.createdAt ?? .distantPast) > ($1.createdAt ?? .distantPast)
        }
    }

    private func message(for error: Error, fallback: String.LocalizationValue) -> String {
        (error as? APIError)?.errorDescription ?? String(localized: fallback)
    }
}
