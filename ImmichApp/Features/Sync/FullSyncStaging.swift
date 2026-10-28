import Foundation

/// The download is disposable until its completion marker arrives. An unlinked
/// file keeps large snapshots off the heap and is reclaimed even after a crash.
final class FullSyncStaging {
    struct Entry: Codable {
        var id: String
        var asset: Asset?
        var visibility: String?
        var permanentlyDeleted: Bool = false
    }

    struct Asset: Codable {
        var id: String
        var type: String
        var isFavorite: Bool
        var createdAt: Date
        var updatedAt: Date
        var ratio: Double?
        var thumbhash: String?
        var duration: Double?
        var livePhotoVideoId: String?

        @MainActor
        init(_ asset: CachedAsset) {
            id = asset.id
            type = asset.type
            isFavorite = asset.isFavorite
            createdAt = asset.createdAt
            updatedAt = asset.updatedAt
            ratio = asset.ratio
            thumbhash = asset.thumbhash
            duration = asset.duration
            livePhotoVideoId = asset.livePhotoVideoId
        }

        @MainActor
        func cachedAsset(visibility: String) -> CachedAsset {
            CachedAsset(id: id, assetId: id, type: type,
                isFavorite: isFavorite, isArchived: visibility != "timeline",
                duration: duration, livePhotoVideoId: livePhotoVideoId,
                createdAt: createdAt, updatedAt: updatedAt,
                ratio: ratio, thumbhash: thumbhash)
        }
    }

    private let handle: FileHandle

    init() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("full-sync-\(UUID().uuidString).ndjson")
        guard FileManager.default.createFile(atPath: url.path, contents: nil,
            attributes: [.posixPermissions: 0o600,
                .protectionKey: FileProtectionType.completeUntilFirstUserAuthentication]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        do {
            handle = try FileHandle(forUpdating: url)
            try FileManager.default.removeItem(at: url)
        } catch {
            try? FileManager.default.removeItem(at: url)
            throw error
        }
    }

    deinit { try? handle.close() }

    @MainActor
    func append(_ asset: CachedAsset, visibility: String) throws {
        try append(Entry(id: asset.id, asset: Asset(asset), visibility: visibility))
    }

    func appendDeletion(_ id: String, permanently: Bool) throws {
        try append(Entry(id: id, permanentlyDeleted: permanently))
    }

    private func append(_ entry: Entry) throws {
        var data = try JSONEncoder().encode(entry)
        data.append(0x0a)
        try handle.write(contentsOf: data)
    }

    @MainActor
    func forEachBatch(_ body: ([Entry]) throws -> Void) throws {
        try handle.seek(toOffset: 0)
        var buffer = Data()
        var entries: [Entry] = []
        while let chunk = try handle.read(upToCount: 64 * 1_024), !chunk.isEmpty {
            try Task.checkCancellation()
            buffer.append(chunk)
            while let end = buffer.firstIndex(of: 0x0a) {
                entries.append(try JSONDecoder().decode(Entry.self, from: buffer[..<end]))
                buffer.removeSubrange(...end)
                if entries.count == 500 {
                    try body(entries)
                    entries.removeAll(keepingCapacity: true)
                }
            }
        }
        guard buffer.isEmpty else { throw CocoaError(.fileReadCorruptFile) }
        if !entries.isEmpty { try body(entries) }
    }
}
