import Photos
import XCTest
@testable import ImmichApp

@MainActor
final class LocalPhotoBackupScanTests: XCTestCase {
    private var suites: [String] = []
    private var gates: [BackupScanGate] = []

    override func tearDown() async throws {
        for gate in gates { gate.complete(.init(photos: [], albumTitles: [:])) }
        gates.removeAll()
        for suite in suites { UserDefaults.standard.removePersistentDomain(forName: suite) }
        suites.removeAll()
        try await super.tearDown()
    }

    func testColdLibraryHasNoScanProofEvenWithSelectedAlbums() {
        let library = library { _ in XCTFail("Reading scan proof must not enumerate Photos"); return self.scan("photo") }

        XCTAssertNil(library.currentSelectionScanID)
        library.selectedAlbumIDs = ["selected"]
        XCTAssertNil(library.currentSelectionScanID)
        XCTAssertTrue(library.photos.isEmpty)
    }

    func testSuccessfulSelectionLoadPublishesProofForThePhotosItRead() async throws {
        let library = library { ids in
            XCTAssertEqual(ids, ["selected"])
            return self.scan("photo")
        }
        library.selectedAlbumIDs = ["selected"]

        await library.load()

        let scanID = try XCTUnwrap(library.currentSelectionScanID)
        XCTAssertEqual(library.photos.map(\.id), ["photo"])
        XCTAssertEqual(library.currentSelectionScanID, scanID, "Reading proof does not create another scan")
    }

    func testASelectedEmptyAlbumHasSuccessfulProofRatherThanAnUnscannedZero() async throws {
        var reads = 0
        let library = library { ids in
            XCTAssertEqual(ids, ["empty-album"])
            reads += 1
            return .init(photos: [], albumTitles: [:])
        }
        library.selectedAlbumIDs = ["empty-album"]
        XCTAssertNil(library.currentSelectionScanID)

        await library.load()

        XCTAssertNotNil(library.currentSelectionScanID)
        XCTAssertEqual(reads, 1)
        XCTAssertTrue(library.photos.isEmpty)
    }

    func testStartingAReplacementLoadInvalidatesProofBeforeItsPhotosArrive() async throws {
        let held = gate()
        var reads = 0
        let library = library { _ in
            reads += 1
            return reads == 1 ? self.scan("old") : await held.value()
        }
        library.selectedAlbumIDs = ["selected"]
        await library.load()
        let firstID = try XCTUnwrap(library.currentSelectionScanID)
        let replacement = Task { await library.load() }
        addTeardownBlock { replacement.cancel(); await held.complete(self.scan("cleanup")); await replacement.value }
        await fulfillment(of: [held.started], timeout: 2)

        XCTAssertNil(library.currentSelectionScanID)
        XCTAssertEqual(library.photos.map(\.id), ["old"], "Old photos are not proof of the pending selection scan")
        held.complete(scan("replacement"))
        await replacement.value

        XCTAssertNotNil(library.currentSelectionScanID)
        XCTAssertNotEqual(library.currentSelectionScanID, firstID)
        XCTAssertEqual(library.photos.map(\.id), ["replacement"])
    }

    func testSelectionChangesAndReturningToTheOriginalSelectionInvalidateProof() async throws {
        let library = library { _ in self.scan("photo") }
        library.selectedAlbumIDs = ["selected"]
        await library.load()
        let firstID = try XCTUnwrap(library.currentSelectionScanID)

        library.selectedAlbumIDs = ["other"]
        XCTAssertNil(library.currentSelectionScanID)
        library.selectedAlbumIDs = ["selected"]
        XCTAssertNil(library.currentSelectionScanID, "Selection ABA must not restore an obsolete scan")

        await library.load()
        XCTAssertNotNil(library.currentSelectionScanID)
        XCTAssertNotEqual(library.currentSelectionScanID, firstID)
    }

    func testPhotoLibraryChangesInvalidateProofEvenWhenAuthorizedPhotosRemainCached() async throws {
        let library = library { _ in self.scan("photo") }
        library.selectedAlbumIDs = ["selected"]
        await library.load()
        let firstID = try XCTUnwrap(library.currentSelectionScanID)

        library.libraryDidChange()

        XCTAssertEqual(library.photos.map(\.id), ["photo"])
        XCTAssertNil(library.currentSelectionScanID)
        await library.load()
        XCTAssertNotNil(library.currentSelectionScanID)
        XCTAssertNotEqual(library.currentSelectionScanID, firstID)
    }

    func testLivePermissionRevocationHidesProofBeforeTheCachedStatusIsRefreshed() async throws {
        let access = BackupScanAccess(.authorized)
        let library = library(access: access) { _ in self.scan("photo") }
        library.selectedAlbumIDs = ["selected"]
        await library.load()
        let firstID = try XCTUnwrap(library.currentSelectionScanID)

        access.status = .denied
        XCTAssertTrue(library.isAuthorized, "The published authorization can lag the live PhotoKit status")
        XCTAssertNil(library.currentSelectionScanID)
        library.refreshAuthorizationStatus()
        access.status = .authorized
        library.refreshAuthorizationStatus()
        XCTAssertNil(library.currentSelectionScanID, "A restored grant still requires a fresh selection scan")

        await library.load()
        XCTAssertNotNil(library.currentSelectionScanID)
        XCTAssertNotEqual(library.currentSelectionScanID, firstID)
    }

    func testSwitchingFromFullToLimitedAccessRequiresANewScan() async throws {
        let access = BackupScanAccess(.authorized)
        let library = library(access: access) { _ in self.scan("photo") }
        library.selectedAlbumIDs = ["selected"]
        await library.load()
        let fullID = try XCTUnwrap(library.currentSelectionScanID)

        access.status = .limited
        XCTAssertNil(library.currentSelectionScanID)
        library.refreshAuthorizationStatus()
        XCTAssertTrue(library.isAuthorized)
        XCTAssertNil(library.currentSelectionScanID)

        await library.load()
        XCTAssertNotNil(library.currentSelectionScanID)
        XCTAssertNotEqual(library.currentSelectionScanID, fullID)
    }

    func testLatePrelogoutLoadCannotRestoreProofOrReplaceTheNewSessionsScan() async throws {
        let held = gate()
        var reads = 0
        let library = library { _ in
            reads += 1
            return reads == 1 ? await held.value() : self.scan("new-session")
        }
        library.selectedAlbumIDs = ["selected"]
        let obsolete = Task { await library.load() }
        addTeardownBlock { obsolete.cancel(); await held.complete(self.scan("cleanup")); await obsolete.value }
        await fulfillment(of: [held.started], timeout: 2)

        library.resetForLogout()
        XCTAssertNil(library.currentSelectionScanID)
        library.selectedAlbumIDs = ["selected"]
        await library.load()
        let currentID = try XCTUnwrap(library.currentSelectionScanID)
        held.complete(scan("previous-session"))
        await obsolete.value

        XCTAssertEqual(library.currentSelectionScanID, currentID)
        XCTAssertEqual(library.photos.map(\.id), ["new-session"])
    }

    func testAnOlderLoadCannotReplaceTheLatestSuccessfulProof() async throws {
        let held = gate()
        var reads = 0
        let library = library { _ in
            reads += 1
            return reads == 1 ? await held.value() : self.scan("latest")
        }
        library.selectedAlbumIDs = ["selected"]
        let obsolete = Task { await library.load() }
        addTeardownBlock { obsolete.cancel(); await held.complete(self.scan("cleanup")); await obsolete.value }
        await fulfillment(of: [held.started], timeout: 2)
        await library.load()
        let latestID = try XCTUnwrap(library.currentSelectionScanID)
        held.complete(scan("obsolete"))
        await obsolete.value

        XCTAssertEqual(library.currentSelectionScanID, latestID)
        XCTAssertEqual(library.photos.map(\.id), ["latest"])
    }

    func testCanceledLoadDoesNotCertifyItsOldPhotosAndCanBeRetried() async throws {
        let held = gate()
        var reads = 0
        let library = library { _ in
            reads += 1
            return reads == 2 ? await held.value() : self.scan(reads == 1 ? "old" : "retry")
        }
        library.selectedAlbumIDs = ["selected"]
        await library.load()
        let firstID = try XCTUnwrap(library.currentSelectionScanID)
        let canceled = Task { await library.load() }
        addTeardownBlock { canceled.cancel(); await held.complete(self.scan("cleanup")); await canceled.value }
        await fulfillment(of: [held.started], timeout: 2)
        canceled.cancel()
        held.complete(scan("canceled"))
        await canceled.value

        XCTAssertNil(library.currentSelectionScanID)
        XCTAssertEqual(library.photos.map(\.id), ["old"])
        await library.load()
        XCTAssertNotNil(library.currentSelectionScanID)
        XCTAssertNotEqual(library.currentSelectionScanID, firstID)
        XCTAssertEqual(library.photos.map(\.id), ["retry"])
    }

    func testAlbumMetadataLookupDoesNotCertifyUnpublishedSelectionCounts() async throws {
        var reads = 0
        let library = library { _ in reads += 1; return self.scan("photo") }
        library.selectedAlbumIDs = ["selected"]

        let title = try await library.sourceAlbumTitle(for: "photo")

        XCTAssertEqual(title, "Album")
        XCTAssertEqual(reads, 1)
        XCTAssertTrue(library.photos.isEmpty)
        XCTAssertNil(library.currentSelectionScanID)
        await library.load()
        let publishedID = try XCTUnwrap(library.currentSelectionScanID)
        _ = try await library.sourceAlbumTitle(for: "photo")
        XCTAssertEqual(library.currentSelectionScanID, publishedID)
        XCTAssertEqual(reads, 2)
    }

    private func library(
        access: BackupScanAccess? = nil,
        scan: @escaping (Set<String>) async -> LocalPhotoScan
    ) -> LocalPhotoLibrary {
        let access = access ?? BackupScanAccess(.authorized)
        let suite = "LocalPhotoBackupScanTests.\(UUID())"
        suites.append(suite)
        return LocalPhotoLibrary(defaults: UserDefaults(suiteName: suite)!, reader: .init(
            authorizationStatus: { access.status },
            requestAuthorization: { XCTFail("These scans must not prompt for Photos access"); return access.status },
            photosInAlbums: scan))
    }

    private func scan(_ id: String) -> LocalPhotoScan {
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        return .init(photos: [.init(id: id, createdAt: date, modifiedAt: date,
            isVideo: false, isLivePhoto: false, duration: nil, ratio: 1)], albumTitles: [id: "Album"])
    }

    private func gate() -> BackupScanGate {
        let gate = BackupScanGate()
        gates.append(gate)
        return gate
    }
}

@MainActor
private final class BackupScanAccess {
    var status: PHAuthorizationStatus
    init(_ status: PHAuthorizationStatus) { self.status = status }
}

@MainActor
private final class BackupScanGate {
    let started = XCTestExpectation(description: "Selection scan is suspended")
    private var continuation: CheckedContinuation<LocalPhotoScan, Never>?
    private var result: LocalPhotoScan?

    func value() async -> LocalPhotoScan {
        if let result { return result }
        return await withCheckedContinuation { continuation = $0; started.fulfill() }
    }

    func complete(_ result: LocalPhotoScan) {
        self.result = result
        continuation?.resume(returning: result)
        continuation = nil
    }
}
