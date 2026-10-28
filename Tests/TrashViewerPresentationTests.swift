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
        window?.isHidden = true
        window?.rootViewController = nil
        window = nil
        previousKeyWindow?.makeKey()
        previousKeyWindow = nil
        try await super.tearDown()
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
        try await Task.sleep(for: .milliseconds(250))

        let confirmation = try XCTUnwrap(presentedAlert(from: root))
        XCTAssertEqual(confirmation.title, "Permanently Delete Photo?")
        XCTAssertEqual(confirmation.message, "This cannot be undone.")
        XCTAssertEqual(confirmation.actions.first(where: { $0.style == .destructive })?.title,
            "Delete Permanently")
        XCTAssertNotNil(confirmation.actions.first(where: { $0.style == .cancel }))
        XCTAssertTrue(deletions.isEmpty, "Opening the warning must not send a permanent deletion")
        confirmation.dismiss(animated: false)
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
        let ownItems = (controller.navigationItem.leftBarButtonItems ?? [])
            + (controller.navigationItem.rightBarButtonItems ?? [])
            + (controller.toolbarItems ?? [])
        return ownItems + controller.children.flatMap { barButtonItems(in: $0) }
    }

    private func presentedAlert(from controller: UIViewController) -> UIAlertController? {
        if let alert = controller as? UIAlertController { return alert }
        if let presented = controller.presentedViewController,
           let alert = presentedAlert(from: presented) { return alert }
        return controller.children.compactMap { presentedAlert(from: $0) }.first
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
