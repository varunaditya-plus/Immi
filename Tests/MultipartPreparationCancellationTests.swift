import XCTest
@testable import ImmichApp

@MainActor
final class MultipartPreparationCancellationTests: XCTestCase {
    private var directories: [URL] = []

    override func tearDown() async throws {
        for directory in directories { try? FileManager.default.removeItem(at: directory) }
        directories.removeAll()
        try await super.tearDown()
    }

    func testAlreadyCancelledBackupPreparationDoesNotReadOrCreateABody() async throws {
        let source = try fixture()
        let reads = ChunkReadGate(holdAt: nil)
        let repository = BackupRepository(api: try api(), readChunk: reads.read)
        let before = try backupBodies()
        let task = Task { try await prepare(repository, source: source.file) }
        task.cancel()

        await assertCancelled(task)

        XCTAssertEqual(reads.count, 0)
        XCTAssertEqual(try backupBodies(), before)
        XCTAssertEqual(try Data(contentsOf: source.file), source.bytes)
    }

    func testCancellingBackupCopyStopsAfterTheHeldChunkAndRemovesItsPartialBody() async throws {
        let source = try fixture()
        let reads = ChunkReadGate(holdAt: 1)
        let repository = BackupRepository(api: try api(), readChunk: reads.read)
        let before = try backupBodies()
        let task = Task { try await prepare(repository, source: source.file) }
        addTeardownBlock {
            task.cancel()
            reads.release()
            if let prepared = try? await task.value { try? FileManager.default.removeItem(at: prepared.bodyFile) }
        }
        await fulfillment(of: [reads.started], timeout: 2)
        let partial = try XCTUnwrap(try backupBodies().subtracting(before).first)
        XCTAssertGreaterThan(try partial.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0, 0)

        task.cancel()
        reads.release()
        await assertCancelled(task)

        XCTAssertEqual(reads.count, 1, "Cancellation must reach the detached worker before another source read")
        XCTAssertFalse(FileManager.default.fileExists(atPath: partial.path))
        XCTAssertEqual(try Data(contentsOf: source.file), source.bytes)
    }

    func testAChangedAccountCannotReceiveThePreparedBodyAndTheBodyIsRemoved() async throws {
        let source = try fixture()
        let session = MockSessionManager()
        try session.setServer("https://first-upload.example")
        let reads = ChunkReadGate(holdAt: 1)
        let repository = BackupRepository(api: APIClient(session: session), readChunk: reads.read)
        let before = try backupBodies()
        let task = Task { try await prepare(repository, source: source.file) }
        addTeardownBlock {
            task.cancel()
            reads.release()
            if let prepared = try? await task.value { try? FileManager.default.removeItem(at: prepared.bodyFile) }
        }
        await fulfillment(of: [reads.started], timeout: 2)
        let partial = try XCTUnwrap(try backupBodies().subtracting(before).first)

        try session.setServer("https://second-upload.example")
        reads.release()
        await assertCancelled(task)

        XCTAssertFalse(FileManager.default.fileExists(atPath: partial.path))
        XCTAssertEqual(try Data(contentsOf: source.file), source.bytes)
    }

    func testNormalBackupBodyContainsEverySourceChunkAndItsClosingBoundary() async throws {
        let source = try fixture()
        let repository = BackupRepository(api: try api())

        let prepared = try await prepare(repository, source: source.file)
        defer { try? FileManager.default.removeItem(at: prepared.bodyFile) }

        let body = try Data(contentsOf: prepared.bodyFile)
        let marker = Data("Content-Type: application/octet-stream\r\n\r\n".utf8)
        let payload = try XCTUnwrap(body.range(of: marker)).upperBound
        XCTAssertEqual(body[payload..<payload + source.bytes.count], source.bytes)
        let contentType = try XCTUnwrap(prepared.request.value(forHTTPHeaderField: "Content-Type"))
        let boundary = try XCTUnwrap(contentType.components(separatedBy: "boundary=").last)
        XCTAssertEqual(Data(body.suffix("\r\n--\(boundary)--\r\n".utf8.count)), Data("\r\n--\(boundary)--\r\n".utf8))
        XCTAssertEqual(prepared.request.value(forHTTPHeaderField: "x-immich-checksum"), "known-checksum")
        XCTAssertEqual(try Data(contentsOf: source.file), source.bytes)
    }

    func testSharedHashAndMultipartCancellationStopReadsWithoutStartingATransfer() async throws {
        // Three data chunks plus EOF complete hashing; call five starts the body.
        for heldRead in [1, 5] {
            let source = try fixture()
            let reads = ChunkReadGate(holdAt: heldRead)
            let session = uploadSession()
            defer { session.invalidateAndCancel() }
            let client = SharedUploadClient(credential: credential(), session: session, readChunk: reads.read)
            let task = Task { try await client.upload(item: item(bytes: source.bytes.count),
                fileURL: source.file, bodyDirectory: source.directory) }
            addTeardownBlock { task.cancel(); reads.release(); _ = try? await task.value }
            await fulfillment(of: [reads.started], timeout: 2)
            let partialBodies = try multipartFiles(in: source.directory)
            XCTAssertEqual(partialBodies.count, heldRead == 1 ? 0 : 1)

            task.cancel()
            reads.release()
            do {
                _ = try await task.value
                XCTFail("Canceled shared preparation must not return an uploaded ID")
            } catch is CancellationError {
            }

            XCTAssertEqual(reads.count, heldRead, "Parent cancellation must stop the detached \(heldRead == 1 ? "hash" : "copy") worker")
            XCTAssertTrue(try multipartFiles(in: source.directory).isEmpty)
            XCTAssertEqual(try Data(contentsOf: source.file), source.bytes)
        }
    }

    func testAlreadyCancelledSharedUploadDoesNotReadItsSource() async throws {
        let source = try fixture()
        let reads = ChunkReadGate(holdAt: nil)
        let client = SharedUploadClient(credential: credential(), readChunk: reads.read)
        let task = Task { try await client.upload(item: item(bytes: source.bytes.count),
            fileURL: source.file, bodyDirectory: source.directory) }
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("Canceled upload must not perform preparation")
        } catch is CancellationError {
        }
        XCTAssertEqual(reads.count, 0)
        XCTAssertTrue(try multipartFiles(in: source.directory).isEmpty)
    }

    private func api() throws -> APIClient {
        let session = MockSessionManager()
        try session.setServer("https://upload-cancellation.example")
        return APIClient(session: session)
    }

    private func prepare(_ repository: BackupRepository, source: URL) async throws -> BackupRepository.PreparedUpload {
        try await repository.makeUploadRequest(fileURL: source, filename: "clip.mov", checksum: "known-checksum",
            deviceAssetId: "local-photo", createdAt: .distantPast, modifiedAt: .distantPast)
    }

    private func assertCancelled(_ task: Task<BackupRepository.PreparedUpload, Error>,
                                 file: StaticString = #filePath, line: UInt = #line) async {
        do {
            let prepared = try await task.value
            try? FileManager.default.removeItem(at: prepared.bodyFile)
            XCTFail("Stale preparation must throw cancellation", file: file, line: line)
        } catch is CancellationError {
        } catch {
            XCTFail("Expected cancellation, received \(error)", file: file, line: line)
        }
    }

    private func fixture() throws -> (directory: URL, file: URL, bytes: Data) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("multipart-cancellation-\(UUID())")
        directories.append(directory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("source.mov")
        var bytes = Data(repeating: 0x71, count: 2 * 1024 * 1024)
        bytes.append(contentsOf: (0..<17).map(UInt8.init))
        try bytes.write(to: file)
        return (directory, file, bytes)
    }

    private func backupBodies() throws -> Set<URL> {
        Set(try FileManager.default.contentsOfDirectory(at: FileManager.default.temporaryDirectory,
            includingPropertiesForKeys: nil).filter {
                $0.lastPathComponent.hasPrefix("upload-") && $0.pathExtension == "multipart"
            })
    }

    private func multipartFiles(in directory: URL) throws -> [URL] {
        try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "multipart" }
    }

    private func credential() -> SharedUploadCredential {
        .init(apiURL: URL(string: "https://upload-cancellation.example/api")!,
            owner: .init(server: "https://upload-cancellation.example/api", userID: "owner"),
            authHeaders: ["Authorization": "Bearer test-token"])
    }

    private func item(bytes: Int) -> SharedUploadItem {
        .init(id: UUID(), filename: "clip.mov", relativePath: "source.mov", contentType: "video/quicktime",
            byteCount: Int64(bytes), createdAt: .distantPast, modifiedAt: .distantPast, state: .queued)
    }

    private func uploadSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CancellationUploadProtocol.self]
        return URLSession(configuration: configuration)
    }
}

/// Holds one real read without consulting Task cancellation itself. Production
/// workers must receive the parent's cancellation and stop after this boundary.
private final class ChunkReadGate: @unchecked Sendable {
    let started = XCTestExpectation(description: "A real source chunk was read")
    private let condition = NSCondition()
    private let holdAt: Int?
    private var reads = 0
    private var released = false

    init(holdAt: Int?) { self.holdAt = holdAt }

    var count: Int { condition.withLock { reads } }

    func read(_ handle: FileHandle, count: Int) throws -> Data? {
        let bytes = try handle.read(upToCount: count)
        condition.lock()
        reads += 1
        if reads == holdAt {
            started.fulfill()
            let deadline = Date().addingTimeInterval(5)
            while !released {
                guard condition.wait(until: deadline) else {
                    condition.unlock()
                    throw URLError(.timedOut)
                }
            }
        }
        condition.unlock()
        return bytes
    }

    func release() {
        condition.lock()
        released = true
        condition.broadcast()
        condition.unlock()
    }
}

private final class CancellationUploadProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        XCTFail("Canceled preparation must not reach the upload transport")
        client?.urlProtocol(self, didFailWithError: URLError(.cancelled))
    }
    override func stopLoading() {}
}

@MainActor
final class BackupPreparationTaskCancellationTests: XCTestCase {
    private var savedEnabled: Any?
    private var fixtures: [PreparationFixture] = []

    override func setUp() async throws {
        savedEnabled = UserDefaults.standard.object(forKey: "backup.enabled")
        UserDefaults.standard.set(false, forKey: "backup.enabled")
    }

    override func tearDown() async throws {
        for fixture in fixtures { fixture.service.stop(); try? FileManager.default.removeItem(at: fixture.directory) }
        fixtures.removeAll()
        if let savedEnabled { UserDefaults.standard.set(savedEnabled, forKey: "backup.enabled") }
        else { UserDefaults.standard.removeObject(forKey: "backup.enabled") }
        savedEnabled = nil
        try await super.tearDown()
    }

    func testCancellingOnePreparationStopsItsReadsWithoutCancellingTheQueueParentOrNeighbor() async throws {
        let fixture = try fixture()
        try fixture.queue.enqueue(["selected", "neighbor"], intent: .manualUpload)
        let neighbor = fixture.queue.item(id: "neighbor")
        let ownership = try XCTUnwrap(fixture.queue.ownership)
        let reads = ChunkReadGate(holdAt: 1)
        let repository = BackupRepository(api: APIClient(session: fixture.session), readChunk: reads.read)
        var wasCancelled = false
        let work = Task {
            await fixture.service.performPreparation(localIdentifier: "selected", isOwned: true,
                ownership: ownership) { _ in
                do {
                    try fixture.queue.markPreparing("selected", phase: .primaryAsset)
                    _ = try await repository.checksum(forFile: fixture.source)
                    XCTFail("The canceled item's hashing must stop")
                } catch is CancellationError { wasCancelled = true }
                catch { XCTFail("Unexpected preparation error: \(error)") }
            }
            return Task.isCancelled
        }
        addTeardownBlock { work.cancel(); reads.release(); _ = await work.value }
        await fulfillment(of: [reads.started], timeout: 2)

        fixture.service.cancelUpload("selected")
        reads.release()
        let parentCancelled = await work.value

        XCTAssertTrue(wasCancelled)
        XCTAssertFalse(parentCancelled)
        XCTAssertEqual(reads.count, 1)
        XCTAssertEqual(fixture.queue.item(id: "selected")?.state, .failed)
        XCTAssertEqual(fixture.queue.item(id: "selected")?.intent, .manualUpload)
        XCTAssertEqual(fixture.queue.item(id: "neighbor"), neighbor)
        var digest: String?
        await fixture.service.performPreparation(localIdentifier: "neighbor", isOwned: true,
            ownership: try XCTUnwrap(fixture.queue.ownership)) { _ in
                digest = try? await repository.checksum(forFile: fixture.source)
            }
        XCTAssertEqual(digest, "a9993e364706816aba3e25717850c26c9cd0d89d",
            "Canceling one item must leave the next preparation usable")
        XCTAssertEqual(try Data(contentsOf: fixture.source), Data("abc".utf8))
    }

    func testStopCancelsOwnedPreparationButPreservesACompletionCallbacksPreparation() async throws {
        for owned in [true, false] {
            let fixture = try fixture()
            try fixture.queue.enqueue(["photo"], intent: .manualUpload)
            let ownership = try XCTUnwrap(fixture.queue.ownership)
            let reads = ChunkReadGate(holdAt: 1)
            let repository = BackupRepository(api: APIClient(session: fixture.session), readChunk: reads.read)
            var cancelled = false
            var digest: String?
            let work = Task { await fixture.service.performPreparation(localIdentifier: "photo", isOwned: owned,
                ownership: ownership) { _ in
                    do {
                        try fixture.queue.markPreparing("photo", phase: .primaryAsset, motionAssetID: "completed-motion")
                        digest = try await repository.checksum(forFile: fixture.source)
                    } catch is CancellationError { cancelled = true }
                    catch { XCTFail("Unexpected preparation error: \(error)") }
                }
            }
            addTeardownBlock { work.cancel(); reads.release(); await work.value }
            await fulfillment(of: [reads.started], timeout: 2)

            fixture.service.stop()
            XCTAssertEqual(fixture.queue.item(id: "photo")?.state, owned ? .queued : .preparing,
                "Stop must not release a callback's still-active preparation")
            reads.release()
            await work.value

            XCTAssertEqual(cancelled, owned)
            XCTAssertEqual(digest, owned ? nil : "a9993e364706816aba3e25717850c26c9cd0d89d")
            XCTAssertEqual(fixture.queue.item(id: "photo")?.state, .queued,
                "Once either worker ends, an unfinished preparation must be resumable")
            XCTAssertEqual(fixture.queue.item(id: "photo")?.motionAssetID, "completed-motion")
            XCTAssertEqual(fixture.queue.item(id: "photo")?.intent, .manualUpload)
        }
    }

    func testLogoutAndAuthenticationPauseCancelEvenCompletionOwnedPreparation() async throws {
        for logout in [false, true] {
            let fixture = try fixture()
            try fixture.queue.enqueue(["photo"], intent: .manualUpload)
            let ownership = try XCTUnwrap(fixture.queue.ownership)
            let reads = ChunkReadGate(holdAt: 1)
            let repository = BackupRepository(api: APIClient(session: fixture.session), readChunk: reads.read)
            var cancelled = false
            let work = Task { await fixture.service.performPreparation(localIdentifier: "photo", isOwned: false,
                ownership: ownership) { _ in
                    do {
                        try fixture.queue.markPreparing("photo", phase: .primaryAsset, motionAssetID: "completed-motion")
                        _ = try await repository.checksum(forFile: fixture.source)
                        XCTFail("A departed account must not continue its preparation")
                    } catch is CancellationError { cancelled = true }
                    catch { XCTFail("Unexpected preparation error: \(error)") }
                }
            }
            addTeardownBlock { work.cancel(); reads.release(); await work.value }
            await fulfillment(of: [reads.started], timeout: 2)

            if logout { fixture.service.resetForLogout() }
            else { fixture.service.pauseForAuthentication() }
            reads.release()
            await work.value

            XCTAssertTrue(cancelled)
            XCTAssertEqual(reads.count, 1)
            if logout { XCTAssertTrue(fixture.queue.items.isEmpty) }
            else {
                XCTAssertEqual(fixture.queue.item(id: "photo")?.state, .waitingForAuthentication)
                XCTAssertEqual(fixture.queue.item(id: "photo")?.motionAssetID, "completed-motion")
                XCTAssertEqual(fixture.queue.item(id: "photo")?.intent, .manualUpload)
            }
        }
    }

    func testParentCancellationReachesTheRegisteredPreparationTask() async throws {
        let fixture = try fixture()
        try fixture.queue.enqueue(["photo"], intent: .manualUpload)
        let ownership = try XCTUnwrap(fixture.queue.ownership)
        let reads = ChunkReadGate(holdAt: 1)
        let repository = BackupRepository(api: APIClient(session: fixture.session), readChunk: reads.read)
        var cancelled = false
        let work = Task { await fixture.service.performPreparation(localIdentifier: "photo", isOwned: true,
            ownership: ownership) { _ in
                do {
                    try fixture.queue.markPreparing("photo", phase: .primaryAsset, motionAssetID: "saved-motion")
                    _ = try await repository.checksum(forFile: fixture.source)
                }
                catch is CancellationError { cancelled = true }
                catch { XCTFail("Unexpected preparation error: \(error)") }
            }
        }
        addTeardownBlock { work.cancel(); reads.release(); await work.value }
        await fulfillment(of: [reads.started], timeout: 2)

        work.cancel()
        reads.release()
        await work.value

        XCTAssertTrue(cancelled)
        XCTAssertEqual(reads.count, 1)
        XCTAssertEqual(fixture.queue.item(id: "photo")?.state, .queued)
        let restored = BackupQueueStore(fileURL: fixture.directory.appendingPathComponent("queue.json"))
        XCTAssertEqual(restored.item(id: "photo")?.motionAssetID, "saved-motion")
        XCTAssertEqual(BackupUploadRequests(queue: restored).readyItems(automaticEnabled: false).map(\.id), ["photo"])
    }

    func testCredentialRevisionChangeRequeuesTheUnfinishedBodyUnderTheSameOwner() async throws {
        let fixture = try fixture()
        try fixture.session.setServer("https://preparation-task.example")
        try fixture.queue.enqueue(["photo"], intent: .manualUpload)
        let ownership = try XCTUnwrap(fixture.queue.ownership)
        let reads = ChunkReadGate(holdAt: 1)
        let repository = BackupRepository(api: APIClient(session: fixture.session), readChunk: reads.read)
        var rejected = false
        let work = Task { await fixture.service.performPreparation(localIdentifier: "photo", isOwned: true,
            ownership: ownership) { _ in
                do {
                    try fixture.queue.markPreparing("photo", phase: .primaryAsset, motionAssetID: "saved-motion")
                    let prepared = try await repository.makeUploadRequest(fileURL: fixture.source, filename: "photo.jpg",
                        checksum: "known-checksum", deviceAssetId: "photo", createdAt: .distantPast, modifiedAt: .distantPast)
                    try? FileManager.default.removeItem(at: prepared.bodyFile)
                    XCTFail("An old credential revision cannot hand off the prepared body")
                } catch is CancellationError { rejected = true }
                catch { XCTFail("Unexpected preparation error: \(error)") }
            }
        }
        addTeardownBlock { work.cancel(); reads.release(); await work.value }
        await fulfillment(of: [reads.started], timeout: 2)

        // Same server/account, new request revision, as with credential renewal.
        try fixture.session.setServer("https://preparation-task.example")
        reads.release()
        await work.value

        XCTAssertTrue(rejected)
        XCTAssertEqual(fixture.queue.ownership, ownership)
        XCTAssertEqual(fixture.queue.item(id: "photo")?.state, .queued)
        XCTAssertEqual(fixture.queue.item(id: "photo")?.motionAssetID, "saved-motion")
        XCTAssertEqual(fixture.queue.item(id: "photo")?.intent, .manualUpload)
        let restored = BackupQueueStore(fileURL: fixture.directory.appendingPathComponent("queue.json"))
        XCTAssertEqual(restored.item(id: "photo")?.state, .queued)
        XCTAssertEqual(BackupUploadRequests(queue: restored).readyItems(automaticEnabled: false).map(\.id), ["photo"])
    }

    private func fixture() throws -> PreparationFixture {
        let fixture = try PreparationFixture()
        fixtures.append(fixture)
        return fixture
    }
}

@MainActor
private final class PreparationFixture {
    let directory: URL
    let source: URL
    let queue: BackupQueueStore
    let service: BackupService
    let session: PreparationSession

    init() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("preparation-task-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        source = directory.appendingPathComponent("source.mov")
        try Data("abc".utf8).write(to: source)
        let manager = SwiftDataManager(storeURL: directory.appendingPathComponent("test.store"),
            backupJournalURL: directory.appendingPathComponent("backup.json"))
        queue = BackupQueueStore(fileURL: directory.appendingPathComponent("queue.json"))
        session = try PreparationSession(dataManager: manager)
        service = BackupService(dataManager: manager, queue: queue)
        service.configure(session: session)
        XCTAssertTrue(manager.isPersistentStoreAvailable)
    }
}

@MainActor
private final class PreparationSession: SessionManager {
    override var backupQueueOwner: BackupQueueOwner? {
        .init(server: "https://preparation-task.example/api", userID: "owner")
    }

    init(dataManager: SwiftDataManager) throws {
        super.init(dataManager: dataManager, restoresSession: false)
        try setServer("https://preparation-task.example")
        isLoggedIn = true
    }
}
