import Foundation

/// Aset server yang sengaja dibuang tetapi salinan PhotoKit-nya masih ada.
///
/// Timeline menggabungkan cache server dengan album perangkat. Sesudah aset
/// server dipindahkan ke Trash, mapping backup lokal -> server sengaja tetap
/// disimpan agar file yang sama tidak di-upload ulang. Tanpa penanda kedua ini,
/// pembukaan aplikasi berikutnya mengira mapping itu adalah upload yang baru
/// selesai dan menggambar lagi foto lokalnya.
///
/// Disimpan di UserDefaults karena ini hanya indeks kecil berisi UUID, bukan
/// metadata atau media pengguna. State dibersihkan saat logout supaya tidak
/// menyeberang ke akun/server berikutnya.
@MainActor
final class DeletedServerAssetRegistry {
    static let shared = DeletedServerAssetRegistry()

    private enum Key {
        static let trashed = "timeline.deletedServerAssets.trashed.v1"
        static let permanent = "timeline.deletedServerAssets.permanent.v1"
    }

    private let defaults: UserDefaults
    private var trashedIDs: Set<String>
    private var permanentIDs: Set<String>

    var suppressedIDs: Set<String> {
        trashedIDs.union(permanentIDs)
    }

    func isTrashed(_ id: String) -> Bool { trashedIDs.contains(id) }
    func isPermanentlyDeleted(_ id: String) -> Bool { permanentIDs.contains(id) }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        trashedIDs = Set(defaults.stringArray(forKey: Key.trashed) ?? [])
        permanentIDs = Set(defaults.stringArray(forKey: Key.permanent) ?? [])
    }

    /// Dipanggil hanya sesudah DELETE /assets dikonfirmasi server.
    func record(_ ids: [String], permanently: Bool) {
        guard !ids.isEmpty else { return }
        let oldTrashed = trashedIDs
        let oldPermanent = permanentIDs
        if permanently {
            trashedIDs.subtract(ids)
            permanentIDs.formUnion(ids)
        } else {
            trashedIDs.formUnion(ids)
        }
        guard oldTrashed != trashedIDs || oldPermanent != permanentIDs else { return }
        persist()
    }

    func restore(_ ids: [String]) {
        guard !ids.isEmpty else { return }
        let oldCount = trashedIDs.count
        trashedIDs.subtract(ids)
        guard oldCount != trashedIDs.count else { return }
        persist()
    }

    /// Restore All hanya berlaku untuk isi Trash. Aset yang sudah dihapus
    /// permanen tetap harus ditekan agar salinan lokalnya tidak muncul kembali.
    func restoreAllFromTrash() {
        guard !trashedIDs.isEmpty else { return }
        trashedIDs.removeAll()
        persist()
    }

    /// Empty Trash mengubah soft-delete menjadi permanent-delete.
    func emptyTrash() {
        guard !trashedIDs.isEmpty else { return }
        permanentIDs.formUnion(trashedIDs)
        trashedIDs.removeAll()
        persist()
    }

    func clear() {
        trashedIDs.removeAll()
        permanentIDs.removeAll()
        defaults.removeObject(forKey: Key.trashed)
        defaults.removeObject(forKey: Key.permanent)
    }

    private func persist() {
        defaults.set(trashedIDs.sorted(), forKey: Key.trashed)
        defaults.set(permanentIDs.sorted(), forKey: Key.permanent)
    }
}
