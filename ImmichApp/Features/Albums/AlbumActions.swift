import SwiftUI

/// Aksi album yang dipakai bersama oleh context menu di daftar album dan menu
/// elipsis di detail album.
///
/// Dikumpulkan dalam satu tipe supaya keduanya tidak bisa berbeda isi — dulu
/// menu di dua tempat itu ditulis terpisah dan gampang menyimpang.
struct AlbumActionsMenu: View {
    var onEdit: () -> Void
    var onAddUser: () -> Void
    var onCreateLink: () -> Void
    var onDelete: () -> Void

    var body: some View {
        Button(action: onEdit) {
            Label("Edit Album", systemImage: "pencil")
        }

        Button(action: onAddUser) {
            Label("Add User", systemImage: "person.badge.plus")
        }

        Button(action: onCreateLink) {
            Label("Create Shared Link", systemImage: "link")
        }

        Divider()

        Button(role: .destructive, action: onDelete) {
            Label("Delete Album", systemImage: "trash")
        }
    }
}

/// Pembungkus supaya URL bisa dipakai `sheet(item:)`.
///
/// `URL` sendiri tidak `Identifiable`, dan menambahkan konformansi itu ke tipe
/// milik Foundation berisiko bentrok dengan deklarasi serupa di tempat lain.
struct SharedLinkPresentation: Identifiable {
    let id = UUID()
    let url: URL

    /// Membuat tautan publik baru untuk sebuah album.
    ///
    /// Used by the album list and Library. Errors reach their existing action
    /// feedback instead of making a failed tap appear to do nothing.
    @MainActor
    static func create(
        albumId: String,
        session: SessionManager
    ) async throws -> SharedLinkPresentation {
        let repo = AlbumRepository(api: APIClient(session: session))
        let link = try await repo.createSharedLink(albumId: albumId)
        guard let url = link.publicURL(base: session.baseURL) else {
            throw APIError.invalidURL
        }
        return SharedLinkPresentation(url: url)
    }
}

/// Pratinjau context menu album: sampulnya saja.
///
/// Tanpa pratinjau kustom, iOS memakai kartunya apa adanya — judul dan jumlah
/// item ikut terseret dalam animasi zoom dan terlihat meregang. Sampulnya saja
/// membesar dengan bersih.
struct AlbumCoverPreview: View {
    let album: AlbumResponseDTO
    /// Disuntikkan lewat parameter, BUKAN `@Environment`: pratinjau context menu
    /// dirender di hosting controller terpisah yang tidak mewarisi environment
    /// view pemanggil, dan `AuthImage` crash tanpa `SessionManager`.
    let session: SessionManager

    private let side: CGFloat = 260

    var body: some View {
        AlbumCoverImage(
            album: album,
            size: "preview",
            pixelSize: 1200,
            placeholderFont: .largeTitle)
            .frame(width: side, height: side)
            // `AuthImage` mengisi framenya (`contentMode: .fill`), jadi sampul
            // yang tidak persegi akan meluber keluar kotak pratinjau tanpa ini.
            .clipShape(RoundedRectangle(cornerRadius: 14))
            .environment(session)
    }
}

/// Sheet ubah nama & deskripsi album.
struct AlbumEditSheet: View {
    let album: AlbumResponseDTO
    /// Callback sinkron sesudah PATCH berhasil. Kerja async sengaja dimiliki
    /// sheet agar tidak melewati escaping async closure milik value-view.
    var onSaved: (AlbumResponseDTO) -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(SessionManager.self) private var session
    @State private var name: String
    @State private var description: String
    @State private var isSaving = false
    @State private var errorMessage: String?
    @State private var successFeedback = 0
    @FocusState private var isNameFocused: Bool

    init(
        album: AlbumResponseDTO,
        onSaved: @escaping (AlbumResponseDTO) -> Void
    ) {
        self.album = album
        self.onSaved = onSaved
        _name = State(initialValue: album.albumName)
        _description = State(initialValue: album.description ?? "")
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Name") {
                    TextField("Album Name", text: $name)
                        .focused($isNameFocused)
                }

                Section("Description") {
                    TextField("Description", text: $description, axis: .vertical)
                        .lineLimit(3...6)
                }
            }
            .navigationTitle("Edit Album")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .disabled(trimmedName.isEmpty || isSaving)
                }
            }
            .alert(
                "Failed to Update Album",
                isPresented: Binding(
                    get: { errorMessage != nil },
                    set: { if !$0 { errorMessage = nil } }),
                actions: { Button("OK", role: .cancel) {} },
                message: { Text(errorMessage ?? "") })
            .sensoryFeedback(.success, trigger: successFeedback)
            .onAppear { isNameFocused = true }
        }
    }

    private var trimmedName: String {
        name.trimmingCharacters(in: .whitespaces)
    }

    @MainActor
    private func save() {
        // Jangan membaca DynamicProperty milik View dari dalam task. SwiftUI
        // bebas mengganti value `AlbumEditSheet` setelah tombol ditekan; pada
        // build teroptimasi capture itu pernah meninggalkan backing String yang
        // sudah tidak sah (terlihat sebagai nama acak lalu EXC_BAD_ACCESS di
        // `trimmingCharacters`). Decode UTF-8 membuat storage milik sendiri,
        // bukan sekadar copy-on-write yang masih berbagi buffer lama.
        let submittedName = String(decoding: name.utf8, as: UTF8.self)
            .trimmingCharacters(in: .whitespaces)
        let submittedDescription = String(decoding: description.utf8, as: UTF8.self)
            .trimmingCharacters(in: .whitespaces)
        let originalAlbum = album
        let savedAction = onSaved
        let repository = AlbumRepository(api: APIClient(session: session))

        isSaving = true
        Task { @MainActor in
            do {
                try await repository.update(
                    originalAlbum.id,
                    name: submittedName,
                    description: .some(
                        submittedDescription.isEmpty ? nil : submittedDescription))

                var updated = originalAlbum
                updated.albumName = submittedName
                updated.description = submittedDescription.isEmpty
                    ? nil
                    : submittedDescription
                updated.updatedAt = Date()
                savedAction(updated)

                isSaving = false
                successFeedback += 1
                try? await Task.sleep(for: .milliseconds(50))
                dismiss()
            } catch {
                isSaving = false
                errorMessage = (error as? APIError)?.errorDescription
                    ?? String(localized: "Failed to update album")
            }
        }
    }
}

/// Sheet pemilih pengguna untuk dibagikan aksesnya ke album.
struct AlbumAddUserSheet: View {
    var onAdd: ([String]) async -> String?

    @Environment(SessionManager.self) private var session
    @Environment(\.dismiss) private var dismiss
    @State private var vm: AlbumUserPickerViewModel?
    @State private var selectedIDs: Set<String> = []
    @State private var isSaving = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            VStack(spacing: 12) {
                if let errorMessage {
                    Text(errorMessage)
                        .font(.callout)
                        .foregroundStyle(.red)
                        .padding(.horizontal)
                }
                content
            }
                .navigationTitle("Add User")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { dismiss() }
                            .disabled(isSaving)
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button {
                            Task { await addSelectedUsers() }
                        } label: {
                            if isSaving { ProgressView() } else { Text("Add") }
                        }
                        .disabled(selectedIDs.isEmpty || isSaving)
                    }
                }
                .task { await load() }
                .interactiveDismissDisabled(isSaving)
        }
    }

    @ViewBuilder
    private var content: some View {
        switch vm?.phase ?? .loading {
        case .idle, .loading:
            ProgressView()
        case .failed(let message):
            ContentUnavailableView {
                Label("Failed to Load", systemImage: "exclamationmark.triangle")
            } description: {
                Text(message)
            } actions: {
                Button("Retry") { Task { await vm?.load() } }
                    .buttonStyle(.borderedProminent)
            }
        case .loaded:
            if vm?.users.isEmpty != false {
                ContentUnavailableView(
                    "No Other Users",
                    systemImage: "person.2",
                    description: Text("There is no one else on this server to share with."))
            } else {
                list
            }
        }
    }

    private var list: some View {
        List(vm?.users ?? []) { user in
            Button {
                toggle(user)
            } label: {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(user.name)
                        Text(user.email)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if selectedIDs.contains(user.id) {
                        Image(systemName: "checkmark")
                            .foregroundStyle(.tint)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(isSaving)
        }
    }

    private func toggle(_ user: UserResponseDTO) {
        if selectedIDs.contains(user.id) {
            selectedIDs.remove(user.id)
        } else {
            selectedIDs.insert(user.id)
        }
    }

    private func load() async {
        if vm == nil {
            vm = AlbumUserPickerViewModel(
                repo: AlbumRepository(api: APIClient(session: session)),
                currentUserID: session.currentUser?.id)
        }
        await vm?.load()
    }

    private func addSelectedUsers() async {
        guard !isSaving, !selectedIDs.isEmpty else { return }
        isSaving = true
        errorMessage = nil
        defer { isSaving = false }
        if let message = await onAdd(Array(selectedIDs)) {
            errorMessage = message
        } else {
            dismiss()
        }
    }
}

@MainActor
@Observable
final class AlbumUserPickerViewModel {
    private(set) var users: [UserResponseDTO] = []
    private(set) var phase: LoadingPhase<Void> = .idle
    private let repo: AlbumRepository
    private let currentUserID: String?

    init(repo: AlbumRepository, currentUserID: String?) {
        self.repo = repo
        self.currentUserID = currentUserID
    }

    func load() async {
        switch phase {
        case .loading, .loaded: return
        case .idle, .failed: break
        }
        phase = .loading
        do {
            let fetched = try await repo.users()
            try Task.checkCancellation()
            users = fetched.filter { $0.id != currentUserID }
            phase = .loaded(())
        } catch {
            if Task.isCancelled || error is CancellationError {
                phase = .idle
            } else {
                phase = .failed((error as? APIError)?.errorDescription
                    ?? String(localized: "Failed to load users"))
            }
        }
    }
}
