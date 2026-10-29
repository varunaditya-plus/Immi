import SwiftUI

/// Daftar tautan publik yang pernah dibuat.
struct SharedLinksView: View {
    @Environment(SessionManager.self) private var session
    @State private var vm: SharedLinksViewModel?
    @State private var editTarget: SharedLinkDTO?
    /// Kegagalan yang berasal dari DAFTAR ini — geser-untuk-hapus dan tarik-untuk
    /// -menyegarkan. Kegagalan di dalam sheet ditampilkan oleh sheet-nya sendiri;
    /// alert dari layar yang tertutup sheet tidak akan pernah terlihat.
    @State private var listError: String?

    var body: some View {
        content
            .navigationTitle("Shared Links")
            .navigationBarTitleDisplayMode(.inline)
            .sheet(item: $editTarget) { link in editSheet(for: link) }
            .alert(
                "Something Went Wrong",
                isPresented: listErrorBinding,
                actions: { Button("OK", role: .cancel) {} },
                message: { Text(listError ?? "") })
            .task {
                if vm == nil {
                    vm = SharedLinksViewModel(
                        repo: SharedLinkRepository(api: APIClient(session: session)))
                }
                if vm?.phase.isIdle == true { await vm?.load() }
            }
    }

    @ViewBuilder
    private var content: some View {
        if let vm {
            switch vm.phase {
            case .idle, .loading:
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

            case .loaded:
                if vm.links.isEmpty {
                    emptyState
                } else {
                    list(vm)
                }

            case .failed(let error):
                errorState(error, vm)
            }
        } else {
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func list(_ vm: SharedLinksViewModel) -> some View {
        List {
            ForEach(vm.links) { link in
                Button {
                    editTarget = link
                } label: {
                    SharedLinkRow(link: link)
                }
                .buttonStyle(.plain)
                // Semua garis pemisah mulai dari tepi kiri TEKS.
                //
                // Bawaannya mengikuti isi baris, dan karena tinggi tiap baris
                // berbeda-beda (ada yang punya deskripsi, ada yang tidak,
                // chip-nya pun berbeda jumlah) panjang garisnya ikut berbeda —
                // itulah yang terlihat "ada yang setengah, ada yang 80%".
                .alignmentGuide(.listRowSeparatorLeading) { _ in
                    sharedLinkThumbnailSide + sharedLinkSpacing
                }
            }
            .onDelete { indices in
                for index in indices {
                    let id = vm.links[index].id
                    Task { listError = await vm.delete(id) }
                }
            }
            // Garis di ATAS baris pertama dibuang: di atasnya nav bar, yang
            // sudah punya batasnya sendiri.
            .listSectionSeparator(.hidden, edges: .top)
        }
        .listStyle(.plain)
        // Penulisan `@State`-nya lewat `MainActor.run`: closure `refreshable`
        // bertanda `@Sendable`, jadi ia nonisolated dan menulis state milik view
        // langsung dari sana adalah pelanggaran isolasi — sekarang peringatan,
        // di Swift 6 kesalahan.
        .refreshable {
            let message = await vm.refresh()
            await MainActor.run { listError = message }
        }
    }

    private func editSheet(for link: SharedLinkDTO) -> some View {
        SharedLinkEditSheet(
            link: link,
            publicURL: link.publicURL(base: session.baseURL),
            // `guard let`, bukan `vm?.` — rantai opsional pada metode yang sudah
            // mengembalikan `String?` menghasilkan `String??`, dan itu bukan tipe
            // yang diminta closure-nya.
            onSave: { edit in
                guard let vm else { return String(localized: "Failed to update link") }
                return await vm.update(link.id, edit: edit)
            },
            onDelete: {
                guard let vm else { return String(localized: "Failed to delete link") }
                return await vm.delete(link.id)
            })
    }

    private var listErrorBinding: Binding<Bool> {
        Binding(
            get: { listError != nil },
            set: { if !$0 { listError = nil } })
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("No Shared Links", systemImage: "link")
        } description: {
            Text("Links you create from an album or a photo will show up here.")
        }
    }

    private func errorState(_ error: String, _ vm: SharedLinksViewModel) -> some View {
        ContentUnavailableView {
            Label("Failed to Load", systemImage: "exclamationmark.triangle")
        } description: {
            Text(error)
        } actions: {
            Button("Retry") { Task { await vm.retry() } }
                .buttonStyle(.borderedProminent)
        }
    }
}

// MARK: - Baris

/// Ukuran sampul dan sela di baris tautan.
///
/// Konstanta, bukan angka yang ditulis ulang di dua tempat: penjajaran garis
/// pemisah dihitung dari keduanya.
let sharedLinkThumbnailSide: CGFloat = 72
let sharedLinkSpacing: CGFloat = 14

struct SharedLinkRow: View {
    let link: SharedLinkDTO

    var body: some View {
        HStack(alignment: .top, spacing: sharedLinkSpacing) {
            thumbnail
                .frame(width: sharedLinkThumbnailSide, height: sharedLinkThumbnailSide)
                .clipShape(RoundedRectangle(cornerRadius: 12))

            VStack(alignment: .leading, spacing: 4) {
                Text(link.isAlbum ? "ALBUM SHARE" : "INDIVIDUAL SHARE")
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(.tint)

                if let name = link.displayName {
                    Text(name)
                        .font(.subheadline)
                        .lineLimit(1)
                }

                expiry

                if !permissions.isEmpty {
                    HStack(spacing: 8) {
                        ForEach(permissions, id: \.self) { permission in
                            Text(permission)
                                .font(.caption)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 5)
                                .overlay {
                                    Capsule().stroke(.secondary.opacity(0.5))
                                }
                        }
                    }
                    .padding(.top, 2)
                }
            }

            Spacer(minLength: 0)
        }
        .padding(.vertical, 8)
        .contentShape(Rectangle())
    }

    /// `Color.clear.overlay` supaya gambar yang mengisi tidak melaporkan ukuran
    /// lebih besar dari petaknya — sama seperti kartu di Library.
    @ViewBuilder
    private var thumbnail: some View {
        let policy = AssetVisibilityPolicy()
        Color.clear.overlay {
            if let album = link.album {
                AlbumCoverImage(album: album)
            } else if let asset = link.assets?.first(where: {
                $0.isVisibleInAlbum && policy.allows(id: $0.id)
            }) {
                AuthImage(assetId: asset.id, thumbhash: asset.thumbhash)
            } else {
                Rectangle()
                    .fill(.fill.tertiary)
                    .overlay {
                        Image(systemName: "link")
                            .foregroundStyle(.secondary)
                    }
            }
        }
    }

    @ViewBuilder
    private var expiry: some View {
        if let expiresAt = link.expiresAt {
            if link.isExpired {
                Label("Expired", systemImage: "timer")
                    .font(.subheadline)
                    .foregroundStyle(.red)
            } else {
                Label {
                    Text("Expires \(expiresAt, format: .relative(presentation: .named))")
                } icon: {
                    Image(systemName: "timer")
                }
                .font(.subheadline)
                .foregroundStyle(.secondary)
            }
        }
    }

    /// Hanya izin yang MENYALA yang ditampilkan — deretan chip yang selalu sama
    /// panjangnya tidak memberi tahu apa pun.
    private var permissions: [String] {
        var result: [String] = []
        if link.allowDownload { result.append(String(localized: "Download")) }
        if link.showMetadata { result.append(String(localized: "EXIF")) }
        if link.allowUpload { result.append(String(localized: "Upload")) }
        return result
    }
}
