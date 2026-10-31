import AVFoundation
import ImageIO
import Observation
import UIKit
import UniformTypeIdentifiers

enum MediaCopy {
    struct Source: Sendable {
        let url: URL
        let isVideo: Bool
    }

    struct Item: Sendable, Equatable {
        let typeIdentifier: String
        let data: Data
    }

    enum CopyError: LocalizedError {
        case unavailable

        var errorDescription: String? { String(localized: "Could not copy these items.") }
    }

    static func prepare(_ sources: [Source]) async throws -> [Item] {
        try Task.checkCancellation()
        guard !sources.isEmpty else { throw CopyError.unavailable }
        let task = Task.detached(priority: .userInitiated) {
            var items: [Item] = []
            for source in sources {
                try Task.checkCancellation()
                guard source.url.isFileURL else { throw CopyError.unavailable }
                let data: Data
                do { data = try Data(contentsOf: source.url, options: .mappedIfSafe) }
                catch { throw CopyError.unavailable }
                guard !data.isEmpty else { throw CopyError.unavailable }
                let type: UTType
                if source.isVideo {
                    do {
                        let tracks = try await AVURLAsset(url: source.url).loadTracks(withMediaType: .video)
                        guard !tracks.isEmpty else {
                            throw CopyError.unavailable
                        }
                    } catch is CancellationError { throw CancellationError() }
                    catch { throw CopyError.unavailable }
                    let actual = PhotoExportService.contentType(of: source.url)
                    guard !actual.conforms(to: .image) else { throw CopyError.unavailable }
                    type = actual.conforms(to: .movie) || actual.conforms(to: .video) ? actual : .movie
                } else {
                    guard let image = CGImageSourceCreateWithData(data as CFData, nil),
                          CGImageSourceGetStatus(image) == .statusComplete,
                          CGImageSourceGetCount(image) > 0,
                          CGImageSourceCreateImageAtIndex(image, 0, nil) != nil,
                          let identifier = CGImageSourceGetType(image) as String?,
                          let imageType = UTType(identifier), imageType.conforms(to: .image) else {
                        throw CopyError.unavailable
                    }
                    type = imageType
                }
                try Task.checkCancellation()
                items.append(Item(typeIdentifier: type.identifier, data: data))
            }
            return items
        }
        let items = try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
        try Task.checkCancellation()
        return items
    }

    @MainActor
    static func write(_ items: [Item], using writer: ([[String: Any]]) -> Void = { UIPasteboard.general.setItems($0) }) {
        writeRepresentations(items.map { [$0] }, using: writer)
    }

    @MainActor
    static func writeRepresentations(
        _ groups: [[Item]], using writer: ([[String: Any]]) -> Void = { UIPasteboard.general.setItems($0) }
    ) {
        guard !groups.isEmpty, groups.allSatisfy({ !$0.isEmpty }) else { return }
        writer(groups.map { group in
            Dictionary(group.map { ($0.typeIdentifier, $0.data as Any) }, uniquingKeysWith: { first, _ in first })
        })
    }
}

@MainActor
@Observable
final class MediaCopyPreparation {
    private(set) var isPreparing = false
    private var request = UUID()
    private var task: Task<Void, Never>?
    private let prepareItems: @Sendable ([MediaCopy.Source]) async throws -> [MediaCopy.Item]

    init(prepareItems: @escaping @Sendable ([MediaCopy.Source]) async throws -> [MediaCopy.Item] = { try await MediaCopy.prepare($0) }) {
        self.prepareItems = prepareItems
    }

    @discardableResult
    func start(
        ids: [String],
        prepare: @escaping @MainActor ([String]) async -> [MediaCopy.Source],
        isAllowed: @escaping @MainActor (String) -> Bool,
        onError: @escaping @MainActor (String) -> Void,
        writer: @escaping @MainActor ([[String: Any]]) -> Void = { UIPasteboard.general.setItems($0) }
    ) -> Task<Void, Never>? {
        guard !Task.isCancelled, !isPreparing, !ids.isEmpty, ids.allSatisfy(isAllowed) else { return nil }
        let generation = LocalSnapshot.generation
        let sourceIDs = AssetServerIdentity.exportIDs(for: ids)
        let token = UUID()
        request = token
        isPreparing = true
        let operation = Task {
            defer {
                if request == token { isPreparing = false; task = nil }
            }
            guard !Task.isCancelled, request == token, generation == LocalSnapshot.generation,
                  AssetServerIdentity.exportIDs(for: ids) == sourceIDs,
                  ids.allSatisfy(isAllowed) else { return }
            let sources = await prepare(ids)
            defer { TemporaryMediaStore.remove(sources.map(\.url)) }
            guard !Task.isCancelled, request == token, generation == LocalSnapshot.generation,
                  AssetServerIdentity.exportIDs(for: ids) == sourceIDs,
                  ids.allSatisfy(isAllowed) else { return }
            do {
                guard sources.count == ids.count else { throw MediaCopy.CopyError.unavailable }
                let items = try await prepareItems(sources)
                guard !Task.isCancelled, request == token, generation == LocalSnapshot.generation,
                      AssetServerIdentity.exportIDs(for: ids) == sourceIDs,
                      ids.allSatisfy(isAllowed) else { return }
                MediaCopy.write(items, using: writer)
            } catch {
                guard !Task.isCancelled, !(error is CancellationError), request == token,
                      generation == LocalSnapshot.generation,
                      AssetServerIdentity.exportIDs(for: ids) == sourceIDs,
                      ids.allSatisfy(isAllowed) else { return }
                onError(error.localizedDescription)
            }
        }
        task = operation
        return operation
    }

    func cancel() {
        request = UUID()
        task?.cancel()
        task = nil
        isPreparing = false
    }
}
