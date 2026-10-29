import Observation
import XCTest
@testable import ImmichApp

@MainActor
final class AssetViewerStateTests: XCTestCase {
    func testRemovalCompletesForItsOriginalPageAfterSwiping() async throws {
        let state = viewer([asset("A"), asset("B"), asset("C")])
        let target = state.target(serverID: "A", detail: nil)
        let held = HeldViewerResult<Bool>()
        var removed: [String] = []
        let task = try XCTUnwrap(state.remove(target, operation: { await held.value() }) { _ in
            removed.append(target.asset.id)
        })
        await fulfillment(of: [held.started], timeout: 2)
        state.select("B")
        held.resolve(true)
        await task.value

        XCTAssertEqual(state.pages.map(\.id), ["B", "C"])
        XCTAssertEqual(state.currentAsset.id, "B")
        XCTAssertEqual(state.currentIndex, 0)
        XCTAssertEqual(removed, ["A"])
        XCTAssertFalse(state.select("A"), "An old pager callback cannot resurrect a removed page")
    }

    func testRemovingCurrentPagesAdvancesThenClosesWithoutRestoringOriginalPages() async throws {
        let state = viewer([asset("A"), asset("B"), asset("C")])
        state.select("B")
        XCTAssertTrue(state.removePage("B"))
        XCTAssertEqual(state.currentAsset.id, "C")
        XCTAssertTrue(state.removePage("C"))
        XCTAssertEqual(state.currentAsset.id, "A")
        let target = state.target(serverID: "A", detail: nil)
        var closed = false
        let task = try XCTUnwrap(state.remove(target, operation: { true }) { presented in closed = presented && state.isEmpty })
        await task.value

        XCTAssertTrue(closed)
        XCTAssertTrue(state.pages.isEmpty)
        XCTAssertFalse(state.isCurrent(target))
        XCTAssertNil(state.prepare(target, kind: .share, operation: { "old-file" }, completion: { _ in
            XCTFail("A closed viewer cannot present a share sheet")
        }))
    }

    func testFailedAndDuplicateRemovalCannotRemoveAnotherPage() async throws {
        let state = viewer([asset("A"), asset("B")])
        let target = state.target(serverID: "A", detail: nil)
        let held = HeldViewerResult<Bool>()
        var completions = 0
        let task = try XCTUnwrap(state.remove(target, operation: { await held.value() }) { _ in completions += 1 })
        XCTAssertNil(state.remove(target, operation: {
            XCTFail("A repeated tap must not issue another removal")
            return true
        }, completion: { _ in }))
        await fulfillment(of: [held.started], timeout: 2)
        state.select("B")
        held.resolve(false)
        await task.value

        XCTAssertEqual(state.pages.map(\.id), ["A", "B"])
        XCTAssertEqual(state.currentAsset.id, "B")
        XCTAssertEqual(completions, 0)
        let retry = try XCTUnwrap(state.remove(target, operation: { true }) { _ in completions += 1 })
        await retry.value
        XCTAssertEqual(state.pages.map(\.id), ["B"])
        XCTAssertEqual(completions, 1)
    }

    func testRemovalAfterLeavingStillReportsItsTargetWithoutDismissingAnotherScreen() async throws {
        let state = viewer([asset("A")])
        let target = state.target(serverID: "A", detail: nil)
        let held = HeldViewerResult<Bool>()
        var removed: [String] = []
        var requestedDismissal = false
        let task = try XCTUnwrap(state.remove(target, operation: { await held.value() }) { isPresented in
            removed.append(target.asset.id)
            requestedDismissal = isPresented && state.isEmpty
        })
        await fulfillment(of: [held.started], timeout: 2)
        state.deactivate()
        held.resolve(true)
        await task.value

        XCTAssertTrue(state.isEmpty)
        XCTAssertEqual(removed, ["A"])
        XCTAssertFalse(requestedDismissal)
    }

    func testReturningToSamePageRejectsOldPreparationAndDeletesItsTemporaryFile() async throws {
        let state = viewer([asset("A"), asset("B")])
        let target = state.target(serverID: "A", detail: makeTestAsset(id: "A"))
        let held = HeldViewerResult<URL?>()
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data("prepared A".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        var presented: [URL] = []
        let task = try XCTUnwrap(state.prepare(target, kind: .share,
            operation: { await held.value() },
            discard: { try? FileManager.default.removeItem(at: $0) },
            completion: { presented.append($0) }))
        XCTAssertNil(state.prepare(target, kind: .share, operation: { file }, completion: { _ in
            XCTFail("Repeated taps must not start duplicate preparation")
        }))
        await fulfillment(of: [held.started], timeout: 2)
        state.select("B")
        state.select("A")
        XCTAssertFalse(state.isCurrent(target))
        held.resolve(file)
        await task.value

        XCTAssertTrue(presented.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
        try Data("new A".utf8).write(to: file)
        let current = state.target(serverID: "A", detail: nil)
        let fresh = try XCTUnwrap(state.prepare(current, kind: .share, operation: { file }) { presented.append($0) })
        await fresh.value
        XCTAssertEqual(presented, [file], "A preparation for the new visit must still be presented")
    }

    func testOldPreparationCannotClearTheNewVisitsProgress() async throws {
        let state = viewer([asset("A"), asset("B")])
        let old = HeldViewerResult<String?>()
        let first = try XCTUnwrap(state.prepare(state.target(serverID: "A", detail: nil), kind: .editor,
            operation: { await old.value() }, completion: { _ in XCTFail("Stale editor must not open") }))
        await fulfillment(of: [old.started], timeout: 2)
        state.select("B")
        state.select("A")
        let current = HeldViewerResult<String?>()
        var opened: [String] = []
        let second = try XCTUnwrap(state.prepare(state.target(serverID: "A", detail: nil), kind: .editor,
            operation: { await current.value() }, completion: { opened.append($0) }))
        await fulfillment(of: [current.started], timeout: 2)
        old.resolve("old")
        await first.value
        XCTAssertTrue(state.isPreparing(.editor))
        current.resolve("new")
        await second.value
        XCTAssertEqual(opened, ["new"])
        XCTAssertFalse(state.isPreparing(.editor))
    }

    func testHeldCompletionKeepsTheSameVisitsDuplicatePreparationGuard() async throws {
        let state = viewer([asset("A")])
        let target = state.target(serverID: "A", detail: nil)
        let completion = HeldViewerResult<Bool>()
        var completions = 0
        let task = try XCTUnwrap(state.prepare(target, kind: .share, operation: { "ready original" }) { value in
            XCTAssertEqual(value, "ready original")
            completions += 1
            _ = await completion.value()
        })
        await fulfillment(of: [completion.started], timeout: 2)

        XCTAssertTrue(state.isPreparing(.share))
        XCTAssertNil(state.prepare(target, kind: .share,
            operation: { XCTFail("A held completion must still reject duplicate original preparation"); return "duplicate" },
            completion: { _ in XCTFail("A duplicate activity must not be presented") }))
        XCTAssertEqual(completions, 1)
        completion.resolve(true)
        await task.value
        XCTAssertFalse(state.isPreparing(.share))
    }

    func testLeavingViewerRejectsLatePresentationEvenWhenSamePageIsVisibleAgain() async throws {
        let state = viewer([asset("A")])
        let held = HeldViewerResult<String?>()
        let target = state.target(serverID: "A", detail: nil)
        var discarded = false
        let task = try XCTUnwrap(state.prepare(target, kind: .sharedLink, operation: { await held.value() },
            discard: { _ in discarded = true }, completion: { _ in XCTFail("A dismissed viewer cannot present a link") }))
        await fulfillment(of: [held.started], timeout: 2)
        state.deactivate()
        state.activate()
        held.resolve("old link")
        await task.value
        XCTAssertTrue(discarded)
        XCTAssertFalse(state.isCurrent(target))
    }

    func testChangingPagesCancelsHeldPresentationPreparation() async throws {
        try await assertPreparationIsCancelled { XCTAssertTrue($0.select("B")) }
    }

    func testLeavingViewerCancelsHeldPresentationPreparation() async throws {
        try await assertPreparationIsCancelled { $0.deactivate() }
    }

    func testRemovingTheCurrentPageCancelsHeldPresentationPreparation() async throws {
        try await assertPreparationIsCancelled { XCTAssertTrue($0.removePage("A")) }
    }

    func testLosingLocalAccessCancelsHeldPresentationPreparation() async throws {
        try await assertPreparationIsCancelled(local: true) { state in
            XCTAssertTrue(state.refreshLocalAccess(hasReadAccess: false, existingLocalIDs: { _ in [] },
                serverIDsByLocalIdentifier: [:]))
        }
    }

    private func assertPreparationIsCancelled(
        local: Bool = false, changeVisit: (AssetViewerState) -> Void
    ) async throws {
        for kind in [AssetViewerState.Preparation.share, .editor, .sharedLink] {
            let id = local ? LocalPhotoLibrary.assetID(for: "A") : "A"
            let state = viewer([asset(id, origin: local ? .device : .server), asset("B")])
            let held = HeldViewerResult<URL?>()
            let cancellation = ViewerPreparationCancellation()
            let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try Data("late prepared original".utf8).write(to: file)
            defer { try? FileManager.default.removeItem(at: file) }
            let target = state.target(serverID: local ? nil : "A", detail: nil)
            let task = try XCTUnwrap(state.prepare(target, kind: kind,
                operation: {
                    await withTaskCancellationHandler {
                        await held.value()
                    } onCancel: {
                        cancellation.mark()
                    }
                }, discard: { try? FileManager.default.removeItem(at: $0) },
                completion: { _ in XCTFail("An obsolete viewer must not present prepared content") }))
            await fulfillment(of: [held.started], timeout: 2)

            changeVisit(state)

            XCTAssertTrue(cancellation.wasCancelled, "\(kind) must stop expensive work as soon as its visit ends")
            held.resolve(file)
            await task.value
            XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
            XCTAssertFalse(state.isPreparing(kind))
        }
    }

    func testPresentingEditorRejectsPendingShareAndRestoresPresentationsOnReturn() async throws {
        let state = viewer([asset("A")])
        let target = state.target(serverID: "A", detail: makeTestAsset(id: "A"))
        let held = HeldViewerResult<String?>()
        var presented: [String] = []
        var discarded: [String] = []
        let share = try XCTUnwrap(state.prepare(target, kind: .share,
            operation: { await held.value() }, discard: { discarded.append($0) },
            completion: { presented.append($0) }))
        await fulfillment(of: [held.started], timeout: 2)
        var editorPresented = false
        let editor = try XCTUnwrap(state.prepareEditor(target, operation: { "edits" }) { _ in
            XCTAssertFalse(Task.isCancelled, "Presenting the ready editor must not cancel its own completion")
            editorPresented = true
        })
        await editor.value
        XCTAssertTrue(editorPresented)
        held.resolve("old share")
        await share.value
        XCTAssertTrue(presented.isEmpty)
        XCTAssertEqual(discarded, ["old share"])
        XCTAssertNil(state.prepare(state.target(serverID: "A", detail: nil), kind: .sharedLink,
            operation: { "covered link" }, completion: { _ in XCTFail("The covered viewer cannot present another sheet") }))

        state.activate()
        let current = state.target(serverID: "A", detail: nil)
        XCTAssertFalse(state.isCurrent(target), "Returning from the editor starts a new presentation visit")
        let fresh = try XCTUnwrap(state.prepare(current, kind: .share, operation: { "new share" }) { presented.append($0) })
        await fresh.value
        XCTAssertEqual(presented, ["new share"])
    }

    func testDownloadChangesOnlyTheOriginalPageAndTracksItsOwnProgress() async throws {
        let state = viewer([asset("A"), asset("B")])
        let target = state.target(serverID: "A", detail: makeTestAsset(id: "A"))
        let held = HeldViewerResult<Bool>()
        let task = try XCTUnwrap(state.download(target, operation: { await held.value() }))
        XCTAssertTrue(state.isDownloading("A"))
        XCTAssertNil(state.download(target, operation: {
            XCTFail("Repeated download taps must not duplicate the save")
            return true
        }))
        await fulfillment(of: [held.started], timeout: 2)
        state.select("B")
        XCTAssertFalse(state.isDownloading("B"))
        held.resolve(true)
        await task.value

        XCTAssertEqual(state.currentAsset.origin, .server)
        XCTAssertEqual(state.pages.first { $0.id == "A" }?.origin, .both)
        XCTAssertFalse(state.isDownloading("A"))
        state.select("A")
        XCTAssertTrue(state.currentAsset.isOnDevice)
        XCTAssertFalse(state.currentAsset.needsUpload)
    }

    func testFailedDownloadDoesNotClaimThatAMappedCopyExists() async throws {
        let state = viewer([asset("A")])
        let target = state.target(serverID: "A", detail: nil)
        let task = try XCTUnwrap(state.download(target, operation: { false }))
        await task.value
        XCTAssertEqual(state.currentAsset.origin, .server)
        XCTAssertFalse(state.isDownloading("A"))
        let retry = try XCTUnwrap(state.download(target, operation: { true }))
        await retry.value
        XCTAssertEqual(state.currentAsset.origin, .both)
    }

    func testCommittedUploadMappingRefreshesTheSameDisplayIDAndPublishesOrigin() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("viewer-upload-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let manager = SwiftDataManager(storeURL: directory.appendingPathComponent("test.store"),
            backupJournalURL: directory.appendingPathComponent("backup.json"))
        let local = asset(LocalPhotoLibrary.assetID(for: "A"), origin: .device)
        let missing = asset(LocalPhotoLibrary.assetID(for: "missing"), origin: .device)
        let state = viewer([local, missing, asset("B")])
        XCTAssertTrue(state.beginUpload(local.id))
        state.finishUpload(local.id)
        state.refreshUploadedCopies(using: manager, existingLocalIDs: { Set($0) })
        XCTAssertEqual(state.currentAsset.origin, .device)
        XCTAssertTrue(state.currentAsset.needsUpload, "Enqueue completion is not evidence that the photo reached the server")
        XCTAssertTrue(state.beginUpload(local.id))
        let changed = expectation(description: "Origin observer updates actions after mapping commit")
        withObservationTracking {
            _ = state.currentAsset.origin
        } onChange: { changed.fulfill() }
        let refreshed = expectation(description: "The same refresh used by the view handles the committed mapping")
        withObservationTracking {
            _ = manager.backupMappingRevision
        } onChange: {
            MainActor.assumeIsolated {
                state.refreshUploadedCopies(using: manager, existingLocalIDs: { Set($0).subtracting(["missing"]) })
                refreshed.fulfill()
            }
        }
        try manager.upsertBackupRecord(assetID: "uploaded-server", checksum: "digest", localIdentifier: "A")
        await fulfillment(of: [changed, refreshed], timeout: 2)

        XCTAssertEqual(state.currentAsset.id, local.id)
        XCTAssertEqual(state.currentAsset.origin, .both)
        XCTAssertFalse(state.currentAsset.needsUpload)
        XCTAssertFalse(state.isUploading(local.id))
        XCTAssertEqual(manager.serverAssetIDsByLocalIdentifier()["A"], "uploaded-server")
        try manager.upsertBackupRecord(assetID: "unavailable-server", checksum: "digest2", localIdentifier: "missing")
        state.refreshUploadedCopies(using: manager, existingLocalIDs: { Set($0).subtracting(["missing"]) })
        XCTAssertEqual(state.pages.first { $0.id == missing.id }?.origin, .device,
            "A server mapping alone cannot claim that the device copy still exists")
        XCTAssertEqual(state.pages.first { $0.id == "B" }?.origin, .server)
    }

    func testTargetsRequireMatchingMetadataAndSelectedSnapshotWinsOverOldPageMetadata() {
        var current = asset("A", origin: .both)
        current.isFavorite = true
        let state = AssetViewerState(currentAsset: current, assets: [asset("A"), asset("B")])
        XCTAssertEqual(state.currentAsset.origin, .both)
        XCTAssertTrue(state.currentAsset.isFavorite)
        XCTAssertNil(state.target(serverID: "A", detail: makeTestAsset(id: "B")).detail)
        XCTAssertEqual(state.target(serverID: "A", detail: makeTestAsset(id: "A")).detail?.id, "A")
        state.setFavorite(true, for: "B")
        XCTAssertTrue(state.currentAsset.isFavorite)
        XCTAssertEqual(state.pages.first { $0.id == "B" }?.isFavorite, true)
        state.setFavorite(false, for: "A")
        XCTAssertFalse(state.currentAsset.isFavorite)
        XCTAssertEqual(state.pages.first { $0.id == "B" }?.isFavorite, true)
    }

    func testRevokedPhotosAccessRemovesLocalPagesAndKeepsServerPages() {
        let local = asset(LocalPhotoLibrary.assetID(for: "local"), origin: .device)
        let state = viewer([local, asset("server")])
        let old = state.target(serverID: nil, detail: nil)

        XCTAssertTrue(state.refreshLocalAccess(hasReadAccess: false, existingLocalIDs: { _ in
            XCTFail("Denied access must not be used to enumerate local assets")
            return ["local"]
        }, serverIDsByLocalIdentifier: [:]))

        XCTAssertEqual(state.pages.map(\.id), ["server"])
        XCTAssertEqual(state.currentAsset.id, "server")
        XCTAssertEqual(state.currentAsset.origin, .server)
        XCTAssertFalse(state.isCurrent(old))
        XCTAssertFalse(state.select(local.id))
    }

    func testLimitedSubsetChangeKeepsReadableCurrentPageAndItsActiveVisit() {
        let hidden = asset(LocalPhotoLibrary.assetID(for: "outside-subset"), origin: .device)
        let allowed = asset(LocalPhotoLibrary.assetID(for: "readable"), origin: .device)
        let state = AssetViewerState(currentAsset: allowed, assets: [hidden, allowed, asset("server")])
        let target = state.target(serverID: nil, detail: nil)

        XCTAssertTrue(state.refreshLocalAccess(hasReadAccess: true, existingLocalIDs: {
            XCTAssertEqual(Set($0), ["outside-subset", "readable"])
            return ["readable"]
        }, serverIDsByLocalIdentifier: [:]))

        XCTAssertEqual(state.pages.map(\.id), [allowed.id, "server"])
        XCTAssertEqual(state.currentAsset.id, allowed.id)
        XCTAssertEqual(state.currentIndex, 0)
        XCTAssertTrue(state.isCurrent(target), "A still-readable page must not lose its active visit")
        XCTAssertFalse(state.refreshLocalAccess(hasReadAccess: true,
            existingLocalIDs: { Set($0) }, serverIDsByLocalIdentifier: [:]))
        XCTAssertTrue(state.isCurrent(target))
    }

    func testInaccessibleMappedVideoSwitchesToItsServerSourceAndPreservesMetadata() async throws {
        let local = AssetLite(id: LocalPhotoLibrary.assetID(for: "video"), isVideo: true,
            ratio: 1.7, thumbhash: "hash", createdAt: .distantPast,
            isFavorite: true, duration: 23, livePhotoVideoID: "motion", origin: .both)
        let state = viewer([local, asset("other")])
        let old = state.target(serverID: "uploaded", detail: nil)

        XCTAssertTrue(state.refreshLocalAccess(hasReadAccess: false,
            existingLocalIDs: { _ in XCTFail("Revoked access cannot enumerate"); return [] },
            serverIDsByLocalIdentifier: ["video": "uploaded"]))

        XCTAssertEqual(state.pages.map(\.id), ["uploaded", "other"])
        let current = state.currentAsset
        XCTAssertEqual(current.origin, .server)
        XCTAssertTrue(current.isVideo)
        XCTAssertTrue(current.isFavorite)
        XCTAssertEqual(current.ratio, local.ratio)
        XCTAssertEqual(current.thumbhash, local.thumbhash)
        XCTAssertEqual(current.createdAt, local.createdAt)
        XCTAssertEqual(current.duration, local.duration)
        XCTAssertEqual(current.livePhotoVideoID, local.livePhotoVideoID)
        XCTAssertFalse(state.isCurrent(old))
        XCTAssertFalse(state.select(local.id))
        var presented = false
        let fresh = try XCTUnwrap(state.prepare(state.target(serverID: "uploaded", detail: nil), kind: .share,
            operation: { "server-file" }, completion: { _ in presented = true }))
        await fresh.value
        XCTAssertTrue(presented, "The allowed server source must remain usable")
    }

    func testMappedFallbackUsesExistingServerPageOnceAndKeepsItsCurrentMetadata() {
        let local = asset(LocalPhotoLibrary.assetID(for: "local"), origin: .both)
        var server = asset("server", origin: .both)
        server.isFavorite = true
        for pages in [[asset("other"), local, server], [asset("other"), server, local]] {
            let state = AssetViewerState(currentAsset: local, assets: pages)

            XCTAssertTrue(state.refreshLocalAccess(hasReadAccess: true, existingLocalIDs: { _ in [] },
                serverIDsByLocalIdentifier: ["local": server.id]))

            XCTAssertEqual(state.pages.map(\.id), ["other", "server"])
            XCTAssertEqual(state.currentAsset.id, "server")
            XCTAssertEqual(state.currentIndex, 1)
            XCTAssertEqual(state.currentAsset.origin, .server)
            XCTAssertTrue(state.currentAsset.isFavorite)
        }
    }

    func testRemovingSeveralInaccessiblePagesAdvancesToTheNextSurvivingPage() {
        let first = asset(LocalPhotoLibrary.assetID(for: "first"), origin: .device)
        let selected = asset(LocalPhotoLibrary.assetID(for: "selected"), origin: .device)
        let state = AssetViewerState(currentAsset: selected, assets: [first, selected, asset("next"), asset("last")])

        XCTAssertTrue(state.refreshLocalAccess(hasReadAccess: false,
            existingLocalIDs: { _ in [] }, serverIDsByLocalIdentifier: [:]))

        XCTAssertEqual(state.pages.map(\.id), ["next", "last"])
        XCTAssertEqual(state.currentAsset.id, "next")
        XCTAssertEqual(state.currentIndex, 0)
    }

    func testLosingTheOnlyLocalPageDiscardsItsHeldShareFileAndLeavesTheViewerEmpty() async throws {
        let local = asset(LocalPhotoLibrary.assetID(for: "local"), origin: .device)
        let state = viewer([local])
        let target = state.target(serverID: nil, detail: nil)
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data("local share".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let held = HeldViewerResult<URL?>()
        var presented = false
        let task = try XCTUnwrap(state.prepare(target, kind: .share,
            operation: { await held.value() },
            discard: { try? FileManager.default.removeItem(at: $0) },
            completion: { _ in presented = true }))
        await fulfillment(of: [held.started], timeout: 2)

        XCTAssertTrue(state.refreshLocalAccess(hasReadAccess: false,
            existingLocalIDs: { _ in [] }, serverIDsByLocalIdentifier: [:]))
        held.resolve(file)
        await task.value

        XCTAssertTrue(state.isEmpty, "The view dismisses when its last readable page is removed")
        XCTAssertFalse(state.isCurrent(target))
        XCTAssertFalse(presented)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
    }

    private func viewer(_ assets: [AssetLite]) -> AssetViewerState {
        AssetViewerState(currentAsset: assets[0], assets: assets)
    }

    private func asset(_ id: String, origin: AssetOrigin = .server) -> AssetLite {
        AssetLite(id: id, isVideo: false, ratio: 1, thumbhash: nil, createdAt: .distantPast, origin: origin)
    }
}

private final class ViewerPreparationCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    var wasCancelled: Bool { lock.withLock { cancelled } }
    func mark() { lock.withLock { cancelled = true } }
}

@MainActor
private final class HeldViewerResult<Value> {
    let started = XCTestExpectation(description: "Production operation is suspended")
    private var continuation: CheckedContinuation<Value, Never>?

    func value() async -> Value {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            started.fulfill()
        }
    }

    func resolve(_ value: Value) {
        precondition(continuation != nil, "Wait for the production operation to start before resolving it")
        continuation?.resume(returning: value)
        continuation = nil
    }
}
