import SwiftUI
import XCTest
@testable import ImmichApp

@MainActor
final class LockedContentPrivacyGuardTests: XCTestCase {
    private var window: UIWindow!
    private var root: UIViewController!
    private weak var previousKeyWindow: UIWindow?

    override func setUp() async throws {
        previousKeyWindow = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }.flatMap(\.windows).first(where: \.isKeyWindow)
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        root = UIViewController()
        window.rootViewController = root
        window.makeKeyAndVisible()
        root.loadViewIfNeeded()
    }

    override func tearDown() async throws {
        window.isHidden = true
        window.rootViewController = nil
        window = nil
        root = nil
        previousKeyWindow?.makeKey()
    }

    func testDeactivationCoversViewerBeforeRevocationAndDismissesItBeforeUncovering() async throws {
        let viewer = UIViewController()
        viewer.modalPresentationStyle = .overFullScreen
        root.present(viewer, animated: false)
        XCTAssertTrue(root.presentedViewController === viewer)
        var revoked = false
        let anchor = LockedContentPrivacyAnchor { [unowned self] in
            revoked = true
            XCTAssertNotNil(cover, "The cover must exist before access is revoked")
            XCTAssertTrue(viewer.view.isHidden)
        }
        root.view.addSubview(anchor)

        NotificationCenter.default.post(name: UIScene.willDeactivateNotification, object: window.windowScene)

        XCTAssertTrue(revoked)
        let shield = try XCTUnwrap(cover)
        XCTAssertTrue(shield.isOpaque)
        XCTAssertEqual(shield.frame, window.bounds)
        XCTAssertTrue(window.subviews.last === shield)
        anchor.removeFromSuperview()
        XCTAssertNotNil(cover, "SwiftUI removing the private subtree must not remove the shield early")

        NotificationCenter.default.post(name: UIScene.didActivateNotification, object: window.windowScene)
        try await waitUntil { self.cover == nil && self.root.presentedViewController == nil }
    }

    func testCurrentPrivateViewerRemainsUsableWhileSceneIsActive() {
        let viewer = UIViewController()
        root.present(viewer, animated: false)
        var revocations = 0
        root.view.addSubview(LockedContentPrivacyAnchor { revocations += 1 })

        XCTAssertTrue(root.presentedViewController === viewer)
        XCTAssertFalse(viewer.view.isHidden)
        XCTAssertNil(cover)
        XCTAssertEqual(revocations, 0)
    }

    func testActivationDoesNotDismissANewPINPrompt() async throws {
        var revoked = false
        let anchor = LockedContentPrivacyAnchor { revoked = true }
        root.view.addSubview(anchor)
        NotificationCenter.default.post(name: UIScene.willDeactivateNotification, object: window.windowScene)
        XCTAssertTrue(revoked)
        XCTAssertNotNil(cover)
        anchor.removeFromSuperview()

        let newPrompt = UIViewController()
        root.present(newPrompt, animated: false)
        XCTAssertTrue(root.presentedViewController === newPrompt)
        NotificationCenter.default.post(name: UIScene.didActivateNotification, object: window.windowScene)
        try await waitUntil { self.cover == nil }

        XCTAssertTrue(root.presentedViewController === newPrompt)
        XCTAssertFalse(newPrompt.view.isHidden)
    }

    func testRemovedGuardCannotCoverAnOrdinaryScreen() {
        var revocations = 0
        let anchor = LockedContentPrivacyAnchor { revocations += 1 }
        root.view.addSubview(anchor)
        anchor.removeFromSuperview()

        NotificationCenter.default.post(name: UIScene.willDeactivateNotification, object: window.windowScene)

        XCTAssertNil(cover)
        XCTAssertEqual(revocations, 0)
    }

    func testCoverWaitsForPrivateSubtreeRemovalAfterActivation() async throws {
        var revoked = false
        let anchor = LockedContentPrivacyAnchor { revoked = true }
        root.view.addSubview(anchor)
        NotificationCenter.default.post(name: UIScene.willDeactivateNotification, object: window.windowScene)
        XCTAssertTrue(revoked)

        NotificationCenter.default.post(name: UIScene.didActivateNotification, object: window.windowScene)
        let mainQueueUpdated = expectation(description: "Previously queued UI updates have run")
        DispatchQueue.main.async { mainQueueUpdated.fulfill() }
        await fulfillment(of: [mainQueueUpdated], timeout: 2)
        XCTAssertNotNil(cover, "An active scene must stay covered while private views remain attached")

        anchor.removeFromSuperview()
        try await waitUntil { self.cover == nil }
    }

    private var cover: UIView? {
        window.subviews.first { $0.accessibilityIdentifier == "lockedContentPrivacyCover" }
    }

    private func waitUntil(_ condition: @MainActor () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(2)
        while !condition(), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(condition(), "Private presentations must be dismissed before the cover is removed")
    }
}
