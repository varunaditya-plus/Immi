import SwiftUI
import XCTest
@testable import ImmichApp

@MainActor
final class TimelineDeviceActionTests: XCTestCase {
    private var directories: [URL] = []

    override func setUp() async throws {
        MockURLProtocol.reset()
        RemovedAssets.shared.clear()
        DeletedServerAssetRegistry.shared.clear()
    }

    override func tearDown() async throws {
        MockURLProtocol.reset()
        RemovedAssets.shared.clear()
        DeletedServerAssetRegistry.shared.clear()
        for directory in directories { try? FileManager.default.removeItem(at: directory) }
        directories.removeAll()
    }

    func testMappedFavoriteUsesServerIDAndSurvivesLocalFallbackRebuildUntilSync() async throws {
        let fixture = try await fixture()
        let displayID = fixture.mappedIDs[0]
        let asset = try XCTUnwrap(fixture.model.asset(for: displayID))
        fixture.respond(204)

        let accepted = await fixture.model.toggleFavorite(asset)

        XCTAssertTrue(accepted)
        XCTAssertEqual(MockURLProtocol.lastRequest?.url?.path, "/api/assets/\(fixture.mappedServerID)")
        XCTAssertEqual(try body()["isFavorite"] as? Bool, true)
        XCTAssertEqual(fixture.model.asset(for: displayID)?.isFavorite, true)
        XCTAssertEqual(fixture.model.sections.flatMap(\.assets).first(where: { $0.id == displayID })?.isFavorite, true)
        await fixture.model.loadTimeline()
        XCTAssertEqual(fixture.model.asset(for: displayID)?.isFavorite, true,
            "Rebuilding before the server row arrives must preserve the accepted favorite")
        try fixture.manager.restoreToTimeline([fixture.photo(fixture.mappedServerID)])
        await fixture.model.loadTimeline()
        XCTAssertNil(fixture.model.asset(for: displayID))
        XCTAssertEqual(fixture.model.asset(for: fixture.mappedServerID)?.isFavorite, false,
            "Once sync supplies the server row its metadata replaces the fallback overlay")
    }

    func testMappedArchiveAndLockUseServerIDsAndPersistVisibilityForLocalCopies() async throws {
        for locked in [false, true] {
            let fixture = try await fixture()
            let ids = [fixture.mappedIDs[0], fixture.serverID]
            var paths: [String] = []
            MockURLProtocol.responseProvider = { request in
                paths.append(request.url?.path ?? "")
                XCTAssertEqual(request.httpMethod, "PUT")
                XCTAssertEqual(Self.body(request)["visibility"] as? String, locked ? "locked" : "archive")
                return Self.response(request, status: 204)
            }

            let accepted: Bool
            if locked { accepted = await fixture.model.lockSelected(ids) }
            else { accepted = await fixture.model.archiveSelected(ids) }

            XCTAssertTrue(accepted)
            XCTAssertEqual(paths, ["/api/assets/\(fixture.mappedServerID)", "/api/assets/\(fixture.serverID)"])
            XCTAssertTrue(fixture.model.allAssets.isEmpty)
            await fixture.model.loadTimeline()
            XCTAssertTrue(fixture.model.allAssets.isEmpty)
            let reopened = fixture.reopen()
            if locked {
                XCTAssertEqual(reopened.privateAssetIDs, [fixture.mappedServerID, fixture.serverID])
            } else {
                XCTAssertEqual(reopened.archivedAssetIDs, [fixture.mappedServerID, fixture.serverID])
            }
            XCTAssertFalse(AssetVisibilityPolicy(scope: .timeline, dataManager: reopened).allows(id: fixture.mappedIDs[0]))
        }
    }

    func testMappedSingleArchiveUsesServerIdentityAndRemovesEveryAlias() async throws {
        let fixture = try await fixture(aliases: 2)
        fixture.respond(204)
        let first = try XCTUnwrap(fixture.model.asset(for: fixture.mappedIDs[0]))

        await fixture.model.archive(first)

        XCTAssertEqual(MockURLProtocol.lastRequest?.url?.path, "/api/assets/\(fixture.mappedServerID)")
        XCTAssertEqual(try body()["visibility"] as? String, "archive")
        XCTAssertEqual(fixture.model.allAssets.map(\.id), [fixture.serverID])
        XCTAssertTrue(fixture.reopen().archivedAssetIDs.contains(fixture.mappedServerID))
    }

    func testMixedSelectionDeduplicatesMappedServerIDsForFavoriteAndAlbumRequests() async throws {
        let fixture = try await fixture(aliases: 2)
        let ids = fixture.mappedIDs + [fixture.serverID]
        var favoritePaths: [String] = []
        MockURLProtocol.responseProvider = { request in
            favoritePaths.append(request.url?.path ?? "")
            return Self.response(request, status: 204)
        }

        let favored = await fixture.model.favoriteSelected(ids)

        XCTAssertTrue(favored)
        XCTAssertEqual(favoritePaths, ["/api/assets/\(fixture.mappedServerID)", "/api/assets/\(fixture.serverID)"])
        XCTAssertTrue(fixture.model.allAssets.allSatisfy(\.isFavorite))
        MockURLProtocol.responseProvider = { request in
            XCTAssertEqual(request.url?.path, "/api/albums/album/assets")
            XCTAssertEqual(request.httpMethod, "PUT")
            let ids = Self.body(request)["ids"] as? [String]
            XCTAssertEqual(ids, [fixture.mappedServerID, fixture.serverID])
            let data = try! JSONSerialization.data(withJSONObject: (ids ?? []).map { ["id": $0, "success": true] as [String: Any] })
            return Self.response(request, data: data)
        }

        let added = await fixture.model.addToAlbum(ids, album: fixture.album)

        XCTAssertTrue(added)
        XCTAssertNil(fixture.model.actionError)
        XCTAssertEqual(fixture.model.allAssets.count, 3)
    }

    func testSharedLinkUsesMappedServerIDsAndCurrentServerBase() async throws {
        let fixture = try await fixture(aliases: 2)
        MockURLProtocol.responseProvider = { request in
            XCTAssertEqual(request.url?.path, "/api/shared-links")
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(Self.body(request)["assetIds"] as? [String], [fixture.mappedServerID, fixture.serverID])
            return Self.response(request, data: Data(#"{"id":"link","key":"public-key","type":"INDIVIDUAL"}"#.utf8))
        }

        let url = await fixture.model.createSharedLink(for: fixture.mappedIDs + [fixture.serverID],
            using: SharedLinkRepository(api: fixture.api), baseURL: fixture.session.baseURL)

        XCTAssertEqual(url?.absoluteString, "https://timeline-actions.example/share/public-key")
        XCTAssertNil(fixture.model.actionError)
    }

    func testDeviceOnlyOrStaleMixedSelectionCannotSendServerRequests() async throws {
        let fixture = try await fixture(includeUnuploaded: true)
        MockURLProtocol.responseProvider = { request in
            XCTFail("An unsupported selection must not issue a server action: \(request)")
            return Self.response(request, status: 500)
        }
        let localOnly = try XCTUnwrap(fixture.model.asset(for: fixture.unuploadedID))
        let ids = [fixture.serverID, fixture.unuploadedID]
        let toggle = await fixture.model.toggleFavorite(localOnly)
        await fixture.model.archive(localOnly)
        let results = [toggle, await fixture.model.favoriteSelected(ids),
            await fixture.model.archiveSelected(ids), await fixture.model.lockSelected(ids),
            await fixture.model.addToAlbum(ids, album: fixture.album)]
        let link = await fixture.model.createSharedLink(for: ids,
            using: SharedLinkRepository(api: fixture.api), baseURL: fixture.session.baseURL)
        XCTAssertEqual(results, Array(repeating: false, count: 5))
        XCTAssertNil(link)
        XCTAssertNil(MockURLProtocol.lastRequest)
        XCTAssertEqual(fixture.model.allAssets.count, 3)
        XCTAssertFalse(fixture.model.allAssets.contains(where: \.isFavorite))
    }

    func testMenusExposeOnlySupportedActionsForDeviceAndMappedTiles() async throws {
        let fixture = try await fixture(includeUnuploaded: true)
        let view = TimelineView()
        let localMenu = view.menuActions(for: fixture.unuploadedID, fixture.model).map(\.title)
        XCTAssertEqual(localMenu, [String(localized: "Share"), String(localized: "Delete")])
        let mappedMenu = view.menuActions(for: fixture.mappedIDs[0], fixture.model).map(\.title)
        XCTAssertTrue(mappedMenu.contains(String(localized: "Favorite")))
        XCTAssertTrue(mappedMenu.contains(String(localized: "Archive")))
        XCTAssertTrue(mappedMenu.contains(String(localized: "Add to Album")))
        XCTAssertTrue(mappedMenu.contains(String(localized: "Share Link")))
        let mixed = view.selectionActions(for: [fixture.serverID, fixture.unuploadedID], fixture.model)
        XCTAssertNil(mixed.favorite)
        XCTAssertNil(mixed.archive)
        XCTAssertTrue(mixed.menu.isEmpty)
        XCTAssertNotNil(mixed.share)
        XCTAssertNotNil(mixed.trashConfirmation)
        XCTAssertNil(mixed.trashConfirmation?.message,
            "Recoverable server/device deletion must not carry an irreversible warning")
        let mapped = view.selectionActions(for: fixture.mappedIDs + [fixture.serverID], fixture.model)
        XCTAssertNotNil(mapped.favorite)
        XCTAssertNotNil(mapped.archive)
        XCTAssertEqual(mapped.menu.count, 3)
        XCTAssertNil(mapped.trashConfirmation?.message)
    }

    func testPrivateAndRemovedMappedTilesLoseServerCapabilitiesBeforeDispatch() async throws {
        for reason in ["private", "trashed"] {
            let fixture = try await fixture()
            if reason == "private" { try fixture.manager.setAssetVisibility([fixture.mappedServerID], to: "locked") }
            else { DeletedServerAssetRegistry.shared.record([fixture.mappedServerID], permanently: false) }
            XCTAssertNil(fixture.model.serverAssetIDs(for: fixture.mappedIDs))
            let accepted = await fixture.model.favoriteSelected(fixture.mappedIDs)
            XCTAssertFalse(accepted)
            XCTAssertNil(MockURLProtocol.lastRequest)
        }
    }

    func testPreviousAccountAndCancelledCallersCannotAdmitServerMutations() async throws {
        let fixture = try await fixture()
        LocalSnapshot.clearAll()
        let oldFavorite = await fixture.model.favoriteSelected(fixture.mappedIDs)
        let oldAlbum = await fixture.model.addToAlbum(fixture.mappedIDs, album: fixture.album)
        XCTAssertFalse(oldFavorite)
        XCTAssertFalse(oldAlbum)
        XCTAssertNil(MockURLProtocol.lastRequest)
        let current = try await self.fixture()
        let cancelled = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return await current.model.lockSelected(current.mappedIDs)
        }
        let accepted = await cancelled.value
        XCTAssertFalse(accepted)
        XCTAssertNil(MockURLProtocol.lastRequest)
    }

    func testMalformedBackupMappingsCannotBecomeServerTargetsAndAValidMappingSupersedesStaleOrigin() async throws {
        let fixture = try await fixture(includeUnuploaded: true)
        let asset = try XCTUnwrap(fixture.model.asset(for: fixture.unuploadedID))
        XCTAssertEqual(asset.origin, .device)
        let localID = LocalPhotoLibrary.localIdentifier(from: asset.id)
        for invalidID in ["", "device:nested-display-id"] {
            try fixture.manager.upsertBackupRecord(assetID: invalidID, checksum: "legacy-record", localIdentifier: localID)

            XCTAssertNil(AssetServerIdentity.resolve(asset, using: fixture.manager))
            XCTAssertNil(fixture.model.serverAssetIDs(for: [asset.id]))
            let accepted = await fixture.model.favoriteSelected([asset.id])
            XCTAssertFalse(accepted)
            XCTAssertNil(MockURLProtocol.lastRequest, "A malformed mapping cannot reach a server endpoint")
        }
        let serverID = UUID().uuidString
        try fixture.manager.upsertBackupRecord(assetID: serverID, checksum: "current-record", localIdentifier: localID)

        XCTAssertEqual(AssetServerIdentity.resolve(asset, using: fixture.manager), serverID)
        XCTAssertEqual(fixture.model.serverAssetIDs(for: [asset.id]), [serverID],
            "Current upload mappings take precedence over a tile's retained device-only origin")
    }

    func testAnAliasScanUsesOneSuppliedMappingSnapshotWhileLaterValidationReadsTheCurrentMapping() async throws {
        let fixture = try await fixture(aliases: 2)
        let assets = try fixture.mappedIDs.map { try XCTUnwrap(fixture.model.asset(for: $0)) }
        let snapshot = fixture.manager.serverAssetIDsByLocalIdentifier()
        let firstLocalID = LocalPhotoLibrary.localIdentifier(from: assets[0].id)
        try fixture.manager.upsertBackupRecord(assetID: "new-server", checksum: "new-checksum", localIdentifier: firstLocalID)

        XCTAssertEqual(assets.compactMap {
            AssetServerIdentity.resolve($0, using: fixture.manager, localMappings: snapshot)
        }, [fixture.mappedServerID, fixture.mappedServerID])
        XCTAssertEqual(AssetServerIdentity.resolve(assets[0], using: fixture.manager), "new-server",
            "Admission after an await must not reuse the alias scan's old mapping")
        XCTAssertNil(AssetServerIdentity.resolve(assets[0], using: fixture.manager, localMappings: [:]),
            "A missing snapshot entry must not fall through to per-item database fetches")
        for invalid in ["", "device:bad-server"] {
            XCTAssertNil(AssetServerIdentity.resolve(assets[0], using: fixture.manager,
                localMappings: [firstLocalID: invalid]))
        }
    }

    func testHeldFavoriteCannotApplyToARemappedTileOrPublishAnOlderAccountsError() async throws {
        for remaps in [true, false] {
            let fixture = try await fixture()
            let asset = try XCTUnwrap(fixture.model.asset(for: fixture.mappedIDs[0]))
            let started = expectation(description: "The mapped favorite request is held")
            let release = DispatchSemaphore(value: 0)
            MockURLProtocol.responseProvider = { request in
                XCTAssertEqual(request.url?.path, "/api/assets/\(fixture.mappedServerID)")
                started.fulfill()
                guard release.wait(timeout: .now() + 5) == .success else {
                    return (nil, nil, URLError(.timedOut))
                }
                return Self.response(request, status: remaps ? 204 : 403,
                    data: remaps ? Data() : Data(#"{"message":"Old account rejected"}"#.utf8))
            }
            let pending = Task { await fixture.model.toggleFavorite(asset) }
            addTeardownBlock { release.signal(); _ = await pending.value }
            await fulfillment(of: [started], timeout: 2)
            if remaps {
                try fixture.manager.upsertBackupRecord(assetID: "replacement-server", checksum: "checksum",
                    localIdentifier: LocalPhotoLibrary.localIdentifier(from: asset.id))
            } else { LocalSnapshot.clearAll() }
            release.signal()
            let accepted = await pending.value

            XCTAssertFalse(accepted)
            XCTAssertEqual(fixture.model.asset(for: asset.id)?.isFavorite, false)
            XCTAssertNil(fixture.manager.getCachedAsset(id: "replacement-server"))
            XCTAssertNil(fixture.model.actionError,
                "An old response must not publish feedback for a different target/account")
        }
    }

    func testDeviceAlbumDoesNotOfferAnEmptyFavoriteCallback() async throws {
        let assets = [AssetLite(id: "device:\(UUID())", isVideo: false, ratio: 1, thumbhash: nil,
            createdAt: .distantPast, origin: .device),
            AssetLite(id: "device:\(UUID())", isVideo: false, ratio: 1, thumbhash: nil,
                createdAt: .distantPast, origin: .both)]
        let view = DeviceAlbumDetailView(album: LocalAlbum(id: "local-album", title: "Camera", count: 2))
        let screen = view.collectionScreen(assets: assets, phase: .loaded(()), actionError: .constant(nil))
        for asset in assets {
            let titles = screen.menuActions(for: asset.id).map(\.title)
            XCTAssertFalse(titles.contains(String(localized: "Favorite")))
            XCTAssertFalse(titles.contains(String(localized: "Unfavorite")))
            XCTAssertTrue(titles.contains(String(localized: "Share")))
            XCTAssertTrue(titles.contains(String(localized: "Delete")))
            XCTAssertEqual(titles.contains(String(localized: "Upload")), asset.origin == .device)
        }
        var favored: [String] = []
        let called = expectation(description: "An ordinary collection still dispatches its favorite callback")
        let ordinary = PhotoCollectionScreen(title: "Ordinary", assets: [assets[0]], phase: .loaded(()),
            onRetry: {}, onToggleFavorite: { favored.append($0.id); called.fulfill() },
            onDelete: { _ in }, shareURLs: { _ in [] })
        let favorite = try XCTUnwrap(ordinary.menuActions(for: assets[0].id)
            .first { $0.title == String(localized: "Favorite") })
        favorite.handler()
        await fulfillment(of: [called], timeout: 2)
        XCTAssertEqual(favored, [assets[0].id])
    }

    private func body() throws -> [String: Any] {
        let data = try XCTUnwrap(MockURLProtocol.lastRequestBody)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private nonisolated static func body(_ request: URLRequest) -> [String: Any] {
        let data = request.httpBody ?? MockURLProtocol.lastRequestBody ?? Data()
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
    }

    private nonisolated static func response(_ request: URLRequest, status: Int = 200, data: Data = Data()) ->
        (Data?, HTTPURLResponse?, Error?) {
        (data, HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil), nil)
    }

    private func fixture(aliases: Int = 1, includeUnuploaded: Bool = false) async throws -> Fixture {
        let fixture = try Fixture(aliases: aliases, includeUnuploaded: includeUnuploaded)
        directories.append(fixture.directory)
        await fixture.model.loadTimeline()
        return fixture
    }

    @MainActor
    private final class Fixture {
        let directory: URL
        let manager: SwiftDataManager
        let api: APIClient
        let session: MockSessionManager
        let model: TimelineViewModel
        let mappedServerID = UUID().uuidString
        let serverID = UUID().uuidString
        let mappedIDs: [String]
        let unuploadedID = LocalPhotoLibrary.assetID(for: UUID().uuidString)
        let album = AlbumResponseDTO(id: "album", albumName: "Album", description: nil,
            assetCount: 0, albumThumbnailAssetId: nil, shared: false, createdAt: .distantPast, assets: nil)

        init(aliases: Int, includeUnuploaded: Bool) throws {
            directory = FileManager.default.temporaryDirectory.appendingPathComponent("timeline-device-actions-\(UUID())")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            manager = SwiftDataManager(storeURL: directory.appendingPathComponent("test.store"),
                backupJournalURL: directory.appendingPathComponent("backup.json"))
            XCTAssertTrue(manager.isPersistentStoreAvailable)
            let localIDs = (0..<aliases).map { _ in UUID().uuidString }
            mappedIDs = localIDs.map(LocalPhotoLibrary.assetID(for:))
            for localID in localIDs { try manager.linkDeviceAsset(localIdentifier: localID, to: mappedServerID) }
            try manager.restoreToTimeline([AssetLite(id: serverID, isVideo: false, ratio: 1, thumbhash: nil,
                createdAt: Date(timeIntervalSince1970: 1_700_000_000))])
            let ids = localIDs + (includeUnuploaded ? [LocalPhotoLibrary.localIdentifier(from: unuploadedID)] : [])
            let photos = ids.enumerated().map { index, id in LocalPhoto(id: id,
                createdAt: Date(timeIntervalSince1970: 1_700_000_100 + Double(index)),
                modifiedAt: .distantPast, isVideo: false, isLivePhoto: false, duration: nil, ratio: 1) }
            session = MockSessionManager()
            try session.setServer("https://timeline-actions.example")
            let config = URLSessionConfiguration.ephemeral
            config.protocolClasses = [MockURLProtocol.self]
            api = APIClient(session: session, urlSession: URLSession(configuration: config))
            model = TimelineViewModel(dataManager: manager,
                assetRepo: AssetDetailRepository(api: api, dataManager: manager),
                albumRepo: AlbumRepository(api: api), localPhotos: { photos })
        }

        func photo(_ id: String) -> AssetLite {
            AssetLite(id: id, isVideo: false, ratio: 1, thumbhash: nil, createdAt: .distantPast)
        }

        func respond(_ status: Int) {
            MockURLProtocol.responseProvider = { request in TimelineDeviceActionTests.response(request, status: status) }
        }

        func reopen() -> SwiftDataManager {
            SwiftDataManager(storeURL: directory.appendingPathComponent("test.store"),
                backupJournalURL: directory.appendingPathComponent("backup.json"))
        }
    }
}
