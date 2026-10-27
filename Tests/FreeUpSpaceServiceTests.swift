import CryptoKit
import XCTest
@testable import ImmichApp

@MainActor
final class FreeUpSpaceServiceTests: XCTestCase {
    func testScanUsesFreshBytesInsteadOfHistoricalBackupChecksums() async throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        try fixture.store.storeChecksums([(localIdentifier: "local-a", checksum: "stale-checksum")])
        let service = fixture.service()

        let review = try await service.scan(fixture.rules)

        XCTAssertEqual(review.candidates.map(\.id), ["local-a"])
        XCTAssertEqual(review.rules, fixture.rules)
        XCTAssertEqual(fixture.library.requests.first?.ids, ["local-a"])
        XCTAssertEqual(fixture.store.storedChecksums()["local-a"], "stale-checksum")
        XCTAssertEqual(fixture.library.deletions, 0)
        XCTAssertEqual(fixture.api.downloads.count, 1)
    }

    func testMissingTrashedAndMismatchedServerCopiesAreExcludedAlongsideAValidCopy() async throws {
        let fixture = try Fixture(ids: ["a", "missing", "trashed", "wrong-bytes"])
        defer { fixture.close() }
        fixture.server.reply("/assets/server-missing", bytes: Data(), status: 404)
        fixture.server.reply("/assets/server-trashed", json: fixture.metadata("server-trashed", trashed: true))
        fixture.server.reply("/assets/server-wrong-bytes/original", bytes: Data("corrupt original".utf8))

        let review = try await fixture.service().scan(fixture.rules)

        XCTAssertEqual(review.candidates.map(\.id), ["local-a"])
        XCTAssertEqual(fixture.library.deletions, 0)
        XCTAssertEqual(fixture.store.uploadedLocalIdentifiers().count, 4)
    }

    func testCurrentReviewIsReverifiedAndOnlyDeviceLinksAreRemoved() async throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        let service = fixture.service()
        let review = try await service.scan(fixture.rules)

        let removed = try await service.remove(review)

        XCTAssertEqual(removed, 1)
        XCTAssertEqual(fixture.library.deletions, 1)
        XCTAssertEqual(fixture.library.deletedCandidates, review.candidates)
        XCTAssertEqual(fixture.library.deletedRules, review.rules)
        XCTAssertTrue(fixture.library.requests.allSatisfy { $0.rules == review.rules })
        XCTAssertEqual(fixture.library.requests.count, 2, "Removal must freshly read local resources again")
        XCTAssertEqual(fixture.api.downloads.count, 2, "Removal must re-download the current server original")
        XCTAssertEqual(fixture.counter.value, 1)
        XCTAssertNil(fixture.store.serverAssetIDsByLocalIdentifier()["local-a"])
        let reopened = fixture.reopenStore()
        XCTAssertNotNil(reopened.getBackupRecord(deviceAssetId: "historical-a"), "The server upload record must survive")
        XCTAssertNil(reopened.serverAssetIDsByLocalIdentifier()["local-a"])
        XCTAssertTrue(fixture.server.requests.allSatisfy { $0.httpMethod == "GET" })
    }

    func testLocalVersionOrBytesChangingAfterReviewStopsDeletion() async throws {
        for changeBytes in [false, true] {
            let fixture = try Fixture()
            defer { fixture.close() }
            let service = fixture.service()
            let review = try await service.scan(fixture.rules)
            let old = try XCTUnwrap(fixture.library.snapshots.first)
            let version = old.version
            let changedVersion = LocalAssetVersion(createdAt: version.createdAt,
                modifiedAt: version.modifiedAt.addingTimeInterval(10), isFavorite: version.isFavorite,
                isVideo: version.isVideo, isLivePhoto: version.isLivePhoto, pixelWidth: version.pixelWidth,
                pixelHeight: version.pixelHeight, duration: version.duration, resources: version.resources)
            fixture.library.snapshots = [LocalSpaceCandidate(id: old.id,
                version: changeBytes ? version : changedVersion,
                resourceChecksums: changeBytes ? [.primary: String(repeating: "1", count: 40)] : old.resourceChecksums)]

            await assertRefused { try await service.remove(review) }

            XCTAssertEqual(fixture.library.deletions, 0)
            XCTAssertEqual(fixture.api.downloads.count, 1, "Changed local proof must be rejected before another download")
            XCTAssertEqual(fixture.store.serverAssetIDsByLocalIdentifier()["local-a"], "server-a")
        }
    }

    func testServerCopyDisappearingAfterReviewStopsDeletion() async throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        let service = fixture.service()
        let review = try await service.scan(fixture.rules)
        fixture.server.reply("/assets/server-a/original", bytes: Data(), status: 404)

        await assertRefused { try await service.remove(review) }

        XCTAssertEqual(fixture.library.deletions, 0)
        XCTAssertEqual(fixture.counter.value, 0)
        XCTAssertEqual(fixture.store.serverAssetIDsByLocalIdentifier()["local-a"], "server-a")
    }

    func testFinalBatchMetadataCheckProtectsEarlierFiles() async throws {
        let fixture = try Fixture(ids: ["a", "b"])
        defer { fixture.close() }
        let service = fixture.service()
        let review = try await service.scan(fixture.rules)
        fixture.server.sequence("/assets/server-a", json: [
            fixture.metadata("server-a"), fixture.metadata("server-a"), fixture.metadata("server-a", trashed: true),
        ])

        await assertRefused { try await service.remove(review) }

        XCTAssertEqual(fixture.api.downloads.count, 4, "Both current files were checked before the final batch fence")
        XCTAssertEqual(fixture.library.deletions, 0)
        XCTAssertEqual(fixture.store.serverAssetIDsByLocalIdentifier().count, 2)
    }

    func testMappingChangeAfterReviewCannotDeleteAnUnverifiedReplacement() async throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        let service = fixture.service()
        let review = try await service.scan(fixture.rules)
        try fixture.store.upsertBackupRecord(assetID: "server-replacement", checksum: "new-record", localIdentifier: "local-a")

        await assertRefused { try await service.remove(review) }

        XCTAssertEqual(fixture.library.deletions, 0)
        XCTAssertEqual(fixture.store.serverAssetIDsByLocalIdentifier()["local-a"], "server-replacement")
    }

    func testAccountChangeAfterAdmissionStopsAllWork() async throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        let service = fixture.service()
        fixture.session.testOwner = BackupQueueOwner(server: fixture.session.baseURL!.absoluteString, userID: "another-user")

        await assertRefused { try await service.scan(fixture.rules) }

        XCTAssertTrue(fixture.library.requests.isEmpty)
        XCTAssertTrue(fixture.server.requests.isEmpty)
        XCTAssertEqual(fixture.library.deletions, 0)
    }

    func testMappingChangeDuringVerificationRequiresANewReview() async throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        let review = try await fixture.service().scan(fixture.rules)
        let started = expectation(description: "Mapped original download is held")
        let gate = ServerFileGate(started: started)
        let service = fixture.service(api: fixture.makeAPI(gate: gate))
        let operation = Task { try await service.remove(review) }
        await fulfillment(of: [started], timeout: 2)
        try fixture.store.upsertBackupRecord(assetID: "replacement", checksum: "new-record", localIdentifier: "local-a")
        fixture.server.asset("replacement", bytes: fixture.bytes)
        await gate.release()
        await assertRefused { try await operation.value }

        XCTAssertEqual(fixture.library.deletions, 0)
        XCTAssertEqual(fixture.store.serverAssetIDsByLocalIdentifier()["local-a"], "replacement")
    }

    func testCancellationDuringServerVerificationNeverReachesPhotos() async throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        let review = try await fixture.service().scan(fixture.rules)
        let started = expectation(description: "Current original was downloaded before deletion")
        let gate = ServerFileGate(started: started)
        let api = fixture.makeAPI(gate: gate)
        let service = fixture.service(api: api)
        let operation = Task { try await service.remove(review) }
        await fulfillment(of: [started], timeout: 2)
        operation.cancel()
        await gate.release()
        await assertRefused { try await operation.value }

        XCTAssertEqual(fixture.library.deletions, 0)
        XCTAssertEqual(fixture.store.serverAssetIDsByLocalIdentifier()["local-a"], "server-a")
        XCTAssertTrue(api.downloads.allSatisfy { !FileManager.default.fileExists(atPath: $0.path) })
    }

    func testAccountChangeDuringVerificationNeverReachesPhotos() async throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        let review = try await fixture.service().scan(fixture.rules)
        let started = expectation(description: "Old account's original download is held")
        let gate = ServerFileGate(started: started)
        let service = fixture.service(api: fixture.makeAPI(gate: gate))
        let operation = Task { try await service.remove(review) }
        await fulfillment(of: [started], timeout: 2)
        fixture.session.testOwner = BackupQueueOwner(server: fixture.session.baseURL!.absoluteString, userID: "another-user")
        await gate.release()
        await assertRefused { try await operation.value }

        XCTAssertEqual(fixture.library.deletions, 0)
        XCTAssertEqual(fixture.store.serverAssetIDsByLocalIdentifier()["local-a"], "server-a")
    }

    func testActualDeletedSubsetDeterminesCountAndMappingCleanup() async throws {
        let fixture = try Fixture(ids: ["a", "b"])
        defer { fixture.close() }
        let service = fixture.service()
        let review = try await service.scan(fixture.rules)
        fixture.library.onDelete = { _ in ["local-b"] }

        let removed = try await service.remove(review)

        XCTAssertEqual(removed, 1)
        XCTAssertEqual(fixture.store.serverAssetIDsByLocalIdentifier()["local-a"], "server-a")
        XCTAssertNil(fixture.store.serverAssetIDsByLocalIdentifier()["local-b"])
        XCTAssertEqual(fixture.counter.value, 1)
    }

    func testZeroPhotosResultDoesNotUnlinkOrRefreshCounts() async throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        let service = fixture.service()
        let review = try await service.scan(fixture.rules)
        fixture.library.onDelete = { _ in [] }

        let removed = try await service.remove(review)

        XCTAssertEqual(removed, 0)
        XCTAssertEqual(fixture.store.serverAssetIDsByLocalIdentifier()["local-a"], "server-a")
        XCTAssertEqual(fixture.counter.value, 0)
    }

    func testCommittedDeletionStillCleansUpAfterViewCancellation() async throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        let service = fixture.service()
        let review = try await service.scan(fixture.rules)
        let started = expectation(description: "Photos transaction was submitted")
        let gate = ServiceDeletionGate(started: started)
        fixture.library.onDelete = { candidates in
            await gate.wait()
            return Set(candidates.map(\.id)) // Simulate Photos committing despite late task cancellation.
        }
        let operation = Task { try await service.remove(review) }
        await fulfillment(of: [started], timeout: 2)
        operation.cancel()
        gate.release()
        let removed = try await operation.value

        XCTAssertEqual(removed, 1)
        XCTAssertNil(fixture.store.serverAssetIDsByLocalIdentifier()["local-a"])
        XCTAssertEqual(fixture.counter.value, 1)
    }

    func testTokenRenewalAfterCommitDoesNotLoseSameAccountCleanup() async throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        let service = fixture.service()
        let review = try await service.scan(fixture.rules)
        fixture.library.onDelete = { candidates in
            fixture.session.testAuthHeaders = ["Authorization": "Bearer renewed-token"]
            return Set(candidates.map(\.id))
        }

        let removed = try await service.remove(review)

        XCTAssertEqual(removed, 1)
        XCTAssertNil(fixture.store.serverAssetIDsByLocalIdentifier()["local-a"])
    }

    func testCommittedOldAccountDeletionCannotUnlinkNewAccountData() async throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        let service = fixture.service()
        let review = try await service.scan(fixture.rules)
        fixture.library.onDelete = { candidates in
            fixture.session.testOwner = BackupQueueOwner(server: fixture.session.baseURL!.absoluteString, userID: "new-user")
            try fixture.store.clearAllAccountData()
            try fixture.store.upsertBackupRecord(assetID: "new-account-asset", checksum: "new-account", localIdentifier: "local-a")
            return Set(candidates.map(\.id))
        }

        await assertRefused { try await service.remove(review) }

        XCTAssertEqual(fixture.store.serverAssetIDsByLocalIdentifier()["local-a"], "new-account-asset")
        XCTAssertEqual(fixture.counter.value, 0)
    }

    private func assertRefused<T>(_ operation: () async throws -> T, file: StaticString = #filePath, line: UInt = #line) async {
        do {
            _ = try await operation()
            XCTFail("Unverified or stale work must not proceed", file: file, line: line)
        } catch { }
    }

    @MainActor
    final class Fixture {
        let directory: URL
        let server = ServerCopyHTTPFixture()
        let session = ServiceSafetySession()
        let store: SwiftDataManager
        let library = ServicePhotoLibrary()
        let counter = ServiceRefreshCounter()
        let api: TrackingServerCopyAPI
        let rules = LocalSpaceRules(cutoff: Date(timeIntervalSince1970: 1_700_000_000),
            keepFavorites: true, keepAlbumIDs: ["protected-album"], keepVideos: true)
        let bytes = Data("verified device original".utf8)

        init(ids: [String] = ["a"]) throws {
            directory = FileManager.default.temporaryDirectory.appendingPathComponent("free-space-service-\(UUID())")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            store = SwiftDataManager(storeURL: directory.appendingPathComponent("test.store"),
                backupJournalURL: directory.appendingPathComponent("backup.json"))
            XCTAssertTrue(store.isPersistentStoreAvailable)
            try session.setServer(server.baseURL.absoluteString)
            session.isLoggedIn = true
            session.testAuthHeaders = ["Authorization": "Bearer current-token"]
            session.testOwner = BackupQueueOwner(server: session.baseURL!.absoluteString, userID: "current-user")
            let configuration = NetworkResponseCache.configuration()
            configuration.protocolClasses = [ServerCopyURLProtocol.self]
            api = TrackingServerCopyAPI(session: session, urlSession: URLSession(configuration: configuration), gate: nil)
            for id in ids {
                try store.upsertBackupRecord(assetID: "server-\(id)", checksum: "historical-\(id)", localIdentifier: "local-\(id)")
                server.asset("server-\(id)", bytes: bytes)
                let version = LocalAssetVersion(createdAt: Date(timeIntervalSince1970: 1_600_000_000),
                    modifiedAt: Date(timeIntervalSince1970: 1_600_000_000), isFavorite: false, isVideo: false,
                    isLivePhoto: false, pixelWidth: 100, pixelHeight: 100, duration: 0,
                    resources: [.init(type: 1, filename: "photo.jpg", contentType: "public.jpeg")])
                let digest = Insecure.SHA1.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
                library.snapshots.append(LocalSpaceCandidate(id: "local-\(id)", version: version, resourceChecksums: [.primary: digest]))
            }
        }

        func service(api: TrackingServerCopyAPI? = nil) -> FreeUpSpaceService {
            let counter = counter
            return FreeUpSpaceService(session: session, dataManager: store, library: library,
                verifier: ServerCopyVerifier(api: api ?? self.api), refreshCounts: { counter.value += 1 })
        }

        func makeAPI(gate: ServerFileGate) -> TrackingServerCopyAPI {
            let configuration = NetworkResponseCache.configuration()
            configuration.protocolClasses = [ServerCopyURLProtocol.self]
            return TrackingServerCopyAPI(session: session, urlSession: URLSession(configuration: configuration), gate: gate)
        }

        func metadata(_ id: String, trashed: Bool = false) -> [String: Any] {
            ["id": id, "type": "IMAGE", "isTrashed": trashed, "isOffline": false,
             "checksum": Data(Insecure.SHA1.hash(data: bytes)).base64EncodedString()]
        }

        func reopenStore() -> SwiftDataManager {
            SwiftDataManager(storeURL: directory.appendingPathComponent("test.store"),
                backupJournalURL: directory.appendingPathComponent("backup.json"))
        }

        func close() {
            library.onDelete = nil
            server.close()
            try? FileManager.default.removeItem(at: directory)
        }
    }
}

@MainActor
final class ServiceSafetySession: MockSessionManager {
    var testOwner: BackupQueueOwner?
    override var backupQueueOwner: BackupQueueOwner? { testOwner }
}

@MainActor
final class ServiceRefreshCounter { var value = 0 }

@MainActor
final class ServicePhotoLibrary: LocalSpaceLibrary {
    struct Request { let ids: Set<String>; let rules: LocalSpaceRules }
    var snapshots: [LocalSpaceCandidate] = []
    private(set) var requests: [Request] = []
    private(set) var deletions = 0
    private(set) var deletedCandidates: [LocalSpaceCandidate] = []
    private(set) var deletedRules: LocalSpaceRules?
    var onDelete: (([LocalSpaceCandidate]) async throws -> Set<String>)?

    func candidates(from localIDs: Set<String>, rules: LocalSpaceRules) async throws -> [LocalSpaceCandidate] {
        requests.append(Request(ids: localIDs, rules: rules))
        return snapshots.filter { localIDs.contains($0.id) }
    }

    func deleteVerified(_ candidates: [LocalSpaceCandidate], rules: LocalSpaceRules) async throws -> Set<String> {
        deletions += 1
        deletedCandidates = candidates
        deletedRules = rules
        return try await onDelete?(candidates) ?? Set(candidates.map(\.id))
    }
}

@MainActor
private final class ServiceDeletionGate {
    let started: XCTestExpectation
    private var continuation: CheckedContinuation<Void, Never>?
    init(started: XCTestExpectation) { self.started = started }
    func wait() async {
        await withCheckedContinuation {
            continuation = $0
            started.fulfill()
        }
    }
    func release() {
        XCTAssertNotNil(continuation)
        continuation?.resume()
        continuation = nil
    }
}
