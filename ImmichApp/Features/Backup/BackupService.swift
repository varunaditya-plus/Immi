import Foundation
import Observation
import Photos

private enum LivePhotoBackupError: LocalizedError {
    case motionResourceMissing
    case primaryResourceMissing
    case sessionUnavailable
    case assetNoLongerLivePhoto

    var errorDescription: String? {
        switch self {
        case .motionResourceMissing:
            String(localized: "The motion part of this Live Photo could not be read.")
        case .primaryResourceMissing:
            String(localized: "The photo part of this Live Photo could not be read.")
        case .sessionUnavailable:
            String(localized: "The upload session is no longer available.")
        case .assetNoLongerLivePhoto:
            String(localized: "This asset is no longer available as a Live Photo.")
        }
    }
}

private struct BackupPersistenceError: LocalizedError {
    var errorDescription: String? {
        String(localized: "Backup is paused because its local upload mapping cannot be saved safely.")
    }
}

private struct BackupAlbumPlacementError: LocalizedError {
    var errorDescription: String? {
        String(localized: "The photo is backed up, but its album could not be resolved. Album placement will retry.")
    }
}

/// Pencadangan otomatis foto perangkat ke server.
///
/// **Apa yang bisa dan tidak bisa dilakukan di iOS.** Aplikasi TIDAK bisa
/// memutuskan kapan tugas latarnya berjalan — sistem yang memilih, berdasarkan
/// kebiasaan pemakaian, baterai, dan jaringan. Immich resmi menuliskannya
/// terang-terangan: "semakin sering kamu membuka aplikasi, semakin sering tugas
/// latarnya berjalan". Jadi tulang punggungnya bukan tugas latar, melainkan
/// unggahan saat aplikasi DIBUKA atau kembali aktif; tugas latar hanya
/// pelengkap yang kadang kebagian giliran.
///
/// Karena itu layar Backup menampilkan angka, bukan janji: berapa yang ada,
/// berapa yang sudah aman, berapa yang belum. Yang belum akan naik pada
/// kesempatan berikutnya, dan pengguna bisa melihat sendiri kapan itu terjadi.
@MainActor
@Observable
final class BackupService {
    static let shared: BackupService = {
        let service = BackupService(dataManager: .shared, queue: .shared)
        service.observeLibraryAndNetwork()
        return service
    }()

    /// Pencadangan dinyalakan pengguna.
    var isEnabled: Bool {
        didSet {
            guard isEnabled != oldValue else { return }
            UserDefaults.standard.set(isEnabled, forKey: Self.enabledKey)
            guard isEnabled else {
                stop()
                BackupScheduler.cancel()
                BackupNotifier.shared.clearProgress()
                if queue.hasPendingUserRequests || hasPendingAlbumPlacements {
                    BackupScheduler.schedule()
                    requestNetworkWake()
                }
                return
            }
            // Izin pemberitahuan diminta TEPAT di sini: pengguna baru saja
            // meminta pekerjaan yang berjalan tanpa dilihat, jadi alasan untuk
            // memberitahunya sudah jelas di layar.
            Task { await BackupNotifier.shared.ensureAuthorization(prompt: true) }
            BackupScheduler.schedule()
            Task { [weak self] in
                await self?.prepare()
                guard !Task.isCancelled else { return }
                self?.start()
            }
        }
    }

    /// Boleh memakai data seluler untuk FOTO.
    ///
    /// Dipisah dari video, seperti Immich resmi, karena selisihnya bukan soal
    /// selera: satu foto beberapa megabyte, satu video bisa ratusan. Banyak
    /// orang rela mengunggah foto lewat seluler dan sama sekali tidak rela
    /// mengunggah video. Bawaannya mati untuk keduanya.
    var cellularPhotos: Bool {
        didSet {
            guard cellularPhotos != oldValue else { return }
            UserDefaults.standard.set(cellularPhotos, forKey: Self.cellularPhotosKey)
            requestNetworkWake()
        }
    }

    /// Boleh memakai data seluler untuk VIDEO.
    var cellularVideos: Bool {
        didSet {
            guard cellularVideos != oldValue else { return }
            UserDefaults.standard.set(cellularVideos, forKey: Self.cellularVideosKey)
            requestNetworkWake()
        }
    }

    /// Menaruh aset yang diunggah ke album server bernama sama dengan album
    /// perangkat asalnya, membuatkannya kalau belum ada.
    var syncAlbums: Bool {
        didSet {
            guard syncAlbums != oldValue else { return }
            UserDefaults.standard.set(syncAlbums, forKey: Self.syncAlbumsKey)
            if syncAlbums {
                resumePendingAlbumPlacements()
                BackupScheduler.schedule()
            }
        }
    }

    /// Seluruh foto unik dari album terpilih.
    private(set) var total = 0
    /// Yang sudah ada di server — diunggah dari sini maupun dari mana pun.
    private(set) var backedUp = 0
    /// Sisanya. Inilah angka yang sebenarnya berarti.
    var remainder: Int { max(0, total - backedUp) }
    private var countedSelectionScanID: UUID?
    private var countedMappingRevision: UUID?
    private var hasRemainingPhotos = false
    private var hasRemainingVideos = false
    private var lastQueueError: String?

    var hasLimitedPhotosAccess: Bool { localLibrary.authorizationStatus == .limited }

    var selectionStatus: BackupSelectionStatus {
        guard !localLibrary.selectedAlbumIDs.isEmpty else { return .noSelection }
        guard localLibrary.isAuthorized else { return .accessRequired }
        guard dataManager.isPersistentStoreAvailable,
              let scan = localLibrary.currentSelectionScanID,
              countedSelectionScanID == scan,
              countedMappingRevision == dataManager.backupMappingRevision else { return .unchecked }
        guard total > 0 else { return .empty }
        return remainder > 0 ? .remaining : .backedUp
    }

    /// Retry messages stay informational when an item leaves its wait state.
    var hasStatusError: Bool {
        guard let lastError else { return false }
        return !failures.isEmpty || lastQueueError != lastError
    }

    private(set) var isUploading = false
    /// Nomor urut yang sedang dikerjakan, untuk bilah kemajuan.
    private(set) var uploadedThisRun = 0
    private(set) var pendingThisRun = 0
    /// Foto yang gagal diunggah pada putaran ini.
    private(set) var failures: [String] = []
    /// Alasan kegagalan TERAKHIR, apa adanya dari server atau sistem.
    private(set) var lastError: String?
    private(set) var lastRunAt: Date?
    private(set) var waitingForNetwork = 0
    private(set) var waitingForICloud = 0
    private(set) var waitingForAuthentication = 0
    private(set) var scheduledForRetry = 0
    private(set) var queueStatusTitle: String?
    private(set) var queueStatusBody: String?
    /// Item persisten yang sedang menunggu, aktif, atau gagal. Layar detail
    /// membaca daftar yang sama dengan scheduler dan notifikasi.
    private(set) var uploadItems: [BackupQueueItem] = []
    /// Progress byte hanya relevan selama proses hidup; lifecycle item sendiri
    /// tetap disimpan di `BackupQueueStore`.
    private(set) var uploadProgressByID: [String: Double] = [:]

    private static let enabledKey = "backup.enabled"
    private static let cellularPhotosKey = "backup.cellularPhotos"
    private static let cellularVideosKey = "backup.cellularVideos"
    private static let syncAlbumsKey = "backup.syncAlbums"

    private var repo: BackupRepository?
    private var albumRepo: AlbumRepository?
    private weak var session: SessionManager?
    private let dataManager: SwiftDataManager
    private let queue: BackupQueueStore
    private let localLibrary: LocalPhotoLibrary
    private let readOriginalFile: @MainActor (String, Bool) async -> (url: URL, filename: String)?
    private let makeAlbumRepository: @MainActor (APIClient) -> AlbumRepository
    private let automaticDiscovery: AutomaticBackupDiscovery
    private let uploadRequests: BackupUploadRequests
    private var task: Task<Void, Never>?
    private var workID: UUID?
    private var networkWakeTask: Task<Void, Never>?
    private var networkWakeID = UUID()
    private struct PreparationClaim {
        let id = UUID()
        let isOwned: Bool
        let ownership: BackupUploadOwnership
        var task: Task<Void, Never>?
    }
    private var preparationClaims: [String: PreparationClaim] = [:]
    private var refillRequested = false
    private var libraryChangeTask: Task<Void, Never>?
    private var retryWakeTask: Task<Void, Never>?
    private var missingTransfers: (ownership: BackupUploadOwnership, items: [BackupQueueItem])?
    private var notificationRevision = 0
    private static let automaticBatchSize = 100
    /// Nama album server → id-nya, supaya album yang sama tidak dicari ulang
    /// untuk setiap foto. Dikosongkan tiap putaran karena album bisa dibuat atau
    /// dihapus dari tempat lain di antara dua putaran.
    private var albumIDsByName: [String: String] = [:]
    private struct AlbumLookup {
        let id: UUID
        let task: Task<String?, Never>
    }
    private var albumLookupOwnership: BackupUploadOwnership?
    private var albumLookups: [String: AlbumLookup] = [:]
    private struct AlbumPlacementWork {
        let id: UUID
        let placement: BackupAlbumPlacement
        let task: Task<Void, Never>
    }
    @ObservationIgnored private var albumPlacementTasks: [String: AlbumPlacementWork] = [:]
    /// Berapa loop pengantrean yang sedang berjalan.
    ///
    /// PENGHITUNG, bukan `Bool`. `stop()` melepas `task` dan mengosongkan
    /// antrean, jadi `start()` berikutnya bisa memulai putaran B selagi loop
    /// putaran A masih tertahan di tengah foto. Dengan sebuah `Bool`, `defer`
    /// milik A akan mematikannya di tengah pengantrean B — membuka kembali
    /// persis lubang yang penanda ini dipasang untuk menutupnya.
    private var enqueueDepth = 0
    /// Hasil transfer lama dapat tiba sesudah logout. Jangan tulis hasil itu ke
    /// database yang sudah menjadi milik sesi berikutnya.
    private var acceptsUploadResults = true
    /// False setelah server menjawab 401. Queue tetap ada, tetapi seluruh task
    /// berhenti membawa token lama sampai pengguna masuk kembali.
    private var hasAuthenticatedSession = true

    init(
        dataManager: SwiftDataManager,
        queue: BackupQueueStore,
        localLibrary: LocalPhotoLibrary? = nil,
        readOriginalFile: @escaping @MainActor (String, Bool) async -> (url: URL, filename: String)? = {
            await LocalPhotoLibrary.shared.originalFile(for: $0, allowsNetworkFallback: $1)
        },
        makeAlbumRepository: @escaping @MainActor (APIClient) -> AlbumRepository = { AlbumRepository(api: $0) }
    ) {
        self.dataManager = dataManager
        self.queue = queue
        self.localLibrary = localLibrary ?? .shared
        self.readOriginalFile = readOriginalFile
        self.makeAlbumRepository = makeAlbumRepository
        automaticDiscovery = AutomaticBackupDiscovery(queue: queue, batchSize: BackupService.automaticBatchSize)
        uploadRequests = BackupUploadRequests(queue: queue)
        isEnabled = UserDefaults.standard.bool(forKey: Self.enabledKey)
        cellularPhotos = UserDefaults.standard.bool(forKey: Self.cellularPhotosKey)
        cellularVideos = UserDefaults.standard.bool(forKey: Self.cellularVideosKey)
        syncAlbums = UserDefaults.standard.bool(forKey: Self.syncAlbumsKey)
        applyQueueSnapshot(notify: false)
    }

    private func observeLibraryAndNetwork() {
        LocalPhotoLibrary.shared.onLibraryChange = { [weak self] in
            self?.handleLibraryChange()
        }
        NetworkMonitor.shared.onPathChange = { [weak self] online, _ in
            self?.handleNetworkChange(isOnline: online)
        }
    }

    var uploadOwnership: BackupUploadOwnership? {
        guard acceptsUploadResults, hasAuthenticatedSession,
              let session, session.isLoggedIn,
              let ownership = queue.ownership,
              session.backupQueueOwner == ownership.owner else { return nil }
        return ownership
    }

    func acceptsUpload(_ context: BackupUploadTaskContext, taskIdentifier: Int) -> Bool {
        guard let ownership = uploadOwnership, context.ownership == ownership else { return false }
        if let currentTask = queue.item(id: context.localIdentifier)?.taskIdentifier {
            return currentTask == taskIdentifier
        }
        return true
    }

    /// Disuntik sekali dari akar aplikasi.
    ///
    /// Layanan ini harus bisa dijangkau tugas latar, yang tidak punya view dan
    /// tidak bisa menerima apa pun lewat environment — karena itu singleton, dan
    /// karena itu sesinya dipasang belakangan.
    func configure(session: SessionManager) {
        guard session.isLoggedIn, session.backupQueueOwner != nil else { return }
        if repo != nil {
            if self.session === session {
                recoverCompletedAlbumPlacements()
                resumePendingAlbumPlacements()
                return
            }
            if self.session?.backupQueueOwner != session.backupQueueOwner { stop() }
        }
        attach(session)
        guard (isEnabled || queue.hasPendingUserRequests), acceptsUploadResults else { return }
        if isEnabled { BackupScheduler.schedule() }
        Task { [weak self] in
            guard let self else { return }
            if self.isEnabled {
                await self.prepare()
                self.start()
            } else {
                self.requestNetworkWake()
            }
        }
    }

    /// Menyiapkan diri sendiri ketika tidak ada yang bisa menyuntikkan apa pun.
    ///
    /// Saat iOS meluncurkan aplikasi ini di latar hanya untuk menyampaikan hasil
    /// transfer, SwiftUI belum tentu membangun satu scene pun — dan `configure`
    /// dipanggil dari sana. Tanpa jalan cadangan ini, unggahan lanjutan di latar
    /// selalu berhenti pada `repo == nil`, diam-diam.
    ///
    /// `SessionManager` sendiri yang tahu cara memulihkan kredensialnya dari
    /// penyimpanan, jadi yang perlu dilakukan hanya membuatnya dan menunggu.
    func ensureConfigured() async {
        guard repo == nil else { return }
        let session = SessionManager()
        let context = session.snapshot
        await session.restore(configureBackup: false)
        // Tugas latar dapat membangunkan proses setelah logout. Jangan membuat
        // repository tanpa sesi lalu mencoba mengantre unggahan anonim.
        guard repo == nil, session.isLoggedIn,
              (try? session.checkCurrent(context)) != nil else { return }
        attach(session)
    }

    private func attach(_ session: SessionManager) {
        self.session = session
        let api = APIClient(session: session)
        repo = BackupRepository(api: api)
        albumRepo = makeAlbumRepository(api)
        acceptsUploadResults = dataManager.isPersistentStoreAvailable
        hasAuthenticatedSession = true
        do {
            if let owner = session.backupQueueOwner {
                _ = try queue.bind(to: owner)
            }
            if missingTransfers?.ownership != queue.ownership { missingTransfers = nil }
            try queue.releaseAuthenticationWaits()
            // Notifikasi terminal ditunda sampai failure lama sempat divalidasi
            // terhadap PhotoKit oleh `prepare()`/restore lifecycle.
            applyQueueSnapshot(notify: false)
        } catch {
            lastError = error.localizedDescription
            acceptsUploadResults = false
        }
        resetAlbumResolution(for: uploadOwnership)
        recoverCompletedAlbumPlacements()
        resumePendingAlbumPlacements()
    }

    /// Dipanggil sejak launch, termasuk cold launch yang hanya terjadi karena
    /// URLSession menyampaikan event. Task sistem direkonsiliasi sebelum scan
    /// baru agar tidak pernah ada dua executor untuk satu aset.
    func restoreBackgroundLifecycle() async {
        BackupUploader.shared.reconnect()
        await ensureConfigured()
        guard let ownership = uploadOwnership else { return }
        do {
            guard try await reconcileBackgroundTasks(ownership: ownership) else { return }
        } catch {
            lastError = error.localizedDescription
            acceptsUploadResults = false
        }
        await pruneUnavailableFailures()
        guard !Task.isCancelled, uploadOwnership == ownership else { return }
        applyQueueSnapshot()
        resumePendingAlbumPlacements()
        if queue.hasPendingUserRequests {
            requestNetworkWake()
        }
    }

    private func handleNetworkChange(isOnline: Bool) {
        guard isOnline else {
            networkWakeTask?.cancel()
            applyQueueSnapshot()
            return
        }
        requestNetworkWake()
    }

    private var networkPolicy: BackupNetworkPolicy {
        BackupNetworkPolicy(isOnline: NetworkMonitor.shared.isOnline,
            isExpensive: NetworkMonitor.shared.isExpensive,
            cellularPhotos: cellularPhotos, cellularVideos: cellularVideos)
    }

    private func requestNetworkWake() {
        networkWakeTask?.cancel()
        let id = UUID()
        networkWakeID = id
        guard isEnabled || queue.hasPendingUserRequests || hasPendingAlbumPlacements else {
            networkWakeTask = nil
            return
        }
        networkWakeTask = Task { [weak self] in
            guard let self else { return }
            defer { if self.networkWakeID == id { self.networkWakeTask = nil } }
            await self.ensureConfigured()
            guard !Task.isCancelled, self.networkWakeID == id,
                  let ownership = self.uploadOwnership else { return }
            await NetworkMonitor.shared.waitUntilReady()
            guard !Task.isCancelled, self.uploadOwnership == ownership,
                  self.repo != nil, self.dataManager.isPersistentStoreAvailable else { return }
            self.recoverCompletedAlbumPlacements()
            self.resumePendingAlbumPlacements()
            do {
                let eligible = try await self.uploadRequests.releaseNetworkWaits(
                    automaticEnabled: self.isEnabled, policy: self.networkPolicy,
                    canProcess: { self.uploadOwnership == ownership },
                    metadata: { await self.photoMetadata(for: $0) })
                guard !Task.isCancelled, self.uploadOwnership == ownership else { return }
                await BackupUploader.shared.requeueBlockedTasks(eligibleIDs: eligible, ownership: ownership)
                guard !Task.isCancelled, self.uploadOwnership == ownership else { return }
            } catch {
                guard !Task.isCancelled, self.uploadOwnership == ownership else { return }
                self.lastError = error.localizedDescription
                self.acceptsUploadResults = false
                return
            }
            self.applyQueueSnapshot()
            self.refillReadyQueue()
            if self.isEnabled { await self.continueInBackground() }
        }
    }

    private func requestQueueRetry() {
        applyQueueSnapshot()
        BackupScheduler.schedule()
        requestNetworkWake()
    }

    var hasPendingRequestedUploads: Bool { queue.hasPendingUserRequests }
    var hasPendingAlbumPlacements: Bool { syncAlbums && !queue.pendingAlbumPlacements.isEmpty }
    /// Mencari pekerjaan baru, lalu menyerahkannya.
    ///
    /// **Inilah yang membuat pencadangan bisa berlanjut tanpa aplikasi dibuka.**
    /// Sesi latar hanya meneruskan transfer yang SUDAH diserahkan padanya; foto
    /// yang baru diambil setelah aplikasinya ditutup tidak dikenalnya sama
    /// sekali. Yang bisa menemukannya cuma kode ini, dan kode ini hanya berjalan
    /// saat iOS memberi aplikasi ini kesempatan hidup sebentar.
    ///
    /// Ada dua kesempatan semacam itu, dan keduanya dipakai: tugas latar
    /// terjadwal (`BackupScheduler`), dan momen tepat setelah sesi latar selesai
    /// menyampaikan hasilnya. Yang kedua membuatnya berantai — selama masih ada
    /// sisa, tiap penyelesaian membangunkan aplikasi ini untuk mengantre lagi.
    func continueInBackground() async {
        guard isEnabled || queue.hasPendingUserRequests || hasPendingAlbumPlacements else { return }
        await ensureConfigured()
        guard !Task.isCancelled else { return }
        recoverCompletedAlbumPlacements()
        resumePendingAlbumPlacements()
        guard isEnabled || queue.hasPendingUserRequests || hasPendingAlbumPlacements,
              repo != nil, !Task.isCancelled else { return }
        if !isEnabled {
            refillReadyQueue()
            return
        }
        await NetworkMonitor.shared.waitUntilReady()
        guard !Task.isCancelled else { return }
        await prepare()
        guard !Task.isCancelled else { return }
        start()
    }

    /// PhotoKit memberi perubahan ketika aplikasi aktif/diberi waktu eksekusi.
    /// Digabung satu detik karena satu impor dapat menghasilkan banyak callback.
    private func handleLibraryChange() {
        guard isEnabled || queue.hasPendingUserRequests else { return }
        libraryChangeTask?.cancel()
        libraryChangeTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled, let self else { return }
            await self.prepare()
            guard !Task.isCancelled else { return }
            if self.isEnabled { self.start() }
            else { self.requestNetworkWake() }
            BackupScheduler.schedule()
        }
    }

    // MARK: - Hitungan

    /// Menghitung ulang tiga angka di layar Backup.
    ///
    /// Murah: satu enumerasi daftar yang sudah ada di memori, plus satu kueri
    /// id yang sudah berpasangan. Tidak ada byte foto yang dibaca di sini.
    func refreshCounts() {
        let photos = localLibrary.photos
        let uploaded = dataManager.uploadedLocalIdentifiers()
        total = photos.count
        var remainingPhotos = false
        var remainingVideos = false
        backedUp = photos.reduce(into: 0) { count, photo in
            if uploaded.contains(photo.id) { count += 1 }
            else if photo.isVideo { remainingVideos = true }
            else { remainingPhotos = true }
        }
        hasRemainingPhotos = remainingPhotos
        hasRemainingVideos = remainingVideos
        countedSelectionScanID = localLibrary.currentSelectionScanID
        countedMappingRevision = dataManager.backupMappingRevision
    }

    /// Memastikan daftar foto perangkat sudah terbaca, lalu menghitung ulang.
    ///
    /// Tanpa ini ketiga angkanya nol setiap kali layar Backup dibuka sebelum tab
    /// Photos pernah disentuh — dan nol yang berarti "belum dibaca" tidak bisa
    /// dibedakan dari nol yang berarti "semuanya sudah aman". Dua keadaan yang
    /// berlawanan, angka yang sama.
    ///
    func prepare() async {
        // Izin belum pernah diberikan DAN belum ada album dipilih berarti tidak
        // ada apa pun yang bisa dibaca — dan `load()` akan memunculkan permintaan
        // izin sistem untuk sesuatu yang tidak pernah diminta pengguna.
        guard localLibrary.isAuthorized
                || !localLibrary.selectedAlbumIDs.isEmpty
        else {
            refreshCounts()
            return
        }
        // `prompt: isEnabled` — bertanya di pembukaan aplikasi hanya kalau
        // pencadangan memang menyala. Itu yang menutup lubang lama: sakelar yang
        // sudah menyala sejak versi sebelumnya tidak pernah memicu dialognya.
        await BackupNotifier.shared.ensureAuthorization(prompt: isEnabled)
        await localLibrary.load()
        await pruneUnavailableFailures()
        refreshCounts()
    }

    /// Membersihkan record gagal dari versi sebelumnya ketika aset sumbernya
    /// sudah tidak dapat ditemukan lagi oleh PhotoKit. Hanya item `.failed`
    /// yang disentuh: transfer aktif dan item yang masih menunggu iCloud tidak
    /// boleh dianggap hilang hanya karena berkas aslinya belum tersedia lokal.
    private func pruneUnavailableFailures() async {
        guard let ownership = uploadOwnership else { return }
        do {
            let changed = try await uploadRequests.pruneUnavailableFailures(
                canProcess: { self.uploadOwnership == ownership },
                hasFullPhotoAccess: { LocalPhotoLibrary.hasFullReadAccess },
                existingIdentifiers: { ids in
                    await Task.detached(priority: .utility) {
                        LocalPhotoLibrary.existingLocalIdentifiers(ids)
                    }.value
                },
                preservedIdentifiers: {
                    Set(BackupTemporaryFiles.recordedContexts(in: BackupTemporaryFiles.recoveryDirectory)
                        .filter { $0.ownership == ownership }.map(\.localIdentifier))
                })
            guard changed else { return }
            // Banner lama mungkin masih memuat hitungan sebelum pembersihan.
            // Snapshot berikutnya akan menerbitkan hasil baru bila memang masih
            // ada hasil terminal yang belum pernah diberitahukan.
            BackupNotifier.shared.clearCompletion()
            applyQueueSnapshot()
        } catch {
            lastError = error.localizedDescription
        }
    }

    // MARK: - Unggah

    /// Dipanggil saat aplikasi dibuka atau kembali aktif.
    func start() {
        guard isEnabled, task == nil, repo != nil, uploadOwnership != nil else { return }
        guard dataManager.isPersistentStoreAvailable else {
            lastError = BackupPersistenceError().localizedDescription
            return
        }
        automaticDiscovery.beginCycle()
        beginQueueWork(discover: true)
    }

    /// Completion frees a staging slot. Refill in foreground as well as during
    /// background events; otherwise a bounded queue would stop after its first window.
    func refillReadyQueue() {
        guard isEnabled || queue.hasPendingUserRequests else { return }
        refillRequested = true
        resumeQueuedUploadsIfRequested()
    }

    func finishStorageRecovery(localIdentifier: String, taskIdentifier: Int) {
        guard acceptsUploadResults else { return }
        do {
            guard try queue.requeueAfterStorageRecovery(
                localIdentifier, taskIdentifier: taskIdentifier) else { return }
            uploadProgressByID[localIdentifier] = nil
            applyQueueSnapshot()
        } catch {
            lastError = error.localizedDescription
            acceptsUploadResults = false
        }
    }

    private func resumeQueuedUploadsIfRequested() {
        guard refillRequested, task == nil else { return }
        refillRequested = false
        guard isEnabled || queue.hasPendingUserRequests,
              acceptsUploadResults, hasAuthenticatedSession, repo != nil,
              uploadOwnership != nil, dataManager.isPersistentStoreAvailable else { return }
        guard !uploadRequests.readyItems(automaticEnabled: isEnabled, limit: 1).isEmpty
                || (hasAutomaticCandidates && canDiscoverAutomaticallyNow) else { return }
        beginQueueWork(discover: isEnabled)
    }

    private func beginQueueWork(discover: Bool) {
        guard let ownership = uploadOwnership else { return }
        let id = UUID()
        workID = id
        task = Task { [weak self] in
            guard let self else { return }
            defer { self.finishQueueWork(id, ownership: ownership) }
            let before = self.queue.items
            if discover {
                await self.enqueueAutomaticBatch()
            } else {
                await NetworkMonitor.shared.waitUntilReady()
                guard !Task.isCancelled, self.workID == id,
                      self.uploadOwnership == ownership else { return }
                await self.processReadyQueueItems()
            }
            if !Task.isCancelled, self.uploadOwnership == ownership,
               self.queue.items != before,
               self.queue.snapshot.active < BackupStagingPolicy.maximumActiveUploads,
               !self.uploadRequests.readyItems(automaticEnabled: self.isEnabled, limit: 1).isEmpty {
                self.refillRequested = true
            }
        }
    }

    private func finishQueueWork(_ id: UUID, ownership: BackupUploadOwnership) {
        guard workID == id else { return }
        task = nil
        workID = nil
        guard uploadOwnership == ownership else { return }
        refreshCounts()
        applyQueueSnapshot()
        resumeQueuedUploadsIfRequested()
    }

    private var hasAutomaticCandidates: Bool {
        guard isEnabled, acceptsUploadResults, hasAuthenticatedSession,
              repo != nil, uploadOwnership != nil, dataManager.isPersistentStoreAvailable else { return false }
        return automaticDiscovery.hasCandidates(
            photos: LocalPhotoLibrary.shared.photos,
            uploadedIDs: dataManager.uploadedLocalIdentifiers())
    }

    /// Replenish the metadata window while preparation can make progress.
    /// Original exports remain bounded by the staging policy below.
    private func enqueueAutomaticBatch() async {
        await NetworkMonitor.shared.waitUntilReady()
        guard !Task.isCancelled, isEnabled, let ownership = uploadOwnership else { return }

        do {
            guard try await reconcileBackgroundTasks(ownership: ownership) else { return }
        } catch {
            guard !Task.isCancelled, uploadOwnership == ownership else { return }
            lastError = error.localizedDescription
            acceptsUploadResults = false
            applyQueueSnapshot()
            return
        }
        do {
            var processedPass = false
            try await automaticDiscovery.run(
                photos: { LocalPhotoLibrary.shared.photos },
                uploadedIDs: { self.dataManager.uploadedLocalIdentifiers() },
                activeIDs: { await BackupUploader.shared.activeLocalIdentifiers(ownership: ownership) },
                shouldContinue: {
                    self.isEnabled && self.uploadOwnership == ownership
                        && self.repo != nil && self.dataManager.isPersistentStoreAvailable
                        && (!processedPass || self.canDiscoverAutomaticallyNow)
                },
                processReady: {
                    guard !Task.isCancelled, self.uploadOwnership == ownership else { return }
                    self.applyQueueSnapshot()
                    await self.processReadyQueueItems()
                    processedPass = true
                })
        } catch {
            guard !Task.isCancelled, uploadOwnership == ownership else { return }
            lastError = error.localizedDescription
            acceptsUploadResults = false
            applyQueueSnapshot()
            return
        }
        guard !Task.isCancelled, uploadOwnership == ownership else { return }
        applyQueueSnapshot()
    }

    private func reconcileBackgroundTasks(ownership: BackupUploadOwnership) async throws -> Bool {
        let activeTasks = await BackupUploader.shared.activeTasks(ownership: ownership)
        guard !Task.isCancelled, uploadOwnership == ownership else { return false }
        try queue.reconcile(
            activeTasks: activeTasks,
            livePreparationIDs: Set(preparationClaims.compactMap {
                $0.value.ownership == ownership ? $0.key : nil
            }))
        let activeIDs = Set(activeTasks.map(\.context.localIdentifier))
        missingTransfers = (ownership, queue.items.filter {
            $0.state == .uploading && !activeIDs.contains($0.id)
        })
        await BackupUploader.shared.reclaimExcessStaging()
        guard !Task.isCancelled, uploadOwnership == ownership else { return false }
        for item in queue.items where item.state == .cancelling {
            await BackupUploader.shared.cancel(localIdentifier: item.id)
            guard !Task.isCancelled, uploadOwnership == ownership else { return false }
        }
        await BackupUploader.shared.resumeTasks(identifiers: Set(
            activeTasks.filter {
                $0.isSuspended && queue.item(id: $0.context.localIdentifier)?.state != .cancelling
            }.map(\.taskIdentifier)))
        return uploadOwnership == ownership
    }

    /// Mengunggah foto tertentu SEKARANG, atas permintaan langsung.
    ///
    /// Terpisah dari `start()`, dan syaratnya lebih longgar: yang ini tidak
    /// menuntut pencadangan otomatis dinyalakan, dan tidak menunggu Wi‑Fi.
    /// Pengguna baru saja menunjuk foto ini dan menekan "Upload" — menahannya
    /// atas nama setelan yang mengatur pekerjaan LATAR akan terbaca sebagai
    /// tombol yang rusak.
    ///
    /// - Parameter ids: id petak, boleh berawalan `device:` maupun tidak.
    func uploadNow(_ ids: [String]) async {
        guard repo != nil, uploadOwnership != nil else { return }
        guard dataManager.isPersistentStoreAvailable else {
            lastError = BackupPersistenceError().localizedDescription
            return
        }
        do {
            try uploadRequests.requestUploads(ids, uploadedIDs: dataManager.uploadedLocalIdentifiers())
        } catch {
            lastError = error.localizedDescription
            return
        }
        requestQueueRetry()
        await waitUntilFinished()
    }

    func stop() {
        refillRequested = false
        task?.cancel()
        task = nil
        workID = nil
        networkWakeTask?.cancel()
        networkWakeTask = nil
        networkWakeID = UUID()
        libraryChangeTask?.cancel()
        libraryChangeTask = nil
        retryWakeTask?.cancel()
        retryWakeTask = nil
        let owned = Set(preparationClaims.filter { $0.value.isOwned }.map(\.key))
        for claim in preparationClaims.values where claim.isOwned { claim.task?.cancel() }
        preparationClaims = preparationClaims.filter { !$0.value.isOwned }
        do { try queue.releasePreparations(owned) }
        catch {
            lastError = error.localizedDescription
            acceptsUploadResults = false
        }
        // Queue persisten dan transfer yang sudah berada di tangan sistem
        // tetap ada; BGTask yang kedaluwarsa
        // tidak boleh mengubah penghentian proses menjadi kehilangan pekerjaan.
        applyQueueSnapshot()
    }

    /// Menghentikan backup dan membuang semua state yang terikat akun.
    func resetForLogout() {
        acceptsUploadResults = false
        stop()
        for claim in preparationClaims.values { claim.task?.cancel() }
        preparationClaims.removeAll()
        repo = nil
        albumRepo = nil
        session = nil
        resetAlbumResolution(for: nil)
        total = 0
        backedUp = 0
        countedSelectionScanID = nil
        countedMappingRevision = nil
        hasRemainingPhotos = false
        hasRemainingVideos = false
        uploadedThisRun = 0
        pendingThisRun = 0
        failures = []
        lastError = nil
        lastQueueError = nil
        lastRunAt = nil
        waitingForNetwork = 0
        waitingForICloud = 0
        waitingForAuthentication = 0
        scheduledForRetry = 0
        queueStatusTitle = nil
        queueStatusBody = nil
        uploadItems = []
        uploadProgressByID = [:]
        hasAuthenticatedSession = false
        try? queue.clear()

        // Setelan backup termasuk state akun: akun baru tidak boleh langsung
        // mengunggah album yang dipilih oleh akun sebelumnya.
        isEnabled = false
        cellularPhotos = false
        cellularVideos = false
        syncAlbums = false
        applyQueueSnapshot()
    }

    /// Berbeda dari logout eksplisit: token yang ditolak tidak membuang queue
    /// atau mapping upload. Setelah login kembali, item dilepas otomatis tanpa
    /// pengguna harus membuka halaman Backup.
    func pauseForAuthentication() {
        hasAuthenticatedSession = false
        resetAlbumResolution(for: nil)
        repo = nil
        albumRepo = nil
        task?.cancel()
        task = nil
        workID = nil
        networkWakeTask?.cancel()
        networkWakeTask = nil
        networkWakeID = UUID()
        for claim in preparationClaims.values { claim.task?.cancel() }
        preparationClaims.removeAll()
        let message = String(localized: "Your Immich session expired. Sign in again to resume backup.")
        do {
            try queue.markAllWaitingForAuthentication(error: message)
        } catch {
            lastError = error.localizedDescription
        }
        applyQueueSnapshot()
    }

    func retryFailedUploads() {
        do {
            try uploadRequests.retryFailed()
            requestQueueRetry()
        } catch {
            lastError = error.localizedDescription
        }
    }

    func retryUpload(_ localIdentifier: String) {
        do {
            try uploadRequests.retry(localIdentifier)
            uploadProgressByID[localIdentifier] = nil
            requestQueueRetry()
        } catch {
            lastError = error.localizedDescription
        }
    }

    /// Menghapus pekerjaan yang belum aktif dari queue persisten. Transfer yang
    /// sedang menyiapkan atau mengirim file harus melewati `cancelUpload(_:)`
    /// agar callback URLSession tetap punya record untuk diselesaikan.
    func removeUpload(_ localIdentifier: String) {
        guard let item = queue.item(id: localIdentifier),
              !item.state.isActive
        else { return }

        do {
            try queue.discard(localIdentifier)
            uploadProgressByID[localIdentifier] = nil
            applyQueueSnapshot()
        } catch {
            lastError = error.localizedDescription
        }
    }

    /// Cancel memindahkan item ke state terminal yang dapat di-Retry. Transfer
    /// aktif menunggu callback URLSession agar tidak balapan dengan completion;
    /// item yang masih menyiapkan file bisa langsung ditandai gagal.
    func cancelUpload(_ localIdentifier: String) {
        guard let item = queue.item(id: localIdentifier), item.state.isActive else { return }
        let canceledMessage = String(localized: "Upload canceled.")
        preparationClaims[localIdentifier]?.task?.cancel()
        preparationClaims[localIdentifier] = nil

        do {
            if item.state == .uploading {
                try queue.markCancelling(localIdentifier)
                applyQueueSnapshot()
                Task { [weak self] in
                    let found = await BackupUploader.shared.cancel(
                        localIdentifier: localIdentifier)
                    guard let self, !found,
                          self.queue.item(id: localIdentifier)?.state == .cancelling
                    else { return }
                    try? self.queue.markFailed(localIdentifier, error: canceledMessage)
                    self.uploadProgressByID[localIdentifier] = nil
                    self.applyQueueSnapshot()
                }
            } else if item.state == .preparing {
                try queue.markFailed(localIdentifier, error: canceledMessage)
                uploadProgressByID[localIdentifier] = nil
                applyQueueSnapshot()
            }
        } catch {
            lastError = error.localizedDescription
        }
    }

    /// Dipanggil URLSession delegate selama badan multipart dikirim.
    func reportUploadProgress(
        context: BackupUploadTaskContext,
        taskIdentifier: Int,
        bytesSent: Int64,
        totalBytesExpected: Int64
    ) {
        guard acceptsUpload(context, taskIdentifier: taskIdentifier),
              totalBytesExpected > 0,
              let item = queue.item(id: context.localIdentifier),
              item.state == .uploading, item.taskIdentifier == taskIdentifier
        else { return }

        let localIdentifier = context.localIdentifier
        let fraction = min(1, max(0, Double(bytesSent) / Double(totalBytesExpected)))
        if context.phase == .livePhotoMotion {
            uploadProgressByID[localIdentifier] = fraction * 0.5
        } else if item.motionAssetID != nil {
            uploadProgressByID[localIdentifier] = 0.5 + fraction * 0.5
        } else {
            uploadProgressByID[localIdentifier] = fraction
        }
    }

    func waitUntilFinished() async {
        while !Task.isCancelled {
            if let wake = networkWakeTask { await wake.value }
            else if let work = task { await work.value }
            else if let placement = albumPlacementTasks.values.first { await placement.task.value }
            else { return }
        }
    }

    /// Jaringan mengizinkan foto INI naik sekarang.
    ///
    /// `isExpensive` menangkap seluler DAN hotspot — keduanya berkuota, dan
    /// keduanya sama-sama tidak diharapkan menelan pustaka foto seseorang.
    func allowsNetwork(for photo: LocalPhoto) -> Bool {
        uploadRequests.allowsNetwork(for: photo, policy: networkPolicy)
    }

    private var canDiscoverAutomaticallyNow: Bool { networkPolicy.allowsAutomaticDiscovery }

    var allowsCellularUploads: Bool {
        if queue.items.contains(where: {
            $0.allowsCellularOverride && $0.state != .failed && $0.state != .cancelling
        }) { return true }
        if selectionStatus == .remaining {
            return (hasRemainingPhotos && cellularPhotos) || (hasRemainingVideos && cellularVideos)
        }
        return cellularPhotos || cellularVideos
    }

    /// Prepare only a small window of originals. The rest of the queue remains
    /// metadata until a transfer completes and frees its temporary body.
    private func processReadyQueueItems() async {
        guard let repo, let ownership = uploadOwnership else { return }
        albumIDsByName = [:]
        enqueueDepth += 1
        defer {
            enqueueDepth -= 1
            if enqueueDepth == 0, uploadOwnership == ownership { finishRunIfSettled() }
        }
        do {
            try await uploadRequests.process(
                automaticEnabled: { self.isEnabled },
                policy: { self.networkPolicy },
                canProcess: {
                    self.uploadOwnership == ownership && self.dataManager.isPersistentStoreAvailable
                        && LocalPhotoLibrary.hasReadAccess
                },
                hasFullPhotoAccess: { LocalPhotoLibrary.hasFullReadAccess },
                metadata: { await self.photoMetadata(for: $0) },
                staging: { await BackupUploader.shared.stagingUsage() },
                unavailable: { id in
                    if BackupTemporaryFiles.recordedContexts(in: BackupTemporaryFiles.recoveryDirectory)
                        .contains(where: { $0.localIdentifier == id && $0.ownership == ownership }) {
                        self.reportPreservedUpload(localIdentifier: id)
                    } else {
                        try? self.queue.discard(id)
                    }
                },
                prepare: { photo, cloud in
                    await self.prepareQueuePhoto(photo, repository: repo,
                        mayReadFromICloud: cloud, ownership: ownership)
                },
                didChange: { self.applyQueueSnapshot() })
        } catch {
            guard !Task.isCancelled, uploadOwnership == ownership else { return }
            lastError = error.localizedDescription
            acceptsUploadResults = false
        }
        guard !Task.isCancelled, uploadOwnership == ownership else { return }
        applyQueueSnapshot()
    }

    private func photoMetadata(for id: String) async -> LocalPhoto? {
        guard LocalPhotoLibrary.hasReadAccess else { return nil }
        if let photo = LocalPhotoLibrary.shared.photos.first(where: { $0.id == id }) { return photo }
        return await LocalPhotoLibrary.shared.photoMetadata(for: id)
    }

    func prepareQueuePhoto(
        _ photo: LocalPhoto, repository repo: BackupRepository,
        mayReadFromICloud: Bool, ownership: BackupUploadOwnership
    ) async {
        await performPreparation(localIdentifier: photo.id, isOwned: true, ownership: ownership) { claim in
            do {
                let motionAssetID = self.queue.item(id: photo.id)?.motionAssetID
                try self.queue.markPreparing(photo.id,
                    phase: photo.isLivePhoto && motionAssetID == nil ? .livePhotoMotion : .primaryAsset,
                    motionAssetID: motionAssetID)
            } catch {
                self.lastError = error.localizedDescription
                self.acceptsUploadResults = false
                return
            }
            self.applyQueueSnapshot()
            do {
                let sourceAlbumName: String?
                if let saved = self.queue.item(id: photo.id)?.sourceAlbumName {
                    sourceAlbumName = saved
                } else if self.syncAlbums {
                    sourceAlbumName = try await self.localLibrary.sourceAlbumTitle(for: photo.id)
                } else {
                    sourceAlbumName = nil
                }
                try self.checkPreparation(photo.id, claim: claim)
                await self.prepareQueuePhoto(photo, repository: repo,
                    mayReadFromICloud: mayReadFromICloud, ownership: ownership, claim: claim,
                    sourceAlbumName: sourceAlbumName)
            } catch {
                guard self.isCurrentPreparation(photo.id, claim: claim) else { return }
                do {
                    try self.queue.markRetry(photo.id, state: .retryScheduled,
                        error: error.localizedDescription, retryAt: self.retryDate(for: photo.id))
                } catch {
                    self.lastError = error.localizedDescription
                    self.acceptsUploadResults = false
                }
                self.applyQueueSnapshot()
            }
        }
    }

    private func prepareQueuePhoto(
        _ photo: LocalPhoto, repository repo: BackupRepository,
        mayReadFromICloud: Bool, ownership: BackupUploadOwnership, claim: UUID, sourceAlbumName: String?
    ) async {
        guard !Task.isCancelled, uploadOwnership == ownership,
              preparationClaims[photo.id]?.id == claim else { return }
        if photo.isLivePhoto {
            do {
                if let motionAssetID = queue.item(id: photo.id)?.motionAssetID {
                    try queue.markPreparing(
                        photo.id,
                        phase: .primaryAsset,
                        motionAssetID: motionAssetID,
                        sourceAlbumName: sourceAlbumName)
                    applyQueueSnapshot()
                    try await enqueueLivePhotoPrimary(
                        photo,
                        motionAssetID: motionAssetID,
                        repository: repo,
                        claim: claim,
                        mayReadFromICloud: mayReadFromICloud,
                        ownership: ownership)
                } else {
                    try queue.markPreparing(photo.id, phase: .livePhotoMotion, sourceAlbumName: sourceAlbumName)
                    applyQueueSnapshot()
                    try await enqueueLivePhoto(
                        photo,
                        repository: repo,
                        claim: claim,
                        mayReadFromICloud: mayReadFromICloud,
                        ownership: ownership)
                }
            } catch {
                guard preparationClaims[photo.id]?.id == claim, !Task.isCancelled,
                      uploadOwnership == ownership else { return }
                handlePreparationFailure(
                    localIdentifier: photo.id,
                    error: error,
                    waitingForICloud: mayReadFromICloud)
            }
            guard uploadOwnership == ownership else { return }
            applyQueueSnapshot()
            return
        }

        do {
            try queue.markPreparing(photo.id, phase: .primaryAsset, sourceAlbumName: sourceAlbumName)
            applyQueueSnapshot()
        } catch {
            lastError = error.localizedDescription
            acceptsUploadResults = false
            return
        }

        guard let file = await readOriginalFile(LocalPhotoLibrary.assetID(for: photo.id), mayReadFromICloud)
        else {
            guard isCurrentPreparation(photo.id, claim: claim) else { return }
            // Berkas iCloud yang sedang menunggu Wi‑Fi bukan kegagalan. Ia
            // akan ditemukan lagi oleh BGTask berikutnya di jaringan sesuai.
            let message = mayReadFromICloud
                ? String(localized: "The original file is still downloading from iCloud.")
                : String(localized: "Waiting for Wi-Fi to download the original from iCloud.")
            try? queue.markRetry(
                photo.id,
                state: .waitingForICloud,
                error: message,
                retryAt: Date(timeIntervalSinceNow: 15 * 60))
            applyQueueSnapshot()
            return
        }

        do {
            try checkPreparation(photo.id, claim: claim)
            let checksum = try await repo.checksum(forFile: file.url)
            if !isCurrentPreparation(photo.id, claim: claim) {
                try? FileManager.default.removeItem(at: file.url)
                return
            }
            let prepared = try await repo.makeUploadRequest(
                fileURL: file.url,
                filename: file.filename,
                checksum: checksum,
                // `PHAsset.localIdentifier`, bukan checksum: yang diminta
                // server adalah id foto ini DI PERANGKAT INI, dan itu yang
                // membuatnya bisa mengenali unggahan ulang dari sumber yang
                // sama.
                deviceAssetId: photo.id,
                createdAt: photo.createdAt,
                modifiedAt: photo.modifiedAt)
            try? FileManager.default.removeItem(at: file.url)
            if !isCurrentPreparation(photo.id, claim: claim) {
                try? FileManager.default.removeItem(at: prepared.bodyFile)
                return
            }

            // DISERAHKAN, bukan ditunggu.
            //
            // Yang mengirimkannya `nsurlsessiond`, dan ia tidak peduli
            // apakah aplikasi ini masih hidup. Hasilnya masuk lewat
            // `finishUpload`, bisa jadi berjam-jam kemudian di proses yang
            // sama sekali baru.
            let uploadTask = try BackupUploader.shared.makeUploadTask(
                prepared,
                localIdentifier: photo.id,
                checksum: checksum,
                allowsCellular: uploadRequests.allowsCellular(for: photo, policy: networkPolicy),
                ownership: ownership,
                sourceAlbumName: queue.item(id: photo.id)?.sourceAlbumName)
            do {
                try queue.markUploading(
                    photo.id,
                    phase: .primaryAsset,
                    checksum: checksum,
                    taskIdentifier: uploadTask.taskIdentifier)
                uploadTask.resume()
                applyQueueSnapshot()
            } catch {
                uploadTask.cancel()
                try? FileManager.default.removeItem(at: prepared.bodyFile)
                throw error
            }
        } catch {
            try? FileManager.default.removeItem(at: file.url)
            guard preparationClaims[photo.id]?.id == claim, !Task.isCancelled,
                      uploadOwnership == ownership else { return }
            handlePreparationFailure(
                localIdentifier: photo.id,
                error: error,
                waitingForICloud: false)
        }
    }

    func reportStorageCleanupFailure(_ error: Error) {
        lastError = error.localizedDescription
    }

    private func isCurrentPreparation(_ id: String, claim: UUID) -> Bool {
        !Task.isCancelled && preparationClaims[id]?.id == claim
            && preparationClaims[id]?.ownership == uploadOwnership
            && uploadOwnership != nil && queue.item(id: id)?.state == .preparing
    }

    private func checkPreparation(_ id: String, claim: UUID) throws {
        guard isCurrentPreparation(id, claim: claim) else { throw CancellationError() }
    }

    private func releasePreparation(_ id: String, claim: UUID) {
        if preparationClaims[id]?.id == claim { preparationClaims[id] = nil }
    }

    /// A per-item task lets Cancel stop expensive preparation without canceling
    /// unrelated queued photos. Parent cancellation still stops the child.
    func performPreparation(
        localIdentifier: String, isOwned: Bool, ownership: BackupUploadOwnership,
        operation: @escaping @MainActor (UUID) async -> Void
    ) async {
        guard !Task.isCancelled, uploadOwnership == ownership else { return }
        var claim = PreparationClaim(isOwned: isOwned, ownership: ownership)
        let claimID = claim.id
        let worker = Task {
            guard !Task.isCancelled, self.uploadOwnership == ownership,
                  self.preparationClaims[localIdentifier]?.id == claimID else { return }
            await operation(claimID)
        }
        claim.task = worker
        preparationClaims[localIdentifier] = claim
        defer {
            if preparationClaims[localIdentifier]?.id == claimID, uploadOwnership == ownership,
               queue.item(id: localIdentifier)?.state == .preparing {
                do {
                    try queue.releasePreparations([localIdentifier])
                } catch {
                    lastError = error.localizedDescription
                    acceptsUploadResults = false
                }
                applyQueueSnapshot()
            }
            releasePreparation(localIdentifier, claim: claimID)
        }
        await withTaskCancellationHandler {
            await worker.value
        } onCancel: {
            worker.cancel()
        }
    }

    /// No automatic re-export is possible without the original. Keep this
    /// visible as a failure rather than silently discarding the queue entry.
    func reportPreservedUpload(localIdentifier: String, taskIdentifier: Int? = nil) {
        if let taskIdentifier, let current = queue.item(id: localIdentifier),
           current.taskIdentifier != taskIdentifier { return }
        let message = String(localized: "Upload failed. A recovery copy was kept because the original is unavailable. Restore Photos access or the original before retrying.")
        lastError = message
        guard acceptsUploadResults else { return }
        do {
            if queue.item(id: localIdentifier) == nil { try queue.enqueue([localIdentifier]) }
            try queue.markFailed(localIdentifier, error: message)
        } catch { lastError = error.localizedDescription }
        uploadProgressByID[localIdentifier] = nil
        applyQueueSnapshot()
        if enqueueDepth == 0 { finishRunIfSettled() }
    }

    /// Tahap pertama Live Photo: upload motion video sebagai hidden asset.
    /// Setelah server mengembalikan id-nya, `BackupUploader` memanggil
    /// `finishLivePhotoMotionUpload` untuk merakit tahap still image.
    private func enqueueLivePhoto(
        _ photo: LocalPhoto,
        repository: BackupRepository,
        claim: UUID,
        mayReadFromICloud: Bool,
        ownership: BackupUploadOwnership
    ) async throws {
        guard let motion = await LocalPhotoLibrary.shared.livePhotoMotionFile(
            for: LocalPhotoLibrary.assetID(for: photo.id),
            allowsNetworkFallback: mayReadFromICloud)
        else { throw LivePhotoBackupError.motionResourceMissing }

        do {
            try checkPreparation(photo.id, claim: claim)
            let checksum = try await repository.checksum(forFile: motion.url)
            try checkPreparation(photo.id, claim: claim)

            // Jika motion video sudah sampai ke server pada putaran sebelumnya
            // tetapi aplikasi mati sebelum still image sempat diantrikan, pakai
            // kembali id tersebut. Ini mencegah hidden orphan bertambah tiap
            // retry dan membuat alur dua tahap idempotent.
            let correlationID = "\(photo.id):live-photo-motion"
            if let existing = try? await repository.duplicateMatches([
                (id: correlationID, checksum: checksum),
            ]).first?.serverAssetID {
                try checkPreparation(photo.id, claim: claim)
                try? FileManager.default.removeItem(at: motion.url)
                try queue.markPreparing(
                    photo.id,
                    phase: .primaryAsset,
                    motionAssetID: existing)
                applyQueueSnapshot()
                try await enqueueLivePhotoPrimary(
                    photo,
                    motionAssetID: existing,
                    repository: repository,
                    claim: claim,
                    mayReadFromICloud: mayReadFromICloud,
                    ownership: ownership)
                return
            }

            try checkPreparation(photo.id, claim: claim)

            let prepared = try await repository.makeUploadRequest(
                fileURL: motion.url,
                filename: motion.filename,
                checksum: checksum,
                deviceAssetId: photo.id,
                createdAt: photo.createdAt,
                modifiedAt: photo.modifiedAt,
                // Hidden mencegah server menjalankan job media biasa pada klip
                // motion yang hanya merupakan pasangan Live Photo.
                additionalFields: ["visibility": "hidden"])
            var handedOff = false
            defer {
                if !handedOff { try? FileManager.default.removeItem(at: prepared.bodyFile) }
            }
            try? FileManager.default.removeItem(at: motion.url)
            try checkPreparation(photo.id, claim: claim)

            let uploadTask = try BackupUploader.shared.makeUploadTask(
                prepared,
                localIdentifier: photo.id,
                checksum: checksum,
                allowsCellular: uploadRequests.allowsCellular(for: photo, policy: networkPolicy),
                ownership: ownership,
                phase: .livePhotoMotion,
                sourceAlbumName: queue.item(id: photo.id)?.sourceAlbumName)
            do {
                try queue.markUploading(
                    photo.id,
                    phase: .livePhotoMotion,
                    checksum: checksum,
                    taskIdentifier: uploadTask.taskIdentifier)
                uploadTask.resume()
                handedOff = true
                applyQueueSnapshot()
            } catch {
                uploadTask.cancel()
                try? FileManager.default.removeItem(at: prepared.bodyFile)
                throw error
            }
        } catch {
            try? FileManager.default.removeItem(at: motion.url)
            throw error
        }
    }

    /// Callback tahap motion Live Photo. Fungsi ini sengaja `async`: pada cold
    /// launch daftar PhotoKit dan repository belum tentu sudah tersedia, tetapi
    /// task description masih membawa local identifier yang dibutuhkan.
    func finishLivePhotoMotionUpload(
        context: BackupUploadTaskContext,
        taskIdentifier: Int,
        outcome: Result<String, Error>,
        remainingBackgroundTasks: Int
    ) async {
        guard acceptsUpload(context, taskIdentifier: taskIdentifier),
              let ownership = context.ownership else { return }
        let localIdentifier = context.localIdentifier
        let sourceAlbumName = queue.item(id: localIdentifier)?.sourceAlbumName ?? context.sourceAlbumName
        if queue.item(id: localIdentifier)?.state == .cancelling {
            try? queue.markFailed(
                localIdentifier,
                error: String(localized: "Upload canceled."))
            uploadProgressByID[localIdentifier] = nil
            applyQueueSnapshot()
            if remainingBackgroundTasks == 0 && enqueueDepth == 0 {
                finishRunIfSettled()
            }
            return
        }
        switch outcome {
        case .failure(let error):
            finishUpload(
                context: context,
                taskIdentifier: taskIdentifier,
                outcome: .failure(error),
                remainingBackgroundTasks: remainingBackgroundTasks)

        case .success(let motionAssetID):
            await ensureConfigured()
            guard acceptsUpload(context, taskIdentifier: taskIdentifier) else { return }
            guard let repo else {
                finishUpload(
                    context: context,
                    taskIdentifier: taskIdentifier,
                    outcome: .failure(LivePhotoBackupError.sessionUnavailable),
                    remainingBackgroundTasks: remainingBackgroundTasks)
                return
            }
            let couldConfirmMissing = LocalPhotoLibrary.hasFullReadAccess
            let restoredPhoto = await LocalPhotoLibrary.shared.photoMetadata(for: localIdentifier)
            guard acceptsUpload(context, taskIdentifier: taskIdentifier) else { return }
            if queue.item(id: localIdentifier)?.state == .cancelling {
                finishUpload(context: context, taskIdentifier: taskIdentifier,
                    outcome: .failure(URLError(.cancelled)), remainingBackgroundTasks: remainingBackgroundTasks)
                return
            }
            guard let photo = restoredPhoto, LocalPhotoLibrary.hasReadAccess else {
                do {
                    if restoredPhoto == nil, couldConfirmMissing, LocalPhotoLibrary.hasFullReadAccess {
                        try queue.discard(localIdentifier)
                    } else {
                        try uploadRequests.retainCompletedMotion(localIdentifier, motionAssetID: motionAssetID,
                            sourceAlbumName: sourceAlbumName)
                    }
                } catch {
                    lastError = error.localizedDescription
                    acceptsUploadResults = false
                }
                uploadProgressByID[localIdentifier] = nil
                applyQueueSnapshot()
                if remainingBackgroundTasks == 0 && enqueueDepth == 0 {
                    finishRunIfSettled()
                }
                return
            }
            guard photo.isLivePhoto else {
                finishUpload(
                    context: context,
                    taskIdentifier: taskIdentifier,
                    outcome: .failure(LivePhotoBackupError.assetNoLongerLivePhoto),
                    remainingBackgroundTasks: remainingBackgroundTasks)
                return
            }

            let allowsCellular = uploadRequests.allowsCellular(for: photo, policy: networkPolicy)
            let mayReadFromICloud = !NetworkMonitor.shared.isExpensive || allowsCellular
            if queue.item(id: localIdentifier)?.state == .cancelling {
                finishUpload(context: context, taskIdentifier: taskIdentifier,
                    outcome: .failure(URLError(.cancelled)), remainingBackgroundTasks: remainingBackgroundTasks)
                return
            }
            guard let current = queue.item(id: localIdentifier), current.state == .uploading,
                  current.phase == .livePhotoMotion else { return }
            await performPreparation(localIdentifier: localIdentifier, isOwned: false, ownership: ownership) { claim in
                do {
                    try self.queue.markPreparing(
                        localIdentifier,
                        phase: .primaryAsset,
                        motionAssetID: motionAssetID,
                        sourceAlbumName: sourceAlbumName)
                    self.applyQueueSnapshot()
                    guard self.allowsNetwork(for: photo) else {
                        try self.queue.markRetry(localIdentifier, state: .waitingForNetwork,
                            error: String(localized: "Waiting for Wi-Fi."),
                            retryAt: Date(timeIntervalSinceNow: 15 * 60))
                        self.applyQueueSnapshot()
                        return
                    }
                    try await self.enqueueLivePhotoPrimary(
                        photo,
                        motionAssetID: motionAssetID,
                        repository: repo,
                        claim: claim,
                        mayReadFromICloud: mayReadFromICloud,
                        ownership: ownership)
                } catch {
                    guard !Task.isCancelled, self.uploadOwnership == ownership,
                          self.preparationClaims[localIdentifier]?.id == claim else { return }
                    self.handlePreparationFailure(
                        localIdentifier: localIdentifier,
                        error: error,
                        waitingForICloud: true)
                    self.applyQueueSnapshot()
                }
            }
        }
    }

    /// Tahap kedua Live Photo: upload still image dengan relasi ke hidden motion
    /// asset. Hanya tahap ini yang menghasilkan `BackupRecord`.
    private func enqueueLivePhotoPrimary(
        _ photo: LocalPhoto,
        motionAssetID: String,
        repository: BackupRepository,
        claim: UUID,
        mayReadFromICloud: Bool,
        ownership: BackupUploadOwnership
    ) async throws {
        guard let still = await LocalPhotoLibrary.shared.originalFile(
            for: LocalPhotoLibrary.assetID(for: photo.id),
            allowsNetworkFallback: mayReadFromICloud)
        else { throw LivePhotoBackupError.primaryResourceMissing }

        do {
            try checkPreparation(photo.id, claim: claim)
            let checksum = try await repository.checksum(forFile: still.url)
            try checkPreparation(photo.id, claim: claim)
            let prepared = try await repository.makeUploadRequest(
                fileURL: still.url,
                filename: still.filename,
                checksum: checksum,
                deviceAssetId: photo.id,
                createdAt: photo.createdAt,
                modifiedAt: photo.modifiedAt,
                additionalFields: ["livePhotoVideoId": motionAssetID])
            var handedOff = false
            defer {
                if !handedOff { try? FileManager.default.removeItem(at: prepared.bodyFile) }
            }
            try? FileManager.default.removeItem(at: still.url)
            try checkPreparation(photo.id, claim: claim)

            let uploadTask = try BackupUploader.shared.makeUploadTask(
                prepared,
                localIdentifier: photo.id,
                checksum: checksum,
                allowsCellular: uploadRequests.allowsCellular(for: photo, policy: networkPolicy),
                ownership: ownership,
                phase: .primaryAsset,
                sourceAlbumName: queue.item(id: photo.id)?.sourceAlbumName)
            do {
                try queue.markUploading(
                    photo.id,
                    phase: .primaryAsset,
                    checksum: checksum,
                    taskIdentifier: uploadTask.taskIdentifier)
                uploadTask.resume()
                handedOff = true
                applyQueueSnapshot()
            } catch {
                uploadTask.cancel()
                try? FileManager.default.removeItem(at: prepared.bodyFile)
                throw error
            }
        } catch {
            try? FileManager.default.removeItem(at: still.url)
            throw error
        }
    }

    /// Hasil satu unggahan, dari `BackupUploader`.
    ///
    /// Bisa dipanggil di proses yang BARU DILUNCURKAN sistem hanya untuk
    /// menyampaikan ini — jadi tidak boleh mengandaikan apa pun masih tersisa
    /// dari sesi sebelumnya. Tujuan album ikut disimpan bersama task dan queue.
    func finishUpload(
        context: BackupUploadTaskContext,
        taskIdentifier: Int,
        outcome: Result<String, Error>,
        remainingBackgroundTasks: Int
    ) {
        guard acceptsUpload(context, taskIdentifier: taskIdentifier) else { return }
        let localIdentifier = context.localIdentifier
        // Preserve the first queued destination; task metadata repairs older or missing ledgers.
        let sourceAlbumName = queue.item(id: localIdentifier)?.sourceAlbumName ?? context.sourceAlbumName
        if let existing = dataManager.getBackupRecord(localIdentifier: localIdentifier) {
            let placement = albumPlacement(existing.assetId, albumName: sourceAlbumName, context: context)
            do {
                if case .success = outcome, let placement {
                    try queue.recordAlbumPlacement(placement)
                }
                try queue.discard(localIdentifier)
            } catch {
                lastError = error.localizedDescription
            }
            applyQueueSnapshot()
            if case .success = outcome, let placement, let ownership = context.ownership {
                scheduleAlbumPlacement(placement, ownership: ownership)
            }
            return
        }
        if queue.item(id: localIdentifier)?.state == .cancelling,
           case .failure = outcome {
            try? queue.markFailed(
                localIdentifier,
                error: String(localized: "Upload canceled."))
            uploadProgressByID[localIdentifier] = nil
            applyQueueSnapshot()
            if remainingBackgroundTasks == 0 && enqueueDepth == 0 {
                finishRunIfSettled()
            }
            return
        }
        // A matching owned task may survive an interrupted queue write.
        if queue.item(id: localIdentifier) == nil {
            try? queue.enqueue([localIdentifier])
        }
        switch outcome {
        case .success(let assetID):
            let placement = albumPlacement(assetID, albumName: sourceAlbumName, context: context)
            do {
                guard dataManager.isPersistentStoreAvailable else {
                    throw BackupPersistenceError()
                }
                try dataManager.upsertBackupRecord(
                    assetID: assetID,
                    checksum: context.checksum,
                    localIdentifier: localIdentifier)
                try queue.markCompleted(localIdentifier, albumPlacement: placement)
            } catch {
                lastError = error.localizedDescription
                try? queue.markRetry(
                    localIdentifier,
                    state: .retryScheduled,
                    error: error.localizedDescription,
                    retryAt: retryDate(for: localIdentifier))
            }

            if let placement, let ownership = context.ownership {
                scheduleAlbumPlacement(placement, ownership: ownership)
            }

        case .failure(let error):
            lastError = error.localizedDescription
            switch BackupUploadFailureDisposition.classify(error) {
            case .retryNetwork:
                try? queue.markRetry(
                    localIdentifier,
                    state: .waitingForNetwork,
                    error: error.localizedDescription,
                    retryAt: retryDate(for: localIdentifier))
            case .retryServer:
                try? queue.markRetry(
                    localIdentifier,
                    state: .retryScheduled,
                    error: error.localizedDescription,
                    retryAt: retryDate(for: localIdentifier))
            case .authenticationRequired:
                if let fingerprint = context.credentialFingerprint,
                   fingerprint == BackupUploadTaskContext.credentialFingerprint(for: session?.authHeaders ?? [:]) {
                    handleAuthenticationRequired()
                } else {
                    // The account is unchanged, but this task used an older
                    // token. Retry with current credentials without expiring them.
                    try? queue.markQueued(localIdentifier)
                    lastError = nil
                }
            case .permanent:
                markFailedIfAssetStillExists(
                    localIdentifier,
                    error: error.localizedDescription)
            }
        }
        refreshCounts()
        applyQueueSnapshot()
        if remainingBackgroundTasks == 0 && enqueueDepth == 0 {
            finishRunIfSettled()
        }
    }

    private func handlePreparationFailure(
        localIdentifier: String,
        error: Error,
        waitingForICloud: Bool
    ) {
        guard !Task.isCancelled, !(error is CancellationError) else { return }
        if let state = queue.item(id: localIdentifier)?.state,
           state == .failed || state == .cancelling {
            return
        }
        lastError = error.localizedDescription
        if error is BackupQueueStoreError {
            acceptsUploadResults = false
            return
        }
        if waitingForICloud,
           error is LivePhotoBackupError {
            try? queue.markRetry(
                localIdentifier,
                state: .waitingForICloud,
                error: String(localized: "The original file is still downloading from iCloud."),
                retryAt: retryDate(for: localIdentifier))
            return
        }

        switch BackupUploadFailureDisposition.classify(error) {
        case .retryNetwork:
            try? queue.markRetry(
                localIdentifier,
                state: .waitingForNetwork,
                error: error.localizedDescription,
                retryAt: retryDate(for: localIdentifier))
        case .retryServer:
            try? queue.markRetry(
                localIdentifier,
                state: .retryScheduled,
                error: error.localizedDescription,
                retryAt: retryDate(for: localIdentifier))
        case .authenticationRequired:
            handleAuthenticationRequired()
        case .permanent:
            markFailedIfAssetStillExists(
                localIdentifier,
                error: error.localizedDescription)
        }
    }

    /// Kegagalan permanen hanya berguna bila pengguna masih punya aset yang
    /// dapat diperbaiki atau dicoba ulang. Jika fotonya sudah dihapus, record
    /// queue juga dibuang agar tidak menjadi failure abadi.
    private func markFailedIfAssetStillExists(_ localIdentifier: String, error: String) {
        try? uploadRequests.markFailedOrDiscard(localIdentifier, error: error,
            hasFullPhotoAccess: { LocalPhotoLibrary.hasFullReadAccess },
            sourceExists: { LocalPhotoLibrary.assetExists(localIdentifier) })
    }

    private func handleAuthenticationRequired() {
        let ownership = uploadOwnership
        let currentSession = session
        let authHeaders = currentSession?.authHeaders
        pauseForAuthentication()
        Task {
            await currentSession?.expireForBackgroundUpload()
            await BackupUploader.shared.cancelAll(ownership: ownership, authHeaders: authHeaders)
        }
    }

    private func retryDate(for localIdentifier: String, now: Date = .now) -> Date {
        let attempts = min(queue.item(id: localIdentifier)?.attemptCount ?? 0, 9)
        let delay = min(6 * 60 * 60, 30 * pow(2, Double(attempts)))
        return now.addingTimeInterval(delay)
    }

    /// UI dan notification membaca snapshot yang sama. Tidak ada lagi angka
    /// putaran dari RAM yang bisa berbeda setelah cold launch.
    private func applyQueueSnapshot(notify: Bool = true) {
        let state = queue.snapshot
        let defersCompletion = state.unfinished == 0 && isEnabled
            && (task != nil || enqueueDepth > 0 || hasAutomaticCandidates)
        uploadItems = queue.items.sorted { lhs, rhs in
            if lhs.state.isActive != rhs.state.isActive {
                return lhs.state.isActive
            }
            return lhs.createdAt < rhs.createdAt
        }
        let activeIDs = Set(uploadItems.filter { $0.state.isActive }.map(\.id))
        uploadProgressByID = uploadProgressByID.filter { activeIDs.contains($0.key) }
        uploadedThisRun = state.completed
        pendingThisRun = state.total
        failures = queue.failedIDs
        isUploading = state.isUploading
        waitingForNetwork = state.waitingForNetwork
        waitingForICloud = state.waitingForICloud
        waitingForAuthentication = state.waitingForAuthentication
        scheduledForRetry = state.retryScheduled
        queueStatusTitle = defersCompletion ? nil : state.presentation?.title
        queueStatusBody = defersCompletion ? nil : state.presentation?.body
        scheduleRetryWake()
        if let queueError = state.lastError {
            lastError = queueError
            lastQueueError = queueError
        } else if state.total == 0 || (state.unfinished == 0 && state.failed == 0) {
            lastError = nil
            lastQueueError = nil
        }
        notificationRevision += 1
        guard notify, isEnabled, !defersCompletion else { return }
        let revision = notificationRevision
        Task { [weak self] in
            await BackupNotifier.shared.ensureAuthorization(prompt: false)
            guard let self, self.notificationRevision == revision else { return }
            guard state.unfinished != 0
                    || (self.task == nil && self.enqueueDepth == 0 && !self.hasAutomaticCandidates)
            else { return }
            if state.unfinished == 0, state.completionNotificationPending {
                // Consume before posting. This intentionally guarantees
                // at-most-once delivery across process termination: a launch
                // can never reinterpret the same persisted completion as new.
                do {
                    try self.queue.consumeCompletionNotification()
                } catch {
                    self.lastError = error.localizedDescription
                    return
                }
            }
            BackupNotifier.shared.update(queue: state)
        }
    }

    private func scheduleRetryWake() {
        retryWakeTask?.cancel()
        retryWakeTask = nil
        guard hasAuthenticatedSession,
              acceptsUploadResults, dataManager.isPersistentStoreAvailable,
              let ownership = uploadOwnership else { return }
        let now = Date.now
        let missing = missingTransfers.flatMap { $0.ownership == ownership ? $0.items : nil } ?? []
        let reconciliationDelay = missing.compactMap { previous -> TimeInterval? in
            guard let current = queue.item(id: previous.id), current.state == .uploading,
                  current.taskIdentifier == previous.taskIdentifier,
                  current.updatedAt == previous.updatedAt else { return nil }
            return max(0, current.updatedAt
                .addingTimeInterval(BackupQueueStore.staleTransferInterval).timeIntervalSince(now))
        }.min()
        let retryDelay = isEnabled || queue.hasPendingUserRequests
            ? uploadRequests.retryWakeDelay(automaticEnabled: isEnabled, now: now) : nil
        guard let delay = [reconciliationDelay, retryDelay].compactMap({ $0 }).min() else { return }
        retryWakeTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard let self, !Task.isCancelled, self.uploadOwnership == ownership else { return }
            do {
                guard try await self.reconcileBackgroundTasks(ownership: ownership) else { return }
            } catch {
                guard !Task.isCancelled, self.uploadOwnership == ownership else { return }
                self.lastError = error.localizedDescription
                self.acceptsUploadResults = false
                self.applyQueueSnapshot()
                return
            }
            guard !Task.isCancelled, self.uploadOwnership == ownership else { return }
            // Keep the handle cancellable through reconciliation, then clear
            // it before the snapshot schedules the next wake.
            self.retryWakeTask = nil
            self.applyQueueSnapshot()
            self.requestNetworkWake()
        }
    }

    /// Settle only after queued preparation and automatic discovery have ended.
    private func finishRunIfSettled() {
        let state = queue.snapshot
        guard state.active == 0, state.queued == 0 else { return }
        if hasAutomaticCandidates {
            if canDiscoverAutomaticallyNow { refillRequested = true }
            else { BackupScheduler.schedule() }
            return
        }
        lastRunAt = Date()
        applyQueueSnapshot()
        if state.waiting > 0 { BackupScheduler.schedule() }
    }

    // MARK: - Sinkronisasi album

    /// Menaruh aset di album server bernama sama dengan album perangkatnya.
    private func placeInAlbum(
        _ assetID: String, albumName name: String, ownership: BackupUploadOwnership
    ) async throws {
        try Task.checkCancellation()
        guard syncAlbums, uploadOwnership == ownership, let albumRepo else { throw CancellationError() }
        guard let albumID = await albumID(named: name, ownership: ownership) else {
            try Task.checkCancellation()
            guard uploadOwnership == ownership else { throw CancellationError() }
            throw BackupAlbumPlacementError()
        }
        try Task.checkCancellation()
        guard syncAlbums, uploadOwnership == ownership else { throw CancellationError() }
        do {
            _ = try await albumRepo.addAssets([assetID], to: albumID)
        } catch {
            if uploadOwnership == ownership, albumIDsByName[name] == albumID { albumIDsByName[name] = nil }
            throw error
        }
    }

    private func albumPlacement(
        _ assetID: String, albumName: String?, context: BackupUploadTaskContext
    ) -> BackupAlbumPlacement? {
        guard syncAlbums, context.phase == .primaryAsset, let albumName,
              let ownership = context.ownership, uploadOwnership == ownership else { return nil }
        return BackupAlbumPlacement(localIdentifier: context.localIdentifier, assetID: assetID, albumName: albumName)
    }

    private func resumePendingAlbumPlacements() {
        guard !Task.isCancelled, syncAlbums, let ownership = uploadOwnership, albumRepo != nil else { return }
        for placement in queue.pendingAlbumPlacements {
            scheduleAlbumPlacement(placement, ownership: ownership)
        }
    }

    /// A crash can land between saving the upload mapping and checkpointing
    /// its album intent. Repair that boundary without requiring the original.
    private func recoverCompletedAlbumPlacements() {
        guard !Task.isCancelled, syncAlbums, uploadOwnership != nil else { return }
        for item in queue.items where item.phase == .primaryAsset {
            guard let name = item.sourceAlbumName,
                  let record = dataManager.getBackupRecord(localIdentifier: item.id) else { continue }
            do {
                try queue.markCompleted(item.id, albumPlacement: .init(
                    localIdentifier: item.id, assetID: record.assetId, albumName: name))
            } catch {
                lastError = error.localizedDescription
                acceptsUploadResults = false
                return
            }
        }
        applyQueueSnapshot(notify: false)
    }

    @discardableResult
    private func scheduleAlbumPlacement(
        _ placement: BackupAlbumPlacement, ownership: BackupUploadOwnership
    ) -> Task<Void, Never>? {
        guard !Task.isCancelled, syncAlbums, uploadOwnership == ownership,
              queue.pendingAlbumPlacements.contains(placement) else { return nil }
        if let current = albumPlacementTasks[placement.id], current.placement == placement { return current.task }
        albumPlacementTasks[placement.id]?.task.cancel()
        let id = UUID()
        let work = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                if self.albumPlacementTasks[placement.id]?.id == id { self.albumPlacementTasks[placement.id] = nil }
            }
            do {
                try await self.placeInAlbum(placement.assetID, albumName: placement.albumName, ownership: ownership)
                try Task.checkCancellation()
                guard self.uploadOwnership == ownership,
                      self.albumPlacementTasks[placement.id]?.id == id else { return }
                try self.queue.completeAlbumPlacement(placement)
            } catch {
                guard !Task.isCancelled, !(error is CancellationError), self.uploadOwnership == ownership,
                      self.albumPlacementTasks[placement.id]?.id == id else { return }
                self.lastError = error.localizedDescription
                BackupScheduler.schedule()
            }
        }
        albumPlacementTasks[placement.id] = AlbumPlacementWork(id: id, placement: placement, task: work)
        return work
    }

    /// Resolve a name once while concurrent upload completions await the same
    /// lookup and creation. A failed lookup never establishes that it is absent.
    func albumID(named name: String, ownership: BackupUploadOwnership) async -> String? {
        guard !Task.isCancelled, uploadOwnership == ownership else { return nil }
        resetAlbumResolution(for: ownership)
        if let cached = albumIDsByName[name] { return cached }
        if let lookup = albumLookups[name] {
            let result = await lookup.task.value
            return !Task.isCancelled && uploadOwnership == ownership ? result : nil
        }
        guard let albumRepo else { return nil }
        let lookupID = UUID()
        let worker = Task { @MainActor [weak self] () -> String? in
            guard let self, self.isCurrentAlbumLookup(name, id: lookupID, ownership: ownership) else { return nil }
            do {
                let existing = try await albumRepo.ownedAlbum(named: name, ownerID: ownership.owner.userID)
                guard self.isCurrentAlbumLookup(name, id: lookupID, ownership: ownership) else { return nil }
                let albumID: String
                if let existing {
                    albumID = existing.id
                } else {
                    let created = try await albumRepo.create(name: name)
                    guard self.isCurrentAlbumLookup(name, id: lookupID, ownership: ownership) else { return nil }
                    albumID = created.id
                }
                self.albumIDsByName[name] = albumID
                return albumID
            } catch {
                return nil
            }
        }
        albumLookups[name] = AlbumLookup(id: lookupID, task: worker)
        let result = await worker.value
        if albumLookups[name]?.id == lookupID { albumLookups[name] = nil }
        return !Task.isCancelled && uploadOwnership == ownership ? result : nil
    }

    private func isCurrentAlbumLookup(_ name: String, id: UUID, ownership: BackupUploadOwnership) -> Bool {
        !Task.isCancelled && uploadOwnership == ownership && albumLookupOwnership == ownership
            && albumLookups[name]?.id == id
    }

    private func resetAlbumResolution(for ownership: BackupUploadOwnership?) {
        guard albumLookupOwnership != ownership else { return }
        for placement in albumPlacementTasks.values { placement.task.cancel() }
        albumPlacementTasks.removeAll()
        for lookup in albumLookups.values { lookup.task.cancel() }
        albumLookups.removeAll()
        albumIDsByName.removeAll()
        albumLookupOwnership = ownership
    }

    /// "Organize into Albums": menyusun ulang aset yang SUDAH ada di server ke
    /// dalam album, memakai pilihan album yang berlaku sekarang.
    ///
    /// Gunanya untuk yang sudah terunggah sebelum sakelar ini dinyalakan — tanpa
    /// ini, satu-satunya cara merapikannya adalah mengunggah ulang semuanya.
    func organizeIntoAlbums() async {
        // `isUploading` TIDAK disentuh di sini. Menyalakannya membuat layar
        // Backup menggambar bilah kemajuan unggahan dengan angka putaran
        // sebelumnya — kemajuan palsu untuk pekerjaan yang berbeda. Tombolnya
        // sendiri sudah menunjukkan spinner-nya.
        guard albumRepo != nil, let ownership = uploadOwnership else { return }
        albumIDsByName = [:]
        let links = dataManager.serverAssetIDsByLocalIdentifier()

        for photo in LocalPhotoLibrary.shared.photos {
            if Task.isCancelled || !syncAlbums { return }
            guard let assetID = links[photo.id],
                  let name = LocalPhotoLibrary.shared.albumTitles[photo.id] else { continue }
            guard uploadOwnership == ownership else { return }
            do {
                let placement = BackupAlbumPlacement(localIdentifier: photo.id, assetID: assetID, albumName: name)
                try queue.recordAlbumPlacement(placement)
                await scheduleAlbumPlacement(placement, ownership: ownership)?.value
            } catch {
                lastError = error.localizedDescription
                return
            }
        }
    }
}
