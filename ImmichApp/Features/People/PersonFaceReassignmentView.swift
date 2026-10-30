import SwiftUI

struct PersonFaceReassignmentView: View {
    let person: PersonDTO
    let repository: PeopleRepository
    let assets: @MainActor () -> [AssetLite]
    let onChanged: @MainActor () async -> Void
    @State private var generation = LocalSnapshot.generation
    @State private var remainingIDs: Set<String>
    @State private var phase: LoadingPhase<[PersonDTO]> = .loading
    @State private var isSaving = false
    @State private var createdPerson: PersonDTO?
    @State private var errorMessage: String?
    @Environment(\.dismiss) private var dismiss
    @Environment(SessionManager.self) private var session

    init(person: PersonDTO, assetIDs: [String], repository: PeopleRepository,
         assets: @escaping @MainActor () -> [AssetLite], onChanged: @escaping @MainActor () async -> Void) {
        self.person = person
        self.repository = repository
        self.assets = assets
        self.onChanged = onChanged
        _remainingIDs = State(initialValue: Set(assetIDs))
    }

    var body: some View {
        NavigationStack {
            Group {
                if let people = phase.value {
                    List {
                        Section {
                            Button("New Person", systemImage: "person.crop.circle.badge.plus") {
                                Task { await reassign(to: nil) }
                            }
                            ForEach(people.filter { $0.id != person.id && !$0.isHidden }) { destination in
                                Button { Task { await reassign(to: destination) } } label: {
                                    HStack(spacing: 14) {
                                        PeoplePortrait(person: destination, side: 54)
                                        Text(destination.displayName).foregroundStyle(.primary)
                                    }
                                }
                            }
                        } footer: {
                            Text("Choose the person in these photos. Your photos will not be deleted.")
                        }
                    }
                    .disabled(isSaving)
                } else if let error = phase.errorMessage {
                    ContentUnavailableView {
                        Label("Failed to Load", systemImage: "exclamationmark.triangle")
                    } description: { Text(error) } actions: {
                        Button("Retry") { Task { await loadPeople() } }
                    }
                } else { ProgressView() }
            }
            .navigationTitle("Who Is This?")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.disabled(isSaving) }
                ToolbarItem(placement: .topBarTrailing) { if isSaving { ProgressView() } }
            }
            .interactiveDismissDisabled(isSaving)
            .alert("Action Failed", isPresented: Binding(
                get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
                Button("OK", role: .cancel) {}
            } message: { Text(errorMessage ?? "") }
            .task { await loadPeople() }
            .onChange(of: session.accountGeneration) { _, _ in dismiss() }
            .onChange(of: admittedIDs, initial: true) { _, ids in
                remainingIDs.formIntersection(ids)
                if remainingIDs.isEmpty { dismiss() }
            }
        }
    }

    private func loadPeople() async {
        phase = .loading
        do {
            let people = try await repository.all()
            guard !Task.isCancelled, generation == LocalSnapshot.generation else { return }
            phase = .loaded(people)
        } catch {
            guard !Task.isCancelled, !(error is CancellationError), generation == LocalSnapshot.generation else { return }
            phase = .failed((error as? APIError)?.errorDescription ?? String(localized: "Failed to load people"))
        }
    }

    private var admittedIDs: Set<String> {
        Set(AssetVisibilityPolicy(scope: .timeline).filter(assets()).map(\.id))
    }

    private func reassign(to destination: PersonDTO?) async {
        guard !isSaving, !Task.isCancelled, generation == LocalSnapshot.generation,
              !remainingIDs.isEmpty, remainingIDs.isSubset(of: admittedIDs) else { return }
        isSaving = true
        errorMessage = nil
        var changed = false
        do {
            let target: PersonDTO
            if let destination { target = destination }
            else if let createdPerson { target = createdPerson }
            else {
                target = try await repository.createUnnamedPerson()
                guard !Task.isCancelled, generation == LocalSnapshot.generation else { isSaving = false; return }
                createdPerson = target
            }
            for assetID in remainingIDs.sorted() {
                guard !Task.isCancelled, generation == LocalSnapshot.generation, admittedIDs.contains(assetID) else { throw CancellationError() }
                let faces = try await repository.faces(in: assetID).filter { $0.person?.id == person.id }
                guard !faces.isEmpty else {
                    throw APIError.server(status: 409, message: String(localized: "These photos no longer contain this person."))
                }
                for face in faces {
                    guard !Task.isCancelled, generation == LocalSnapshot.generation,
                          admittedIDs.contains(assetID) else { throw CancellationError() }
                    let updated = try await repository.reassign(faceID: face.id, to: target.id)
                    guard !Task.isCancelled, generation == LocalSnapshot.generation,
                          admittedIDs.contains(assetID) else { throw CancellationError() }
                    guard updated.id == target.id else { throw URLError(.badServerResponse) }
                    changed = true
                }
                remainingIDs.remove(assetID)
            }
            guard generation == LocalSnapshot.generation, !Task.isCancelled else { isSaving = false; return }
        } catch {
            if !(error is CancellationError), generation == LocalSnapshot.generation {
                errorMessage = (error as? APIError)?.errorDescription ?? String(localized: "Failed to update person")
            }
        }
        if changed, generation == LocalSnapshot.generation, !Task.isCancelled {
            LocalSnapshot.remove(LocalSnapshot.Key.person(person.id), expectedGeneration: generation)
            if let destination = destination ?? createdPerson {
                LocalSnapshot.remove(LocalSnapshot.Key.person(destination.id), expectedGeneration: generation)
            }
            await onChanged()
        }
        isSaving = false
        if remainingIDs.isEmpty, errorMessage == nil { dismiss() }
    }
}
