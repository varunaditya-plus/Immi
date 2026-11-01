import SwiftUI
import UIKit
import XCTest
@testable import ImmichApp

@MainActor
final class AlbumCommentComposerTests: SimulatorHostedTestCase {
    func testDelayedSendPreservesTheNewerDraftTypedIntoTheActualComposer() async throws {
        let (window, model, repository) = try await showComposer()
        try await enter("First comment", in: window)
        try await activateAccessibilityButton(named: "Send Comment", in: window)
        await fulfillment(of: [repository.started], timeout: 2)
        XCTAssertTrue(model.isPerformingAction)
        try await enter("A newer unsent draft", in: window)

        repository.complete(.success(()))

        try await waitUntil("The real Send action finishes") { !model.isPerformingAction }
        _ = try await screenshot(window)
        XCTAssertEqual(repository.comments, ["First comment"])
        XCTAssertEqual(model.items.first?.activity.comment, "First comment")
        XCTAssertEqual(text(in: window), "A newer unsent draft")
    }

    func testSuccessfulSendClearsTheActualUnchangedComposer() async throws {
        let (window, model, repository) = try await showComposer()
        try await enter("Accepted comment", in: window)
        try await activateAccessibilityButton(named: "Send Comment", in: window)
        await fulfillment(of: [repository.started], timeout: 2)

        repository.complete(.success(()))

        try await waitUntil("Accepted text clears after the actual action") {
            !model.isPerformingAction && self.text(in: window).isEmpty
        }
        XCTAssertEqual(repository.comments, ["Accepted comment"])
        XCTAssertEqual(model.items.first?.activity.comment, "Accepted comment")
    }

    func testRejectedSendRetainsTheActualDraftForRetry() async throws {
        let (window, model, repository) = try await showComposer()
        try await enter("Do not discard this", in: window)
        try await activateAccessibilityButton(named: "Send Comment", in: window)
        await fulfillment(of: [repository.started], timeout: 2)

        repository.complete(.failure(APIError.server(status: 403, message: "Read only")))

        try await waitUntil("Rejected comment exposes action feedback") { model.actionError != nil }
        XCTAssertEqual(text(in: window), "Do not discard this")
        XCTAssertTrue(model.items.isEmpty)
    }

    private func showComposer() async throws -> (UIWindow, AlbumActivityViewModel, ComposerActivityRepository) {
        let repository = ComposerActivityRepository(api: makeStubAPIClient())
        let model = AlbumActivityViewModel(repository: repository)
        let album = AlbumResponseDTO(id: UUID().uuidString, albumName: "Shared album", description: nil,
            assetCount: 0, albumThumbnailAssetId: nil, shared: true, createdAt: .distantPast, assets: nil)
        let window = try await host(AlbumActivitySheet(album: album, viewModel: model))
        addTeardownBlock { repository.complete(.failure(CancellationError())) }
        try await waitUntil("The real native composer is mounted") { self.input(in: window) != nil }
        return (window, model, repository)
    }

    private func enter(_ value: String, in window: UIWindow) async throws {
        let input = try XCTUnwrap(input(in: window))
        if let textView = input as? UITextView {
            XCTAssertTrue(textView.isEditable)
            textView.text = value
            textView.delegate?.textViewDidChange?(textView)
        } else if let textField = input as? UITextField {
            XCTAssertTrue(textField.isEnabled)
            textField.text = value
            textField.sendActions(for: .editingChanged)
        } else { XCTFail("Expected the native editable composer"); return }
        try await waitUntil("The composer accepts typed text") { self.text(in: window) == value }
    }

    private func input(in view: UIView) -> UIView? {
        if view is UITextView || view is UITextField { return view }
        for child in view.subviews {
            if let found = input(in: child) { return found }
        }
        return nil
    }

    private func text(in view: UIView) -> String {
        if let input = input(in: view) as? UITextView { return input.text ?? "" }
        if let input = input(in: view) as? UITextField { return input.text ?? "" }
        return ""
    }
}

private final class ComposerActivityRepository: AlbumActivityRepository {
    let started = XCTestExpectation(description: "Actual composer sent its comment")
    var comments: [String] = []
    private var continuation: CheckedContinuation<Void, Error>?
    private var result: Result<Void, Error>?

    override func all(in albumID: String) async throws -> [AlbumActivityDTO] { [] }

    override func comment(_ text: String, in albumID: String) async throws -> AlbumActivityDTO {
        comments.append(text)
        started.fulfill()
        if let result { try result.get() }
        else { try await withCheckedThrowingContinuation { continuation = $0 } }
        return AlbumActivityDTO(id: UUID().uuidString, assetId: nil, comment: text, createdAt: Date(), type: "comment",
            user: UserResponseDTO(id: "user", email: "user@example.test", name: "Person", profileImagePath: nil,
                profileChangedAt: nil, storageLabel: nil, isAdmin: false))
    }

    func complete(_ result: Result<Void, Error>) {
        guard self.result == nil else { return }
        self.result = result
        continuation?.resume(with: result)
        continuation = nil
    }
}
