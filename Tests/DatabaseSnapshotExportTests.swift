import SQLite3
import XCTest
@testable import ImmichApp

@MainActor
final class DatabaseSnapshotExportTests: XCTestCase {
    private var directory: URL!
    private var manager: SwiftDataManager!
    private var copies: [SwiftDataManager] = []
    private var exports: [URL] = []

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("database-snapshot-tests-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        manager = SwiftDataManager(storeURL: directory.appendingPathComponent("source.store"),
            backupJournalURL: directory.appendingPathComponent("source-journal.json"))
        XCTAssertTrue(manager.isPersistentStoreAvailable)
    }

    override func tearDown() async throws {
        copies.removeAll()
        manager = nil
        for url in exports { try? FileManager.default.removeItem(at: url) }
        exports.removeAll()
        try? FileManager.default.removeItem(at: directory)
        directory = nil
    }

    func testExportContainsCommittedRecordsAndRemainsIndependentOfTheWorkingDatabase() async throws {
        try manager.restoreToTimeline([photo("before-export")])

        let url = try await manager.exportDatabase()
        exports.append(url)
        XCTAssertNotEqual(url, directory.appendingPathComponent("source.store"))
        XCTAssertEqual(try integrity(of: url), "ok")
        let copy = SwiftDataManager(storeURL: url, backupJournalURL: directory.appendingPathComponent("copy-journal.json"))
        copies.append(copy)
        XCTAssertEqual(copy.timelineAssets().map(\.asset.id), ["before-export"])

        try manager.restoreToTimeline([photo("after-export")])

        XCTAssertEqual(Set(manager.timelineAssets().map(\.asset.id)), ["before-export", "after-export"])
        XCTAssertEqual(copy.timelineAssets().map(\.asset.id), ["before-export"],
            "The activity receives a snapshot, not a live link to the working store")
    }

    func testOverlappingExportsHaveIndependentReadableFiles() async throws {
        try manager.restoreToTimeline([photo("shared-source")])
        // Separate windows can request snapshots within the same clock second.
        let requests = (0..<8).map { _ in
            Task { () -> Result<URL, Error> in
                do { return .success(try await self.manager.exportDatabase()) }
                catch { return .failure(error) }
            }
        }
        var errors: [String] = []
        for request in requests {
            switch await request.value {
            case .success(let url): exports.append(url)
            case .failure(let error): errors.append(error.localizedDescription)
            }
        }
        XCTAssertTrue(errors.isEmpty, "Every independent request must complete: \(errors)")
        XCTAssertEqual(exports.count, 8)
        XCTAssertEqual(Set(exports).count, 8, "One export must never overwrite another export's active file")
        for url in Set(exports) { XCTAssertEqual(try integrity(of: url), "ok") }
        let first = try XCTUnwrap(exports.first)
        try FileManager.default.removeItem(at: first)
        for url in Set(exports).subtracting([first]) {
            XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
            XCTAssertEqual(try integrity(of: url), "ok")
        }
    }

    func testFailedSnapshotRemovesItsPartialFileAndLeavesOtherExportsAlone() throws {
        let source = directory.appendingPathComponent("invalid.sqlite")
        let destination = directory.appendingPathComponent("failed.sqlite")
        let active = directory.appendingPathComponent("active.sqlite")
        try Data("not a SQLite database".utf8).write(to: source)
        try Data("active export".utf8).write(to: active)

        XCTAssertThrowsError(try SwiftDataManager.createDatabaseSnapshot(from: source, to: destination))

        for suffix in ["", "-wal", "-shm", "-journal"] {
            XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path + suffix),
                "A failed database export must not retain its partial output")
        }
        XCTAssertEqual(try Data(contentsOf: active), Data("active export".utf8))
    }

    func testAlreadyCanceledExportCreatesNoShareableSnapshot() async throws {
        let before = Set(try FileManager.default.contentsOfDirectory(
            at: FileManager.default.temporaryDirectory, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix("Immich-Sync-") })
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await manager.exportDatabase()
        }
        do {
            let url = try await task.value
            exports.append(url)
            XCTFail("A canceled export must not produce a database file")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
        let after = Set(try FileManager.default.contentsOfDirectory(
            at: FileManager.default.temporaryDirectory, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix("Immich-Sync-") })
        XCTAssertEqual(after, before)
    }

    func testCancelingAnInProgressSnapshotRemovesItsPartialFileAndKeepsTheSourceReadable() async throws {
        let source = directory.appendingPathComponent("large.sqlite")
        let destination = directory.appendingPathComponent("canceled.sqlite")
        var database: OpaquePointer?
        guard sqlite3_open(source.path, &database) == SQLITE_OK else {
            if database != nil { sqlite3_close(database) }
            throw LocalDatabaseMaintenanceError.exportFailed
        }
        let created = sqlite3_exec(database,
            "CREATE TABLE payload(bytes BLOB); INSERT INTO payload VALUES(zeroblob(536870912));", nil, nil, nil)
        sqlite3_close(database)
        XCTAssertEqual(created, SQLITE_OK)
        let status = SnapshotCopyStatus()
        let task = Task.detached {
            defer { status.finish() }
            try SwiftDataManager.createDatabaseSnapshot(from: source, to: destination)
        }
        addTeardownBlock { task.cancel(); _ = try? await task.value }
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        var observedPartialCopy = false
        while ContinuousClock.now < deadline, !status.isFinished {
            let bytes = (try? FileManager.default.attributesOfItem(atPath: destination.path)[.size] as? NSNumber)?.int64Value ?? 0
            if bytes >= 4 * 1024 * 1024, !status.isFinished {
                observedPartialCopy = true
                break
            }
            try await Task.sleep(for: .milliseconds(1))
        }
        XCTAssertTrue(observedPartialCopy, "Cancellation must be exercised after copying started, before completion")
        task.cancel()
        do {
            try await task.value
            XCTFail("A snapshot canceled during copying must not finish successfully")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }

        for suffix in ["", "-wal", "-shm", "-journal"] {
            XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path + suffix))
        }
        XCTAssertEqual(try integrity(of: source), "ok")
    }

    private func photo(_ id: String) -> AssetLite {
        AssetLite(id: id, isVideo: false, ratio: 1, thumbhash: nil, createdAt: .distantPast)
    }

    private func integrity(of url: URL) throws -> String {
        for suffix in ["-wal", "-shm", "-journal"] {
            XCTAssertFalse(FileManager.default.fileExists(atPath: url.path + suffix),
                "A shared SQLite snapshot must not depend on unshared sidecar files")
        }
        var database: OpaquePointer?
        guard sqlite3_open_v2(url.path, &database, SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
            if database != nil { sqlite3_close(database) }
            throw LocalDatabaseMaintenanceError.exportFailed
        }
        defer { sqlite3_close(database) }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, "PRAGMA integrity_check", -1, &statement, nil) == SQLITE_OK else {
            throw LocalDatabaseMaintenanceError.exportFailed
        }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW,
              let text = sqlite3_column_text(statement, 0) else {
            throw LocalDatabaseMaintenanceError.exportFailed
        }
        return String(cString: text)
    }
}

private final class SnapshotCopyStatus: @unchecked Sendable {
    private let lock = NSLock()
    private var finished = false
    var isFinished: Bool {
        lock.lock()
        defer { lock.unlock() }
        return finished
    }
    func finish() {
        lock.lock()
        finished = true
        lock.unlock()
    }
}
