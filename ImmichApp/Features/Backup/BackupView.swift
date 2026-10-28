import SwiftUI
import UIKit

/// Layar pencadangan.
///
/// Susunannya mengikuti aplikasi Immich resmi karena susunan itu menjawab satu
/// pertanyaan dengan benar: **apa yang belum aman?** Tiga angka berurutan —
/// seluruhnya, yang sudah naik, sisanya — dan sisa itulah satu-satunya yang
/// perlu diperhatikan. Gayanya milik kita.
struct BackupView: View {
    @Environment(SessionManager.self) private var session
    @Environment(\.scenePhase) private var scenePhase
    @State private var backup = BackupService.shared
    @State private var sharedUploads = SharedUploadService.shared
    @State private var library = LocalPhotoLibrary.shared
    @State private var albums: [LocalAlbum] = []
    @State private var isExpanded = false
    @State private var showOptions = false
    @State private var showPicker = false
    @State private var showUploadDetails = false

    /// Berapa album yang terlihat sebelum daftarnya harus dibentangkan sendiri.
    ///
    /// Pustaka orang bisa berisi puluhan album, dan daftar sepanjang itu
    /// mendorong ketiga angka — bagian yang paling penting di layar ini — jauh
    /// ke bawah lipatan.
    private static let collapsedLimit = 10

    var body: some View {
        List {
            albumsSection
            countsSection
            settingsSection
        }
        .navigationTitle("Backup")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showOptions = true
                } label: {
                    Image(systemName: "gearshape")
                }
                .accessibilityLabel("Backup Options")
            }
        }
        .navigationDestination(isPresented: $showOptions) { BackupOptionsView() }
        .navigationDestination(isPresented: $showPicker) { DeviceAlbumsView() }
        .navigationDestination(isPresented: $showUploadDetails) { UploadDetailsView() }
        .task {
            backup.configure(session: session)
            await sharedUploads.refreshPending(session: session)
            albums = await library.albums()
            await backup.prepare()
        }
        // Mencentang album mengubah kumpulan fotonya, bukan cuma hitungannya —
        // jadi yang dipanggil `prepare()`, yang membaca ulang pustakanya, bukan
        // `refreshCounts()` yang hanya menghitung isi lama.
        .onChange(of: library.selectedAlbumIDs) {
            Task {
                await backup.prepare()
                // `start()` IKUT dipanggil, tidak cuma menghitung ulang.
                //
                // Memilih album adalah satu-satunya cara menambah pekerjaan ke
                // antrean pencadangan. Tanpa baris ini angka "Remainder" naik
                // seketika lalu diam — dan satu-satunya cara menjalankannya
                // adalah menutup dan membuka aplikasinya lagi, yang tidak
                // pernah terbaca sebagai sesuatu yang disengaja.
                backup.start()
                BackupScheduler.schedule()
            }
        }
        .onChange(of: library.currentSelectionScanID) { backup.refreshCounts() }
        .onChange(of: SwiftDataManager.shared.backupMappingRevision) { backup.refreshCounts() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { library.refreshAuthorizationStatus() }
        }
    }

    // MARK: - Album

    private var albumsSection: some View {
        Section {
            if selectedAlbums.isEmpty {
                Text("None selected")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(visibleAlbums) { album in
                    LabeledContent(album.title) {
                        Text("\(album.count)")
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                }
                if selectedAlbums.count > Self.collapsedLimit {
                    expandButton
                }
            }

            Button("Select") { showPicker = true }
        } header: {
            Text("Backup Albums")
        } footer: {
            Text("Albums to be backed up.")
        }
    }

    private var expandButton: some View {
        Button {
            withAnimation { isExpanded.toggle() }
        } label: {
            HStack {
                Text(isExpanded
                     ? "Show Less"
                     : "and \(selectedAlbums.count - Self.collapsedLimit) more")
                Spacer()
                Image(systemName: "chevron.down")
                    .font(.footnote.weight(.semibold))
                    .rotationEffect(.degrees(isExpanded ? 180 : 0))
            }
            .contentShape(Rectangle())
        }
    }

    // MARK: - Turunan daftar album

    /// Album TERPILIH saja, terbanyak isinya lebih dulu.
    ///
    /// Kartu ini ringkasan, bukan pemilih — pemilihnya di layar `Select`. Dan
    /// dengan daftar yang terpotong sepuluh, urutan menentukan apa yang
    /// benar-benar terlihat, jadi bukan urutan sembarang dari PhotoKit.
    private var selectedAlbums: [LocalAlbum] {
        albums
            .filter { library.selectedAlbumIDs.contains($0.id) }
            .sorted { $0.count > $1.count }
    }

    private var visibleAlbums: [LocalAlbum] {
        isExpanded ? selectedAlbums : Array(selectedAlbums.prefix(Self.collapsedLimit))
    }


    // MARK: - Hitungan

    private var countsSection: some View {
        Section {
            countRow(
                title: "Total",
                caption: "All unique photos and videos from selected albums",
                value: backup.total,
                tint: .primary)

            countRow(
                title: "Backup",
                caption: "Backed up photos and videos",
                value: backup.backedUp,
                tint: .green)

            countRow(
                title: "Remainder",
                caption: "Remaining photos and videos to back up from selection",
                value: backup.remainder,
                tint: backup.remainder == 0 ? .secondary : .orange)

            if let title = backup.queueStatusTitle,
               let body = backup.queueStatusBody,
               backup.pendingThisRun > 0 {
                Label {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(title)
                        Text(body)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } icon: {
                    Image(systemName: queueStatusSymbol)
                        .foregroundStyle(backup.isUploading ? Color.accentColor : .orange)
                }
            }

            if !backup.failures.isEmpty {
                Button("Retry Failed Uploads") { backup.retryFailedUploads() }
            }

        } footer: {
            VStack(alignment: .leading, spacing: 10) {
                if backup.isUploading {
                    uploadProgress
                } else if backup.hasStatusError, let error = backup.lastError {
                    // Alasan kegagalan ditulis apa adanya, bukan diringkas jadi
                    // "terjadi kesalahan". Yang bisa diperbaiki pengguna hanya yang
                    // bisa dibacanya.
                    Label(error, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                }

            }
        }
    }

    private func countRow(
        title: String, caption: String, value: Int, tint: Color
    ) -> some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(caption)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 12)
            Text("\(value)")
                .font(.title3.weight(.semibold))
                // Angka yang berubah tiap unggahan tidak boleh menggeser
                // barisnya; lebar digit tetap menahannya diam.
                .monospacedDigit()
                .foregroundStyle(tint)
        }
        .padding(.vertical, 2)
    }

    private var uploadProgress: some View {
        VStack(alignment: .leading, spacing: 6) {
            ProgressView(
                value: Double(backup.uploadedThisRun),
                total: Double(max(1, backup.pendingThisRun)))
            Text("Backing up \(backup.uploadedThisRun + 1) of \(backup.pendingThisRun)…")
        }
        .padding(.top, 6)
    }

    private var queueStatusSymbol: String {
        if backup.waitingForAuthentication > 0 { return "person.crop.circle.badge.exclamationmark" }
        if backup.waitingForICloud > 0 { return "icloud.and.arrow.down" }
        if backup.waitingForNetwork > 0 { return "wifi.exclamationmark" }
        if backup.scheduledForRetry > 0 { return "arrow.clockwise" }
        if backup.isUploading { return "arrow.up.circle" }
        return "tray.full"
    }

    // MARK: - Setelan

    private var settingsSection: some View {
        Section {
            Toggle("Enable Backup", isOn: Bindable(backup).isEnabled)
        } footer: {
            VStack(alignment: .leading, spacing: 12) {
                Text(statusText)

                if sharedUploads.items.contains(where: { $0.item.state == .failed }) {
                    Label("Some shared uploads need attention. View Details to retry or remove them.",
                          systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                }
                if let error = sharedUploads.lastError {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                }

                // Rincian antrean sengaja menjadi aksi paling bawah di layar,
                // mengikuti penempatan footer aplikasi Immich resmi.
                if backup.remainder > 0 || !backup.uploadItems.isEmpty
                    || !sharedUploads.items.isEmpty || sharedUploads.lastError != nil {
                    Button {
                        showUploadDetails = true
                    } label: {
                        HStack {
                            Text("View Details")
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.footnote.weight(.semibold))
                        }
                        .frame(maxWidth: .infinity)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Color.accentColor)
                }
            }
        }
    }

    private var statusText: String {
        BackupStatus(backup: backup, sharedUploads: sharedUploads).explanation(
            backup: backup,
            backgroundRefreshAvailable: UIApplication.shared.backgroundRefreshStatus == .available,
            isOnline: NetworkMonitor.shared.isOnline,
            isExpensive: NetworkMonitor.shared.isExpensive)
    }
}

#Preview {
    NavigationStack {
        BackupView().environment(SessionManager())
    }
}
