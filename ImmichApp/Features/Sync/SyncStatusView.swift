import Observation
import SwiftUI
import UIKit

enum SyncStatusJob: String, CaseIterable, Identifiable, Hashable {
    case syncLocal
    case syncRemote
    case syncCloudIDs
    case hashAssets

    var id: Self { self }

    var title: LocalizedStringKey {
        switch self {
        case .syncLocal: "Sync Local"
        case .syncRemote: "Sync Remote"
        case .syncCloudIDs: "Sync Cloud IDs"
        case .hashAssets: "Hash Assets"
        }
    }

    var symbol: String {
        switch self {
        case .syncLocal: "arrow.trianglehead.2.clockwise.rotate.90"
        case .syncRemote: "arrow.trianglehead.2.clockwise.rotate.90.icloud"
        case .syncCloudIDs: "icloud.and.arrow.down"
        case .hashAssets: "number"
        }
    }
}

enum SyncStatusJobState: Equatable {
    case idle
    case running
    case succeeded(Date?, String)
    case failed(String)

    var subtitle: Text {
        switch self {
        case .idle:
            return Text("Tap to run job")
        case .running:
            return Text("Running…")
        case let .succeeded(date, message):
            if let date {
                return Text("\(message) • \(date, format: .relative(presentation: .named))")
            }
            return Text(message)
        case let .failed(message):
            return Text(message)
        }
    }
}

private struct SyncStatusJobError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

@MainActor
@Observable
final class SyncStatusViewModel {
    var localAssets: Int?
    var remoteAssets: Int?
    var localAlbums: Int?
    var remoteAlbums: Int?
    var memories: Int?
    var hashedAssets: Int?
    var storageUsage: AppStorageUsage?
    var cacheSize: Int { storageUsage?.imageCache ?? 0 }
    var backgroundUploadSize = 0
    var isRefreshing = false
    var isClearingCache = false
    var isResettingDatabase = false
    var runningJob: SyncStatusJob?
    var jobStates: [SyncStatusJob: SyncStatusJobState] = [:]
    var completionFeedback = 0

    private let settingsRepo: SettingsRepository
    private let albumRepo: AlbumRepository
    private let memoriesRepo: MemoriesRepository
    private let syncRepo: SyncRepository
    private let matcher: DeviceAssetMatcher
    private let dataManager: SwiftDataManager
    private let library: LocalPhotoLibrary
    private let prepareLocal: @MainActor () async -> Void
    private var didLoad = false

    var storageStartupState: LocalStoreStartupState {
        dataManager.startupState
    }

    init(
        session: SessionManager,
        library: LocalPhotoLibrary? = nil,
        dataManager: SwiftDataManager? = nil,
        api: APIClient? = nil,
        prepareLocal: @escaping @MainActor () async -> Void = { await BackupService.shared.prepare() }
    ) {
        let dataManager = dataManager ?? .shared
        self.library = library ?? .shared
        self.dataManager = dataManager
        self.prepareLocal = prepareLocal
        let api = api ?? APIClient(session: session)
        settingsRepo = SettingsRepository(api: api)
        albumRepo = AlbumRepository(api: api)
        memoriesRepo = MemoriesRepository(api: api)
        syncRepo = SyncRepository(api: api, dataManager: dataManager)
        matcher = DeviceAssetMatcher(
            repo: BackupRepository(api: api),
            dataManager: dataManager)

        for job in SyncStatusJob.allCases { jobStates[job] = .idle }
    }

    func loadIfNeeded() async {
        guard !didLoad else { return }
        didLoad = true
        await refreshCounts()
        inferExistingJobStates()
    }

    func refreshCounts() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }

        // Local storage remains available even if server requests are slow.
        await refreshStorageUsage()

        async let statsTask: AssetStatsDTO? = try? settingsRepo.getAssetStats()
        async let remoteAlbumsTask: [AlbumResponseDTO]? = try? albumRepo.all()
        async let memoriesTask: [MemoryDTO]? = try? memoriesRepo.getMemories()
        let local = try? await library.statusCounts()
        let localRevision = library.revision
        let (stats, albums, memoryItems) = await (
            statsTask,
            remoteAlbumsTask,
            memoriesTask)

        library.refreshAuthorizationStatus()
        let localIsCurrent = !Task.isCancelled && library.isAuthorized && localRevision == library.revision
        localAssets = localIsCurrent ? local?.assets : nil
        localAlbums = localIsCurrent ? local?.albums : nil
        remoteAssets = stats?.total
        remoteAlbums = albums?.count
        memories = memoryItems?.count
        hashedAssets = dataManager.storedChecksums().count
    }

    func run(_ job: SyncStatusJob, appSync: SyncViewModel?) async {
        guard runningJob == nil else { return }
        runningJob = job
        jobStates[job] = .running

        do {
            let result: String
            switch job {
            case .syncLocal:
                try Task.checkCancellation()
                let hasAccess = await library.requestAccess()
                try Task.checkCancellation()
                guard hasAccess else {
                    throw SyncStatusJobError(message: String(localized: "Allow Photos access before syncing local assets."))
                }
                await prepareLocal()
                let counts = try await library.statusCounts()
                result = String(localized: "Scanned \(counts.assets) local assets")

            case .syncRemote:
                let needsFullSync = dataManager.getSyncState().lastFullSyncAt == nil
                if let appSync {
                    let succeeded: Bool
                    if needsFullSync {
                        succeeded = await appSync.performFullSync()
                    } else {
                        succeeded = await appSync.performDeltaSync()
                    }
                    guard succeeded else {
                        throw SyncStatusJobError(message: appSync.syncProgress)
                    }
                } else {
                    if needsFullSync {
                        try await syncRepo.fullSync()
                    } else {
                        try await syncRepo.deltaSync()
                    }
                }
                result = String(localized: "Remote library is up to date")

            case .syncCloudIDs:
                let photos = await library.allPhotosForSync()
                guard library.isAuthorized else {
                    throw SyncStatusJobError(
                        message: String(localized: "Allow Photos access before syncing cloud IDs."))
                }
                let linked = try await matcher.matchNow(photos)
                result = linked == 0
                    ? String(localized: "Cloud IDs are up to date")
                    : String(localized: "Matched \(linked) cloud IDs")

            case .hashAssets:
                let photos = await library.allPhotosForSync()
                guard library.isAuthorized else {
                    throw SyncStatusJobError(
                        message: String(localized: "Allow Photos access before hashing assets."))
                }
                let hashed = try await matcher.hashNow(photos)
                result = hashed == 0
                    ? String(localized: "All available assets are hashed")
                    : String(localized: "Hashed \(hashed) assets")
            }

            jobStates[job] = .succeeded(.now, result)
            completionFeedback &+= 1
            await refreshCounts()
        } catch is CancellationError {
            jobStates[job] = .idle
        } catch {
            let message = (error as? LocalizedError)?.errorDescription
                ?? error.localizedDescription
            jobStates[job] = .failed(message)
        }

        runningJob = nil
    }

    func clearCache() async {
        guard !isClearingCache else { return }
        isClearingCache = true
        await ImageCache.shared.clear()
        NetworkResponseCache.clear()
        await refreshStorageUsage()
        isClearingCache = false
        completionFeedback &+= 1
    }

    func refreshStorageUsage() async {
        async let localFiles = AppStorageUsage.measure()
        let uploads = await BackupUploader.shared.stagingUsage()
        backgroundUploadSize = uploads.bytes
        storageUsage = await localFiles
    }

    func exportDatabase() async throws -> URL {
        try await dataManager.exportDatabase()
    }

    func resetDatabase() async throws {
        guard !isResettingDatabase else { return }
        isResettingDatabase = true
        defer { isResettingDatabase = false }

        try dataManager.resetSyncDatabase()
        hashedAssets = 0
        jobStates[.syncRemote] = .idle
        jobStates[.hashAssets] = .idle
        completionFeedback &+= 1
    }

    func state(for job: SyncStatusJob) -> SyncStatusJobState {
        jobStates[job] ?? .idle
    }

    private func inferExistingJobStates() {
        if library.isAuthorized {
            jobStates[.syncLocal] = .succeeded(nil, String(localized: "Local library is available"))
        }

        let syncState = dataManager.getSyncState()
        if let date = syncState.lastDeltaSyncAt ?? syncState.lastFullSyncAt {
            jobStates[.syncRemote] = .succeeded(date, String(localized: "Remote library synced"))
        }

        if !dataManager.uploadedLocalIdentifiers().isEmpty {
            jobStates[.syncCloudIDs] = .succeeded(nil, String(localized: "Cloud IDs are available"))
        }

        if dataManager.storedChecksums().count > 0 {
            jobStates[.hashAssets] = .succeeded(nil, String(localized: "Hashed assets are available"))
        }
    }
}

/// Ringkasan database sinkronisasi dan pekerjaan perawatannya.
///
/// Informasinya mengikuti halaman Immich resmi, sementara tata letaknya memakai
/// `List`, section, semantic colors, dan SF Symbols agar tetap terasa native di
/// dalam Settings iOS aplikasi ini.
struct SyncStatusView: View {
    @Environment(SyncViewModel.self) private var appSync: SyncViewModel?
    @State private var vm: SyncStatusViewModel
    @State private var databaseExport = DatabaseExportSharing()
    @State private var exportTask: Task<Void, Never>?
    @State private var actionError: ErrorEvent?
    @State private var showResetConfirmation = false
    private let session: SessionManager

    init(session: SessionManager) {
        self.session = session
        _vm = State(initialValue: SyncStatusViewModel(session: session))
    }

    var body: some View {
        List {
            databaseHealthSection
            statusSection(
                "Assets",
                leading: ("Local", "iphone", vm.localAssets),
                trailing: ("Remote", "icloud.fill", vm.remoteAssets))
            statusSection(
                "Albums",
                leading: ("Local", "rectangle.stack", vm.localAlbums),
                trailing: ("Remote", "icloud.fill", vm.remoteAlbums))
            statusSection(
                "Other",
                leading: ("Memories", "calendar", vm.memories),
                trailing: ("Hashed Assets", "number", vm.hashedAssets))

            jobsSection
            storageSection
            actionsSection
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Sync Status")
        .navigationBarTitleDisplayMode(.inline)
        .task { await vm.loadIfNeeded() }
        .refreshable { await vm.refreshCounts() }
        .sensoryFeedback(.success, trigger: vm.completionFeedback)
        .sheet(item: databaseExport.binding) { presentation in
            databaseExport.shareSheet(for: presentation)
        }
        .onDisappear {
            exportTask?.cancel()
            databaseExport.cancelPreparation()
        }
        .onChange(of: session.snapshot) { _, _ in
            exportTask?.cancel()
            databaseExport.invalidate()
        }
        .alert("Reset Sync Database?", isPresented: $showResetConfirmation) {
            Button("Reset", role: .destructive) {
                Task {
                    do {
                        try await vm.resetDatabase()
                    } catch {
                        actionError = ErrorEvent(error.localizedDescription)
                    }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes the local sync index and hashed-asset cache. Photos on your device and server remain safe. Run Sync Remote afterward to rebuild the index.")
        }
        .errorToast($actionError)
    }

    @ViewBuilder
    private var databaseHealthSection: some View {
        switch vm.storageStartupState {
        case .ready:
            EmptyView()

        case let .recovered(quarantinedStore, restoredCount, warning):
            Section("Database Recovery") {
                Label {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Local cache was rebuilt")
                        Text("Restored \(restoredCount) protected backup mappings. Remote sync can rebuild the remaining cache.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } icon: {
                    Image(systemName: "arrow.clockwise.icloud.fill")
                        .foregroundStyle(.orange)
                }

                if quarantinedStore != nil || warning != nil {
                    Text("The unreadable database was preserved for diagnostics instead of being deleted.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

        case let .protectionUnavailable(message):
            Section("Database Protection") {
                Label(message, systemImage: "exclamationmark.shield.fill")
                    .foregroundStyle(.orange)
            }

        case let .persistentStoreUnavailable(message):
            Section("Database Unavailable") {
                Label {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Automatic backup is paused")
                        Text(message)
                            .font(.caption)
                    }
                } icon: {
                    Image(systemName: "externaldrive.badge.xmark")
                }
                .foregroundStyle(.red)
            }
        }
    }

    private func statusSection(
        _ title: LocalizedStringKey,
        leading: (title: LocalizedStringKey, symbol: String, value: Int?),
        trailing: (title: LocalizedStringKey, symbol: String, value: Int?)
    ) -> some View {
        Section(title) {
            HStack(spacing: 12) {
                statusCard(leading)
                statusCard(trailing)
            }
            .listRowInsets(EdgeInsets())
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
        }
    }

    private func statusCard(
        _ item: (title: LocalizedStringKey, symbol: String, value: Int?)
    ) -> some View {
        VStack(spacing: 9) {
            Label(item.title, systemImage: item.symbol)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.tint)
                .lineLimit(1)
                .minimumScaleFactor(0.8)

            Group {
                if let value = item.value {
                    Text(value.formatted())
                        .contentTransition(.numericText())
                } else if vm.isRefreshing {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Text("—")
                        .foregroundStyle(.secondary)
                }
            }
            .font(.title2.weight(.medium))
            .monospacedDigit()
            .frame(height: 28)
        }
        .frame(maxWidth: .infinity, minHeight: 104)
        .background(
            Color(uiColor: .secondarySystemGroupedBackground),
            in: .rect(cornerRadius: 18))
        .overlay {
            RoundedRectangle(cornerRadius: 18)
                .strokeBorder(.separator.opacity(0.35), lineWidth: 0.5)
        }
    }

    private var jobsSection: some View {
        Section {
            ForEach(SyncStatusJob.allCases) { job in
                Button {
                    Task { await vm.run(job, appSync: appSync) }
                } label: {
                    HStack(spacing: 14) {
                        Image(systemName: job.symbol)
                            .font(.title3)
                            .foregroundStyle(.secondary)
                            .frame(width: 28)

                        VStack(alignment: .leading, spacing: 3) {
                            Text(job.title)
                                .foregroundStyle(.primary)
                            vm.state(for: job).subtitle
                                .font(.caption)
                                .foregroundStyle(jobSubtitleColor(job))
                                .lineLimit(2)
                        }

                        Spacer()
                        jobIndicator(job)
                    }
                    .contentShape(.rect)
                }
                .disabled(vm.runningJob != nil)
            }
        } header: {
            Text("Jobs")
        } footer: {
            Text("Manual jobs update the local index and server cache. Hashing may need to download originals from iCloud, so it only runs on Wi-Fi.")
        }
    }

    private var storageSection: some View {
        Section {
            if let usage = vm.storageUsage {
                LabeledContent("Image Cache", value: formatBytes(usage.imageCache))
                LabeledContent("Other Caches", value: formatBytes(usage.otherCaches))
                LabeledContent("Backup Files", value: formatBytes(usage.backupFiles))
                LabeledContent("Recovery Copies", value: formatBytes(usage.recoveredUploads))
                LabeledContent("Temporary Files", value: formatBytes(usage.temporaryFiles))
                LabeledContent("App Data", value: formatBytes(usage.appData))
                LabeledContent("Shared Data", value: formatBytes(usage.sharedData))
                LabeledContent("Local Files Total", value: formatBytes(usage.total))
                LabeledContent("Background Upload Data", value: formatBytes(vm.backgroundUploadSize))
            }
            Button("Refresh Storage Usage", systemImage: "arrow.clockwise") {
                Task { await vm.refreshStorageUsage() }
            }
        } header: {
            Text("On-Device Storage")
        } footer: {
            Text("Other Caches includes HTTP and system graphics caches. HTTP cache is cleared when a video closes or the app enters the background. System-managed cache files may remain or be recreated, so this number may not reach zero.")
            Text("Temporary upload files are removed after server-confirmed success, or after a failed upload when the original is still accessible in Photos. Recovery Copies are kept when an upload fails and the original is unavailable; Clear File Cache does not remove them. Restore Photos access or the original before retrying. iOS may also keep background-upload copies that are not included in Local Files Total.")
        }
    }

    private var actionsSection: some View {
        Section {
            Button {
                Task { await vm.clearCache() }
            } label: {
                LabeledContent {
                    if vm.isClearingCache {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Text(formatBytes(vm.cacheSize))
                            .foregroundStyle(.secondary)
                    }
                } label: {
                    Label("Clear File Cache", systemImage: "trash")
                }
            }
            .disabled(vm.isClearingCache)

            Button {
                guard exportTask == nil else { return }
                exportTask = Task {
                    defer { exportTask = nil }
                    if let error = await databaseExport.prepare(session: session, export: {
                        try await vm.exportDatabase()
                    }) {
                        actionError = ErrorEvent(error)
                    }
                }
            } label: {
                HStack {
                    Label("Export Database", systemImage: "square.and.arrow.up")
                    Spacer()
                    if databaseExport.isPreparing {
                        ProgressView()
                            .controlSize(.small)
                    }
                }
            }
            .disabled(exportTask != nil || databaseExport.presentation != nil || vm.isResettingDatabase)

            Button(role: .destructive) {
                showResetConfirmation = true
            } label: {
                Label("Reset Sync Database", systemImage: "arrow.counterclockwise.circle")
            }
            .disabled(vm.isResettingDatabase || vm.runningJob != nil)
        } header: {
            Text("Actions")
        } footer: {
            Text("Cache and database actions only affect local app data. Photos on your device and server remain safe.")
        }
    }

    private func formatBytes(_ bytes: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }

    private func jobSubtitleColor(_ job: SyncStatusJob) -> Color {
        if case .failed = vm.state(for: job) { return .red }
        return .secondary
    }

    @ViewBuilder
    private func jobIndicator(_ job: SyncStatusJob) -> some View {
        switch vm.state(for: job) {
        case .idle:
            Image(systemName: "chevron.right")
                .font(.caption.bold())
                .foregroundStyle(.tertiary)
        case .running:
            ProgressView()
                .controlSize(.small)
        case .succeeded:
            Image(systemName: "checkmark.circle.fill")
                .font(.title3)
                .foregroundStyle(.green)
        case .failed:
            Image(systemName: "xmark.circle.fill")
                .font(.title3)
                .foregroundStyle(.red)
        }
    }
}
