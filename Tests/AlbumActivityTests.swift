import XCTest
@testable import ImmichApp

@MainActor
final class AlbumActivityTests: XCTestCase {
    func testFeedQueriesOnlySharedAlbumsAndSortsActualEventsNewestFirst() async {
        let repository = ActivityTestRepository(api: makeStubAPIClient())
        repository.read = { id in [self.activity(id, at: id == "older" ? 1 : 2)] }
        let model = AlbumActivityViewModel(repository: repository)

        await model.load(albums: [album("private", shared: false), album("older"), album("newer"), album("older")])

        XCTAssertEqual(repository.readIDs, ["older", "newer"])
        XCTAssertEqual(model.items.map(\.activity.id), ["newer", "older"])
        XCTAssertNotNil(model.phase.value)
        XCTAssertNil(model.partialError)
    }

    func testPartialFailurePreservesOtherAlbumsActivityAndReportsTheMissingFeed() async {
        let repository = ActivityTestRepository(api: makeStubAPIClient())
        repository.read = { id in
            if id == "denied" { throw APIError.server(status: 403, message: "Not allowed") }
            return [self.activity("kept")]
        }
        let model = AlbumActivityViewModel(repository: repository)
        await model.load(albums: [album("allowed"), album("denied")])

        XCTAssertEqual(model.items.map(\.activity.id), ["kept"])
        XCTAssertNotNil(model.phase.value)
        XCTAssertNotNil(model.partialError)
        await model.load(albums: [album("denied")])
        XCTAssertTrue(model.items.isEmpty)
        XCTAssertNotNil(model.phase.errorMessage)
    }

    func testOlderFeedCannotOverwriteAConfirmedNewComment() async {
        let repository = ActivityTestRepository(api: makeStubAPIClient())
        let gate = ActivityTestGate<[AlbumActivityDTO]>()
        repository.read = { _ in try await gate.wait() }
        repository.createComment = { text, _ in self.activity("new", text: text) }
        let model = AlbumActivityViewModel(repository: repository)
        let album = album("album")
        let loading = Task { await model.load(albums: [album]) }
        addTeardownBlock { await gate.finish(.success([])); await loading.value }
        await fulfillment(of: [gate.started], timeout: 2)

        let posted = await model.addComment("  New comment  ", album: album)
        gate.finish(.success([]))
        await loading.value

        XCTAssertTrue(posted)
        XCTAssertEqual(repository.comments, ["New comment"])
        XCTAssertEqual(model.items.map(\.activity.comment), ["New comment"])
        XCTAssertNil(model.actionError)
    }

    func testRejectedCommentAndDeleteKeepConfirmedActivity() async {
        let repository = ActivityTestRepository(api: makeStubAPIClient())
        repository.read = { _ in [self.activity("existing")] }
        repository.createComment = { _, _ in throw APIError.server(status: 403, message: "Read only") }
        repository.removal = { _ in throw APIError.server(status: 403, message: "Read only") }
        let model = AlbumActivityViewModel(repository: repository)
        await model.load(albums: [album("album")])

        let posted = await model.addComment("Keep the draft", album: album("album"))
        XCTAssertFalse(posted)
        XCTAssertNotNil(model.actionError)
        XCTAssertEqual(model.items.map(\.activity.id), ["existing"])
        await model.delete("existing")
        XCTAssertNotNil(model.actionError)
        XCTAssertEqual(model.items.map(\.activity.id), ["existing"])
        repository.removal = { _ in }
        await model.delete("existing")
        XCTAssertTrue(model.items.isEmpty)
        XCTAssertNil(model.actionError)
    }

    func testConfirmedDeletionSettlesTheSupersededRefreshWithoutRestoringDeletedActivity() async {
        let repository = ActivityTestRepository(api: makeStubAPIClient())
        let existing = activity("existing")
        repository.read = { _ in [existing] }
        let model = AlbumActivityViewModel(repository: repository)
        let album = album("album")
        await model.load(albums: [album])
        let gate = ActivityTestGate<[AlbumActivityDTO]>()
        repository.read = { _ in try await gate.wait() }
        let refreshing = Task { await model.load(albums: [album]) }
        addTeardownBlock { await gate.finish(.success([])); await refreshing.value }
        await fulfillment(of: [gate.started], timeout: 2)
        XCTAssertTrue(model.phase.isLoading)
        XCTAssertEqual(model.items.map(\.activity.id), ["existing"])

        await model.delete("existing")

        XCTAssertTrue(model.items.isEmpty)
        XCTAssertNotNil(model.phase.value, "The accepted deletion must not leave an empty feed loading forever")
        gate.finish(.success([existing]))
        await refreshing.value
        XCTAssertTrue(model.items.isEmpty, "The older refresh must not resurrect the confirmed deletion")
        XCTAssertNotNil(model.phase.value)
        XCTAssertNil(model.actionError)
    }

    func testAccountChangeHidesPublishedEventsAndRejectsLateCommentResults() async {
        let repository = ActivityTestRepository(api: makeStubAPIClient())
        repository.read = { _ in [self.activity("old-account")] }
        let gate = ActivityTestGate<AlbumActivityDTO>()
        repository.createComment = { _, _ in try await gate.wait() }
        let model = AlbumActivityViewModel(repository: repository)
        await model.load(albums: [album("album")])
        XCTAssertEqual(model.items.count, 1)
        let posting = Task { await model.addComment("Late", album: self.album("album")) }
        addTeardownBlock { await gate.finish(.failure(CancellationError())); _ = await posting.value }
        await fulfillment(of: [gate.started], timeout: 2)

        LocalSnapshot.clearAll()
        XCTAssertTrue(model.items.isEmpty)
        XCTAssertTrue(model.phase.isIdle)
        XCTAssertNil(model.actionError)
        gate.finish(.success(activity("late")))
        let posted = await posting.value

        XCTAssertFalse(posted)
        XCTAssertTrue(model.items.isEmpty)
        XCTAssertNil(model.actionError)
        await model.load(albums: [album("another-old-request")])
        XCTAssertEqual(repository.readIDs, ["album"])
    }

    func testAssetActivityDisappearsWhenItsPhotoBecomesPrivate() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("activity-privacy-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let db = SwiftDataManager(storeURL: directory.appendingPathComponent("store"), backupJournalURL: directory.appendingPathComponent("journal.json"))
        let photoID = UUID().uuidString
        try db.restoreToTimeline([AssetLite(id: photoID, isVideo: false, ratio: 1, thumbhash: nil, createdAt: .distantPast)])
        let repository = ActivityTestRepository(api: makeStubAPIClient())
        repository.read = { _ in [self.activity("photo-event", assetID: photoID), self.activity("album-event")] }
        let model = AlbumActivityViewModel(repository: repository, dataManager: db)
        await model.load(albums: [album("album")])
        XCTAssertEqual(Set(model.items.map(\.activity.id)), ["photo-event", "album-event"])

        try db.setAssetVisibility([photoID], to: "locked")

        XCTAssertEqual(model.items.map(\.activity.id), ["album-event"])
    }

    func testBlankCommentsAndPrivateAlbumsDoNotSendMutations() async {
        let repository = ActivityTestRepository(api: makeStubAPIClient())
        let model = AlbumActivityViewModel(repository: repository)
        let blank = await model.addComment(" \n ", album: album("shared"))
        let privateAlbum = await model.addComment("Text", album: album("private", shared: false))
        XCTAssertFalse(blank)
        XCTAssertFalse(privateAlbum)
        XCTAssertTrue(repository.comments.isEmpty)
    }

    func testFeedUsesCurrentAlbumMetadataAndRemovesDeletedOrUnsharedDestinationsWithoutARefetch() async {
        let repository = ActivityTestRepository(api: makeStubAPIClient())
        repository.read = { _ in [self.activity("comment")] }
        let model = AlbumActivityViewModel(repository: repository)
        let original = album("album")
        await model.load(albums: [original])
        var renamed = original
        renamed.albumName = "Renamed album"
        renamed.albumThumbnailAssetId = "new-cover"

        let refreshed = model.items(in: [renamed])

        XCTAssertEqual(refreshed.first?.album.albumName, "Renamed album")
        XCTAssertEqual(refreshed.first?.album.albumThumbnailAssetId, "new-cover")
        XCTAssertEqual(refreshed.first?.activity.id, "comment")
        XCTAssertTrue(model.items(in: []).isEmpty)
        renamed.shared = false
        XCTAssertTrue(model.items(in: [renamed]).isEmpty)
        XCTAssertEqual(repository.readIDs, ["album"])
    }

    private func album(_ id: String, shared: Bool = true) -> AlbumResponseDTO {
        .init(id: id, albumName: id, description: nil, assetCount: 0, albumThumbnailAssetId: nil,
              shared: shared, createdAt: .distantPast, assets: nil)
    }

    private func activity(_ id: String, at: TimeInterval = 1, text: String = "Comment", assetID: String? = nil) -> AlbumActivityDTO {
        AlbumActivityDTO(id: id, assetId: assetID, comment: text, createdAt: Date(timeIntervalSince1970: at), type: "comment",
            user: UserResponseDTO(id: "user", email: "user@example.test", name: "Person", profileImagePath: nil,
                profileChangedAt: nil, storageLabel: nil, isAdmin: false))
    }
}

private final class ActivityTestRepository: AlbumActivityRepository {
    var read: (String) async throws -> [AlbumActivityDTO] = { _ in [] }
    var createComment: (String, String) async throws -> AlbumActivityDTO = { _, _ in throw APIError.unknown }
    var removal: (String) async throws -> Void = { _ in }
    var readIDs: [String] = []
    var comments: [String] = []
    override func all(in albumID: String) async throws -> [AlbumActivityDTO] {
        readIDs.append(albumID)
        return try await read(albumID)
    }
    override func comment(_ text: String, in albumID: String) async throws -> AlbumActivityDTO {
        comments.append(text)
        return try await createComment(text, albumID)
    }
    override func delete(_ activityID: String) async throws { try await removal(activityID) }
}

@MainActor
private final class ActivityTestGate<Value> {
    let started = XCTestExpectation(description: "Activity request reached its held response")
    private var continuation: CheckedContinuation<Value, Error>?
    private var result: Result<Value, Error>?
    func wait() async throws -> Value {
        started.fulfill()
        if let result { return try result.get() }
        return try await withCheckedThrowingContinuation { continuation = $0 }
    }
    func finish(_ result: Result<Value, Error>) {
        guard self.result == nil else { return }
        self.result = result
        continuation?.resume(with: result)
        continuation = nil
    }
}
