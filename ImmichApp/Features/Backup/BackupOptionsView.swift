import SwiftUI

/// Setelan pencadangan yang tidak perlu dilihat setiap hari.
///
/// Dipisah dari layar Backup dengan sengaja: yang di depan menjawab "apa yang
/// belum aman", yang di sini menjawab "dengan syarat apa". Pertanyaan kedua
/// dijawab sekali lalu jarang disentuh lagi, dan menaruh keduanya berdampingan
/// membuat angka yang penting tenggelam di antara sakelar.
struct BackupOptionsView: View {
    @State private var backup = BackupService.shared
    @State private var isOrganizing = false

    var body: some View {
        List {
            networkSection
            albumSyncSection
        }
        .navigationTitle("Backup Options")
        .navigationBarTitleDisplayMode(.inline)
        .settingsSheetCloseButton()
    }

    // MARK: - Jaringan

    private var networkSection: some View {
        Section {
            Toggle(isOn: Bindable(backup).cellularVideos) {
                Text("Videos")
                Text("Use cellular data to backup videos")
            }
            Toggle(isOn: Bindable(backup).cellularPhotos) {
                Text("Photos")
                Text("Use cellular data to backup photos")
            }
        } header: {
            Label("Network Requirements", systemImage: "antenna.radiowaves.left.and.right")
        } footer: {
            // Keduanya mati berarti pencadangan DIAM di luar Wi‑Fi, dan diam
            // tanpa keterangan selalu dibaca sebagai rusak.
            if !backup.cellularPhotos && !backup.cellularVideos {
                Text("Backup only runs on Wi-Fi.")
            }
        }
    }

    // MARK: - Sinkronisasi album

    private var albumSyncSection: some View {
        Section {
            Toggle(isOn: Bindable(backup).syncAlbums) {
                Text("Sync albums")
                Text("Create and upload your photos and videos to the selected albums on Immich")
            }

            Button {
                organize()
            } label: {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Organize into albums")
                        Text("Put existing photos into albums using current sync settings")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 12)
                    if isOrganizing {
                        ProgressView()
                    } else {
                        Image(systemName: "arrow.trianglehead.2.clockwise")
                            .foregroundStyle(.tint)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            // Menyusun ulang saat sakelarnya mati akan memakai aturan yang
            // barusan dimatikan — hasilnya membingungkan, jadi tidak diizinkan.
            .disabled(!backup.syncAlbums || isOrganizing)
        } header: {
            Label("Backup Albums Synchronization", systemImage: "arrow.trianglehead.2.clockwise")
        }
    }

    private func organize() {
        isOrganizing = true
        Task {
            await backup.organizeIntoAlbums()
            isOrganizing = false
        }
    }
}

#Preview {
    NavigationStack { BackupOptionsView() }
}
