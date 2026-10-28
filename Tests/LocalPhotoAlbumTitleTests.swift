import Photos
import XCTest
@testable import ImmichApp

@MainActor
final class LocalPhotoAlbumTitleTests: XCTestCase {
    private var suites: [String] = []

    override func tearDown() async throws {
        for suite in suites { UserDefaults.standard.removePersistentDomain(forName: suite) }
        suites.removeAll()
        try await super.tearDown()
    }

    func testColdSelectedAlbumLookupFindsAndCachesNamesWithoutPublishingPhotos() async throws {
        let access = AlbumTitleAccess(.authorized)
        var reads = 0
        let library = library(access: access) { ids in
            XCTAssertEqual(ids, ["selected"])
            reads += 1
            return self.scan(["first": "Camera", "second": "Trips"])
        }
        library.selectedAlbumIDs = ["selected"]
        XCTAssertTrue(library.albumTitles.isEmpty)
        XCTAssertTrue(library.photos.isEmpty)

        let first = try await library.sourceAlbumTitle(for: LocalPhotoLibrary.assetID(for: "first"))
        let second = try await library.sourceAlbumTitle(for: "second")

        XCTAssertEqual(first, "Camera")
        XCTAssertEqual(second, "Trips")
        XCTAssertEqual(reads, 1, "One selected-album metadata scan serves the whole queued batch")
        XCTAssertEqual(library.albumTitles, ["first": "Camera", "second": "Trips"])
        XCTAssertTrue(library.photos.isEmpty)
        XCTAssertEqual(access.prompts, 0)
    }

    func testKnownMissingAssetAndEmptySelectionDoNotRepeatMetadataScans() async throws {
        let access = AlbumTitleAccess(.limited)
        var reads = 0
        let library = library(access: access) { _ in
            reads += 1
            return self.scan(["selected-photo": "Camera"])
        }
        let empty = try await library.sourceAlbumTitle(for: "unselected-photo")
        XCTAssertNil(empty)
        XCTAssertEqual(reads, 0)
        library.selectedAlbumIDs = ["selected"]

        let missing = try await library.sourceAlbumTitle(for: "unselected-photo")
        let missingAgain = try await library.sourceAlbumTitle(for: "another-unselected-photo")

        XCTAssertNil(missing)
        XCTAssertNil(missingAgain)
        XCTAssertEqual(reads, 1)
        XCTAssertTrue(library.photos.isEmpty)
    }

    func testOrdinaryLoadProvidesAValidFastPathUntilPhotoKitChanges() async throws {
        let access = AlbumTitleAccess(.authorized)
        var reads = 0
        let library = library(access: access) { _ in
            reads += 1
            return reads == 1
                ? self.scan(["photo": "Old Name"])
                : self.scan(["photo": "Renamed", "metadata-only": "Renamed"])
        }
        library.selectedAlbumIDs = ["selected"]
        await library.load()
        let cached = try await library.sourceAlbumTitle(for: "photo")
        XCTAssertEqual(cached, "Old Name")
        XCTAssertEqual(reads, 1)
        XCTAssertEqual(library.photos.map(\.id), ["photo"])

        library.libraryDidChange()
        let refreshed = try await library.sourceAlbumTitle(for: "photo")

        XCTAssertEqual(refreshed, "Renamed")
        XCTAssertEqual(reads, 2, "An authorized library change must invalidate even a nonempty title cache")
        XCTAssertEqual(library.albumTitles["metadata-only"], "Renamed")
        XCTAssertEqual(library.photos.map(\.id), ["photo"], "Metadata lookup must not replace the timeline array")
    }

    func testDeniedAndRestrictedAccessCannotReadOrReuseCachedTitles() async throws {
        for denied in [PHAuthorizationStatus.denied, .restricted] {
            let access = AlbumTitleAccess(.authorized)
            var reads = 0
            let library = library(access: access) { _ in
                reads += 1
                return self.scan(["photo": "Camera"])
            }
            library.selectedAlbumIDs = ["selected"]
            let allowed = try await library.sourceAlbumTitle(for: "photo")
            XCTAssertEqual(allowed, "Camera")
            access.status = denied

            do {
                _ = try await library.sourceAlbumTitle(for: "photo")
                XCTFail("Revoked access cannot use a previously cached title")
            } catch LocalPhotoLibraryError.accessRequired {}

            XCTAssertEqual(reads, 1)
            XCTAssertTrue(library.albumTitles.isEmpty)
            XCTAssertTrue(library.photos.isEmpty)
            XCTAssertEqual(access.prompts, 0)
        }
    }

    func testRevocationDuringMetadataReadRejectsItsPayloadAndAllowsAReadableRetry() async throws {
        let access = AlbumTitleAccess(.authorized)
        let held = AlbumTitleReadGate()
        var reads = 0
        let library = library(access: access) { _ in
            reads += 1
            return reads == 1 ? await held.value() : self.scan(["photo": "Current"])
        }
        library.selectedAlbumIDs = ["selected"]
        let read = Task { try await library.sourceAlbumTitle(for: "photo") }
        addTeardownBlock { read.cancel(); await held.close(); _ = try? await read.value }
        await fulfillment(of: [held.started], timeout: 2)
        access.status = .denied
        held.complete(scan(["photo": "No Longer Readable"]))

        do {
            _ = try await read.value
            XCTFail("A completed scan cannot publish after permission is revoked")
        } catch LocalPhotoLibraryError.accessRequired {}
        XCTAssertTrue(library.albumTitles.isEmpty)
        XCTAssertTrue(library.photos.isEmpty)
        access.status = .limited
        let retried = try await library.sourceAlbumTitle(for: "photo")
        XCTAssertEqual(retried, "Current")
        XCTAssertEqual(reads, 2)
    }

    func testSelectionChangesIncludingReturningToTheOriginalSelectionRejectHeldMetadata() async throws {
        for returnsToOriginal in [false, true] {
            let access = AlbumTitleAccess(.authorized)
            let held = AlbumTitleReadGate()
            var reads = 0
            let library = library(access: access) { _ in
                reads += 1
                return reads == 1 ? await held.value() : self.scan(["photo": "Current Selection"])
            }
            library.selectedAlbumIDs = ["original"]
            let read = Task { try await library.sourceAlbumTitle(for: "photo") }
            addTeardownBlock { read.cancel(); await held.close(); _ = try? await read.value }
            await fulfillment(of: [held.started], timeout: 2)
            library.selectedAlbumIDs = ["changed"]
            if returnsToOriginal { library.selectedAlbumIDs = ["original"] }
            held.complete(scan(["photo": "Stale Selection"]))
            await assertLibraryChanged(read)

            XCTAssertTrue(library.albumTitles.isEmpty)
            let retried = try await library.sourceAlbumTitle(for: "photo")
            XCTAssertEqual(retried, "Current Selection")
            XCTAssertEqual(reads, 2)
            XCTAssertTrue(library.photos.isEmpty)
        }
    }

    func testLogoutRejectsHeldMetadataBeforeTheNextAccountsSelectionIsRead() async throws {
        let access = AlbumTitleAccess(.authorized)
        let held = AlbumTitleReadGate()
        var reads = 0
        let library = library(access: access) { _ in
            reads += 1
            return reads == 1 ? await held.value() : self.scan(["photo": "New Account Selection"])
        }
        library.selectedAlbumIDs = ["selected"]
        let read = Task { try await library.sourceAlbumTitle(for: "photo") }
        addTeardownBlock { read.cancel(); await held.close(); _ = try? await read.value }
        await fulfillment(of: [held.started], timeout: 2)
        library.resetForLogout()
        library.selectedAlbumIDs = ["selected"]
        held.complete(scan(["photo": "Previous Account Selection"]))
        await assertLibraryChanged(read)

        XCTAssertTrue(library.albumTitles.isEmpty)
        let current = try await library.sourceAlbumTitle(for: "photo")
        XCTAssertEqual(current, "New Account Selection")
        XCTAssertTrue(library.photos.isEmpty)
    }

    func testCanceledMetadataReadCannotPublishButAQueuedRetryCanReadItsAlbum() async throws {
        let access = AlbumTitleAccess(.authorized)
        let held = AlbumTitleReadGate()
        var reads = 0
        let library = library(access: access) { _ in
            reads += 1
            return reads == 1 ? await held.value() : self.scan(["photo": "Retry Album"])
        }
        library.selectedAlbumIDs = ["selected"]
        let read = Task { try await library.sourceAlbumTitle(for: "photo") }
        addTeardownBlock { read.cancel(); await held.close(); _ = try? await read.value }
        await fulfillment(of: [held.started], timeout: 2)
        read.cancel()
        held.complete(scan(["photo": "Canceled Album"]))

        do {
            _ = try await read.value
            XCTFail("Cancellation must prevent caching metadata")
        } catch is CancellationError {}
        XCTAssertTrue(library.albumTitles.isEmpty)
        let current = try await library.sourceAlbumTitle(for: "photo")
        XCTAssertEqual(current, "Retry Album")
        XCTAssertEqual(reads, 2)
    }

    func testANewerTimelineLoadCannotBeOverwrittenByAnOlderMetadataOnlyRead() async throws {
        let access = AlbumTitleAccess(.authorized)
        let held = AlbumTitleReadGate()
        var reads = 0
        let library = library(access: access) { _ in
            reads += 1
            return reads == 1 ? await held.value() : self.scan(["photo": "New Timeline Scan"])
        }
        library.selectedAlbumIDs = ["selected"]
        let read = Task { try await library.sourceAlbumTitle(for: "photo") }
        addTeardownBlock { read.cancel(); await held.close(); _ = try? await read.value }
        await fulfillment(of: [held.started], timeout: 2)
        await library.load()
        held.complete(scan(["photo": "Obsolete Metadata"]))
        await assertLibraryChanged(read)

        XCTAssertEqual(library.albumTitles, ["photo": "New Timeline Scan"])
        XCTAssertEqual(library.photos.map(\.id), ["photo"])
        let cached = try await library.sourceAlbumTitle(for: "photo")
        XCTAssertEqual(cached, "New Timeline Scan")
        XCTAssertEqual(reads, 2)
    }

    func testFirstPermissionGrantCanResolveAnAlbumWithoutStartingATimelineLoad() async throws {
        let access = AlbumTitleAccess(.notDetermined)
        let library = library(access: access, request: {
            access.status = .authorized
            return .authorized
        }) { _ in self.scan(["photo": "First Grant"]) }
        library.selectedAlbumIDs = ["selected"]

        let name = try await library.sourceAlbumTitle(for: "photo")

        XCTAssertEqual(name, "First Grant")
        XCTAssertEqual(access.prompts, 1)
        XCTAssertTrue(library.photos.isEmpty)
    }

    private func assertLibraryChanged(
        _ task: Task<String?, Error>, file: StaticString = #filePath, line: UInt = #line
    ) async {
        do {
            _ = try await task.value
            XCTFail("The superseded metadata scan must not publish its title", file: file, line: line)
        } catch LocalPhotoLibraryError.libraryChanged {} catch {
            XCTFail("Unexpected metadata error: \(error)", file: file, line: line)
        }
    }

    private func library(
        access: AlbumTitleAccess,
        request: (() async -> PHAuthorizationStatus)? = nil,
        scan: @escaping (Set<String>) async -> LocalPhotoScan
    ) -> LocalPhotoLibrary {
        let name = "LocalPhotoAlbumTitleTests.\(UUID())"
        suites.append(name)
        return LocalPhotoLibrary(defaults: UserDefaults(suiteName: name)!, reader: .init(
            authorizationStatus: { access.status },
            requestAuthorization: {
                access.prompts += 1
                if let request { return await request() }
                return access.status
            },
            photosInAlbums: scan))
    }

    private func scan(_ titles: [String: String]) -> LocalPhotoScan {
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let photos = titles.keys.sorted().map {
            LocalPhoto(id: $0, createdAt: date, modifiedAt: date,
                isVideo: false, isLivePhoto: false, duration: nil, ratio: 1)
        }
        return .init(photos: photos, albumTitles: titles)
    }
}

@MainActor
private final class AlbumTitleAccess {
    var status: PHAuthorizationStatus
    var prompts = 0
    init(_ status: PHAuthorizationStatus) { self.status = status }
}

@MainActor
private final class AlbumTitleReadGate {
    let started = XCTestExpectation(description: "Selected-album metadata is held")
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

    func close() { complete(.init(photos: [], albumTitles: [:])) }
}
