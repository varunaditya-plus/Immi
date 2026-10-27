import XCTest
@testable import ImmichApp

@MainActor
final class AssetDetailAsyncTests: XCTestCase {
    private let prefix = "viewer-\(UUID().uuidString)-"
    private var assetIDs = Set<String>()

    override func setUp() async throws {
        UnreadableAssets.shared.clear()
    }

    override func tearDown() async throws {
        for id in assetIDs { LocalSnapshot.remove(LocalSnapshot.Key.assetDetail(id)) }
        UnreadableAssets.shared.clear()
    }

    func testOldPhotoResponseCannotReplaceTheCurrentPhoto() async throws {
        let a = asset("a"), b = asset("b")
        let gate = DetailResultGate<AssetResponseDTO>(started: expectation(description: "A request started"))
        let repo = DetailRaceRepository()
        repo.fetch = { id in id == a.id ? try await gate.wait() : b }
        let model = AssetDetailViewModel(repo: repo)
        let old = Task { await model.load(a.id) }
        await fulfillment(of: [gate.started], timeout: 2)

        await model.load(b.id)
        gate.resolve(.success(a))
        await old.value

        XCTAssertEqual(model.detail?.id, b.id)
        XCTAssertEqual(cached(b.id)?.id, b.id)
        XCTAssertNil(cached(a.id), "A stale read must not overwrite its later snapshot")
        assertLoaded(model)
    }

    func testOldPhotoErrorCannotFailCurrentPhotoOrRemoveItsNewSnapshot() async throws {
        let a = asset("a"), b = asset("b")
        let gate = DetailResultGate<AssetResponseDTO>(started: expectation(description: "A request started"))
        let repo = DetailRaceRepository()
        repo.fetch = { id in id == a.id ? try await gate.wait() : b }
        let model = AssetDetailViewModel(repo: repo)
        let old = Task { await model.load(a.id) }
        await fulfillment(of: [gate.started], timeout: 2)
        await model.load(b.id)
        LocalSnapshot.save(asset("a", filename: "newer-a.jpg"), for: LocalSnapshot.Key.assetDetail(a.id))

        gate.resolve(.failure(APIError.server(status: 400, message: "Unreadable asset")))
        await old.value

        XCTAssertEqual(model.detail?.id, b.id)
        XCTAssertEqual(cached(a.id)?.originalFileName, "newer-a.jpg")
        XCTAssertNil(model.actionError)
        assertLoaded(model)
    }

    func testReturnVisitRejectsThePreviousVisitsResponse() async throws {
        let oldA = asset("a", filename: "old.jpg"), newA = asset("a", filename: "new.jpg")
        let gate = DetailResultGate<AssetResponseDTO>(started: expectation(description: "First A request started"))
        let repo = DetailRaceRepository()
        var requests = 0
        repo.fetch = { id in
            requests += 1
            return requests == 1 ? try await gate.wait() : newA
        }
        let model = AssetDetailViewModel(repo: repo)
        let firstVisit = model.selectAsset(oldA.id)
        let first = Task { await model.load(firstVisit) }
        await fulfillment(of: [gate.started], timeout: 2)
        _ = model.selectAsset(prefix + "b")
        let currentVisit = model.selectAsset(oldA.id)
        await model.load(currentVisit)
        gate.resolve(.success(oldA))
        await first.value

        XCTAssertFalse(model.isCurrent(firstVisit))
        XCTAssertTrue(model.isCurrent(currentVisit))
        XCTAssertEqual(model.detail?.originalFileName, "new.jpg")
        XCTAssertEqual(cached(oldA.id)?.originalFileName, "new.jpg")
    }

    func testSamePhotoRefreshRejectsAnOlderResponseWithoutChangingVisits() async throws {
        let oldA = asset("a", filename: "old.jpg"), newA = asset("a", filename: "new.jpg")
        let gate = DetailResultGate<AssetResponseDTO>(started: expectation(description: "Old refresh started"))
        let repo = DetailRaceRepository()
        var requests = 0
        repo.fetch = { _ in
            requests += 1
            return requests == 1 ? try await gate.wait() : newA
        }
        let model = AssetDetailViewModel(repo: repo)
        let selected = model.selectAsset(oldA.id)
        let old = Task { await model.load(selected) }
        await fulfillment(of: [gate.started], timeout: 2)
        await model.load(selected)
        gate.resolve(.success(oldA))
        await old.value

        XCTAssertTrue(model.isCurrent(selected))
        XCTAssertEqual(model.detail?.originalFileName, "new.jpg")
        XCTAssertEqual(cached(oldA.id)?.originalFileName, "new.jpg")
        XCTAssertEqual(requests, 2)
    }

    func testStaleSelectionIsRejectedBeforeStartingAnotherRequest() async {
        let a = asset("a"), b = asset("b")
        let repo = DetailRaceRepository()
        repo.fetch = { _ in XCTFail("The stale page must not issue a request"); return a }
        let model = AssetDetailViewModel(repo: repo)
        let old = model.selectAsset(a.id)
        let current = model.selectAsset(b.id)

        await model.load(old)

        XCTAssertTrue(model.isCurrent(current))
        XCTAssertTrue(repo.fetchRequests.isEmpty)
        XCTAssertNil(model.detail)
    }

    func testCurrentReadErrorStillFailsAndRemovesUnreadableSnapshot() async {
        let a = asset("a")
        LocalSnapshot.save(a, for: LocalSnapshot.Key.assetDetail(a.id))
        let repo = DetailRaceRepository()
        repo.fetch = { _ in throw APIError.server(status: 400, message: "Unreadable asset") }
        let model = AssetDetailViewModel(repo: repo)

        await model.load(a.id)

        if case .failed = model.phase { } else { XCTFail("Current errors must still be represented") }
        XCTAssertNil(cached(a.id))
        XCTAssertEqual(repo.fetchRequests, [a.id])
    }

    func testSelectingDevicePhotoImmediatelyClearsServerDetailsAndAlbums() async throws {
        let a = asset("a")
        let gate = DetailResultGate<[AlbumResponseDTO]>(started: expectation(description: "A albums started"))
        let repo = DetailRaceRepository()
        repo.fetch = { _ in a }
        let albums = DetailRaceAlbumsRepository()
        albums.containing = { _ in try await gate.wait() }
        let model = AssetDetailViewModel(repo: repo, albumRepo: albums)
        await model.load(a.id)
        model.containingAlbums = [album("existing")]
        let selected = model.selectAsset(a.id)
        let old = Task { await model.loadContainingAlbums(selected) }
        await fulfillment(of: [gate.started], timeout: 2)

        let device = model.selectAsset("device:local-photo")
        XCTAssertNil(model.detail)
        XCTAssertTrue(model.containingAlbums.isEmpty)
        await model.load(device)
        gate.resolve(.success([album("old-a")]))
        await old.value

        XCTAssertNil(model.detail)
        XCTAssertTrue(model.containingAlbums.isEmpty)
        XCTAssertEqual(repo.fetchRequests, [a.id], "Device photos have no server detail endpoint")
        assertLoaded(model)
    }

    func testContainingAlbumResponsesFollowPhotoAndRequestRevisions() async throws {
        let a = asset("a"), b = asset("b")
        let gate = DetailResultGate<[AlbumResponseDTO]>(started: expectation(description: "A albums started"))
        let albums = DetailRaceAlbumsRepository()
        albums.containing = { id in id == a.id ? try await gate.wait() : [self.album("b-album")] }
        let model = AssetDetailViewModel(repo: DetailRaceRepository(), albumRepo: albums)
        let oldSelection = model.selectAsset(a.id)
        let old = Task { await model.loadContainingAlbums(oldSelection) }
        await fulfillment(of: [gate.started], timeout: 2)
        let current = model.selectAsset(b.id)
        await model.loadContainingAlbums(current)
        gate.resolve(.success([album("a-album")]))
        await old.value

        XCTAssertEqual(model.containingAlbums.map(\.id), [prefix + "b-album"])
        XCTAssertTrue(model.isCurrent(current))
    }

    func testContainingAlbumsReturnVisitRejectsOldFailure() async throws {
        let a = asset("a")
        let gate = DetailResultGate<[AlbumResponseDTO]>(started: expectation(description: "First A albums started"))
        let albums = DetailRaceAlbumsRepository()
        var requests = 0
        albums.containing = { _ in
            requests += 1
            return requests == 1 ? try await gate.wait() : [self.album("new-a")]
        }
        let model = AssetDetailViewModel(repo: DetailRaceRepository(), albumRepo: albums)
        let oldSelection = model.selectAsset(a.id)
        let old = Task { await model.loadContainingAlbums(oldSelection) }
        await fulfillment(of: [gate.started], timeout: 2)
        _ = model.selectAsset(prefix + "b")
        await model.loadContainingAlbums(model.selectAsset(a.id))
        gate.resolve(.failure(APIError.unknown))
        await old.value

        XCTAssertEqual(model.containingAlbums.map(\.id), [prefix + "new-a"])
        XCTAssertNil(model.actionError)
    }

    func testFavoriteCompletionPatchesItsTargetSnapshotAndLeavesCurrentPhotoAlone() async throws {
        let a = asset("a"), b = asset("b")
        let gate = DetailResultGate<Void>(started: expectation(description: "A favorite started"))
        let repo = DetailRaceRepository()
        repo.fetch = { id in id == a.id ? a : b }
        var request: (String, Bool)?
        repo.favorite = { id, value in request = (id, value); try await gate.wait() }
        let model = AssetDetailViewModel(repo: repo)
        await model.load(a.id)
        let action = Task { await model.toggleFavorite(a.id, to: true) }
        await fulfillment(of: [gate.started], timeout: 2)
        await model.load(b.id)
        gate.resolve(.success(()))
        let succeeded = await action.value

        XCTAssertTrue(succeeded, "The server accepted A even though the viewer moved to B")
        XCTAssertEqual(request?.0, a.id)
        XCTAssertEqual(request?.1, true)
        XCTAssertEqual(model.detail?.id, b.id)
        XCTAssertEqual(model.detail?.isFavorite, false)
        XCTAssertEqual(cached(a.id)?.isFavorite, true)
        XCTAssertEqual(cached(a.id)?.id, a.id)
        XCTAssertEqual(cached(b.id)?.isFavorite, false)
    }

    func testArchiveAndDescriptionCompletionsCannotPatchAnotherPhotosMetadata() async throws {
        for isDescription in [false, true] {
            let a = asset("a-\(isDescription)", description: "original-a")
            let b = asset("b-\(isDescription)", description: "original-b")
            let gate = DetailResultGate<Void>(started: expectation(description: "A mutation started"))
            let repo = DetailRaceRepository()
            repo.fetch = { id in id == a.id ? a : b }
            repo.archive = { id, value in XCTAssertEqual(id, a.id); XCTAssertTrue(value); try await gate.wait() }
            repo.descriptionUpdate = { id, text in XCTAssertEqual(id, a.id); XCTAssertEqual(text, "changed-a"); try await gate.wait() }
            let model = AssetDetailViewModel(repo: repo)
            await model.load(a.id)
            let action = Task {
                if isDescription { _ = await model.updateDescription(a.id, to: "changed-a") }
                else { await model.toggleArchive(a.id) }
            }
            await fulfillment(of: [gate.started], timeout: 2)
            await model.load(b.id)
            gate.resolve(.success(()))
            await action.value

            XCTAssertEqual(model.detail?.id, b.id)
            XCTAssertEqual(model.detail?.isArchived, false)
            XCTAssertEqual(model.detail?.exifInfo?.description, "original-b")
            XCTAssertEqual(cached(a.id)?.isArchived, !isDescription)
            XCTAssertEqual(cached(a.id)?.id, a.id)
            XCTAssertEqual(cached(a.id)?.exifInfo?.description, isDescription ? "changed-a" : "original-a")
            XCTAssertEqual(cached(b.id)?.exifInfo?.description, "original-b")
        }
    }

    func testOldMutationFailureDoesNotShowAnErrorOnTheNextPhoto() async throws {
        let a = asset("a"), b = asset("b")
        let gate = DetailResultGate<Void>(started: expectation(description: "A favorite started"))
        let repo = DetailRaceRepository()
        repo.fetch = { id in id == a.id ? a : b }
        repo.favorite = { _, _ in try await gate.wait() }
        let model = AssetDetailViewModel(repo: repo)
        await model.load(a.id)
        let action = Task { await model.toggleFavorite(a.id) }
        await fulfillment(of: [gate.started], timeout: 2)
        await model.load(b.id)
        gate.resolve(.failure(APIError.unknown))
        let succeeded = await action.value

        XCTAssertFalse(succeeded)
        XCTAssertNil(model.actionError)
        XCTAssertEqual(model.detail?.id, b.id)
        XCTAssertEqual(cached(a.id)?.isFavorite, false)
    }

    func testDateAndLocationCompletionsDoNotReloadAnOldPhoto() async throws {
        for isLocation in [false, true] {
            let a = asset("a-\(isLocation)"), b = asset("b-\(isLocation)")
            let gate = DetailResultGate<Void>(started: expectation(description: "A metadata edit started"))
            let repo = DetailRaceRepository()
            repo.fetch = { id in id == a.id ? a : b }
            repo.metadataUpdate = { id in XCTAssertEqual(id, a.id); try await gate.wait() }
            let model = AssetDetailViewModel(repo: repo)
            await model.load(a.id)
            let action = Task {
                if isLocation { return await model.updateLocation(a.id, latitude: 12, longitude: 34) }
                return await model.updateDate(a.id, to: Date(timeIntervalSince1970: 1_600_000_000))
            }
            await fulfillment(of: [gate.started], timeout: 2)
            await model.load(b.id)
            gate.resolve(.success(()))
            let succeeded = await action.value

            XCTAssertTrue(succeeded)
            XCTAssertEqual(model.detail?.id, b.id)
            XCTAssertEqual(repo.fetchRequests, [a.id, b.id])
            XCTAssertNil(cached(a.id), "Off-page metadata changes must invalidate the old detail snapshot")
            XCTAssertNotNil(cached(b.id))
            XCTAssertNil(model.actionError)
        }
    }

    func testCurrentMetadataEditStillReloadsCurrentDetails() async {
        let a = asset("a"), updated = asset("a", filename: "updated.jpg")
        let repo = DetailRaceRepository()
        var value = a
        repo.fetch = { _ in value }
        repo.metadataUpdate = { _ in value = updated }
        let model = AssetDetailViewModel(repo: repo)
        await model.load(a.id)

        let succeeded = await model.updateDate(a.id, to: Date())

        XCTAssertTrue(succeeded)
        XCTAssertEqual(repo.fetchRequests, [a.id, a.id])
        XCTAssertEqual(model.detail?.originalFileName, "updated.jpg")
        XCTAssertEqual(cached(a.id)?.originalFileName, "updated.jpg")
    }

    func testDurableMetadataChangeRefreshesTheLatestReturnVisitToItsTarget() async {
        let a = asset("a"), updated = asset("a", filename: "updated.jpg"), b = asset("b")
        let gate = DetailResultGate<Void>(started: expectation(description: "Date save started"))
        let repo = DetailRaceRepository()
        var serverA = a
        repo.fetch = { id in id == a.id ? serverA : b }
        repo.metadataUpdate = { _ in try await gate.wait(); serverA = updated }
        let model = AssetDetailViewModel(repo: repo)
        await model.load(a.id)
        let change = Task { await model.updateDate(a.id, to: Date()) }
        await fulfillment(of: [gate.started], timeout: 2)
        await model.load(b.id)
        await model.load(a.id)
        gate.resolve(.success(()))
        let accepted = await change.value

        XCTAssertTrue(accepted)
        XCTAssertEqual(model.detail?.id, a.id)
        XCTAssertEqual(model.detail?.originalFileName, "updated.jpg")
        XCTAssertEqual(repo.fetchRequests, [a.id, b.id, a.id, a.id])
        XCTAssertEqual(cached(a.id)?.originalFileName, "updated.jpg")
    }

    func testOffPageEditAndVisibilitySuccessRemoveOnlyTheirTargetSnapshot() async {
        for isVisibility in [false, true] {
            let a = asset("a-\(isVisibility)"), b = asset("b-\(isVisibility)")
            let gate = DetailResultGate<Void>(started: expectation(description: "A mutation started"))
            let repo = DetailRaceRepository()
            repo.fetch = { id in id == a.id ? a : b }
            repo.metadataUpdate = { id in XCTAssertEqual(id, a.id); try await gate.wait() }
            let model = AssetDetailViewModel(repo: repo)
            await model.load(a.id)
            let action = Task {
                if isVisibility { return await model.move(a.id, to: .archive) }
                return await model.applyEdits([], to: a.id)
            }
            await fulfillment(of: [gate.started], timeout: 2)
            await model.load(b.id)
            gate.resolve(.success(()))
            let accepted = await action.value

            XCTAssertTrue(accepted)
            XCTAssertEqual(model.detail?.id, b.id)
            XCTAssertEqual(repo.fetchRequests, [a.id, b.id])
            XCTAssertNil(cached(a.id))
            XCTAssertNotNil(cached(b.id))
        }
    }

    func testReadStartedBeforeFavoriteCommitCannotRevertThatCommit() async throws {
        let oldA = asset("a"), acceptedA = asset("a", favorite: true)
        let gate = DetailResultGate<AssetResponseDTO>(started: expectation(description: "Pre-mutation read started"))
        let repo = DetailRaceRepository()
        var fetches = 0
        repo.fetch = { _ in
            fetches += 1
            return fetches == 1 ? try await gate.wait() : acceptedA
        }
        let model = AssetDetailViewModel(repo: repo)
        let selected = model.selectAsset(oldA.id)
        let load = Task { await model.load(selected) }
        await fulfillment(of: [gate.started], timeout: 2)
        let succeeded = await model.toggleFavorite(oldA.id, to: true)
        XCTAssertTrue(succeeded)
        gate.resolve(.success(oldA))
        await load.value

        XCTAssertEqual(model.detail?.isFavorite, true)
        XCTAssertEqual(cached(oldA.id)?.isFavorite, true)
        XCTAssertEqual(repo.fetchRequests, [oldA.id, oldA.id])
        assertLoaded(model)
    }

    func testInvalidatedSelectionKeepsSuccessfulTargetedWritesWithoutReopeningDetails() async throws {
        let a = asset("a", description: "original")
        let gate = DetailResultGate<Void>(started: expectation(description: "Description save started"))
        let repo = DetailRaceRepository()
        repo.fetch = { _ in a }
        repo.descriptionUpdate = { _, _ in try await gate.wait() }
        let model = AssetDetailViewModel(repo: repo)
        await model.load(a.id)
        let action = Task { await model.updateDescription(a.id, to: "saved after leaving") }
        await fulfillment(of: [gate.started], timeout: 2)
        model.invalidateSelection()
        gate.resolve(.success(()))
        let succeeded = await action.value

        XCTAssertTrue(succeeded)
        XCTAssertNil(model.detail)
        XCTAssertTrue(model.containingAlbums.isEmpty)
        XCTAssertEqual(cached(a.id)?.exifInfo?.description, "saved after leaving")
        XCTAssertNil(model.actionError)
    }

    func testInvalidatedSelectionRejectsAnUncancelledLateRead() async {
        let a = asset("a")
        let gate = DetailResultGate<AssetResponseDTO>(started: expectation(description: "A read started"))
        let repo = DetailRaceRepository()
        repo.fetch = { _ in try await gate.wait() }
        let model = AssetDetailViewModel(repo: repo)
        let load = Task { await model.load(a.id) }
        await fulfillment(of: [gate.started], timeout: 2)
        model.invalidateSelection()
        gate.resolve(.success(a))
        await load.value

        XCTAssertNil(model.detail)
        XCTAssertNil(cached(a.id))
        if case .idle = model.phase { } else { XCTFail("An inactive viewer must stay idle") }
    }

    func testDeleteCompletionRemovesOnlyItsTargetSnapshot() async throws {
        let a = asset("a"), b = asset("b")
        let gate = DetailResultGate<Void>(started: expectation(description: "A delete started"))
        let repo = DetailRaceRepository()
        repo.fetch = { id in id == a.id ? a : b }
        repo.deletion = { _ in try await gate.wait() }
        let model = AssetDetailViewModel(repo: repo)
        await model.load(a.id)
        let action = Task { await model.delete(a.id) }
        await fulfillment(of: [gate.started], timeout: 2)
        await model.load(b.id)
        gate.resolve(.success(()))
        let succeeded = await action.value

        XCTAssertTrue(succeeded)
        XCTAssertEqual(model.detail?.id, b.id)
        XCTAssertNil(cached(a.id))
        XCTAssertNotNil(cached(b.id))
    }

    func testDeletePreventsLateFavoriteFromRecreatingDeletedMetadata() async throws {
        let a = asset("a")
        let gate = DetailResultGate<Void>(started: expectation(description: "A favorite started"))
        let repo = DetailRaceRepository()
        repo.fetch = { _ in a }
        repo.favorite = { _, _ in try await gate.wait() }
        let model = AssetDetailViewModel(repo: repo)
        await model.load(a.id)
        let favorite = Task { await model.toggleFavorite(a.id, to: true) }
        await fulfillment(of: [gate.started], timeout: 2)
        let deleted = await model.delete(a.id)
        XCTAssertTrue(deleted)
        gate.resolve(.success(()))
        let accepted = await favorite.value

        XCTAssertFalse(accepted, "A deleted target must not produce a later favorite UI update")
        XCTAssertNil(model.detail)
        XCTAssertNil(cached(a.id))
    }

    func testCanceledReadCannotPublishOrDeleteAnExistingSnapshot() async throws {
        let a = asset("a"), cachedA = asset("a", filename: "current-cache.jpg")
        let gate = DetailResultGate<AssetResponseDTO>(started: expectation(description: "A read started"))
        let repo = DetailRaceRepository()
        repo.fetch = { _ in try await gate.wait() }
        let model = AssetDetailViewModel(repo: repo)
        let operation = Task { await model.load(a.id) }
        await fulfillment(of: [gate.started], timeout: 2)
        operation.cancel()
        LocalSnapshot.save(cachedA, for: LocalSnapshot.Key.assetDetail(a.id))
        gate.resolve(.failure(APIError.server(status: 400, message: "Unreadable asset")))
        await operation.value

        XCTAssertEqual(cached(a.id)?.originalFileName, "current-cache.jpg")
        XCTAssertNil(model.actionError)
        XCTAssertNil(model.detail)
    }

    func testWrongAssetResponseIsNotAdmittedOrStored() async {
        let a = asset("a"), b = asset("b")
        let repo = DetailRaceRepository()
        repo.fetch = { _ in b }
        let model = AssetDetailViewModel(repo: repo)

        await model.load(a.id)

        XCTAssertNil(model.detail)
        XCTAssertNil(cached(a.id))
        if case .failed = model.phase { } else { XCTFail("A response for the wrong ID must fail") }
    }

    func testOpposingFavoriteWritesRunInOrderAndOnlyLatestResultUpdatesCaller() async {
        let a = asset("a")
        let first = DetailResultGate<Void>(started: expectation(description: "First favorite started"))
        let second = DetailResultGate<Void>(started: expectation(description: "Second favorite started"))
        let queued = expectation(description: "Second favorite queued")
        let repo = DetailRaceRepository()
        repo.fetch = { _ in a }
        var requests: [Bool] = []
        var serverValue = false
        repo.favorite = { id, value in
            XCTAssertEqual(id, a.id)
            requests.append(value)
            if value { try await first.wait() } else { try await second.wait() }
            serverValue = value
        }
        let model = AssetDetailViewModel(repo: repo)
        await model.load(a.id)
        var callerValue = false
        let older = Task {
            if await model.toggleFavorite(a.id, to: true) { callerValue = true }
        }
        await fulfillment(of: [first.started], timeout: 2)
        let newer = Task {
            queued.fulfill()
            if await model.toggleFavorite(a.id, to: false) { callerValue = false }
        }
        await fulfillment(of: [queued], timeout: 2)
        XCTAssertEqual(requests, [true], "Conflicting writes must not reach the server concurrently")
        first.resolve(.success(()))
        await fulfillment(of: [second.started], timeout: 2)
        await older.value
        XCTAssertFalse(callerValue, "Superseded success must not publish its captured value")
        XCTAssertEqual(cached(a.id)?.isFavorite, true, "Cache follows the accepted server state while the next write is pending")
        second.resolve(.success(()))
        await newer.value

        XCTAssertEqual(requests, [true, false])
        XCTAssertFalse(serverValue)
        XCTAssertFalse(callerValue)
        XCTAssertEqual(model.detail?.isFavorite, false)
        XCTAssertEqual(cached(a.id)?.isFavorite, false)
    }

    func testQueuedDescriptionFailureKeepsTheLastServerAcceptedDescription() async {
        let a = asset("a", description: "original")
        let first = DetailResultGate<Void>(started: expectation(description: "First save started"))
        let second = DetailResultGate<Void>(started: expectation(description: "Second save started"))
        let queued = expectation(description: "Second save queued")
        let repo = DetailRaceRepository()
        repo.fetch = { _ in a }
        var requests: [String] = []
        repo.descriptionUpdate = { id, value in
            XCTAssertEqual(id, a.id)
            requests.append(value)
            if value == "first" { try await first.wait() } else { try await second.wait() }
        }
        let model = AssetDetailViewModel(repo: repo)
        await model.load(a.id)
        let older = Task { await model.updateDescription(a.id, to: "first") }
        await fulfillment(of: [first.started], timeout: 2)
        let newer = Task {
            queued.fulfill()
            return await model.updateDescription(a.id, to: "second")
        }
        await fulfillment(of: [queued], timeout: 2)
        XCTAssertEqual(requests, ["first"])
        first.resolve(.success(()))
        await fulfillment(of: [second.started], timeout: 2)
        let olderAccepted = await older.value
        XCTAssertFalse(olderAccepted)
        second.resolve(.failure(APIError.unknown))
        let newerAccepted = await newer.value

        XCTAssertFalse(newerAccepted)
        XCTAssertEqual(requests, ["first", "second"])
        XCTAssertEqual(model.detail?.exifInfo?.description, "first")
        XCTAssertEqual(cached(a.id)?.exifInfo?.description, "first")
        XCTAssertNotNil(model.actionError)
    }

    func testDifferentMutationFieldsDoNotWaitForEachOther() async {
        let a = asset("a", description: "original")
        let gate = DetailResultGate<Void>(started: expectation(description: "Favorite started"))
        let repo = DetailRaceRepository()
        repo.fetch = { _ in a }
        repo.favorite = { _, _ in try await gate.wait() }
        let model = AssetDetailViewModel(repo: repo)
        await model.load(a.id)
        let favorite = Task { await model.toggleFavorite(a.id, to: true) }
        await fulfillment(of: [gate.started], timeout: 2)

        let descriptionAccepted = await model.updateDescription(a.id, to: "saved independently")

        XCTAssertTrue(descriptionAccepted)
        XCTAssertEqual(model.detail?.exifInfo?.description, "saved independently")
        gate.resolve(.success(()))
        let favoriteAccepted = await favorite.value
        XCTAssertTrue(favoriteAccepted)
        XCTAssertEqual(cached(a.id)?.exifInfo?.description, "saved independently")
        XCTAssertEqual(cached(a.id)?.isFavorite, true)
    }

    func testLateFavoriteCannotRestoreSnapshotInvalidatedByMetadataChange() async {
        let a = asset("a"), b = asset("b")
        let favoriteGate = DetailResultGate<Void>(started: expectation(description: "A favorite started"))
        let dateGate = DetailResultGate<Void>(started: expectation(description: "A date change started"))
        let repo = DetailRaceRepository()
        var serverA = a
        repo.fetch = { id in id == a.id ? serverA : b }
        repo.favorite = { _, value in try await favoriteGate.wait(); serverA.isFavorite = value }
        repo.metadataUpdate = { _ in try await dateGate.wait() }
        let model = AssetDetailViewModel(repo: repo)
        await model.load(a.id)
        let favorite = Task { await model.toggleFavorite(a.id, to: true) }
        let date = Task { await model.updateDate(a.id, to: Date()) }
        await fulfillment(of: [favoriteGate.started, dateGate.started], timeout: 2)
        await model.load(b.id)
        dateGate.resolve(.success(()))
        let dateAccepted = await date.value
        XCTAssertTrue(dateAccepted)
        XCTAssertNil(cached(a.id))
        favoriteGate.resolve(.success(()))
        let favoriteAccepted = await favorite.value

        XCTAssertTrue(favoriteAccepted)
        XCTAssertNil(cached(a.id), "A captured pre-date DTO cannot recreate the invalidated snapshot")
        XCTAssertEqual(model.detail?.id, b.id)
        await model.load(a.id)
        XCTAssertEqual(cached(a.id)?.isFavorite, true, "A fresh admitted read can restore the snapshot")
        repo.favorite = { _, value in serverA.isFavorite = value }
        let nextFavorite = await model.toggleFavorite(a.id, to: false)
        XCTAssertTrue(nextFavorite)
        XCTAssertEqual(cached(a.id)?.isFavorite, false, "Ordinary field patches remain cacheable after a fresh read")
    }

    func testCanceledQueuedWriteDoesNotReachServerAndQueueCanBeUsedAgain() async {
        let a = asset("a")
        let first = DetailResultGate<Void>(started: expectation(description: "First favorite started"))
        let queued = expectation(description: "Canceled favorite queued")
        let repo = DetailRaceRepository()
        repo.fetch = { _ in a }
        var requests: [Bool] = []
        repo.favorite = { _, value in
            requests.append(value)
            if requests.count == 1 { try await first.wait() }
        }
        let model = AssetDetailViewModel(repo: repo)
        await model.load(a.id)
        let older = Task { await model.toggleFavorite(a.id, to: true) }
        await fulfillment(of: [first.started], timeout: 2)
        let canceled = Task {
            queued.fulfill()
            return await model.toggleFavorite(a.id, to: false)
        }
        await fulfillment(of: [queued], timeout: 2)
        canceled.cancel()
        first.resolve(.success(()))
        _ = await older.value
        let canceledAccepted = await canceled.value
        XCTAssertFalse(canceledAccepted)
        XCTAssertEqual(requests, [true])
        XCTAssertNil(model.actionError)
        let finalAccepted = await model.toggleFavorite(a.id, to: false)
        XCTAssertTrue(finalAccepted)
        XCTAssertEqual(requests, [true, false])
        XCTAssertEqual(cached(a.id)?.isFavorite, false)
    }

    private func asset(_ suffix: String, filename: String = "photo.jpg", favorite: Bool = false, description: String? = nil) -> AssetResponseDTO {
        let id = prefix + suffix
        assetIDs.insert(id)
        let exif = description.flatMap { value -> ExifDTO? in
            let data = try! JSONSerialization.data(withJSONObject: ["description": value])
            return try! JSONDecoder.immich.decode(ExifDTO.self, from: data)
        }
        return makeTestAsset(id: id, originalFileName: filename, isFavorite: favorite, exifInfo: exif)
    }

    private func cached(_ id: String) -> AssetResponseDTO? {
        LocalSnapshot.load(AssetResponseDTO.self, for: LocalSnapshot.Key.assetDetail(id))
    }

    private func album(_ suffix: String) -> AlbumResponseDTO {
        AlbumResponseDTO(id: prefix + suffix, albumName: suffix, description: nil, assetCount: 1,
            albumThumbnailAssetId: nil, shared: false, createdAt: Date(), assets: nil)
    }

    private func assertLoaded(_ model: AssetDetailViewModel, file: StaticString = #filePath, line: UInt = #line) {
        if case .loaded = model.phase { } else { XCTFail("Current photo should stay loaded", file: file, line: line) }
    }
}

@MainActor
private final class DetailResultGate<Value> {
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
        XCTAssertNotNil(continuation, "Wait for the request to reach the held boundary first")
        continuation?.resume(with: result)
        continuation = nil
    }
}

private final class DetailRaceRepository: AssetDetailRepository {
    @MainActor var fetch: (String) async throws -> AssetResponseDTO = { _ in throw APIError.unknown }
    @MainActor var favorite: (String, Bool) async throws -> Void = { _, _ in }
    @MainActor var archive: (String, Bool) async throws -> Void = { _, _ in }
    @MainActor var descriptionUpdate: (String, String) async throws -> Void = { _, _ in }
    @MainActor var metadataUpdate: (String) async throws -> Void = { _ in }
    @MainActor var deletion: (String) async throws -> Void = { _ in }
    @MainActor private(set) var fetchRequests: [String] = []

    @MainActor init() { super.init(api: makeStubAPIClient()) }
    override func fetchAsset(_ id: String) async throws -> AssetResponseDTO {
        await recordFetch(id)
        return try await fetch(id)
    }
    @MainActor private func recordFetch(_ id: String) { fetchRequests.append(id) }
    override func toggleFavorite(_ id: String, to value: Bool) async throws { try await favorite(id, value) }
    override func toggleArchive(_ id: String, to value: Bool) async throws { try await archive(id, value) }
    override func updateDescription(_ id: String, to text: String) async throws { try await descriptionUpdate(id, text) }
    override func updateDate(_ id: String, to date: Date) async throws { try await metadataUpdate(id) }
    override func updateLocation(_ id: String, latitude: Double, longitude: Double) async throws { try await metadataUpdate(id) }
    override func setVisibility(_ id: String, to value: Visibility) async throws { try await metadataUpdate(id) }
    override func removeEdits(from id: String) async throws { try await metadataUpdate(id) }
    override func delete(_ id: String) async throws { try await deletion(id) }
}

private final class DetailRaceAlbumsRepository: AlbumRepository {
    @MainActor var containing: (String) async throws -> [AlbumResponseDTO] = { _ in [] }
    @MainActor init() { super.init(api: makeStubAPIClient()) }
    override func albums(containing assetId: String) async throws -> [AlbumResponseDTO] { try await containing(assetId) }
}
