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
