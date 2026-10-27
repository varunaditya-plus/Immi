import SwiftUI
import TipKit
import UIKit

/// Ada untuk panggilan sistem yang tidak punya padanan langsung di SwiftUI.
///
/// Saat transfer latar selesai sementara aplikasinya sudah tidak berjalan,
/// sistem meluncurkannya kembali dan memanggil metode di bawah. SwiftUI tidak
/// menyediakan jalur untuk itu — `.onOpenURL`, `.backgroundTask`, dan
/// `scenePhase` semuanya tentang hal lain. Delegate ini juga mendaftarkan
/// `AppSceneDelegate`, karena quick action sekarang dikirim lewat lifecycle
/// UIScene, bukan launch options UIApplication.
final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        let launchedAt = Date()
        NetworkResponseCache.clear()
        // File original yang disiapkan untuk share sheet harus bersifat
        // sementara. Bersihkan sisa crash/versi lama sebelum membuat yang baru.
        TemporaryMediaStore.cleanupAfterLaunch()

        // Delegate notifikasi harus terpasang sebelum launch selesai agar tap
        // notifikasi cold-start tidak hilang sebelum SwiftUI sempat dibangun.
        let notifier = BackupNotifier.shared
        BackupUploader.shared.reconnect()
        Task { @MainActor in
            await BackupUploader.shared.cleanupOrphanedFiles(olderThan: launchedAt)
            await ImageCache.shared.enforceDiskLimit()
            await notifier.ensureAuthorization(prompt: false)
            await BackupService.shared.restoreBackgroundLifecycle()
        }

        return true
    }

    func application(
        _ application: UIApplication,
        configurationForConnecting connectingSceneSession: UISceneSession,
        options: UIScene.ConnectionOptions
    ) -> UISceneConfiguration {
        let configuration = UISceneConfiguration(
            name: nil,
            sessionRole: connectingSceneSession.role)
        if connectingSceneSession.role == .windowApplication {
            configuration.delegateClass = AppSceneDelegate.self
        }
        return configuration
    }

    func application(
        _ application: UIApplication,
        handleEventsForBackgroundURLSession identifier: String,
        completionHandler: @escaping () -> Void
    ) {
        guard identifier == BackupUploader.sessionIdentifier else {
            completionHandler()
            return
        }
        // Disimpan, BUKAN dipanggil sekarang. iOS menuntutnya dipanggil setelah
        // semua delegate selesai menyampaikan hasilnya — memanggilnya lebih awal
        // berarti melapor siap sebelum catatannya tertulis.
        // Tanpa pembungkus `Task`: `UIApplicationDelegate` sudah terikat main
        // actor, jadi menundanya satu giliran hanya membuka jeda tempat sesi
        // latar bisa lebih dulu memanggil `urlSessionDidFinishEvents` dan
        // menemukan handler-nya masih nil.
        BackupUploader.shared.backgroundCompletion = completionHandler
        BackupUploader.shared.reconnect()
    }
}

/// Penerima quick action berbasis UIScene untuk cold start dan saat aplikasi
/// sudah berjalan. SwiftUI tetap membuat serta mengelola window-nya; delegate
/// ini hanya menangani event scene yang belum punya modifier SwiftUI.
final class AppSceneDelegate: NSObject, UIWindowSceneDelegate {
    func sceneDidEnterBackground(_ scene: UIScene) {
        NetworkResponseCache.clear()
    }

    func scene(
        _ scene: UIScene,
        willConnectTo session: UISceneSession,
        options connectionOptions: UIScene.ConnectionOptions
    ) {
        guard let shortcutItem = connectionOptions.shortcutItem else { return }
        AppNavigation.shared.handle(shortcutItem)
    }

    func windowScene(
        _ windowScene: UIWindowScene,
        performActionFor shortcutItem: UIApplicationShortcutItem,
        completionHandler: @escaping (Bool) -> Void
    ) {
        AppNavigation.shared.handle(shortcutItem)
        completionHandler(true)
    }
}

@main
struct ImmichApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @Environment(\.scenePhase) private var scenePhase
    @State private var session = SessionManager()

    init() {
        try? Tips.configure([.displayFrequency(.immediate)])
        // Pendaftaran tugas latar harus terjadi SEBELUM peluncuran selesai.
        // `BGTaskScheduler` menegakkan itu dengan keras: mendaftar belakangan
        // menjatuhkan aplikasinya, bukan sekadar gagal.
        BackupScheduler.register()
    }

    var body: some Scene {
        WindowGroup {
            AppRouter()
                .environment(session)
                .task {
                    await session.restore()
                    SharedUploadService.shared.processPending(session: session)
                }
                .onOpenURL { AppNavigation.shared.handle($0) }
                .onChange(of: scenePhase) { _, phase in
                    switch phase {
                    case .active:
                        LocalPhotoLibrary.shared.refreshAuthorizationStatus()
                        // INILAH tulang punggung pencadangan di iOS, bukan tugas
                        // latarnya. Yang benar-benar bisa diandalkan adalah saat
                        // pengguna membuka aplikasinya sendiri; sisanya bonus.
                        BackupService.shared.configure(session: session)
                        SharedUploadService.shared.processPending(session: session)
                        // Menyambung kembali ke transfer yang mungkin masih
                        // berjalan sejak sesi sebelumnya — sistem menyimpannya,
                        // dan tanpa ini hasilnya tidak pernah terbaca.
                        BackupUploader.shared.reconnect()
                        guard BackupService.shared.isEnabled else { return }
                        BackupScheduler.schedule()
                        Task {
                            await BackupService.shared.restoreBackgroundLifecycle()
                            await BackupService.shared.prepare()
                            BackupService.shared.start()
                        }
                    case .background:
                        BackupScheduler.schedule()
                    default:
                        break
                    }
                }
        }

        // Hierarchy khusus yang hanya dibuat ketika sistem menjalankan app di
        // Assistive Access. Control SwiftUI native di dalam scene ini mendapat
        // style Row/Grid, ukuran tombol, dan navigation chrome dari iOS.
        AssistiveAccess {
            AssistiveAccessRouter()
                .environment(session)
                .task { await session.restore() }
        }
    }
}
