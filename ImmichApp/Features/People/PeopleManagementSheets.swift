import SwiftUI

struct PersonIdentityEditor: View {
    @State private var detail: PersonDetailState
    let repository: PeopleRepository
    var onUpdated: (PersonUpdate) -> Void
    @State private var isSaving = false
    @State private var isLoadingPhotos = false
    @State private var keyPhotos: [AssetLite]?
    @State private var selectedKeyPhoto: String?
    @State private var errorMessage: String?
    @Environment(\.dismiss) private var dismiss
    @Environment(SessionManager.self) private var session
    @FocusState private var isNameFocused: Bool
    private let generation = LocalSnapshot.generation

    init(person: PersonDTO, repository: PeopleRepository, detailState: PersonDetailState? = nil,
         onUpdated: @escaping (PersonUpdate) -> Void) {
        _detail = State(initialValue: detailState ?? PersonDetailState(person: person))
        self.repository = repository
        self.onUpdated = onUpdated
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack {
                        Spacer()
                        PeoplePortrait(person: detail.person, side: 160)
                        Spacer()
                    }
                    .listRowBackground(Color.clear)
                    Button {
                        Task { await loadKeyPhotos() }
                    } label: {
                        HStack {
                            Text("Edit Key Photo")
                            Spacer()
                            if isLoadingPhotos { ProgressView() }
                        }
                    }
                    .disabled(isLoadingPhotos || isSaving)
                    TextField("Name This Person", text: Bindable(detail).renameDraft)
                        .focused($isNameFocused)
                        .textContentType(.name)
                }
            }
            .navigationTitle("Edit Name and Photos")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.disabled(isSaving) }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        Task { await save() }
                    } label: {
                        if isSaving { ProgressView() } else { Text("Done") }
                    }
                    .disabled(detail.renameDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isSaving)
                }
            }
            .sheet(isPresented: Binding(
                get: { keyPhotos != nil }, set: { if !$0 { keyPhotos = nil } })) {
                AlbumKeyPhotoPicker(assets: visibleKeyPhotos, selectedID: selectedKeyPhoto) { id in
                    let error = await detail.chooseKeyPhoto(id, from: visibleKeyPhotos, using: repository, onUpdated: onUpdated)
                    if error == nil { selectedKeyPhoto = id }
                    return error
                }
            }
            .alert("Action Failed", isPresented: Binding(
                get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
                Button("OK", role: .cancel) {}
            } message: { Text(errorMessage ?? "") }
            .interactiveDismissDisabled(isSaving)
            .onAppear { isNameFocused = detail.person.name.isEmpty }
            .onChange(of: session.accountGeneration) { _, _ in dismiss() }
        }
    }

    private var visibleKeyPhotos: [AssetLite] {
        AssetVisibilityPolicy(scope: .timeline).filter(keyPhotos ?? [])
    }

    private func loadKeyPhotos() async {
        guard !isLoadingPhotos, detail.isCurrent else { return }
        isLoadingPhotos = true
        defer { isLoadingPhotos = false }
        do {
            let loaded = try await repository.assets(personId: detail.person.id).map(AssetLite.init)
            guard !Task.isCancelled, detail.isCurrent, generation == LocalSnapshot.generation else { return }
            keyPhotos = loaded
        } catch {
            guard !Task.isCancelled, !(error is CancellationError) else { return }
            errorMessage = (error as? APIError)?.errorDescription ?? String(localized: "Failed to load photos")
        }
    }

    private func save() async {
        if detail.renameDraft.trimmingCharacters(in: .whitespacesAndNewlines) == detail.person.name { dismiss(); return }
        guard let request = detail.prepareRename() else { return }
        isSaving = true
        let result = await detail.saveRename(request, using: repository)
        isSaving = false
        switch result {
        case .saved?:
            onUpdated(PersonUpdate(person: detail.person, fields: [.name]))
            dismiss()
        case .failed(let error)?:
            errorMessage = error
        case nil:
            break
        }
    }
}

struct PeopleMergePicker: View {
    let person: PersonDTO
    let people: [PersonDTO]
    let onMerge: ([String], String) async -> Bool
    @State private var candidate: PersonDTO?
    @State private var isMerging = false
    @State private var errorMessage: String?
    @Environment(\.dismiss) private var dismiss
    @Environment(SessionManager.self) private var session

    var body: some View {
        NavigationStack {
            List(people.filter { $0.id != person.id && !$0.isHidden }) { other in
                Button { candidate = other } label: {
                    HStack(spacing: 14) {
                        PeoplePortrait(person: other, side: 54)
                        Text(other.displayName).foregroundStyle(.primary)
                    }
                }
                .disabled(isMerging)
                .confirmationDialog("Merge These People?", isPresented: Binding(
                    get: { candidate?.id == other.id }, set: { if !$0 { candidate = nil } }), titleVisibility: .visible) {
                    Button("Merge Photos") {
                        isMerging = true
                        Task {
                            let merged = await onMerge([other.id], person.id)
                            isMerging = false
                            if merged { dismiss() }
                            else { errorMessage = String(localized: "Some people could not be merged. Try again.") }
                        }
                    }
                    Button("Cancel", role: .cancel) {}
                } message: { Text("The photos will be combined into one person.") }
            }
            .navigationTitle("Merge People")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.disabled(isMerging) } }
            .alert("Action Failed", isPresented: Binding(
                get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
                Button("OK", role: .cancel) {}
            } message: { Text(errorMessage ?? "") }
            .interactiveDismissDisabled(isMerging)
            .onChange(of: session.accountGeneration) { _, _ in dismiss() }
        }
    }
}

struct PeopleDiscoveryView: View {
    enum Mode { case unnamed, hidden }
    let repository: PeopleRepository
    let mode: Mode
    let onUpdated: (PersonUpdate) -> Void
    @State private var model: PeopleListViewModel?
    @State private var editedPerson: PersonDTO?
    @Environment(\.dismiss) private var dismiss
    @Environment(SessionManager.self) private var session

    var body: some View {
        NavigationStack {
            Group {
                if let model, model.phase.value != nil {
                    if displayedPeople.isEmpty {
                        ContentUnavailableView(mode == .hidden ? "No Hidden People" : "No Additional People",
                            systemImage: "person.2.fill")
                    } else {
                        List(displayedPeople) { person in
                            HStack(spacing: 14) {
                                PeoplePortrait(person: person, side: 64)
                                Text(person.displayName)
                                Spacer()
                                if mode == .hidden {
                                    Button("Show") {
                                        Task {
                                            await model.setHidden(person.id, to: false)
                                            if let updated = model.people.first(where: { $0.id == person.id }), !updated.isHidden {
                                                onUpdated(PersonUpdate(person: updated, fields: [.hidden]))
                                            }
                                        }
                                    }
                                    .buttonStyle(.bordered)
                                } else {
                                    Button("Add Name") { editedPerson = person }
                                        .buttonStyle(.bordered)
                                }
                            }
                        }
                    }
                } else if let error = model?.phase.errorMessage {
                    ContentUnavailableView {
                        Label("Failed to Load", systemImage: "exclamationmark.triangle")
                    } description: { Text(error) } actions: {
                        Button("Retry") { Task { await model?.loadPeople() } }
                    }
                } else { ProgressView() }
            }
            .navigationTitle(mode == .hidden ? "Hidden People" : "Add People")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .sheet(item: $editedPerson) { person in
                PersonIdentityEditor(person: person, repository: repository) { updated in
                    model?.applyPersonUpdate(updated)
                    onUpdated(updated)
                }
            }
            .alert("Action Failed", isPresented: Binding(
                get: { model?.actionError != nil }, set: { if !$0 { model?.actionError = nil } })) {
                Button("OK", role: .cancel) {}
            } message: { Text(model?.actionError ?? "") }
            .task {
                if model == nil { model = PeopleListViewModel(repo: repository, includesHidden: true) }
                await model?.loadPeople()
            }
            .onChange(of: session.accountGeneration) { _, _ in dismiss() }
        }
    }

    private var displayedPeople: [PersonDTO] {
        guard model?.isCurrent == true else { return [] }
        return (model?.people ?? []).filter { mode == .hidden ? $0.isHidden : !$0.isHidden && $0.name.isEmpty }
    }
}

struct PeopleReorderSheet: View {
    let people: @MainActor () -> [PersonDTO]
    @State private var order: [String]
    let onSave: ([String]) -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(SessionManager.self) private var session
    @State private var generation = LocalSnapshot.generation

    init(people: @escaping @MainActor () -> [PersonDTO], onSave: @escaping ([String]) -> Void) {
        self.people = people
        _order = State(initialValue: people().map(\.id))
        self.onSave = onSave
    }

    var body: some View {
        NavigationStack {
            List {
                ForEach(visiblePeople) { person in
                    HStack(spacing: 14) {
                        PeoplePortrait(person: person, side: 54)
                        Text(person.displayName)
                    }
                }
                .onMove {
                    var ids = visiblePeople.map(\.id)
                    ids.move(fromOffsets: $0, toOffset: $1)
                    order = ids
                }
            }
            .environment(\.editMode, .constant(.active))
            .navigationTitle("Sort by Custom Order")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        if generation == LocalSnapshot.generation { onSave(visiblePeople.map(\.id)) }
                        dismiss()
                    }
                }
            }
            .onChange(of: session.accountGeneration) { _, _ in dismiss() }
        }
    }

    private var visiblePeople: [PersonDTO] {
        guard generation == LocalSnapshot.generation else { return [] }
        var positions: [String: Int] = [:]
        for (index, id) in order.enumerated() where positions[id] == nil { positions[id] = index }
        return people().filter { !$0.isHidden }.sorted {
            let a = positions[$0.id] ?? Int.max, b = positions[$1.id] ?? Int.max
            return a == b ? $0.id < $1.id : a < b
        }
    }
}
