import Foundation

struct AppStorageUsage: Sendable {
    var imageCache = 0
    var otherCaches = 0
    var backupFiles = 0
    var temporaryFiles = 0
    var recoveredUploads = 0
    var appData = 0
    var sharedData = 0
    var total: Int { imageCache + otherCaches + backupFiles + temporaryFiles + recoveredUploads + appData + sharedData }

    static func measure() async -> Self {
        let home = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
        let shared = ImmiSharedContainer.rootURL
        return await Task.detached(priority: .utility) {
            scan(home: home, shared: shared)
        }.value
    }

    /// Read allocated bytes, including hidden files and nested URLSession data.
    /// Nothing here opens photo contents or removes user data.
    static func scan(home: URL, shared: URL?) -> Self {
        var usage = Self()
        enumerate(home) { path, size in
            if path.hasPrefix("Library/Caches/immich-image-cache/") {
                usage.imageCache += size
            } else if path.hasPrefix("Library/Caches/") {
                usage.otherCaches += size
            } else if path.hasPrefix(BackupTemporaryFiles.recoveryRelativePath + "/") {
                usage.recoveredUploads += size
            } else if path.hasPrefix("tmp/") {
                let name = (path as NSString).lastPathComponent
                if name.hasPrefix("backup-source-")
                    || (name.hasPrefix("upload-") && (name as NSString).pathExtension == "multipart") {
                    usage.backupFiles += size
                } else {
                    usage.temporaryFiles += size
                }
            } else {
                usage.appData += size
            }
        }
        if let shared {
            enumerate(shared) { _, size in usage.sharedData += size }
        }
        return usage
    }

    private static func enumerate(_ root: URL, visit: (String, Int) -> Void) {
        let keys: Set<URLResourceKey> = [
            .isRegularFileKey, .totalFileAllocatedSizeKey, .fileAllocatedSizeKey, .fileSizeKey,
        ]
        // This enumerator supplies paths relative to the root. Slicing an
        // absolute URL by root.path.count breaks when Foundation normalizes
        // a trailing slash or the /var -> /private/var container alias.
        guard let files = FileManager.default.enumerator(atPath: root.path) else { return }
        for case let path as String in files {
            let url = root.appendingPathComponent(path)
            guard let values = try? url.resourceValues(forKeys: keys),
                  values.isRegularFile == true else { continue }
            visit(path, values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? values.fileSize ?? 0)
        }
    }
}
