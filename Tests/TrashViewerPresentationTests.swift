import SwiftUI
import UIKit
import Vision
import XCTest
@testable import ImmichApp

@MainActor
final class TrashViewerPresentationTests: XCTestCase {
    private var window: UIWindow?
    private weak var previousKeyWindow: UIWindow?

    override func tearDown() async throws {
        if let root = window?.rootViewController,
           let alert = presentedAlert(from: root) {
            await dismiss(alert)
        }
        closeWindow()
        try await super.tearDown()
    }

    private func closeWindow() {
        window?.isHidden = true
        window?.rootViewController = nil
        window = nil
        previousKeyWindow?.makeKey()
        previousKeyWindow = nil
    }

    func testCompactTrashViewerShowsRestoreAndPermanentDelete() async throws {
        try await assertTrashChrome(width: 390, sizeClass: .compact)
    }

    func testRegularTrashViewerShowsTheSameActionsInItsNavigationBar() async throws {
        try await assertTrashChrome(width: 1024, sizeClass: .regular)
    }

    func testOrdinaryViewerDoesNotAcquireTrashActions() async throws {
        let asset = photo()
        try show(AssetDetailView(currentAsset: asset, assets: [asset], isModal: true),
            width: 390, sizeClass: .compact)
        let text = try await visibleText()
        XCTAssertFalse(text.contains("Restore"), text)
        XCTAssertFalse(text.contains("Delete Permanently"), text)
    }

    func testPermanentDeletePresentsItsNativeConfirmationBeforeSendingARequest() async throws {
        let asset = photo()
        var deletions: [String] = []
        let actions = TrashViewerActions(restore: { _ in XCTFail("Delete must not restore"); return false },
            deletePermanently: { deletions.append($0); return true })
        try show(AssetDetailView(currentAsset: asset, assets: [asset],
            visibilityPolicy: AssetVisibilityPolicy(removalScope: .trash), isModal: true, trashActions: actions),
            width: 390, sizeClass: .compact)
        _ = try await visibleText()
        let root = try XCTUnwrap(window?.rootViewController)
        let item = try XCTUnwrap(barButtonItems(in: root).first {
            $0.title == "Delete Permanently" || $0.accessibilityLabel == "Delete Permanently"
        })
        let action = try XCTUnwrap(item.action, "The visible toolbar item must expose its UIKit action")
        XCTAssertTrue(UIApplication.shared.sendAction(action, to: item.target, from: item, for: nil))
        let confirmation = try await waitForPresentedAlert(from: root)
        XCTAssertEqual(confirmation.title, "Permanently Delete Photo?")
        XCTAssertEqual(confirmation.message, "This cannot be undone.")
        XCTAssertEqual(confirmation.actions.first(where: { $0.style == .destructive })?.title,
            "Delete Permanently")
        XCTAssertNotNil(confirmation.actions.first(where: { $0.style == .cancel }))
        XCTAssertTrue(deletions.isEmpty, "Opening the warning must not send a permanent deletion")
        await dismiss(confirmation)
    }

    func testRestoreToolbarUsesDisplayedPhotoAndOnlyRemovesItAfterSuccessfulRetry() async throws {
        for (width, sizeClass) in [(CGFloat(390), UserInterfaceSizeClass.compact), (CGFloat(1024), .regular)] {
            let asset = photo()
            let response = RestoreToolbarResponse()
            defer {
                response.abandon()
                closeWindow()
            }
            let actions = TrashViewerActions(restore: { await response.restore($0) },
                deletePermanently: { _ in XCTFail("Restore must not permanently delete"); return false },
                errorMessage: { response.recordFailure() })
            try show(AssetDetailView(currentAsset: asset, assets: [asset],
                visibilityPolicy: AssetVisibilityPolicy(removalScope: .trash), isModal: true,
                onAssetRemoved: { response.recordRemoval($0) }, trashActions: actions),
                width: width, sizeClass: sizeClass)
            _ = try await visibleText()

            try activateToolbarItem("Restore")
            await fulfillment(of: [response.requests[0]], timeout: 2)
            XCTAssertEqual(response.requestedIDs, [asset.id])
            XCTAssertTrue(response.removedIDs.isEmpty, "A pending restore must keep the displayed photo")
            try response.respond(false)
            await fulfillment(of: [response.failure], timeout: 2)
            XCTAssertTrue(response.removedIDs.isEmpty, "A failed restore must not notify the parent of a removal")

            // Resolve the current visible item again after failure redraws the
            // toolbar; the retry must still operate on the same displayed photo.
            _ = try await visibleText()
            try activateToolbarItem("Restore")
            await fulfillment(of: [response.requests[1]], timeout: 2)
            XCTAssertEqual(response.requestedIDs, [asset.id, asset.id])
            XCTAssertTrue(response.removedIDs.isEmpty)
            try response.respond(true)
            await fulfillment(of: [response.removal], timeout: 2)
            XCTAssertEqual(response.removedIDs, [asset.id])
            XCTAssertEqual(response.failureCount, 1)
        }
    }

    private func assertTrashChrome(width: CGFloat, sizeClass: UserInterfaceSizeClass) async throws {
        let asset = photo()
        let actions = TrashViewerActions(restore: { _ in XCTFail("Rendering must not restore"); return false },
            deletePermanently: { _ in XCTFail("Rendering must not delete"); return false })
        try show(AssetDetailView(currentAsset: asset, assets: [asset],
            visibilityPolicy: AssetVisibilityPolicy(removalScope: .trash), isModal: true, trashActions: actions),
            width: width, sizeClass: sizeClass)
        let text = try await visibleText()
        XCTAssertTrue(text.contains("Restore"), text)
        XCTAssertTrue(text.contains("Delete Permanently"), text)
        XCTAssertFalse(text.contains("Edit Photo"), text)
        XCTAssertFalse(text.contains("Share Link"), text)
        XCTAssertFalse(text.contains("Archive"), text)
        XCTAssertFalse(text.contains("Upload"), text)
    }

    private func photo() -> AssetLite {
        AssetLite(id: UUID().uuidString, isVideo: false, ratio: 1, thumbhash: nil,
            createdAt: Date(timeIntervalSince1970: 1_700_000_000))
    }

    private func barButtonItems(in controller: UIViewController) -> [UIBarButtonItem] {
        let groups = controller.navigationItem.leadingItemGroups + controller.navigationItem.centerItemGroups
            + controller.navigationItem.trailingItemGroups
        let ownItems = (controller.navigationItem.leftBarButtonItems ?? [])
            + (controller.navigationItem.rightBarButtonItems ?? [])
            + (controller.toolbarItems ?? [])
            + groups.flatMap(\.barButtonItems)
        return ownItems + controller.children.flatMap { barButtonItems(in: $0) }
    }

    private func activateToolbarItem(_ title: String) throws {
        let root = try XCTUnwrap(window?.rootViewController)
        let item = try XCTUnwrap(barButtonItems(in: root).first {
            $0.title == title || $0.accessibilityLabel == title
        })
        XCTAssertTrue(item.isEnabled, "The visible \(title) action must be enabled")
        let action = try XCTUnwrap(item.action, "The visible toolbar item must expose its UIKit action")
        XCTAssertTrue(UIApplication.shared.sendAction(action, to: item.target, from: item, for: nil))
    }

    private func presentedAlert(from controller: UIViewController) -> UIAlertController? {
        if let alert = controller as? UIAlertController { return alert }
        if let presented = controller.presentedViewController,
           let alert = presentedAlert(from: presented) { return alert }
        return controller.children.compactMap { presentedAlert(from: $0) }.first
    }

    private func dismiss(_ controller: UIViewController) async {
        await waitForTransition(of: controller)
        guard controller.presentingViewController != nil else { return }
        await withCheckedContinuation { continuation in
            controller.dismiss(animated: false) { continuation.resume() }
        }
    }

    private func waitForPresentedAlert(from root: UIViewController) async throws -> UIAlertController {
        let appeared = XCTNSPredicateExpectation(predicate: NSPredicate { [weak self, weak root] _, _ in
            guard let self, let root else { return false }
            if Thread.isMainThread {
                return MainActor.assumeIsolated { self.presentedAlert(from: root) != nil }
            }
            return DispatchQueue.main.sync { self.presentedAlert(from: root) != nil }
        }, object: nil)
        await fulfillment(of: [appeared], timeout: 2)
        let alert = try XCTUnwrap(presentedAlert(from: root))
        await waitForTransition(of: alert)
        return alert
    }

    private func waitForTransition(of controller: UIViewController) async {
        guard let coordinator = controller.transitionCoordinator else { return }
        let finished = expectation(description: "The UIKit presentation transition completed")
        coordinator.animate(alongsideTransition: nil) { _ in finished.fulfill() }
        await fulfillment(of: [finished], timeout: 2)
    }

    private func show(_ detail: AssetDetailView, width: CGFloat, sizeClass: UserInterfaceSizeClass) throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first(where: { $0.activationState == .foregroundActive }))
        previousKeyWindow = scene.windows.first(where: \.isKeyWindow)
        let host = UIHostingController(rootView: NavigationStack { detail }
            .environment(MockSessionManager() as SessionManager)
            .environment(\.horizontalSizeClass, sizeClass)
            .environment(\.locale, Locale(identifier: "en_US"))
            .environment(\.colorScheme, .light))
        let testWindow = UIWindow(windowScene: scene)
        testWindow.frame = CGRect(x: 0, y: 0, width: width, height: 844)
        testWindow.rootViewController = host
        testWindow.makeKeyAndVisible()
        host.view.frame = testWindow.bounds
        host.view.setNeedsLayout()
        host.view.layoutIfNeeded()
        window = testWindow
    }

    private func visibleText() async throws -> String {
        try await Task.sleep(for: .milliseconds(250))
        let window = try XCTUnwrap(window)
        window.layoutIfNeeded()
        let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        let attachment = XCTAttachment(image: image)
        attachment.lifetime = .keepAlways
        add(attachment)
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["en-US"]
        try VNImageRequestHandler(cgImage: try XCTUnwrap(image.cgImage)).perform([request])
        return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: " ")
    }
}

@MainActor
private final class RestoreToolbarResponse {
    let requests = [XCTestExpectation(description: "Initial toolbar restore reached its response"),
        XCTestExpectation(description: "Toolbar restore retry reached its response")]
    let failure = XCTestExpectation(description: "The failed toolbar restore was reported")
    let removal = XCTestExpectation(description: "The successful toolbar restore notified its parent")
    private(set) var requestedIDs: [String] = []
    private(set) var removedIDs: [String] = []
    private(set) var failureCount = 0
    private var pending: CheckedContinuation<Bool, Never>?
    private var isAbandoned = false

    init() {
        removal.assertForOverFulfill = true
        failure.assertForOverFulfill = true
    }

    func restore(_ id: String) async -> Bool {
        guard !isAbandoned else { return false }
        guard requestedIDs.count < requests.count, pending == nil else {
            XCTFail("The toolbar must not send an extra or overlapping restore")
            return false
        }
        requestedIDs.append(id)
        return await withCheckedContinuation {
            pending = $0
            requests[requestedIDs.count - 1].fulfill()
        }
    }

    func respond(_ succeeds: Bool) throws {
        let continuation = try XCTUnwrap(pending, "The toolbar must reach its held response before completion")
        pending = nil
        continuation.resume(returning: succeeds)
    }

    func recordFailure() -> String {
        guard !isAbandoned else { return "Restore rejected" }
        failureCount += 1
        failure.fulfill()
        return "Restore rejected"
    }

    func recordRemoval(_ id: String) {
        guard !isAbandoned else { return }
        removedIDs.append(id)
        removal.fulfill()
    }

    func abandon() {
        isAbandoned = true
        pending?.resume(returning: false)
        pending = nil
    }
}
