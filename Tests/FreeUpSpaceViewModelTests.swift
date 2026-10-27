import XCTest
@testable import ImmichApp

@MainActor
final class FreeUpSpaceViewModelTests: XCTestCase {
    func testCurrentScanCapturesAllRulesAndPublishesItsReview() async throws {
        let started = expectation(description: "Scan reached its asynchronous boundary")
        let gate = SpaceReviewGate<FreeUpSpaceReview>(started: started)
        let expectedRules = rules()
        let expected = review("verified-photo", rules: expectedRules)
        var receivedRules: LocalSpaceRules?
        let model = FreeUpSpaceViewModel(scanner: {
            receivedRules = $0
            return try await gate.wait()
        }, remover: { _ in XCTFail("Scanning must not remove anything"); return 0 })

        let scan = try XCTUnwrap(model.scan(expectedRules))
        XCTAssertEqual(model.stage, .scanning, "Admission happens before the request task starts")
        XCTAssertTrue(model.isBusy)
        await fulfillment(of: [started], timeout: 2)
        XCTAssertEqual(receivedRules, expectedRules)
        gate.resolve(.success(expected))
        await scan.value

        XCTAssertEqual(model.stage, .review)
        XCTAssertEqual(model.candidates, expected.candidates)
        XCTAssertFalse(model.isBusy)
        XCTAssertEqual(model.removedCount, 0)
        XCTAssertNil(model.actionError)
    }

    func testChangingRulesDuringScanRejectsLateResultsEvenIfScannerIgnoresCancellation() async throws {
        let started = expectation(description: "Old cutoff scan started")
        let gate = SpaceReviewGate<FreeUpSpaceReview>(started: started)
        let oldReview = review("old-cutoff-photo")
        let model = FreeUpSpaceViewModel(scanner: { _ in try await gate.wait() }, remover: { _ in 0 })
        let scan = try XCTUnwrap(model.scan(oldReview.rules))
        await fulfillment(of: [started], timeout: 2)

        // This is the same invalidation used by cutoff and keep-rule changes,
        // including while the old operation is still marked as scanning.
        model.invalidate()
        XCTAssertTrue(scan.isCancelled)
        gate.resolve(.success(oldReview))
        await scan.value

        XCTAssertEqual(model.stage, .select)
        XCTAssertTrue(model.candidates.isEmpty)
        XCTAssertNil(model.remove())
        XCTAssertNil(model.actionError)
    }

    func testOldScanCannotReplaceANewerReview() async throws {
        let oldStarted = expectation(description: "Old scan started")
        let newStarted = expectation(description: "Replacement scan started")
        let oldGate = SpaceReviewGate<FreeUpSpaceReview>(started: oldStarted)
        let newGate = SpaceReviewGate<FreeUpSpaceReview>(started: newStarted)
        let oldRules = rules(cutoff: Date(timeIntervalSince1970: 1_700_000_000))
        let newRules = rules(cutoff: Date(timeIntervalSince1970: 1_600_000_000))
        let oldReview = review("old-photo", rules: oldRules)
        let newReview = review("current-photo", rules: newRules)
        let model = FreeUpSpaceViewModel(scanner: {
            try await ($0 == oldRules ? oldGate : newGate).wait()
        }, remover: { _ in 0 })

        let oldScan = try XCTUnwrap(model.scan(oldRules))
        await fulfillment(of: [oldStarted], timeout: 2)
        let newScan = try XCTUnwrap(model.scan(newRules))
        await fulfillment(of: [newStarted], timeout: 2)
        newGate.resolve(.success(newReview))
        await newScan.value
        oldGate.resolve(.success(oldReview))
        await oldScan.value

        XCTAssertEqual(model.stage, .review)
        XCTAssertEqual(model.candidates.map(\.id), ["current-photo"])
        XCTAssertNil(model.actionError)
    }

    func testOldScanErrorCannotReplaceANewerReview() async throws {
        let started = expectation(description: "Old scan started")
        let gate = SpaceReviewGate<FreeUpSpaceReview>(started: started)
        let oldRules = rules(cutoff: Date(timeIntervalSince1970: 1_700_000_000))
        let newReview = review("current-photo", rules: rules(cutoff: Date(timeIntervalSince1970: 1_600_000_000)))
        let model = FreeUpSpaceViewModel(scanner: {
            if $0 == oldRules { return try await gate.wait() }
            return newReview
        }, remover: { _ in 0 })

        let oldScan = try XCTUnwrap(model.scan(oldRules))
        await fulfillment(of: [started], timeout: 2)
        let newScan = try XCTUnwrap(model.scan(newReview.rules))
        await newScan.value
        gate.resolve(.failure(SpaceReviewTestError.failed))
        await oldScan.value

        XCTAssertEqual(model.stage, .review)
        XCTAssertEqual(model.candidates.map(\.id), ["current-photo"])
        XCTAssertNil(model.actionError)
    }

    func testInvalidatingBeforeQueuedScanStartsDoesNotCallScanner() async throws {
        var requests = 0
        let model = FreeUpSpaceViewModel(scanner: {
            requests += 1
            return self.review("unexpected", rules: $0)
        }, remover: { _ in 0 })
        let scan = try XCTUnwrap(model.scan(rules()))

        model.invalidate()
        await scan.value

        XCTAssertEqual(requests, 0)
        XCTAssertEqual(model.stage, .select)
        XCTAssertTrue(model.candidates.isEmpty)
    }

    func testDeletionReceivesReviewAndReportsOnlyTheConfirmedCount() async throws {
        let expected = FreeUpSpaceReview(rules: rules(), candidates:
            review("verified-photo-a").candidates + review("verified-photo-b").candidates)
        var removedReview: FreeUpSpaceReview?
        let model = FreeUpSpaceViewModel(scanner: { _ in expected }, remover: {
            removedReview = $0
            return 1
        })
        let scan = try XCTUnwrap(model.scan(expected.rules))
        await scan.value

        let deletion = try XCTUnwrap(model.remove())
        XCTAssertEqual(model.stage, .deleting)
        XCTAssertTrue(model.isBusy)
        await deletion.value

        XCTAssertEqual(removedReview, expected)
        XCTAssertEqual(model.stage, .complete)
        XCTAssertEqual(model.removedCount, 1)
        XCTAssertTrue(model.candidates.isEmpty)
        XCTAssertNil(model.actionError)
    }

    func testZeroDeletionResultDoesNotClaimSuccessAndRequiresAnotherScan() async throws {
        let expected = review("unverifiable-photo")
        let model = FreeUpSpaceViewModel(scanner: { _ in expected }, remover: { _ in 0 })
        let scan = try XCTUnwrap(model.scan(expected.rules))
        await scan.value
        let deletion = try XCTUnwrap(model.remove())
        await deletion.value

        XCTAssertEqual(model.stage, .select)
        XCTAssertEqual(model.removedCount, 0)
        XCTAssertTrue(model.candidates.isEmpty)
        XCTAssertNotNil(model.actionError)
        XCTAssertNil(model.remove())
    }

    func testDeletionFailureKeepsReviewAndReportsTheFailure() async throws {
        let expected = review("still-on-device")
        let model = FreeUpSpaceViewModel(scanner: { _ in expected }, remover: { _ in
            throw SpaceReviewTestError.failed
        })
        let scan = try XCTUnwrap(model.scan(expected.rules))
        await scan.value
        let deletion = try XCTUnwrap(model.remove())
        await deletion.value

        XCTAssertEqual(model.stage, .review)
        XCTAssertEqual(model.candidates, expected.candidates)
        XCTAssertEqual(model.removedCount, 0)
        XCTAssertEqual(model.actionError?.message, SpaceReviewTestError.failed.localizedDescription)
        XCTAssertFalse(model.isBusy)
    }

    func testInvalidatingHeldDeletionRejectsItsLateSuccess() async throws {
        let expected = review("old-account-photo")
        let started = expectation(description: "Deletion reached its asynchronous boundary")
        let gate = SpaceReviewGate<Int>(started: started)
        let model = FreeUpSpaceViewModel(scanner: { _ in expected }, remover: { _ in try await gate.wait() })
        let scan = try XCTUnwrap(model.scan(expected.rules))
        await scan.value
        let deletion = try XCTUnwrap(model.remove())
        await fulfillment(of: [started], timeout: 2)

        model.invalidate()
        gate.resolve(.success(1))
        await deletion.value

        XCTAssertTrue(deletion.isCancelled)
        XCTAssertEqual(model.stage, .select)
        XCTAssertEqual(model.removedCount, 0)
        XCTAssertTrue(model.candidates.isEmpty)
        XCTAssertNil(model.actionError)
    }

    func testInvalidatingBeforeQueuedDeletionStartsDoesNotCallRemover() async throws {
        let expected = review("verified-photo")
        var removals = 0
        let model = FreeUpSpaceViewModel(scanner: { _ in expected }, remover: { _ in
            removals += 1
            return 1
        })
        let scan = try XCTUnwrap(model.scan(expected.rules))
        await scan.value

        let deletion = try XCTUnwrap(model.remove())
        model.invalidate()
        await deletion.value

        XCTAssertEqual(removals, 0)
        XCTAssertEqual(model.stage, .select)
        XCTAssertEqual(model.removedCount, 0)
    }

    func testDuplicateDeletionAndScanCannotOverlapADeletion() async throws {
        let expected = review("verified-photo")
        let started = expectation(description: "Deletion started")
        let gate = SpaceReviewGate<Int>(started: started)
        var removals = 0
        let model = FreeUpSpaceViewModel(scanner: { _ in expected }, remover: { _ in
            removals += 1
            return try await gate.wait()
        })
        let scan = try XCTUnwrap(model.scan(expected.rules))
        await scan.value
        let deletion = try XCTUnwrap(model.remove())
        await fulfillment(of: [started], timeout: 2)

        XCTAssertNil(model.remove())
        XCTAssertNil(model.scan(rules()))
        XCTAssertEqual(removals, 1)
        gate.resolve(.success(1))
        await deletion.value
        XCTAssertEqual(model.stage, .complete)
    }

    func testNoCutoffOrEmptyReviewCannotStartDeletion() async throws {
        var requests = 0
        let model = FreeUpSpaceViewModel(scanner: {
            requests += 1
            return FreeUpSpaceReview(rules: $0, candidates: [])
        }, remover: { _ in XCTFail("An empty review must not reach deletion"); return 0 })

        XCTAssertNil(model.scan(LocalSpaceRules()))
        XCTAssertEqual(requests, 0)
        let scan = try XCTUnwrap(model.scan(rules()))
        await scan.value

        XCTAssertEqual(model.stage, .review)
        XCTAssertTrue(model.candidates.isEmpty)
        XCTAssertNil(model.remove())
        XCTAssertNil(model.actionError)
        XCTAssertEqual(requests, 1)
    }

    func testScanFailureReportsErrorWithoutPublishingCandidates() async throws {
        let model = FreeUpSpaceViewModel(scanner: { _ in throw SpaceReviewTestError.failed }, remover: { _ in 0 })

        let scan = try XCTUnwrap(model.scan(rules()))
        await scan.value

        XCTAssertEqual(model.stage, .select)
        XCTAssertTrue(model.candidates.isEmpty)
        XCTAssertFalse(model.isBusy)
        XCTAssertEqual(model.actionError?.message, SpaceReviewTestError.failed.localizedDescription)
    }

    private func rules(cutoff: Date = Date(timeIntervalSince1970: 1_700_000_000)) -> LocalSpaceRules {
        LocalSpaceRules(cutoff: cutoff, keepFavorites: true, keepAlbumIDs: ["protected-album"], keepPhotos: false, keepVideos: true)
    }

    private func review(_ id: String, rules: LocalSpaceRules? = nil) -> FreeUpSpaceReview {
        let date = Date(timeIntervalSince1970: 1_500_000_000)
        let candidate = LocalSpaceCandidate(id: id, version: LocalAssetVersion(
            createdAt: date, modifiedAt: date, isFavorite: false, isVideo: false, isLivePhoto: false,
            pixelWidth: 1, pixelHeight: 1, duration: 0,
            resources: [LocalSpaceResourceDescriptor(type: 1, filename: "photo.jpg", contentType: "public.jpeg")]),
            resourceChecksums: [.primary: "fresh-content-checksum"])
        return FreeUpSpaceReview(rules: rules ?? self.rules(), candidates: [candidate])
    }
}

private enum SpaceReviewTestError: LocalizedError {
    case failed
    var errorDescription: String? { "The copies could not be verified." }
}

/// Deliberately ignores task cancellation: admission must remain safe when an
/// already-issued network or Photos operation completes after invalidation.
@MainActor
private final class SpaceReviewGate<Value> {
    let started: XCTestExpectation
    private var continuation: CheckedContinuation<Value, Error>?

    init(started: XCTestExpectation) { self.started = started }

    func wait() async throws -> Value {
        try await withCheckedThrowingContinuation {
            continuation = $0
            started.fulfill()
        }
    }

    func resolve(_ result: Result<Value, Error>) {
        XCTAssertNotNil(continuation, "Wait for the operation to start before releasing it")
        continuation?.resume(with: result)
        continuation = nil
    }
}
