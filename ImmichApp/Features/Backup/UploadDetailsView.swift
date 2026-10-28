import SwiftUI

/// Rincian antrean yang sama dengan pekerjaan background sebenarnya.
/// Tidak ada model UI bayangan: state, cancel, dan retry semuanya melewati
/// layanan masing-masing agar callback URLSession tetap terikat antreannya.
struct UploadDetailsView: View {
    @Environment(SessionManager.self) private var session
    @State private var backup = BackupService.shared
    @State private var sharedUploads = SharedUploadService.shared
    @State private var actionError: ErrorEvent?

    private var uploading: [BackupQueueItem] {
        backup.uploadItems.filter { $0.state.isActive }
    }

    private var waiting: [BackupQueueItem] {
        backup.uploadItems.filter {
            $0.state == .queued || $0.state.isWaiting
        }
    }

    private var failed: [BackupQueueItem] {
        backup.uploadItems.filter { $0.state == .failed }
    }

    var body: some View {
        Group {
            if backup.uploadItems.isEmpty && sharedUploads.items.isEmpty && sharedUploads.lastError == nil {
                ContentUnavailableView(
                    "No Uploads",
                    systemImage: "checkmark.icloud",
                    description: Text("There are no items in the backup queue."))
            } else {
                List {
                    uploadSection("Uploading", items: uploading)
                    uploadSection("Waiting", items: waiting)
                    uploadSection("Failed", items: failed)
                    sharedUploadSection
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
            }
        }
        .navigationTitle("Upload Details")
        .navigationBarTitleDisplayMode(.inline)
        .task { await sharedUploads.refreshPending(session: session) }
        .refreshable { await sharedUploads.refreshPending(session: session) }
        .errorToast($actionError)
    }

    @ViewBuilder
    private var sharedUploadSection: some View {
        if !sharedUploads.items.isEmpty || sharedUploads.lastError != nil {
            Section("Shared Uploads") {
                if let error = sharedUploads.lastError {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                }
                ForEach(sharedUploads.items) { entry in
                    VStack(alignment: .leading, spacing: 8) {
                        Text(entry.item.filename)
                            .font(.headline)
                        Text(sharedUploadStatus(entry.item.state))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        if let error = entry.item.lastError {
                            Text(error)
                                .font(.caption)
                                .foregroundStyle(.orange)
                        }
                        if entry.item.state == .failed {
                            HStack {
                                Button("Retry", systemImage: "arrow.clockwise") {
                                    performSharedAction { try await sharedUploads.retry(entry, session: session) }
                                }
                                Button("Remove", systemImage: "trash", role: .destructive) {
                                    performSharedAction { try await sharedUploads.remove(entry, session: session) }
                                }
                            }
                            .buttonStyle(.bordered)
                        }
                    }
                    .padding(.vertical, 6)
                }
            }
        }
    }

    private func performSharedAction(_ action: @escaping @MainActor () async throws -> Void) {
        Task {
            do { try await action() }
            catch is CancellationError {}
            catch { actionError = ErrorEvent(error.localizedDescription) }
        }
    }

    private func sharedUploadStatus(_ state: SharedUploadItemState) -> LocalizedStringKey {
        switch state {
        case .failed: "Failed"
        case .uploading: "Uploading"
        default: "Queued"
        }
    }

    @ViewBuilder
    private func uploadSection(
        _ title: LocalizedStringKey,
        items: [BackupQueueItem]
    ) -> some View {
        if !items.isEmpty {
            Section {
                ForEach(items) { item in
                    UploadDetailCard(
                        item: item,
                        progress: backup.uploadProgressByID[item.id] ?? 0,
                        onCancel: { backup.cancelUpload(item.id) })
                    .listRowInsets(EdgeInsets(
                        top: 6,
                        leading: 16,
                        bottom: 6,
                        trailing: 16))
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
                    .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                        if item.state == .failed {
                            Button("Retry", systemImage: "arrow.clockwise") {
                                backup.retryUpload(item.id)
                            }
                            .tint(Color.accentColor)
                        }

                        if !item.state.isActive {
                            Button(
                                "Remove",
                                systemImage: "trash",
                                role: .destructive
                            ) {
                                backup.removeUpload(item.id)
                            }
                        }
                    }
                }
            } header: {
                HStack(spacing: 8) {
                    Text(title)
                        .font(.title2.bold())
                    Text("\(items.count)")
                        .font(.subheadline.weight(.semibold))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 4)
                        .background(.fill.tertiary, in: .capsule)
                }
                .foregroundStyle(.primary)
                .textCase(nil)
                .padding(.top, 12)
            }
        }
    }
}

private struct UploadDetailCard: View {
    let item: BackupQueueItem
    let progress: Double
    let onCancel: () -> Void

    @State private var image: UIImage?
    @State private var metadata: LocalPhotoDisplayMetadata?

    private var percent: Int {
        Int((min(1, max(0, progress)) * 100).rounded())
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 14) {
                thumbnail

                VStack(alignment: .leading, spacing: 5) {
                    Text(metadata?.filename ?? fallbackName)
                        .font(.headline)
                        .lineLimit(1)
                    if let metadata {
                        Text(metadata.createdAt, format: .dateTime.day().month().year())
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        Text(item.phase == .livePhotoMotion ? "Live Photo" : "Local asset")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Text(statusText)
                        .font(.caption)
                        .foregroundStyle(statusColor)
                        .lineLimit(2)
                }

                Spacer(minLength: 8)

                if item.state == .uploading || item.state == .preparing {
                    Text(
                        min(1, max(0, progress)),
                        format: .percent.precision(.fractionLength(0))
                    )
                        .font(.title3.weight(.semibold))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            }

            if item.state.isActive {
                ProgressView(value: progress, total: 1)
                    .tint(item.state == .cancelling ? .secondary : .accentColor)
            }

            action
        }
        .padding(14)
        .background(.background.secondary, in: .rect(cornerRadius: 18))
        .overlay {
            RoundedRectangle(cornerRadius: 18)
                .stroke(.separator.opacity(0.45), lineWidth: 0.5)
        }
        .task(id: item.id) {
            guard metadata == nil || image == nil else { return }
            metadata = await LocalPhotoLibrary.shared.displayMetadata(for: item.id)
            image = await LocalPhotoLibrary.shared.thumbnail(
                for: LocalPhotoLibrary.assetID(for: item.id),
                size: CGSize(width: 240, height: 240))
        }
    }

    private var thumbnail: some View {
        RoundedRectangle(cornerRadius: 12)
            .fill(.fill.tertiary)
            .frame(width: 72, height: 72)
            .overlay {
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                } else {
                    Image(systemName: item.state == .preparing ? "hourglass" : "photo")
                        .font(.title2)
                        .foregroundStyle(.secondary)
                }
            }
            .clipShape(.rect(cornerRadius: 12))
            .overlay(alignment: .bottomTrailing) {
                if metadata?.isVideo == true {
                    Image(systemName: "video.fill")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.white)
                        .padding(5)
                        .background(.black.opacity(0.65), in: .circle)
                        .padding(5)
                }
            }
    }

    @ViewBuilder
    private var action: some View {
        switch item.state {
        case .preparing, .uploading:
            Button("Cancel", systemImage: "xmark.circle", role: .destructive) {
                onCancel()
            }
            .buttonStyle(.bordered)

        case .cancelling:
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                Text("Cancelling…")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

        case .failed:
            EmptyView()

        case .queued, .waitingForNetwork, .waitingForICloud,
             .waitingForAuthentication, .retryScheduled:
            EmptyView()
        }
    }

    private var fallbackName: String {
        String(item.id.prefix(18))
    }

    private var statusText: String {
        switch item.state {
        case .queued:
            String(localized: "Queued")
        case .preparing:
            String(localized: "Preparing original file…")
        case .uploading:
            item.phase == .livePhotoMotion
                ? String(localized: "Uploading Live Photo video…")
                : String(localized: "Uploading…")
        case .cancelling:
            String(localized: "Cancelling…")
        case .waitingForNetwork:
            String(localized: "Waiting for network")
        case .waitingForICloud:
            String(localized: "Waiting for iCloud")
        case .waitingForAuthentication:
            String(localized: "Sign in required")
        case .retryScheduled:
            String(localized: "Retry scheduled")
        case .failed:
            item.lastError ?? String(localized: "Upload failed")
        }
    }

    private var statusColor: Color {
        switch item.state {
        case .failed:
            .red
        case .waitingForNetwork, .waitingForICloud,
             .waitingForAuthentication, .retryScheduled:
            .orange
        default:
            .secondary
        }
    }
}

#Preview {
    NavigationStack {
        UploadDetailsView()
            .environment(SessionManager(restoresSession: false))
    }
}
