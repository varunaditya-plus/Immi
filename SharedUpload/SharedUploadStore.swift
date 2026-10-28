import Darwin
import Foundation

struct SharedUploadOwner: Codable, Equatable, Sendable {
    let server: String
    let userID: String
}

enum SharedUploadItemState: String, Codable, Sendable {
    case queued
    case uploading
    case uploaded
}

struct SharedUploadItem: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    let filename: String
    let relativePath: String
    let contentType: String
    let byteCount: Int64
    let createdAt: Date
    let modifiedAt: Date
    var state: SharedUploadItemState
    var lastError: String?
}

struct SharedUploadBatch: Codable, Equatable, Identifiable, Sendable {
    var version = 1
    let id: UUID
    let owner: SharedUploadOwner
    let createdAt: Date
    var items: [SharedUploadItem]
}

enum SharedUploadStoreError: LocalizedError {
    case appGroupUnavailable
    case invalidFilename

    var errorDescription: String? {
        switch self {
        case .appGroupUnavailable:
            String(localized: "SelfPhotos could not access its shared upload storage.")
        case .invalidFilename:
            String(localized: "One of the shared files has an invalid name.")
        }
    }
}

/// The descriptor keeps the batch claimed across awaits and processes. The
/// system releases it even if an extension is terminated during an upload.
final class SharedUploadBatchClaim: @unchecked Sendable {
    private let descriptor: Int32

    fileprivate init(descriptor: Int32) {
        self.descriptor = descriptor
    }

    deinit {
        flock(descriptor, LOCK_UN)
        close(descriptor)
    }
}

/// Ledger per batch, bukan satu JSON global. Dengan begitu proses extension dan
/// aplikasi utama tidak menimpa batch satu sama lain saat keduanya aktif.
actor SharedUploadStore {
    static let shared = SharedUploadStore()
    private static let draftLifetime: TimeInterval = 24 * 60 * 60

    private let rootURL: URL?
    private let fileManager: FileManager
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    init(rootURL: URL? = nil, fileManager: FileManager = .default) {
        self.rootURL = rootURL ?? SelfPhotosSharedContainer.rootURL?
            .appendingPathComponent("ShareUploadInbox", isDirectory: true)
        self.fileManager = fileManager
        encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
    }

    func makeBatchDirectory(id: UUID) throws -> URL {
        let directory = try batchDirectory(id: id)
        try fileManager.createDirectory(
            at: directory,
            withIntermediateDirectories: true)
        return directory
    }

    func makeDraftDirectory(id: UUID) throws -> (directory: URL, claim: SharedUploadBatchClaim) {
        // Failure to remove an older draft must not prevent a new share.
        _ = try? cleanupAbandonedDrafts()
        let directory = try makeBatchDirectory(id: id)
        guard let claim = try claimBatch(id: id) else { throw POSIXError(.EBUSY) }
        return (directory, claim)
    }

    /// Only uncommitted, inactive drafts expire. Any manifest is durable intent,
    /// including one this version cannot decode or does not own.
    @discardableResult
    func cleanupAbandonedDrafts(now: Date = .now) throws -> Int {
        guard let rootURL else { throw SharedUploadStoreError.appGroupUnavailable }
        guard fileManager.fileExists(atPath: rootURL.path) else { return 0 }
        let directories = try fileManager.contentsOfDirectory(
            at: rootURL, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles])
        let cutoff = now.addingTimeInterval(-Self.draftLifetime)
        var removed = 0
        var firstError: Error?
        for directory in directories {
            do {
                guard let id = UUID(uuidString: directory.lastPathComponent),
                      directory.lastPathComponent == id.uuidString else { continue }
                let values = try directory.resourceValues(
                    forKeys: [.isDirectoryKey, .isSymbolicLinkKey, .contentModificationDateKey])
                guard values.isDirectory == true, values.isSymbolicLink != true,
                      let modified = values.contentModificationDate, modified < cutoff,
                      try !hasManifest(id: id),
                      let claim = try claimBatch(id: id) else { continue }
                defer { withExtendedLifetime(claim) {} }
                // Admission in another process may have finished before this claim.
                guard try !hasManifest(id: id) else { continue }
                do {
                    try fileManager.removeItem(at: directory)
                } catch {
                    // Creating a legacy draft's first lock changes its directory
                    // date. A failed removal must not renew its retention period.
                    try? fileManager.setAttributes([.modificationDate: modified], ofItemAtPath: directory.path)
                    throw error
                }
                removed += 1
            } catch {
                firstError = firstError ?? error
            }
        }
        if let firstError { throw firstError }
        return removed
    }

    private func hasManifest(id: UUID) throws -> Bool {
        let manifest = try batchDirectory(id: id).appendingPathComponent("manifest.json")
        do {
            _ = try fileManager.attributesOfItem(atPath: manifest.path)
            return true
        } catch let error as CocoaError where Self.isMissing(error) {
            return false
        }
    }

    func existingBatchDirectory(id: UUID) throws -> URL? {
        let directory = try batchDirectory(id: id)
        do {
            let values = try directory.resourceValues(forKeys: [.isDirectoryKey])
            guard values.isDirectory == true else {
                throw CocoaError(.fileReadInvalidFileName)
            }
            return directory
        } catch let error as CocoaError where Self.isMissing(error) {
            return nil
        }
    }

    func claimBatch(id: UUID) throws -> SharedUploadBatchClaim? {
        guard let directory = try existingBatchDirectory(id: id) else { return nil }
        let lockURL = directory.appendingPathComponent(".processing.lock")
        let descriptor = open(lockURL.path, O_CREAT | O_RDWR | O_CLOEXEC, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else {
            if errno == ENOENT { return nil }
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            let failure = errno
            close(descriptor)
            if failure == EWOULDBLOCK || failure == EAGAIN { return nil }
            throw POSIXError(POSIXErrorCode(rawValue: failure) ?? .EIO)
        }
        return SharedUploadBatchClaim(descriptor: descriptor)
    }

    func batch(id: UUID, owner: SharedUploadOwner) throws -> SharedUploadBatch? {
        let manifest = try batchDirectory(id: id).appendingPathComponent("manifest.json")
        let data: Data
        do {
            data = try Data(contentsOf: manifest)
        } catch let error as CocoaError where Self.isMissing(error) {
            return nil
        }
        let batch = try decoder.decode(SharedUploadBatch.self, from: data)
        guard batch.id == id, batch.version == 1, batch.owner == owner else { return nil }
        return batch
    }

    func save(_ batch: SharedUploadBatch) throws {
        let directory = try makeBatchDirectory(id: batch.id)
        let target = directory.appendingPathComponent("manifest.json")
        let temporary = directory.appendingPathComponent("manifest-\(UUID().uuidString).tmp")
        let data = try encoder.encode(batch)
        try data.write(to: temporary, options: .atomic)
        if fileManager.fileExists(atPath: target.path) {
            _ = try fileManager.replaceItemAt(target, withItemAt: temporary)
        } else {
            try fileManager.moveItem(at: temporary, to: target)
        }
    }

    func batches(for owner: SharedUploadOwner) throws -> [SharedUploadBatch] {
        guard let rootURL else { throw SharedUploadStoreError.appGroupUnavailable }
        guard fileManager.fileExists(atPath: rootURL.path) else { return [] }
        let directories = try fileManager.contentsOfDirectory(
            at: rootURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles])

        return directories.compactMap { directory in
            let manifest = directory.appendingPathComponent("manifest.json")
            guard let data = try? Data(contentsOf: manifest),
                  let batch = try? decoder.decode(SharedUploadBatch.self, from: data),
                  batch.version == 1,
                  batch.owner == owner
            else { return nil }
            return batch
        }
        .sorted { $0.createdAt < $1.createdAt }
    }

    func fileURL(for item: SharedUploadItem, batchID: UUID) throws -> URL {
        let directory = try batchDirectory(id: batchID)
        let candidate = directory.appendingPathComponent(item.relativePath)
            .standardizedFileURL
        guard candidate.deletingLastPathComponent() == directory.standardizedFileURL else {
            throw SharedUploadStoreError.invalidFilename
        }
        return candidate
    }

    func removeFile(for item: SharedUploadItem, batchID: UUID) throws {
        let url = try fileURL(for: item, batchID: batchID)
        if fileManager.fileExists(atPath: url.path) {
            try fileManager.removeItem(at: url)
        }
    }

    func removeBatch(id: UUID) throws {
        let directory = try batchDirectory(id: id)
        if fileManager.fileExists(atPath: directory.path) {
            try fileManager.removeItem(at: directory)
        }
    }

    private func batchDirectory(id: UUID) throws -> URL {
        guard let rootURL else { throw SharedUploadStoreError.appGroupUnavailable }
        return rootURL.appendingPathComponent(id.uuidString, isDirectory: true)
    }

    private static func isMissing(_ error: CocoaError) -> Bool {
        error.code == .fileNoSuchFile || error.code == .fileReadNoSuchFile
    }
}
