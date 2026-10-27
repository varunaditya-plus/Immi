import Photos
import XCTest
@testable import ImmichApp

@MainActor
final class BackupSourceAvailabilityTests: XCTestCase {
    private var directories: [URL] = []
    private let timestamp = Date(timeIntervalSince1970: 1_700_000_000)

    override func tearDown() async throws {
        for directory in directories { try? FileManager.default.removeItem(at: directory) }
        directories.removeAll()
        try await super.tearDown()
    }

    func testDeniedRestrictedAndLimitedScopesCannotPruneFailedOriginals() async throws {
        for status in [PHAuthorizationStatus.denied, .restricted, .limited, .notDetermined] {
            let fixture = try fixture()
            try seed("photo", in: fixture.queue)
            try fixture.queue.markFailed("photo", error: "Existing failure", now: timestamp)
            let original = fixture.queue.items
            let bytes = try Data(contentsOf: fixture.url)

            let changed = try await fixture.requests.pruneUnavailableFailures(
                canProcess: { true }, hasFullPhotoAccess: { status == .authorized },
                existingIdentifiers: { _ in XCTFail("An incomplete scope cannot prove absence"); return [] },
                preservedIdentifiers: { [] })

            XCTAssertFalse(changed)
            XCTAssertEqual(fixture.queue.items, original)
            XCTAssertEqual(try Data(contentsOf: fixture.url), bytes)
            XCTAssertEqual(BackupQueueStore(fileURL: fixture.url).items, original)
        }
    }

    func testFullAccessPrunesOnlyMissingUnprotectedFailures() async throws {
        let fixture = try fixture()
        for id in ["missing", "existing", "recovery", "active", "queued"] {
            try seed(id, in: fixture.queue)
            if id != "active", id != "queued" {
                try fixture.queue.markFailed(id, error: "Existing failure", now: timestamp)
            }
        }
        try fixture.queue.markQueued("queued", now: timestamp)
        let retained = fixture.queue.items.filter { $0.id != "missing" }
        var scanned: [String] = []

        let changed = try await fixture.requests.pruneUnavailableFailures(
            canProcess: { true }, hasFullPhotoAccess: { true },
            existingIdentifiers: { ids in scanned = ids; return ["existing"] },
            preservedIdentifiers: { ["recovery"] })

        XCTAssertTrue(changed)
        XCTAssertEqual(Set(scanned), ["missing", "existing", "recovery"])
        XCTAssertNil(fixture.queue.item(id: "missing"))
        XCTAssertEqual(fixture.queue.items, retained)
        XCTAssertEqual(BackupQueueStore(fileURL: fixture.url).items, retained)
    }

    func testPruningRejectsAccessLossCancellationAndOwnershipChangesDuringTheScan() async throws {
        for interruption in 0..<3 {
            let fixture = try fixture()
            try seed("photo", in: fixture.queue)
            try fixture.queue.markFailed("photo", error: "Existing failure", now: timestamp)
            let original = fixture.queue.items
            let bytes = try Data(contentsOf: fixture.url)
            let gate = SourceAvailabilityGate()
            var fullAccess = true
            var currentOwner = true
            let prune = Task { try await fixture.requests.pruneUnavailableFailures(
                canProcess: { currentOwner }, hasFullPhotoAccess: { fullAccess },
                existingIdentifiers: { _ in await gate.value() }, preservedIdentifiers: { [] }) }
            addTeardownBlock { await gate.close(); _ = try? await prune.value }
            await fulfillment(of: [gate.started], timeout: 2)
            switch interruption {
            case 0: fullAccess = false
            case 1: currentOwner = false
            default: prune.cancel()
            }
            gate.resolve([])
            let changed = try await prune.value

            XCTAssertFalse(changed)
            XCTAssertEqual(fixture.queue.items, original)
            XCTAssertEqual(try Data(contentsOf: fixture.url), bytes)
        }
    }

    func testPruningCannotDiscardAFailureRetriedWhileItsExistenceScanWasInFlight() async throws {
        let fixture = try fixture()
        try seed("photo", in: fixture.queue)
        try fixture.queue.markFailed("photo", error: "Existing failure", now: timestamp)
        let gate = SourceAvailabilityGate()
        let prune = Task { try await fixture.requests.pruneUnavailableFailures(
            canProcess: { true }, hasFullPhotoAccess: { true },
            existingIdentifiers: { _ in await gate.value() }, preservedIdentifiers: { [] }) }
        addTeardownBlock { await gate.close(); _ = try? await prune.value }
        await fulfillment(of: [gate.started], timeout: 2)
        try fixture.requests.retry("photo")
        let retried = fixture.queue.items
        let bytes = try Data(contentsOf: fixture.url)
        gate.resolve([])

        let changed = try await prune.value

        XCTAssertFalse(changed)
        XCTAssertEqual(fixture.queue.items, retried)
        XCTAssertEqual(try Data(contentsOf: fixture.url), bytes)
        XCTAssertEqual(fixture.queue.item(id: "photo")?.intent, .manualUpload)
        XCTAssertEqual(fixture.queue.item(id: "photo")?.motionAssetID, "saved-motion")
    }

    func testPermanentFailureRetainsIntentAndProgressUnlessFullAccessProvesDeletion() throws {
        for (fullAccess, exists) in [(false, false), (true, true), (true, false)] {
            let fixture = try fixture()
            try seed("photo", in: fixture.queue)
            let original = try XCTUnwrap(fixture.queue.item(id: "photo"))
            try fixture.requests.markFailedOrDiscard("photo", error: "Server rejected the upload",
                hasFullPhotoAccess: { fullAccess }, sourceExists: { exists })

            if fullAccess, !exists {
                XCTAssertNil(fixture.queue.item(id: "photo"))
                XCTAssertTrue(BackupQueueStore(fileURL: fixture.url).items.isEmpty)
            } else {
                let retained = try XCTUnwrap(BackupQueueStore(fileURL: fixture.url).item(id: "photo"))
                XCTAssertEqual(retained.state, .failed)
                XCTAssertEqual(retained.intent, original.intent)
                XCTAssertEqual(retained.phase, original.phase)
                XCTAssertEqual(retained.motionAssetID, original.motionAssetID)
                XCTAssertEqual(retained.checksum, original.checksum)
                XCTAssertEqual(retained.attemptCount, original.attemptCount)
            }
        }
        let fixture = try fixture()
        try seed("photo", in: fixture.queue)
        var fullAccess = true
        try fixture.requests.markFailedOrDiscard("photo", error: "Failure",
            hasFullPhotoAccess: { fullAccess }, sourceExists: { fullAccess = false; return false })
        XCTAssertEqual(fixture.queue.item(id: "photo")?.state, .failed,
            "Revocation during an existence check cannot prove deletion")
    }

    func testCompletedMotionPersistsTheStillHandoffWithoutLosingUserIntent() throws {
        let fixture = try fixture()
        try fixture.queue.enqueue(["live"], intent: .manualUpload, now: timestamp)
        try fixture.queue.markPreparing("live", phase: .livePhotoMotion, now: timestamp)
        try fixture.queue.markUploading("live", phase: .livePhotoMotion, checksum: "motion-checksum",
            taskIdentifier: 42, now: timestamp)
        let original = try XCTUnwrap(fixture.queue.item(id: "live"))

        try fixture.requests.retainCompletedMotion("live", motionAssetID: "uploaded-motion")

        let reopened = BackupQueueStore(fileURL: fixture.url)
        let retained = try XCTUnwrap(reopened.item(id: "live"))
        XCTAssertEqual(retained.state, .queued)
        XCTAssertEqual(retained.phase, .primaryAsset)
        XCTAssertEqual(retained.motionAssetID, "uploaded-motion")
        XCTAssertEqual(retained.intent, original.intent)
        XCTAssertEqual(retained.checksum, original.checksum)
        XCTAssertEqual(retained.attemptCount, original.attemptCount)
        XCTAssertEqual(retained.createdAt, original.createdAt)
        XCTAssertNil(retained.taskIdentifier)
        XCTAssertEqual(BackupUploadRequests(queue: reopened).readyItems(automaticEnabled: false).map(\.id), ["live"])
    }

    func testCompletedMotionCannotReviveACancelledOrAlreadyAdvancedItem() throws {
        for phase in [BackupUploadPhase.primaryAsset, .livePhotoMotion] {
            let fixture = try fixture()
            try seed("photo", in: fixture.queue, phase: phase)
            if phase == .livePhotoMotion { try fixture.queue.markCancelling("photo", now: timestamp) }
            let original = fixture.queue.items
            let bytes = try Data(contentsOf: fixture.url)

            try fixture.requests.retainCompletedMotion("photo", motionAssetID: "late-motion")

            XCTAssertEqual(fixture.queue.items, original)
            XCTAssertEqual(try Data(contentsOf: fixture.url), bytes)
        }
    }

    private func seed(_ id: String, in queue: BackupQueueStore, phase: BackupUploadPhase = .primaryAsset) throws {
        try queue.enqueue([id], intent: .manualUpload, now: timestamp)
        try queue.markPreparing(id, phase: phase, motionAssetID: "saved-motion", now: timestamp)
        try queue.markUploading(id, phase: phase, checksum: "saved-checksum", taskIdentifier: 42, now: timestamp)
    }

    private func fixture() throws -> (queue: BackupQueueStore, requests: BackupUploadRequests, url: URL) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("backup-availability-\(UUID())")
        directories.append(directory)
        let url = directory.appendingPathComponent("queue.json")
        let queue = BackupQueueStore(fileURL: url)
        return (queue, BackupUploadRequests(queue: queue), url)
    }
}

@MainActor
private final class SourceAvailabilityGate {
    let started = XCTestExpectation(description: "Source existence scan reached its response boundary")
    private var continuation: CheckedContinuation<Set<String>, Never>?
    private var closed = false

    func value() async -> Set<String> {
        guard !closed else { return [] }
        return await withCheckedContinuation { continuation = $0; started.fulfill() }
    }

    func resolve(_ ids: Set<String>) {
        XCTAssertNotNil(continuation)
        continuation?.resume(returning: ids)
        continuation = nil
    }

    func close() {
        closed = true
        continuation?.resume(returning: [])
        continuation = nil
    }
}
