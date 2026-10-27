import XCTest
@testable import ImmichApp

final class SharedUploadStoreTests: XCTestCase {
    private var rootURL: URL!
    private var store: SharedUploadStore!

    override func setUpWithError() throws {
        rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("SharedUploadStoreTests-\(UUID().uuidString)", isDirectory: true)
        store = SharedUploadStore(rootURL: rootURL)
    }

    override func tearDownWithError() throws {
        if let rootURL {
            try? FileManager.default.removeItem(at: rootURL)
        }
        store = nil
        rootURL = nil
    }

    func testBatchSurvivesReloadAndIsScopedToOwner() async throws {
        let owner = SharedUploadOwner(server: "https://one.example/api", userID: "user-1")
        let otherOwner = SharedUploadOwner(server: "https://one.example/api", userID: "user-2")
        let batch = makeBatch(owner: owner, state: .uploading)

        try await store.save(batch)

        let reloaded = SharedUploadStore(rootURL: rootURL)
        let matching = try await reloaded.batches(for: owner)
        let other = try await reloaded.batches(for: otherOwner)
        XCTAssertEqual(matching, [batch])
        XCTAssertTrue(other.isEmpty)
    }

    func testRemovingBatchDeletesStagedFilesAndManifest() async throws {
        let batch = makeBatch(
            owner: SharedUploadOwner(server: "https://one.example/api", userID: "user-1"),
            state: .queued)
        let directory = try await store.makeBatchDirectory(id: batch.id)
        let fileURL = directory.appendingPathComponent(batch.items[0].relativePath)
        try Data("image".utf8).write(to: fileURL)
        try await store.save(batch)

        try await store.removeBatch(id: batch.id)

        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
    }

    func testFileURLRejectsPathTraversal() async throws {
        var batch = makeBatch(
            owner: SharedUploadOwner(server: "https://one.example/api", userID: "user-1"),
            state: .queued)
        let original = batch.items[0]
        batch.items[0] = SharedUploadItem(
            id: original.id,
            filename: original.filename,
            relativePath: "../outside.jpg",
            contentType: original.contentType,
            byteCount: original.byteCount,
            createdAt: original.createdAt,
            modifiedAt: original.modifiedAt,
            state: original.state,
            lastError: original.lastError)

        do {
            _ = try await store.fileURL(for: batch.items[0], batchID: batch.id)
            XCTFail("Path traversal should be rejected")
        } catch SharedUploadStoreError.invalidFilename {
            // Expected.
        }
    }

    func testIndependentStoresExcludeASecondClaimUntilTheFirstIsReleased() async throws {
        let batch = makeBatch(owner: owner, state: .queued)
        try await store.save(batch)
        let otherStore = SharedUploadStore(rootURL: rootURL)
        var firstClaim = try await store.claimBatch(id: batch.id)
        XCTAssertNotNil(firstClaim)

        let blockedClaim = try await otherStore.claimBatch(id: batch.id)
        XCTAssertNil(blockedClaim)
        withExtendedLifetime(firstClaim) {}
        firstClaim = nil

        let nextClaim = try await otherStore.claimBatch(id: batch.id)
        XCTAssertNotNil(nextClaim, "Closing the first descriptor must release its batch")
        withExtendedLifetime(nextClaim) {}
    }

    func testClaimingOneBatchDoesNotBlockADifferentBatch() async throws {
        let first = makeBatch(owner: owner, state: .queued)
        let second = makeBatch(owner: owner, state: .queued)
        try await store.save(first)
        try await store.save(second)
        let otherStore = SharedUploadStore(rootURL: rootURL)

        let firstClaim = try await store.claimBatch(id: first.id)
        let secondClaim = try await otherStore.claimBatch(id: second.id)

        XCTAssertNotNil(firstClaim)
        XCTAssertNotNil(secondClaim)
        withExtendedLifetime((firstClaim, secondClaim)) {}
    }

    func testExactBatchReloadChecksOwnerAndVersion() async throws {
        var batch = makeBatch(owner: owner, state: .uploaded)
        try await store.save(batch)
        let reloaded = SharedUploadStore(rootURL: rootURL)

        let matching = try await reloaded.batch(id: batch.id, owner: owner)
        let wrongUser = try await reloaded.batch(id: batch.id,
            owner: SharedUploadOwner(server: owner.server, userID: "other-user"))
        let wrongServer = try await reloaded.batch(id: batch.id,
            owner: SharedUploadOwner(server: "https://other.example/api", userID: owner.userID))
        XCTAssertEqual(matching, batch)
        XCTAssertNil(wrongUser)
        XCTAssertNil(wrongServer)

        batch.version = 2
        try await store.save(batch)
        let unsupported = try await reloaded.batch(id: batch.id, owner: owner)
        XCTAssertNil(unsupported)
    }

    func testExactBatchReloadRejectsAManifestForAnotherID() async throws {
        let batch = makeBatch(owner: owner, state: .queued)
        try await store.save(batch)
        let other = makeBatch(owner: owner, state: .queued)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let directory = try await store.makeBatchDirectory(id: batch.id)
        try encoder.encode(other).write(to: directory.appendingPathComponent("manifest.json"))

        let mismatched = try await store.batch(id: batch.id, owner: owner)

        XCTAssertNil(mismatched)
    }

    func testMalformedManifestThrowsWithoutReplacingItsContents() async throws {
        let batch = makeBatch(owner: owner, state: .queued)
        try await store.save(batch)
        let directory = try await store.makeBatchDirectory(id: batch.id)
        let manifest = directory.appendingPathComponent("manifest.json")
        let malformed = Data("{not a complete manifest".utf8)
        try malformed.write(to: manifest)

        do {
            _ = try await store.batch(id: batch.id, owner: owner)
            XCTFail("A corrupt manifest must not look like a completed or missing batch")
        } catch {
            XCTAssertTrue(error is DecodingError)
        }

        XCTAssertEqual(try Data(contentsOf: manifest), malformed)
    }

    func testMissingRecoveryLookupsDoNotCreateABatchOrInbox() async throws {
        let batch = makeBatch(owner: owner, state: .queued)

        let missingBatch = try await store.batch(id: batch.id, owner: owner)
        let missingClaim = try await store.claimBatch(id: batch.id)
        let missingDirectory = try await store.existingBatchDirectory(id: batch.id)
        let missingFile = try await store.fileURL(for: batch.items[0], batchID: batch.id)
        try await store.removeFile(for: batch.items[0], batchID: batch.id)

        XCTAssertNil(missingBatch)
        XCTAssertNil(missingClaim)
        XCTAssertNil(missingDirectory)
        XCTAssertEqual(missingFile.lastPathComponent, batch.items[0].relativePath)
        XCTAssertFalse(FileManager.default.fileExists(atPath: rootURL.path))
    }

    func testAStaleClaimCannotRecreateARemovedBatch() async throws {
        let batch = makeBatch(owner: owner, state: .queued)
        try await store.save(batch)
        let claim = try await store.claimBatch(id: batch.id)
        XCTAssertNotNil(claim)
        let otherStore = SharedUploadStore(rootURL: rootURL)

        try await store.removeBatch(id: batch.id)
        let staleClaim = try await otherStore.claimBatch(id: batch.id)
        let removedBatch = try await otherStore.batch(id: batch.id, owner: owner)
        let remaining = try FileManager.default.contentsOfDirectory(atPath: rootURL.path)

        XCTAssertNil(staleClaim)
        XCTAssertNil(removedBatch)
        XCTAssertTrue(remaining.isEmpty, "Locks must not leave files outside their completed batch")
        withExtendedLifetime(claim) {}
    }

    private var owner: SharedUploadOwner {
        SharedUploadOwner(server: "https://one.example/api", userID: "user-1")
    }

    private func makeBatch(
        owner: SharedUploadOwner,
        state: SharedUploadItemState
    ) -> SharedUploadBatch {
        let itemID = UUID()
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        return SharedUploadBatch(
            id: UUID(),
            owner: owner,
            createdAt: now,
            items: [SharedUploadItem(
                id: itemID,
                filename: "shared.jpg",
                relativePath: "\(itemID.uuidString)-shared.jpg",
                contentType: "image/jpeg",
                byteCount: 5,
                createdAt: now,
                modifiedAt: now,
                state: state,
                lastError: nil)])
    }
}
