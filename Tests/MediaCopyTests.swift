import AVFoundation
import ImageIO
import SwiftData
import UIKit
import UniformTypeIdentifiers
import XCTest
@testable import ImmichApp

@MainActor
final class MediaCopyTests: XCTestCase {
    private var files: [URL] = []
    private var mappings: [(recordID: String, localID: String)] = []

    override func tearDown() async throws {
        TemporaryMediaStore.remove(files)
        files.removeAll()
        for mapping in mappings {
            let recordID = mapping.recordID
            let descriptor = FetchDescriptor<BackupRecord>(predicate: #Predicate { $0.id == recordID })
            for record in try SwiftDataManager.shared.modelContext.fetch(descriptor) {
                SwiftDataManager.shared.modelContext.delete(record)
            }
            try SwiftDataManager.shared.unlinkDeviceAsset(localIdentifier: mapping.localID)
        }
        mappings.removeAll()
        try await super.tearDown()
    }

    func testPreparedImageAndVideoKeepTheirBytesTypesAndOrderAfterTemporaryFilesAreRemoved() async throws {
        let image = try imageFile()
        let movie = try TemporaryMediaStore.adoptShareFile(at: await makePagerPlaybackMovie(), suggestedFilename: "copy.mp4")
        files.append(movie)
        let originals = try [image, movie].map { try Data(contentsOf: $0) }

        let items = try await MediaCopy.prepare([.init(url: image, isVideo: false), .init(url: movie, isVideo: true)])
        TemporaryMediaStore.remove([image, movie])
        let clipboard = CopyClipboard()
        MediaCopy.write(items, using: clipboard.write)

        XCTAssertEqual(clipboard.writes, 1)
        XCTAssertEqual(items.map(\.typeIdentifier), [UTType.jpeg.identifier, UTType.quickTimeMovie.identifier])
        XCTAssertEqual(clipboard.media.map(\.data), originals)
        XCTAssertEqual(clipboard.media.map(\.typeIdentifier), items.map(\.typeIdentifier))
        XCTAssertFalse(FileManager.default.fileExists(atPath: image.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: movie.path))
        let source = try XCTUnwrap(CGImageSourceCreateWithData(try XCTUnwrap(clipboard.media.first).data as CFData, nil))
        let properties = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any])
        XCTAssertEqual((properties[kCGImagePropertyGPSDictionary as String] as? [String: Any])?[kCGImagePropertyGPSLatitude as String] as? Double, 12.5)
        XCTAssertEqual((properties[kCGImagePropertyExifDictionary as String] as? [String: Any])?[kCGImagePropertyExifUserComment as String] as? String, "Synthetic copy metadata")
    }

    func testAlternativeRepresentationsStayInOneClipboardItemAndKeepSelectionOrderAfterCleanup() async throws {
        let image = try imageFile()
        let rendered = try XCTUnwrap(UIImage(contentsOfFile: image.path))
        let compatible = try managed(try XCTUnwrap(rendered.pngData()), filename: "compatible.png")
        let movie = try TemporaryMediaStore.adoptShareFile(at: await makePagerPlaybackMovie(), suggestedFilename: "second.mov")
        files.append(movie)
        let originals = try [image, compatible, movie].map { try Data(contentsOf: $0) }
        let items = try await MediaCopy.prepare([
            .init(url: image, isVideo: false), .init(url: compatible, isVideo: false), .init(url: movie, isVideo: true),
        ])
        TemporaryMediaStore.remove([image, compatible, movie])
        var clipboard: [[String: Any]] = []
        var writes = 0

        MediaCopy.writeRepresentations([Array(items.prefix(2)), [items[2]]]) { values in
            writes += 1
            clipboard = values
        }

        XCTAssertEqual(writes, 1)
        XCTAssertEqual(clipboard.count, 2, "Alternative formats represent one photo, not extra pasted photos")
        let first = try XCTUnwrap(clipboard.first), second = try XCTUnwrap(clipboard.last)
        XCTAssertEqual(Set(first.keys), [UTType.jpeg.identifier, UTType.png.identifier])
        XCTAssertEqual(first[UTType.jpeg.identifier] as? Data, originals[0])
        XCTAssertEqual(first[UTType.png.identifier] as? Data, originals[1])
        XCTAssertEqual(Set(second.keys), [UTType.quickTimeMovie.identifier])
        XCTAssertEqual(second[UTType.quickTimeMovie.identifier] as? Data, originals[2])
        XCTAssertTrue([image, compatible, movie].allSatisfy { !FileManager.default.fileExists(atPath: $0.path) })
    }

    func testFailureAndPartialExportsLeaveTheExistingClipboardUntouchedAndCleanReturnedFiles() async throws {
        for scenario in ["missing", "empty", "invalid", "partial", "wrong-media"] {
            let preparation = MediaCopyPreparation()
            let clipboard = CopyClipboard()
            var errors: [String] = []
            let valid = try imageFile()
            let broken: URL
            switch scenario {
            case "missing": broken = valid.deletingLastPathComponent().appendingPathComponent("absent.jpg")
            case "empty": broken = try managed(Data(), filename: "empty.jpg")
            case "invalid": broken = try managed(Data("not an image".utf8), filename: "invalid.jpg")
            default: broken = valid
            }
            let ids = scenario == "partial" ? ["first", "second"] : ["first"]
            let task = try XCTUnwrap(preparation.start(ids: ids, prepare: { _ in
                [.init(url: broken, isVideo: scenario == "wrong-media")]
            }, isAllowed: { _ in true }, onError: { errors.append($0) }, writer: clipboard.write))

            await task.value

            XCTAssertEqual(clipboard.writes, 0, scenario)
            XCTAssertEqual(clipboard.marker, "Previous clipboard", scenario)
            XCTAssertEqual(errors, [String(localized: "Could not copy these items.")], scenario)
            XCTAssertFalse(preparation.isPreparing, scenario)
            if scenario != "missing" { XCTAssertFalse(FileManager.default.fileExists(atPath: broken.path), scenario) }
        }
    }

    func testTruncatedImageWithARecognizableJPEGHeaderCannotReplaceTheClipboard() async throws {
        let valid = try imageFile()
        let original = try Data(contentsOf: valid)
        let scanMarker = try XCTUnwrap(original.range(of: Data([0xFF, 0xDA])))
        let lengthOffset = scanMarker.upperBound
        XCTAssertGreaterThan(original.count, lengthOffset + 2)
        let headerLength = Int(original[lengthOffset]) << 8 | Int(original[lengthOffset + 1])
        let scanStart = lengthOffset + headerLength
        XCTAssertGreaterThan(original.count, scanStart + 1)
        let truncatedBytes = original.prefix(scanStart - 1)
        let truncated = try managed(Data(truncatedBytes), filename: "truncated.jpg")
        let source = try XCTUnwrap(CGImageSourceCreateWithData(truncatedBytes as CFData, nil))
        XCTAssertEqual(CGImageSourceGetType(source) as String?, UTType.jpeg.identifier)
        XCTAssertGreaterThan(CGImageSourceGetCount(source), 0, "The fixture must pass header-only image validation")
        XCTAssertNil(CGImageSourceCreateImageAtIndex(source, 0, nil),
            "The fixture preserves a recognizable JPEG header but ends before its scan header is complete")
        let preparation = MediaCopyPreparation()
        let clipboard = CopyClipboard()
        var errors: [String] = []
        let task = try XCTUnwrap(preparation.start(ids: ["valid", "truncated"], prepare: { _ in
            [.init(url: valid, isVideo: false), .init(url: truncated, isVideo: false)]
        }, isAllowed: { _ in true }, onError: { errors.append($0) }, writer: clipboard.write))

        await task.value

        XCTAssertEqual(clipboard.writes, 0, "A failed later item must not partially replace the clipboard")
        XCTAssertEqual(clipboard.marker, "Previous clipboard")
        XCTAssertEqual(errors, [String(localized: "Could not copy these items.")])
        XCTAssertFalse(preparation.isPreparing)
        XCTAssertTrue([valid, truncated].allSatisfy { !FileManager.default.fileExists(atPath: $0.path) })
    }

    func testSuccessfulTrackedCopyWritesAllItemsOnceAndCleansItsExports() async throws {
        let preparation = MediaCopyPreparation()
        let clipboard = CopyClipboard()
        let first = try imageFile(), second = try imageFile()
        let originals = try [first, second].map { try Data(contentsOf: $0) }
        var errors: [String] = []
        let task = try XCTUnwrap(preparation.start(ids: ["first", "second"], prepare: { _ in
            [.init(url: first, isVideo: false), .init(url: second, isVideo: false)]
        }, isAllowed: { _ in true }, onError: { errors.append($0) }, writer: clipboard.write))

        await task.value

        XCTAssertEqual(clipboard.writes, 1)
        XCTAssertEqual(clipboard.media.map(\.data), originals)
        XCTAssertTrue(errors.isEmpty)
        XCTAssertFalse(preparation.isPreparing)
        XCTAssertFalse(FileManager.default.fileExists(atPath: first.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: second.path))
    }

    func testCancellationAccountAndPrivacyChangesRejectALateExportWithoutReplacingTheClipboard() async throws {
        for invalidation in ["cancel", "account", "privacy"] {
            let preparation = MediaCopyPreparation()
            let clipboard = CopyClipboard()
            let gate = CopyExportGate()
            let admission = CopyAdmission()
            let file = try imageFile()
            var errors: [String] = []
            let task = try XCTUnwrap(preparation.start(ids: ["photo"], prepare: { _ in await gate.value() },
                isAllowed: { _ in admission.isAllowed }, onError: { errors.append($0) }, writer: clipboard.write))
            await fulfillment(of: [gate.started], timeout: 2)
            switch invalidation {
            case "cancel": preparation.cancel()
            case "account": LocalSnapshot.clearAll()
            default: admission.isAllowed = false
            }
            gate.finish([.init(url: file, isVideo: false)])

            await task.value

            XCTAssertEqual(clipboard.writes, 0, invalidation)
            XCTAssertEqual(clipboard.marker, "Previous clipboard", invalidation)
            XCTAssertTrue(errors.isEmpty, invalidation)
            XCTAssertFalse(preparation.isPreparing, invalidation)
            XCTAssertFalse(FileManager.default.fileExists(atPath: file.path), invalidation)
        }
    }

    func testAnOlderCancelledCopyCannotWriteOrStopAReplacementCopy() async throws {
        let preparation = MediaCopyPreparation()
        let clipboard = CopyClipboard()
        let firstGate = CopyExportGate(), secondGate = CopyExportGate()
        let first = try imageFile(), second = try imageFile()
        let expected = try Data(contentsOf: second)
        var errors: [String] = []
        let firstTask = try XCTUnwrap(preparation.start(ids: ["first"], prepare: { _ in await firstGate.value() },
            isAllowed: { _ in true }, onError: { errors.append($0) }, writer: clipboard.write))
        await fulfillment(of: [firstGate.started], timeout: 2)
        XCTAssertNil(preparation.start(ids: ["duplicate"], prepare: { _ in
            XCTFail("A pending Copy must not start another export"); return []
        }, isAllowed: { _ in true }, onError: { errors.append($0) }, writer: clipboard.write))
        preparation.cancel()
        let secondTask = try XCTUnwrap(preparation.start(ids: ["second"], prepare: { _ in await secondGate.value() },
            isAllowed: { _ in true }, onError: { errors.append($0) }, writer: clipboard.write))
        await fulfillment(of: [secondGate.started], timeout: 2)
        firstGate.finish([.init(url: first, isVideo: false)])
        await firstTask.value
        XCTAssertTrue(preparation.isPreparing)
        XCTAssertEqual(clipboard.writes, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: first.path))

        secondGate.finish([.init(url: second, isVideo: false)])
        await secondTask.value

        XCTAssertFalse(preparation.isPreparing)
        XCTAssertEqual(clipboard.writes, 1)
        XCTAssertEqual(clipboard.media.map(\.data), [expected])
        XCTAssertTrue(errors.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: second.path))
    }

    func testServerContextChangeWithoutAccountResetRejectsALateCopy() async throws {
        let session = MockSessionManager()
        try session.setServer("https://copy-before.example")
        let api = APIClient(session: session)
        let context = session.snapshot
        let generation = LocalSnapshot.generation
        let preparation = MediaCopyPreparation()
        let clipboard = CopyClipboard()
        let gate = CopyExportGate()
        let file = try imageFile()
        var errors: [String] = []
        let task = try XCTUnwrap(preparation.start(ids: ["photo"], prepare: { _ in await gate.value() },
            isAllowed: { _ in (try? api.checkCurrent(context)) != nil },
            onError: { errors.append($0) }, writer: clipboard.write))
        await fulfillment(of: [gate.started], timeout: 2)

        try session.setServer("https://copy-after.example")
        XCTAssertEqual(LocalSnapshot.generation, generation)
        gate.finish([.init(url: file, isVideo: false)])
        await task.value

        XCTAssertEqual(clipboard.writes, 0)
        XCTAssertEqual(clipboard.marker, "Previous clipboard")
        XCTAssertTrue(errors.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
    }

    func testRemappingOrUnlinkingAnAliasAfterItsActualBytesArePreparedCannotCopyTheOldSource() async throws {
        for invalidation in ["remap", "unlink", "remap-and-hide-source"] {
            let recordID = UUID().uuidString, localID = UUID().uuidString
            let oldID = UUID().uuidString, newID = UUID().uuidString
            let displayID = LocalPhotoLibrary.assetID(for: localID)
            mappings.append((recordID, localID))
            try SwiftDataManager.shared.insertBackupRecord(BackupRecord(id: recordID, assetId: oldID,
                deviceAssetId: "", localIdentifier: localID))
            let gate = CopyBytesGate()
            let preparation = MediaCopyPreparation(prepareItems: { sources in
                let items = try await MediaCopy.prepare(sources)
                return await gate.hold(items)
            })
            let removed = RemovedAssets()
            let policy = AssetVisibilityPolicy(scope: .timeline, removed: removed)
            let clipboard = CopyClipboard()
            let file = try imageFile(), expected = try Data(contentsOf: file)
            var errors: [String] = []
            let task = try XCTUnwrap(preparation.start(ids: [displayID], prepare: { _ in
                [.init(url: file, isVideo: false)]
            }, isAllowed: { policy.allows(id: $0) }, onError: { errors.append($0) }, writer: clipboard.write))
            addTeardownBlock { await gate.release(); await task.value }
            await fulfillment(of: [gate.started], timeout: 2)
            XCTAssertEqual(gate.items.map(\.data), [expected], "The real media reader must finish before the identity changes")

            if invalidation == "unlink" { try SwiftDataManager.shared.unlinkDeviceAsset(localIdentifier: localID) }
            else { try SwiftDataManager.shared.upsertBackupRecord(assetID: newID, checksum: "", localIdentifier: localID) }
            if invalidation == "remap-and-hide-source" {
                removed.remove([oldID])
                XCTAssertFalse(policy.allows(id: oldID))
            }
            XCTAssertTrue(policy.allows(id: displayID), "Logical privacy alone would still authorize the obsolete bytes")
            gate.release()
            await task.value

            XCTAssertEqual(clipboard.writes, 0, invalidation)
            XCTAssertEqual(clipboard.marker, "Previous clipboard", invalidation)
            XCTAssertTrue(errors.isEmpty, invalidation)
            XCTAssertFalse(preparation.isPreparing, invalidation)
            XCTAssertFalse(FileManager.default.fileExists(atPath: file.path), invalidation)
        }
    }

    func testAlreadyCancelledPreparationDoesNotReadMediaOrChangeTheClipboard() async throws {
        let clipboard = CopyClipboard()
        let file = try imageFile()
        let task = Task {
            let items = try await MediaCopy.prepare([.init(url: file, isVideo: false)])
            MediaCopy.write(items, using: clipboard.write)
        }
        task.cancel()
        do { try await task.value; XCTFail("An already-cancelled Copy must stop before publishing") }
        catch is CancellationError {}
        catch { XCTFail("Expected cancellation, received \(error)") }

        XCTAssertEqual(clipboard.writes, 0)
        XCTAssertEqual(clipboard.marker, "Previous clipboard")
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path), "The reader must not delete a caller-owned source")
    }

    private func imageFile() throws -> URL {
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        let image = UIGraphicsImageRenderer(size: CGSize(width: 6, height: 4), format: format).image { context in
            UIColor.green.setFill(); context.fill(CGRect(x: 0, y: 0, width: 6, height: 4))
        }
        let output = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(output, UTType.jpeg.identifier as CFString, 1, nil))
        let metadata: [CFString: Any] = [
            kCGImagePropertyGPSDictionary: [kCGImagePropertyGPSLatitude: 12.5, kCGImagePropertyGPSLatitudeRef: "N",
                kCGImagePropertyGPSLongitude: 66.7, kCGImagePropertyGPSLongitudeRef: "E"],
            kCGImagePropertyExifDictionary: [kCGImagePropertyExifUserComment: "Synthetic copy metadata"],
        ]
        CGImageDestinationAddImage(destination, try XCTUnwrap(image.cgImage), metadata as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return try managed(output as Data, filename: "image.misnamed")
    }

    private func managed(_ data: Data, filename: String) throws -> URL {
        let source = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try data.write(to: source)
        let file = try TemporaryMediaStore.adoptShareFile(at: source, suggestedFilename: filename)
        files.append(file)
        return file
    }
}

@MainActor
private final class CopyClipboard {
    private(set) var marker = "Previous clipboard"
    private(set) var writes = 0
    private(set) var media: [MediaCopy.Item] = []

    func write(_ items: [[String: Any]]) {
        writes += 1
        marker = "Media"
        media = items.flatMap { item in
            item.compactMap { key, value in (value as? Data).map { MediaCopy.Item(typeIdentifier: key, data: $0) } }
        }
    }
}

@MainActor
private final class CopyAdmission { var isAllowed = true }

@MainActor
private final class CopyExportGate {
    let started = XCTestExpectation(description: "The Copy export is held")
    private var pending: CheckedContinuation<[MediaCopy.Source], Never>?

    func value() async -> [MediaCopy.Source] {
        await withCheckedContinuation { pending = $0; started.fulfill() }
    }

    func finish(_ sources: [MediaCopy.Source]) {
        guard let pending else { return XCTFail("The held export must exist") }
        self.pending = nil
        pending.resume(returning: sources)
    }
}

@MainActor
private final class CopyBytesGate {
    let started = XCTestExpectation(description: "The actual Copy bytes are held before publication")
    private(set) var items: [MediaCopy.Item] = []
    private var pending: CheckedContinuation<[MediaCopy.Item], Never>?

    func hold(_ items: [MediaCopy.Item]) async -> [MediaCopy.Item] {
        self.items = items
        return await withCheckedContinuation { pending = $0; started.fulfill() }
    }

    func release() {
        pending?.resume(returning: items)
        pending = nil
    }
}
