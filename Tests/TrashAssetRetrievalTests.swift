import Foundation
import XCTest
@testable import ImmichApp

@MainActor
final class TrashAssetRetrievalTests: XCTestCase {
    private var directory: URL!
    private var store: SwiftDataManager!
    private var session: MockSessionManager!
    private var transport: URLSession!
    private var repository: TrashRepository!
    private var snapshotKeys: [String] = []

    override func setUp() async throws {
        try await super.setUp()
        MockURLProtocol.reset()
        RemovedAssets.shared.clear()
        DeletedServerAssetRegistry.shared.clear()
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("trash-query-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        store = SwiftDataManager(storeURL: directory.appendingPathComponent("test.store"),
            backupJournalURL: directory.appendingPathComponent("backup.json"))
        XCTAssertTrue(store.isPersistentStoreAvailable)
        session = MockSessionManager()
        try session.setServer("https://trash-query.example")
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        transport = URLSession(configuration: configuration)
        repository = TrashRepository(api: APIClient(session: session, urlSession: transport), dataManager: store)
    }

    override func tearDown() async throws {
        transport?.invalidateAndCancel()
        repository = nil
        transport = nil
        session = nil
        store = nil
        for key in snapshotKeys { LocalSnapshot.remove(key) }
        snapshotKeys.removeAll()
        try? FileManager.default.removeItem(at: directory)
        directory = nil
        MockURLProtocol.reset()
        RemovedAssets.shared.clear()
        DeletedServerAssetRegistry.shared.clear()
        try await super.tearDown()
    }

    func testTrashQueryIncludesArchivedPhotosAndPreservesFiltersAcrossActualContinuationPages() async throws {
        var bodies: [[String: Any]] = []
        MockURLProtocol.responseProvider = { request in
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.url?.path, "/api/search/metadata")
            let body = Self.body(request)
            bodies.append(body)
            let page = body["page"] as? Int ?? 0
            guard page == 1 || page == 4 else {
                XCTFail("Trash must follow the actual server continuation")
                return Self.response(request, items: [], status: 500)
            }
            var items = [Self.asset(page == 1 ? "ordinary" : "archived",
                visibility: page == 1 ? "timeline" : "archive")]
            if let requestedVisibility = body["visibility"] as? String {
                items = items.filter { $0["visibility"] as? String == requestedVisibility }
            }
            return Self.response(request, items: items, next: page == 1 ? "4" : nil)
        }

        let items = try await repository.assets()

        XCTAssertEqual(items.map(\.id), ["ordinary", "archived"])
        XCTAssertEqual(items.last?.visibility, "archive", "Restore needs the original visibility classification")
        XCTAssertEqual(items.last?.isArchived, true)
        XCTAssertEqual(bodies.compactMap { $0["page"] as? Int }, [1, 4])
        XCTAssertTrue(bodies.allSatisfy { $0["visibility"] == nil })
        XCTAssertTrue(bodies.allSatisfy { $0["withDeleted"] as? Bool == true })
        XCTAssertTrue(bodies.allSatisfy { $0["trashedAfter"] as? String == "1970-01-01T00:00:00.000Z" })
        XCTAssertTrue(bodies.allSatisfy { $0["withExif"] as? Bool == true })
        XCTAssertTrue(bodies.allSatisfy { $0["size"] as? Int == 200 })
        XCTAssertTrue(bodies.allSatisfy { $0["order"] as? String == "desc" })
    }

    func testOnlyTrashedOrdinaryAndArchivedRowsCanEnterTheCollection() async throws {
        MockURLProtocol.responseProvider = { request in
            Self.response(request, items: [
                Self.asset("ordinary"), Self.asset("archive", visibility: "archive"),
                Self.asset("legacy-archive", visibility: nil, archived: true),
                Self.asset("legacy-ordinary", visibility: nil),
                Self.asset("live", trashed: false),
                Self.asset("locked", visibility: "locked"), Self.asset("hidden", visibility: "hidden"),
                Self.asset("unknown", visibility: "future-private-visibility"),
            ])
        }

        let items = try await repository.assets()

        XCTAssertEqual(items.map(\.id), ["ordinary", "archive", "legacy-archive", "legacy-ordinary"])
        XCTAssertTrue(items.allSatisfy(\.isTrashed))
        XCTAssertEqual(store.cachedAssetCount(), 0,
            "Reading Trash must not restore its rows to the timeline")
        XCTAssertEqual(DeletedServerAssetRegistry().suppressedIDs,
            ["ordinary", "archive", "legacy-archive", "legacy-ordinary", "locked", "hidden", "unknown"],
            "Current private Trash rows must also suppress stale library/device copies after relaunch")
    }

    func testPrivateOnlyPagesDoNotHideAnArchivedPhotoOnALaterPage() async throws {
        var pages: [Int] = []
        MockURLProtocol.responseProvider = { request in
            let page = Self.body(request)["page"] as? Int ?? 0
            pages.append(page)
            switch page {
            case 1: return Self.response(request, items: [Self.asset("locked", visibility: "locked")], next: "3")
            case 3: return Self.response(request, items: [Self.asset("hidden", visibility: "hidden")], next: "8")
            case 8: return Self.response(request, items: [Self.asset("archived", visibility: "archive")])
            default: return Self.response(request, items: [], status: 500)
            }
        }

        let items = try await repository.assets()

        XCTAssertEqual(items.map(\.id), ["archived"])
        XCTAssertEqual(pages, [1, 3, 8])
    }

    func testCurrentPrivacyAndRemovalStateOverrideTrashResponseRows() async throws {
        let privateIDs: Set<String> = ["known-private", "archive-labelled-private", "timeline-labelled-private",
            "malformed-live-private"]
        try store.setAssetVisibility(Array(privateIDs), to: "locked")
        try store.setAssetVisibility(["known-archive"], to: "archive")
        RemovedAssets.shared.remove(["unavailable"])
        RemovedAssets.shared.remove(["soft-deleted"], reason: .trashed)
        DeletedServerAssetRegistry.shared.record(["permanent"], permanently: true)
        DeletedServerAssetRegistry.shared.record(["soft-deleted"], permanently: false)
        MockURLProtocol.responseProvider = { request in
            Self.response(request, items: [Self.asset("known-private", visibility: nil),
                Self.asset("archive-labelled-private", visibility: "archive"),
                Self.asset("timeline-labelled-private", visibility: "timeline"),
                Self.asset("known-archive", visibility: "archive"), Self.asset("unavailable"),
                Self.asset("permanent"), Self.asset("soft-deleted"),
                Self.asset("malformed-live-private", trashed: false)])
        }

        let items = try await repository.assets()

        XCTAssertEqual(items.map(\.id), ["known-archive", "soft-deleted"])
        XCTAssertEqual(store.privateAssetIDs, privateIDs,
            "Trash metadata cannot release privacy protection, including malformed live response rows")
        XCTAssertTrue(DeletedServerAssetRegistry.shared.isPermanentlyDeleted("permanent"))
        XCTAssertTrue(DeletedServerAssetRegistry.shared.isTrashed("soft-deleted"))
    }

    func testALockAcceptedWhileTrashIsLoadingCannotBeUndoneByItsOlderResponse() async throws {
        let started = expectation(description: "Trash response is held")
        let release = DispatchSemaphore(value: 0)
        MockURLProtocol.responseProvider = { request in
            started.fulfill()
            guard release.wait(timeout: .now() + 5) == .success else {
                return (nil, nil, URLError(.timedOut))
            }
            return Self.response(request, items: [Self.asset("locked-during-load"), Self.asset("kept")])
        }
        let repo = try XCTUnwrap(repository)
        let load = Task { try await repo.assets() }
        addTeardownBlock { release.signal(); _ = try? await load.value }
        await fulfillment(of: [started], timeout: 2)
        try store.setAssetVisibility(["locked-during-load"], to: "locked")
        release.signal()

        let items = try await load.value

        XCTAssertEqual(items.map(\.id), ["kept"])
        XCTAssertEqual(store.privateAssetIDs, ["locked-during-load"])
        XCTAssertTrue(DeletedServerAssetRegistry.shared.suppressedIDs.isEmpty,
            "A response predating a local mutation must not write deletion markers")
    }

    func testAnOlderTrashResponseCannotReinsertARestoredPhotoButAFreshRetrashCan() async throws {
        RemovedAssets.shared.remove(["restored"], reason: .trashed)
        DeletedServerAssetRegistry.shared.record(["restored"], permanently: false)
        let started = expectation(description: "Trash response predates restore")
        let release = DispatchSemaphore(value: 0)
        MockURLProtocol.responseProvider = { request in
            started.fulfill()
            guard release.wait(timeout: .now() + 5) == .success else {
                return (nil, nil, URLError(.timedOut))
            }
            return Self.response(request, items: [Self.asset("restored"), Self.asset("kept")])
        }
        let repo = try XCTUnwrap(repository)
        let load = Task { try await repo.assets() }
        addTeardownBlock { release.signal(); _ = try? await load.value }
        await fulfillment(of: [started], timeout: 2)
        RemovedAssets.shared.restoreFromTrash(["restored"])
        DeletedServerAssetRegistry.shared.restore(["restored"])
        release.signal()

        do {
            _ = try await load.value
            XCTFail("A response predating a restore cannot publish an older Trash collection")
        } catch is CancellationError {} catch { XCTFail("Expected cancellation, received \(error)") }
        XCTAssertTrue(RemovedAssets.shared.contains("restored", scope: .trash))
        XCTAssertFalse(RemovedAssets.shared.contains("restored", scope: .library))
        XCTAssertTrue(DeletedServerAssetRegistry.shared.suppressedIDs.isEmpty,
            "An older GET cannot undo a confirmed restore or write unrelated deletion markers")

        MockURLProtocol.responseProvider = { request in
            Self.response(request, items: [Self.asset("restored", visibility: "archive")])
        }
        let currentItems = try await repository.assets()

        XCTAssertEqual(currentItems.map(\.id), ["restored"])
        XCTAssertFalse(RemovedAssets.shared.contains("restored", scope: .trash))
        XCTAssertTrue(RemovedAssets.shared.contains("restored", scope: .library))
        XCTAssertTrue(DeletedServerAssetRegistry().isTrashed("restored"))
    }

    func testAcceptedBulkActionsCancelOlderQueriesEvenWhenNoTrashIDsAreKnownLocally() async throws {
        for restoring in [true, false] {
            RemovedAssets.shared.clear()
            DeletedServerAssetRegistry.shared.clear()
            let received = expectation(description: "Validated Trash response is held before bulk action")
            let api = HeldValidatedTrashReadClient(session: session, urlSession: transport, received: received)
            let repo = TrashRepository(api: api, dataManager: store)
            let model = AssetGridViewModel(assetRepo: AssetDetailRepository(api: api, dataManager: store),
                albumRepo: AlbumRepository(api: api), dataManager: store) { [] }
            let bulkPath = restoring ? "/api/trash/restore" : "/api/trash/empty"
            var paths: [String] = []
            MockURLProtocol.responseProvider = { request in
                let path = request.url?.path ?? ""
                paths.append(path)
                if path == "/api/search/metadata" {
                    return Self.response(request, items: [Self.asset("before-bulk")])
                }
                XCTAssertEqual(path, bulkPath)
                return (Data(), HTTPURLResponse(url: request.url!, statusCode: 204,
                    httpVersion: nil, headerFields: nil), nil)
            }
            let load = Task { try await repo.assets() }
            addTeardownBlock { await api.release(); _ = try? await load.value }
            await fulfillment(of: [received], timeout: 2)
            XCTAssertTrue(model.assets.isEmpty)
            XCTAssertTrue(RemovedAssets.shared.ids.isEmpty)
            XCTAssertTrue(DeletedServerAssetRegistry.shared.suppressedIDs.isEmpty)

            let succeeded: Bool
            if restoring { succeeded = await model.restoreAll(using: repo) }
            else { succeeded = await model.emptyTrash(using: repo) }
            XCTAssertTrue(succeeded)
            XCTAssertNil(model.actionError)
            api.release()

            do {
                _ = try await load.value
                XCTFail("An accepted bulk action must cancel its older Trash response")
            } catch is CancellationError {} catch { XCTFail("Expected cancellation, received \(error)") }
            XCTAssertFalse(RemovedAssets.shared.contains("before-bulk"))
            XCTAssertFalse(DeletedServerAssetRegistry.shared.isTrashed("before-bulk"))

            MockURLProtocol.responseProvider = { request in
                paths.append(request.url?.path ?? "")
                return Self.response(request, items: [Self.asset("fresh-after-bulk")])
            }
            let fresh = try await repo.assets()

            XCTAssertEqual(fresh.map(\.id), ["fresh-after-bulk"])
            XCTAssertTrue(DeletedServerAssetRegistry.shared.isTrashed("fresh-after-bulk"))
            XCTAssertEqual(paths, ["/api/search/metadata", bulkPath, "/api/search/metadata"])
        }
    }

    func testAnAssetMutationWhileTrashLoadsPreventsDurableReclassification() async throws {
        let started = expectation(description: "Trash response predates an asset mutation")
        let release = DispatchSemaphore(value: 0)
        MockURLProtocol.responseProvider = { request in
            started.fulfill()
            guard release.wait(timeout: .now() + 5) == .success else {
                return (nil, nil, URLError(.timedOut))
            }
            return Self.response(request, items: [Self.asset("old-query-row"),
                Self.asset("stale-private-row", visibility: "locked")])
        }
        let repo = try XCTUnwrap(repository)
        let load = Task { try await repo.assets() }
        addTeardownBlock { release.signal(); _ = try? await load.value }
        await fulfillment(of: [started], timeout: 2)
        try store.patchCachedAsset("unrelated", isFavorite: true)
        release.signal()

        let items = try await load.value

        XCTAssertEqual(items.map(\.id), ["old-query-row"])
        XCTAssertFalse(RemovedAssets.shared.contains("old-query-row"))
        XCTAssertTrue(store.privateAssetIDs.isEmpty,
            "A response predating a mutation cannot publish raw private classifications")
        XCTAssertTrue(DeletedServerAssetRegistry.shared.suppressedIDs.isEmpty)
    }

    func testAccountOrSnapshotChangesRejectHeldTrashResults() async throws {
        for changesAccount in [false, true] {
            let currentSession = MockSessionManager()
            try currentSession.setServer("https://held-trash.example")
            let current = TrashRepository(api: APIClient(session: currentSession, urlSession: transport), dataManager: store)
            let started = expectation(description: "Trash is held before account/snapshot change")
            let release = DispatchSemaphore(value: 0)
            MockURLProtocol.responseProvider = { request in
                started.fulfill()
                guard release.wait(timeout: .now() + 5) == .success else {
                    return (nil, nil, URLError(.timedOut))
                }
                return Self.response(request, items: [Self.asset("old-account")])
            }
            let load = Task { try await current.assets() }
            addTeardownBlock { release.signal(); _ = try? await load.value }
            await fulfillment(of: [started], timeout: 2)
            if changesAccount { try currentSession.setServer("https://next-trash.example") }
            else { LocalSnapshot.clearAll() }
            release.signal()
            do {
                _ = try await load.value
                XCTFail("An old Trash request cannot return another account's collection")
            } catch is CancellationError {} catch { XCTFail("Expected cancellation, received \(error)") }
            XCTAssertFalse(RemovedAssets.shared.contains("old-account"))
            XCTAssertFalse(DeletedServerAssetRegistry.shared.isTrashed("old-account"))
        }
    }

    func testLaterPageFailureKeepsThePreviousTrashSnapshotAndAllowsAFreshCompleteRetry() async throws {
        let key = "trash-retrieval-\(UUID())"
        snapshotKeys.append(key)
        let previous = AssetLite(makeTestAsset(id: "previous"))
        LocalSnapshot.save([previous], for: key)
        var failSecond = true
        var pages: [Int] = []
        MockURLProtocol.responseProvider = { request in
            let page = Self.body(request)["page"] as? Int ?? 0
            pages.append(page)
            if page == 1 { return Self.response(request, items: [Self.asset("ordinary")], next: "4") }
            if page == 4 {
                return failSecond ? Self.response(request, items: [], status: 503)
                    : Self.response(request, items: [Self.asset("archive", visibility: "archive")])
            }
            return Self.response(request, items: [], status: 500)
        }
        let api = APIClient(session: session, urlSession: transport)
        let repo = try XCTUnwrap(repository)
        let model = AssetGridViewModel(assetRepo: AssetDetailRepository(api: api, dataManager: store),
            albumRepo: AlbumRepository(api: api), snapshotKey: key, dataManager: store) {
                try await repo.assets().map(AssetLite.init)
            }

        await model.load()
        XCTAssertEqual(model.assets.map(\.id), ["previous"])
        XCTAssertEqual(LocalSnapshot.load([AssetLite].self, for: key)?.map(\.id), ["previous"])
        XCTAssertNotNil(model.phase.value)
        XCTAssertTrue(DeletedServerAssetRegistry.shared.suppressedIDs.isEmpty,
            "A failed later page cannot publish partial deletion markers")
        failSecond = false
        await model.load()

        XCTAssertEqual(model.assets.map(\.id), ["ordinary", "archive"])
        XCTAssertEqual(LocalSnapshot.load([AssetLite].self, for: key)?.map(\.id), ["ordinary", "archive"])
        XCTAssertEqual(pages, [1, 4, 1, 4])
        XCTAssertNotNil(model.phase.value)
    }

    func testRawPrivateTrashEvidenceSurvivesRestoreAllForCachedAndMappedCopies() async throws {
        let visibilities = ["locked", "hidden", "future-private-visibility"]
        let ids = visibilities.map { "raw-private-\($0)" }
        for id in ids {
            try store.restoreToTimeline([AssetLite(makeTestAsset(id: id))])
            try store.linkDeviceAsset(localIdentifier: "device-\(id)", to: id)
        }
        XCTAssertTrue(store.privateAssetIDs.isEmpty, "Only this query supplies private visibility evidence")
        MockURLProtocol.responseProvider = { request in
            if request.url?.path == "/api/search/metadata" {
                return Self.response(request, items: zip(ids, visibilities).map { Self.asset($0.0, visibility: $0.1) })
            }
            XCTAssertEqual(request.url?.path, "/api/trash/restore")
            XCTAssertEqual(request.httpMethod, "POST")
            return (Data(), HTTPURLResponse(url: request.url!, statusCode: 204,
                httpVersion: nil, headerFields: nil), nil)
        }
        let api = APIClient(session: session, urlSession: transport)
        let repo = try XCTUnwrap(repository)
        let model = AssetGridViewModel(assetRepo: AssetDetailRepository(api: api, dataManager: store),
            albumRepo: AlbumRepository(api: api), dataManager: store) {
                try await repo.assets().map(AssetLite.init)
            }
        await model.load()
        XCTAssertTrue(model.assets.isEmpty)
        XCTAssertEqual(store.privateAssetIDs, Set(ids))
        XCTAssertEqual(DeletedServerAssetRegistry.shared.trashedIDs, Set(ids))
        let before = AssetVisibilityPolicy(dataManager: store)
        for id in ids {
            XCTAssertFalse(before.allows(id: id))
            XCTAssertFalse(before.allows(id: "device:device-\(id)"))
        }

        let succeeded = await model.restoreAll(using: repo)

        XCTAssertTrue(succeeded)
        XCTAssertEqual(MockURLProtocol.lastRequest?.url?.path, "/api/trash/restore")
        XCTAssertTrue(DeletedServerAssetRegistry.shared.trashedIDs.isEmpty)
        let after = AssetVisibilityPolicy(dataManager: store)
        for id in ids {
            XCTAssertFalse(after.allows(id: id), "A restored private server row must stay private")
            XCTAssertFalse(after.allows(id: "device:device-\(id)"), "A restored private device copy must stay private")
        }
        XCTAssertTrue(store.timelineAssets().isEmpty, "Stale cached private rows must never reenter the timeline")
        let reopened = SwiftDataManager(storeURL: directory.appendingPathComponent("test.store"),
            backupJournalURL: directory.appendingPathComponent("backup.json"))
        XCTAssertEqual(reopened.privateAssetIDs, Set(ids), "Raw private Trash evidence must survive reopening")
        XCTAssertTrue(reopened.timelineAssets().isEmpty)
        XCTAssertTrue(DeletedServerAssetRegistry().suppressedIDs.isEmpty,
            "Private classification must protect restored rows without leftover deletion markers")
        let reopenedPolicy = AssetVisibilityPolicy(dataManager: reopened)
        for id in ids {
            XCTAssertFalse(reopenedPolicy.allows(id: id))
            XCTAssertFalse(reopenedPolicy.allows(id: "device:device-\(id)"))
        }
    }

    func testLaterPrivateDuplicatesHideEarlierPublicRowsAndProtectMappedCopies() async throws {
        for (visibility, isTrashed) in [("locked", true), ("hidden", true),
            ("future-private-visibility", true), ("locked", false)] {
            let id = "later-private-\(visibility)-\(isTrashed)"
            try store.restoreToTimeline([AssetLite(makeTestAsset(id: id))])
            try store.linkDeviceAsset(localIdentifier: "local-\(id)", to: id)
            var pages: [Int] = []
            MockURLProtocol.responseProvider = { request in
                if request.url?.path == "/api/trash/restore" {
                    XCTAssertEqual(request.httpMethod, "POST")
                    return (Data(), HTTPURLResponse(url: request.url!, statusCode: 204,
                        httpVersion: nil, headerFields: nil), nil)
                }
                let page = Self.body(request)["page"] as? Int ?? 0
                pages.append(page)
                if page == 1 { return Self.response(request, items: [Self.asset(id)], next: "4") }
                XCTAssertEqual(page, 4)
                return Self.response(request, items: [Self.asset(id, visibility: visibility, trashed: isTrashed),
                    Self.asset("public-\(id)")])
            }

            let result = try await repository.assets()

            XCTAssertEqual(result.map(\.id), ["public-\(id)"],
                "A later private row must override an earlier public duplicate")
            XCTAssertEqual(pages, [1, 4])
            XCTAssertTrue(store.privateAssetIDs.contains(id))
            let policy = AssetVisibilityPolicy(dataManager: store)
            XCTAssertFalse(policy.allows(id: id))
            XCTAssertFalse(policy.allows(id: "device:local-\(id)"))
            let api = APIClient(session: session, urlSession: transport)
            let model = AssetGridViewModel(assetRepo: AssetDetailRepository(api: api, dataManager: store),
                albumRepo: AlbumRepository(api: api), dataManager: store) { result.map(AssetLite.init) }
            await model.load()
            let restored = await model.restoreAll(using: repository)
            XCTAssertTrue(restored)
            XCTAssertTrue(DeletedServerAssetRegistry.shared.suppressedIDs.isEmpty,
                "Deletion markers must not be left behind as a substitute for private classification")
            XCTAssertFalse(policy.allows(id: id))
            XCTAssertFalse(policy.allows(id: "device:local-\(id)"))
            let reopened = SwiftDataManager(storeURL: directory.appendingPathComponent("test.store"),
                backupJournalURL: directory.appendingPathComponent("backup.json"))
            XCTAssertTrue(reopened.privateAssetIDs.contains(id))
            let reopenedPolicy = AssetVisibilityPolicy(dataManager: reopened)
            XCTAssertFalse(reopenedPolicy.allows(id: id))
            XCTAssertFalse(reopenedPolicy.allows(id: "device:local-\(id)"))
            XCTAssertFalse(reopened.timelineAssets().contains { $0.asset.id == id })
        }
    }

    func testPrivateDuplicateStillWinsWhenANewerMutationPreventsPersistence() async throws {
        let received = expectation(description: "First raw page is held before a newer mutation")
        let api = HeldValidatedTrashReadClient(session: session, urlSession: transport, received: received)
        let repo = TrashRepository(api: api, dataManager: store)
        MockURLProtocol.responseProvider = { request in
            if Self.body(request)["page"] as? Int == 1 {
                return Self.response(request, items: [Self.asset("changed-duplicate")], next: "4")
            }
            return Self.response(request, items: [Self.asset("changed-duplicate", visibility: "locked"),
                Self.asset("retained-public")])
        }
        let read = Task { try await repo.assets() }
        addTeardownBlock { await api.release(); _ = try? await read.value }
        await fulfillment(of: [received], timeout: 2)
        try store.patchCachedAsset("unrelated", isFavorite: true)
        api.release()

        let result = try await read.value

        XCTAssertEqual(result.map(\.id), ["retained-public"],
            "Raw privacy must still filter the response when its stale context cannot write classifications")
        XCTAssertTrue(store.privateAssetIDs.isEmpty)
        XCTAssertTrue(DeletedServerAssetRegistry.shared.suppressedIDs.isEmpty)
        XCTAssertTrue(RemovedAssets.shared.ids.isEmpty)
    }

    func testRepeatedPublicRowsRemainUniqueAndKeepTheirArchiveEvidence() async throws {
        MockURLProtocol.responseProvider = { request in
            if Self.body(request)["page"] as? Int == 1 {
                return Self.response(request, items: [Self.asset("repeated-public")], next: "4")
            }
            return Self.response(request, items: [Self.asset("repeated-public", visibility: "archive"),
                Self.asset("another-public"), Self.asset("another-public")])
        }

        let result = try await repository.assets()

        XCTAssertEqual(result.map(\.id), ["repeated-public", "another-public"])
        XCTAssertEqual(result.first?.visibility, "archive")
        XCTAssertEqual(AssetLite(try XCTUnwrap(result.first)).trashVisibility, "archive")
        XCTAssertTrue(store.privateAssetIDs.isEmpty)
    }

    private nonisolated static func body(_ request: URLRequest) -> [String: Any] {
        let bytes = request.httpBody ?? MockURLProtocol.lastRequestBody ?? Data()
        return (try? JSONSerialization.jsonObject(with: bytes)) as? [String: Any] ?? [:]
    }

    private nonisolated static func asset(_ id: String, visibility: String? = "timeline",
        archived: Bool = false, trashed: Bool = true) -> [String: Any] {
        var value: [String: Any] = ["id": id, "type": "IMAGE", "originalFileName": "\(id).jpg",
            "fileCreatedAt": "2026-10-01T00:00:00.000Z", "localDateTime": "2026-10-01T00:00:00.000Z",
            "isFavorite": false, "isArchived": archived || visibility == "archive", "isTrashed": trashed]
        if let visibility { value["visibility"] = visibility }
        return value
    }

    private nonisolated static func response(_ request: URLRequest, items: [[String: Any]], next: String? = nil,
        status: Int = 200) -> (Data?, HTTPURLResponse?, Error?) {
        let data = try! JSONSerialization.data(withJSONObject: ["assets": ["items": items,
            "total": items.count, "nextPage": next as Any? ?? NSNull()]])
        return (data, HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil), nil)
    }
}

private final class HeldValidatedTrashReadClient: APIClient {
    private let received: XCTestExpectation
    private var continuation: CheckedContinuation<Void, Never>?
    private var holdsNextRead = true

    @MainActor
    init(session: SessionManager, urlSession: URLSession, received: XCTestExpectation) {
        self.received = received
        super.init(session: session, urlSession: urlSession)
    }

    @MainActor
    override func send<T: Decodable>(_ endpoint: Endpoint) async throws -> T {
        let result: T = try await super.send(endpoint)
        if holdsNextRead {
            holdsNextRead = false
            received.fulfill()
            await withCheckedContinuation { continuation = $0 }
        }
        return result
    }

    @MainActor
    func release() {
        continuation?.resume()
        continuation = nil
    }
}
