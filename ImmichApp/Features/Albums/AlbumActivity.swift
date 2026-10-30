import Foundation
import Observation
import SwiftUI

struct AlbumActivityDTO: Decodable, Identifiable {
    let id: String
    let assetId: String?
    let comment: String?
    let createdAt: Date
    let type: String
    let user: UserResponseDTO
}

class AlbumActivityRepository {
    private let api: APIClient

    init(api: APIClient) { self.api = api }

    func all(in albumID: String) async throws -> [AlbumActivityDTO] {
        try await api.send(.init(path: "/activities", query: [.init(name: "albumId", value: albumID)]))
    }

    func comment(_ text: String, in albumID: String) async throws -> AlbumActivityDTO {
        struct Body: Encodable { let albumId: String; let type = "comment"; let comment: String }
        return try await api.send(.json("/activities", method: .post,
            body: Body(albumId: albumID, comment: text)))
    }

    func like(_ albumID: String) async throws -> AlbumActivityDTO {
        struct Body: Encodable { let albumId: String; let type = "like" }
        return try await api.send(.json("/activities", method: .post, body: Body(albumId: albumID)))
    }

    func delete(_ activityID: String) async throws {
        try await api.sendVoid(.init(path: "/activities/\(activityID)", method: .delete))
    }
}

struct AlbumActivityItem: Identifiable {
    let album: AlbumResponseDTO
    let activity: AlbumActivityDTO
    var id: String { "\(album.id):\(activity.id)" }
}

@MainActor
@Observable
final class AlbumActivityViewModel {
    private let repository: AlbumActivityRepository
    private let dataManager: SwiftDataManager
    private let generation = LocalSnapshot.generation
    private var requestID = UUID()
    private var loadedItems: [AlbumActivityItem] = []
    private var loadingPhase: LoadingPhase<Void> = .idle
    private var loadingError: String?
    private(set) var isPerformingAction = false
    private var mutationError: String?
    var actionError: String? { generation == LocalSnapshot.generation ? mutationError : nil }

    var items: [AlbumActivityItem] {
        guard generation == LocalSnapshot.generation else { return [] }
        let policy = AssetVisibilityPolicy(scope: .collection, dataManager: dataManager)
        return loadedItems.filter { $0.activity.assetId.map { policy.allows(id: $0) } ?? true }
    }

    var phase: LoadingPhase<Void> { generation == LocalSnapshot.generation ? loadingPhase : .idle }
    var partialError: String? { generation == LocalSnapshot.generation ? loadingError : nil }

    func items(in currentAlbums: [AlbumResponseDTO]) -> [AlbumActivityItem] {
        let current = Dictionary(currentAlbums.filter(\.shared).map { ($0.id, $0) },
                                 uniquingKeysWith: { first, _ in first })
        return items.compactMap {
            guard let album = current[$0.album.id] else { return nil }
            return AlbumActivityItem(album: album, activity: $0.activity)
        }
    }

    init(repository: AlbumActivityRepository, dataManager: SwiftDataManager? = nil) {
        self.repository = repository
        self.dataManager = dataManager ?? .shared
    }

    func load(albums: [AlbumResponseDTO]) async {
        guard generation == LocalSnapshot.generation, !Task.isCancelled else { return }
        let request = UUID()
        requestID = request
        loadingPhase = .loading
        loadingError = nil
        var loaded: [AlbumActivityItem] = []
        var failure: String?
        var seen = Set<String>()
        let shared = albums.filter { $0.shared && seen.insert($0.id).inserted }
        for album in shared {
            do {
                let activities = try await repository.all(in: album.id)
                guard accepts(request) else { return }
                loaded.append(contentsOf: activities.map { AlbumActivityItem(album: album, activity: $0) })
            } catch {
                guard accepts(request), !(error is CancellationError) else { return }
                failure = (error as? APIError)?.errorDescription ?? String(localized: "Failed to load activity")
            }
        }
        guard accepts(request) else { return }
        loadedItems = loaded.sorted {
            $0.activity.createdAt == $1.activity.createdAt
                ? $0.id < $1.id : $0.activity.createdAt > $1.activity.createdAt
        }
        loadingError = failure
        if loaded.isEmpty, let failure { loadingPhase = .failed(failure) }
        else { loadingPhase = .loaded(()) }
    }

    private func accepts(_ request: UUID) -> Bool {
        !Task.isCancelled && generation == LocalSnapshot.generation && requestID == request
    }

    func addComment(_ text: String, album: AlbumResponseDTO) async -> Bool {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return false }
        return await add(album: album) { try await repository.comment(text, in: album.id) }
    }

    func like(album: AlbumResponseDTO) async -> Bool {
        await add(album: album) { try await repository.like(album.id) }
    }

    private func add(album: AlbumResponseDTO, operation: () async throws -> AlbumActivityDTO) async -> Bool {
        guard generation == LocalSnapshot.generation, !Task.isCancelled, !isPerformingAction, album.shared else { return false }
        isPerformingAction = true
        mutationError = nil
        defer { isPerformingAction = false }
        do {
            let activity = try await operation()
            guard generation == LocalSnapshot.generation, !Task.isCancelled else { return false }
            requestID = UUID()
            loadedItems.removeAll { $0.album.id == album.id && $0.activity.id == activity.id }
            loadedItems.insert(AlbumActivityItem(album: album, activity: activity), at: 0)
            loadingPhase = .loaded(())
            return true
        } catch {
            guard generation == LocalSnapshot.generation, !Task.isCancelled, !(error is CancellationError) else { return false }
            mutationError = (error as? APIError)?.errorDescription ?? String(localized: "Failed to update activity")
            return false
        }
    }

    func delete(_ activityID: String) async {
        guard generation == LocalSnapshot.generation, !Task.isCancelled, !isPerformingAction,
              loadedItems.contains(where: { $0.activity.id == activityID }) else { return }
        isPerformingAction = true
        mutationError = nil
        defer { isPerformingAction = false }
        do {
            try await repository.delete(activityID)
            guard generation == LocalSnapshot.generation, !Task.isCancelled else { return }
            requestID = UUID()
            loadedItems.removeAll { $0.activity.id == activityID }
        } catch {
            guard generation == LocalSnapshot.generation, !Task.isCancelled, !(error is CancellationError) else { return }
            mutationError = (error as? APIError)?.errorDescription ?? String(localized: "Failed to update activity")
        }
    }
}

struct AlbumActivitySheet: View {
    let album: AlbumResponseDTO
    @Environment(SessionManager.self) private var session
    @Environment(\.dismiss) private var dismiss
    @State private var model: AlbumActivityViewModel?
    @State private var comment = ""

    init(album: AlbumResponseDTO, viewModel: AlbumActivityViewModel? = nil) {
        self.album = album
        _model = State(initialValue: viewModel)
    }

    var body: some View {
        NavigationStack {
            Group {
                if let model {
                    activityList(model)
                } else { ProgressView() }
            }
            .navigationTitle("Activity")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
            .safeAreaInset(edge: .bottom) { composer }
            .task {
                if model == nil { model = AlbumActivityViewModel(repository: AlbumActivityRepository(api: APIClient(session: session))) }
                await model?.load(albums: [album])
            }
        }
    }

    private func activityList(_ model: AlbumActivityViewModel) -> some View {
        List {
            Section {
                Button {
                    Task {
                        if let ownLike = model.items.first(where: {
                            $0.activity.type == "like" && $0.activity.assetId == nil
                                && $0.activity.user.id == session.currentUser?.id
                        }) { await model.delete(ownLike.activity.id) }
                        else { _ = await model.like(album: album) }
                    }
                } label: {
                    let liked = model.items.contains {
                        $0.activity.type == "like" && $0.activity.assetId == nil
                            && $0.activity.user.id == session.currentUser?.id
                    }
                    Label(liked ? LocalizedStringKey("Liked") : "Like", systemImage: liked ? "heart.fill" : "heart")
                }
                .disabled(model.isPerformingAction)
            }
            if let error = model.actionError ?? model.partialError { Text(error).foregroundStyle(.red) }
            if model.phase.isLoading && model.items.isEmpty { ProgressView() }
            ForEach(model.items) { item in
                AlbumActivityRow(item: item)
                    .swipeActions {
                        if item.activity.user.id == session.currentUser?.id || album.ownerId == session.currentUser?.id {
                            Button("Delete", role: .destructive) { Task { await model.delete(item.activity.id) } }
                                .disabled(model.isPerformingAction)
                        }
                    }
            }
            if !model.phase.isLoading && model.items.isEmpty && model.partialError == nil {
                Text("No Activity").foregroundStyle(.secondary)
            }
        }
        .refreshable { await model.load(albums: [album]) }
    }

    private var composer: some View {
        HStack(alignment: .bottom, spacing: 12) {
            TextField("Add a Comment", text: $comment, axis: .vertical)
                .lineLimit(1...4)
                .textFieldStyle(.roundedBorder)
                .accessibilityIdentifier("album.comment")
            Button {
                let submitted = comment
                Task {
                    if await model?.addComment(submitted, album: album) == true, comment == submitted { comment = "" }
                }
            } label: { Image(systemName: "arrow.up.circle.fill").font(.title) }
            .accessibilityLabel("Send Comment")
            .disabled(comment.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || model == nil || model?.isPerformingAction == true)
        }
        .padding()
        .background(.bar)
    }
}

struct AlbumActivityRow: View {
    let item: AlbumActivityItem

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            AlbumCoverImage(album: item.album)
                .frame(width: 64, height: 64)
                .clipShape(RoundedRectangle(cornerRadius: 10))
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(item.activity.user.name).fontWeight(.semibold)
                    Spacer()
                    Text(item.activity.createdAt, style: .relative)
                        .font(.caption).foregroundStyle(.secondary)
                }
                if let comment = item.activity.comment, item.activity.type == "comment" {
                    Text(comment).lineLimit(3)
                } else if item.activity.type == "like" {
                    Label(item.activity.assetId == nil ? LocalizedStringKey("Liked this album") : "Liked this item", systemImage: "heart.fill")
                        .font(.subheadline).foregroundStyle(.secondary)
                } else {
                    Text("Activity").font(.subheadline).foregroundStyle(.secondary)
                }
                Text(item.album.albumName).font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }
}
