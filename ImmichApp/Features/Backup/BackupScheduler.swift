import BackgroundTasks
import Foundation

/// Mendaftarkan dan menjadwalkan pencadangan latar.
///
/// **Apa yang sebenarnya dijanjikan iOS di sini: tidak banyak.** Yang bisa
/// dilakukan aplikasi hanyalah MENGAJUKAN permintaan; sistem yang memutuskan
/// kapan — atau apakah — permintaan itu dipenuhi, berdasarkan kebiasaan
/// pemakaian, baterai, dan jaringan. Aplikasi Immich resmi menyatakannya apa
/// adanya di dokumentasinya, dan layar Backup di sini menyatakannya juga.
///
/// `BGProcessingTask`, bukan `BGAppRefreshTask`: yang kedua diberi waktu sekitar
/// 30 detik, dan 30 detik tidak cukup bahkan untuk satu video. Yang pertama
/// dijalankan lebih jarang tapi diberi waktu menit-menitan, dan bisa meminta
/// syarat jaringan secara eksplisit.
enum BackupScheduler {
    /// DUA pengenal, bukan satu — sama seperti aplikasi Immich resmi, yang
    /// mendaftarkan `…background.refreshUpload` dan `…background.processingUpload`.
    ///
    /// Keduanya punya antrean penjadwalan SENDIRI-SENDIRI di iOS, dengan
    /// perhitungan yang berbeda. Mendaftarkan keduanya berarti dua kesempatan
    /// yang tidak saling meniadakan, bukan satu kesempatan yang dihitung dua
    /// kali.
    ///
    /// - `refresh` (`BGAppRefreshTask`): sering, tapi jatahnya hanya sekitar 30
    ///   detik. Dulu itu terlalu pendek untuk apa pun. Sekarang tidak: yang
    ///   dikerjakan cuma memindai album dan MENYERAHKAN unggahannya ke sesi
    ///   latar — transfernya sendiri urusan `nsurlsessiond`, yang tidak peduli
    ///   jatah waktu aplikasi ini sudah habis.
    /// - `processing` (`BGProcessingTask`): jarang, tapi menit-menitan. Inilah
    ///   yang biasanya berbunyi tengah malam — iOS menjalankannya saat perangkat
    ///   sedang mengisi daya, diam, dan tersambung Wi‑Fi.
    static let refreshIdentifier = "app.immich.backup.refresh"
    static let processingIdentifier = "app.immich.backup.processing"

    /// Refresh dan processing dapat diberikan iOS pada waktu yang berdekatan.
    /// Satu scan saja yang boleh hidup; duanya membaca pustaka dan antrean yang
    /// sama, sehingga menjalankan keduanya tidak menambah pekerjaan berguna.
    @MainActor private static var isRunning = false

    /// HARUS dipanggil sebelum aplikasi selesai diluncurkan.
    ///
    /// `BGTaskScheduler` menuntut setiap pengenal terdaftar sejak awal; mendaftar
    /// belakangan bukan sekadar tidak berhasil — ia menjatuhkan aplikasinya.
    static func register() {
        for identifier in [refreshIdentifier, processingIdentifier] {
            BGTaskScheduler.shared.register(
                forTaskWithIdentifier: identifier, using: nil
            ) { task in
                handle(task)
            }
        }
    }

    /// Mengajukan giliran berikutnya.
    ///
    /// Dipanggil ulang setiap aplikasi masuk latar DAN di awal tiap tugas latar:
    /// satu permintaan hanya berlaku sekali, jadi rantainya harus disambung
    /// sendiri atau berhenti setelah giliran pertama.
    ///
    /// `@MainActor` karena ia membaca `BackupService.isEnabled`, dan layanan itu
    /// terikat main actor. Handler milik `BGTaskScheduler` TIDAK — ia dipanggil
    /// di antrean sistem, jadi pemanggilan dari sana harus lewat `Task
    /// { @MainActor in … }`, bukan langsung.
    @MainActor
    static func schedule() {
        guard BackupService.shared.isEnabled || BackupService.shared.hasPendingRequestedUploads else { return }

        let processing = BGProcessingTaskRequest(identifier: processingIdentifier)
        processing.requiresNetworkConnectivity = true
        // Daya luar TIDAK diwajibkan. Mewajibkannya membuat pencadangan hanya
        // terjadi saat mengisi daya — benar untuk kerja berat berjam-jam, tapi
        // terlalu ketat untuk mengunggah beberapa foto baru.
        processing.requiresExternalPower = false
        processing.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60)

        let refresh = BGAppRefreshTaskRequest(identifier: refreshIdentifier)
        // Sama dengan Immich iOS: refresh diberi kesempatan lebih awal, tetapi
        // tanggal ini hanya batas TERAWAL—iOS tetap memilih waktu sebenarnya.
        refresh.earliestBeginDate = Date(timeIntervalSinceNow: 5 * 60)

        // Gagal menjadwalkan bukan kondisi luar biasa: simulator tidak
        // mendukungnya sama sekali, dan sistem menolak kalau Background App
        // Refresh dimatikan pengguna. Keduanya sah, dan keduanya tidak boleh
        // menghentikan apa pun — unggahan saat aplikasi dibuka tetap jalan.
        try? BGTaskScheduler.shared.submit(processing)
        try? BGTaskScheduler.shared.submit(refresh)
    }

    @MainActor
    static func cancel() {
        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: refreshIdentifier)
        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: processingIdentifier)
    }

    private static func handle(_ task: BGTask) {
        let work = Task { @MainActor in
            guard !isRunning else {
                task.setTaskCompleted(success: false)
                return
            }
            isRunning = true
            defer { isRunning = false }

            // Giliran berikutnya diajukan DULU, sebelum kerja apa pun. Kalau
            // sistem menghentikan tugas ini di tengah jalan, rantainya sudah
            // tersambung.
            schedule()

            // `continueInBackground`, bukan `prepare` + `start` langsung: proses
            // yang dijalankan sistem untuk tugas latar belum tentu punya sesi
            // yang sudah disuntikkan dari mana pun.
            await BackupService.shared.continueInBackground()
            await BackupService.shared.waitUntilFinished()
            task.setTaskCompleted(success: !Task.isCancelled)
        }

        // Sistem memanggil ini saat waktunya habis, dan menuntut aplikasinya
        // berhenti. Berhenti dengan patuh menjaga jatah giliran berikutnya;
        // tidak berhenti membuatnya dihentikan paksa, dan giliran berikutnya
        // jadi makin jarang — atau tidak ada sama sekali.
        //
        // Yang memanggil `setTaskCompleted` tetap `work` di atas: `stop()`
        // membatalkan unggahannya, `waitUntilFinished` pulang, lalu baris
        // terakhirnya berjalan dengan `success: false`.
        task.expirationHandler = {
            work.cancel()
            Task { @MainActor in BackupService.shared.stop() }
        }
    }
}
