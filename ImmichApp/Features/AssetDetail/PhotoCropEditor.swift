import SwiftUI
import UIKit

struct PhotoCropEditor: View {
    private let requiresSave: Bool
    private let loadImage: @MainActor () async -> UIImage?
    private let isAllowed: @MainActor () -> Bool
    private let onSave: @MainActor (PhotoEditRecipe) async -> Bool
    private let onRevert: @MainActor () async -> Bool
    @Environment(\.dismiss) private var dismiss
    @State private var history: PhotoEditHistory
    @State private var image: UIImage?
    @State private var tool = PhotoEditorTool.adjust
    @State private var isSaving = false
    @State private var loadFailed = false
    @State private var loadRevision = UUID()
    @State private var discardConfirmation = false
    @State private var revertConfirmation = false
    @State private var error: ErrorEvent?
    @State private var saveTask: Task<Void, Never>?
    @State private var aspectDrawer = false

    init(initialRecipe: PhotoEditRecipe, requiresSave: Bool = false, loadImage: @escaping @MainActor () async -> UIImage?,
         isAllowed: @escaping @MainActor () -> Bool,
         onSave: @escaping @MainActor (PhotoEditRecipe) async -> Bool,
         onRevert: @escaping @MainActor () async -> Bool) {
        self.requiresSave = requiresSave
        self.loadImage = loadImage
        self.isAllowed = isAllowed
        self.onSave = onSave
        self.onRevert = onRevert
        _history = State(initialValue: PhotoEditHistory(recipe: initialRecipe))
    }

    private var recipe: Binding<PhotoEditRecipe> {
        Binding(get: { history.recipe }, set: { if !isSaving { history.update($0) } })
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if isAllowed(), let image {
                    PhotoEditCanvas(image: image, recipe: recipe, tool: tool, comparing: false,
                        onEditingChanged: history.editingChanged)
                    PhotoEditToolControls(image: image, recipe: recipe, tool: tool, aspectDrawer: $aspectDrawer,
                        onEditingChanged: history.editingChanged)
                    toolPicker
                } else if loadFailed {
                    ContentUnavailableView {
                        Label("Photo Unavailable", systemImage: "photo.badge.exclamationmark")
                    } description: {
                        Text("The photo could not be loaded for editing.")
                    } actions: {
                        Button("Retry") { loadRevision = UUID() }
                    }
                    .frame(maxHeight: .infinity)
                } else {
                    ProgressView("Loading photo…").frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .ignoresSafeArea(.container, edges: .bottom)
            .disabled(isSaving)
            .allowsHitTesting(!isSaving)
            .foregroundStyle(.primary)
            .background(Color(uiColor: .systemBackground))
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(Color(uiColor: .systemBackground), for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    PhotoEditorToolbarButton("Cancel", systemImage: "xmark") {
                        history.editingChanged(false)
                        if history.isDirty { discardConfirmation = true } else { dismiss() }
                    }
                    .disabled(isSaving)
                }
                .sharedBackgroundVisibility(.hidden)
                ToolbarItem(placement: .topBarLeading) {
                    if tool == .crop {
                        PhotoCropTransformButtons(recipe: recipe, onEditingChanged: history.editingChanged)
                            .disabled(isSaving)
                    } else {
                        HStack(spacing: 8) {
                            Button("Undo", systemImage: "arrow.uturn.backward", action: history.undo)
                                .frame(width: 44, height: 44).disabled(!history.canUndo || isSaving)
                            Button("Redo", systemImage: "arrow.uturn.forward", action: history.redo)
                                .frame(width: 44, height: 44).disabled(!history.canRedo || isSaving)
                        }
                        .labelStyle(.iconOnly).buttonStyle(.plain)
                        .glassEffect(.regular, in: .capsule)
                    }
                }
                .sharedBackgroundVisibility(.hidden)
                if tool == .crop {
                    ToolbarItemGroup(placement: .topBarTrailing) {
                        Button("Aspect Ratio", systemImage: "aspectratio") {
                            history.editingChanged(false)
                            aspectDrawer.toggle()
                        }
                        .labelStyle(.iconOnly)
                        .disabled(isSaving || image == nil)
                        moreMenu
                    }
                    .sharedBackgroundVisibility(.visible)
                } else {
                    ToolbarItem(placement: .topBarTrailing) {
                        moreMenu
                            .frame(width: 44, height: 44)
                            .glassEffect(.regular, in: .circle)
                    }
                    .sharedBackgroundVisibility(.hidden)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    PhotoEditorToolbarButton("Done", systemImage: "checkmark",
                        tint: history.isDirty || requiresSave ? .yellow : .secondary) { save(reverting: false) }
                        .disabled(isSaving || image == nil || !isAllowed())
                }
                .sharedBackgroundVisibility(.hidden)
            }
            .overlay {
                if isSaving {
                    ZStack {
                        Color.black.opacity(0.45).ignoresSafeArea()
                        ProgressView("Applying edits…").padding(20)
                            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
                    }
                }
            }
            .confirmationDialog("Discard Changes?", isPresented: $discardConfirmation, titleVisibility: .visible) {
                Button("Discard Changes", role: .destructive) { dismiss() }
                Button("Keep Editing", role: .cancel) {}
            }
            .confirmationDialog("Revert to Original?", isPresented: $revertConfirmation, titleVisibility: .visible) {
                Button("Revert to Original", role: .destructive) { save(reverting: true) }
                Button("Cancel", role: .cancel) {}
            } message: { Text("This will remove the edits made to this photo.") }
            .errorToast($error)
            .task(id: loadRevision) {
                let generation = LocalSnapshot.generation
                loadFailed = false
                guard isAllowed() else { dismiss(); return }
                let loaded = await loadImage()
                guard !Task.isCancelled, generation == LocalSnapshot.generation, isAllowed() else { return }
                image = loaded
                loadFailed = loaded == nil
            }
            .onChange(of: isAllowed()) { _, allowed in
                if !allowed { saveTask?.cancel(); image = nil; dismiss() }
            }
            .onDisappear { saveTask?.cancel() }
        }
        .interactiveDismissDisabled(history.isDirty || isSaving)
        .persistentSystemOverlays(.hidden)
        .statusBarHidden()
    }

    private var toolPicker: some View {
        PhotoEditorToolPicker(selected: Binding(get: { tool }, set: {
            guard !isSaving else { return }
            history.editingChanged(false)
            tool = $0
        }), isEnabled: !isSaving)
        .padding(.bottom, 16)
    }

    private var moreMenu: some View {
        Menu {
            Text("Edits are saved on this device.")
            Button("Revert to Original", systemImage: "arrow.counterclockwise", role: .destructive) {
                revertConfirmation = true
            }
            .disabled(!history.isDirty && history.initialRecipe.isIdentity && !requiresSave)
        } label: {
            Image(systemName: "ellipsis").font(.system(size: 20, weight: .medium))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("More")
        .disabled(isSaving || image == nil)
    }

    private func save(reverting: Bool) {
        guard !isSaving, isAllowed(), let image else { return }
        history.editingChanged(false)
        if !reverting, !history.isDirty, !requiresSave { dismiss(); return }
        let value = history.recipe, generation = LocalSnapshot.generation
        isSaving = true
        error = nil
        saveTask = Task {
            defer { isSaving = false; saveTask = nil }
            do {
                if !reverting { _ = try await PhotoEditRenderer.shared.renderPreview(image, recipe: value) }
                guard !Task.isCancelled, generation == LocalSnapshot.generation, isAllowed() else { return }
                let accepted = reverting ? await onRevert() : await onSave(value)
                guard !Task.isCancelled, generation == LocalSnapshot.generation, isAllowed() else { return }
                if accepted { dismiss() }
                else { error = ErrorEvent(String(localized: "The edits could not be saved. Please try again.")) }
            } catch {
                guard !Task.isCancelled, generation == LocalSnapshot.generation, isAllowed() else { return }
                self.error = ErrorEvent(error.localizedDescription)
            }
        }
    }
}
