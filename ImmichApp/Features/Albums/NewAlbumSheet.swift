import SwiftUI

/// Membuat album baru: judul, deskripsi, dan — kalau diminta — fotonya sekalian.
///
/// Satu sheet untuk dua tempat yang kebutuhannya beda tipis. Dibuka dari layar
/// Albums, ia layar "New Album" utuh dengan pemilih foto. Dibuka dari sheet
/// "Add to Album", fotonya SUDAH ditentukan sebelum sheet ini muncul — menawarkan
/// pemilih foto lagi di situ hanya menanyakan hal yang barusan dijawab.
struct NewAlbumSheet: View {
    var allowsAssetSelection = true
    var photoRepository: SearchRepository? = nil
    /// Membuat albumnya. Mengembalikan pesan kesalahan; nil berarti berhasil dan
    /// sheet-nya menutup.
    var onCreate: (_ name: String, _ description: String, _ assetIds: [String]) async -> String?

    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var description = ""
    @State private var assetIDs: [String] = []
    @State private var isCreating = false
    @State private var errorMessage: String?
    @State private var showPhotoPicker = false
    @State private var successFeedback = 0
    @FocusState private var isNameFocused: Bool

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 28) {
                    VStack(spacing: 8) {
                        albumCover
                        if allowsAssetSelection {
                            Button(photoButtonTitle) { showPhotoPicker = true }
                                .font(.subheadline.weight(.semibold))
                                .padding(.horizontal, 14).padding(.vertical, 6)
                                .background(Color(.tertiarySystemFill), in: .capsule)
                                .frame(minHeight: 44)
                                .contentShape(.capsule)
                        }
                    }
                    VStack(spacing: 12) {
                        TextField("Album Name", text: $name)
                            .font(.headline)
                            .focused($isNameFocused)
                            .padding(.horizontal, 16).padding(.vertical, 14)
                            .background(Color(.secondarySystemGroupedBackground), in: .capsule)
                        TextField("Add Description", text: $description, axis: .vertical)
                            .lineLimit(1...4)
                            .padding(.horizontal, 16).padding(.vertical, 14)
                            .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 20))
                    }
                    .textFieldStyle(.plain)
                }
                .frame(maxWidth: .infinity)
                .padding(20)
            }
            .scrollDismissesKeyboard(.interactively)
            .background(Color(.systemGroupedBackground))
            .navigationTitle("New Album")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { toolbar }
            .sheet(isPresented: $showPhotoPicker) {
                AddPhotosToAlbumSheet(existingIDs: Set(assetIDs), viewModel: photoRepository.map {
                    AlbumPhotoPickerViewModel(repo: $0, existingIDs: Set(assetIDs))
                }) { picked in
                    assetIDs.append(contentsOf: picked)
                }
            }
            .alert(
                "Failed to Create Album",
                isPresented: errorBinding,
                actions: { Button("OK", role: .cancel) {} },
                message: { Text(errorMessage ?? "") })
            .sensoryFeedback(.success, trigger: successFeedback)
            .onAppear { isNameFocused = true }
        }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .cancellationAction) {
            Button("Close", systemImage: "xmark") { dismiss() }
                .labelStyle(.iconOnly)
        }
        ToolbarItem(placement: .confirmationAction) {
            Button("Create") { create() }
                .buttonStyle(.glassProminent)
                .disabled(trimmedName.isEmpty || isCreating)
        }
    }

    private var albumCover: some View {
        Color(.tertiarySystemFill)
            .overlay {
                if let id = assetIDs.first { AuthImage(assetId: id) }
                else { Image(systemName: "photo.fill").font(.largeTitle).foregroundStyle(.tertiary) }
            }
            .aspectRatio(1, contentMode: .fit)
            .frame(maxWidth: 200)
            .clipShape(.rect(cornerRadius: 20))
            .accessibilityHidden(true)
    }

    private var photoButtonTitle: LocalizedStringKey {
        assetIDs.isEmpty
            ? "Add Photos"
            : "^[\(assetIDs.count) Photo](inflect: true) Selected"
    }

    private var trimmedName: String {
        name.trimmingCharacters(in: .whitespaces)
    }

    private var errorBinding: Binding<Bool> {
        Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } })
    }

    private func create() {
        isCreating = true
        Task {
            errorMessage = await onCreate(
                trimmedName,
                description.trimmingCharacters(in: .whitespaces),
                assetIDs)
            isCreating = false
            guard errorMessage == nil else { return }
            successFeedback += 1
            // Beri SwiftUI satu frame untuk mengirim sensory feedback sebelum
            // seluruh hierarchy sheet dilepas oleh dismiss.
            try? await Task.sleep(for: .milliseconds(50))
            dismiss()
        }
    }
}
