import SwiftUI

/// Review grup foto serupa dari Duplicate Detection Immich.
///
/// Tiap kartu sengaja berdiri sendiri: pengguna dapat menyelesaikan grup kecil
/// tanpa masuk mode seleksi global yang rawan menghapus pilihan dari grup lain.
struct DuplicatesView: View {
    @Environment(SessionManager.self) private var session
    @State private var viewModel: DuplicatesViewModel?

    var body: some View {
        content
            .navigationTitle("Duplicates")
            .navigationBarTitleDisplayMode(.inline)
            .alert("Action Failed", isPresented: actionErrorBinding) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(viewModel?.actionError ?? "")
            }
            .task { await start() }
    }

    @ViewBuilder
    private var content: some View {
        if let viewModel {
            switch viewModel.phase {
            case .idle, .loading:
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

            case .loaded:
                if viewModel.groups.isEmpty {
                    emptyState
                } else {
                    groupList(viewModel)
                }

            case .failed(let message):
                failureState(message, viewModel)
            }
        } else {
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func groupList(_ viewModel: DuplicatesViewModel) -> some View {
        ScrollView {
            LazyVStack(spacing: 18) {
                reviewExplanation(groupCount: viewModel.groups.count)

                ForEach(viewModel.groups) { group in
                    DuplicateGroupCard(
                        group: group,
                        isWorking: viewModel.workingGroupIDs.contains(group.id),
                        onResolve: { keepIDs in
                            Task { await viewModel.resolve(group, keeping: keepIDs) }
                        },
                        onKeepAll: {
                            Task { await viewModel.keepAll(group) }
                        })
                    .transition(.scale(scale: 0.96).combined(with: .opacity))
                }
            }
            .padding(16)
            .animation(.smooth, value: viewModel.groups.map(\.id))
        }
        .refreshable { await viewModel.load() }
    }

    private func reviewExplanation(groupCount: Int) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("\(groupCount) groups to review")
                .font(.headline)
            Text("Select the best items to keep. Unselected items will be moved to Trash after confirmation.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 4)
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("No Duplicates", systemImage: "square.on.square")
        } description: {
            Text("No duplicate groups need review.")
        }
    }

    private func failureState(
        _ message: String,
        _ viewModel: DuplicatesViewModel
    ) -> some View {
        ContentUnavailableView {
            Label("Failed to Load", systemImage: "exclamationmark.triangle")
        } description: {
            Text(message)
        } actions: {
            Button("Retry") { Task { await viewModel.load() } }
                .buttonStyle(.borderedProminent)
        }
    }

    private var actionErrorBinding: Binding<Bool> {
        Binding(
            get: { viewModel?.actionError != nil },
            set: { if !$0 { viewModel?.actionError = nil } })
    }

    private func start() async {
        if viewModel == nil {
            let api = APIClient(session: session)
            viewModel = DuplicatesViewModel(
                repository: DuplicateRepository(api: api),
                assetRepository: AssetDetailRepository(api: api),
                usesResolveEndpoint: (session.serverCompatibility?.version.major ?? 3) >= 3)
        }
        if viewModel?.phase.isIdle == true { await viewModel?.load() }
    }
}

private struct DuplicateGroupCard: View {
    let group: DuplicateGroupDTO
    let isWorking: Bool
    let onResolve: (Set<String>) -> Void
    let onKeepAll: () -> Void

    @State private var keepAssetIDs: Set<String>
    @State private var showsResolveConfirmation = false
    @State private var showsKeepAllConfirmation = false

    init(
        group: DuplicateGroupDTO,
        isWorking: Bool,
        onResolve: @escaping (Set<String>) -> Void,
        onKeepAll: @escaping () -> Void
    ) {
        self.group = group
        self.isWorking = isWorking
        self.onResolve = onResolve
        self.onKeepAll = onKeepAll
        _keepAssetIDs = State(initialValue: group.initialKeepAssetIDs)
    }

    private var trashCount: Int {
        group.assets.count - keepAssetIDs.intersection(group.assets.map(\.id)).count
    }

    /// `confirmationDialog` meneruskan judulnya ke dialog native sebagai teks
    /// biasa. Berbeda dari `Text`, markup Automatic Grammar Agreement tidak
    /// dirender di jalur itu dan justru terlihat mentah di layar. Bentuk tunggal
    /// dan jamak dibuat eksplisit, sama seperti copy notifikasi backup.
    private var resolveConfirmationTitle: String {
        trashCount == 1
            ? String(localized: "Move 1 item to Trash?")
            : String(localized: "Move \(trashCount) items to Trash?")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            assetStrip
            actions
        }
        .padding(14)
        .background(.background.secondary, in: .rect(cornerRadius: 18))
        .overlay {
            RoundedRectangle(cornerRadius: 18)
                .stroke(.separator.opacity(0.45), lineWidth: 0.5)
        }
        .opacity(isWorking ? 0.65 : 1)
        .allowsHitTesting(!isWorking)
        .confirmationDialog(
            resolveConfirmationTitle,
            isPresented: $showsResolveConfirmation,
            titleVisibility: .visible
        ) {
            Button("Move to Trash", role: .destructive) {
                onResolve(keepAssetIDs)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Selected items will be kept. You can restore the others from Trash.")
        }
        .confirmationDialog(
            "Keep every item?",
            isPresented: $showsKeepAllConfirmation,
            titleVisibility: .visible
        ) {
            Button("Keep All", action: onKeepAll)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This group will be dismissed and its items will no longer be marked as duplicates.")
        }
        .overlay {
            if isWorking { ProgressView().controlSize(.large) }
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Similar Items")
                    .font(.headline)
                Text("\(group.assets.count) items · tap to keep or trash")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if !group.suggestedKeepAssetIds.isEmpty {
                Label("Suggested", systemImage: "sparkles")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tint)
            }
        }
    }

    private var assetStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(alignment: .top, spacing: 12) {
                ForEach(group.assets) { asset in
                    DuplicateAssetChoice(
                        asset: asset,
                        isKept: keepAssetIDs.contains(asset.id),
                        isSuggested: group.suggestedKeepAssetIds.contains(asset.id)) {
                            if keepAssetIDs.contains(asset.id) {
                                // Setidaknya satu aset harus bertahan. Mencegah
                                // ketukan terakhir lebih jelas daripada baru
                                // menolak saat tombol Resolve ditekan.
                                if keepAssetIDs.count > 1 { keepAssetIDs.remove(asset.id) }
                            } else {
                                keepAssetIDs.insert(asset.id)
                            }
                        }
                }
            }
            .padding(.vertical, 2)
        }
        .scrollClipDisabled()
    }

    private var actions: some View {
        HStack(spacing: 10) {
            Button {
                showsKeepAllConfirmation = true
            } label: {
                Label("Keep All", systemImage: "checkmark.circle")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)

            Button(role: .destructive) {
                showsResolveConfirmation = true
            } label: {
                Label("Trash \(trashCount)", systemImage: "trash")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(.red)
            .disabled(trashCount == 0 || keepAssetIDs.isEmpty)
        }
    }
}

private struct DuplicateAssetChoice: View {
    let asset: AssetResponseDTO
    let isKept: Bool
    let isSuggested: Bool
    let onToggle: () -> Void

    var body: some View {
        Button(action: onToggle) {
            VStack(alignment: .leading, spacing: 7) {
                thumbnail
                Text(asset.originalFileName)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Text(metadata)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .frame(width: 154, alignment: .leading)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(asset.originalFileName)
        .accessibilityValue(isKept ? "Keep" : "Move to Trash")
        .accessibilityHint("Double tap to change this choice")
    }

    private var thumbnail: some View {
        AuthImage(
            assetId: asset.id,
            thumbhash: asset.thumbhash,
            pixelSize: 600)
            .frame(width: 154, height: 154)
            .clipShape(.rect(cornerRadius: 12))
            .overlay(alignment: .topLeading) {
                statusBadge
                    .padding(8)
            }
            .overlay {
                RoundedRectangle(cornerRadius: 12)
                    .stroke(isKept ? Color.green : Color.red, lineWidth: 3)
            }
    }

    private var statusBadge: some View {
        HStack(spacing: 4) {
            Image(systemName: isKept ? "checkmark.circle.fill" : "trash.circle.fill")
            Text(isKept ? "Keep" : "Trash")
            if isSuggested { Image(systemName: "sparkles") }
        }
        .font(.caption2.weight(.bold))
        .foregroundStyle(.white)
        .padding(.horizontal, 7)
        .padding(.vertical, 5)
        .background(isKept ? Color.green : Color.red, in: .capsule)
    }

    private var metadata: String {
        var parts: [String] = []
        if let width = asset.exifInfo?.exifImageWidth,
           let height = asset.exifInfo?.exifImageHeight {
            parts.append("\(width)×\(height)")
        }
        if let bytes = asset.exifInfo?.fileSizeInByte {
            parts.append(ByteCountFormatter.string(
                fromByteCount: Int64(bytes), countStyle: .file))
        }
        if parts.isEmpty {
            parts.append(asset.fileCreatedAt.formatted(date: .abbreviated, time: .omitted))
        }
        return parts.joined(separator: " · ")
    }
}
