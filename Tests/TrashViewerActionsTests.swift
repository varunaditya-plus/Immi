import XCTest
@testable import ImmichApp

@MainActor
final class TrashViewerActionsTests: XCTestCase {
    func testBothActionsUseTheirCapturedServerIDAndOnlyRemoveConfirmedPages() async throws {
        for mutation in [TrashViewerActions.Mutation.restore, .deletePermanently] {
            let state = viewer()
            let target = state.target(serverID: "server-A", detail: nil)
            var calls: [String] = []
            var presentations: [Bool] = []
            let actions = TrashViewerActions(restore: { calls.append("restore:\($0)"); return true },
                deletePermanently: { calls.append("delete:\($0)"); return true })
            let task = try XCTUnwrap(actions.perform(mutation, target: target, in: state,
                onError: { XCTFail($0) }, completion: { presentations.append($0) }))
            await task.value
            XCTAssertEqual(calls, [mutation == .restore ? "restore:server-A" : "delete:server-A"])
            XCTAssertEqual(state.pages.map(\.id), ["B"])
            XCTAssertEqual(state.currentAsset.id, "B")
            XCTAssertEqual(presentations, [true])
            XCTAssertFalse(state.isRemoving("A"))
        }
    }

    func testSwipingWhileARequestIsHeldRemovesItsOriginalPageAndKeepsTheNewSelection() async throws {
        let state = viewer()
        let gate = TrashViewerGate()
        let actions = TrashViewerActions(restore: { _ in await gate.value() }, deletePermanently: { _ in false })
        let target = state.target(serverID: "A", detail: nil)
        var removed: [String] = []
        let task = try XCTUnwrap(actions.perform(.restore, target: target, in: state,
            onError: { XCTFail($0) }, completion: { _ in removed.append(target.asset.id) }))
        addTeardownBlock { await gate.finish(true); await task.value }
        await fulfillment(of: [gate.started], timeout: 2)
        XCTAssertTrue(state.isRemoving("A"))
        XCTAssertTrue(state.select("B"))
        gate.finish(true)
        await task.value
        XCTAssertEqual(removed, ["A"])
        XCTAssertEqual(state.pages.map(\.id), ["B"])
        XCTAssertEqual(state.currentAsset.id, "B")
    }

    func testFailureKeepsThePageShowsTheCollectionsErrorAndAllowsRetry() async throws {
        let state = viewer()
        let outcome = TrashViewerOutcome()
        var errors: [String] = []
        var completions = 0
        let actions = TrashViewerActions(restore: { _ in outcome.succeeds }, deletePermanently: { _ in false },
            errorMessage: { "Restore rejected" })
        let target = state.target(serverID: "A", detail: nil)
        let first = try XCTUnwrap(actions.perform(.restore, target: target, in: state,
            onError: { errors.append($0) }, completion: { _ in completions += 1 }))
        await first.value
        XCTAssertEqual(state.pages.map(\.id), ["A", "B"])
        XCTAssertEqual(errors, ["Restore rejected"])
        XCTAssertEqual(completions, 0)
        XCTAssertFalse(state.isRemoving("A"))
        outcome.succeeds = true
        let retry = try XCTUnwrap(actions.perform(.restore, target: target, in: state,
            onError: { errors.append($0) }, completion: { _ in completions += 1 }))
        await retry.value
        XCTAssertEqual(state.pages.map(\.id), ["B"])
        XCTAssertEqual(completions, 1)
        XCTAssertEqual(errors.count, 1)
    }

    func testFailuresForAnOlderVisitDoNotAppearOverAnotherPhotoOrAReturnVisit() async throws {
        for returnsToA in [false, true] {
            let state = viewer()
            let gate = TrashViewerGate()
            var errors: [String] = []
            let actions = TrashViewerActions(restore: { _ in await gate.value() }, deletePermanently: { _ in false })
            let task = try XCTUnwrap(actions.perform(.restore, target: state.target(serverID: "A", detail: nil),
                in: state, onError: { errors.append($0) }, completion: { _ in XCTFail("The action failed") }))
            addTeardownBlock { await gate.finish(false); await task.value }
            await fulfillment(of: [gate.started], timeout: 2)
            state.select("B")
            if returnsToA { state.select("A") }
            gate.finish(false)
            await task.value
            XCTAssertTrue(errors.isEmpty)
            XCTAssertEqual(state.pages.map(\.id), ["A", "B"])
        }
    }

    func testDuplicateRestoreAndDeleteCannotSendTwoMutationsForTheSamePage() async throws {
        let state = viewer()
        let gate = TrashViewerGate()
        var deletes = 0
        let actions = TrashViewerActions(restore: { _ in await gate.value() },
            deletePermanently: { _ in deletes += 1; return true })
        let target = state.target(serverID: "A", detail: nil)
        let first = try XCTUnwrap(actions.perform(.restore, target: target, in: state,
            onError: { XCTFail($0) }, completion: { _ in }))
        addTeardownBlock { await gate.finish(true); await first.value }
        await fulfillment(of: [gate.started], timeout: 2)
        XCTAssertNil(actions.perform(.deletePermanently, target: target, in: state,
            onError: { XCTFail($0) }, completion: { _ in XCTFail("A duplicate must not complete") }))
        XCTAssertEqual(deletes, 0)
        gate.finish(true)
        await first.value
        XCTAssertEqual(state.pages.map(\.id), ["B"])
    }

    func testStaleConfirmationAndMissingServerIdentityDoNotSendRequests() {
        let state = viewer()
        let target = state.target(serverID: "A", detail: nil)
        var calls = 0
        let actions = TrashViewerActions(restore: { _ in calls += 1; return true },
            deletePermanently: { _ in calls += 1; return true })
        state.select("B")
        state.select("A")
        XCTAssertNil(actions.perform(.deletePermanently, target: target, in: state,
            onError: { XCTFail($0) }, completion: { _ in XCTFail("Stale confirmation") }))
        XCTAssertNil(actions.perform(.restore, target: state.target(serverID: nil, detail: nil), in: state,
            onError: { XCTFail($0) }, completion: { _ in XCTFail("No server identity") }))
        XCTAssertEqual(calls, 0)
        XCTAssertEqual(state.pages.map(\.id), ["A", "B"])
    }

    func testAccountChangeBeforeAdmissionRejectsAnOldViewersActions() {
        let state = viewer()
        var calls = 0
        let actions = TrashViewerActions(restore: { _ in calls += 1; return true },
            deletePermanently: { _ in calls += 1; return true })
        LocalSnapshot.clearAll()
        XCTAssertNil(actions.perform(.restore, target: state.target(serverID: "A", detail: nil), in: state,
            onError: { XCTFail($0) }, completion: { _ in XCTFail("Old account") }))
        XCTAssertEqual(calls, 0)
    }

    func testAccountChangeOrCancellationDuringTheRequestCannotPublishItsLateSuccess() async throws {
        for cancels in [false, true] {
            let state = viewer()
            let gate = TrashViewerGate()
            let actions = TrashViewerActions(restore: { _ in await gate.value() }, deletePermanently: { _ in false })
            let task = try XCTUnwrap(actions.perform(.restore, target: state.target(serverID: "A", detail: nil),
                in: state, onError: { XCTFail($0) }, completion: { _ in XCTFail("Late result must not publish") }))
            addTeardownBlock { await gate.finish(true); await task.value }
            await fulfillment(of: [gate.started], timeout: 2)
            if cancels { task.cancel() } else { LocalSnapshot.clearAll() }
            gate.finish(true)
            await task.value
            XCTAssertEqual(state.pages.map(\.id), ["A", "B"])
            XCTAssertFalse(state.isRemoving("A"))
        }
    }

    func testAlreadyCanceledCallerCannotAdmitAMutation() async {
        let state = viewer()
        var calls = 0
        let actions = TrashViewerActions(restore: { _ in calls += 1; return true },
            deletePermanently: { _ in calls += 1; return true })
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            let action = actions.perform(.restore, target: state.target(serverID: "A", detail: nil),
                in: state, onError: { XCTFail($0) }, completion: { _ in XCTFail("Canceled mutation") })
            XCTAssertNil(action)
        }
        await task.value
        XCTAssertEqual(calls, 0)
        XCTAssertEqual(state.pages.map(\.id), ["A", "B"])
    }

    func testSuccessAfterLeavingUpdatesTheOriginalPagesWithoutDismissingANewerScreen() async throws {
        let state = viewer()
        let gate = TrashViewerGate()
        let actions = TrashViewerActions(restore: { _ in await gate.value() }, deletePermanently: { _ in false })
        var presentations: [Bool] = []
        let task = try XCTUnwrap(actions.perform(.restore, target: state.target(serverID: "A", detail: nil),
            in: state, onError: { XCTFail($0) }, completion: { presentations.append($0) }))
        addTeardownBlock { await gate.finish(true); await task.value }
        await fulfillment(of: [gate.started], timeout: 2)
        state.deactivate()
        gate.finish(true)
        await task.value
        XCTAssertEqual(state.pages.map(\.id), ["B"])
        XCTAssertEqual(presentations, [false])
    }

    private func viewer() -> AssetViewerState {
        let assets = ["A", "B"].map { AssetLite(makeTestAsset(id: $0)) }
        return AssetViewerState(currentAsset: assets[0], assets: assets)
    }
}

@MainActor
private final class TrashViewerOutcome {
    var succeeds = false
}

@MainActor
private final class TrashViewerGate {
    let started = XCTestExpectation(description: "A Trash viewer action reached the held server response")
    private var result: Bool?
    private var continuation: CheckedContinuation<Bool, Never>?
    func value() async -> Bool {
        started.fulfill()
        if let result { return result }
        return await withCheckedContinuation { continuation = $0 }
    }
    func finish(_ result: Bool) {
        guard self.result == nil else { return }
        self.result = result
        continuation?.resume(returning: result)
        continuation = nil
    }
}
