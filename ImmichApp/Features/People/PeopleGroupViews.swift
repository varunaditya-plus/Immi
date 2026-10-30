import SwiftUI

struct PeopleGroupsSection: View {
    let people: [PersonDTO]
    let store: PeopleGroupsStore
    @State private var showsCreate = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                NavigationLink {
                    PeopleGroupsListView(people: people, store: store)
                } label: {
                    HStack(spacing: 5) {
                        Text("Groups").font(.title2.bold())
                        Image(systemName: "chevron.forward").font(.subheadline.bold()).foregroundStyle(.secondary)
                    }
                }
                .buttonStyle(.plain)
                Spacer()
                Menu {
                    Button("Create New Group", systemImage: "person.3") { showsCreate = true }
                } label: {
                    Image(systemName: "plus").frame(minWidth: 44, minHeight: 44)
                }
                .accessibilityLabel("Add")
                .disabled(people.filter { !$0.isHidden }.count < 2 || !store.isCurrent)
            }
            if !store.groups.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(alignment: .top, spacing: 12) {
                        ForEach(store.groups) { group in
                            PeopleGroupLink(group: group, people: people, store: store, width: 150)
                        }
                    }
                }
            } else {
                Text("Create a group to see people together.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .sheet(isPresented: $showsCreate) {
            PeopleGroupEditor(people: people, store: store)
        }
    }
}

struct PeopleGroupsListView: View {
    let people: [PersonDTO]
    let store: PeopleGroupsStore
    @State private var showsCreate = false
    @State private var showsReorder = false

    var body: some View {
        GeometryReader { geometry in
            ScrollView {
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], alignment: .leading, spacing: 20) {
                    ForEach(store.groups) { group in
                        PeopleGroupLink(group: group, people: people, store: store,
                            width: max(100, (geometry.size.width - 44) / 2))
                    }
                }
                .padding(16)
                if store.groups.isEmpty {
                    ContentUnavailableView("No Groups", systemImage: "person.3",
                        description: Text("Create a group to see people together."))
                }
            }
        }
        .navigationTitle("Groups")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button("Create New Group", systemImage: "plus") { showsCreate = true }
                        .disabled(people.filter { !$0.isHidden }.count < 2 || !store.isCurrent)
                    Button("Reorder", systemImage: "arrow.up.arrow.down") { showsReorder = true }
                        .disabled(store.groups.count < 2)
                } label: { Image(systemName: "ellipsis") }
                .accessibilityLabel("Group Options")
            }
        }
        .sheet(isPresented: $showsCreate) { PeopleGroupEditor(people: people, store: store) }
        .sheet(isPresented: $showsReorder) { PeopleGroupsReorderSheet(people: people, store: store) }
    }
}

private struct PeopleGroupLink: View {
    let group: PeopleGroup
    let people: [PersonDTO]
    let store: PeopleGroupsStore
    let width: CGFloat
    @State private var showsEdit = false
    @State private var showsDelete = false

    var body: some View {
        NavigationLink {
            PeopleGroupDetailView(groupID: group.id, people: people, store: store)
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                PeopleGroupCover(group: group, people: people)
                    .frame(width: width, height: width * 0.8)
                    .clipShape(RoundedRectangle(cornerRadius: 14))
                Text(group.title(in: people))
                    .font(.headline)
                    .lineLimit(2)
                    .frame(width: width, alignment: .leading)
            }
        }
        .buttonStyle(.plain)
        .draggable(group.id)
        .dropDestination(for: String.self) { ids, _ in
            guard ids.count == 1 else { return false }
            return store.move(ids[0], to: group.id)
        }
        .contextMenu {
            Button("Edit Name and People", systemImage: "pencil") { showsEdit = true }
            Button("Delete Group", systemImage: "trash", role: .destructive) { showsDelete = true }
        }
        .accessibilityAction(named: Text("Edit Name and People")) { showsEdit = true }
        .accessibilityAction(named: Text("Delete Group")) { showsDelete = true }
        .sheet(isPresented: $showsEdit) { PeopleGroupEditor(group: group, people: people, store: store) }
        .confirmationDialog("Delete Group?", isPresented: $showsDelete, titleVisibility: .visible) {
            Button("Delete Group", role: .destructive) { store.remove(group.id) }
            Button("Cancel", role: .cancel) {}
        } message: { Text("The photos will stay in your library.") }
    }
}

private struct PeopleGroupCover: View {
    let group: PeopleGroup
    let people: [PersonDTO]
    @Environment(SessionManager.self) private var session
    @State private var verifiedCover: VerifiedCover?

    private var policy: AssetVisibilityPolicy { AssetVisibilityPolicy(scope: .timeline) }

    var body: some View {
        ZStack {
            Color(.secondarySystemBackground)
            if let verifiedCover, group.isAvailable(in: people),
               verifiedCover.people == Set(group.personIDs), verifiedCover.assetID == group.keyPhotoID,
               verifiedCover.revisions == PeopleGroupMembership.revisions(for: group.personIDs),
               policy.allows(id: verifiedCover.assetID) {
                AuthImage(assetId: verifiedCover.assetID)
            } else if group.isAvailable(in: people) {
                HStack(spacing: -16) {
                    ForEach(group.personIDs.prefix(3), id: \.self) { id in
                        if let person = people.first(where: { $0.id == id }) {
                            PeopleGroupFace(person: person, size: 70)
                        }
                    }
                }
            } else {
                Image(systemName: "person.crop.circle.badge.questionmark").font(.largeTitle).foregroundStyle(.secondary)
            }
        }
        .accessibilityHidden(true)
        .task(id: CoverRequest(assetID: group.keyPhotoID, people: group.personIDs,
            available: group.isAvailable(in: people), revision: SwiftDataManager.shared.assetMutationRevision,
            personRevisions: PeopleGroupMembership.revisions(for: group.personIDs))) {
            verifiedCover = nil
            guard let id = group.keyPhotoID, group.isAvailable(in: people), policy.allows(id: id) else { return }
            let generation = LocalSnapshot.generation
            let revisions = PeopleGroupMembership.revisions(for: group.personIDs)
            let repository = AssetDetailRepository(api: APIClient(session: session))
            guard let asset = try? await repository.fetchAsset(id), !Task.isCancelled,
                  generation == LocalSnapshot.generation,
                  revisions == PeopleGroupMembership.revisions(for: group.personIDs),
                  asset.isTimelineVisible, policy.allows(id: id),
                  (try? PeopleGroupMembership.includes(asset, people: Set(group.personIDs), includingOtherPeople: false)) == true
            else { return }
            verifiedCover = VerifiedCover(assetID: id, people: Set(group.personIDs), revisions: revisions)
        }
    }

    private struct CoverRequest: Hashable {
        let assetID: String?
        let people: [String]
        let available: Bool
        let revision: UUID
        let personRevisions: [UInt64]
    }

    private struct VerifiedCover {
        let assetID: String
        let people: Set<String>
        let revisions: [UInt64]
    }
}

private struct PeopleGroupFace: View {
    let person: PersonDTO
    let size: CGFloat

    var body: some View {
        Group {
            if person.thumbnailPath?.isEmpty == false {
                AuthImage(assetId: person.id, path: "/people/\(person.id)/thumbnail")
                    .id(person.updatedAt)
            } else {
                Image(systemName: "person.crop.circle.fill").resizable().foregroundStyle(.secondary)
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .overlay { Circle().stroke(.background, lineWidth: 2) }
        .accessibilityHidden(true)
    }
}

struct PeopleGroupEditor: View {
    let group: PeopleGroup?
    let people: [PersonDTO]
    let store: PeopleGroupsStore
    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var selected: Set<String>
    @State private var keyPhotoID: String?
    @State private var choosingInitialPeople: Bool
    @State private var showsAddPeople = false
    @State private var showsKeyPhoto = false
    @State private var errorMessage: String?

    init(group: PeopleGroup? = nil, people: [PersonDTO], store: PeopleGroupsStore) {
        self.group = group
        self.people = people
        self.store = store
        _name = State(initialValue: group?.name ?? "")
        _selected = State(initialValue: Set(group?.personIDs ?? []))
        _keyPhotoID = State(initialValue: group?.keyPhotoID)
        _choosingInitialPeople = State(initialValue: group == nil)
    }

    private var available: [PersonDTO] {
        people.filter { !$0.isHidden }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
    private var availableIDs: Set<String> { Set(available.map(\.id)) }

    var body: some View {
        NavigationStack {
            Group {
                if choosingInitialPeople {
                    PeopleGroupMembersPicker(people: available, selected: selected, title: "Create New Group",
                        minimumPeople: minimumPeople, isCurrent: store.isCurrent, onCancel: { dismiss() }) { ids in
                            selected = ids
                            choosingInitialPeople = false
                        }
                } else {
                    editorForm
                }
            }
            .onAppear { selected.formIntersection(availableIDs) }
            .onChange(of: selected) { _, _ in keyPhotoID = nil }
            .onChange(of: availableIDs) { _, ids in selected.formIntersection(ids) }
            .sheet(isPresented: $showsAddPeople) {
                NavigationStack {
                    PeopleGroupMembersPicker(people: available, selected: selected, title: "Add People",
                        minimumPeople: minimumPeople, isCurrent: store.isCurrent, onCancel: { showsAddPeople = false }) { ids in
                            selected = ids
                            showsAddPeople = false
                        }
                }
            }
            .sheet(isPresented: $showsKeyPhoto) {
                PeopleGroupKeyPhotoPicker(personIDs: selected.sorted(), selectedID: keyPhotoID) { id in
                    keyPhotoID = id
                    return nil
                }
            }
            .alert("Action Failed", isPresented: Binding(
                get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
                Button("OK", role: .cancel) {}
            } message: { Text(errorMessage ?? "") }
        }
    }

    private var editorForm: some View {
        Form {
            Section {
                HStack {
                    Spacer()
                    keyPhotoButton
                    Spacer()
                }
                .listRowBackground(Color.clear)
                TextField("Group Name", text: $name)
            } footer: { Text("Groups are saved on this device.") }
            Section {
                ScrollView(.horizontal) {
                    HStack(alignment: .top, spacing: 16) {
                        ForEach(available.filter { selected.contains($0.id) }) { person in
                            memberPortrait(person)
                        }
                    }
                    .padding(.vertical, 8)
                }
                Button("Add People", systemImage: "plus") { showsAddPeople = true }
            } header: { Text("People") } footer: {
                if let group, !group.isAvailable(in: people) {
                    Text("Some people are no longer available. Choose the people for this group.")
                }
            }
        }
        .navigationTitle(group == nil ? "Create New Group" : "Edit Name and People")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button(group == nil ? "Create" : "Done") { save() }
                    .disabled(selected.count < minimumPeople || !selected.isSubset(of: availableIDs) || !store.isCurrent)
            }
        }
    }

    private var keyPhotoButton: some View {
        Button { showsKeyPhoto = true } label: {
            PeopleGroupCover(group: PeopleGroup(id: group?.id ?? "draft", name: name,
                personIDs: selected.sorted(), keyPhotoID: keyPhotoID), people: people)
                .frame(width: 150, height: 150)
                .clipShape(.rect(cornerRadius: 20))
                .overlay(alignment: .bottomTrailing) {
                    Image(systemName: "photo").padding(10).background(.regularMaterial, in: .circle)
                }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Edit Key Photo")
        .disabled(selected.count < minimumPeople)
    }

    private func memberPortrait(_ person: PersonDTO) -> some View {
        VStack(spacing: 6) {
            ZStack(alignment: .topLeading) {
                PeopleGroupFace(person: person, size: 72)
                Button { selected.remove(person.id) } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title2).symbolRenderingMode(.palette)
                        .foregroundStyle(.primary, .background)
                        .frame(minWidth: 44, minHeight: 44)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Remove")
                .accessibilityValue(person.displayName)
            }
            Text(person.displayName).font(.caption).lineLimit(2)
                .frame(width: 72).multilineTextAlignment(.center)
        }
    }

    private func save() {
        guard selected.isSubset(of: availableIDs), store.isCurrent else { return }
        guard store.save(id: group?.id, name: name, personIDs: selected.sorted(), keyPhotoID: keyPhotoID,
            expectedPeople: group?.personIDs) != nil else {
            errorMessage = String(localized: "This group is no longer available.")
            return
        }
        dismiss()
    }

    private var minimumPeople: Int { group?.personIDs.count == 1 ? 1 : 2 }
}

private struct PeopleGroupMembersPicker: View {
    let people: [PersonDTO]
    @State var selected: Set<String>
    let title: LocalizedStringKey
    let minimumPeople: Int
    let isCurrent: Bool
    let onCancel: () -> Void
    let onDone: (Set<String>) -> Void

    private var availableIDs: Set<String> { Set(people.map(\.id)) }

    var body: some View {
        List {
            Section {
                ForEach(people) { person in
                    memberButton(person)
                }
            } footer: { Text("Choose people to include in your group photos.") }
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel", action: onCancel) }
            ToolbarItem(placement: .confirmationAction) {
                Button("Done") { onDone(selected) }
                    .disabled(selected.count < minimumPeople || !selected.isSubset(of: availableIDs) || !isCurrent)
            }
        }
        .onChange(of: availableIDs) { _, ids in selected.formIntersection(ids) }
    }

    private func memberButton(_ person: PersonDTO) -> some View {
        Button {
            if !selected.insert(person.id).inserted { selected.remove(person.id) }
        } label: {
            HStack(spacing: 12) {
                PeopleGroupFace(person: person, size: 44)
                Text(person.displayName).foregroundStyle(.primary)
                Spacer()
                Image(systemName: selected.contains(person.id) ? "checkmark.circle.fill" : "circle")
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(person.displayName)
        .accessibilityAddTraits(selected.contains(person.id) ? .isSelected : [])
    }
}

private struct PeopleGroupsReorderSheet: View {
    let people: [PersonDTO]
    let store: PeopleGroupsStore
    @Environment(\.dismiss) private var dismiss
    @State private var order: [String] = []

    private var ordered: [PeopleGroup] {
        let groups = store.groups
        let byID = Dictionary(groups.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let retained = order.compactMap { byID[$0] }
        let seen = Set(retained.map(\.id))
        return retained + groups.filter { !seen.contains($0.id) }
    }

    var body: some View {
        NavigationStack {
            List {
                ForEach(ordered) { group in Text(group.title(in: people)) }
                    .onMove { from, to in
                        var ids = ordered.map(\.id)
                        ids.move(fromOffsets: from, toOffset: to)
                        order = ids
                    }
            }
            .environment(\.editMode, .constant(.active))
            .navigationTitle("Reorder")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { store.setOrder(ordered.map(\.id)); dismiss() }
                }
            }
            .onAppear { order = store.groups.map(\.id) }
        }
    }
}

struct PeopleGroupDetailView: View {
    let groupID: String
    let people: [PersonDTO]
    let store: PeopleGroupsStore
    @Environment(SessionManager.self) private var session
    @Environment(\.dismiss) private var dismiss
    @State private var model: AssetGridViewModel?
    @State private var loadedQuery: Query?
    @State private var includingOtherPeople = false
    @State private var showsEditor = false
    @State private var showsKeyPhoto = false
    @State private var albumPicker: AssetLite?
    @State private var actionMessage: ErrorEvent?

    private var group: PeopleGroup? { store.group(groupID) }
    private var query: Query {
        Query(people: group?.personIDs.sorted() ?? [], includesOthers: includingOtherPeople,
            available: group?.isAvailable(in: people) == true, generation: session.accountGeneration,
            revisions: PeopleGroupMembership.revisions(for: group?.personIDs ?? []))
    }
    private var admittedAssets: [AssetLite] {
        guard let group, group.isAvailable(in: people), loadedQuery == query else { return [] }
        return AssetVisibilityPolicy(scope: .timeline).filter(model?.assets ?? [])
    }

    var body: some View {
        Group {
            if let group, group.isAvailable(in: people) {
                PhotoCollectionScreen(
                    title: LocalizedStringKey(group.title(in: people)), heroAssetID: group.keyPhotoID,
                    assets: admittedAssets, phase: loadedQuery == query ? model?.phase ?? .loading : .loading,
                    actionError: Binding(get: { model?.actionError }, set: { model?.actionError = $0 }),
                    emptyState: PhotoCollectionEmptyState(title: "No Group Photos", systemImage: "person.3",
                        description: "There are no photos or videos of this group of people together."),
                    onRetry: { Task { await model?.load() } },
                    onToggleFavorite: { await model?.toggleFavorite($0) },
                    onDelete: { _ = await model?.delete($0) }, shareURLs: { await model?.shareURLs(for: $0) ?? [] },
                    onAddToAlbum: { albumPicker = $0 },
                    onFavoriteSelection: { _ = await model?.setFavorite($0, to: true) },
                    onArchiveSelection: { _ = await model?.setArchived($0, to: true) },
                    onMoveToLocked: { _ = await model?.setLocked($0) }, visibilityScope: .timeline,
                    viewOptions: { AnyView(Toggle("Other People", isOn: $includingOtherPeople)) },
                    options: {
                        Button("Edit Name and People", systemImage: "pencil") { showsEditor = true }
                        Button("Edit Key Photo", systemImage: "photo") { showsKeyPhoto = true }
                    })
            } else {
                ContentUnavailableView("Group Unavailable", systemImage: "person.crop.circle.badge.questionmark",
                    description: Text("A person in this group is hidden or no longer available."))
            }
        }
        .task(id: query) { await load() }
        .onChange(of: group == nil) { _, removed in if removed { dismiss() } }
        .sheet(isPresented: $showsEditor) {
            if let group { PeopleGroupEditor(group: group, people: people, store: store) }
        }
        .sheet(isPresented: $showsKeyPhoto) {
            if let group {
                PeopleGroupKeyPhotoPicker(personIDs: group.personIDs, selectedID: group.keyPhotoID) { id in
                    guard AssetVisibilityPolicy(scope: .timeline).allows(id: id),
                          store.setKeyPhoto(id, in: group.id, expectedPeople: group.personIDs) else {
                        return String(localized: "This group is no longer available.")
                    }
                    return nil
                }
            }
        }
        .sheet(item: $albumPicker) { asset in
            AlbumPickerLoader { album in
                Task {
                    if let message = await model?.addToAlbum([asset.id], album: album) { actionMessage = ErrorEvent(message) }
                }
            }
        }
        .errorToast($actionMessage)
    }

    private func load() async {
        guard !Task.isCancelled, let group, group.isAvailable(in: people) else { model = nil; return }
        let api = APIClient(session: session)
        let repository = PeopleGroupRepository(repository: SearchRepository(api: api))
        let otherPeople = includingOtherPeople
        loadedQuery = query
        let grid = AssetGridViewModel(assetRepo: AssetDetailRepository(api: api), albumRepo: AlbumRepository(api: api)) {
            try await repository.assets(personIDs: group.personIDs, includingOtherPeople: otherPeople)
        }
        model = grid
        await grid.load()
    }

    private struct Query: Hashable {
        let people: [String]
        let includesOthers: Bool
        let available: Bool
        let generation: UUID
        let revisions: [UInt64]
    }
}

struct PeopleGroupKeyPhotoPicker: View {
    let personIDs: [String]
    let selectedID: String?
    var assetLoader: (([String]) async throws -> [AssetLite])? = nil
    let onSave: (String) async -> String?
    @Environment(SessionManager.self) private var session
    @Environment(\.dismiss) private var dismiss
    @State private var phase: LoadingPhase<[AssetLite]> = .loading
    @State private var loadedQuery: SelectionQuery?
    @State private var loadRequest = UUID()

    private var query: SelectionQuery {
        SelectionQuery(people: personIDs.sorted(), revisions: PeopleGroupMembership.revisions(for: personIDs),
            generation: session.accountGeneration)
    }

    var body: some View {
        Group {
            if let assets = phase.value, let loadedQuery, loadedQuery == query {
                AlbumKeyPhotoPicker(assets: AssetVisibilityPolicy(scope: .timeline).filter(assets), selectedID: selectedID) { id in
                    guard loadedQuery == query, AssetVisibilityPolicy(scope: .timeline).allows(id: id) else {
                        return String(localized: "This photo is no longer available.")
                    }
                    return await onSave(id)
                }
            } else {
                NavigationStack {
                    Group {
                        if let error = phase.errorMessage {
                            ContentUnavailableView {
                                Label("Failed to Load", systemImage: "person.3")
                            } description: { Text(error) } actions: {
                                Button("Retry") { Task { await load() } }
                            }
                        } else { ProgressView() }
                    }
                    .navigationTitle("Choose Key Photo")
                    .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
                }
            }
        }
        .task(id: query) { await load() }
    }

    private func load() async {
        let request = UUID()
        let currentQuery = query
        loadRequest = request
        phase = .loading
        loadedQuery = currentQuery
        let api = APIClient(session: session)
        do {
            let assets: [AssetLite]
            if let assetLoader { assets = try await assetLoader(currentQuery.people) }
            else {
                assets = try await PeopleGroupRepository(repository: SearchRepository(api: api))
                    .assets(personIDs: currentQuery.people, includingOtherPeople: false)
            }
            guard !Task.isCancelled, loadRequest == request, query == currentQuery else { return }
            phase = .loaded(assets)
        } catch {
            guard !Task.isCancelled, !(error is CancellationError), loadRequest == request, query == currentQuery else { return }
            phase = .failed((error as? APIError)?.errorDescription ?? String(localized: "Failed to load photos"))
        }
    }

    private struct SelectionQuery: Hashable {
        let people: [String]
        let revisions: [UInt64]
        let generation: UUID
    }
}
