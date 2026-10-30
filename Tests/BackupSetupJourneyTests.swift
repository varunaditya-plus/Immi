import XCTest
@testable import ImmichApp

@MainActor
final class BackupSetupJourneyTests: XCTestCase {
    private var selectedAlbumIDs: Set<String> = []

    func testNoSelectedAlbumStartsAtProfile() {
        let journey = makeJourney()

        journey.refreshForAlbumSelection()

        XCTAssertEqual(journey.step, .profile)
        assertCoachmarkBecomesVisibleWhenReady(journey)
    }

    func testSelectedAlbumKeepsJourneyHidden() {
        selectedAlbumIDs = ["recents"]
        let journey = makeJourney()

        journey.refreshForAlbumSelection()

        XCTAssertEqual(journey.step, .idle)
        XCTAssertFalse(journey.isCoachmarkVisible)
    }

    func testSelectingAlbumDismissesActiveJourney() {
        let journey = makeJourney()
        journey.refreshForAlbumSelection()
        selectedAlbumIDs = ["recents"]

        journey.refreshForAlbumSelection()

        XCTAssertEqual(journey.step, .idle)
        XCTAssertFalse(journey.isCoachmarkVisible)
    }

    func testRemovingLastAlbumOffersJourneyAgain() {
        let journey = makeJourney()
        selectedAlbumIDs = ["recents"]
        journey.refreshForAlbumSelection()
        selectedAlbumIDs = []

        journey.refreshForAlbumSelection()

        XCTAssertEqual(journey.step, .profile)
        assertCoachmarkBecomesVisibleWhenReady(journey)
    }

    func testCompletionSuppressesRepeatedRefreshOnlyForCurrentEmptySelection() {
        let journey = makeJourney()
        journey.refreshForAlbumSelection()
        journey.finish()

        journey.refreshForAlbumSelection()

        XCTAssertEqual(journey.step, .idle)
        XCTAssertFalse(journey.isCoachmarkVisible)

        selectedAlbumIDs = ["recents"]
        journey.refreshForAlbumSelection()
        selectedAlbumIDs = []
        journey.refreshForAlbumSelection()

        XCTAssertEqual(journey.step, .profile)
        assertCoachmarkBecomesVisibleWhenReady(journey)
    }

    func testNewAppSessionOffersTipAgainWhenAlbumsRemainEmpty() {
        let firstSession = makeJourney()
        firstSession.refreshForAlbumSelection()
        firstSession.finish()

        let nextSession = makeJourney()
        nextSession.refreshForAlbumSelection()

        XCTAssertEqual(nextSession.step, .profile)
        assertCoachmarkBecomesVisibleWhenReady(nextSession)
    }

    func testClosingSettingsReturnsJourneyToProfile() {
        let journey = makeJourney()
        journey.refreshForAlbumSelection()
        journey.advanceToBackupRow()

        journey.returnToProfileIfNeeded()

        XCTAssertEqual(journey.step, .profile)
        assertCoachmarkBecomesVisibleWhenReady(journey)
    }

    func testCallbackForPreviousStepDoesNotPresentCoachmark() {
        let journey = makeJourney()
        journey.refreshForAlbumSelection()
        let profileRequest = journey.presentationRequest
        journey.advanceToBackupRow()

        journey.markTipReady(for: .profile, request: profileRequest)

        XCTAssertEqual(journey.step, .backupRow)
        assertCoachmarkBecomesVisibleWhenReady(journey)
    }

    func testCallbackForPreviousRequestAtSameStepDoesNotPresentCoachmark() {
        let journey = makeJourney()
        journey.refreshForAlbumSelection()
        let oldRequest = journey.presentationRequest
        journey.advanceToBackupRow()
        journey.returnToProfileIfNeeded()

        journey.markTipReady(for: .profile, request: oldRequest)

        XCTAssertEqual(journey.step, .profile)
        assertCoachmarkBecomesVisibleWhenReady(journey)
    }

    func testCallbackAfterCompletionDoesNotPresentCoachmark() {
        let journey = makeJourney()
        journey.refreshForAlbumSelection()
        let request = journey.presentationRequest
        journey.finish()

        journey.markTipReady(for: .profile, request: request)

        XCTAssertEqual(journey.step, .idle)
        XCTAssertFalse(journey.isCoachmarkVisible)
    }

    func testDismissedProfileDoesNotReopenForRepeatedReadyCallbacksOrRefreshes() {
        let journey = makeJourney()
        journey.refreshForAlbumSelection()
        let request = journey.presentationRequest
        journey.markTipReady(for: .profile, request: request)
        XCTAssertTrue(journey.isCoachmarkVisible)

        journey.dismissCoachmark(for: .profile, request: request)
        journey.markTipReady(for: .profile, request: request)
        journey.refreshForAlbumSelection()
        journey.markTipReady(for: .profile, request: journey.presentationRequest)

        XCTAssertEqual(journey.step, .idle)
        XCTAssertFalse(journey.isCoachmarkVisible)
    }

    func testDismissedBackupRowDoesNotReturnToProfileWhenSettingsCloses() {
        let journey = makeJourney()
        journey.refreshForAlbumSelection()
        journey.advanceToBackupRow()
        let request = journey.presentationRequest
        journey.markTipReady(for: .backupRow, request: request)

        journey.dismissCoachmark(for: .backupRow, request: request)
        journey.returnToProfileIfNeeded()
        journey.markTipReady(for: .backupRow, request: request)
        journey.refreshForAlbumSelection()

        XCTAssertEqual(journey.step, .idle)
        XCTAssertFalse(journey.isCoachmarkVisible)
    }

    func testLosingAnchorRejectsItsPendingCallbackWithoutSuppressingTheJourney() {
        let journey = makeJourney()
        journey.refreshForAlbumSelection()
        let request = journey.presentationRequest

        journey.suspendPresentation(for: .profile, request: request)
        journey.markTipReady(for: .profile, request: request)

        XCTAssertEqual(journey.step, .profile)
        XCTAssertFalse(journey.isCoachmarkVisible)
        XCTAssertNotEqual(journey.presentationRequest, request)
        assertCoachmarkBecomesVisibleWhenReady(journey)
    }

    func testLosingVisibleAnchorHidesTheTipUntilTheCurrentAnchorIsReady() {
        let journey = makeJourney()
        journey.refreshForAlbumSelection()
        let request = journey.presentationRequest
        journey.markTipReady(for: .profile, request: request)

        journey.suspendPresentation(for: .profile, request: request)

        XCTAssertEqual(journey.step, .profile)
        XCTAssertFalse(journey.isCoachmarkVisible)
        assertCoachmarkBecomesVisibleWhenReady(journey)
    }

    func testRetiredAnchorCannotHideANewerPresentation() {
        let journey = makeJourney()
        journey.refreshForAlbumSelection()
        let retiredRequest = journey.presentationRequest
        journey.suspendPresentation(for: .profile, request: retiredRequest)
        let currentRequest = journey.presentationRequest
        journey.markTipReady(for: .profile, request: currentRequest)

        journey.suspendPresentation(for: .profile, request: retiredRequest)

        XCTAssertEqual(journey.presentationRequest, currentRequest)
        XCTAssertTrue(journey.isCoachmarkVisible)
    }

    func testProfileAnchorCannotHideTheSettingsRowPresentation() {
        let journey = makeJourney()
        journey.refreshForAlbumSelection()
        let profileRequest = journey.presentationRequest
        journey.advanceToBackupRow()
        let rowRequest = journey.presentationRequest
        journey.markTipReady(for: .backupRow, request: rowRequest)

        journey.suspendPresentation(for: .profile, request: profileRequest)

        XCTAssertEqual(journey.presentationRequest, rowRequest)
        XCTAssertTrue(journey.isCoachmarkVisible)
    }

    func testDismissalFromRetiredPopoverCannotSuppressANewerPresentation() {
        let journey = makeJourney()
        journey.refreshForAlbumSelection()
        let retiredRequest = journey.presentationRequest
        journey.suspendPresentation(for: .profile, request: retiredRequest)
        let currentRequest = journey.presentationRequest
        journey.markTipReady(for: .profile, request: currentRequest)

        journey.dismissCoachmark(for: .profile, request: retiredRequest)

        XCTAssertEqual(journey.step, .profile)
        XCTAssertEqual(journey.presentationRequest, currentRequest)
        XCTAssertTrue(journey.isCoachmarkVisible)
    }

    func testIdleJourneyRejectsReadinessWithoutAnActiveStep() {
        let journey = makeJourney()

        journey.markTipReady(for: .idle, request: journey.presentationRequest)

        XCTAssertFalse(journey.isCoachmarkVisible)
    }

    private func assertCoachmarkBecomesVisibleWhenReady(
        _ journey: BackupSetupJourney,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertFalse(journey.isCoachmarkVisible, file: file, line: line)

        journey.markTipReady(for: journey.step, request: journey.presentationRequest)

        XCTAssertTrue(journey.isCoachmarkVisible, file: file, line: line)
    }

    private func makeJourney() -> BackupSetupJourney {
        BackupSetupJourney(hasSelectedAlbums: { !self.selectedAlbumIDs.isEmpty })
    }
}
