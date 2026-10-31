import SwiftData
import XCTest
@testable import ImmichApp

@MainActor
final class SharePreparationTests: XCTestCase {
    private var files: [URL] = []
    private var directories: [URL] = []
    private var mappings: [(recordID: String, localID: String)] = []

    func testUnmodifiedOriginalExportUsesFalseWithoutChangingOrdinarySharing() async throws {
        let repository = try makeRepository()
        var requests: [(String, String?)] = []
        MockURLProtocol.responseProvider = { request in
            let edited = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?
                .first { $0.name == "edited" }?.value
            requests.append((request.url!.path, edited))
            return Self.response(request, status: 200, expectedEdited: request.url!.path.contains("/current/"))
        }

        let current = try await repository.shareFile("current")
        files.append(current)
        let originals = await repository.shareOriginalFiles(["first", "last"])
        files.append(contentsOf: originals)

        XCTAssertEqual(requests.map(\.0), ["/api/assets/current/original", "/api/assets/first/original", "/api/assets/last/original"])
        XCTAssertEqual(requests.map(\.1), ["true", "false", "false"])
        XCTAssertEqual(try Data(contentsOf: current), Data("original-current".utf8))
        XCTAssertEqual(try originals.map { try Data(contentsOf: $0) }, [Data("original-first".utf8), Data("original-last".utf8)])
    }

    override func setUp() async throws {
        MockURLProtocol.reset()
        RemovedAssets.shared.clear()
        DeletedServerAssetRegistry.shared.clear()
    }

    override func tearDown() async throws {
        MockURLProtocol.reset()
        TemporaryMediaStore.remove(files)
        files.removeAll()
        for directory in directories { try? FileManager.default.removeItem(at: directory) }
        directories.removeAll()
        for mapping in mappings {
            let recordID = mapping.recordID
            let descriptor = FetchDescriptor<BackupRecord>(predicate: #Predicate { $0.id == recordID })
            for record in try SwiftDataManager.shared.modelContext.fetch(descriptor) {
                SwiftDataManager.shared.modelContext.delete(record)
            }
            try SwiftDataManager.shared.unlinkDeviceAsset(localIdentifier: mapping.localID)
        }
        mappings.removeAll()
        RemovedAssets.shared.clear()
        DeletedServerAssetRegistry.shared.clear()
    }

    func testAllHTTPDownloadsFailVisiblyAndTheSamePreparationCanRetry() async throws {
        let repository = try makeRepository()
        let preparation = SharePreparation()
        let observation = ShareObservation()
        var requests: [String] = []
        MockURLProtocol.responseProvider = { request in
            requests.append(request.url!.path)
            return Self.response(request, status: 503)
        }
        let failed = try XCTUnwrap(preparation.start(ids: ["photo", "video"],
            prepare: { await repository.shareFiles($0) }, isAllowed: { _ in true },
            onError: observation.failed, onReady: observation.prepared))
        await failed.value

        XCTAssertEqual(requests, ["/api/assets/photo/original", "/api/assets/video/original"])
        XCTAssertEqual(observation.errors, [String(localized: "Failed to prepare share")])
        XCTAssertTrue(observation.files.isEmpty, "An all-failed request must not open an empty activity sheet")
        XCTAssertFalse(preparation.isPreparing)

        MockURLProtocol.responseProvider = { Self.response($0, status: 200) }
        let retry = try XCTUnwrap(preparation.start(ids: ["photo"],
            prepare: { await repository.shareFiles($0) }, isAllowed: { _ in true },
            onError: observation.failed, onReady: observation.prepared))
        await retry.value
        let file = try XCTUnwrap(observation.files.first?.first)
        files.append(file)
        XCTAssertEqual(try Data(contentsOf: file), Data("original-photo".utf8))
        XCTAssertEqual(observation.errors.count, 1)
        XCTAssertFalse(preparation.isPreparing)
    }

    func testPartialHTTPFailureStillSharesSuccessfulOriginalsWithoutAnError() async throws {
        let repository = try makeRepository()
        let preparation = SharePreparation()
        let observation = ShareObservation()
        MockURLProtocol.responseProvider = { request in
            Self.response(request, status: request.url!.path.contains("missing") ? 503 : 200)
        }
        let task = try XCTUnwrap(preparation.start(ids: ["first", "missing", "last"],
            prepare: { await repository.shareFiles($0) }, isAllowed: { _ in true },
            onError: observation.failed, onReady: observation.prepared))
        await task.value

        let prepared = try XCTUnwrap(observation.files.first)
        files.append(contentsOf: prepared)
        XCTAssertEqual(prepared.count, 2)
        XCTAssertEqual(try prepared.map { try Data(contentsOf: $0) },
            [Data("original-first".utf8), Data("original-last".utf8)])
        XCTAssertTrue(observation.errors.isEmpty)
        XCTAssertFalse(preparation.isPreparing)
    }

    func testStoryShareFailureStaysInTheModalWithoutOverwritingParentFeedback() async throws {
        let session = MockSessionManager()
        try session.setServer("https://share-story.example")
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let api = APIClient(session: session, urlSession: URLSession(configuration: configuration))
        let library = LibraryViewModel(memoriesRepo: MemoriesRepository(api: api), albumRepo: AlbumRepository(api: api),
            peopleRepo: PeopleRepository(api: api), searchRepo: SearchRepository(api: api),
            assetRepo: AssetDetailRepository(api: api))
        let asset = AssetLite(makeTestAsset(id: UUID().uuidString))
        library.actionError = "Another library action failed"
        MockURLProtocol.responseProvider = { Self.response($0, status: 503) }
        let preparation = SharePreparation(), observation = ShareObservation()
        let task = try XCTUnwrap(preparation.start(ids: [asset.id], prepare: { _ in
            if let url = await library.shareURL(for: asset, reportsErrors: false) { return [url] }
            return []
        }, isAllowed: { _ in true }, onError: observation.failed, onReady: observation.prepared))
        await task.value

        XCTAssertEqual(observation.errors, [String(localized: "Failed to prepare share")])
        XCTAssertTrue(observation.files.isEmpty)
        XCTAssertEqual(library.actionError, "Another library action failed")
        let ordinary = await library.shareURL(for: asset)
        XCTAssertNil(ordinary)
        XCTAssertEqual(library.actionError, "Original unavailable",
            "The ordinary Library share action must still report its own download failure")
    }

    func testCanceledOlderRequestCannotReplaceOrStopANewerRequest() async throws {
        let preparation = SharePreparation()
        let observation = ShareObservation()
        let firstGate = SharePreparationGate(), secondGate = SharePreparationGate()
        let firstFile = try managedFile("first"), secondFile = try managedFile("second")
        let first = try XCTUnwrap(preparation.start(ids: ["first"],
            prepare: { _ in await firstGate.wait() }, isAllowed: { _ in true },
            onError: observation.failed, onReady: observation.prepared))
        await fulfillment(of: [firstGate.started], timeout: 2)
        XCTAssertTrue(preparation.isPreparing)
        XCTAssertNil(preparation.start(ids: ["duplicate"], prepare: { _ in
            XCTFail("A pending request must not start another download"); return []
        }, isAllowed: { _ in true }, onError: observation.failed, onReady: observation.prepared))
        preparation.cancel()
        let second = try XCTUnwrap(preparation.start(ids: ["second"],
            prepare: { _ in await secondGate.wait() }, isAllowed: { _ in true },
            onError: observation.failed, onReady: observation.prepared))
        addTeardownBlock { await firstGate.finish([]); await secondGate.finish([]); await first.value; await second.value }
        await fulfillment(of: [secondGate.started], timeout: 2)
        firstGate.finish([firstFile])
        await first.value
        XCTAssertTrue(preparation.isPreparing, "The old task's defer must not clear the new progress state")
        XCTAssertTrue(observation.files.isEmpty)
        XCTAssertTrue(observation.errors.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: firstFile.path))

        secondGate.finish([secondFile])
        await second.value
        XCTAssertEqual(observation.files, [[secondFile]])
        XCTAssertFalse(preparation.isPreparing)
        preparation.cancel()
        XCTAssertTrue(FileManager.default.fileExists(atPath: secondFile.path),
            "Files already handed to an activity controller belong to its completion/dismissal cleanup")
    }

    func testCancellationAccountAndPrivacyChangesDiscardLateFilesWithoutPresentingErrors() async throws {
        for invalidation in ["cancel", "account", "privacy"] {
            let preparation = SharePreparation()
            let observation = ShareObservation()
            let gate = SharePreparationGate()
            let policy = ShareAdmission()
            let file = try managedFile(invalidation)
            let task = try XCTUnwrap(preparation.start(ids: ["photo"],
                prepare: { _ in await gate.wait() }, isAllowed: { _ in policy.isAllowed },
                onError: observation.failed, onReady: observation.prepared))
            addTeardownBlock { await gate.finish([]); await task.value }
            await fulfillment(of: [gate.started], timeout: 2)
            switch invalidation {
            case "cancel": preparation.cancel()
            case "account": LocalSnapshot.clearAll()
            default: policy.isAllowed = false
            }
            gate.finish([file])
            await task.value

            XCTAssertTrue(observation.files.isEmpty, invalidation)
            XCTAssertTrue(observation.errors.isEmpty, invalidation)
            XCTAssertFalse(FileManager.default.fileExists(atPath: file.path), invalidation)
            XCTAssertFalse(preparation.isPreparing, invalidation)
        }
    }

    func testCanceledFailureCannotPublishAFalseErrorOverANewerShare() async throws {
        let preparation = SharePreparation()
        let observation = ShareObservation()
        let gate = SharePreparationGate()
        let old = try XCTUnwrap(preparation.start(ids: ["old"], prepare: { _ in await gate.wait() },
            isAllowed: { _ in true }, onError: observation.failed, onReady: observation.prepared))
        addTeardownBlock { await gate.finish([]); await old.value }
        await fulfillment(of: [gate.started], timeout: 2)
        preparation.cancel()
        let currentFile = try managedFile("current")
        let current = try XCTUnwrap(preparation.start(ids: ["current"], prepare: { _ in [currentFile] },
            isAllowed: { _ in true }, onError: observation.failed, onReady: observation.prepared))
        await current.value
        gate.finish([])
        await old.value

        XCTAssertEqual(observation.files, [[currentFile]])
        XCTAssertTrue(observation.errors.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: currentFile.path))
    }

    func testAliasRemappingAndUnlinkingDiscardHeldShareFilesEvenWhenLogicalPrivacyStillAllowsThem() async throws {
        for invalidation in ["remap", "unlink"] {
            let localID = UUID().uuidString, recordID = UUID().uuidString
            let originalID = UUID().uuidString
            let displayID = LocalPhotoLibrary.assetID(for: localID)
            mappings.append((recordID, localID))
            try SwiftDataManager.shared.insertBackupRecord(BackupRecord(id: recordID, assetId: originalID,
                deviceAssetId: "", localIdentifier: localID))
            let preparation = SharePreparation(), observation = ShareObservation(), gate = SharePreparationGate()
            let policy = AssetVisibilityPolicy(scope: .timeline)
            let file = try managedFile(invalidation)
            let task = try XCTUnwrap(preparation.start(ids: [displayID], prepare: { _ in await gate.wait() },
                isAllowed: { policy.allows(id: $0) }, onError: observation.failed, onReady: observation.prepared))
            addTeardownBlock { await gate.finish([]); await task.value }
            await fulfillment(of: [gate.started], timeout: 2)

            if invalidation == "unlink" { try SwiftDataManager.shared.unlinkDeviceAsset(localIdentifier: localID) }
            else { try SwiftDataManager.shared.upsertBackupRecord(assetID: UUID().uuidString, checksum: "", localIdentifier: localID) }
            XCTAssertTrue(policy.allows(id: displayID))
            gate.finish([file])
            await task.value

            XCTAssertTrue(observation.files.isEmpty, invalidation)
            XCTAssertTrue(observation.errors.isEmpty, invalidation)
            XCTAssertTrue(preparation.preparedSourceIDs.isEmpty, invalidation)
            XCTAssertFalse(FileManager.default.fileExists(atPath: file.path), invalidation)
            XCTAssertFalse(preparation.isPreparing, invalidation)
        }
    }

    func testPreparedSourceIDsAreAvailableInsideTheCompletionAndStayFrozenUntilTheNextAcceptedRequest() async throws {
        let localID = UUID().uuidString, recordID = UUID().uuidString
        let originalID = UUID().uuidString, replacementID = UUID().uuidString
        let displayID = LocalPhotoLibrary.assetID(for: localID)
        let otherID = UUID().uuidString, localOnlyID = LocalPhotoLibrary.assetID(for: UUID().uuidString)
        mappings.append((recordID, localID))
        try SwiftDataManager.shared.insertBackupRecord(BackupRecord(id: recordID, assetId: originalID,
            deviceAssetId: "", localIdentifier: localID))
        let preparation = SharePreparation(), observation = ShareObservation()
        let urls = try ["mapped", "server", "local-only"].map(managedFile)
        var captured: [String] = []
        let task = try XCTUnwrap(preparation.start(ids: [displayID, otherID, localOnlyID], prepare: { _ in urls },
            isAllowed: { _ in true }, onError: observation.failed) { files in
            captured = preparation.preparedSourceIDs
            observation.prepared(files)
        })
        await task.value
        XCTAssertEqual(captured, [originalID, otherID, localOnlyID])
        XCTAssertEqual(preparation.preparedSourceIDs, captured)
        try SwiftDataManager.shared.upsertBackupRecord(assetID: replacementID, checksum: "", localIdentifier: localID)
        XCTAssertEqual(preparation.preparedSourceIDs, captured, "Presentation must retain the source paired with its bytes")
        let next = try XCTUnwrap(preparation.start(ids: [displayID], prepare: { _ in
            XCTAssertTrue(preparation.preparedSourceIDs.isEmpty)
            return [urls[0]]
        }, isAllowed: { _ in true }, onError: observation.failed, onReady: observation.prepared))
        await next.value
        XCTAssertEqual(preparation.preparedSourceIDs, [replacementID])
        preparation.cancel()
        XCTAssertTrue(preparation.preparedSourceIDs.isEmpty)
        XCTAssertEqual(captured, [originalID, otherID, localOnlyID])
        XCTAssertTrue(observation.errors.isEmpty)
    }

    func testServerChangeWithoutAccountClearDiscardsAHeldShareAndDoesNotLatchItsContext() async throws {
        let session = MockSessionManager()
        try session.setServer("https://share-preparation-a.example")
        let initialContext = session.snapshot
        let generation = LocalSnapshot.generation
        let preparation = SharePreparation(), observation = ShareObservation()
        let file = try managedFile("prepared-server-a")
        let gate = SharePreparationGate()
        let task = try XCTUnwrap(preparation.start(ids: ["same-id-on-both-servers"], session: session,
            prepare: { _ in await gate.wait() }, isAllowed: { _ in true },
            onError: observation.failed, onReady: observation.prepared))
        addTeardownBlock { await gate.finish([file]); _ = await task.value }
        await fulfillment(of: [gate.started], timeout: 2)

        try session.setServer("https://share-preparation-b.example")
        XCTAssertEqual(LocalSnapshot.generation, generation)
        XCTAssertNotEqual(session.snapshot, initialContext)
        gate.finish([file])
        await task.value

        XCTAssertTrue(observation.files.isEmpty)
        XCTAssertTrue(observation.errors.isEmpty)
        XCTAssertNil(preparation.preparedContext)
        XCTAssertTrue(preparation.preparedSourceIDs.isEmpty)
        XCTAssertFalse(preparation.isPreparing)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
    }

    func testPreparedRequestContextIsLatchedInsideReadyAndRemainsBoundToItsBytes() async throws {
        let session = MockSessionManager()
        try session.setServer("https://share-preparation-a.example")
        let initialContext = session.snapshot
        let preparation = SharePreparation(), observation = ShareObservation()
        let file = try managedFile("context-bound-file")
        var captured: SessionRequestContext?
        let task = try XCTUnwrap(preparation.start(ids: ["photo"], session: session,
            prepare: { _ in [file] }, isAllowed: { _ in true }, onError: observation.failed) { files in
            captured = preparation.preparedContext
            observation.prepared(files)
        })
        await task.value
        XCTAssertEqual(captured, initialContext)
        XCTAssertEqual(preparation.preparedContext, initialContext)
        try session.setServer("https://share-preparation-b.example")
        XCTAssertEqual(preparation.preparedContext, initialContext)
        XCTAssertNotEqual(preparation.preparedContext, session.snapshot)
        preparation.cancel()
        XCTAssertNil(preparation.preparedContext)
    }

    func testEmptyHiddenAndAlreadyCanceledCallsDoNotStartOrReportFailures() async throws {
        let preparation = SharePreparation()
        let observation = ShareObservation()
        let prepare: @MainActor ([String]) async -> [URL] = { _ in XCTFail("Ineligible sharing must not start"); return [] }
        XCTAssertNil(preparation.start(ids: [], prepare: prepare, isAllowed: { _ in true },
            onError: observation.failed, onReady: observation.prepared))
        XCTAssertNil(preparation.start(ids: ["private"], prepare: prepare, isAllowed: { _ in false },
            onError: observation.failed, onReady: observation.prepared))
        let canceled = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            XCTAssertNil(preparation.start(ids: ["photo"], prepare: prepare, isAllowed: { _ in true },
                onError: observation.failed, onReady: observation.prepared))
        }
        await canceled.value
        XCTAssertFalse(preparation.isPreparing)
        XCTAssertTrue(observation.errors.isEmpty)
        XCTAssertTrue(observation.files.isEmpty)
    }

    private func managedFile(_ name: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("share-preparation-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        directories.append(directory)
        let source = directory.appendingPathComponent(name)
        try Data(name.utf8).write(to: source)
        let file = try TemporaryMediaStore.adoptShareFile(at: source, suggestedFilename: name + ".heic")
        files.append(file)
        return file
    }

    private func makeRepository() throws -> AssetDetailRepository {
        let session = MockSessionManager()
        try session.setServer("https://share-preparation.example")
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        return AssetDetailRepository(api: APIClient(session: session, urlSession: URLSession(configuration: configuration)))
    }

    private nonisolated static func response(_ request: URLRequest, status: Int, expectedEdited: Bool = true) -> (Data?, URLResponse?, Error?) {
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertEqual(request.url?.query, "edited=\(expectedEdited)", "Current and unmodified exports must use their respective server renditions")
        let id = request.url!.path.split(separator: "/").dropLast().last.map(String.init)!
        let data = status == 200 ? Data("original-\(id)".utf8) : Data(#"{"message":"Original unavailable"}"#.utf8)
        let headers = ["Content-Type": "image/heic", "Content-Disposition": "attachment; filename=\"\(id).heic\""]
        return (data, HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: headers), nil)
    }
}

@MainActor
private final class ShareObservation {
    var errors: [String] = []
    var files: [[URL]] = []
    func failed(_ message: String) { errors.append(message) }
    func prepared(_ urls: [URL]) { files.append(urls) }
}

@MainActor
private final class ShareAdmission { var isAllowed = true }

@MainActor
private final class SharePreparationGate {
    let started = XCTestExpectation(description: "The share preparation reached its held response")
    private var continuation: CheckedContinuation<[URL], Never>?
    func wait() async -> [URL] {
        await withCheckedContinuation { continuation = $0; started.fulfill() }
    }
    func finish(_ files: [URL]) {
        continuation?.resume(returning: files)
        continuation = nil
    }
}
