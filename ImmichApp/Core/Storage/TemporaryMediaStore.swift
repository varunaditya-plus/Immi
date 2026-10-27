import Foundation

/// Tempat terisolasi untuk media yang harus diberikan ke share sheet.
///
/// Berkas di `temporaryDirectory` tidak otomatis hilang saat share sheet
/// ditutup. Menulis original foto/video langsung ke akar folder tersebut
/// membuat setiap aset yang pernah dibagikan menetap sampai iOS kebetulan
/// membersihkannya — pada pustaka video besar jumlahnya bisa puluhan GB.
enum TemporaryMediaStore {
    private static let shareDirectoryName = "selfphotos-share"

    private static var shareDirectory: URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent(shareDirectoryName, isDirectory: true)
    }

    /// Consumes an exported/downloaded temporary file, including on failure.
    /// A move keeps large originals out of memory and avoids another full copy.
    static func adoptShareFile(at source: URL, suggestedFilename: String) throws -> URL {
        guard source.isFileURL else { throw CocoaError(.fileReadUnsupportedScheme) }
        let fileManager = FileManager.default
        if Task.isCancelled {
            try? fileManager.removeItem(at: source)
            throw CancellationError()
        }
        let root = shareDirectory.standardizedFileURL.path + "/"
        if source.standardizedFileURL.path.hasPrefix(root) { return source }
        defer { try? fileManager.removeItem(at: source) }
        try fileManager.createDirectory(
            at: shareDirectory,
            withIntermediateDirectories: true)

        let safeName = URL(fileURLWithPath:
            suggestedFilename.replacingOccurrences(of: "\\", with: "/")).lastPathComponent
        let filename = safeName.isEmpty || safeName == "." || safeName == ".." ? "media" : safeName
        let url = shareDirectory
            .appendingPathComponent(UUID().uuidString + "-" + filename)
        do {
            try fileManager.moveItem(at: source, to: url)
            try Task.checkCancellation()
            return url
        } catch {
            try? fileManager.removeItem(at: url)
            throw error
        }
    }

    /// Hanya menghapus URL yang memang dibuat store ini. `ShareSheet` juga
    /// dipakai untuk tautan HTTPS, jadi URL yang diserahkan pemanggil tidak
    /// boleh dihapus secara membabi buta.
    static func remove(_ urls: [URL]) {
        let root = shareDirectory.standardizedFileURL.path + "/"
        for url in urls {
            let candidate = url.standardizedFileURL
            guard candidate.isFileURL, candidate.path.hasPrefix(root) else { continue }
            try? FileManager.default.removeItem(at: candidate)
        }
    }

    static func remove(_ url: URL) {
        remove([url])
    }

    /// Dipanggil setiap cold launch. Direktori share khusus selalu basi setelah
    /// proses sebelumnya mati. Berkas lama di akar tmp ikut dibuang untuk
    /// memulihkan kebocoran dari versi app terdahulu.
    ///
    /// Sumber dan multipart backup dikecualikan karena background URLSession
    /// dapat melanjutkan transfernya setelah app diluncurkan ulang.
    static func cleanupAfterLaunch() {
        let fileManager = FileManager.default
        // Old working directories can contain files that a root-only scan
        // never visits. Keep recent work: frameworks may create it before
        // didFinishLaunchingWithOptions is called.
        cleanupStaleWorkingDirectories(
            in: fileManager.temporaryDirectory,
            olderThan: Date().addingTimeInterval(-24 * 60 * 60))
        try? fileManager.removeItem(at: shareDirectory)
        cleanupStaleFiles(
            in: fileManager.temporaryDirectory,
            // Cold launch tidak punya share foreground yang masih aktif. Semua
            // regular file selain sumber backup yang dikecualikan di bawah
            // aman dibuang sekarang juga, termasuk kebocoran yang masih baru.
            olderThan: .distantFuture)
    }

    /// Cold-launch cleanup for the app's abandoned nested working files.
    /// Do not recursively wipe tmp: unrelated directories may belong to
    /// background transfers, and symlinks must never expand this scope.
    static func cleanupStaleWorkingDirectories(in directory: URL, olderThan cutoff: Date) {
        let manager = FileManager.default
        let keys: Set<URLResourceKey> = [
            .isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey, .contentModificationDateKey,
        ]
        guard let roots = try? manager.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: Array(keys)) else { return }

        func isDisposable(_ url: URL) -> Bool {
            let name = url.lastPathComponent
            guard !name.hasPrefix("upload-"), !name.hasPrefix("backup-source-"),
                  let values = try? url.resourceValues(forKeys: keys),
                  values.isSymbolicLink != true,
                  let modified = values.contentModificationDate, modified < cutoff
            else { return false }
            if values.isDirectory == true {
                guard let children = try? manager.contentsOfDirectory(
                    at: url, includingPropertiesForKeys: Array(keys)) else { return false }
                return children.allSatisfy(isDisposable)
            }
            return values.isRegularFile == true
        }

        for root in roots where root.lastPathComponent.hasPrefix("NSIRD_ImmichApp_") {
            guard (try? root.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true,
                  isDisposable(root) else { continue }
            try? manager.removeItem(at: root)
        }
    }

    /// Internal agar aturan pemulihan versi lama bisa diuji tanpa menyentuh tmp
    /// milik proses test.
    static func cleanupStaleFiles(in directory: URL, olderThan cutoff: Date) {
        let fileManager = FileManager.default
        guard let contents = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [
                .isRegularFileKey,
                .contentModificationDateKey,
            ],
            options: [.skipsHiddenFiles])
        else { return }

        for url in contents {
            let name = url.lastPathComponent
            // Dipakai oleh pemulihan backup lintas-peluncuran.
            if name.hasPrefix("upload-") || name.hasPrefix("backup-source-") {
                continue
            }

            guard let values = try? url.resourceValues(forKeys: [
                .isRegularFileKey,
                .contentModificationDateKey,
            ]),
            values.isRegularFile == true,
            let modified = values.contentModificationDate,
            modified < cutoff
            else { continue }

            try? fileManager.removeItem(at: url)
        }
    }
}
