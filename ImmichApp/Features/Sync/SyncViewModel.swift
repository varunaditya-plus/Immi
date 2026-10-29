import Foundation
import Observation

@MainActor
@Observable
final class SyncViewModel {
    /// Diteruskan dari `NetworkMonitor`, tidak dipantau sendiri lagi.
    ///
    /// Dulu view model ini memegang `NWPathMonitor`-nya sendiri — dan karena ia
    /// hidup sebagai `@State` milik satu view, layar yang tidak bisa
    /// menjangkaunya (detail aset, yang dipresentasikan UIKit) tidak punya cara
    /// tahu sedang offline.
    var isOnline: Bool { NetworkMonitor.shared.isOnline }
    var isSyncing: Bool = false
    var lastSyncTime: Date?
    var syncProgress: String = ""
    /// Naik setiap percobaan sync pembuka selesai, termasuk ketika perangkat
    /// offline atau server tidak dapat dijangkau.
    ///
    /// Timeline membutuhkannya untuk membedakan snapshot cache sementara dari
    /// snapshot pembuka yang sudah final. `lastSyncTime` tidak cukup karena ia
    /// hanya berubah saat sync berhasil; pada kegagalan grid akan tersembunyi
    /// selamanya kalau memakai nilai itu sebagai gerbang.
    private(set) var backgroundSyncCompletionCount = 0

    private let repo: SyncRepository
    private let dataManager: SwiftDataManager

    init(repo: SyncRepository, dataManager: SwiftDataManager) {
        self.repo = repo
        self.dataManager = dataManager
    }

    @discardableResult
    func performFullSync() async -> Bool {
        guard !isSyncing else {
            syncProgress = String(localized: "A sync job is already running")
            return false
        }
        guard isOnline else {
            syncProgress = String(localized: "No network connection")
            return false
        }
        isSyncing = true
        syncProgress = String(localized: "Syncing...")
        defer { isSyncing = false }

        do {
            try await repo.fullSync()
            lastSyncTime = Date()
            syncProgress = String(localized: "Sync complete")
            return true
        } catch {
            syncProgress = String(localized: "Sync failed: \(error.localizedDescription)")
            return false
        }
    }

    @discardableResult
    func performDeltaSync() async -> Bool {
        guard !isSyncing else {
            syncProgress = String(localized: "A sync job is already running")
            return false
        }
        guard isOnline else {
            syncProgress = String(localized: "No network connection")
            return false
        }
        isSyncing = true
        syncProgress = String(localized: "Syncing changes...")
        defer { isSyncing = false }

        do {
            try await repo.deltaSync()
            lastSyncTime = Date()
            syncProgress = String(localized: "Sync complete")
            return true
        } catch {
            syncProgress = String(localized: "Sync failed: \(error.localizedDescription)")
            return false
        }
    }

    /// Dipakai juga oleh layar Photos, yang merender DARI hasil sync ini —
    /// karena itu statusnya harus terlihat, bukan diam-diam seperti dulu. Layar
    /// kosong yang tidak menjelaskan apa-apa selama sync pertama berjalan
    /// terlihat persis seperti aplikasi yang menggantung.
    func performBackgroundSync() async {
        guard isOnline else {
            backgroundSyncCompletionCount &+= 1
            return
        }
        guard !isSyncing else { return }
        isSyncing = true
        defer {
            isSyncing = false
            backgroundSyncCompletionCount &+= 1
        }

        do {
            let state = dataManager.getSyncState()
            if state.lastFullSyncAt == nil {
                try await repo.fullSync()
            } else {
                try await repo.deltaSync()
            }
            lastSyncTime = Date()
            syncProgress = String(localized: "Sync complete")
        } catch {
            // Jangan hilangkan diagnosis lagi. Layar status sync dan log state
            // kini dapat menunjukkan penyebab sebenarnya bila kontrak server,
            // autentikasi, atau jaringan berubah.
            syncProgress = String(localized: "Sync failed: \(error.localizedDescription)")
        }
    }

}
