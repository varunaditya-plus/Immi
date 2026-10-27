import UIKit
import XCTest
@testable import ImmichApp

@MainActor
final class ImageCacheInvalidationTests: XCTestCase {
    func testOldCompletionCannotLoseTheReplacementRequestsCancellation() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = ImageCache(diskCacheURL: directory)
        let key = UUID().uuidString
        let oldFetch = HeldImageFetch()
        let currentFetch = HeldImageFetch()
        let old = Task { try await cache.image(key: key, maxPixelSize: nil) { await oldFetch.fetch() } }
        await fulfillment(of: [oldFetch.started], timeout: 2)
        await cache.remove(key: key, maxPixelSize: nil)
        let current = Task { try await cache.image(key: key, maxPixelSize: nil) { await currentFetch.fetch() } }
        await fulfillment(of: [currentFetch.started], timeout: 2)
        await oldFetch.resolve(png(width: 10))
        await assertCancelled(old)

        // The old completion must leave the replacement registered, so this
        // invalidation still cancels its fetch and prevents it entering L1/L2.
        await cache.remove(key: key, maxPixelSize: nil)
        await currentFetch.resolve(png(width: 20))
        await assertCancelled(current)
        XCTAssertNil(ImageMemoryCache.shared.image(for: ImageCache.memoryKey(key, nil)))
        let diskSize = await cache.diskCacheSize()
        XCTAssertEqual(diskSize, 0)

        let replacement = try await cache.image(key: key, maxPixelSize: nil) { self.png(width: 30) }
        XCTAssertEqual(replacement.size.width, 30)
        await cache.remove(key: key, maxPixelSize: nil)
    }

    func testInvalidationDuringStagedWriteCannotRestoreOldDiskBytes() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let writes = HeldImageWrites()
        let cache = ImageCache(diskCacheURL: directory, stageWrite: { await writes.stage($0) })
        let key = UUID().uuidString
        let oldData = png(width: 10)
        let currentData = png(width: 20)
        let old = Task { try await cache.image(key: key, maxPixelSize: nil) { oldData } }
        try await waitUntil { await writes.count == 1 }
        await cache.remove(key: key, maxPixelSize: nil)
        let current = Task { try await cache.image(key: key, maxPixelSize: nil) { currentData } }
        try await waitUntil { await writes.count == 2 }
        await writes.release(1)
        let currentImage = try await current.value
        XCTAssertEqual(currentImage.size.width, 20)
        await writes.release(0)
        await assertCancelled(old)

        // Read the disk variant afresh; an L1 hit would hide stale disk bytes.
        ImageMemoryCache.shared.remove(for: ImageCache.memoryKey(key, nil))
        let diskImage = try await cache.image(key: key, maxPixelSize: nil) {
            XCTFail("The current preview should already be on disk")
            return oldData
        }
        XCTAssertEqual(diskImage.size.width, 20)
        let temporaryPaths = await writes.paths
        XCTAssertTrue(temporaryPaths.allSatisfy { !FileManager.default.fileExists(atPath: $0.path) })
        await cache.remove(key: key, maxPixelSize: nil)
    }

    func testConcurrentReadersStillShareTheCurrentFetchAndDecodedImage() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = ImageCache(diskCacheURL: directory)
        let key = UUID().uuidString
        let fetch = HeldImageFetch()
        let first = Task { try await cache.image(key: key, maxPixelSize: nil) { await fetch.fetch() } }
        await fulfillment(of: [fetch.started], timeout: 2)
        let joinedStarted = expectation(description: "second reader called cache")
        let unexpectedFetch = expectation(description: "duplicate fetch")
        unexpectedFetch.isInverted = true
        let fallback = png(width: 10)
        let second = Task {
            joinedStarted.fulfill()
            return try await cache.image(key: key, maxPixelSize: nil) {
                unexpectedFetch.fulfill()
                return fallback
            }
        }
        await fulfillment(of: [joinedStarted, unexpectedFetch], timeout: 0.1)
        await fetch.resolve(png(width: 20))
        let firstImage = try await first.value
        let secondImage = try await second.value
        XCTAssertEqual(firstImage.size.width, 20)
        XCTAssertTrue(firstImage === secondImage)
        await cache.remove(key: key, maxPixelSize: nil)
    }

    func testConcurrentSizeVariantsCanCommitToTheSameDiskEntry() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let writes = HeldImageWrites()
        let cache = ImageCache(diskCacheURL: directory, stageWrite: { await writes.stage($0) })
        let key = UUID().uuidString
        let data = png(width: 20)
        let fullSize = Task { try await cache.image(key: key, maxPixelSize: nil) { data } }
        try await waitUntil { await writes.count == 1 }
        let smallSize = Task { try await cache.image(key: key, maxPixelSize: 5) { data } }
        try await waitUntil { await writes.count == 2 }
        await writes.release(0)
        let fullImage = try await fullSize.value
        XCTAssertEqual(fullImage.size.width, 20)
        await writes.release(1)
        let smallImage = try await smallSize.value
        XCTAssertEqual(smallImage.size.width, 5)
        ImageMemoryCache.shared.remove(for: ImageCache.memoryKey(key, nil))
        let diskImage = try await cache.image(key: key, maxPixelSize: nil) {
            XCTFail("The second size variant must preserve the committed original bytes")
            return data
        }
        XCTAssertEqual(diskImage.size.width, 20)
        await cache.remove(key: key, maxPixelSize: nil)
        await cache.remove(key: key, maxPixelSize: 5)
    }

    private func makeDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private nonisolated func png(width: Int) -> Data {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: CGSize(width: width, height: 10), format: format).pngData { context in
            UIColor.blue.setFill()
            context.fill(CGRect(x: 0, y: 0, width: width, height: 10))
        }
    }

    private func assertCancelled(_ task: Task<UIImage, Error>, file: StaticString = #filePath, line: UInt = #line) async {
        do {
            _ = try await task.value
            XCTFail("Invalidated preview must fail with cancellation", file: file, line: line)
        } catch {
            XCTAssertTrue(error is CancellationError, "Unexpected error: \(error)", file: file, line: line)
        }
    }

    private func waitUntil(_ predicate: () async -> Bool, file: StaticString = #filePath, line: UInt = #line) async throws {
        let deadline = Date().addingTimeInterval(2)
        while !(await predicate()), Date() < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
        let satisfied = await predicate()
        _ = try XCTUnwrap(satisfied ? true : nil, "Condition did not become true before timeout", file: file, line: line)
    }
}

private actor HeldImageFetch {
    nonisolated let started = XCTestExpectation(description: "image fetch started")
    private var continuation: CheckedContinuation<Data, Never>?

    func fetch() async -> Data {
        await withCheckedContinuation {
            continuation = $0
            started.fulfill()
        }
    }

    func resolve(_ data: Data) {
        precondition(continuation != nil)
        continuation?.resume(returning: data)
        continuation = nil
    }
}

private actor HeldImageWrites {
    private var continuations: [CheckedContinuation<URL?, Never>] = []
    private(set) var paths: [URL] = []
    var count: Int { continuations.count }

    func stage(_ data: Data) async -> URL? {
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        do { try data.write(to: temporary, options: .atomic) }
        catch { return nil }
        paths.append(temporary)
        return await withCheckedContinuation { continuations.append($0) }
    }

    func release(_ index: Int) { continuations[index].resume(returning: paths[index]) }
}
