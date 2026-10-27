import Foundation
import XCTest
@testable import ImmichApp

@MainActor
final class AutomaticBackupDiscoveryTests: XCTestCase {
    private var directories: [URL] = []

    override func tearDown() async throws {
        for directory in directories { try? FileManager.default.removeItem(at: directory) }
        directories.removeAll()
        try await super.tearDown()
    }

    func testCompletionRefillsBackUpEveryPhotoBeyondTwoHundredWithoutAnotherStart() async throws {
        let fixture = try fixture(count: 237)
        try await fixture.run()

        XCTAssertEqual(Set(fixture.queue.items.map(\.id)), Set((0..<100).map(Fixture.id)))
        XCTAssertEqual(fixture.queue.snapshot.active, BackupStagingPolicy.maximumActiveUploads)
        XCTAssertTrue(fixture.discovery.hasCandidates(
            photos: fixture.photos, uploadedIDs: fixture.manager.uploadedLocalIdentifiers()))

        for _ in 0..<237 {
            let finished = try XCTUnwrap(fixture.activeTransfers.first, "Discovery must keep work available until the last photo")
            try fixture.complete(finished)
            if fixture.manager.uploadedLocalIdentifiers().count < fixture.photos.count {
                XCTAssertTrue(fixture.queue.snapshot.hasWork, "A completed window must not look like a completed library")
            }
            // This is the same run invoked by the service's upload-completion
            // refill; there is no new cycle, launch, library or network event.
            try await fixture.run()
        }

        let expected = Set((0..<237).map(Fixture.id))
        XCTAssertEqual(fixture.manager.uploadedLocalIdentifiers(), expected)
        XCTAssertEqual(fixture.reopenedManager().uploadedLocalIdentifiers(), expected)
        XCTAssertEqual(Set(fixture.stagedIDs), expected)
        XCTAssertEqual(fixture.stagedIDs.count, 237, "No photo may be staged twice")
        XCTAssertEqual(fixture.queue.snapshot.completed, 237)
        XCTAssertEqual(fixture.queue.snapshot.total, 237)
        XCTAssertFalse(fixture.queue.snapshot.hasWork)
        XCTAssertTrue(fixture.queue.snapshot.completionNotificationPending)
        XCTAssertLessThanOrEqual(fixture.maximumRunnableWindow, 100)
        XCTAssertEqual(fixture.maximumActiveTransfers, BackupStagingPolicy.maximumActiveUploads)

        try fixture.queue.consumeCompletionNotification()
        let calls = fixture.processCalls
        try await fixture.run()
        XCTAssertEqual(fixture.processCalls, calls)
        XCTAssertFalse(fixture.queue.snapshot.completionNotificationPending)
        XCTAssertEqual(fixture.queue.snapshot.completed, 237)
    }

    func testSynchronousCompletionsContinuePastBothBatchBoundariesAndKeepTotals() async throws {
        let fixture = try fixture(count: 237)
        fixture.completesImmediately = true

        try await fixture.run()

        XCTAssertEqual(fixture.processCalls, 3)
        XCTAssertEqual(fixture.stagedIDs, (0..<237).map(Fixture.id))
        XCTAssertEqual(fixture.queue.snapshot.completed, 237)
        XCTAssertEqual(fixture.queue.snapshot.total, 237)
        XCTAssertTrue(fixture.queue.items.isEmpty)
        XCTAssertEqual(fixture.reopenedManager().uploadedLocalIdentifiers().count, 237)
        XCTAssertEqual(fixture.maximumRunnableWindow, 100)
    }

    func testRefillingExistingReadyItemsDoesNotRescanLibraryOrMappingsUntilTheWindowDrains() async throws {
        let fixture = try fixture(count: 237)
        try await fixture.run()
        let initialPhotoReads = fixture.photoReads
        let initialMappingReads = fixture.uploadedReads
        XCTAssertGreaterThan(initialPhotoReads, 0)
        XCTAssertGreaterThan(initialMappingReads, 0)

        try fixture.complete(try XCTUnwrap(fixture.activeTransfers.first))
        try await fixture.run()

        XCTAssertEqual(fixture.photoReads, initialPhotoReads, "Queued metadata must be used before rescanning the whole library")
        XCTAssertEqual(fixture.uploadedReads, initialMappingReads)
        XCTAssertEqual(fixture.stagedIDs.count, 4)
        for _ in 0..<100 where fixture.photoReads == initialPhotoReads {
            try fixture.complete(try XCTUnwrap(fixture.activeTransfers.first))
            try await fixture.run()
        }

        XCTAssertGreaterThan(fixture.photoReads, initialPhotoReads, "Draining ready work must discover the next window")
        XCTAssertGreaterThan(fixture.uploadedReads, initialMappingReads)
        XCTAssertTrue(fixture.queue.items.contains { $0.id == Fixture.id(100) })
        XCTAssertLessThanOrEqual(fixture.maximumRunnableWindow, 100)
    }

    func testNewestHundredFailedEntriesDoNotConsumeTheDiscoveryWindowOrGetRetried() async throws {
        let fixture = try fixture(count: 237)
        let failedIDs = (0..<100).map(Fixture.id)
        let recordedAt = Date(timeIntervalSince1970: 1000)
        try fixture.queue.enqueue(failedIDs, now: recordedAt)
        for (index, id) in failedIDs.enumerated() {
            try fixture.queue.markPreparing(id, phase: .livePhotoMotion, now: recordedAt)
            try fixture.queue.markUploading(id, phase: .livePhotoMotion,
                checksum: "old-\(id)", taskIdentifier: index + 1, now: recordedAt)
            try fixture.queue.markFailed(id, error: "Permanent failure \(id)", now: recordedAt)
        }
        let originalFailures = fixture.queue.items

        try await fixture.run()

        XCTAssertEqual(fixture.queue.items.filter { failedIDs.contains($0.id) }, originalFailures)
        XCTAssertEqual(fixture.queue.snapshot.failed, 100)
        XCTAssertEqual(fixture.stagedIDs, (100..<103).map(Fixture.id))
        XCTAssertEqual(Set(fixture.queue.items.filter { !failedIDs.contains($0.id) }.map(\.id)),
            Set((100..<200).map(Fixture.id)))
        let reopened = BackupQueueStore(fileURL: fixture.queueURL)
        XCTAssertEqual(reopened.items.filter { failedIDs.contains($0.id) }, originalFailures)
    }

    func testPreparationFailuresAdvanceToOlderPhotosWithoutAnUploadCompletion() async throws {
        let fixture = try fixture(count: 237)
        fixture.failPreparationIDs = Set((0..<100).map(Fixture.id))

        try await fixture.run()

        XCTAssertEqual(Set(fixture.queue.failedIDs), fixture.failPreparationIDs)
        XCTAssertEqual(fixture.stagedIDs, (100..<103).map(Fixture.id))
        XCTAssertEqual(fixture.processCalls, 2)
        XCTAssertTrue(fixture.manager.uploadedLocalIdentifiers().isEmpty)
        XCTAssertEqual(fixture.queue.snapshot.active, 3)
    }

    func testExistingQueuedWindowDoesNotAdmitAnotherHundredOrDuplicateItsEntries() async throws {
        let fixture = try fixture(count: 237)
        let existingIDs = (0..<100).map(Fixture.id)
        try fixture.queue.enqueue(existingIDs)

        try await fixture.run()
        try await fixture.run()

        XCTAssertEqual(Set(fixture.queue.items.map(\.id)), Set(existingIDs))
        XCTAssertEqual(fixture.queue.items.count, 100)
        XCTAssertEqual(fixture.stagedIDs, (0..<3).map(Fixture.id))
        XCTAssertEqual(fixture.queue.snapshot.active, 3)
        XCTAssertEqual(fixture.queue.snapshot.queued, 97)
    }

    func testExistingQueueBeyondOneWindowContinuesAfterFirstHundredPreparationFailures() async throws {
        let fixture = try fixture(count: 200)
        try fixture.queue.enqueue((0..<200).map(Fixture.id))
        fixture.failPreparationIDs = Set((0..<100).map(Fixture.id))

        try await fixture.run()

        XCTAssertEqual(fixture.processCalls, 2)
        XCTAssertEqual(Set(fixture.queue.failedIDs), fixture.failPreparationIDs)
        XCTAssertEqual(fixture.stagedIDs, (100..<103).map(Fixture.id))
        XCTAssertEqual(fixture.queue.items.count, 200, "The legacy backlog is processed without rediscovering its existing entries")
        XCTAssertEqual(fixture.queue.snapshot.active, 3)
        XCTAssertEqual(fixture.queue.snapshot.queued, 97)
        XCTAssertTrue(fixture.manager.uploadedLocalIdentifiers().isEmpty)
    }

    func testWaitingOriginalsDoNotBlockOlderPhotosOrLoseTheirRetryState() async throws {
        let fixture = try fixture(count: 237)
        fixture.waitForOriginalIDs = Set((0..<100).map(Fixture.id))

        try await fixture.run()

        let waits = fixture.queue.items.filter { fixture.waitForOriginalIDs.contains($0.id) }
        XCTAssertEqual(waits.count, 100)
        XCTAssertTrue(waits.allSatisfy { $0.state == .waitingForICloud && $0.nextAttemptAt == .distantFuture })
        XCTAssertEqual(fixture.stagedIDs, (100..<103).map(Fixture.id))
        let beforeRefill = waits
        try fixture.complete(try XCTUnwrap(fixture.activeTransfers.first))
        try await fixture.run()
        XCTAssertEqual(fixture.queue.items.filter { fixture.waitForOriginalIDs.contains($0.id) }, beforeRefill)
        XCTAssertEqual(fixture.queue.snapshot.waitingForICloud, 100)
        XCTAssertLessThanOrEqual(fixture.maximumRunnableWindow, 100)
    }

    func testClosedNetworkGateStopsMetadataWalkUntilUploadingIsPermittedAgain() async throws {
        let fixture = try fixture(count: 237)
        fixture.waitForNetworkIDs = Set((0..<100).map(Fixture.id))
        fixture.pausesAfterNetworkWaits = true

        try await fixture.run()

        XCTAssertEqual(fixture.processCalls, 1)
        XCTAssertEqual(fixture.queue.items.count, 100)
        XCTAssertEqual(fixture.queue.snapshot.waitingForNetwork, 100)
        XCTAssertTrue(fixture.stagedIDs.isEmpty)
        XCTAssertTrue(fixture.discovery.hasCandidates(photos: fixture.photos, uploadedIDs: []),
            "The network gate, rather than candidate exhaustion, must stop this scan")
        let waits = fixture.queue.items

        fixture.enabled = true
        fixture.pausesAfterNetworkWaits = false
        try await fixture.run()

        XCTAssertEqual(fixture.stagedIDs, (100..<103).map(Fixture.id))
        XCTAssertEqual(fixture.queue.items.filter { fixture.waitForNetworkIDs.contains($0.id) }, waits)
    }

    func testFullStagingOrAnUnchangedQueueDoesNotSpinOrAdmitAnUnboundedBacklog() async throws {
        let fixture = try fixture(count: 237)
        fixture.stagedBytes = BackupStagingPolicy.stagingThreshold
        fixture.processCallLimit = 3

        try await fixture.run()
        XCTAssertEqual(fixture.processCalls, 1)
        XCTAssertEqual(fixture.queue.items.count, 100)
        XCTAssertTrue(fixture.stagedIDs.isEmpty)
        let before = fixture.queue.items
        try await fixture.run()
        XCTAssertEqual(fixture.processCalls, 2)
        XCTAssertEqual(fixture.queue.items, before)

        fixture.stagedBytes = 0
        fixture.processCallLimit = 1000
        try await fixture.run()
        XCTAssertEqual(fixture.stagedIDs, (0..<3).map(Fixture.id))
        XCTAssertEqual(fixture.queue.items.count, 100)
        XCTAssertEqual(fixture.maximumActiveTransfers, 3)
    }

    func testUploadedAndSystemOwnedPhotosAreExcludedAndAnEmptyPassDoesNoWork() async throws {
        let fixture = try fixture(count: 10)
        for index in 0..<5 { try fixture.recordMapping(Fixture.id(index)) }
        fixture.externalActiveIDs = Set((5..<8).map(Fixture.id))

        try await fixture.run()

        XCTAssertEqual(Set(fixture.queue.items.map(\.id)), Set((8..<10).map(Fixture.id)))
        XCTAssertTrue(fixture.stagedIDs.isEmpty, "Existing system transfers still own all three staging slots")
        for index in 5..<8 { try fixture.recordMapping(Fixture.id(index)) }
        fixture.externalActiveIDs = []
        try await fixture.run()
        XCTAssertEqual(fixture.stagedIDs, (8..<10).map(Fixture.id))
        for id in fixture.activeTransfers { try fixture.complete(id) }
        let calls = fixture.processCalls
        try await fixture.run()
        XCTAssertEqual(fixture.processCalls, calls)
        XCTAssertFalse(fixture.discovery.hasCandidates(
            photos: fixture.photos, uploadedIDs: fixture.manager.uploadedLocalIdentifiers()))
    }

    func testDiscardedMetadataIsNotRediscoveredUntilANewCycle() async throws {
        let fixture = try fixture(count: 237)
        fixture.discardsMissingOriginals = true
        fixture.processCallLimit = 7

        try await fixture.run()

        XCTAssertEqual(fixture.processCalls, 3)
        XCTAssertTrue(fixture.queue.items.isEmpty)
        XCTAssertFalse(fixture.discovery.hasCandidates(photos: fixture.photos, uploadedIDs: []))
        try await fixture.run()
        XCTAssertEqual(fixture.processCalls, 3)
        fixture.discovery.beginCycle()
        XCTAssertTrue(fixture.discovery.hasCandidates(photos: fixture.photos, uploadedIDs: []))
        try await fixture.run()
        XCTAssertEqual(fixture.processCalls, 6, "An explicit new scan can reconsider metadata refreshed by PhotoKit")
    }

    func testDisableDuringActiveTaskLookupPreventsDiscoveryAndCurrentRunCanResume() async throws {
        try await assertHeldLookupCannotAdmitWork(cancel: false)
    }

    func testCancellationDuringActiveTaskLookupPreventsDiscoveryAndCurrentRunCanResume() async throws {
        try await assertHeldLookupCannotAdmitWork(cancel: true)
    }

    func testNewCycleRejectsThePreviousCyclesHeldTaskLookup() async throws {
        let fixture = try fixture(count: 237)
        let held = HeldActiveIdentifiers()
        let old = Task { try await fixture.run(activeIDs: { await held.value() }) }
        await fulfillment(of: [held.started], timeout: 2)
        fixture.discovery.beginCycle()
        try await fixture.run()
        let admitted = fixture.queue.items
        let staged = fixture.stagedIDs
        held.resolve([])
        try await old.value

        XCTAssertEqual(fixture.queue.items, admitted)
        XCTAssertEqual(fixture.stagedIDs, staged)
        XCTAssertEqual(fixture.processCalls, 1)
    }

    func testQueuePersistenceFailureCannotBeginStaging() async throws {
        let fixture = try fixture(count: 237)
        try FileManager.default.createDirectory(at: fixture.queueURL, withIntermediateDirectories: true)

        do {
            try await fixture.run()
            XCTFail("A failed queue write must propagate before any original can be staged")
        } catch {
            XCTAssertTrue(error is BackupQueueStoreError)
        }

        XCTAssertEqual(fixture.processCalls, 0)
        XCTAssertTrue(fixture.stagedIDs.isEmpty)
        XCTAssertTrue(BackupQueueStore(fileURL: fixture.queueURL).items.isEmpty)
    }

    private func assertHeldLookupCannotAdmitWork(cancel: Bool) async throws {
        let fixture = try fixture(count: 237)
        let held = HeldActiveIdentifiers()
        let pending = Task { try await fixture.run(activeIDs: { await held.value() }) }
        await fulfillment(of: [held.started], timeout: 2)
        if cancel { pending.cancel() }
        else { fixture.enabled = false }
        held.resolve([])
        try await pending.value

        XCTAssertTrue(fixture.queue.items.isEmpty)
        XCTAssertEqual(fixture.processCalls, 0)
        fixture.enabled = true
        fixture.discovery.beginCycle()
        try await fixture.run()
        XCTAssertEqual(fixture.stagedIDs, (0..<3).map(Fixture.id))
    }

    private func fixture(count: Int) throws -> Fixture {
        let value = try Fixture(count: count)
        directories.append(value.directory)
        return value
    }
}

@MainActor
private final class Fixture {
    let directory: URL
    let queueURL: URL
    let queue: BackupQueueStore
    let manager: SwiftDataManager
    let discovery: AutomaticBackupDiscovery
    let photos: [LocalPhoto]
    var enabled = true
    var externalActiveIDs: Set<String> = []
    var stagedBytes = 0
    var failPreparationIDs: Set<String> = []
    var waitForOriginalIDs: Set<String> = []
    var waitForNetworkIDs: Set<String> = []
    var pausesAfterNetworkWaits = false
    var discardsMissingOriginals = false
    var completesImmediately = false
    var processCallLimit = 1000
    private(set) var processCalls = 0
    private(set) var stagedIDs: [String] = []
    private(set) var maximumRunnableWindow = 0
    private(set) var maximumActiveTransfers = 0
    private(set) var photoReads = 0
    private(set) var uploadedReads = 0
    private var taskIdentifier = 1000

    var activeTransfers: [String] { queue.items.filter { $0.state == .uploading }.map(\.id) }

    init(count: Int) throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("automatic-discovery-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        queueURL = directory.appendingPathComponent("queue.json")
        queue = BackupQueueStore(fileURL: queueURL)
        manager = SwiftDataManager(storeURL: directory.appendingPathComponent("cache.store"),
            backupJournalURL: directory.appendingPathComponent("mappings.json"))
        discovery = AutomaticBackupDiscovery(queue: queue)
        // Supply oldest first so the production selector must establish its
        // newest-first order rather than relying on this fixture's input order.
        photos = (0..<count).reversed().map { index in
            let date = Date(timeIntervalSince1970: 1_700_000_000 - Double(index))
            return LocalPhoto(id: Self.id(index), createdAt: date, modifiedAt: date,
                isVideo: false, isLivePhoto: false, duration: nil, ratio: 1)
        }
        discovery.beginCycle()
    }

    static func id(_ index: Int) -> String { String(format: "photo-%03d", index) }

    func run(activeIDs: (@MainActor () async -> Set<String>)? = nil) async throws {
        try await discovery.run(photos: {
            self.photoReads += 1
            return self.photos
        }, uploadedIDs: {
            self.uploadedReads += 1
            return self.manager.uploadedLocalIdentifiers()
        },
            activeIDs: activeIDs ?? { self.externalActiveIDs.union(self.activeTransfers) },
            shouldContinue: { self.enabled }, processReady: { await self.processReady() })
    }

    func recordMapping(_ id: String) throws {
        try manager.upsertBackupRecord(assetID: "server-\(id)", checksum: "checksum-\(id)", localIdentifier: id)
    }

    func complete(_ id: String) throws {
        try recordMapping(id)
        try queue.markCompleted(id)
    }

    func reopenedManager() -> SwiftDataManager {
        SwiftDataManager(storeURL: directory.appendingPathComponent("cache.store"),
            backupJournalURL: directory.appendingPathComponent("mappings.json"))
    }

    /// Only the resource boundary is simulated: the coordinator and persistent
    /// queue are real. No test can export or upload a user's actual Photos asset.
    private func processReady() async {
        processCalls += 1
        guard processCalls <= processCallLimit else {
            enabled = false
            return XCTFail("An unchanged queue must not make automatic discovery spin")
        }
        maximumRunnableWindow = max(maximumRunnableWindow,
            queue.readyItems(limit: 10_000).count + queue.snapshot.active)
        defer {
            if pausesAfterNetworkWaits, queue.snapshot.waitingForNetwork > 0 { enabled = false }
        }
        do {
            for item in queue.readyItems(limit: 100) {
                let activeCount = externalActiveIDs.union(activeTransfers).count
                guard BackupStagingPolicy.canPrepare(activeCount: activeCount, stagedBytes: stagedBytes) else { return }
                if discardsMissingOriginals {
                    try queue.discard(item.id)
                    continue
                }
                try queue.markPreparing(item.id, phase: .primaryAsset)
                if failPreparationIDs.contains(item.id) {
                    try queue.markFailed(item.id, error: "The original cannot be prepared")
                    continue
                }
                if waitForOriginalIDs.contains(item.id) {
                    try queue.markRetry(item.id, state: .waitingForICloud,
                        error: "Original is not local yet", retryAt: .distantFuture)
                    continue
                }
                if waitForNetworkIDs.contains(item.id) {
                    try queue.markRetry(item.id, state: .waitingForNetwork,
                        error: "The current transport is not permitted", retryAt: .distantFuture)
                    continue
                }
                taskIdentifier += 1
                try queue.markUploading(item.id, phase: .primaryAsset,
                    checksum: "checksum-\(item.id)", taskIdentifier: taskIdentifier)
                stagedIDs.append(item.id)
                maximumActiveTransfers = max(maximumActiveTransfers, externalActiveIDs.union(activeTransfers).count)
                if completesImmediately { try complete(item.id) }
            }
        } catch {
            XCTFail("The controlled resource boundary failed: \(error)")
            enabled = false
        }
    }
}

@MainActor
private final class HeldActiveIdentifiers {
    let started = XCTestExpectation(description: "System task lookup is suspended")
    private var continuation: CheckedContinuation<Set<String>, Never>?

    func value() async -> Set<String> {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            started.fulfill()
        }
    }

    func resolve(_ ids: Set<String>, file: StaticString = #filePath, line: UInt = #line) {
        guard let continuation else {
            return XCTFail("The production lookup did not start before the held result was released", file: file, line: line)
        }
        continuation.resume(returning: ids)
        self.continuation = nil
    }
}
