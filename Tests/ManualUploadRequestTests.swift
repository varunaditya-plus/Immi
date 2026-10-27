import Foundation
import XCTest
@testable import ImmichApp

@MainActor
final class ManualUploadRequestTests: XCTestCase {
    private var directories: [URL] = []

    override func tearDown() async throws {
        for directory in directories { try? FileManager.default.removeItem(at: directory) }
        directories.removeAll()
        try await super.tearDown()
    }

    func testManualUploadOnCellularStagesOnlyRequestedUnmappedPhotos() async throws {
        let fixture = try fixture()
        fixture.photos = ["selected": photo("selected"), "automatic": photo("automatic")]
        try fixture.queue.enqueue(["failed", "canceled", "automatic"], now: timestamp)
        try fixture.queue.markFailed("failed", error: "Server rejected this photo", now: timestamp)
        try fixture.queue.markFailed("canceled", error: "Upload canceled.", now: timestamp)
        let unrelated = fixture.queue.items

        try fixture.requests.requestUploads([
            LocalPhotoLibrary.assetID(for: "selected"), "selected", "already-uploaded",
        ], uploadedIDs: ["already-uploaded"])
        try await fixture.process()

        XCTAssertEqual(fixture.prepared.map(\.id), ["selected"])
        XCTAssertEqual(fixture.prepared.first?.allowsCellular, true)
        XCTAssertEqual(fixture.prepared.first?.mayReadFromICloud, true)
        XCTAssertEqual(fixture.queue.item(id: "selected")?.state, .uploading)
        XCTAssertEqual(fixture.queue.item(id: "selected")?.intent, .manualUpload)
        XCTAssertNil(fixture.queue.item(id: "already-uploaded"))
        XCTAssertEqual(fixture.queue.items.filter { $0.id != "selected" }, unrelated)
        XCTAssertEqual(fixture.metadataLookups, ["selected"])
    }

    func testRetryWithAutomaticBackupOffRunsOnlyItsTargetAndRetainsNetworkRestrictions() async throws {
        let fixture = try fixture()
        fixture.photos = ["retry": photo("retry"), "other": photo("other")]
        try fixture.queue.enqueue(["retry", "other"], now: timestamp)
        try fixture.queue.markFailed("retry", error: "Retry me", now: timestamp)
        try fixture.queue.markFailed("other", error: "Leave me failed", now: timestamp)
        let other = fixture.queue.item(id: "other")

        try fixture.requests.retry("retry")
        try await fixture.process()

        XCTAssertTrue(fixture.prepared.isEmpty)
        XCTAssertEqual(fixture.queue.item(id: "retry")?.intent, .retry)
        XCTAssertEqual(fixture.queue.item(id: "retry")?.state, .waitingForNetwork)
        XCTAssertTrue(fixture.queue.hasPendingUserRequests)
        XCTAssertEqual(fixture.queue.item(id: "other"), other)

        fixture.policy = policy(photos: true)
        let released = try await fixture.releaseWaits()
        XCTAssertTrue(released.isEmpty, "Queued work has no existing URLSession task to upgrade")
        XCTAssertEqual(fixture.queue.item(id: "retry")?.state, .queued)
        try await fixture.process()

        XCTAssertEqual(fixture.prepared.map(\.id), ["retry"])
        XCTAssertEqual(fixture.prepared.first?.allowsCellular, true)
        XCTAssertEqual(fixture.queue.item(id: "other"), other)
    }

    func testRetryAllWithAutomaticBackupOffLeavesUnrequestedQueuedWorkAlone() async throws {
        let fixture = try fixture()
        fixture.policy = policy(expensive: false)
        fixture.photos = ["one": photo("one"), "two": photo("two"), "automatic": photo("automatic")]
        try fixture.queue.enqueue(["automatic", "one", "two"], now: timestamp)
        try fixture.queue.markFailed("one", error: "First failure", now: timestamp)
        try fixture.queue.markFailed("two", error: "Second failure", now: timestamp)
        let automatic = fixture.queue.item(id: "automatic")

        try fixture.requests.retryFailed()
        try await fixture.process()

        XCTAssertEqual(Set(fixture.prepared.map(\.id)), ["one", "two"])
        XCTAssertTrue(fixture.prepared.allSatisfy { !$0.allowsCellular && $0.mayReadFromICloud })
        XCTAssertEqual(fixture.queue.item(id: "automatic"), automatic)
    }

    func testManualLivePhotoGrantSurvivesReopenAndThePrimaryPhase() async throws {
        let fixture = try fixture()
        fixture.photos = ["live": photo("live", live: true)]
        try fixture.requests.requestUploads(["live"], uploadedIDs: [])
        try await fixture.process()
        XCTAssertEqual(fixture.prepared.map(\.id), ["live"])
        let motion = try XCTUnwrap(fixture.prepared.first)
        XCTAssertTrue(motion.allowsCellular)
        XCTAssertTrue(motion.mayReadFromICloud)

        // The motion transfer has finished; its still image may be prepared in
        // a later process, using the relationship saved in the actual ledger.
        try fixture.queue.markPreparing("live", phase: .primaryAsset, motionAssetID: "server-motion", now: timestamp)
        try fixture.queue.markRetry("live", state: .waitingForNetwork, error: "Connection changed",
            retryAt: .distantFuture, now: timestamp)
        fixture.reopen()
        fixture.prepared.removeAll()
        XCTAssertEqual(fixture.queue.item(id: "live")?.intent, .manualUpload)
        XCTAssertEqual(fixture.queue.item(id: "live")?.motionAssetID, "server-motion")
        XCTAssertEqual(fixture.queue.item(id: "live")?.phase, .primaryAsset)

        let released = try await fixture.releaseWaits()
        XCTAssertTrue(released.isEmpty)
        XCTAssertEqual(fixture.queue.item(id: "live")?.state, .queued)
        try await fixture.process()

        XCTAssertEqual(fixture.prepared.map(\.id), ["live"])
        let primary = try XCTUnwrap(fixture.prepared.first)
        XCTAssertTrue(primary.allowsCellular)
        XCTAssertTrue(primary.mayReadFromICloud)
        XCTAssertEqual(fixture.queue.item(id: "live")?.motionAssetID, "server-motion")
        XCTAssertEqual(fixture.queue.item(id: "live")?.attemptCount, 2)
    }

    func testManualCellularGrantDoesNotBypassAnOfflineConnection() async throws {
        let fixture = try fixture()
        fixture.photos = ["manual": photo("manual")]
        fixture.policy = policy(online: false)
        try fixture.requests.requestUploads(["manual"], uploadedIDs: [])

        try await fixture.process()

        XCTAssertTrue(fixture.prepared.isEmpty)
        XCTAssertEqual(fixture.queue.item(id: "manual")?.state, .waitingForNetwork)
        let waiting = fixture.queue.item(id: "manual")
        let offlineRelease = try await fixture.releaseWaits()
        XCTAssertTrue(offlineRelease.isEmpty)
        XCTAssertEqual(fixture.queue.item(id: "manual"), waiting)
        fixture.policy = policy()
        _ = try await fixture.releaseWaits()
        try await fixture.process()
        XCTAssertEqual(fixture.prepared.map(\.id), ["manual"])
    }

    func testAutomaticPhotosVideoAndLivePhotosRetainTheirCategoryPermissions() async throws {
        for kind in ["photo", "video", "live"] {
            let fixture = try fixture()
            fixture.automaticEnabled = true
            fixture.photos[kind] = photo(kind, video: kind == "video", live: kind == "live")
            try fixture.queue.enqueue([kind], now: timestamp)
            fixture.policy = policy(photos: true)

            try await fixture.process()

            if kind == "photo" {
                XCTAssertEqual(fixture.prepared.map(\.id), [kind])
            } else {
                XCTAssertTrue(fixture.prepared.isEmpty)
                XCTAssertEqual(fixture.queue.item(id: kind)?.state, .waitingForNetwork)
                fixture.policy = policy(photos: kind == "live", videos: true)
                _ = try await fixture.releaseWaits()
                try await fixture.process()
                XCTAssertEqual(fixture.prepared.map(\.id), [kind])
            }
            let prepared = try XCTUnwrap(fixture.prepared.first)
            XCTAssertTrue(prepared.allowsCellular)
            XCTAssertTrue(prepared.mayReadFromICloud)
            XCTAssertNil(fixture.queue.item(id: kind)?.intent)
        }
    }

    func testCellularChangesReleaseOnlyCompatibleWaitsAndActiveTransfers() async throws {
        let fixture = try fixture()
        fixture.automaticEnabled = true
        fixture.photos = ["photo": photo("photo"), "video": photo("video", video: true),
            "live": photo("live", live: true), "active": photo("active", video: true),
            "canceling": photo("canceling", video: true)]
        try fixture.queue.enqueue(["photo", "video", "live", "missing", "active", "canceling"], now: timestamp)
        for id in ["photo", "video", "live", "missing"] {
            try fixture.queue.markRetry(id, state: .waitingForNetwork, error: "Waiting for Wi-Fi",
                retryAt: .distantFuture, now: timestamp)
        }
        try makeUploading("active", queue: fixture.queue, task: 50)
        try makeUploading("canceling", queue: fixture.queue, task: 51)
        try fixture.queue.markCancelling("canceling", now: timestamp)
        let blocked = Dictionary(uniqueKeysWithValues: fixture.queue.items
            .filter { $0.id != "photo" }.map { ($0.id, $0) })
        fixture.policy = policy(photos: true)

        let photosReleased = try await fixture.releaseWaits()

        XCTAssertTrue(photosReleased.isEmpty)
        XCTAssertEqual(fixture.queue.item(id: "photo")?.state, .queued)
        for (id, item) in blocked { XCTAssertEqual(fixture.queue.item(id: id), item) }
        fixture.policy = policy(videos: true)
        let videosReleased = try await fixture.releaseWaits()
        XCTAssertEqual(videosReleased, ["active"])
        XCTAssertEqual(fixture.queue.item(id: "video")?.state, .queued)
        XCTAssertEqual(fixture.queue.item(id: "live")?.state, .waitingForNetwork)
        XCTAssertEqual(fixture.queue.item(id: "canceling")?.state, .cancelling)

        fixture.policy = policy(photos: true, videos: true)
        let liveReleased = try await fixture.releaseWaits()
        XCTAssertEqual(liveReleased, ["active"])
        XCTAssertEqual(fixture.queue.item(id: "live")?.state, .queued)
        XCTAssertEqual(fixture.queue.item(id: "missing")?.state, .waitingForNetwork)
    }

    func testWakeWithAutomaticBackupOffCannotReleaseAnAutomaticWait() async throws {
        let fixture = try fixture()
        fixture.photos = ["automatic": photo("automatic"), "manual": photo("manual")]
        try fixture.queue.enqueue(["automatic"], now: timestamp)
        try fixture.queue.markRetry("automatic", state: .waitingForNetwork, error: "Automatic wait",
            retryAt: .distantFuture, now: timestamp)
        let automatic = fixture.queue.item(id: "automatic")
        try fixture.requests.requestUploads(["manual"], uploadedIDs: [])
        try fixture.queue.markRetry("manual", state: .waitingForNetwork, error: "Manual wait",
            retryAt: .distantFuture, now: timestamp)

        let released = try await fixture.releaseWaits()
        XCTAssertTrue(released.isEmpty)
        XCTAssertEqual(fixture.queue.item(id: "manual")?.state, .queued)
        try await fixture.process()

        XCTAssertEqual(fixture.prepared.map(\.id), ["manual"])
        XCTAssertEqual(fixture.queue.item(id: "manual")?.state, .uploading)
        XCTAssertEqual(fixture.queue.item(id: "automatic"), automatic)
    }

    func testWiFiWakeReleasesWaitsWithoutRestartingAnActiveTransfer() async throws {
        let fixture = try fixture()
        fixture.automaticEnabled = true
        fixture.policy = policy(expensive: false, photos: true)
        fixture.photos = ["active": photo("active"), "waiting": photo("waiting")]
        try fixture.queue.enqueue(["active", "waiting"], now: timestamp)
        try makeUploading("active", queue: fixture.queue, task: 90)
        try fixture.queue.markRetry("waiting", state: .waitingForNetwork, error: "Waiting for a connection",
            retryAt: .distantFuture, now: timestamp)
        let active = fixture.queue.item(id: "active")

        let upgradesOnWiFi = try await fixture.releaseWaits()

        XCTAssertTrue(upgradesOnWiFi.isEmpty)
        XCTAssertEqual(fixture.queue.item(id: "active"), active)
        XCTAssertEqual(fixture.queue.item(id: "waiting")?.state, .queued)
        fixture.policy = policy(photos: true)
        let upgradesOnCellular = try await fixture.releaseWaits()
        XCTAssertEqual(upgradesOnCellular, ["active"], "The same transfer may need recreation only after moving to a restricted path")
    }

    func testRequestedWorkBehindMoreThanOneHundredAutomaticItemsIsSelectedBeforeTheLimit() async throws {
        let fixture = try fixture()
        let automaticIDs = (0..<150).map { "automatic-\($0)" }
        try fixture.queue.enqueue(automaticIDs, now: timestamp)
        fixture.photos["manual"] = photo("manual")
        try fixture.requests.requestUploads(["manual"], uploadedIDs: [])

        XCTAssertEqual(fixture.requests.readyItems(automaticEnabled: false, limit: 1).map(\.id), ["manual"])
        try await fixture.process()

        XCTAssertEqual(fixture.prepared.map(\.id), ["manual"])
        XCTAssertEqual(fixture.metadataLookups, ["manual"])
        XCTAssertEqual(fixture.queue.snapshot.queued, automaticIDs.count)
    }

    func testManualUploadTakesTheNextFreeSlotAheadOfALargeAutomaticBacklog() async throws {
        let fixture = try fixture()
        fixture.automaticEnabled = true
        fixture.policy = policy(expensive: false)
        let automaticIDs = (0..<150).map { "automatic-\($0)" }
        fixture.photos = Dictionary(uniqueKeysWithValues: automaticIDs.map { ($0, photo($0)) })
        fixture.photos["manual"] = photo("manual")
        try fixture.queue.enqueue(automaticIDs, now: timestamp)
        try fixture.requests.requestUploads(["manual"], uploadedIDs: [])

        XCTAssertEqual(fixture.requests.readyItems(automaticEnabled: true, limit: 1).map(\.id), ["manual"])
        try await fixture.process()

        XCTAssertEqual(fixture.prepared.first?.id, "manual")
        XCTAssertEqual(fixture.prepared.count, BackupStagingPolicy.maximumActiveUploads)
        XCTAssertEqual(fixture.prepared.first?.allowsCellular, true)
        XCTAssertTrue(fixture.prepared.dropFirst().allSatisfy { !$0.allowsCellular })
        XCTAssertEqual(fixture.queue.item(id: "manual")?.state, .uploading)
        XCTAssertEqual(fixture.queue.snapshot.queued, 148)
    }

    func testManualRetryWakeIgnoresAnEarlierUnrelatedAutomaticDeadline() throws {
        let fixture = try fixture()
        let automaticDeadline = timestamp.addingTimeInterval(60)
        let requestedDeadline = timestamp.addingTimeInterval(600)
        try fixture.queue.enqueue(["automatic"], now: timestamp)
        try fixture.queue.markRetry("automatic", state: .retryScheduled, error: "Automatic backoff",
            retryAt: automaticDeadline, now: timestamp)
        try fixture.requests.requestUploads(["manual"], uploadedIDs: [])
        try fixture.queue.markRetry("manual", state: .waitingForICloud, error: "Original is downloading",
            retryAt: requestedDeadline, now: timestamp)
        fixture.reopen()

        XCTAssertEqual(fixture.requests.retryWakeDelay(automaticEnabled: false, now: timestamp), 600)
        XCTAssertEqual(fixture.requests.retryWakeDelay(automaticEnabled: true, now: timestamp), 60)
        XCTAssertTrue(fixture.queue.hasPendingUserRequests)
        try fixture.queue.markCompleted("manual")
        XCTAssertNil(fixture.requests.retryWakeDelay(automaticEnabled: false, now: timestamp))
        XCTAssertFalse(fixture.queue.hasPendingUserRequests)
        XCTAssertEqual(fixture.requests.retryWakeDelay(automaticEnabled: true, now: timestamp), 60)
    }

    func testRetryWakePreservesAShortFutureDeadlineAndBoundsAnOverdueWait() throws {
        let fixture = try fixture()
        try fixture.requests.requestUploads(["manual"], uploadedIDs: [])
        let deadline = timestamp.addingTimeInterval(10)
        try fixture.queue.markRetry("manual", state: .waitingForICloud, error: "Original is downloading",
            retryAt: deadline, now: timestamp)

        XCTAssertEqual(fixture.requests.retryWakeDelay(automaticEnabled: false, now: timestamp), 10)
        XCTAssertEqual(fixture.requests.retryWakeDelay(automaticEnabled: false, now: deadline), 30)
        XCTAssertEqual(fixture.requests.retryWakeDelay(automaticEnabled: false, now: deadline.addingTimeInterval(60)), 30)
        XCTAssertEqual(fixture.queue.item(id: "manual")?.nextAttemptAt, deadline,
            "The wake delay must not rewrite the resource's retry deadline")
    }

    func testOverdueRetryWithAFullStagingWindowHasABoundedWakeAndRefillsWhenASlotFrees() async throws {
        let fixture = try fixture()
        let ids = ["active-one", "active-two", "active-three", "retry"]
        fixture.photos = Dictionary(uniqueKeysWithValues: ids.map { ($0, photo($0)) })
        try fixture.requests.requestUploads(ids, uploadedIDs: [])
        for (index, id) in ids.prefix(3).enumerated() { try makeUploading(id, queue: fixture.queue, task: index + 1) }
        try fixture.queue.markRetry("retry", state: .retryScheduled, error: "Temporary server error",
            retryAt: timestamp, now: timestamp)
        let waiting = fixture.queue.item(id: "retry")

        for elapsed: TimeInterval in [0, 30, 60] {
            try await fixture.process()
            XCTAssertEqual(fixture.requests.retryWakeDelay(automaticEnabled: false, now: timestamp.addingTimeInterval(elapsed)), 30)
            XCTAssertEqual(fixture.queue.item(id: "retry"), waiting)
        }
        XCTAssertTrue(fixture.prepared.isEmpty)

        try fixture.queue.markCompleted("active-one")
        try await fixture.process()
        XCTAssertEqual(fixture.prepared.map(\.id), ["retry"])
        XCTAssertNil(fixture.requests.retryWakeDelay(automaticEnabled: false, now: timestamp))
        XCTAssertEqual(fixture.queue.snapshot.active, BackupStagingPolicy.maximumActiveUploads)
    }

    func testOverdueWaitDoesNotDelayAnotherRequestsUpcomingDeadline() throws {
        let fixture = try fixture()
        try fixture.requests.requestUploads(["overdue", "upcoming"], uploadedIDs: [])
        try fixture.queue.markRetry("overdue", state: .retryScheduled, error: "Earlier failure",
            retryAt: timestamp.addingTimeInterval(-60), now: timestamp)
        try fixture.queue.markRetry("upcoming", state: .waitingForICloud, error: "Original is downloading",
            retryAt: timestamp.addingTimeInterval(10), now: timestamp)

        XCTAssertEqual(fixture.requests.retryWakeDelay(automaticEnabled: false, now: timestamp), 10)
        XCTAssertEqual(fixture.requests.retryWakeDelay(automaticEnabled: false, now: timestamp.addingTimeInterval(10)), 30)
        try fixture.queue.markCompleted("upcoming")
        XCTAssertEqual(fixture.requests.retryWakeDelay(automaticEnabled: false, now: timestamp), 30)
    }

    func testRequestArrivingDuringPreparationRemainsQueuedForTheNextPass() async throws {
        let fixture = try fixture()
        fixture.photos = ["first": photo("first"), "next": photo("next")]
        try fixture.requests.requestUploads(["first"], uploadedIDs: [])
        let held = HeldMetadata()
        let pass = Task { try await fixture.process(metadata: { _ in await held.value() }) }
        await fulfillment(of: [held.started], timeout: 2)
        try fixture.requests.requestUploads(["next", "first"], uploadedIDs: [])
        held.resolve(photo("first"))
        try await pass.value

        XCTAssertEqual(fixture.prepared.map(\.id), ["first"])
        XCTAssertEqual(fixture.queue.item(id: "next")?.state, .queued)
        XCTAssertEqual(fixture.queue.item(id: "first")?.attemptCount, 1)
        try await fixture.process()
        XCTAssertEqual(fixture.prepared.map(\.id), ["first", "next"])
    }

    func testAutomaticSnapshotYieldsToAManualRequestArrivingDuringAnAwait() async throws {
        for metadataLookup in [false, true] {
            let fixture = try fixture()
            fixture.automaticEnabled = true
            fixture.policy = policy(expensive: false)
            fixture.photos = ["automatic": photo("automatic"), "manual": photo("manual")]
            try fixture.queue.enqueue(["automatic"], now: timestamp)
            let metadata = HeldMetadata()
            let staging = HeldStaging(expectedCalls: 1)
            let pass = Task {
                if metadataLookup {
                    try await fixture.process(metadata: { _ in await metadata.value() })
                } else {
                    try await fixture.process(staging: { await staging.value() })
                }
            }
            await fulfillment(of: [metadataLookup ? metadata.started : staging.started], timeout: 2)
            try fixture.requests.requestUploads(["manual"], uploadedIDs: [])
            if metadataLookup { metadata.resolve(photo("automatic")) }
            else { staging.resolve(0) }
            try await pass.value

            XCTAssertTrue(fixture.prepared.isEmpty, "The old automatic snapshot must yield before using the next free slot")
            XCTAssertEqual(fixture.queue.item(id: "automatic")?.state, .queued)
            XCTAssertEqual(fixture.queue.item(id: "manual")?.state, .queued)
            try await fixture.process()
            XCTAssertEqual(fixture.prepared.map(\.id), ["manual", "automatic"])
        }
    }

    func testConcurrentPassesRecheckOwnershipAfterAwaitingStaging() async throws {
        let fixture = try fixture()
        fixture.photos["manual"] = photo("manual")
        try fixture.requests.requestUploads(["manual"], uploadedIDs: [])
        let gates = HeldStaging()
        let first = Task { try await fixture.process(staging: { await gates.value() }) }
        let second = Task { try await fixture.process(staging: { await gates.value() }) }
        await fulfillment(of: [gates.started], timeout: 2)
        gates.resolve(0)
        gates.resolve(1)
        try await first.value
        try await second.value

        XCTAssertEqual(fixture.prepared.map(\.id), ["manual"])
        XCTAssertEqual(fixture.queue.item(id: "manual")?.attemptCount, 1)
    }

    func testPermissionChangesDuringMetadataLookupPreventPreparation() async throws {
        for authentication in [true, false] {
            let fixture = try fixture()
            fixture.photos["manual"] = photo("manual")
            try fixture.requests.requestUploads(["manual"], uploadedIDs: [])
            let held = HeldMetadata()
            let pass = Task { try await fixture.process(metadata: { _ in await held.value() }) }
            await fulfillment(of: [held.started], timeout: 2)
            if authentication { fixture.authenticated = false }
            else { fixture.storageAvailable = false }
            held.resolve(photo("manual"))
            try await pass.value

            XCTAssertTrue(fixture.prepared.isEmpty)
            XCTAssertEqual(fixture.queue.item(id: "manual")?.state, .queued)
            fixture.authenticated = true
            fixture.storageAvailable = true
            try await fixture.process()
            XCTAssertEqual(fixture.prepared.map(\.id), ["manual"])
        }
    }

    func testCanceledLookupCannotDiscardAQueuedUserRequest() async throws {
        let fixture = try fixture()
        fixture.photos["manual"] = photo("manual")
        try fixture.requests.requestUploads(["manual"], uploadedIDs: [])
        let held = HeldMetadata()
        let pass = Task { try await fixture.process(metadata: { _ in await held.value() }) }
        await fulfillment(of: [held.started], timeout: 2)
        pass.cancel()
        held.resolve(nil)
        try await pass.value

        XCTAssertTrue(fixture.unavailableIDs.isEmpty)
        XCTAssertTrue(fixture.prepared.isEmpty)
        XCTAssertEqual(fixture.queue.item(id: "manual")?.state, .queued)
        try await fixture.process()
        XCTAssertEqual(fixture.prepared.map(\.id), ["manual"])
    }

    func testMissingMetadataCannotDiscardWorkClaimedOrCompletedDuringLookup() async throws {
        for completed in [false, true] {
            let fixture = try fixture()
            try fixture.requests.requestUploads(["manual"], uploadedIDs: [])
            let held = HeldMetadata()
            let pass = Task { try await fixture.process(metadata: { _ in await held.value() }) }
            await fulfillment(of: [held.started], timeout: 2)
            if completed { try fixture.queue.markCompleted("manual") }
            else { try makeUploading("manual", queue: fixture.queue, task: 88) }
            held.resolve(nil)
            try await pass.value

            XCTAssertTrue(fixture.unavailableIDs.isEmpty)
            XCTAssertTrue(fixture.prepared.isEmpty)
            if completed {
                XCTAssertEqual(fixture.queue.snapshot.completed, 1)
                XCTAssertNil(fixture.queue.item(id: "manual"))
            } else {
                XCTAssertEqual(fixture.queue.item(id: "manual")?.state, .uploading)
                XCTAssertEqual(fixture.queue.item(id: "manual")?.taskIdentifier, 88)
            }
        }
        let missing = try fixture()
        try missing.requests.requestUploads(["missing"], uploadedIDs: [])
        try await missing.process()
        XCTAssertEqual(missing.unavailableIDs, ["missing"])
        XCTAssertTrue(missing.queue.items.isEmpty, "An unchanged missing source must still reach the unavailable handler")
    }

    func testCanceledActiveTaskIsNotUpgradedAfterAHeldNetworkWakeLookup() async throws {
        let fixture = try fixture()
        fixture.photos["manual"] = photo("manual")
        try fixture.requests.requestUploads(["manual"], uploadedIDs: [])
        try makeUploading("manual", queue: fixture.queue, task: 77)
        let held = HeldMetadata()
        let wake = Task {
            try await fixture.requests.releaseNetworkWaits(automaticEnabled: false, policy: fixture.policy,
                metadata: { _ in await held.value() })
        }
        await fulfillment(of: [held.started], timeout: 2)
        try fixture.queue.markCancelling("manual", now: timestamp)
        held.resolve(photo("manual"))
        let upgrades = try await wake.value

        XCTAssertTrue(upgrades.isEmpty)
        XCTAssertEqual(fixture.queue.item(id: "manual")?.state, .cancelling)
        XCTAssertEqual(fixture.queue.item(id: "manual")?.taskIdentifier, 77)
    }

    func testCanceledNetworkWakeCannotReleaseOrUpgradeWorkAfterMetadataReturns() async throws {
        for active in [false, true] {
            let fixture = try fixture()
            try fixture.requests.requestUploads(["manual"], uploadedIDs: [])
            if active { try makeUploading("manual", queue: fixture.queue, task: 77) }
            else {
                try fixture.queue.markRetry("manual", state: .waitingForNetwork, error: "Waiting for Wi-Fi",
                    retryAt: .distantFuture, now: timestamp)
            }
            let before = fixture.queue.item(id: "manual")
            let held = HeldMetadata()
            let wake = Task {
                try await fixture.requests.releaseNetworkWaits(automaticEnabled: false, policy: fixture.policy,
                    metadata: { _ in await held.value() })
            }
            await fulfillment(of: [held.started], timeout: 2)
            wake.cancel()
            held.resolve(photo("manual"))

            let upgraded = try await wake.value
            XCTAssertTrue(upgraded.isEmpty)
            XCTAssertEqual(fixture.queue.item(id: "manual"), before)
        }
    }

    func testAuthenticationWaitsPreserveManualIntentUntilSignInReleasesThem() async throws {
        let fixture = try fixture()
        fixture.photos = ["manual": photo("manual"), "automatic": photo("automatic")]
        try fixture.queue.enqueue(["automatic"], now: timestamp)
        try fixture.requests.requestUploads(["manual"], uploadedIDs: [])
        try fixture.queue.markAllWaitingForAuthentication(error: "Sign in required", now: timestamp)
        fixture.reopen()

        try await fixture.process()
        XCTAssertTrue(fixture.prepared.isEmpty)
        XCTAssertTrue(fixture.queue.hasPendingUserRequests)
        XCTAssertEqual(fixture.queue.item(id: "manual")?.intent, .manualUpload)
        try fixture.queue.releaseAuthenticationWaits(now: timestamp)
        try await fixture.process()
        XCTAssertEqual(fixture.prepared.map(\.id), ["manual"])
        XCTAssertEqual(fixture.queue.item(id: "automatic")?.state, .queued)
    }

    func testPersistentAdmissionFailureCannotGrantCellularOrStartPreparation() async throws {
        let fixture = try fixture()
        fixture.photos["manual"] = photo("manual")
        try FileManager.default.createDirectory(at: fixture.queueURL, withIntermediateDirectories: true)

        XCTAssertThrowsError(try fixture.requests.requestUploads(["manual"], uploadedIDs: []))
        try await fixture.process()

        XCTAssertTrue(fixture.queue.items.isEmpty)
        XCTAssertFalse(fixture.queue.hasPendingUserRequests)
        XCTAssertTrue(fixture.prepared.isEmpty)
        XCTAssertTrue(fixture.metadataLookups.isEmpty)
        try FileManager.default.removeItem(at: fixture.queueURL)
        try fixture.requests.requestUploads(["manual"], uploadedIDs: [])
        try await fixture.process()
        XCTAssertEqual(fixture.prepared.map(\.id), ["manual"])
    }

    func testFailedNetworkWaitWritePropagatesInsteadOfLeavingUnreportedWork() async throws {
        let fixture = try fixture()
        fixture.photos["retry"] = photo("retry")
        try fixture.queue.enqueue(["retry"], now: timestamp)
        try fixture.queue.markFailed("retry", error: "Retry me", now: timestamp)
        try fixture.requests.retry("retry")
        try FileManager.default.removeItem(at: fixture.queueURL)
        try FileManager.default.createDirectory(at: fixture.queueURL, withIntermediateDirectories: true)

        do {
            try await fixture.process()
            XCTFail("A network-wait persistence error must reach the service's error path")
        } catch {
            XCTAssertTrue(error is BackupQueueStoreError)
        }

        XCTAssertTrue(fixture.prepared.isEmpty)
    }

    func testAFullStagingWindowPausesManualPreparationAndResumesWhenOneSlotFrees() async throws {
        let fixture = try fixture()
        let ids = ["active-one", "active-two", "active-three", "next"]
        fixture.photos = Dictionary(uniqueKeysWithValues: ids.map { ($0, photo($0)) })
        try fixture.requests.requestUploads(ids, uploadedIDs: [])
        for (index, id) in ids.prefix(3).enumerated() { try makeUploading(id, queue: fixture.queue, task: index + 1) }

        try await fixture.process()
        XCTAssertTrue(fixture.prepared.isEmpty)
        XCTAssertEqual(fixture.queue.item(id: "next")?.state, .queued)
        try fixture.queue.markCompleted("active-one")
        try await fixture.process()
        XCTAssertEqual(fixture.prepared.map(\.id), ["next"])
        XCTAssertEqual(fixture.queue.snapshot.active, BackupStagingPolicy.maximumActiveUploads)
    }

    private var timestamp: Date { Date(timeIntervalSince1970: 1_700_000_000) }

    private func photo(_ id: String, video: Bool = false, live: Bool = false) -> LocalPhoto {
        LocalPhoto(id: id, createdAt: timestamp, modifiedAt: timestamp, isVideo: video,
            isLivePhoto: live, duration: video ? 10 : nil, ratio: 1)
    }

    private func policy(online: Bool = true, expensive: Bool = true, photos: Bool = false, videos: Bool = false) -> BackupNetworkPolicy {
        BackupNetworkPolicy(isOnline: online, isExpensive: expensive, cellularPhotos: photos, cellularVideos: videos)
    }

    private func makeUploading(_ id: String, queue: BackupQueueStore, task: Int) throws {
        try queue.markPreparing(id, phase: .primaryAsset, now: timestamp)
        try queue.markUploading(id, phase: .primaryAsset, checksum: "checksum-\(id)", taskIdentifier: task, now: timestamp)
    }

    private func fixture() throws -> Fixture {
        let value = try Fixture()
        directories.append(value.directory)
        return value
    }
}

@MainActor
private final class Fixture {
    struct Preparation {
        let id: String
        let allowsCellular: Bool
        let mayReadFromICloud: Bool
    }

    let directory: URL
    let queueURL: URL
    private(set) var queue: BackupQueueStore
    private(set) var requests: BackupUploadRequests
    var automaticEnabled = false
    var authenticated = true
    var storageAvailable = true
    var policy = BackupNetworkPolicy(isOnline: true, isExpensive: true, cellularPhotos: false, cellularVideos: false)
    var photos: [String: LocalPhoto] = [:]
    var prepared: [Preparation] = []
    private(set) var metadataLookups: [String] = []
    private(set) var unavailableIDs: [String] = []
    private var taskIdentifier = 1000

    init() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("manual-request-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        queueURL = directory.appendingPathComponent("queue.json")
        let queue = BackupQueueStore(fileURL: queueURL)
        self.queue = queue
        requests = BackupUploadRequests(queue: queue)
    }

    func reopen() {
        queue = BackupQueueStore(fileURL: queueURL)
        requests = BackupUploadRequests(queue: queue)
    }

    func process(
        metadata: (@MainActor (String) async -> LocalPhoto?)? = nil,
        staging: (@MainActor () async -> (activeTasks: Int, bytes: Int))? = nil
    ) async throws {
        try await requests.process(automaticEnabled: { self.automaticEnabled }, policy: { self.policy },
            canProcess: { self.authenticated && self.storageAvailable },
            metadata: metadata ?? { id in
                self.metadataLookups.append(id)
                return self.photos[id]
            },
            staging: staging ?? { (self.queue.snapshot.active, 0) },
            unavailable: { id in
                self.unavailableIDs.append(id)
                try? self.queue.discard(id)
            },
            prepare: { photo, cloud in self.prepare(photo, cloud: cloud) },
            didChange: {})
    }

    func releaseWaits() async throws -> Set<String> {
        try await requests.releaseNetworkWaits(automaticEnabled: automaticEnabled, policy: policy, metadata: { self.photos[$0] })
    }

    /// Only the resource handoff is simulated. Admission, retry scoping,
    /// network decisions, staging checks and ledger persistence are production code.
    private func prepare(_ photo: LocalPhoto, cloud: Bool) {
        do {
            let motionID = queue.item(id: photo.id)?.motionAssetID
            let phase: BackupUploadPhase = photo.isLivePhoto && motionID == nil ? .livePhotoMotion : .primaryAsset
            try queue.markPreparing(photo.id, phase: phase, motionAssetID: motionID)
            taskIdentifier += 1
            try queue.markUploading(photo.id, phase: phase, checksum: "checksum-\(photo.id)", taskIdentifier: taskIdentifier)
            prepared.append(Preparation(id: photo.id,
                allowsCellular: requests.allowsCellular(for: photo, policy: policy), mayReadFromICloud: cloud))
        } catch {
            XCTFail("The resource boundary could not claim its selected item: \(error)")
        }
    }
}

@MainActor
private final class HeldMetadata {
    let started = XCTestExpectation(description: "The production request processor is awaiting metadata")
    private var continuation: CheckedContinuation<LocalPhoto?, Never>?

    func value() async -> LocalPhoto? {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            started.fulfill()
        }
    }

    func resolve(_ photo: LocalPhoto?, file: StaticString = #filePath, line: UInt = #line) {
        guard let continuation else {
            return XCTFail("The metadata request did not reach its held boundary", file: file, line: line)
        }
        self.continuation = nil
        continuation.resume(returning: photo)
    }
}

@MainActor
private final class HeldStaging {
    let started: XCTestExpectation
    private var continuations: [CheckedContinuation<(activeTasks: Int, bytes: Int), Never>] = []

    init(expectedCalls: Int = 2) {
        started = XCTestExpectation(description: "The production processor is awaiting the staging boundary")
        started.expectedFulfillmentCount = expectedCalls
    }

    func value() async -> (activeTasks: Int, bytes: Int) {
        await withCheckedContinuation { continuation in
            continuations.append(continuation)
            started.fulfill()
        }
    }

    func resolve(_ index: Int, file: StaticString = #filePath, line: UInt = #line) {
        guard continuations.indices.contains(index) else {
            return XCTFail("The staging request did not reach its held boundary", file: file, line: line)
        }
        continuations[index].resume(returning: (0, 0))
    }
}
