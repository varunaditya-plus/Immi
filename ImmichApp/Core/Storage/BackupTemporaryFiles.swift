import Foundation

/// Active uploads and receipt-owned bodies survive generic launch cleanup.
/// Failed uploads without an accessible original are kept outside tmp.
enum BackupTemporaryFiles {
    private static let completionLock = NSLock()
    static let recoveryRelativePath = "Library/Application Support/RecoveredUploads"

    static var recoveryDirectory: URL {
        URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
            .appendingPathComponent(recoveryRelativePath, isDirectory: true)
    }

    /// Persist ownership before URLSession starts, so a crash or a completion
    /// racing launch cleanup cannot turn the last copy into an "orphan".
    static func record(_ context: BackupUploadTaskContext, in directory: URL = FileManager.default.temporaryDirectory) throws {
        guard let body = bodyURL(for: context.bodyPath, in: directory) else {
            throw CocoaError(.fileWriteInvalidFileName)
        }
        try JSONEncoder().encode(context).write(to: body.appendingPathExtension("json"), options: .atomic)
    }

    static func recordedContexts(in directory: URL) -> [BackupUploadTaskContext] {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return files.compactMap { file in
            guard file.lastPathComponent.hasPrefix("upload-"),
                  file.lastPathComponent.hasSuffix(".multipart.json"),
                  let data = try? Data(contentsOf: file),
                  let context = try? JSONDecoder().decode(BackupUploadTaskContext.self, from: data),
                  bodyURL(for: context.bodyPath, in: directory)?.appendingPathExtension("json") == file
            else { return nil }
            return context
        }
    }

    /// Returns true if an unsuccessful upload had to be preserved. This is a
    /// rename, not another full media copy. No credentials are stored.
    @discardableResult
    static func finish(
        _ context: BackupUploadTaskContext,
        succeeded: Bool,
        sourceAvailable: Bool,
        in directory: URL = FileManager.default.temporaryDirectory,
        recovery: URL = recoveryDirectory
    ) throws -> Bool {
        try completionLock.withLock {
            try finishLocked(context, succeeded: succeeded, sourceAvailable: sourceAvailable, in: directory, recovery: recovery)
        }
    }

    private static func finishLocked(
        _ context: BackupUploadTaskContext, succeeded: Bool, sourceAvailable: Bool,
        in directory: URL, recovery: URL
    ) throws -> Bool {
        guard let body = bodyURL(for: context.bodyPath, in: directory) else { return false }
        let manager = FileManager.default
        let receipt = body.appendingPathExtension("json")
        if manager.fileExists(atPath: body.path) {
            if succeeded || sourceAvailable {
                try manager.removeItem(at: body)
            } else {
                // Write metadata first. If the move fails, the tmp receipt
                // continues protecting the source on the next launch.
                try record(context, in: directory)
                try manager.createDirectory(at: recovery, withIntermediateDirectories: true)
                try record(context, in: recovery)
                try manager.moveItem(at: body, to: recovery.appendingPathComponent(body.lastPathComponent))
            }
        }
        if manager.fileExists(atPath: receipt.path) { try manager.removeItem(at: receipt) }
        if succeeded, let ownership = context.ownership {
            // A later retry may recreate the body after Photos access returns.
            // Recovery copies must belong to this account and queue generation.
            // Legacy receipts without ownership cannot prove that relationship.
            for saved in recordedContexts(in: recovery)
            where saved.ownership == ownership
                && saved.localIdentifier == context.localIdentifier
                && saved.checksum == context.checksum && saved.phase == context.phase {
                guard let savedBody = bodyURL(for: saved.bodyPath, in: recovery) else { continue }
                if manager.fileExists(atPath: savedBody.path) { try manager.removeItem(at: savedBody) }
                try manager.removeItem(at: savedBody.appendingPathExtension("json"))
            }
        }
        return !succeeded && !sourceAvailable
            && manager.fileExists(atPath: recovery.appendingPathComponent(body.lastPathComponent).path)
    }

    static func cleanupOrphans(
        in directory: URL,
        activeBodyPaths: Set<String>,
        olderThan cutoff: Date
    ) {
        let manager = FileManager.default
        // iOS may change the container's absolute path when updating the app.
        let protectedNames = Set(activeBodyPaths.map {
            URL(fileURLWithPath: $0).lastPathComponent
        })
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .contentModificationDateKey]
        guard let files = try? manager.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: Array(keys)) else { return }
        for file in files {
            let name = file.lastPathComponent
            guard name.hasPrefix("backup-source-")
                    || (name.hasPrefix("upload-") && file.pathExtension == "multipart"),
                  !protectedNames.contains(name),
                  // Even an unreadable receipt must protect its media. Never
                  // infer that malformed metadata means the file is disposable.
                  !manager.fileExists(atPath: file.appendingPathExtension("json").path),
                  let values = try? file.resourceValues(forKeys: keys),
                  values.isRegularFile == true,
                  let modified = values.contentModificationDate,
                  modified < cutoff
            else { continue }
            try? manager.removeItem(at: file)
        }
    }

    static func bodyURL(for path: String, in directory: URL = FileManager.default.temporaryDirectory) -> URL? {
        let name = URL(fileURLWithPath: path).lastPathComponent
        guard name.hasPrefix("upload-"), name.hasSuffix(".multipart") else { return nil }
        return directory.appendingPathComponent(name)
    }
}

enum BackupStagingPolicy {
    static let maximumActiveUploads = 3
    static let stagingThreshold = 256 * 1024 * 1024

    /// Check BEFORE exporting another original. A single large video can exceed
    /// the threshold; no more originals are staged while it occupies the budget.
    static func canPrepare(activeCount: Int, stagedBytes: Int) -> Bool {
        activeCount < maximumActiveUploads && stagedBytes < stagingThreshold
    }

    struct Upload: Sendable {
        let taskIdentifier: Int
        let bytes: Int
        let progress: Double
    }

    /// An app update preserves URLSession's old tasks AND its system-owned
    /// copies. Shrink that existing window as well as limiting new exports.
    /// Keep the transfers nearest completion, allowing one oversized video.
    static func retainedTaskIDs(
        from uploads: [Upload], protectedTaskIDs: Set<Int> = []
    ) -> Set<Int> {
        let ordered = uploads.sorted {
            if $0.progress != $1.progress { return $0.progress > $1.progress }
            return $0.taskIdentifier < $1.taskIdentifier
        }
        // If PhotoKit no longer exposes an original, the staged copy may be
        // the only copy left. Finish that upload rather than reclaiming it.
        var retained = Set(uploads.map(\.taskIdentifier)).intersection(protectedTaskIDs)
        var bytes = uploads.filter { retained.contains($0.taskIdentifier) }
            .reduce(0) { $0 + max(0, $1.bytes) }
        for upload in ordered {
            if retained.contains(upload.taskIdentifier) { continue }
            let size = max(0, upload.bytes)
            guard retained.count < maximumActiveUploads else { break }
            guard retained.isEmpty || size <= max(0, stagingThreshold - bytes) else { continue }
            retained.insert(upload.taskIdentifier)
            bytes += size
        }
        return retained
    }
}
