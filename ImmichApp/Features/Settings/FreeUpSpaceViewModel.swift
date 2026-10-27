import Foundation
import Observation

@MainActor
@Observable
final class FreeUpSpaceViewModel {
    enum Stage: Equatable {
        case select
        case scanning
        case review
        case deleting
        case complete
    }

    private(set) var stage = Stage.select
    var candidates: [LocalSpaceCandidate] { review?.candidates ?? [] }
    private(set) var removedCount = 0
    var actionError: ErrorEvent?

    var isBusy: Bool { stage == .scanning || stage == .deleting }

    private let scanner: @MainActor (LocalSpaceRules) async throws -> FreeUpSpaceReview
    private let remover: @MainActor (FreeUpSpaceReview) async throws -> Int
    private var review: FreeUpSpaceReview?
    private var revision = UUID()
    @ObservationIgnored private var operation: Task<Void, Never>?

    init(
        scanner: @escaping @MainActor (LocalSpaceRules) async throws -> FreeUpSpaceReview,
        remover: @escaping @MainActor (FreeUpSpaceReview) async throws -> Int
    ) {
        self.scanner = scanner
        self.remover = remover
    }

    /// Rule changes and leaving the screen revoke every pending result, even
    /// when a scanner or the Photos confirmation ignores task cancellation.
    func invalidate() {
        revision = UUID()
        operation?.cancel()
        operation = nil
        review = nil
        removedCount = 0
        actionError = nil
        stage = .select
    }

    /// Capture the review request synchronously, before its task can be delayed
    /// by another UI event which changes the cutoff or account.
    @discardableResult
    func scan(_ rules: LocalSpaceRules) -> Task<Void, Never>? {
        guard stage != .deleting, rules.cutoff != nil else { return nil }
        invalidate()
        let expectedRevision = revision
        stage = .scanning
        let scanner = scanner
        let task = Task { [weak self] in
            defer {
                if self?.revision == expectedRevision { self?.operation = nil }
            }
            do {
                try Task.checkCancellation()
                let result = try await scanner(rules)
                guard let self, revision == expectedRevision, !Task.isCancelled else { return }
                review = result
                stage = .review
            } catch is CancellationError {
                guard self?.revision == expectedRevision else { return }
                self?.stage = .select
            } catch {
                guard let self, revision == expectedRevision, !Task.isCancelled else { return }
                stage = .select
                actionError = ErrorEvent(error.localizedDescription)
            }
        }
        operation = task
        return task
    }

    @discardableResult
    func remove() -> Task<Void, Never>? {
        guard stage == .review, let review, !review.candidates.isEmpty else { return nil }
        let expectedRevision = revision
        stage = .deleting
        actionError = nil
        let remover = remover
        let task = Task { [weak self] in
            defer {
                if self?.revision == expectedRevision { self?.operation = nil }
            }
            do {
                try Task.checkCancellation()
                let count = try await remover(review)
                guard let self, revision == expectedRevision, !Task.isCancelled else { return }
                self.review = nil
                guard count > 0 else {
                    stage = .select
                    actionError = ErrorEvent("No items could be verified for removal. Scan again.")
                    return
                }
                removedCount = count
                stage = .complete
            } catch is CancellationError {
                guard let self, revision == expectedRevision else { return }
                self.review = nil
                stage = .select
            } catch {
                guard let self, revision == expectedRevision, !Task.isCancelled else { return }
                stage = .review
                actionError = ErrorEvent(error.localizedDescription)
            }
        }
        operation = task
        return task
    }
}
