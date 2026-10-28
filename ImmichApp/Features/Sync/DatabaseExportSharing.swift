import Observation
import SwiftUI

@MainActor
@Observable
final class DatabaseExportSharing {
    final class Presentation: Identifiable, Sendable {
        let id = UUID()
        let url: URL

        init(url: URL) { self.url = url }

        deinit { TemporaryMediaStore.remove(url) }
    }

    private(set) var presentation: Presentation?
    private(set) var isPreparing = false
    private var request: UUID?

    var binding: Binding<Presentation?> {
        let id = presentation?.id
        return Binding(get: { self.presentation }, set: { value in
            if value == nil, let id { self.finish(id) }
        })
    }

    func prepare(
        session: SessionManager,
        export: @MainActor () async throws -> URL
    ) async -> String? {
        guard !isPreparing, presentation == nil, !Task.isCancelled else { return nil }
        let currentRequest = UUID()
        request = currentRequest
        let generation = LocalSnapshot.generation
        let context = session.snapshot
        isPreparing = true
        defer {
            if request == currentRequest { isPreparing = false; request = nil }
        }

        do {
            let source = try await export()
            // Consume the export even when navigation/account changes won the
            // race. An export is owned temporary data, never the working store.
            var adopted = false
            defer { if !adopted { try? FileManager.default.removeItem(at: source) } }
            try Task.checkCancellation()
            try session.checkCurrent(context)
            guard generation == LocalSnapshot.generation, request == currentRequest else { return nil }
            let url = try TemporaryMediaStore.adoptShareFile(at: source,
                suggestedFilename: source.lastPathComponent)
            adopted = true
            presentation = Presentation(url: url)
            return nil
        } catch is CancellationError {
            return nil
        } catch {
            guard !Task.isCancelled, generation == LocalSnapshot.generation,
                  request == currentRequest, (try? session.checkCurrent(context)) != nil else { return nil }
            return error.localizedDescription
        }
    }

    func shareSheet(for item: Presentation) -> MultiShareSheet {
        MultiShareSheet(urls: [item.url], onFinish: {
            Task { @MainActor in self.finish(item.id) }
        })
    }

    func finish(_ id: UUID) {
        guard let current = presentation, current.id == id else { return }
        TemporaryMediaStore.remove(current.url)
        presentation = nil
    }

    /// A sheet can cover its parent while the receiver still reads the file.
    /// Only pending preparation is canceled when the parent disappears.
    func cancelPreparation() {
        request = nil
        isPreparing = false
    }

    func invalidate() {
        cancelPreparation()
        if let id = presentation?.id { finish(id) }
    }
}
