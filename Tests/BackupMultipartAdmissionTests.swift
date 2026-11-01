import Photos
import Synchronization
import XCTest
@testable import ImmichApp

@MainActor
final class BackupMultipartAdmissionTests: XCTestCase {
    func testReceiptFailureRemovesThePreparedBodyAndKeepsTheRequestRetryable() async throws {
        let keys = ["backup.enabled", "backup.syncAlbums", "backup.cellularPhotos", "backup.cellularVideos"]
        let savedDefaults = keys.map { ($0, UserDefaults.standard.object(forKey: $0)) }
        for key in keys { UserDefaults.standard.set(false, forKey: key) }
        defer {
            for (key, value) in savedDefaults {
                if let value { UserDefaults.standard.set(value, forKey: key) }
                else { UserDefaults.standard.removeObject(forKey: key) }
            }
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("multipart-admission-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let suiteName = "BackupMultipartAdmissionTests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let queueURL = directory.appendingPathComponent("queue.json")
        let queue = BackupQueueStore(fileURL: queueURL)
        let manager = SwiftDataManager(storeURL: directory.appendingPathComponent("test.store"),
            backupJournalURL: directory.appendingPathComponent("backup.json"))
        XCTAssertTrue(manager.isPersistentStoreAvailable)
        let library = LocalPhotoLibrary(defaults: defaults, reader: .init(
            authorizationStatus: { .authorized },
            requestAuthorization: { XCTFail("Synthetic preparation must not prompt for Photos access"); return .denied }))
        let source = directory.appendingPathComponent("source.jpg")
        let bytes = Data("Synthetic source copied into the real multipart builder".utf8)
        try bytes.write(to: source)
        let photo = LocalPhoto(id: UUID().uuidString, createdAt: .distantPast, modifiedAt: .distantPast,
            isVideo: false, isLivePhoto: false, duration: nil, ratio: 1)
        var exports = 0
        let service = BackupService(dataManager: manager, queue: queue, localLibrary: library,
            readOriginalFile: { id, allowsNetwork in
                exports += 1
                XCTAssertEqual(id, LocalPhotoLibrary.assetID(for: photo.id))
                XCTAssertFalse(allowsNetwork)
                return (source, "source.jpg")
            })
        defer { service.resetForLogout() }
        let session = ReceiptFailureSession(manager: manager)
        try session.setServer("http://127.0.0.1:1")
        session.isLoggedIn = true
        service.configure(session: session)
        try queue.enqueue([photo.id], intent: .manualUpload)
        let ownership = try XCTUnwrap(service.uploadOwnership)
        let repository = ReceiptFailureRepository(api: APIClient(session: session))
        defer { repository.cleanup() }

        await service.prepareQueuePhoto(photo, repository: repository,
            mayReadFromICloud: false, ownership: ownership)

        let body = try XCTUnwrap(repository.bodyFile)
        XCTAssertEqual(exports, 1)
        XCTAssertTrue(repository.copiedSource)
        XCTAssertTrue(try body.appendingPathExtension("json").resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true,
            "A directory must still block the real receipt write before a URLSession task can be created")
        XCTAssertFalse(FileManager.default.fileExists(atPath: body.path), "An unadmitted multipart body has no owner left to clean it up")
        XCTAssertFalse(FileManager.default.fileExists(atPath: source.path))
        let retained = try XCTUnwrap(queue.item(id: photo.id))
        XCTAssertEqual(retained.state, .retryScheduled)
        XCTAssertNil(retained.taskIdentifier)
        XCTAssertNotNil(retained.nextAttemptAt)
        XCTAssertNotNil(retained.lastError)
        let reopened = BackupQueueStore(fileURL: queueURL)
        let persisted = try XCTUnwrap(reopened.item(id: photo.id))
        XCTAssertEqual(persisted.id, retained.id)
        XCTAssertEqual(persisted.phase, retained.phase)
        XCTAssertEqual(persisted.state, retained.state)
        XCTAssertEqual(persisted.intent, retained.intent)
        XCTAssertEqual(persisted.attemptCount, retained.attemptCount)
        XCTAssertEqual(persisted.lastError, retained.lastError)
        XCTAssertEqual(persisted.taskIdentifier, retained.taskIdentifier)
        XCTAssertEqual(persisted.checksum, retained.checksum)
        XCTAssertEqual(persisted.motionAssetID, retained.motionAssetID)
        XCTAssertEqual(persisted.sourceAlbumName, retained.sourceAlbumName)
        let persistedRetry = try XCTUnwrap(persisted.nextAttemptAt)
        let retainedRetry = try XCTUnwrap(retained.nextAttemptAt)
        // The queue's ISO8601 encoding persists whole seconds.
        for (saved, current) in [(persistedRetry, retainedRetry),
            (persisted.createdAt, retained.createdAt), (persisted.updatedAt, retained.updatedAt)] {
            XCTAssertLessThan(abs(saved.timeIntervalSince(current)), 1)
        }
        XCTAssertEqual(reopened.snapshot.completed, 0)
        XCTAssertEqual(queue.snapshot.completed, 0)
    }
}

@MainActor
private final class ReceiptFailureSession: SessionManager {
    override var backupQueueOwner: BackupQueueOwner? {
        .init(server: "http://127.0.0.1:1/api", userID: "synthetic-receipt-owner")
    }

    init(manager: SwiftDataManager) {
        super.init(dataManager: manager, restoresSession: false)
    }
}

private final class ReceiptFailureRepository: BackupRepository {
    private let prepared = Mutex<(body: URL?, copiedSource: Bool)>((nil, false))
    var bodyFile: URL? { prepared.withLock { $0.body } }
    var copiedSource: Bool { prepared.withLock { $0.copiedSource } }

    override func makeUploadRequest(
        fileURL: URL, filename: String, checksum: String, deviceAssetId: String,
        createdAt: Date, modifiedAt: Date, additionalFields: [String: String] = [:]
    ) async throws -> PreparedUpload {
        let result = try await super.makeUploadRequest(fileURL: fileURL, filename: filename,
            checksum: checksum, deviceAssetId: deviceAssetId, createdAt: createdAt,
            modifiedAt: modifiedAt, additionalFields: additionalFields)
        prepared.withLock { $0.body = result.bodyFile }
        let source = try Data(contentsOf: fileURL)
        let body = try Data(contentsOf: result.bodyFile)
        prepared.withLock { $0.copiedSource = body.range(of: source) != nil }
        try FileManager.default.createDirectory(at: result.bodyFile.appendingPathExtension("json"), withIntermediateDirectories: false)
        return result
    }

    func cleanup() {
        guard let bodyFile else { return }
        try? FileManager.default.removeItem(at: bodyFile)
        try? FileManager.default.removeItem(at: bodyFile.appendingPathExtension("json"))
    }
}
