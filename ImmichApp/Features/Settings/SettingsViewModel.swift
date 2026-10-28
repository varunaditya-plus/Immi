import Foundation
import Observation
import UIKit

private struct ServerReleaseVersion: Comparable {
    let core: [String]
    let prerelease: [String]

    init?(_ tag: String) {
        let version = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
        let buildParts = version.split(separator: "+", omittingEmptySubsequences: false)
        guard buildParts.count <= 2 else { return nil }
        if buildParts.count == 2, !Self.validIdentifiers(buildParts[1]) { return nil }
        let parts = buildParts[0].split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        let core = parts[0].split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        guard core.count == 3, core.allSatisfy(Self.validNumber) else { return nil }
        self.core = core
        if parts.count == 2 {
            guard Self.validIdentifiers(parts[1]) else { return nil }
            let identifiers = parts[1].split(separator: ".").map(String.init)
            guard identifiers.allSatisfy({ !Self.isNumeric($0) || Self.validNumber($0) }) else { return nil }
            prerelease = identifiers
        } else {
            prerelease = []
        }
    }

    static func < (lhs: Self, rhs: Self) -> Bool {
        for (left, right) in zip(lhs.core, rhs.core) where left != right {
            return numberPrecedes(left, right)
        }
        guard !lhs.prerelease.isEmpty else { return false }
        guard !rhs.prerelease.isEmpty else { return true }
        for (left, right) in zip(lhs.prerelease, rhs.prerelease) where left != right {
            let leftIsNumeric = isNumeric(left)
            let rightIsNumeric = isNumeric(right)
            if leftIsNumeric != rightIsNumeric { return leftIsNumeric }
            return leftIsNumeric ? numberPrecedes(left, right) : left < right
        }
        return lhs.prerelease.count < rhs.prerelease.count
    }

    private static func isNumeric(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.allSatisfy { (48...57).contains($0) }
    }

    private static func validNumber(_ value: String) -> Bool {
        isNumeric(value) && (value == "0" || !value.hasPrefix("0"))
    }

    // Compare decimal strings to avoid overflowing Int on large version components.
    private static func numberPrecedes(_ lhs: String, _ rhs: String) -> Bool {
        lhs.count == rhs.count ? lhs < rhs : lhs.count < rhs.count
    }

    private static func validIdentifiers(_ value: Substring) -> Bool {
        value.split(separator: ".", omittingEmptySubsequences: false).allSatisfy { identifier in
            !identifier.isEmpty && identifier.utf8.allSatisfy {
                (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45
            }
        }
    }
}

@MainActor
@Observable
final class SettingsViewModel {
    var storage: ServerStorageDTO?
    var serverInfo: ServerAboutDTO?
    var assetStats: AssetStatsDTO?
    var latestVersion: String?
    var cacheSize = 0

    /// Fase yang HANYA menyangkut data server.
    ///
    /// Dulu satu fase ini menutupi seluruh layar dengan spinner. Padahal
    /// sebagian besar isi pengaturan sudah ada di perangkat ini — tema, jumlah
    /// kolom, ukuran cache, versi aplikasi, alamat server, keluar akun — dan
    /// tidak menunggu siapa pun. Menahannya di belakang satu permintaan jaringan
    /// berarti pengaturan yang seharusnya bisa dipakai offline pun ikut tidak
    /// bisa dibuka saat servernya tidak terjangkau.
    ///
    /// Sekarang penantiannya tinggal di bagian yang memang datang dari server:
    /// penyimpanan, jumlah aset, dan versi server.
    var serverPhase: LoadingPhase<Void> = .idle

    // Preferensi tampilan disimpan lokal — API Immich tidak punya
    // preferensi theme/grid, dulu app salah mengirimnya ke server.
    static let themeKey = "settings.theme"
    static let gridColumnsKey = "settings.gridColumns"
    /// iPad punya bidang cukup luas untuk lima petak tanpa membuat thumbnail
    /// terlalu kecil. Nilai ini hanya dipakai kalau belum ada pilihan tersimpan.
    static var defaultGridColumns: Int {
        UIDevice.current.userInterfaceIdiom == .pad ? 5 : 3
    }

    var selectedTheme: String
    var gridColumns: Int

    private let repo: SettingsRepository

    init(repo: SettingsRepository) {
        self.repo = repo
        selectedTheme = UserDefaults.standard.string(forKey: Self.themeKey) ?? "system"
        let stored = UserDefaults.standard.integer(forKey: Self.gridColumnsKey)
        gridColumns = stored > 0 ? stored : Self.defaultGridColumns
    }

    /// Nama dan email penggunanya TIDAK diambil di sini — `SessionManager` sudah
    /// memegangnya sejak masuk, dan menyegarkannya adalah urusan
    /// `SessionManager.refreshUser()`. Menariknya lagi di sini hanya berarti dua
    /// permintaan `/users/me` untuk satu layar yang sama.
    func loadServerInfo() async {
        serverPhase = .loading
        do {
            async let storageTask = repo.getStorageInfo()
            async let serverTask = repo.getServerInfo()
            // Jumlah aset dibiarkan gagal diam-diam: header masih berguna tanpa
            // angka itu, sedangkan menjatuhkan seluruh bagian server karena satu
            // hitungan tidak.
            async let statsTask = try? repo.getAssetStats()
            // Sama: pemeriksaan versi bisa dimatikan di server, dan itu bukan
            // alasan untuk menandai datanya gagal.
            async let versionTask = try? repo.getVersionCheck()

            let (storage, server) = try await (storageTask, serverTask)

            self.storage = storage
            self.serverInfo = server
            self.assetStats = await statsTask
            self.latestVersion = await versionTask?.releaseVersion

            serverPhase = .loaded(())
        } catch {
            serverPhase = .failed(
                (error as? APIError)?.errorDescription ?? error.localizedDescription)
        }
    }

    /// Versi aplikasi ini, dari Info.plist.
    var appVersion: String {
        let short = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String
        return build.map { "\(short) (\($0))" } ?? short
    }

    var isUpdateAvailable: Bool {
        guard let latestVersion, let currentVersion = serverInfo?.version,
              let latest = ServerReleaseVersion(latestVersion),
              let current = ServerReleaseVersion(currentVersion)
        else { return false }
        return current < latest
    }

    func refreshCacheSize() async {
        cacheSize = await ImageCache.shared.diskCacheSize()
    }

    func clearCache() async {
        await ImageCache.shared.clear()
        await refreshCacheSize()
    }

    func updateTheme(_ theme: String) {
        selectedTheme = theme
        UserDefaults.standard.set(theme, forKey: Self.themeKey)
    }

    func updateGridColumns(_ columns: Int) {
        gridColumns = columns
        UserDefaults.standard.set(columns, forKey: Self.gridColumnsKey)
    }
}
