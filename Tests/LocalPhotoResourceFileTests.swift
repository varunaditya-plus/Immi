import Photos
import XCTest
@testable import ImmichApp

@MainActor
final class LocalPhotoResourceFileTests: XCTestCase {
    private var directories: [URL] = []

    override func tearDown() async throws {
        for directory in directories { try? FileManager.default.removeItem(at: directory) }
        directories.removeAll()
        try await super.tearDown()
    }

    func testResourceChunksPreserveTheOriginalBytesAndExtension() async throws {
        let directory = try directory()
        let requests = ResourceFileRequests()
        requests.onStart = { attempt in
            attempt.data(Data("first chunk".utf8))
            attempt.data(Data([0, 255, 13, 10]))
            attempt.finish(nil)
            attempt.data(Data("late bytes".utf8))
            attempt.finish(URLError(.cancelled))
        }

        let result = await export(requests, directory: directory)

        let file = try XCTUnwrap(result)
        XCTAssertEqual(file.pathExtension, "HEIC")
        XCTAssertEqual(try Data(contentsOf: file), Data("first chunk".utf8) + Data([0, 255, 13, 10]))
        XCTAssertEqual(requests.networkFlags, [false])
        XCTAssertTrue(requests.cancelledIDs.isEmpty)
        XCTAssertEqual(try files(in: directory), [file])
    }

    func testLocalFailureCleansItsPartialFileBeforeTheNetworkFallback() async throws {
        let directory = try directory()
        let requests = ResourceFileRequests()
        requests.onStart = { attempt in
            if attempt.allowsNetwork {
                XCTAssertEqual((try? FileManager.default.contentsOfDirectory(atPath: directory.path))?.count, 1)
                attempt.data(Data("downloaded original".utf8))
                attempt.finish(nil)
            } else {
                attempt.data(Data("incomplete local data".utf8))
                attempt.finish(URLError(.resourceUnavailable))
            }
        }

        let result = await export(requests, directory: directory)

        let file = try XCTUnwrap(result)
        XCTAssertEqual(try Data(contentsOf: file), Data("downloaded original".utf8))
        XCTAssertEqual(requests.networkFlags, [false, true])
        XCTAssertEqual(try files(in: directory), [file])
    }

    func testLocalOnlyFailureRemovesItsPartialFileWithoutStartingANetworkRequest() async throws {
        let directory = try directory()
        let requests = ResourceFileRequests()
        requests.onStart = { attempt in
            attempt.data(Data("partial".utf8))
            attempt.finish(URLError(.resourceUnavailable))
        }

        let result = await export(requests, directory: directory, allowsNetworkFallback: false)

        XCTAssertNil(result)
        XCTAssertEqual(requests.networkFlags, [false])
        XCTAssertTrue(try files(in: directory).isEmpty)
    }

    func testAlreadyCancelledExportDoesNotCreateAFileOrStartPhotoKit() async throws {
        let directory = try directory()
        let requests = ResourceFileRequests()
        let task = Task { await export(requests, directory: directory) }
        task.cancel()

        let result = await task.value

        XCTAssertNil(result)
        XCTAssertTrue(requests.networkFlags.isEmpty)
        XCTAssertTrue(try files(in: directory).isEmpty)
    }

    func testCancellationStopsTheActivePhotoKitRequestAndDeletesItsPartialFile() async throws {
        let directory = try directory()
        let requests = ResourceFileRequests()
        let task = Task { await export(requests, directory: directory) }
        await fulfillment(of: [requests.started], timeout: 2)
        let attempt = try XCTUnwrap(requests.attempts.first)
        attempt.data(Data("partial original".utf8))
        let partial = try XCTUnwrap(try files(in: directory).first)
        XCTAssertEqual(try Data(contentsOf: partial), Data("partial original".utf8))

        task.cancel()

        XCTAssertFalse(FileManager.default.fileExists(atPath: partial.path))
        attempt.data(Data("late original bytes".utf8))
        attempt.finish(URLError(.cancelled))
        attempt.finish(nil)
        let result = await task.value
        XCTAssertNil(result)
        XCTAssertEqual(requests.cancelledIDs, [attempt.id])
        XCTAssertEqual(requests.networkFlags, [false], "A canceled local export must not start iCloud fallback")
        XCTAssertTrue(try files(in: directory).isEmpty)
    }

    func testCancellationBeforePhotoKitReturnsItsRequestIDStillCancelsThatRequest() async throws {
        let directory = try directory()
        let requests = ResourceFileRequests()
        let handle = ResourceExportTaskHandle()
        requests.onStart = { attempt in
            attempt.data(Data("partial before request ID".utf8))
            handle.cancel()
            attempt.finish(URLError(.cancelled))
        }
        let task = Task { await export(requests, directory: directory) }
        handle.set(task)

        let result = await task.value

        XCTAssertNil(result)
        XCTAssertEqual(requests.networkFlags, [false])
        XCTAssertEqual(requests.cancelledIDs, requests.attempts.map(\.id))
        XCTAssertEqual(requests.cancelledIDs.count, 1)
        XCTAssertTrue(try files(in: directory).isEmpty)
    }

    func testUnwritableDestinationDoesNotStartPhotoKitOrDeleteANeighbor() async throws {
        let directory = try directory()
        let neighbor = directory.appendingPathComponent("neighbor.jpg")
        try Data("neighbor".utf8).write(to: neighbor)
        let requests = ResourceFileRequests()

        let result = await export(requests, directory: neighbor)

        XCTAssertNil(result)
        XCTAssertTrue(requests.networkFlags.isEmpty)
        XCTAssertEqual(try Data(contentsOf: neighbor), Data("neighbor".utf8))
        XCTAssertEqual(try files(in: directory), [neighbor])
    }

    private func export(
        _ requests: ResourceFileRequests, directory: URL, allowsNetworkFallback: Bool = true
    ) async -> URL? {
        await LocalPhotoResourceFile.export(
            filename: "original.HEIC", allowsNetworkFallback: allowsNetworkFallback, directory: directory,
            request: { requests.start(allowsNetwork: $0, data: $1, finish: $2) },
            cancel: { requests.cancel($0) })
    }

    private func directory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("PhotoResource-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        directories.append(directory)
        return directory
    }

    private func files(in directory: URL) throws -> [URL] {
        try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
    }
}

private final class ResourceFileRequests: @unchecked Sendable {
    struct Attempt {
        let id: PHAssetResourceDataRequestID
        let allowsNetwork: Bool
        let data: @Sendable (Data) -> Void
        let finish: @Sendable (Error?) -> Void
    }

    let started = XCTestExpectation(description: "PhotoKit resource request started")
    var onStart: (@Sendable (Attempt) -> Void)?
    private let lock = NSLock()
    private var savedAttempts: [Attempt] = []
    private var savedCancelledIDs: [PHAssetResourceDataRequestID] = []
    var attempts: [Attempt] { lock.withLock { savedAttempts } }
    var networkFlags: [Bool] { attempts.map(\.allowsNetwork) }
    var cancelledIDs: [PHAssetResourceDataRequestID] { lock.withLock { savedCancelledIDs } }

    func start(
        allowsNetwork: Bool, data: @escaping @Sendable (Data) -> Void,
        finish: @escaping @Sendable (Error?) -> Void
    ) -> PHAssetResourceDataRequestID {
        let attempt = lock.withLock {
            let attempt = Attempt(id: PHAssetResourceDataRequestID(savedAttempts.count + 1),
                allowsNetwork: allowsNetwork, data: data, finish: finish)
            savedAttempts.append(attempt)
            return attempt
        }
        if attempt.id == 1 { started.fulfill() }
        onStart?(attempt)
        return attempt.id
    }

    func cancel(_ id: PHAssetResourceDataRequestID) { lock.withLock { savedCancelledIDs.append(id) } }
}

private final class ResourceExportTaskHandle: @unchecked Sendable {
    private let lock = NSLock()
    private var task: Task<URL?, Never>?
    func set(_ task: Task<URL?, Never>) { lock.withLock { self.task = task } }
    func cancel() { lock.withLock { task }?.cancel() }
}
