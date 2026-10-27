import Photos
import XCTest
@testable import ImmichApp

@MainActor
final class LocalPhotoLibraryLifecycleTests: XCTestCase {
    private var suites: [String] = []
    private var closeWorkers: [() -> Void] = []

    override func tearDown() async throws {
        closeWorkers.forEach { $0() }
        closeWorkers.removeAll()
        for suite in suites { UserDefaults.standard.removePersistentDomain(forName: suite) }
        suites.removeAll()
        try await super.tearDown()
    }

    func testOlderSelectedAlbumScanCannotReplaceTheNewSelection() async {
        let access = Access(.authorized)
        let old = heldScan()
        let library = library(access: access, scan: { ids in
            if ids == ["old-album"] { return await old.value() }
            XCTAssertEqual(ids, ["new-album"])
            return self.scan("new-photo", album: "New Album")
        })
        library.selectedAlbumIDs = ["old-album"]
        let first = Task { await library.load() }
        await fulfillment(of: [old.started], timeout: 2)

        library.selectedAlbumIDs = ["new-album"]
        await library.load()
        old.complete(scan("old-photo", album: "Old Album"))
        await first.value

        XCTAssertEqual(library.photos.map(\.id), ["new-photo"])
        XCTAssertEqual(library.albumTitles, ["new-photo": "New Album"])
        XCTAssertEqual(library.selectedAlbumIDs, ["new-album"])
    }

    func testSelectionEditClearsCachedPhotosAndReturningToOldSelectionDoesNotAdmitItsHeldScan() async {
        let access = Access(.authorized)
        let held = heldScan()
        var calls = 0
        let library = library(access: access, scan: { _ in
            calls += 1
            if calls == 2 { return await held.value() }
            return self.scan(calls == 1 ? "cached" : "fresh")
        })
        library.selectedAlbumIDs = ["album"]
        await library.load()
        let old = Task { await library.load() }
        await fulfillment(of: [held.started], timeout: 2)

        library.selectedAlbumIDs = ["different"]
        XCTAssertTrue(library.photos.isEmpty)
        XCTAssertTrue(library.albumTitles.isEmpty)
        library.selectedAlbumIDs = ["album"]
        held.complete(scan("stale"))
        await old.value
        XCTAssertTrue(library.photos.isEmpty)
        XCTAssertTrue(library.albumTitles.isEmpty)

        await library.load()
        XCTAssertEqual(library.photos.map(\.id), ["fresh"])
        XCTAssertEqual(calls, 3)
    }

    func testNewestScanWinsEvenWhenSelectionIsUnchangedAndOldScanIsEmpty() async {
        let access = Access(.authorized)
        let held = heldScan()
        var calls = 0
        let library = library(access: access, scan: { _ in
            calls += 1
            return calls == 1 ? await held.value() : self.scan("latest")
        })
        library.selectedAlbumIDs = ["album"]
        let first = Task { await library.load() }
        await fulfillment(of: [held.started], timeout: 2)
        await library.load()
        held.complete(LocalPhotoScan(photos: [], albumTitles: [:]))
        await first.value

        XCTAssertEqual(library.photos.map(\.id), ["latest"])
        XCTAssertEqual(library.albumTitles, ["latest": "Album"])
        XCTAssertEqual(calls, 2)
    }

    func testChangingBackupSelectionDoesNotInvalidateUnrelatedLibraryCounts() async throws {
        let access = Access(.authorized)
        let held = heldCounts()
        let library = library(access: access, counts: { await held.value() })
        let revision = library.revision
        let read = Task { try await library.statusCounts() }
        await fulfillment(of: [held.started], timeout: 2)

        library.selectedAlbumIDs = ["new-backup-selection"]
        held.complete(.init(assets: 42, albums: 3))
        let counts = try await read.value

        XCTAssertEqual(counts.assets, 42)
        XCTAssertEqual(counts.albums, 3)
        XCTAssertEqual(library.revision, revision)
    }

    func testLogoutAndNewSessionSelectionRejectTheOldScan() async {
        let access = Access(.authorized)
        let held = heldScan()
        var calls = 0
        let library = library(access: access, scan: { _ in
            calls += 1
            return calls == 1 ? await held.value() : self.scan("new-session")
        })
        library.selectedAlbumIDs = ["album"]
        let first = Task { await library.load() }
        await fulfillment(of: [held.started], timeout: 2)
        library.resetForLogout()
        library.selectedAlbumIDs = ["album"]
        await library.load()
        held.complete(scan("prior-session"))
        await first.value

        XCTAssertEqual(library.photos.map(\.id), ["new-session"])
        XCTAssertEqual(library.albumTitles, ["new-session": "Album"])
    }

    func testSameLimitedPermissionLibraryChangeRejectsAnOldSubsetAndAllowsFreshScan() async {
        let access = Access(.limited)
        let held = heldScan()
        var calls = 0
        let library = library(access: access, scan: { _ in
            calls += 1
            if calls == 2 { return await held.value() }
            return self.scan(calls == 1 ? "previously-readable" : "new-subset")
        })
        library.selectedAlbumIDs = ["album"]
        await library.load()
        let first = Task { await library.load() }
        await fulfillment(of: [held.started], timeout: 2)

        library.libraryDidChange()
        XCTAssertTrue(library.photos.isEmpty)
        XCTAssertTrue(library.albumTitles.isEmpty)
        await library.load()
        held.complete(scan("no-longer-readable"))
        await first.value

        XCTAssertEqual(library.authorizationStatus, .limited)
        XCTAssertTrue(library.isAuthorized)
        XCTAssertEqual(library.photos.map(\.id), ["new-subset"])
        XCTAssertEqual(library.albumTitles, ["new-subset": "Album"])
    }

    func testPermissionRevokedDuringScanClearsCacheAndRejectsLatePhotos() async {
        let access = Access(.authorized)
        let held = heldScan()
        var calls = 0
        let library = library(access: access, scan: { _ in
            calls += 1
            return calls == 1 ? self.scan("cached") : await held.value()
        })
        library.selectedAlbumIDs = ["album"]
        await library.load()
        let pending = Task { await library.load() }
        await fulfillment(of: [held.started], timeout: 2)
        access.status = .denied
        held.complete(scan("late"))
        await pending.value

        XCTAssertEqual(library.authorizationStatus, .denied)
        XCTAssertFalse(library.isAuthorized)
        XCTAssertTrue(library.photos.isEmpty)
        XCTAssertTrue(library.albumTitles.isEmpty)
    }

    func testRegrantAndNewScanCannotBeOverwrittenByPreRevocationResult() async {
        let access = Access(.authorized)
        let held = heldScan()
        var calls = 0
        let library = library(access: access, scan: { _ in
            calls += 1
            return calls == 1 ? await held.value() : self.scan("current-access")
        })
        library.selectedAlbumIDs = ["album"]
        let old = Task { await library.load() }
        await fulfillment(of: [held.started], timeout: 2)
        access.status = .denied
        library.refreshAuthorizationStatus()
        access.status = .authorized
        await library.load()
        held.complete(scan("old-access"))
        await old.value

        XCTAssertTrue(library.isAuthorized)
        XCTAssertEqual(library.photos.map(\.id), ["current-access"])
    }

    func testOldPermissionCallbackCannotOverrideTheCurrentLiveAuthorization() async {
        let access = Access(.notDetermined)
        let permission = heldPermission()
        let library = library(access: access, request: { await permission.value() })
        let pending = Task { await library.requestAccess() }
        await fulfillment(of: [permission.started], timeout: 2)
        access.status = .restricted
        permission.complete(.authorized)

        let allowed = await pending.value
        XCTAssertFalse(allowed)
        XCTAssertEqual(library.authorizationStatus, .restricted)
        XCTAssertFalse(library.isAuthorized)
    }

    func testFirstPermissionGrantReadsTheCurrentLibraryWithoutAnotherPrompt() async throws {
        let access = Access(.notDetermined)
        var prompts = 0
        var reads = 0
        let library = library(access: access, request: {
            prompts += 1
            access.status = .limited
            return .limited
        }, counts: {
            reads += 1
            return .init(assets: 2, albums: 1)
        })

        let first = try await library.statusCounts()
        let second = try await library.statusCounts()

        XCTAssertEqual(first.assets, 2)
        XCTAssertEqual(second.assets, 2)
        XCTAssertEqual(library.authorizationStatus, .limited)
        XCTAssertTrue(library.isAuthorized)
        XCTAssertEqual(prompts, 1)
        XCTAssertEqual(reads, 2)
    }

    func testFirstFullPermissionGrantAllowsTheInitialSelectedAlbumScanToPublish() async {
        let access = Access(.notDetermined)
        var prompts = 0
        var scans = 0
        let library = library(access: access, request: {
            prompts += 1
            access.status = .authorized
            return .authorized
        }, scan: { ids in
            scans += 1
            XCTAssertEqual(ids, ["selected"])
            return self.scan("first-photo")
        })
        library.selectedAlbumIDs = ["selected"]

        await library.load()

        XCTAssertEqual(library.authorizationStatus, .authorized)
        XCTAssertTrue(library.isAuthorized)
        XCTAssertEqual(library.photos.map(\.id), ["first-photo"])
        XCTAssertEqual(library.albumTitles, ["first-photo": "Album"])
        XCTAssertEqual(prompts, 1)
        XCTAssertEqual(scans, 1)
    }

    func testAuthorizationTransitionsAndLibraryEventsNotifyConsumersOnce() {
        let access = Access(.denied)
        let library = library(access: access)
        var changes = 0
        library.onLibraryChange = { changes += 1 }

        library.refreshAuthorizationStatus()
        XCTAssertEqual(changes, 0)
        access.status = .limited
        library.refreshAuthorizationStatus()
        XCTAssertEqual(changes, 1)
        library.refreshAuthorizationStatus()
        XCTAssertEqual(changes, 1)
        library.libraryDidChange()
        XCTAssertEqual(changes, 2, "The limited subset can change without changing permission status")
        access.status = .restricted
        library.libraryDidChange()
        XCTAssertEqual(changes, 3, "One PhotoKit event must not also emit a duplicate status callback")
        XCTAssertFalse(library.isAuthorized)
    }

    func testDeniedAndRestrictedReadsDoNotEnumerateButReadableEmptyLibrariesAreValid() async throws {
        for status in [PHAuthorizationStatus.denied, .restricted, .authorized, .limited] {
            let access = Access(status)
            var reads = 0
            var prompts = 0
            let library = library(access: access, request: {
                prompts += 1
                return status
            }, scan: { _ in
                reads += 1
                return LocalPhotoScan(photos: [], albumTitles: [:])
            }, albums: {
                reads += 1
                return []
            }, counts: {
                reads += 1
                return LocalLibraryStatusCounts(assets: 0, albums: 0)
            }, allPhotos: {
                reads += 1
                return []
            })
            library.selectedAlbumIDs = ["album"]
            await library.load()
            let albums = await library.albums()
            let photos = await library.photos(inAlbum: "album")
            let allPhotos = await library.allPhotosForSync()
            XCTAssertTrue(albums.isEmpty)
            XCTAssertTrue(photos.isEmpty)
            XCTAssertTrue(allPhotos.isEmpty)
            if status == .authorized || status == .limited {
                let counts = try await library.statusCounts()
                XCTAssertEqual(counts.assets, 0)
                XCTAssertEqual(counts.albums, 0)
                XCTAssertEqual(reads, 5)
                XCTAssertTrue(library.isAuthorized)
            } else {
                do {
                    _ = try await library.statusCounts()
                    XCTFail("Unavailable access cannot be reported as an empty library")
                } catch LocalPhotoLibraryError.accessRequired {} catch {
                    XCTFail("Unexpected error: \(error)")
                }
                XCTAssertEqual(reads, 0)
                XCTAssertFalse(library.isAuthorized)
            }
            XCTAssertEqual(library.authorizationStatus, status)
            XCTAssertEqual(prompts, 0, "Determined permission should not be requested again")
        }
    }

    func testCountsRevokedDuringReadThrowInsteadOfReturningZeroOrStaleSuccess() async throws {
        let access = Access(.authorized)
        let held = heldCounts()
        var reads = 0
        let library = library(access: access, counts: {
            reads += 1
            return reads == 1 ? await held.value() : LocalLibraryStatusCounts(assets: 3, albums: 1)
        })
        let pending = Task { try await library.statusCounts() }
        await fulfillment(of: [held.started], timeout: 2)
        access.status = .denied
        held.complete(LocalLibraryStatusCounts(assets: 0, albums: 0))
        do {
            _ = try await pending.value
            XCTFail("A revoked read must not produce a successful count")
        } catch LocalPhotoLibraryError.accessRequired {} catch {
            XCTFail("Unexpected error: \(error)")
        }
        XCTAssertFalse(library.isAuthorized)
        access.status = .limited
        let fresh = try await library.statusCounts()
        XCTAssertEqual(fresh.assets, 3)
        XCTAssertEqual(fresh.albums, 1)
        XCTAssertEqual(reads, 2)
    }

    func testCountsRejectChangedLibraryButAStableRetryReturnsTheNewCounts() async throws {
        let access = Access(.authorized)
        let held = heldCounts()
        var reads = 0
        let library = library(access: access, counts: {
            reads += 1
            return reads == 1 ? await held.value() : .init(assets: 4, albums: 2)
        })
        let old = Task { try await library.statusCounts() }
        await fulfillment(of: [held.started], timeout: 2)
        library.libraryDidChange()
        held.complete(.init(assets: 100, albums: 10))
        do {
            _ = try await old.value
            XCTFail("The count no longer describes the current library")
        } catch LocalPhotoLibraryError.libraryChanged {} catch {
            XCTFail("Unexpected error: \(error)")
        }

        let fresh = try await library.statusCounts()
        XCTAssertEqual(fresh.assets, 4)
        XCTAssertEqual(fresh.albums, 2)
        XCTAssertTrue(library.isAuthorized)
    }

    func testRevocationDuringEachMetadataReadDiscardsThePayloadAndAllowsReadableRetry() async {
        for kind in 0..<3 {
            let access = Access(.authorized)
            let photoRead = heldScan()
            let albumRead: Held<[LocalAlbum]> = held(fallback: [])
            var reads = 0
            let current = scan("current-photo")
            let currentAlbums = [LocalAlbum(id: "current-album", title: "Current", count: 1)]
            let library = library(access: access, scan: { _ in
                reads += 1
                return reads == 1 ? await photoRead.value() : current
            }, albums: {
                reads += 1
                return reads == 1 ? await albumRead.value() : currentAlbums
            }, allPhotos: {
                reads += 1
                return reads == 1 ? await photoRead.value().photos : current.photos
            })
            let read: () async -> [String] = {
                switch kind {
                case 0: return await library.albums().map(\.id)
                case 1: return await library.photos(inAlbum: "album").map(\.id)
                default: return await library.allPhotosForSync().map(\.id)
                }
            }
            let pending = Task { await read() }
            await fulfillment(of: [kind == 0 ? albumRead.started : photoRead.started], timeout: 2)
            access.status = .denied
            albumRead.complete([LocalAlbum(id: "old-album", title: "Old", count: 100)])
            photoRead.complete(scan("old-photo"))
            let rejected = await pending.value
            XCTAssertTrue(rejected.isEmpty, "Read kind \(kind) must discard data from revoked access")
            XCTAssertFalse(library.isAuthorized)

            access.status = .limited
            let retried = await read()
            XCTAssertEqual(retried, kind == 0 ? ["current-album"] : ["current-photo"])
            XCTAssertTrue(library.isAuthorized)
            XCTAssertEqual(reads, 2)
        }
    }

    func testCancelledScanCannotPublishAndFreshRetryStillWorks() async {
        let access = Access(.authorized)
        let held = heldScan()
        var calls = 0
        let library = library(access: access, scan: { _ in
            calls += 1
            return calls == 1 ? await held.value() : self.scan("retry")
        })
        library.selectedAlbumIDs = ["album"]
        let cancelled = Task { await library.load() }
        await fulfillment(of: [held.started], timeout: 2)
        cancelled.cancel()
        held.complete(scan("cancelled"))
        await cancelled.value
        XCTAssertTrue(library.photos.isEmpty)
        XCTAssertTrue(library.albumTitles.isEmpty)

        await library.load()
        XCTAssertEqual(library.photos.map(\.id), ["retry"])
        XCTAssertEqual(calls, 2)
    }

    private func library(
        access: Access,
        request: (() async -> PHAuthorizationStatus)? = nil,
        scan: ((Set<String>) async -> LocalPhotoScan)? = nil,
        albums: (() async -> [LocalAlbum])? = nil,
        counts: (() async -> LocalLibraryStatusCounts)? = nil,
        allPhotos: (() async -> [LocalPhoto])? = nil
    ) -> LocalPhotoLibrary {
        let suite = "LocalPhotoLibraryLifecycleTests.\(UUID().uuidString)"
        suites.append(suite)
        return LocalPhotoLibrary(defaults: UserDefaults(suiteName: suite)!, reader: .init(
            authorizationStatus: { access.status },
            requestAuthorization: request ?? { XCTFail("Unexpected permission prompt"); return access.status },
            photosInAlbums: scan ?? { _ in XCTFail("Unexpected photo enumeration"); return .init(photos: [], albumTitles: [:]) },
            albums: albums ?? { XCTFail("Unexpected album enumeration"); return [] },
            statusCounts: counts ?? { XCTFail("Unexpected count enumeration"); return .init(assets: 0, albums: 0) },
            allPhotos: allPhotos ?? { XCTFail("Unexpected all-photo enumeration"); return [] }))
    }

    private func scan(_ id: String, album: String = "Album") -> LocalPhotoScan {
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        return LocalPhotoScan(photos: [LocalPhoto(id: id, createdAt: date, modifiedAt: date,
            isVideo: false, isLivePhoto: false, duration: nil, ratio: 1)], albumTitles: [id: album])
    }

    private func heldScan() -> Held<LocalPhotoScan> {
        held(fallback: LocalPhotoScan(photos: [], albumTitles: [:]))
    }

    private func heldPermission() -> Held<PHAuthorizationStatus> { held(fallback: .denied) }
    private func heldCounts() -> Held<LocalLibraryStatusCounts> {
        held(fallback: LocalLibraryStatusCounts(assets: 0, albums: 0))
    }

    private func held<Value>(fallback: Value) -> Held<Value> {
        let worker = Held(fallback: fallback)
        closeWorkers.append { worker.close() }
        return worker
    }

    private final class Access {
        var status: PHAuthorizationStatus
        init(_ status: PHAuthorizationStatus) { self.status = status }
    }

    private final class Held<Value> {
        let started = XCTestExpectation(description: "PhotoKit worker started")
        private let fallback: Value
        private var continuation: CheckedContinuation<Value, Never>?
        private var result: Value?

        init(fallback: Value) { self.fallback = fallback }
        func value() async -> Value {
            started.fulfill()
            if let result { return result }
            return await withCheckedContinuation { continuation = $0 }
        }
        func complete(_ value: Value) {
            result = value
            continuation?.resume(returning: value)
            continuation = nil
        }
        func close() { complete(fallback) }
    }
}
