import CryptoKit
import XCTest
@testable import ImmichApp

@MainActor
final class DeviceAssetChecksumTests: XCTestCase {
    private var directories: [URL] = []

    override func tearDown() async throws {
        for directory in directories { try? FileManager.default.removeItem(at: directory) }
        directories.removeAll()
        try await super.tearDown()
    }

    func testFileChecksumMatchesKnownEmptyAndSmallDigests() async throws {
        let directory = try directory()
        let repository = BackupRepository(api: makeStubAPIClient())
        for (name, bytes, expected) in [
            ("empty", Data(), "da39a3ee5e6b4b0d3255bfef95601890afd80709"),
            ("abc", Data("abc".utf8), "a9993e364706816aba3e25717850c26c9cd0d89d"),
        ] {
            let file = directory.appendingPathComponent(name)
            try bytes.write(to: file)

            let checksum = try await repository.checksum(forFile: file)

            XCTAssertEqual(checksum, expected)
            XCTAssertEqual(try Data(contentsOf: file), bytes, "Hashing must not consume its caller's source")
        }
    }

    func testFileChecksumReadsEveryChunkAndTheFinalPartialChunk() async throws {
        let directory = try directory()
        let file = directory.appendingPathComponent("long.mov")
        var bytes = Data(repeating: 0x71, count: 2 * 1024 * 1024)
        bytes.append(Data((0..<31).map(UInt8.init)))
        try bytes.write(to: file)
        let expected = Insecure.SHA1.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        let repository = BackupRepository(api: makeStubAPIClient())

        let checksum = try await repository.checksum(forFile: file)

        XCTAssertEqual(checksum, expected)
        XCTAssertEqual(try file.resourceValues(forKeys: [.fileSizeKey]).fileSize, bytes.count)
    }

    func testAlreadyCanceledFileChecksumThrowsRatherThanReturningADigest() async throws {
        let file = try directory().appendingPathComponent("original.mov")
        try Data("original bytes".utf8).write(to: file)
        let repository = BackupRepository(api: makeStubAPIClient())
        let task = Task { try await repository.checksum(forFile: file) }
        task.cancel()

        do {
            _ = try await task.value
            XCTFail("Canceled hashing must not report a completed checksum")
        } catch is CancellationError {
            XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
        }
    }

    func testMissingFileChecksumThrows() async throws {
        let file = try directory().appendingPathComponent("missing.mov")
        let repository = BackupRepository(api: makeStubAPIClient())
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
        do {
            _ = try await repository.checksum(forFile: file)
            XCTFail("An unreadable source must not produce a checksum")
        } catch is CancellationError {
            XCTFail("A missing source is not task cancellation")
        } catch {
            XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
        }
    }

    func testMatcherHashesExportedFilesSequentiallyAndRemovesEachTemporarySource() async throws {
        let directory = try directory()
        let repository = RecordingFileChecksumRepository(api: makeStubAPIClient())
        var exportedIDs: [String] = []
        var exportedURLs: [URL] = []
        let matcher = matcher(repository: repository, directory: directory) { id in
            XCTAssertTrue(exportedURLs.allSatisfy { !FileManager.default.fileExists(atPath: $0.path) },
                "The previous file must be released before exporting another original")
            exportedIDs.append(id)
            let localID = LocalPhotoLibrary.localIdentifier(from: id)
            let file = directory.appendingPathComponent("\(localID).mov")
            try? Data(localID.utf8).write(to: file)
            exportedURLs.append(file)
            return file
        }

        let checksums = await matcher.computeChecksums(["first", "second"])

        XCTAssertEqual(exportedIDs, ["device:first", "device:second"])
        XCTAssertEqual(repository.files, exportedURLs)
        XCTAssertEqual(checksums.map(\.localIdentifier), ["first", "second"])
        let expected = ["first", "second"].map { id in
            Insecure.SHA1.hash(data: Data(id.utf8)).map { String(format: "%02x", $0) }.joined()
        }
        XCTAssertEqual(checksums.map(\.checksum), expected)
        XCTAssertTrue(exportedURLs.allSatisfy { !FileManager.default.fileExists(atPath: $0.path) })
    }

    func testMatcherCleansFailedHashSourcesAndContinuesWithTheNextFile() async throws {
        let directory = try directory()
        let repository = RecordingFileChecksumRepository(api: makeStubAPIClient())
        repository.failedName = "bad.mov"
        let unrelated = directory.appendingPathComponent("unrelated.mov")
        try Data("preserve me".utf8).write(to: unrelated)
        var exportedURLs: [URL] = []
        let matcher = matcher(repository: repository, directory: directory) { id in
            let localID = LocalPhotoLibrary.localIdentifier(from: id)
            let file = directory.appendingPathComponent("\(localID).mov")
            try? Data(localID.utf8).write(to: file)
            exportedURLs.append(file)
            return file
        }

        let checksums = await matcher.computeChecksums(["bad", "good"])

        XCTAssertEqual(repository.files.map(\.lastPathComponent), ["bad.mov", "good.mov"])
        XCTAssertEqual(checksums.map(\.localIdentifier), ["good"])
        XCTAssertTrue(exportedURLs.allSatisfy { !FileManager.default.fileExists(atPath: $0.path) })
        XCTAssertEqual(try Data(contentsOf: unrelated), Data("preserve me".utf8))
    }

    func testMissingExportIsSkippedWithoutPreventingLaterHashes() async throws {
        let directory = try directory()
        let repository = RecordingFileChecksumRepository(api: makeStubAPIClient())
        var requested: [String] = []
        let matcher = matcher(repository: repository, directory: directory) { id in
            requested.append(id)
            let localID = LocalPhotoLibrary.localIdentifier(from: id)
            guard localID != "missing" else { return nil }
            let file = directory.appendingPathComponent("\(localID).jpg")
            try? Data("abc".utf8).write(to: file)
            return file
        }

        let checksums = await matcher.computeChecksums(["missing", "available"])

        XCTAssertEqual(requested, ["device:missing", "device:available"])
        XCTAssertEqual(repository.files.map(\.lastPathComponent), ["available.jpg"])
        XCTAssertEqual(checksums.map(\.localIdentifier), ["available"])
        XCTAssertEqual(checksums.map(\.checksum), ["a9993e364706816aba3e25717850c26c9cd0d89d"])
    }

    func testCancellationAfterExportReleasesTheSourceWithoutHashingOrExportingMore() async throws {
        let directory = try directory()
        let file = directory.appendingPathComponent("exported.mov")
        try Data("exported bytes".utf8).write(to: file)
        let export = DeferredChecksumFileExport()
        let repository = RecordingFileChecksumRepository(api: makeStubAPIClient())
        let matcher = matcher(repository: repository, directory: directory) { id in
            await export.file(for: id)
        }
        let task = Task { await matcher.computeChecksums(["first", "second"]) }
        await fulfillment(of: [export.started], timeout: 2)
        task.cancel()
        await export.complete(with: file)

        let checksums = await task.value

        XCTAssertTrue(checksums.isEmpty)
        XCTAssertTrue(repository.files.isEmpty)
        let ids = await export.ids
        XCTAssertEqual(ids, ["device:first"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
    }

    func testCancellationWhileHashingDiscardsALateResultAndReleasesTheSource() async throws {
        let directory = try directory()
        let file = directory.appendingPathComponent("exported.mov")
        try Data("abc".utf8).write(to: file)
        let repository = DeferredFileChecksumRepository(api: makeStubAPIClient())
        var exportedIDs: [String] = []
        let matcher = matcher(repository: repository, directory: directory) { id in
            exportedIDs.append(id)
            return file
        }
        let task = Task { await matcher.computeChecksums(["first", "second"]) }
        await fulfillment(of: [repository.probe.started], timeout: 2)
        task.cancel()
        await repository.probe.complete(with: "a9993e364706816aba3e25717850c26c9cd0d89d")

        let checksums = await task.value

        XCTAssertTrue(checksums.isEmpty)
        XCTAssertEqual(exportedIDs, ["device:first"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
    }

    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("checksum-files-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        directories.append(url)
        return url
    }

    private func matcher(
        repository: BackupRepository,
        directory: URL,
        originalFile: @escaping (String) async -> URL?
    ) -> DeviceAssetMatcher {
        let manager = SwiftDataManager(
            storeURL: directory.appendingPathComponent("cache.sqlite"),
            backupJournalURL: directory.appendingPathComponent("backup.json"))
        return DeviceAssetMatcher(repo: repository, dataManager: manager, originalFile: originalFile)
    }
}

private final class RecordingFileChecksumRepository: BackupRepository {
    var files: [URL] = []
    var failedName: String?

    override func checksum(forFile url: URL) async throws -> String {
        files.append(url)
        if url.lastPathComponent == failedName { throw CocoaError(.fileReadUnknown) }
        return try await super.checksum(forFile: url)
    }
}

private actor DeferredChecksumFileExport {
    nonisolated let started = XCTestExpectation(description: "Original file export started")
    private(set) var ids: [String] = []
    private var continuation: CheckedContinuation<URL?, Never>?
    private var result: URL?

    func file(for id: String) async -> URL? {
        ids.append(id)
        if let result { return result }
        return await withCheckedContinuation {
            continuation = $0
            started.fulfill()
        }
    }

    func complete(with url: URL) {
        result = url
        continuation?.resume(returning: url)
        continuation = nil
    }
}

private final class DeferredFileChecksumRepository: BackupRepository {
    let probe = DeferredChecksumHash()

    override func checksum(forFile url: URL) async throws -> String {
        await probe.hash()
    }
}

private actor DeferredChecksumHash {
    nonisolated let started = XCTestExpectation(description: "File hashing started")
    private var continuation: CheckedContinuation<String, Never>?
    private var result: String?

    func hash() async -> String {
        if let result { return result }
        return await withCheckedContinuation {
            continuation = $0
            started.fulfill()
        }
    }

    func complete(with checksum: String) {
        result = checksum
        continuation?.resume(returning: checksum)
        continuation = nil
    }
}
