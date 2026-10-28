import Observation
import SwiftUI
import UIKit
import XCTest
@testable import ImmichApp

@MainActor
final class DatabaseExportSharingTests: XCTestCase {
    private var directory: URL!
    private var managedFiles: [URL] = []

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("database-export-sharing-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        TemporaryMediaStore.remove(managedFiles)
        managedFiles.removeAll()
        try? FileManager.default.removeItem(at: directory)
        directory = nil
    }

    func testActualActivityCompletionCleansItsExportAndPresentationForSuccessCancelAndError() async throws {
        for outcome in 0..<3 {
            let sharing = DatabaseExportSharing()
            let session = try session()
            let source = try file("database-\(outcome).sqlite", bytes: "database-\(outcome)")
            let unrelated = try managedFile("active-photo.jpg")
            let error = await sharing.prepare(session: session) { source }
            XCTAssertNil(error)
            let item = try XCTUnwrap(sharing.presentation)
            managedFiles.append(item.url)
            XCTAssertFalse(exists(source))
            XCTAssertEqual(try Data(contentsOf: item.url), Data("database-\(outcome)".utf8))

            let sheet = sharing.shareSheet(for: item)
            let coordinator = sheet.makeCoordinator()
            let controller = sheet.activityController(using: coordinator)
            let finished = expectation(description: "Activity completion clears the export presentation")
            withObservationTracking { _ = sharing.presentation } onChange: { finished.fulfill() }
            let handler = try XCTUnwrap(controller.completionWithItemsHandler)
            handler(nil, outcome == 0, nil, outcome == 2 ? CocoaError(.fileReadUnknown) : nil)
            await fulfillment(of: [finished], timeout: 2)

            XCTAssertNil(sharing.presentation)
            XCTAssertFalse(exists(item.url))
            XCTAssertTrue(exists(unrelated), "Completing one share must preserve another active file")
            MultiShareSheet.dismantleUIViewController(controller, coordinator: coordinator)
            XCTAssertTrue(exists(unrelated))
        }
    }

    func testDismantlingAnActivityWithoutCompletionCleansOnlyItsExportAndCallsFinishOnce() async throws {
        let sharing = DatabaseExportSharing()
        let session = try session()
        let source = try file("database.sqlite")
        _ = await sharing.prepare(session: session) { source }
        let item = try XCTUnwrap(sharing.presentation)
        managedFiles.append(item.url)
        let unrelated = try managedFile("other-database.sqlite")
        let response = FinishCounter()
        let sheet = MultiShareSheet(urls: [item.url], onFinish: { response.count += 1 })
        let coordinator = sheet.makeCoordinator()
        let controller = sheet.activityController(using: coordinator)
        XCTAssertTrue(exists(item.url), "An active activity keeps its file until completion or dismantling")

        MultiShareSheet.dismantleUIViewController(controller, coordinator: coordinator)
        XCTAssertEqual(response.count, 1, "Dismantling alone must finish the share without waiting for a completion callback")
        XCTAssertFalse(exists(item.url))
        XCTAssertTrue(exists(unrelated))
        controller.completionWithItemsHandler?(nil, false, nil, nil)
        MultiShareSheet.dismantleUIViewController(controller, coordinator: coordinator)

        XCTAssertEqual(response.count, 1)
        XCTAssertFalse(exists(item.url))
        XCTAssertTrue(exists(unrelated))
    }

    func testAnOldBindingAndFinishCannotDeleteANewerExport() async throws {
        let sharing = DatabaseExportSharing()
        let session = try session()
        let firstSource = try file("first.sqlite"), secondSource = try file("second.sqlite")
        _ = await sharing.prepare(session: session) { firstSource }
        let first = try XCTUnwrap(sharing.presentation)
        managedFiles.append(first.url)
        let oldBinding = sharing.binding
        let oldSheet = sharing.shareSheet(for: first)
        let oldCoordinator = oldSheet.makeCoordinator()
        let oldController = oldSheet.activityController(using: oldCoordinator)
        sharing.finish(first.id)
        _ = await sharing.prepare(session: session) { secondSource }
        let second = try XCTUnwrap(sharing.presentation)
        managedFiles.append(second.url)

        oldBinding.wrappedValue = nil
        oldController.completionWithItemsHandler?(nil, false, nil, nil)
        // The production activity schedules its ID-scoped finish on MainActor.
        // Check the newer export after the queued main-thread callback runs.
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }

        XCTAssertEqual(sharing.presentation?.id, second.id)
        XCTAssertTrue(exists(second.url))
        XCTAssertFalse(exists(first.url))
        sharing.binding.wrappedValue = nil
        XCTAssertNil(sharing.presentation)
        XCTAssertFalse(exists(second.url))
    }

    func testCoveringTheParentPreservesAnActiveExportButAccountInvalidationRemovesIt() async throws {
        let sharing = DatabaseExportSharing()
        let session = try session()
        let source = try file("database.sqlite")
        _ = await sharing.prepare(session: session) { source }
        let item = try XCTUnwrap(sharing.presentation)
        managedFiles.append(item.url)

        sharing.cancelPreparation()

        XCTAssertEqual(sharing.presentation?.id, item.id)
        XCTAssertTrue(exists(item.url), "Presenting a sheet must not remove the database being shared")
        sharing.invalidate()
        XCTAssertNil(sharing.presentation)
        XCTAssertFalse(exists(item.url))
    }

    func testLateCanceledOrPreviousAccountResultsAreDiscardedWithoutReplacingANewerExport() async throws {
        for cancel in [true, false] {
            let sharing = DatabaseExportSharing()
            let session = try session()
            let oldSource = try file("old-\(cancel).sqlite"), currentSource = try file("current-\(cancel).sqlite")
            let gate = DatabaseExportGate(started: expectation(description: "An older database export is held"))
            let pending = Task { await sharing.prepare(session: session) { try await gate.value() } }
            addTeardownBlock { await gate.finish(oldSource); _ = await pending.value }
            await fulfillment(of: [gate.started], timeout: 2)
            if cancel { pending.cancel(); sharing.cancelPreparation() }
            else { try session.setServer("https://next-account.example"); sharing.invalidate() }
            _ = await sharing.prepare(session: session) { currentSource }
            let current = try XCTUnwrap(sharing.presentation)
            managedFiles.append(current.url)
            gate.finish(oldSource)
            let error = await pending.value

            XCTAssertNil(error)
            XCTAssertFalse(exists(oldSource))
            XCTAssertEqual(sharing.presentation?.id, current.id)
            XCTAssertTrue(exists(current.url))
            XCTAssertFalse(sharing.isPreparing)
        }
    }

    func testAnAccountGenerationChangeAloneDiscardsAHeldExport() async throws {
        let sharing = DatabaseExportSharing()
        let session = try session()
        let source = try file("old-generation.sqlite")
        let gate = DatabaseExportGate(started: expectation(description: "An old-generation export is held"))
        let pending = Task { await sharing.prepare(session: session) { try await gate.value() } }
        addTeardownBlock { await gate.finish(source); _ = await pending.value }
        await fulfillment(of: [gate.started], timeout: 2)

        LocalSnapshot.clearAll()
        gate.finish(source)
        let error = await pending.value

        XCTAssertNil(error)
        XCTAssertNil(sharing.presentation)
        XCTAssertFalse(sharing.isPreparing)
        XCTAssertFalse(exists(source))
    }

    func testDuplicatePreparationAndAlreadyCanceledCallersDoNotCreateMoreExports() async throws {
        let sharing = DatabaseExportSharing()
        let session = try session()
        let source = try file("held.sqlite")
        let gate = DatabaseExportGate(started: expectation(description: "The first export is held"))
        let pending = Task { await sharing.prepare(session: session) { try await gate.value() } }
        addTeardownBlock { await gate.finish(source); _ = await pending.value }
        await fulfillment(of: [gate.started], timeout: 2)
        XCTAssertTrue(sharing.isPreparing)
        let duplicate = await sharing.prepare(session: session) { XCTFail("A duplicate must not export"); return source }
        XCTAssertNil(duplicate)
        gate.finish(source)
        _ = await pending.value
        let item = try XCTUnwrap(sharing.presentation)
        managedFiles.append(item.url)
        sharing.finish(item.id)

        let canceled = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return await sharing.prepare(session: session) { XCTFail("A canceled caller must not export"); return source }
        }
        let error = await canceled.value
        XCTAssertNil(error)
        XCTAssertNil(sharing.presentation)
        XCTAssertFalse(sharing.isPreparing)
    }

    func testPreparationFailureReportsItsErrorAndAllowsRetryWithoutLeakingTheFailedSource() async throws {
        let sharing = DatabaseExportSharing()
        let session = try session()
        let invalid = try file(String(repeating: "x", count: 240))
        // The source filename itself is valid, but the store's UUID prefix
        // makes its managed destination too long for the filesystem.
        let error = await sharing.prepare(session: session) { invalid }
        XCTAssertNotNil(error)
        XCTAssertFalse(exists(invalid))
        XCTAssertNil(sharing.presentation)
        XCTAssertFalse(sharing.isPreparing)
        let retry = try file("retry.sqlite")
        let retryError = await sharing.prepare(session: session) { retry }
        XCTAssertNil(retryError)
        let item = try XCTUnwrap(sharing.presentation)
        managedFiles.append(item.url)
        XCTAssertTrue(exists(item.url))
    }

    func testAnAlreadyManagedExportStaysAvailableUntilFinished() async throws {
        let sharing = DatabaseExportSharing()
        let session = try session()
        let source = try managedFile("database.sqlite")

        let error = await sharing.prepare(session: session) { source }

        XCTAssertNil(error)
        let item = try XCTUnwrap(sharing.presentation)
        XCTAssertEqual(item.url, source)
        XCTAssertTrue(exists(source))
        sharing.finish(item.id)
        XCTAssertFalse(exists(source))
    }

    func testAbandoningAPreparedButUnpresentedExportReleasesItsOwnedFile() async throws {
        var sharing: DatabaseExportSharing? = DatabaseExportSharing()
        let session = try session()
        let source = try file("unpresented.sqlite")
        _ = await sharing?.prepare(session: session) { source }
        let url = try XCTUnwrap(sharing?.presentation?.url)
        managedFiles.append(url)
        let presentationWasReleased = { [weak presentation = sharing?.presentation] in presentation == nil }
        XCTAssertTrue(exists(url))

        sharing = nil

        XCTAssertTrue(presentationWasReleased())
        XCTAssertFalse(exists(url), "Leaving before a sheet is presented must not retain the prepared database")
    }

    private func session() throws -> MockSessionManager {
        let session = MockSessionManager()
        try session.setServer("https://database-export.example")
        return session
    }

    private func file(_ name: String, bytes: String = "database") throws -> URL {
        let url = directory.appendingPathComponent(name)
        try Data(bytes.utf8).write(to: url)
        return url
    }

    private func managedFile(_ name: String) throws -> URL {
        let url = try TemporaryMediaStore.adoptShareFile(at: file("\(UUID())-\(name)"), suggestedFilename: name)
        managedFiles.append(url)
        return url
    }

    private func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }
}

@MainActor
private final class FinishCounter { var count = 0 }

@MainActor
private final class DatabaseExportGate {
    let started: XCTestExpectation
    private var continuation: CheckedContinuation<URL, Error>?
    private var result: URL?
    init(started: XCTestExpectation) { self.started = started }
    func value() async throws -> URL {
        if let result { return result }
        return try await withCheckedThrowingContinuation {
            continuation = $0
            started.fulfill()
        }
    }
    func finish(_ url: URL) {
        result = url
        continuation?.resume(returning: url)
        continuation = nil
    }
}
