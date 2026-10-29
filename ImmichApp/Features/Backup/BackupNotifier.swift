import Foundation
import Observation
import UserNotifications

/// Pemberitahuan sistem selama pencadangan berjalan.
///
/// **Kenapa ini perlu ada sama sekali.** Unggahan yang paling penting justru
/// yang tidak dilihat siapa pun: tugas latar yang dijalankan iOS saat aplikasinya
/// tertutup. Tanpa pemberitahuan, satu-satunya cara mengetahui hasilnya adalah
/// membuka aplikasi dan menebak dari angka yang berubah.
///
/// **Dua jenis, dan bedanya disengaja.** Kemajuan bersifat `passive`: masuk ke
/// Notification Center tanpa membangunkan layar, tanpa suara, dan menimpa
/// dirinya sendiri karena memakai identifier yang sama. Penyelesaian bersifat
/// biasa: itu satu-satunya yang benar-benar layak mengganggu, dan hanya terjadi
/// sekali per putaran.
@MainActor
@Observable
final class BackupNotifier: NSObject {
    static let shared = BackupNotifier()

    private nonisolated static let progressID = "backup.progress"
    private nonisolated static let completionID = "backup.completed"

    /// Kemajuan diterbitkan paling cepat setiap sekian detik.
    ///
    /// Satu pemberitahuan per berkas berarti ratusan penulisan ke pusat
    /// pemberitahuan untuk satu putaran — pekerjaan yang tidak sepadan, dan
    /// angka yang berkedip terlalu cepat untuk dibaca.
    private static let minimumInterval: TimeInterval = 3

    private var lastPostedAt: Date?
    private var isAuthorized = false
    private var lastQueuePresentationKey: String?

    /// Dua tahap deep-link disimpan terpisah supaya Library yang sudah dibangun
    /// di tab tidak dapat menghabiskan permintaan sebelum MainTab sempat pindah.
    private(set) var shouldSelectLibrary = false
    private(set) var shouldOpenBackup = false

    private override init() {
        super.init()
        UNUserNotificationCenter.current().delegate = self
    }

    func requestOpenBackup() {
        shouldSelectLibrary = true
        shouldOpenBackup = true
    }

    func didSelectLibrary() {
        shouldSelectLibrary = false
    }

    func didOpenBackup() {
        shouldOpenBackup = false
    }

    /// - Parameter prompt: boleh memunculkan dialog izin sistem kalau belum
    ///   pernah ditanyakan.
    ///
    /// **Satu pintu, bukan dua.** Versi sebelumnya memisahkan "minta izin" dan
    /// "baca izin", dan pemisahan itu punya lubang: dialognya HANYA muncul pada
    /// detik sakelar Enable Backup dinyalakan. Siapa pun yang sakelarnya sudah
    /// menyala sejak versi sebelumnya tidak pernah ditanya, statusnya menetap di
    /// `notDetermined`, dan tidak ada satu pun pemberitahuan yang pernah keluar
    /// — tanpa satu pun petunjuk kenapa.
    ///
    /// Sekarang pembukaan aplikasi ikut boleh bertanya, TAPI hanya kalau
    /// pencadangan memang menyala. Syarat itu yang menjaganya tetap sopan:
    /// dialog izin cuma mengejutkan kalau muncul untuk sesuatu yang tidak pernah
    /// diminta, dan menyalakan pencadangan adalah permintaan itu.
    ///
    /// Status tetap dibaca ulang tiap kali karena izin bisa dicabut dari
    /// Settings — jawaban kemarin tidak boleh dipercaya begitu saja.
    func ensureAuthorization(prompt: Bool) async {
        let current = await status()
        if current == .notDetermined, prompt {
            isAuthorized = (try? await UNUserNotificationCenter.current()
                .requestAuthorization(options: [.alert, .sound])) ?? false
            return
        }
        switch current {
        case .authorized, .provisional, .ephemeral:
            isAuthorized = true
        default:
            isAuthorized = false
        }
    }

    private func status() async -> UNAuthorizationStatus {
        await UNUserNotificationCenter.current().notificationSettings()
            .authorizationStatus
    }

    // MARK: - Kemajuan

    /// Queue dan notification memakai snapshot identik. Ini penting pada cold
    /// launch: angka tidak dibangun ulang dari variabel putaran yang sudah
    /// hilang bersama proses sebelumnya.
    func update(queue: BackupQueueSnapshot) {
        guard queue.total > 0 else {
            clearProgress()
            lastQueuePresentationKey = nil
            return
        }

        if queue.unfinished == 0 {
            lastQueuePresentationKey = nil
            if queue.completionNotificationPending {
                finish(uploaded: queue.completed, failed: queue.failed)
            } else {
                clearProgress()
            }
            return
        }

        UNUserNotificationCenter.current().removeDeliveredNotifications(
            withIdentifiers: [Self.completionID])

        guard let presentation = queue.presentation else { return }
        let force = presentation.key != lastQueuePresentationKey
        lastQueuePresentationKey = presentation.key
        post(title: presentation.title, body: presentation.body, force: force)
    }

    private func post(title: String, body: String, force: Bool) {
        guard isAuthorized else { return }
        let now = Date()
        if !force, let last = lastPostedAt, now.timeIntervalSince(last) < Self.minimumInterval {
            return
        }
        lastPostedAt = now

        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        // `passive`: masuk daftar, tapi tidak menyalakan layar dan tidak
        // berbunyi. Inilah tingkat yang memang dibuat untuk kemajuan.
        content.interruptionLevel = .passive

        add(content, id: Self.progressID)
    }

    // MARK: - Selesai

    private func finish(uploaded: Int, failed: Int) {
        clearProgress()
        guard isAuthorized, uploaded > 0 || failed > 0 else { return }

        // Tanpa markup infleksi `^[…](inflect: true)`.
        //
        // Markup itu hanya diproses kalau kalimatnya melewati katalog string
        // dengan Automatic Grammar Agreement. Di sini tidak — jadi yang muncul
        // di layar kunci adalah markupnya sendiri, apa adanya: "^[1 item]
        // (inflect: true) backed up". Bentuk jamaknya ditulis tangan saja.
        let content = UNMutableNotificationContent()
        if failed == 0 {
            content.title = String(localized: "Backup Complete")
            content.body = uploaded == 1
                ? String(localized: "1 item backed up")
                : String(localized: "\(uploaded) items backed up")
        } else {
            content.title = String(localized: "Backup Finished with Errors")
            content.body = failed == 1
                ? String(localized: "\(uploaded) uploaded, 1 failed")
                : String(localized: "\(uploaded) uploaded, \(failed) failed")
        }

        add(content, id: Self.completionID)
    }

    /// Dipanggil juga saat putaran BERHENTI di tengah — jaringan berpindah, atau
    /// sistem menghentikan tugas latarnya. Kemajuan yang membeku di "12 of 40"
    /// selamanya lebih membingungkan daripada tidak ada apa-apa.
    func clearProgress() {
        lastQueuePresentationKey = nil
        let center = UNUserNotificationCenter.current()
        center.removeDeliveredNotifications(withIdentifiers: [Self.progressID])
        center.removePendingNotificationRequests(withIdentifiers: [Self.progressID])
    }

    /// Menghapus hasil terminal yang sudah tidak sesuai dengan ledger, misalnya
    /// setelah kegagalan untuk foto yang telah dihapus dibersihkan dari queue.
    func clearCompletion() {
        let center = UNUserNotificationCenter.current()
        center.removeDeliveredNotifications(withIdentifiers: [Self.completionID])
        center.removePendingNotificationRequests(withIdentifiers: [Self.completionID])
    }

    /// Trigger `nil` berarti SEKARANG. Identifier yang sama menimpa yang lama,
    /// jadi yang tersisa di pusat pemberitahuan selalu satu baris, bukan riwayat.
    private func add(_ content: UNMutableNotificationContent, id: String) {
        content.userInfo = ["destination": "backup"]
        let request = UNNotificationRequest(identifier: id, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }
}

extension BackupNotifier: UNUserNotificationCenterDelegate {
    /// Tanpa ini, pemberitahuan saat aplikasi sedang dibuka TIDAK diperlihatkan
    /// sama sekali — itu bawaan iOS.
    ///
    /// Yang mendapat SPANDUK hanya penyelesaian. Kemajuan tetap dikirim, tapi
    /// lewat `.list` — masuk ke Notification Center dan Lock Screen, tanpa
    /// menutupi layar.
    ///
    /// Bedanya disengaja. Sepanjang unggahan berjalan, angka yang sama sudah
    /// tergambar di layar Backup; spanduk yang menutupinya tiap beberapa detik
    /// untuk mengulanginya adalah gangguan, bukan kabar. Tapi mengembalikan `[]`
    /// seperti sebelumnya berarti kemajuan itu tidak muncul DI MANA PUN selagi
    /// aplikasinya dibuka — dan tidak ada yang terlihat sulit dibedakan dari
    /// tidak ada yang bekerja.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        notification.request.identifier == BackupNotifier.completionID
            ? [.banner, .sound, .list]
            : [.list]
    }

    /// Ketukan pada pemberitahuannya membuka layar Backup.
    ///
    /// Yang dicatat cuma permintaannya; yang mengantar `MainTabView` dan
    /// `LibraryView`. Pembagian itu perlu karena tujuannya berada di dalam tab
    /// Library — jadi ada dua hal yang harus terjadi berurutan, dan keduanya
    /// milik view, bukan milik lapisan pemberitahuan.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        let id = response.notification.request.identifier
        guard id == BackupNotifier.progressID || id == BackupNotifier.completionID
        else { return }
        await MainActor.run { BackupNotifier.shared.requestOpenBackup() }
    }
}
