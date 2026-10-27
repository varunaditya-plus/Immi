import Foundation
import XCTest
@testable import ImmichApp

final class TemporaryMediaStoreTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "temporary-media-store-tests-\(UUID().uuidString)",
                isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    func testShareFileMovesTheSourceIsUniqueAndRemovedExplicitly() throws {
        let firstSource = directory.appendingPathComponent("one")
        let secondSource = directory.appendingPathComponent("two")
        try Data("one".utf8).write(to: firstSource)
        try Data("two".utf8).write(to: secondSource)
        let first = try TemporaryMediaStore.adoptShareFile(
            at: firstSource,
            suggestedFilename: "../photo.jpg")
        let second = try TemporaryMediaStore.adoptShareFile(
            at: secondSource,
            suggestedFilename: "photo.jpg")
        defer { TemporaryMediaStore.remove([first, second]) }

        XCTAssertNotEqual(first, second)
        XCTAssertTrue(first.lastPathComponent.hasSuffix("-photo.jpg"))
        XCTAssertEqual(try Data(contentsOf: first), Data("one".utf8))
        XCTAssertEqual(try Data(contentsOf: second), Data("two".utf8))
        XCTAssertFalse(FileManager.default.fileExists(atPath: firstSource.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: secondSource.path))

        TemporaryMediaStore.remove(first)
        XCTAssertFalse(FileManager.default.fileExists(atPath: first.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: second.path))
    }

    func testAdoptingAManagedShareDoesNotMoveOrDeleteIt() throws {
        let source = directory.appendingPathComponent("source")
        try Data("movie".utf8).write(to: source)
        let managed = try TemporaryMediaStore.adoptShareFile(at: source, suggestedFilename: "movie.mp4")
        defer { TemporaryMediaStore.remove(managed) }

        let adopted = try TemporaryMediaStore.adoptShareFile(at: managed, suggestedFilename: "movie.mp4")

        XCTAssertEqual(adopted, managed)
        XCTAssertEqual(try Data(contentsOf: adopted), Data("movie".utf8))
    }

    func testFailedAdoptionRemovesItsOwnedSource() throws {
        let source = directory.appendingPathComponent("source")
        try Data("original".utf8).write(to: source)

        XCTAssertThrowsError(try TemporaryMediaStore.adoptShareFile(
            at: source, suggestedFilename: String(repeating: "x", count: 512) + ".mov"))

        XCTAssertFalse(FileManager.default.fileExists(atPath: source.path))
    }

    @MainActor
    func testCanceledAdoptionRemovesUnmanagedAndManagedSources() async throws {
        for alreadyManaged in [false, true] {
            let original = directory.appendingPathComponent(UUID().uuidString)
            try Data("original".utf8).write(to: original)
            let source = alreadyManaged
                ? try TemporaryMediaStore.adoptShareFile(at: original, suggestedFilename: "movie.mp4")
                : original
            let task = Task { try TemporaryMediaStore.adoptShareFile(at: source, suggestedFilename: "movie.mp4") }
            task.cancel()
            do {
                let file = try await task.value
                TemporaryMediaStore.remove(file)
                XCTFail("Canceled preparation must not produce a share file")
            } catch {
                XCTAssertTrue(error is CancellationError)
            }
            XCTAssertFalse(FileManager.default.fileExists(atPath: source.path))
        }
    }

    func testCleanupRemovesOnlyStaleRegularFiles() throws {
        let stale = directory.appendingPathComponent("old-video.mov")
        let fresh = directory.appendingPathComponent("fresh-photo.jpg")
        let nested = directory.appendingPathComponent("nested", isDirectory: true)
        try Data("old".utf8).write(to: stale)
        try Data("fresh".utf8).write(to: fresh)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)

        let now = Date()
        try FileManager.default.setAttributes(
            [.modificationDate: now.addingTimeInterval(-7_200)],
            ofItemAtPath: stale.path)
        try FileManager.default.setAttributes(
            [.modificationDate: now],
            ofItemAtPath: fresh.path)

        TemporaryMediaStore.cleanupStaleFiles(
            in: directory,
            olderThan: now.addingTimeInterval(-3_600))

        XCTAssertFalse(FileManager.default.fileExists(atPath: stale.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: fresh.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: nested.path))
    }

    func testCleanupPreservesBackgroundBackupFiles() throws {
        let multipart = directory.appendingPathComponent("upload-old.multipart")
        let source = directory.appendingPathComponent("backup-source-old.mov")
        try Data("body".utf8).write(to: multipart)
        try Data("source".utf8).write(to: source)

        let oldDate = Date().addingTimeInterval(-7_200)
        try FileManager.default.setAttributes(
            [.modificationDate: oldDate],
            ofItemAtPath: multipart.path)
        try FileManager.default.setAttributes(
            [.modificationDate: oldDate],
            ofItemAtPath: source.path)

        TemporaryMediaStore.cleanupStaleFiles(
            in: directory,
            olderThan: Date().addingTimeInterval(-3_600))

        XCTAssertTrue(FileManager.default.fileExists(atPath: multipart.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
    }

    func testColdLaunchCleanupRemovesMeasuredNestedTemporaryFiles() throws {
        let tmp = directory.appendingPathComponent("tmp")
        let cutoff = Date().addingTimeInterval(-86_400)
        for suffix in ["A7Toxm", "twrESE"] {
            let folder = tmp.appendingPathComponent("NSIRD_ImmichApp_\(suffix)")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let file = folder.appendingPathComponent(".old-working-file")
            try Data(repeating: 1, count: 12_000).write(to: file)
            for url in [file, folder] {
                try FileManager.default.setAttributes(
                    [.modificationDate: cutoff.addingTimeInterval(-60)], ofItemAtPath: url.path)
            }
        }
        XCTAssertGreaterThan(AppStorageUsage.scan(home: directory, shared: nil).temporaryFiles, 0)
        TemporaryMediaStore.cleanupStaleWorkingDirectories(in: tmp, olderThan: cutoff)
        XCTAssertEqual(AppStorageUsage.scan(home: directory, shared: nil).temporaryFiles, 0)
        // Repeated launches remain harmless.
        TemporaryMediaStore.cleanupStaleWorkingDirectories(in: tmp, olderThan: cutoff)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: tmp.path).isEmpty)
    }

    func testWorkingDirectoryCleanupPreservesRecentProtectedAndUnrelatedFiles() throws {
        let cutoff = Date().addingTimeInterval(-86_400)
        for (folderName, fileName, recent) in [
            ("NSIRD_ImmichApp_recent", "working", true),
            ("NSIRD_ImmichApp_backup", "upload-active.multipart", false),
            ("NSIRD_ImmichApp_source", "backup-source-video.mov", false),
            ("unrelated-directory", "working", false),
        ] {
            let folder = directory.appendingPathComponent(folderName)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let file = folder.appendingPathComponent(fileName)
            try Data([1]).write(to: file)
            try FileManager.default.setAttributes(
                [.modificationDate: recent ? Date() : cutoff.addingTimeInterval(-60)], ofItemAtPath: file.path)
            try FileManager.default.setAttributes(
                [.modificationDate: cutoff.addingTimeInterval(-60)], ofItemAtPath: folder.path)
            TemporaryMediaStore.cleanupStaleWorkingDirectories(in: directory, olderThan: cutoff)
            XCTAssertTrue(FileManager.default.fileExists(atPath: file.path), folderName)
        }
    }

    func testWorkingDirectoryCleanupDoesNotFollowSymbolicLinks() throws {
        let target = directory.appendingPathComponent("target")
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        let file = target.appendingPathComponent("preserve")
        try Data([1]).write(to: file)
        let link = directory.appendingPathComponent("NSIRD_ImmichApp_link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        TemporaryMediaStore.cleanupStaleWorkingDirectories(in: directory, olderThan: .distantFuture)
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
        XCTAssertTrue(try link.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == true)
    }
}
