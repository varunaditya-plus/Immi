import CryptoKit
import Foundation
import UIKit

enum BackupUploadPhase: String, Codable, Sendable {
    case primaryAsset
    case livePhotoMotion
}

/// State minimum yang harus selamat ketika proses aplikasi dihentikan di antara
/// dua tahap upload Live Photo. `URLSessionTask.taskDescription` disimpan oleh
/// `nsurlsessiond`, sehingga konteks ini tetap tersedia saat iOS meluncurkan
/// proses baru hanya untuk menyampaikan hasil motion video.
struct BackupUploadTaskContext: Codable, Equatable, Sendable {
    let phase: BackupUploadPhase
    let localIdentifier: String
    let checksum: String
    let bodyPath: String
    // Older task descriptions still decode for temporary-file cleanup, but
    // cannot be attributed to an account and must not update its backup state.
    var ownership: BackupUploadOwnership? = nil
    // Bind a rejected upload to its credentials without persisting another token copy.
    var credentialFingerprint: String? = nil
    /// Persisted in URLSession so cancellation remains a requeue operation
    /// even when the process exits before its completion callback arrives.
    var isStorageRecovery: Bool? = nil

    var encoded: String {
        guard let data = try? JSONEncoder().encode(self) else { return "" }
        return String(decoding: data, as: UTF8.self)
    }

    static func credentialFingerprint(for headers: [String: String]) -> String? {
        let credentials = headers.compactMap { name, value -> String? in
            let name = name.lowercased()
            guard name == "authorization" || name == "x-api-key" else { return nil }
            return "\(name):\(value)"
        }.sorted()
        guard !credentials.isEmpty else { return nil }
        return SHA256.hash(data: Data(credentials.joined(separator: "\n").utf8))
            .map { String(format: "%02x", $0) }.joined()
    }

    static func decode(_ value: String?) -> Self? {
        guard let value else { return nil }
        if let data = value.data(using: .utf8),
           let context = try? JSONDecoder().decode(Self.self, from: data) {
            return context
        }

        // Task versi sebelum C4 masih dapat selesai setelah aplikasi di-update.
        // Format lamanya: localIdentifier, checksum, bodyPath.
        let legacy = value.components(separatedBy: "\u{1}")
        guard legacy.count == 3 else { return nil }
        return Self(
            phase: .primaryAsset,
            localIdentifier: legacy[0],
            checksum: legacy[1],
            bodyPath: legacy[2])
    }
}

enum BackupUploadFailureDisposition: Equatable, Sendable {
    case retryNetwork
    case retryServer
    case authenticationRequired
    case permanent
}

extension BackupUploadFailureDisposition {
    static func classify(_ error: Error) -> Self {
        if let urlError = error as? URLError {
            switch urlError.code {
            case .notConnectedToInternet, .networkConnectionLost,
                 .cannotConnectToHost, .cannotFindHost, .timedOut,
                 .dataNotAllowed, .internationalRoamingOff, .dnsLookupFailed,
                 .resourceUnavailable, .backgroundSessionWasDisconnected,
                 .cancelled, .fileDoesNotExist:
                return .retryNetwork
            case .userAuthenticationRequired, .userCancelledAuthentication:
                return .authenticationRequired
            default:
                return .retryServer
            }
        }

        if let apiError = error as? APIError {
            switch apiError {
            case .unauthorized:
                return .authenticationRequired
            case .notConnected:
                return .retryNetwork
            case .server(let status, _):
                if status == 401 { return .authenticationRequired }
                if status == 408 || status == 425 || status == 429 || status >= 500 {
                    return .retryServer
                }
                return .permanent
            case .invalidURL, .decoding:
                return .permanent
            case .unknown:
                return .retryServer
            }
        }
        return .retryServer
    }
}

/// Unggahan yang berjalan terus setelah aplikasinya ditutup.
///
/// **Kenapa BUKAN Background App Refresh.** `BGProcessingTask` — yang sudah ada
/// di `BackupScheduler` — hanya memberi aplikasi ini beberapa menit sesekali,
/// dan menit-menit itu habis jauh sebelum satu pustaka foto selesai naik. Yang
/// benar-benar bisa bekerja tanpa aplikasinya hidup adalah `URLSession` LATAR:
/// unggahannya diserahkan ke `nsurlsessiond`, daemon milik sistem, yang
/// meneruskannya meski proses aplikasi ini sudah lama tidak ada. Ketika selesai,
/// sistem MELUNCURKAN kembali aplikasi ini di latar untuk memberitahukan
/// hasilnya.
///
/// **Satu batas yang tidak bisa disiasati siapa pun.** Kalau pengguna menutup
/// paksa aplikasinya dari app switcher, iOS menghentikan seluruh transfernya dan
/// tidak akan meluncurkannya kembali. Itu berlaku untuk semua aplikasi, termasuk
/// Immich resmi. Menutup aplikasi dengan cara biasa — tombol Home, berpindah
/// aplikasi, layar mati — tidak termasuk; itu justru keadaan yang dilayani di
/// sini.
///
/// Konsekuensinya pada bentuk kode: tidak ada `async/await` dan tidak ada
/// completion handler. Sesi latar hanya bekerja lewat delegate, karena
/// jawabannya bisa datang di proses yang BERBEDA dari yang mengirimkannya.
final class BackupUploader: NSObject {
    @MainActor static let shared = BackupUploader()

    static let sessionIdentifier = "app.immich.backup.upload"
    @MainActor private var isRecoveringStorage = false

    /// Diisi `AppDelegate` saat sistem meluncurkan aplikasi ini hanya untuk
    /// menyampaikan hasil transfer. WAJIB dipanggil setelah semua delegate
    /// selesai — kalau tidak, iOS mencatat aplikasi ini sebagai yang menggantung
    /// dan memperlambat penjadwalan berikutnya.
    var backgroundCompletion: (() -> Void)?

    /// Badan jawaban per task, dirakit dari potongan.
    ///
    /// Sesi latar menyerahkan datanya lewat `didReceive data`, bukan sekaligus
    /// di akhir — dan id aset yang kita butuhkan ada di dalamnya.
    private var responses: [Int: Data] = [:]
    private let lock = NSLock()
    /// `urlSessionDidFinishEvents` dapat datang sesaat setelah callback motion
    /// video, sementara tahap foto utamanya masih sedang dirakit di Task async.
    /// Group ini mencegah completion handler background dipanggil terlalu awal.
    private let completionHandlers = DispatchGroup()

    private lazy var session: URLSession = {
        let config = URLSessionConfiguration.background(
            withIdentifier: Self.sessionIdentifier)
        // Sistem BOLEH meluncurkan aplikasi ini kembali untuk menyampaikan
        // hasilnya. Tanpa ini transfernya tetap jalan, tapi catatannya baru
        // tertulis saat pengguna kebetulan membuka aplikasinya lagi.
        config.sessionSendsLaunchEvents = true
        // Saat task dibuat oleh BGTask, iOS memperlakukannya sebagai
        // discretionary dan dapat menunggu Wi‑Fi/daya. Saat dibuat di foreground
        // nilainya false menjaga tombol backup tetap responsif.
        config.isDiscretionary = false
        config.allowsCellularAccess = true
        // Percobaan ulang diserahkan ke sistem: ia tahu kapan jaringannya
        // kembali, dan mencoba lagi sendiri tanpa aplikasinya perlu hidup.
        config.waitsForConnectivity = true
        return URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }()

    /// Menyerahkan satu unggahan ke sistem.
    ///
    /// - Parameter localIdentifier: `PHAsset.localIdentifier` foto asalnya.
    ///   Dititipkan di `taskDescription`, dan itu bukan kemalasan: properti itu
    ///   ikut disimpan bersama task-nya, jadi ia SELAMAT melewati terminasi
    ///   aplikasi. Saat jawabannya datang di proses yang baru diluncurkan, itulah
    ///   satu-satunya cara mengetahui foto mana yang barusan naik — tanpa perlu
    ///   tabel tambahan yang harus dijaga tetap sinkron.
    /// Membuat task dalam keadaan suspended. Pemanggil WAJIB menulis
    /// taskIdentifier ke queue persisten sebelum memanggil `resume()`. Urutan
    /// itu menutup celah terminasi di antara "URLSession sudah bekerja" dan
    /// "aplikasi belum sempat mencatat siapa pemilik task".
    func makeUploadTask(
        _ prepared: BackupRepository.PreparedUpload,
        localIdentifier: String,
        checksum: String,
        allowsCellular: Bool,
        ownership: BackupUploadOwnership,
        phase: BackupUploadPhase = .primaryAsset
    ) throws -> URLSessionUploadTask {
        var request = prepared.request
        // Ditegakkan PER PERMINTAAN, bukan per sesi: satu sesi latar melayani
        // foto dan video sekaligus, sedangkan aturannya berbeda untuk keduanya.
        request.allowsCellularAccess = allowsCellular
        request.allowsExpensiveNetworkAccess = allowsCellular
        // Low Data Mode selalu dihormati; pengguna hanya memilih seluler biasa,
        // bukan memberi izin mengabaikan pembatasan data sistem.
        request.allowsConstrainedNetworkAccess = false

        let context = BackupUploadTaskContext(
            phase: phase,
            localIdentifier: localIdentifier,
            checksum: checksum,
            bodyPath: prepared.bodyFile.path,
            ownership: ownership,
            credentialFingerprint: BackupUploadTaskContext.credentialFingerprint(
                for: request.allHTTPHeaderFields ?? [:]))
        try BackupTemporaryFiles.record(context)
        let task = session.uploadTask(with: request, fromFile: prepared.bodyFile)
        task.taskDescription = context.encoded
        return task
    }

    /// Melanjutkan sesi yang mungkin masih punya transfer berjalan.
    ///
    /// Menyentuh `session` sudah cukup: membuat ulang konfigurasi dengan
    /// identifier yang SAMA membuat sistem mengembalikan task-task lama ke sesi
    /// ini, lengkap dengan `taskDescription`-nya.
    func reconnect() {
        _ = session
    }

    @MainActor
    func cleanupOrphanedFiles(olderThan cutoff: Date) async {
        let tasks = await session.allTasks
        let paths = Set(tasks.compactMap {
            BackupUploadTaskContext.decode($0.taskDescription)?.bodyPath
        })
        let directory = FileManager.default.temporaryDirectory
        await Task.detached(priority: .utility) {
            let activeNames = Set(paths.map { URL(fileURLWithPath: $0).lastPathComponent })
            for context in BackupTemporaryFiles.recordedContexts(in: directory) {
                let name = URL(fileURLWithPath: context.bodyPath).lastPathComponent
                guard !activeNames.contains(name),
                      let body = BackupTemporaryFiles.bodyURL(for: context.bodyPath, in: directory),
                      let modified = try? body.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
                      modified < cutoff else { continue }
                // An absent task does not prove server success. Preserve its
                // last copy when Photos access is missing or restricted.
                _ = try? BackupTemporaryFiles.finish(
                    context, succeeded: false,
                    sourceAvailable: LocalPhotoLibrary.hasReadAccess && LocalPhotoLibrary.assetExists(context.localIdentifier))
            }
            BackupTemporaryFiles.cleanupOrphans(
                in: directory, activeBodyPaths: paths, olderThan: cutoff)
        }.value
    }

    /// Call only after the queue has adopted/persisted the existing tasks.
    /// Cancellation asks URLSession to release its own upload copy; deleting
    /// our multipart alone would leave that copy occupying device storage.
    @MainActor
    func reclaimExcessStaging() async {
        guard !isRecoveringStorage, LocalPhotoLibrary.hasReadAccess,
              let ownership = BackupService.shared.uploadOwnership else { return }
        isRecoveringStorage = true
        defer { isRecoveringStorage = false }
        let tasks = await session.allTasks
        guard !Task.isCancelled, BackupService.shared.uploadOwnership == ownership else { return }
        let localIDs = tasks.compactMap {
            BackupUploadTaskContext.decode($0.taskDescription)?.localIdentifier
        }
        let availableOriginals = await Task.detached(priority: .utility) {
            LocalPhotoLibrary.existingLocalIdentifiers(localIDs)
        }.value
        guard !Task.isCancelled, BackupService.shared.uploadOwnership == ownership else { return }
        let protectedTaskIDs = Set(tasks.compactMap { task -> Int? in
            guard let context = BackupUploadTaskContext.decode(task.taskDescription),
                  !availableOriginals.contains(context.localIdentifier) else { return nil }
            return task.taskIdentifier
        })
        let candidates = tasks.compactMap { task -> BackupStagingPolicy.Upload? in
            guard task.state == .running || task.state == .suspended,
                  let context = BackupUploadTaskContext.decode(task.taskDescription),
                  context.isStorageRecovery != true || protectedTaskIDs.contains(task.taskIdentifier)
            else { return nil }
            let expected = max(0, task.countOfBytesExpectedToSend)
            let fileSize = BackupTemporaryFiles.bodyURL(for: context.bodyPath).flatMap {
                try? $0.resourceValues(forKeys: [.fileSizeKey]).fileSize
            } ?? 0
            let size = max(fileSize, Int(expected))
            let progress = size > 0 ? min(1, Double(task.countOfBytesSent) / Double(size)) : 0
            return .init(taskIdentifier: task.taskIdentifier, bytes: size, progress: progress)
        }
        let retained = BackupStagingPolicy.retainedTaskIDs(
            from: candidates, protectedTaskIDs: protectedTaskIDs)
        for task in tasks {
            guard task.state == .running || task.state == .suspended,
                  var context = BackupUploadTaskContext.decode(task.taskDescription)
            else { continue }
            if retained.contains(task.taskIdentifier) {
                if protectedTaskIDs.contains(task.taskIdentifier), context.isStorageRecovery == true {
                    context.isStorageRecovery = nil
                    task.taskDescription = context.encoded
                }
                continue
            }
            context.isStorageRecovery = true
            task.taskDescription = context.encoded
            // Do not unlink its file until didCompleteWithError acknowledges
            // cancellation. A successful response racing this call still wins.
            task.cancel()
        }
    }

    @MainActor
    func stagingUsage() async -> (activeTasks: Int, bytes: Int) {
        let tasks = await session.allTasks
        let bytes = tasks.reduce(0) { total, task in
            guard let context = BackupUploadTaskContext.decode(task.taskDescription),
                  let url = BackupTemporaryFiles.bodyURL(for: context.bodyPath)
            else { return total + Int(max(0, task.countOfBytesExpectedToSend)) }
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize)
                ?? Int(max(0, task.countOfBytesExpectedToSend))
            return total + size
        }
        return (tasks.count, bytes)
    }

    /// ID PhotoKit yang sudah berada di tangan `nsurlsessiond`.
    ///
    /// Daftar ini bertahan saat proses aplikasi mati. Tanpanya cold launch
    /// background mengantre file yang sama lagi karena `pendingPhotos` hanya RAM.
    @MainActor
    func activeLocalIdentifiers(ownership: BackupUploadOwnership?) async -> Set<String> {
        Set(await activeTasks(ownership: ownership).map(\.context.localIdentifier))
    }

    @MainActor
    func activeTasks(ownership: BackupUploadOwnership?) async -> [BackupActiveTask] {
        let tasks = await session.allTasks
        guard !Task.isCancelled, let ownership,
              BackupService.shared.uploadOwnership == ownership else { return [] }
        var result: [BackupActiveTask] = []
        for task in tasks {
            guard task.state != .completed else { continue }
            guard let context = BackupUploadTaskContext.decode(task.taskDescription),
                  context.ownership == ownership else {
                // Task tanpa identitas tidak mungkin diselesaikan dengan aman
                // dan task suspended semacam ini akan menahan session finish
                // event selamanya. Batalkan; scan PhotoKit akan menemukan aset
                // aslinya kembali jika memang masih perlu diunggah.
                task.cancel()
                continue
            }
            result.append(BackupActiveTask(
                taskIdentifier: task.taskIdentifier,
                context: context,
                isSuspended: task.state == .suspended))
        }
        return result
    }

    @MainActor
    func resumeTasks(identifiers: Set<Int>) async {
        guard !identifiers.isEmpty else { return }
        let tasks = await session.allTasks
        guard !Task.isCancelled else { return }
        for task in tasks where identifiers.contains(task.taskIdentifier) && task.state == .suspended {
            guard let context = BackupUploadTaskContext.decode(task.taskDescription),
                  context.isStorageRecovery != true,
                  BackupService.shared.acceptsUpload(context, taskIdentifier: task.taskIdentifier)
            else { continue }
            task.resume()
        }
    }

    /// Membatalkan transfer untuk satu aset tanpa menyentuh item lain di sesi
    /// latar yang sama. Hasil akhirnya tetap datang lewat delegate, sehingga
    /// queue dapat menyelesaikan state `cancelling` secara konsisten.
    @discardableResult
    @MainActor
    func cancel(localIdentifier: String) async -> Bool {
        guard let ownership = BackupService.shared.uploadOwnership,
              let taskIdentifier = BackupQueueStore.shared.item(id: localIdentifier)?.taskIdentifier
        else { return false }
        let tasks = await session.allTasks
        guard !Task.isCancelled, BackupService.shared.uploadOwnership == ownership else { return false }
        let matching = tasks.filter {
            guard let context = BackupUploadTaskContext.decode($0.taskDescription) else { return false }
            return $0.taskIdentifier == taskIdentifier
                && context.localIdentifier == localIdentifier && context.ownership == ownership
        }
        matching.forEach { $0.cancel() }
        return !matching.isEmpty
    }

    /// Membatalkan transfer yang sudah diserahkan ke `nsurlsessiond`.
    ///
    /// `BackupService.stop()` hanya menghentikan loop pengantrean di proses ini;
    /// task background tetap membawa header akun lama sampai dibatalkan di sini.
    func cancelAll(
        ownership: BackupUploadOwnership?, authHeaders: [String: String]? = nil
    ) async {
        let tasks = await session.allTasks
        let matching = tasks.filter { task in
            let taskOwnership = BackupUploadTaskContext.decode(task.taskDescription)?.ownership
            guard taskOwnership == nil || taskOwnership == ownership else { return false }
            guard taskOwnership != nil, let authHeaders, !authHeaders.isEmpty else { return true }
            return authHeaders.allSatisfy { name, value in
                task.originalRequest?.value(forHTTPHeaderField: name) == value
            }
        }
        matching.forEach { $0.cancel() }

        lock.withLock {
            for task in matching { responses[task.taskIdentifier] = nil }
        }
    }
}

// MARK: - Delegate

extension BackupUploader: URLSessionDataDelegate {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didSendBodyData bytesSent: Int64,
        totalBytesSent: Int64,
        totalBytesExpectedToSend: Int64
    ) {
        guard totalBytesExpectedToSend > 0,
              let context = BackupUploadTaskContext.decode(task.taskDescription)
        else { return }
        Task { @MainActor in
            BackupService.shared.reportUploadProgress(
                context: context,
                taskIdentifier: task.taskIdentifier,
                bytesSent: totalBytesSent,
                totalBytesExpected: totalBytesExpectedToSend)
        }
    }

    func urlSession(
        _ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data
    ) {
        lock.lock()
        defer { lock.unlock() }
        responses[dataTask.taskIdentifier, default: Data()].append(data)
    }

    func urlSession(
        _ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?
    ) {
        lock.lock()
        let body = responses.removeValue(forKey: task.taskIdentifier) ?? Data()
        lock.unlock()

        guard let context = BackupUploadTaskContext.decode(task.taskDescription) else { return }
        let outcome: Result<String, Error>
        if let error {
            outcome = .failure(error)
        } else {
            outcome = Result { try BackupRepository.assetID(from: body, response: task.response) }
        }

        let completedTaskID = task.taskIdentifier
        completionHandlers.enter()
        Task { @MainActor in
            defer { self.completionHandlers.leave() }
            let service = BackupService.shared
            await service.ensureConfigured()
            let succeeded: Bool
            if case .success = outcome { succeeded = true } else { succeeded = false }
            do {
                let preserved = try await Task.detached(priority: .utility) {
                    try BackupTemporaryFiles.finish(
                        context, succeeded: succeeded,
                        sourceAvailable: succeeded || (LocalPhotoLibrary.hasReadAccess && LocalPhotoLibrary.assetExists(context.localIdentifier)))
                }.value
                guard service.acceptsUpload(context, taskIdentifier: completedTaskID) else { return }
                if preserved {
                    service.reportPreservedUpload(
                        localIdentifier: context.localIdentifier, taskIdentifier: completedTaskID)
                    return
                }
            } catch {
                // Do not silently report cleanup success; the receipt protects
                // the file until a later launch can retry filesystem cleanup.
                guard service.acceptsUpload(context, taskIdentifier: completedTaskID) else { return }
                service.reportStorageCleanupFailure(error)
            }
            guard service.acceptsUpload(context, taskIdentifier: completedTaskID) else { return }
            defer { service.refillReadyQueue() }
            if context.isStorageRecovery == true,
               (error as? URLError)?.code == .cancelled {
                service.finishStorageRecovery(
                    localIdentifier: context.localIdentifier,
                    taskIdentifier: completedTaskID)
                return
            }
            let activeTasks = await self.session.allTasks
            guard service.acceptsUpload(context, taskIdentifier: completedTaskID) else { return }
            let remaining = activeTasks.filter { $0.taskIdentifier != completedTaskID }.count
            switch context.phase {
            case .primaryAsset:
                BackupService.shared.finishUpload(
                    context: context,
                    taskIdentifier: completedTaskID,
                    outcome: outcome,
                    remainingBackgroundTasks: remaining)

            case .livePhotoMotion:
                await BackupService.shared.finishLivePhotoMotionUpload(
                    context: context,
                    taskIdentifier: completedTaskID,
                    outcome: outcome,
                    remainingBackgroundTasks: remaining)
            }
        }
    }

    /// Semua yang tertunda sudah disampaikan.
    ///
    /// Ini satu-satunya saat aplikasi ini hidup di latar tanpa diminta siapa
    /// pun, jadi dipakai sekalian untuk MENCARI pekerjaan baru. Foto yang diambil
    /// setelah aplikasinya ditutup tidak dikenal sesi latar — sesi itu cuma
    /// meneruskan apa yang sudah diserahkan padanya. Menyerahkan gelombang
    /// berikutnya di sini membuat rantainya menyambung sendiri: selama masih ada
    /// sisa, tiap penyelesaian membangunkan aplikasi ini untuk mengantre lagi.
    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        Task { @MainActor in
            await withCheckedContinuation { continuation in
                self.completionHandlers.notify(queue: .global(qos: .utility)) {
                    continuation.resume()
                }
            }
            await BackupService.shared.continueInBackground()
            // WAJIB. `continueInBackground` pulang begitu `start()` membuat
            // Task-nya — sebelum satu foto pun benar-benar diserahkan. Tanpa
            // baris ini, seluruh ongkosnya dibayar (memulihkan sesi, mengenumerasi
            // album) lalu handler-nya dipanggil dengan gelombang berikutnya masih
            // kosong: persis akibat yang hendak dicegah.
            await BackupService.shared.waitUntilFinished()
            // Dipanggil TERAKHIR, setelah pengantrean berikutnya selesai. iOS
            // menganggap aplikasi ini boleh disuspend lagi begitu handler-nya
            // dijalankan, dan pekerjaan yang belum sempat diserahkan akan ikut
            // terpotong.
            let completion = self.backgroundCompletion
            self.backgroundCompletion = nil
            completion?()
        }
    }
}
