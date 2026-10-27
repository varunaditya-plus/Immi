import XCTest
@testable import ImmichApp

@MainActor
final class LockedFolderAccessTests: XCTestCase {
    func testEntryLocksPreviouslyElevatedSessionBeforeOfferingPIN() async {
        let repo = LifecyclePinRepository(api: makeStubAPIClient())
        repo.serverIsElevated = true
        let access = LockedFolderAccess(repo: repo)

        await access.enter()

        XCTAssertEqual(repo.events, ["lock", "status"])
        XCTAssertFalse(repo.serverIsElevated)
        XCTAssertFalse(access.isUnlocked)
        XCTAssertTrue(access.showPinSheet)
        XCTAssertEqual(access.status?.pinCode, true)
    }

    func testCorrectPINOpensCurrentVisitAndClosesPrompt() async throws {
        let repo = LifecyclePinRepository(api: makeStubAPIClient())
        let access = LockedFolderAccess(repo: repo)
        await access.enter()

        try await access.unlock(pin: "1234", visit: access.visitID)

        XCTAssertTrue(access.isUnlocked)
        XCTAssertTrue(repo.serverIsElevated)
        XCTAssertFalse(access.showPinSheet)
        XCTAssertFalse(access.isVerifying)
        XCTAssertEqual(repo.events, ["lock", "status", "unlock:1234", "unlocked"])
        XCTAssertFalse(access.shouldLeaveAfterSheetDismissal())
    }

    func testFailedInitialLockCannotReuseElevatedServerSession() async throws {
        let repo = LifecyclePinRepository(api: makeStubAPIClient())
        repo.serverIsElevated = true
        repo.lockError = APIError.notConnected
        let access = LockedFolderAccess(repo: repo)

        await access.enter()

        XCTAssertFalse(access.isUnlocked)
        XCTAssertFalse(access.showPinSheet)
        XCTAssertNil(access.status)
        XCTAssertNotNil(access.errorMessage)
        XCTAssertEqual(repo.events, ["lock"])

        repo.lockError = nil
        await access.presentPIN()
        XCTAssertTrue(access.showPinSheet)
        XCTAssertFalse(access.isUnlocked)
        try await access.unlock(pin: "1234", visit: access.visitID)
        XCTAssertTrue(access.isUnlocked)
    }

    func testFailedStatusCheckCannotOpenFolderOrOfferUnknownPINSetup() async {
        let repo = LifecyclePinRepository(api: makeStubAPIClient())
        repo.statusError = APIError.notConnected
        let access = LockedFolderAccess(repo: repo)

        await access.enter()

        XCTAssertFalse(access.isUnlocked)
        XCTAssertFalse(access.showPinSheet)
        XCTAssertNil(access.status)
        XCTAssertNotNil(access.errorMessage)
    }

    func testDeactivationImmediatelyRevokesLoadedContentAndNextActivationRequiresPIN() async throws {
        let repo = LifecyclePinRepository(api: makeStubAPIClient())
        let access = LockedFolderAccess(repo: repo)
        await access.enter()
        try await access.unlock(pin: "1234", visit: access.visitID)
        XCTAssertTrue(access.isUnlocked)

        access.deactivate()

        XCTAssertFalse(access.isUnlocked)
        XCTAssertNil(access.status)
        XCTAssertFalse(access.showPinSheet)
        XCTAssertFalse(access.isVerifying)

        await access.activate()
        XCTAssertFalse(repo.serverIsElevated)
        XCTAssertFalse(access.isUnlocked)
        XCTAssertTrue(access.showPinSheet)
        try await access.unlock(pin: "1234", visit: access.visitID)
        XCTAssertTrue(access.isUnlocked)
    }

    func testLateUnlockCannotReopenFolderAndIsLockedBeforeNewVisitChecksStatus() async throws {
        let repo = LifecyclePinRepository(api: makeStubAPIClient())
        let gate = LifecyclePinGate(started: expectation(description: "PIN request in flight"))
        repo.unlockGate = gate
        let access = LockedFolderAccess(repo: repo)
        await access.enter()
        let oldUnlock = Task { try await access.unlock(pin: "1234", visit: access.visitID) }
        await fulfillment(of: [gate.started], timeout: 2)

        access.deactivate()
        let returning = Task { await access.activate() }
        XCTAssertFalse(access.isUnlocked)
        gate.resume()
        do {
            try await oldUnlock.value
            XCTFail("The old PIN completion must be rejected")
        } catch is CancellationError {
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
        await returning.value

        XCTAssertEqual(repo.events, ["lock", "status", "unlock:1234", "unlocked", "lock", "lock", "status"])
        XCTAssertFalse(repo.serverIsElevated)
        XCTAssertFalse(access.isUnlocked)
        XCTAssertTrue(access.showPinSheet)
        try await access.unlock(pin: "5678", visit: access.visitID)
        XCTAssertTrue(access.isUnlocked)
    }

    func testLateStatusCannotShowPINOrPrivateContentWhileInactive() async {
        let repo = LifecyclePinRepository(api: makeStubAPIClient())
        let gate = LifecyclePinGate(started: expectation(description: "Status request in flight"))
        repo.statusGate = gate
        let access = LockedFolderAccess(repo: repo)
        let entering = Task { await access.enter() }
        await fulfillment(of: [gate.started], timeout: 2)

        access.deactivate()
        gate.resume()
        await entering.value

        XCTAssertFalse(access.isUnlocked)
        XCTAssertNil(access.status)
        XCTAssertFalse(access.showPinSheet)
        XCTAssertFalse(access.isChecking)
        await access.activate()
        XCTAssertTrue(access.showPinSheet)
        XCTAssertFalse(access.isUnlocked)
    }

    func testSubmissionFromDismissedPromptCannotUnlockNewVisit() async throws {
        let repo = LifecyclePinRepository(api: makeStubAPIClient())
        let access = LockedFolderAccess(repo: repo)
        await access.enter()
        let oldVisit = access.visitID
        access.deactivate()
        await access.activate()
        let beforeSubmission = repo.events

        do {
            try await access.unlock(pin: "1234", visit: oldVisit)
            XCTFail("A submit task retained by the dismissed prompt must be rejected")
        } catch is CancellationError {
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        XCTAssertEqual(repo.events, beforeSubmission)
        XCTAssertFalse(access.isUnlocked)
        try await access.unlock(pin: "5678", visit: access.visitID)
        XCTAssertTrue(access.isUnlocked)
    }

    func testRepeatedBackgroundPhasesDoNotCreateOverlappingRelocks() async throws {
        let repo = LifecyclePinRepository(api: makeStubAPIClient())
        let access = LockedFolderAccess(repo: repo)
        await access.enter()
        try await access.unlock(pin: "1234", visit: access.visitID)

        access.deactivate()
        access.deactivate()
        await access.activate()

        XCTAssertEqual(repo.events.filter { $0 == "lock" }.count, 3)
        XCTAssertFalse(access.isUnlocked)
    }

    func testPrivacyDismissalKeepsFolderOpenButUserCancellingPINLeavesIt() async {
        let repo = LifecyclePinRepository(api: makeStubAPIClient())
        let access = LockedFolderAccess(repo: repo)
        await access.enter()
        access.deactivate()
        await access.activate()

        XCTAssertFalse(access.shouldLeaveAfterSheetDismissal())
        XCTAssertTrue(access.showPinSheet)
        access.showPinSheet = false
        XCTAssertTrue(access.shouldLeaveAfterSheetDismissal())
    }

    func testPINSetupCreatesThenUnlocksBeforeShowingPhotos() async throws {
        let repo = LifecyclePinRepository(api: makeStubAPIClient())
        repo.hasPIN = false
        let access = LockedFolderAccess(repo: repo)
        await access.enter()
        XCTAssertEqual(access.status?.pinCode, false)

        try await access.unlock(pin: "12345", visit: access.visitID)

        XCTAssertEqual(repo.events, ["lock", "status", "create:12345", "unlock:12345", "unlocked"])
        XCTAssertTrue(access.isUnlocked)
        XCTAssertEqual(access.status?.pinCode, true)
    }

    func testRejectedPINKeepsPromptAvailableAndNeverPublishesAccess() async {
        let repo = LifecyclePinRepository(api: makeStubAPIClient())
        repo.unlockError = APIError.unauthorized
        let access = LockedFolderAccess(repo: repo)
        await access.enter()

        do {
            try await access.unlock(pin: "0000", visit: access.visitID)
            XCTFail("Rejected PIN must fail")
        } catch {
            XCTAssertFalse(access.isUnlocked)
            XCTAssertFalse(access.isVerifying)
            XCTAssertTrue(access.showPinSheet)
            XCTAssertFalse(repo.serverIsElevated)
        }
    }
}

@MainActor
private final class LifecyclePinRepository: PinRepository {
    var events: [String] = []
    var hasPIN = true
    var serverIsElevated = false
    var lockError: Error?
    var statusError: Error?
    var unlockError: Error?
    var unlockGate: LifecyclePinGate?
    var statusGate: LifecyclePinGate?

    override func status() async throws -> AuthStatusDTO {
        events.append("status")
        if let gate = statusGate {
            statusGate = nil
            await gate.wait()
        }
        if let statusError { throw statusError }
        return AuthStatusDTO(pinCode: hasPIN, isElevated: serverIsElevated)
    }

    override func lock() async throws {
        events.append("lock")
        if let lockError { throw lockError }
        serverIsElevated = false
    }

    override func createPin(_ pin: String) async throws {
        events.append("create:\(pin)")
        hasPIN = true
    }

    override func unlock(pin: String) async throws {
        events.append("unlock:\(pin)")
        if let gate = unlockGate {
            unlockGate = nil
            await gate.wait()
        }
        if let unlockError { throw unlockError }
        serverIsElevated = true
        events.append("unlocked")
    }
}

@MainActor
private final class LifecyclePinGate {
    let started: XCTestExpectation
    private var continuation: CheckedContinuation<Void, Never>?

    init(started: XCTestExpectation) { self.started = started }

    func wait() async {
        await withCheckedContinuation {
            continuation = $0
            started.fulfill()
        }
    }

    func resume() {
        XCTAssertNotNil(continuation, "The request must start before it is released")
        continuation?.resume()
        continuation = nil
    }
}
