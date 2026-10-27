import Combine
import Foundation
import UniformTypeIdentifiers
import UIKit

struct SharePreviewItem: Identifiable {
    var uploadItem: SharedUploadItem
    let fileURL: URL
    let thumbnail: UIImage?
    var isSelected = true

    var id: UUID { uploadItem.id }
}

@MainActor
final class ShareExtensionModel: ObservableObject {
    enum Phase: Equatable {
        case loading
        case ready
        case uploading(current: Int, total: Int)
        case queued(Int)
        case failed(String)
    }

    @Published private(set) var phase: Phase = .loading
    @Published private(set) var items: [SharePreviewItem] = []
    @Published private(set) var session = SharedSessionStore.load()
    private let submission = SharedUploadSubmission()
    private weak var shareContext: NSExtensionContext?
    private var hasLoaded = false

    init(extensionContext: NSExtensionContext?) {
        shareContext = extensionContext
    }

    var selectedCount: Int { items.count(where: \.isSelected) }
    var canEditSelection: Bool { !isBusy && submission.canEdit }
    var isBusy: Bool { phase == .loading || submission.isProcessing || submission.isClosing }
    var serverLabel: String {
        session?.displayServerURL ?? String(localized: "Sign in to SelfPhotos first")
    }

    func load() async {
        guard !hasLoaded else { return }
        hasLoaded = true

        do {
            let directory = try await SharedUploadStore.shared.makeBatchDirectory(id: submission.batchID)
            let providers = (shareContext?.inputItems as? [NSExtensionItem] ?? [])
                .flatMap { $0.attachments ?? [] }
                .prefix(30)

            for provider in providers {
                guard let typeIdentifier = Self.supportedTypeIdentifier(for: provider)
                else { continue }
                let materialized = try await Self.materialize(
                    provider: provider,
                    typeIdentifier: typeIdentifier,
                    directory: directory)
                items.append(materialized)
            }

            phase = items.isEmpty
                ? .failed(String(localized: "No supported photos or videos were shared."))
                : .ready
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    func toggle(_ id: UUID) {
        guard canEditSelection, let index = items.firstIndex(where: { $0.id == id }) else { return }
        items[index].isSelected.toggle()
    }

    func primaryAction() {
        switch phase {
        case .queued:
            cancel()
        case .ready, .failed:
            let selected = items.filter(\.isSelected).map(\.uploadItem)
            guard !selected.isEmpty, submission.begin() else { return }
            phase = .uploading(current: 0, total: selected.count)
            Task { await uploadSelected(selected) }
        default:
            break
        }
    }

    func cancel() {
        guard !isBusy else { return }
        phase = .loading
        Task {
            do {
                if try await submission.close() { complete() }
            } catch {
                phase = .failed(error.localizedDescription)
            }
        }
    }

    private func uploadSelected(_ selected: [SharedUploadItem]) async {
        defer { submission.finish() }
        guard let credential = session?.credential() else {
            phase = .failed(String(localized: "Open SelfPhotos and sign in before uploading."))
            return
        }

        do {
            try await submission.admit(owner: credential.owner, items: selected)
        } catch {
            phase = .failed(error.localizedDescription)
            return
        }

        let client = SharedUploadClient(credential: credential)
        do {
            let outcome = try await SharedUploadProcessor(store: .shared).process(
                batchID: submission.batchID,
                owner: credential.owner,
                upload: { item, fileURL, directory in
                    _ = try await client.upload(item: item, fileURL: fileURL, bodyDirectory: directory)
                },
                progress: { [weak self] current, total in
                    self?.phase = .uploading(current: current, total: total)
                })
            switch outcome {
            case .busy:
                phase = .queued(selected.count)
            case .finished(let remaining):
                phase = .queued(remaining)
                if remaining == 0 {
                    try? await Task.sleep(for: .milliseconds(450))
                    complete()
                }
            }
        } catch {
            // Admission already succeeded. Closing must leave these files for
            // the app even when a later checkpoint or cleanup could not save.
            do {
                let batch = try await SharedUploadStore.shared.batch(
                    id: submission.batchID, owner: credential.owner)
                phase = .queued(batch?.items.count { $0.state != .uploaded } ?? 0)
            } catch {
                phase = .queued(selected.count)
            }
        }
    }

    private func complete() {
        shareContext?.completeRequest(returningItems: nil)
    }

    private nonisolated static func materialize(
        provider: NSItemProvider,
        typeIdentifier: String,
        directory: URL
    ) async throws -> SharePreviewItem {
        let providerSuggestedName = provider.suggestedName
        return try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<SharePreviewItem, Error>) in
            provider.loadFileRepresentation(forTypeIdentifier: typeIdentifier) {
                sourceURL, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                guard let sourceURL else {
                    continuation.resume(throwing: SharedUploadStoreError.invalidFilename)
                    return
                }

                do {
                    let sharedType = UTType(typeIdentifier) ?? .data
                    let type = UTType(filenameExtension: sourceURL.pathExtension) ?? sharedType
                    let fallbackExtension = type.preferredFilenameExtension
                        ?? (sharedType.conforms(to: .movie) ? "mov" : "jpg")
                    let fallbackName = sharedType.conforms(to: .movie)
                        ? "Shared Video" : "Shared Image"
                    var suggested = providerSuggestedName?.trimmingCharacters(in: .whitespacesAndNewlines)
                    if suggested?.isEmpty != false { suggested = sourceURL.deletingPathExtension().lastPathComponent }
                    if (suggested as NSString?)?.pathExtension.isEmpty != false {
                        suggested = "\(suggested ?? fallbackName).\(fallbackExtension)"
                    }
                    let safeName = sanitize(suggested ?? "\(fallbackName).\(fallbackExtension)")
                    let id = UUID()
                    let storedName = "\(id.uuidString)-\(safeName)"
                    let destination = directory.appendingPathComponent(storedName)
                    try FileManager.default.copyItem(at: sourceURL, to: destination)

                    let values = try destination.resourceValues(forKeys: [
                        .fileSizeKey,
                        .creationDateKey,
                        .contentModificationDateKey,
                    ])
                    let now = Date()
                    let item = SharedUploadItem(
                        id: id,
                        filename: safeName,
                        relativePath: storedName,
                        contentType: type.preferredMIMEType ?? "application/octet-stream",
                        byteCount: Int64(values.fileSize ?? 0),
                        createdAt: values.creationDate ?? now,
                        modifiedAt: values.contentModificationDate ?? now,
                        state: .queued,
                        lastError: nil)
                    continuation.resume(returning: SharePreviewItem(
                        uploadItem: item,
                        fileURL: destination,
                        thumbnail: UIImage(contentsOfFile: destination.path)))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private nonisolated static func supportedTypeIdentifier(
        for provider: NSItemProvider
    ) -> String? {
        // Movie diperiksa lebih dulu agar provider video yang juga menawarkan
        // thumbnail gambar tidak kehilangan file aslinya dan hanya mengunggah
        // satu frame diam.
        if provider.hasItemConformingToTypeIdentifier(UTType.movie.identifier) {
            return UTType.movie.identifier
        }
        if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
            return UTType.image.identifier
        }
        return nil
    }

    private nonisolated static func sanitize(_ filename: String) -> String {
        let forbidden = CharacterSet(charactersIn: "/:\\")
        let pieces = filename.components(separatedBy: forbidden)
        let joined = pieces.filter { !$0.isEmpty }.joined(separator: "-")
        return joined.isEmpty ? "Shared Image.jpg" : joined
    }
}
