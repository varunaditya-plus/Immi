import Foundation
import Observation
import SwiftData
import XCTest
@testable import ImmichApp

@MainActor
final class AssistiveAccessLifecycleTests: XCTestCase {
    private var directory: URL!
    private var manager: SwiftDataManager!
    private var session: SessionManager!
    private var api: APIClient!
    private var transport: URLSession!
    private var suite: String!
    private var previousFavorites: [AssetLite]?
    private var albumKeys: [String] = []

    override func setUp() async throws {
        MockURLProtocol.reset()
        RemovedAssets.shared.clear()
        DeletedServerAssetRegistry.shared.clear()
        previousFavorites = LocalSnapshot.load([AssetLite].self, for: LocalSnapshot.Key.favorites)
        LocalSnapshot.remove(LocalSnapshot.Key.favorites)
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("assistive-lifecycle-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        manager = SwiftDataManager(storeURL: directory.appendingPathComponent("test.store"),
            backupJournalURL: directory.appendingPathComponent("backup.json"))
        suite = "assistive-lifecycle-\(UUID())"
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        transport = URLSession(configuration: configuration)
        session = SessionManager(urlSession: transport, defaults: try XCTUnwrap(UserDefaults(suiteName: suite)),
            dataManager: manager, restoresSession: false)
        try session.setServer("https://assistive-lifecycle.example.invalid")
        session.isLoggedIn = true
        api = APIClient(session: session, urlSession: transport)
    }

    override func tearDown() async throws {
        transport?.invalidateAndCancel()
        api = nil
        session = nil
        transport = nil
        let container = manager?.modelContainer
        manager = nil
        try container?.erase()
        if let directory { try FileManager.default.removeItem(at: directory) }
        if let suite { UserDefaults.standard.removePersistentDomain(forName: suite) }
        if let previousFavorites { LocalSnapshot.save(previousFavorites, for: LocalSnapshot.Key.favorites) }
        else { LocalSnapshot.remove(LocalSnapshot.Key.favorites) }
        for key in albumKeys { LocalSnapshot.remove(key) }
        albumKeys.removeAll()
        RemovedAssets.shared.clear()
        DeletedServerAssetRegistry.shared.clear()
        MockURLProtocol.reset()
        try await super.tearDown()
    }

    func testCurrentLoadPublishesChronologicalNetworkResultsAndTheCompletedSyncCache() async throws {
        let old = asset("old", at: 100), new = asset("new", at: 200), albumID = albumID()
        let reads = try respond(["favorites": [new, old], albumID: [new, old]])
        let model = AssistiveAccessViewModel(api: api, dataManager: manager, performSync: { [manager = manager!] in
            try? manager.restoreToTimeline([AssetLite(old), AssetLite(new)])
        })

        await model.load(showsFavorites: true, albumID: albumID)

        await fulfillment(of: Array(reads.values), timeout: 2)
        XCTAssertEqual(model.photos.map(\.id), [old.id, new.id])
        XCTAssertEqual(model.favorites.map(\.id), [old.id, new.id])
        XCTAssertEqual(model.album.map(\.id), [old.id, new.id])
        XCTAssertEqual(snapshot(LocalSnapshot.Key.favorites), [old.id, new.id])
        XCTAssertEqual(snapshot(LocalSnapshot.Key.album(albumID)), [old.id, new.id])
        XCTAssertTrue(model.isCurrent)
        XCTAssertFalse(model.isLoading)
    }

    func testSameAssetMetadataRefreshNotifiesEveryPublicSourceWhileLoadingRemainsFalse() async throws {
        let original = asset("metadata", at: 100), album = albumID()
        try manager.restoreToTimeline([AssetLite(original)])
        let initialReads = try respond(["favorites": [original], album: [original]])
        let firstSync = gate(), heldSync = gate()
        firstSync.complete(.success(()))
        let sequence = AssistiveSyncSequence([firstSync, heldSync])
        let model = AssistiveAccessViewModel(api: api, dataManager: manager, performSync: { await sequence.run() })
        await model.load(showsFavorites: true, albumID: album)
        await fulfillment(of: Array(initialReads.values), timeout: 2)
        XCTAssertFalse(model.isLoading)

        var changed = original
        changed.fileCreatedAt = Date(timeIntervalSince1970: 200)
        changed.isFavorite = false
        changed.exifInfo = try JSONDecoder().decode(ExifDTO.self,
            from: Data(#"{"exifImageWidth":200,"exifImageHeight":100}"#.utf8))
        var favorite = changed
        favorite.isFavorite = true
        let reads = try respond(["favorites": [favorite], album: [changed]])
        let refresh = Task { await model.load(showsFavorites: true, albumID: album) }
        addTeardownBlock { await heldSync.complete(.success(())); await refresh.value }
        await fulfillment(of: [heldSync.started] + Array(reads.values), timeout: 2)
        XCTAssertFalse(model.isLoading, "All three cached sources are full, so a busy-state notification cannot refresh this UI")
        XCTAssertEqual(model.photos.first?.createdAt, original.fileCreatedAt)
        XCTAssertEqual(model.favorites.first?.createdAt, original.fileCreatedAt)
        XCTAssertEqual(model.album.first?.createdAt, original.fileCreatedAt)
        try manager.restoreToTimeline([AssetLite(changed)])
        let photosChanged = expectation(description: "The same timeline ID publishes its new date and favorite")
        let favoritesChanged = expectation(description: "The same favorite ID publishes its new date and ratio")
        let albumChanged = expectation(description: "The same album ID publishes its new date and favorite")
        withObservationTracking { _ = model.photos.first?.createdAt } onChange: { photosChanged.fulfill() }
        withObservationTracking { _ = model.favorites.first?.ratio } onChange: { favoritesChanged.fulfill() }
        withObservationTracking { _ = model.album.first?.isFavorite } onChange: { albumChanged.fulfill() }

        heldSync.complete(.success(()))
        await refresh.value

        await fulfillment(of: [photosChanged, favoritesChanged, albumChanged], timeout: 2)
        XCTAssertFalse(model.isLoading)
        for source in [model.photos, model.favorites, model.album] {
            XCTAssertEqual(source.map(\.id), [original.id])
            XCTAssertEqual(source.first?.createdAt, changed.fileCreatedAt)
            XCTAssertEqual(source.first?.ratio, 2)
        }
        XCTAssertEqual(model.photos.first?.isFavorite, false)
        XCTAssertEqual(model.favorites.first?.isFavorite, true)
        XCTAssertEqual(model.album.first?.isFavorite, false)
    }

    func testAnOlderPreferenceLoadCannotOverwriteTheNewerAlbumOrGlobalFavoritesSnapshot() async throws {
        let originalFavorite = AssetLite(asset("cached-favorite")), oldFavorite = asset("old-favorite")
        let oldPhoto = asset("old-album"), newPhoto = asset("new-album")
        let oldAlbum = albumID(), newAlbum = albumID()
        LocalSnapshot.save([originalFavorite], for: LocalSnapshot.Key.favorites)
        let reads = try respond(["favorites": [oldFavorite], oldAlbum: [oldPhoto], newAlbum: [newPhoto]])
        let firstSync = gate(), secondSync = gate()
        let sequence = AssistiveSyncSequence([firstSync, secondSync])
        let model = AssistiveAccessViewModel(api: api, dataManager: manager, performSync: { await sequence.run() })
        let old = Task { await model.load(showsFavorites: true, albumID: oldAlbum) }
        addTeardownBlock { await firstSync.complete(.success(())); await old.value }
        await fulfillment(of: [firstSync.started, try XCTUnwrap(reads["favorites"]), try XCTUnwrap(reads[oldAlbum])], timeout: 2)
        let current = Task { await model.load(showsFavorites: false, albumID: newAlbum) }
        addTeardownBlock { await secondSync.complete(.success(())); await current.value }
        await fulfillment(of: [secondSync.started, try XCTUnwrap(reads[newAlbum])], timeout: 2)
        XCTAssertTrue(model.favorites.isEmpty)

        secondSync.complete(.success(()))
        await current.value
        XCTAssertEqual(model.album.map(\.id), [newPhoto.id])
        XCTAssertEqual(snapshot(LocalSnapshot.Key.album(newAlbum)), [newPhoto.id])
        XCTAssertEqual(snapshot(LocalSnapshot.Key.favorites), [originalFavorite.id],
            "Disabling an Assistive shortcut must not erase the app-wide offline Favorites cache")
        firstSync.complete(.success(()))
        await old.value

        XCTAssertTrue(model.favorites.isEmpty)
        XCTAssertEqual(model.album.map(\.id), [newPhoto.id])
        XCTAssertEqual(snapshot(LocalSnapshot.Key.album(newAlbum)), [newPhoto.id])
        XCTAssertNil(LocalSnapshot.load([AssetLite].self, for: LocalSnapshot.Key.album(oldAlbum)))
        XCTAssertEqual(snapshot(LocalSnapshot.Key.favorites), [originalFavorite.id])
        XCTAssertFalse(model.isLoading)
    }

    func testAnOlderLoadFinishingFirstCannotClearTheNewerLoadsBusyState() async throws {
        let firstAlbum = albumID(), secondAlbum = albumID()
        let oldPhoto = asset("old"), currentPhoto = asset("current")
        let reads = try respond([firstAlbum: [oldPhoto], secondAlbum: [currentPhoto]])
        let firstSync = gate(), secondSync = gate()
        let sequence = AssistiveSyncSequence([firstSync, secondSync])
        let model = AssistiveAccessViewModel(api: api, dataManager: manager, performSync: { await sequence.run() })
        let first = Task { await model.load(showsFavorites: false, albumID: firstAlbum) }
        addTeardownBlock { await firstSync.complete(.success(())); await first.value }
        await fulfillment(of: [firstSync.started, try XCTUnwrap(reads[firstAlbum])], timeout: 2)
        let second = Task { await model.load(showsFavorites: false, albumID: secondAlbum) }
        addTeardownBlock { await secondSync.complete(.success(())); await second.value }
        await fulfillment(of: [secondSync.started, try XCTUnwrap(reads[secondAlbum])], timeout: 2)
        XCTAssertTrue(model.isLoading)

        firstSync.complete(.success(()))
        await first.value

        XCTAssertTrue(model.isLoading, "The current held request still owns the loading indicator")
        XCTAssertTrue(model.album.isEmpty)
        XCTAssertNil(LocalSnapshot.load([AssetLite].self, for: LocalSnapshot.Key.album(firstAlbum)))
        secondSync.complete(.success(()))
        await second.value
        XCTAssertFalse(model.isLoading)
        XCTAssertEqual(model.album.map(\.id), [currentPhoto.id])
    }

    func testCancelledLoadDoesNotPublishCompletedHTTPResultsOrAReloadedSyncCache() async throws {
        let cached = asset("cached"), fresh = asset("fresh"), synced = asset("synced")
        try manager.restoreToTimeline([AssetLite(cached)])
        LocalSnapshot.save([AssetLite(cached)], for: LocalSnapshot.Key.favorites)
        let reads = try respond(["favorites": [fresh]])
        let held = gate()
        let model = AssistiveAccessViewModel(api: api, dataManager: manager, performSync: { _ = try? await held.value() })
        let pending = Task { await model.load(showsFavorites: true, albumID: "") }
        addTeardownBlock { await held.complete(.success(())); await pending.value }
        await fulfillment(of: [held.started, try XCTUnwrap(reads["favorites"])], timeout: 2)
        XCTAssertEqual(model.photos.map(\.id), [cached.id])
        XCTAssertEqual(model.favorites.map(\.id), [cached.id])
        try manager.restoreToTimeline([AssetLite(synced)])

        pending.cancel()
        held.complete(.success(()))
        await pending.value

        XCTAssertEqual(model.photos.map(\.id), [cached.id], "Cancellation cannot restore a newer sync cache into the abandoned load")
        XCTAssertEqual(model.favorites.map(\.id), [cached.id])
        XCTAssertEqual(snapshot(LocalSnapshot.Key.favorites), [cached.id])
        XCTAssertFalse(model.isLoading)
    }

    func testAccountGenerationImmediatelyHidesAllCachedResultsAndRejectsAHeldCompletion() async throws {
        let cached = asset("cached"), late = asset("late"), album = albumID()
        try manager.restoreToTimeline([AssetLite(cached)])
        LocalSnapshot.save([AssetLite(cached)], for: LocalSnapshot.Key.favorites)
        LocalSnapshot.save([AssetLite(cached)], for: LocalSnapshot.Key.album(album))
        let reads = try respond(["favorites": [late], album: [late]])
        let held = gate()
        let model = AssistiveAccessViewModel(api: api, dataManager: manager, performSync: { _ = try? await held.value() })
        let pending = Task { await model.load(showsFavorites: true, albumID: album) }
        addTeardownBlock { await held.complete(.success(())); await pending.value }
        await fulfillment(of: [held.started] + Array(reads.values), timeout: 2)
        XCTAssertEqual(model.photos.map(\.id), [cached.id])
        XCTAssertEqual(model.favorites.map(\.id), [cached.id])
        XCTAssertEqual(model.album.map(\.id), [cached.id])

        LocalSnapshot.clearAll()

        XCTAssertFalse(model.isCurrent)
        XCTAssertTrue(model.photos.isEmpty)
        XCTAssertTrue(model.favorites.isEmpty)
        XCTAssertTrue(model.album.isEmpty)
        XCTAssertFalse(model.isLoading)
        held.complete(.success(()))
        await pending.value
        XCTAssertTrue(model.photos.isEmpty)
        XCTAssertNil(LocalSnapshot.load([AssetLite].self, for: LocalSnapshot.Key.favorites))
        XCTAssertNil(LocalSnapshot.load([AssetLite].self, for: LocalSnapshot.Key.album(album)))
    }

    func testSameServerRevisionInvalidatesTheOldModelAndANewModelCanLoad() async throws {
        let cached = asset("cached")
        try manager.restoreToTimeline([AssetLite(cached)])
        let old = AssistiveAccessViewModel(api: api, dataManager: manager, performSync: {})
        await old.load(showsFavorites: false, albumID: "")
        XCTAssertEqual(old.photos.map(\.id), [cached.id])
        let generation = LocalSnapshot.generation, context = session.snapshot

        try session.setServer("https://assistive-lifecycle.example.invalid")

        XCTAssertEqual(LocalSnapshot.generation, generation)
        XCTAssertNotEqual(session.snapshot, context)
        XCTAssertFalse(old.isCurrent)
        XCTAssertTrue(old.photos.isEmpty)
        let replacement = AssistiveAccessViewModel(api: APIClient(session: session, urlSession: transport),
            dataManager: manager, performSync: {})
        await replacement.load(showsFavorites: false, albumID: "")
        XCTAssertTrue(replacement.isCurrent)
        XCTAssertEqual(replacement.photos.map(\.id), [cached.id])
        XCTAssertFalse(replacement.isLoading)
    }

    func testCachedFavoritesAndAlbumsObserveCurrentVisibilityAndDurableRemovalWithoutReloading() async throws {
        let ordinary = asset("ordinary"), archived = asset("archived"), locked = asset("locked"), album = albumID()
        let all = [ordinary, archived, locked].map(AssetLite.init)
        try manager.restoreToTimeline(all)
        LocalSnapshot.save(all, for: LocalSnapshot.Key.favorites)
        LocalSnapshot.save(all, for: LocalSnapshot.Key.album(album))
        MockURLProtocol.responseProvider = { _ in (nil, nil, URLError(.notConnectedToInternet)) }
        let model = AssistiveAccessViewModel(api: api, dataManager: manager, performSync: {})
        await model.load(showsFavorites: true, albumID: album)
        XCTAssertEqual(Set(model.photos.map(\.id)), Set(all.map(\.id)))
        XCTAssertEqual(Set(model.favorites.map(\.id)), Set(all.map(\.id)))
        XCTAssertEqual(Set(model.album.map(\.id)), Set(all.map(\.id)))
        let changed = expectation(description: "Cached favorites observe a new privacy restriction")
        withObservationTracking { _ = model.favorites } onChange: { changed.fulfill() }

        try manager.setAssetVisibility([locked.id], to: "locked")
        try manager.setAssetVisibility([archived.id], to: "archive")

        await fulfillment(of: [changed], timeout: 2)
        XCTAssertEqual(model.photos.map(\.id), [ordinary.id])
        XCTAssertEqual(model.favorites.map(\.id), [ordinary.id])
        XCTAssertEqual(Set(model.album.map(\.id)), [ordinary.id, archived.id])
        RemovedAssets.shared.remove([ordinary.id])
        XCTAssertTrue(model.photos.isEmpty)
        XCTAssertTrue(model.favorites.isEmpty)
        XCTAssertEqual(model.album.map(\.id), [archived.id])
        DeletedServerAssetRegistry.shared.record([archived.id], permanently: true)
        XCTAssertTrue(model.album.isEmpty)
    }

    private func asset(_ name: String, at time: TimeInterval = 100) -> AssetResponseDTO {
        var asset = makeTestAsset(id: "assistive-\(name)-\(UUID())", isFavorite: true)
        asset.fileCreatedAt = Date(timeIntervalSince1970: time)
        return asset
    }

    private func albumID() -> String {
        let id = UUID().uuidString
        albumKeys.append(LocalSnapshot.Key.album(id))
        return id
    }

    private func gate() -> PeopleStateGate<Void> {
        let gate = PeopleStateGate<Void>()
        addTeardownBlock { gate.complete(.success(())) }
        return gate
    }

    private func snapshot(_ key: String) -> [String] {
        LocalSnapshot.load([AssetLite].self, for: key)?.map(\.id) ?? []
    }

    private func respond(_ assets: [String: [AssetResponseDTO]]) throws -> [String: XCTestExpectation] {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let responses = try assets.mapValues { items in
            try JSONSerialization.data(withJSONObject: ["assets": [
                "items": try JSONSerialization.jsonObject(with: encoder.encode(items)),
                "total": items.count, "nextPage": NSNull(),
            ]])
        }
        let served = Dictionary(uniqueKeysWithValues: assets.keys.map { ($0, expectation(description: "The real metadata request for \($0) is served")) })
        MockURLProtocol.responseProvider = { request in
            guard request.httpMethod == "POST", request.url?.path == "/api/search/metadata",
                  let key = Self.responseKey(request), let data = responses[key] else {
                XCTFail("Unexpected Assistive metadata request: \(request)")
                return (nil, nil, URLError(.unsupportedURL))
            }
            served[key]?.fulfill()
            return (data, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil), nil)
        }
        return served
    }

    nonisolated private static func responseKey(_ request: URLRequest) -> String? {
        var data = request.httpBody ?? Data()
        if data.isEmpty, let stream = request.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                guard count >= 0 else { return nil }
                if count == 0 { break }
                data.append(contentsOf: buffer.prefix(count))
            }
        }
        guard let body = try? JSONSerialization.jsonObject(with: data) as? [String: Any], body["page"] as? Int == 1 else { return nil }
        return (body["albumIds"] as? [String])?.first ?? (body["isFavorite"] as? Bool == true ? "favorites" : nil)
    }
}

@MainActor
private final class AssistiveSyncSequence {
    private let gates: [PeopleStateGate<Void>]
    private var index = 0
    init(_ gates: [PeopleStateGate<Void>]) { self.gates = gates }

    func run() async {
        guard gates.indices.contains(index) else { XCTFail("An unexpected sync started"); return }
        let gate = gates[index]
        index += 1
        _ = try? await gate.value()
    }
}
