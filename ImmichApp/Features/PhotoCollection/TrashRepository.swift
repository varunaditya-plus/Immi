import Foundation

/// Operasi khusus tong sampah.
///
/// Terpisah dari `AssetDetailRepository` karena artinya berbeda: di sana
/// "delete" berarti MEMINDAHKAN ke tong sampah, sedangkan di sini penghapusannya
/// permanen dan tidak bisa dibatalkan.
class TrashRepository {
    private let api: APIClient

    init(api: APIClient) {
        self.api = api
    }

    /// Menghapus PERMANEN seluruh isi tong sampah.
    func empty() async throws {
        try await api.sendVoid(.init(path: "/trash/empty", method: .post))
    }

    /// Mengembalikan seluruh isi tong sampah ke perpustakaan.
    func restoreAll() async throws {
        try await api.sendVoid(.init(path: "/trash/restore", method: .post))
    }

    func restore(_ ids: [String]) async throws {
        guard !ids.isEmpty else { return }
        try await api.sendVoid(
            .json("/trash/restore/assets", method: .post, body: ["ids": ids]))
    }
}
