import Foundation
import Observation

/// Aset yang dikeluarkan dari perpustakaan sepanjang sesi ini.
/// Soft-delete tetap boleh ditampilkan di Trash; aset yang tidak tersedia tidak.
///
/// **Masalah yang dipecahkannya.** Menghapus foto dari linimasa membereskan
/// cache linimasa — dan hanya itu. Album, Favorites, dan foto per orang punya
/// daftarnya masing-masing yang diambil dari endpoint lain dan disimpan sebagai
/// potret terpisah. Tidak ada satu pun dari daftar itu yang tahu bahwa fotonya
/// baru saja dibuang, jadi foto yang sudah dihapus tetap berdiri di sana sampai
/// layarnya memuat ulang dari server.
///
/// Menyisir setiap potret setiap kali sesuatu dihapus akan berarti membaca,
/// menyunting, dan menulis ulang selusin berkas JSON untuk satu ketukan. Yang
/// dilakukan di sini kebalikannya: daftar id yang dibuang disimpan sekali di
/// memori, dan setiap layar menyaring miliknya sendiri lewat daftar itu.
///
/// Sengaja TIDAK bertahan antar peluncuran. Isinya cuma tambalan sampai sync
/// berikutnya membawa kebenaran dari server — menyimpannya ke disk berarti
/// menyimpan tebakan yang bisa keliru selamanya.
///
/// Polanya sama dengan `UnreadableAssets.shared`, dan alasannya sama: yang perlu
/// tahu tersebar di banyak layar yang tidak saling mengenal.
@MainActor
@Observable
final class RemovedAssets {
    static let shared = RemovedAssets()

    enum Reason { case trashed, unavailable }
    enum Scope { case library, trash }

    private(set) var ids: Set<String> = []
    private(set) var trashedIDs: Set<String> = []
    private var restoredTrashIDs: Set<String> = []
    private(set) var trashRevision = UUID()
    private(set) var trashMutationRevision: UInt64 = 0
    private var trashChanges: [String: UInt64] = [:]

    init() {}

    func remove(_ removed: [String], reason: Reason = .unavailable) {
        guard !removed.isEmpty else { return }
        recordTrashMutation(removed)
        restoredTrashIDs.subtract(removed)
        ids.formUnion(removed)
        switch reason {
        case .trashed: trashedIDs.formUnion(removed)
        case .unavailable: trashedIDs.subtract(removed)
        }
    }

    /// Dipakai saat foto DIKEMBALIKAN dari tong sampah.
    ///
    /// Tanpa ini, memulihkan foto yang barusan dibuang akan menghasilkan foto
    /// yang ada di server tapi tetap tak terlihat di aplikasi — tersaring oleh
    /// catatan yang sudah tidak berlaku.
    func restore(_ restored: [String]) {
        let changed = ids.intersection(restored)
        guard !changed.isEmpty else { return }
        restoredTrashIDs.formUnion(trashedIDs.intersection(restored))
        ids.subtract(restored)
        trashedIDs.subtract(restored)
        recordTrashMutation(Array(changed))
    }

    /// A confirmed restore also hides retained Trash snapshots in other windows.
    func restoreFromTrash(_ restored: [String]) {
        guard !restored.isEmpty else { return }
        ids.subtract(restored)
        trashedIDs.subtract(restored)
        restoredTrashIDs.formUnion(restored)
        recordTrashMutation(restored)
    }

    func emptyTrash(_ emptied: [String]) {
        remove(emptied, reason: .unavailable)
    }

    /// Only a current server query may admit a photo that was restored locally.
    @discardableResult
    func confirmTrashed(_ candidates: [String], expectedRevision: UUID) -> Bool {
        guard expectedRevision == trashRevision else { return false }
        let confirmed = candidates.filter { !ids.contains($0) || trashedIDs.contains($0) }
        let changed = restoredTrashIDs.intersection(confirmed)
        restoredTrashIDs.subtract(confirmed)
        ids.formUnion(confirmed)
        trashedIDs.formUnion(confirmed)
        // Ordinary reads do not turn existing rows into a newer mutation. New
        // evidence that a restored photo was trashed again does supersede one.
        if !changed.isEmpty { recordTrashMutation(Array(changed)) }
        return true
    }

    func invalidateTrashQueries() {
        trashRevision = UUID()
    }

    func changedInTrash(_ id: String, after revision: UInt64) -> Bool {
        (trashChanges[id] ?? 0) > revision
    }

    private func recordTrashMutation(_ changed: [String]) {
        guard !changed.isEmpty else { return }
        trashRevision = UUID()
        trashMutationRevision &+= 1
        for id in changed { trashChanges[id] = trashMutationRevision }
    }

    func clear() {
        ids.removeAll()
        trashedIDs.removeAll()
        restoredTrashIDs.removeAll()
        trashChanges.removeAll()
        trashMutationRevision = 0
        trashRevision = UUID()
    }

    func contains(_ id: String, scope: Scope = .library) -> Bool {
        if scope == .trash {
            return restoredTrashIDs.contains(id) || (ids.contains(id) && !trashedIDs.contains(id))
        }
        return ids.contains(id)
    }

    func excludedIDs(scope: Scope = .library) -> Set<String> {
        scope == .trash ? ids.subtracting(trashedIDs).union(restoredTrashIDs) : ids
    }

    /// Menyaring daftar apa pun. Pulang apa adanya kalau tidak ada yang dibuang —
    /// keadaan yang paling sering terjadi, dan tidak perlu membayar satu lintasan
    /// untuknya.
    func filter(_ assets: [AssetLite], scope: Scope = .library) -> [AssetLite] {
        let excluded = excludedIDs(scope: scope)
        guard !excluded.isEmpty else { return assets }
        return assets.filter { !excluded.contains($0.id) }
    }
}
