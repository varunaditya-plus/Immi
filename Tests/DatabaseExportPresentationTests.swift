import SwiftUI
import UIKit
import XCTest
@testable import ImmichApp

@MainActor
final class DatabaseExportPresentationTests: XCTestCase {
    private var window: UIWindow?
    private weak var previousKeyWindow: UIWindow?
    private var source: URL?
    private var sharedURL: URL?

    override func tearDown() async throws {
        if let root = window?.rootViewController, root.presentedViewController != nil {
            await dismissPresentations(from: root)
        }
        window?.isHidden = true
        window?.rootViewController = nil
        window = nil
        previousKeyWindow?.makeKey()
        previousKeyWindow = nil
        if let source { try? FileManager.default.removeItem(at: source) }
        if let sharedURL { TemporaryMediaStore.remove(sharedURL) }
        source = nil
        sharedURL = nil
        try await super.tearDown()
    }

    func testUIKitDismissalReleasesTheRenderedDatabaseExportBeforeParentRemoval() async throws {
        let sharing = DatabaseExportSharing()
        let session = MockSessionManager()
        try session.setServer("https://database-presentation.example")
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first(where: { $0.activationState == .foregroundActive }))
        previousKeyWindow = scene.windows.first(where: \.isKeyWindow)
        var parent: UIHostingController<DatabaseExportFixture>? = UIHostingController(
            rootView: DatabaseExportFixture(sharing: sharing))
        let testWindow = UIWindow(windowScene: scene)
        testWindow.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        testWindow.rootViewController = parent
        testWindow.makeKeyAndVisible()
        window = testWindow
        parent?.view.layoutIfNeeded()

        let bytes = Data("owned database export".utf8)
        let source = FileManager.default.temporaryDirectory
            .appendingPathComponent("database-presentation-\(UUID()).sqlite")
        self.source = source
        try bytes.write(to: source)
        let error = await sharing.prepare(session: session) { source }
        XCTAssertNil(error)
        let url = try XCTUnwrap(sharing.presentation?.url)
        sharedURL = url
        try await waitUntil("The native activity controller is presented") {
            guard let parent else { return false }
            return self.activityController(from: parent)?.viewIfLoaded?.window != nil
        }
        let activity = try XCTUnwrap(activityController(from: try XCTUnwrap(parent)))
        await waitForTransition(of: activity)
        XCTAssertNotNil(activity.presentingViewController ?? activity.parent?.presentingViewController)
        XCTAssertEqual(try Data(contentsOf: url), bytes,
            "Covering the export screen must preserve the database handed to UIKit")
        XCTAssertNotNil(sharing.presentation)
        XCTAssertFalse(FileManager.default.fileExists(atPath: source.path))

        // Dismiss the real UIKit presentation while its SwiftUI parent remains mounted.
        // Keep `sharing` and `activity` alive so owner/controller deallocation
        // cannot substitute for SwiftUI dismantling the representable.
        await dismissPresentations(from: try XCTUnwrap(parent))
        try await waitUntil("Dismissing the native activity releases the export before removing its parent") {
            sharing.presentation == nil && !FileManager.default.fileExists(atPath: url.path)
        }
        XCTAssertTrue(testWindow.rootViewController === parent)
        XCTAssertNil(activity.viewIfLoaded?.window)

        testWindow.isHidden = true
        testWindow.rootViewController = nil
        parent = nil
        XCTAssertNil(sharing.presentation)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    private func activityController(from controller: UIViewController) -> UIActivityViewController? {
        if let activity = controller as? UIActivityViewController { return activity }
        if let presented = controller.presentedViewController,
           let activity = activityController(from: presented) { return activity }
        return controller.children.compactMap { activityController(from: $0) }.first
    }

    private func dismissPresentations(from controller: UIViewController) async {
        if let presented = controller.presentedViewController { await waitForTransition(of: presented) }
        await withCheckedContinuation { continuation in
            controller.dismiss(animated: false) { continuation.resume() }
        }
    }

    private func waitForTransition(of controller: UIViewController) async {
        guard let transition = controller.transitionCoordinator else { return }
        let completed = expectation(description: "The UIKit presentation transition completed")
        transition.animate(alongsideTransition: nil) { _ in completed.fulfill() }
        await fulfillment(of: [completed], timeout: 3)
    }

    private func waitUntil(_ description: String, _ condition: @MainActor () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(3)
        while !condition(), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(condition(), description)
    }
}

@MainActor
private struct DatabaseExportFixture: View {
    let sharing: DatabaseExportSharing

    var body: some View {
        Text("Sync Status")
            .sheet(item: sharing.binding) { sharing.shareSheet(for: $0) }
            .onDisappear { sharing.cancelPreparation() }
    }
}
