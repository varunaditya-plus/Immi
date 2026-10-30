import SwiftUI

struct AlbumKeyPhotoPicker: View {
    let assets: [AssetLite]
    let selectedID: String?
    var onSave: (String) async -> String?

    @Environment(\.dismiss) private var dismiss
    @State private var pendingID: String?
    @State private var isSaving = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 2), count: 3), spacing: 2) {
                    ForEach(assets) { asset in
                        Button { pendingID = asset.id } label: {
                            Color.clear
                                .aspectRatio(1, contentMode: .fit)
                                .overlay { AuthImage(assetId: asset.id, thumbhash: asset.thumbhash) }
                                .clipped()
                                .overlay(alignment: .bottomTrailing) {
                                    if pendingID == asset.id {
                                        Image(systemName: "checkmark.circle.fill")
                                            .font(.title2)
                                            .symbolRenderingMode(.palette)
                                            .foregroundStyle(.white, .blue)
                                            .padding(6)
                                    }
                                }
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(Text(asset.createdAt, format: .dateTime.year().month().day()))
                        .accessibilityAddTraits(pendingID == asset.id ? [.isSelected] : [])
                        .disabled(isSaving)
                    }
                }
            }
            .navigationTitle("Choose Key Photo")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }.disabled(isSaving)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button { Task { await save() } } label: {
                        if isSaving { ProgressView() } else { Text("Done") }
                    }
                    .disabled(pendingID == nil || isSaving)
                }
            }
            .alert("Action Failed", isPresented: Binding(
                get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
                Button("OK", role: .cancel) {}
            } message: { Text(errorMessage ?? "") }
            .onAppear { pendingID = selectedID.flatMap { id in assets.contains { $0.id == id } ? id : nil } }
            .interactiveDismissDisabled(isSaving)
        }
    }

    private func save() async {
        guard let pendingID, assets.contains(where: { $0.id == pendingID }) else { return }
        if pendingID == selectedID { dismiss(); return }
        isSaving = true
        errorMessage = await onSave(pendingID)
        isSaving = false
        if errorMessage == nil { dismiss() }
    }
}

struct AlbumPhotoReorderSheet: View {
    @Environment(\.dismiss) private var dismiss
    let assets: [AssetLite]
    private let visibilityPolicy: AssetVisibilityPolicy
    @State private var order: [String]
    let onSave: ([String]) -> Void

    init(assets: [AssetLite], visibilityPolicy: AssetVisibilityPolicy? = nil,
         onSave: @escaping ([String]) -> Void) {
        self.assets = assets
        self.visibilityPolicy = visibilityPolicy ?? AssetVisibilityPolicy(scope: .collection)
        _order = State(initialValue: assets.map(\.id))
        self.onSave = onSave
    }

    private var visibleAssets: [AssetLite] {
        var positions: [String: Int] = [:]
        for (index, id) in order.enumerated() where positions[id] == nil { positions[id] = index }
        return visibilityPolicy.filter(assets).sorted {
            let a = positions[$0.id] ?? Int.max
            let b = positions[$1.id] ?? Int.max
            return a == b ? $0.createdAt < $1.createdAt : a < b
        }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(visibleAssets) { asset in
                        HStack(spacing: 12) {
                            AuthImage(assetId: asset.id, thumbhash: asset.thumbhash)
                                .frame(width: 52, height: 52)
                                .clipShape(RoundedRectangle(cornerRadius: 6))
                            VStack(alignment: .leading) {
                                Text(asset.createdAt, format: .dateTime.month().day().year())
                                Text(asset.isVideo ? LocalizedStringKey("Video") : "Photo")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        .accessibilityElement(children: .combine)
                    }
                    .onMove {
                        var ids = visibleAssets.map(\.id)
                        ids.move(fromOffsets: $0, toOffset: $1)
                        order = ids
                    }
                } footer: {
                    Text("Custom order is saved on this device.")
                }
            }
            .environment(\.editMode, .constant(.active))
            .navigationTitle("Reorder Photos")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { onSave(visibleAssets.map(\.id)); dismiss() }
                }
            }
        }
    }
}
