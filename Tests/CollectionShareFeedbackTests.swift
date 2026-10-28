import Observation
import SwiftUI
import UIKit
import XCTest
@testable import ImmichApp

@MainActor
final class CollectionShareFeedbackTests: XCTestCase {
    private var window: UIWindow?
    private weak var previousKeyWindow: UIWindow?
    private var observation: CollectionShareObservation!
    private var transport: URLSession?

    override func setUp() async throws {
        MockURLProtocol.reset()
        RemovedAssets.shared.clear()
        DeletedServerAssetRegistry.shared.clear()
        observation = CollectionShareObservation()
    }

    override func tearDown() async throws {
        if let root = window?.rootViewController, let presented = root.presentedViewController {
            await waitForTransition(presented)
            await withCheckedContinuation { continuation in
                root.dismiss(animated: false) { continuation.resume() }
            }
        }
        window?.isHidden = true
        window?.rootViewController = nil
        window = nil
        previousKeyWindow?.makeKey()
        previousKeyWindow = nil
        transport?.invalidateAndCancel()
        transport = nil
        TemporaryMediaStore.remove(observation.files)
        observation = nil
        MockURLProtocol.reset()
        RemovedAssets.shared.clear()
        DeletedServerAssetRegistry.shared.clear()
    }

    func testTheActualCollectionShareToolbarShowsFailureAndCanRetry() async throws {
        try showCollection(status: 503)
        try await selectThePhoto()
        try await activate("Share")

        let alert: UIAlertController = try await presentedController()
        XCTAssertEqual(alert.title, String(localized: "Action Failed"))
        XCTAssertEqual(alert.message, String(localized: "Failed to prepare share"))
        XCTAssertEqual(observation.preparations, 1)
        XCTAssertEqual(observation.requestedIDs, [[try XCTUnwrap(observation.assetID)]])
        XCTAssertTrue(observation.files.isEmpty)
        observation.error = nil
        await waitUntil("The error alert dismisses") { [self] in
            guard let root = window?.rootViewController else { return false }
            return self.findPresented(UIAlertController.self, from: root) == nil
        }
        stub(status: 200)
        try await activate("Share")

        let activity: UIActivityViewController = try await presentedController()
        XCTAssertNotNil(activity.presentingViewController ?? activity.parent?.presentingViewController)
        XCTAssertEqual(observation.preparations, 2)
        XCTAssertEqual(observation.files.count, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: try XCTUnwrap(observation.files.first).path))
        XCTAssertNil(observation.error)
    }

    func testARepeatedToolbarActionCannotReplaceFilesAlreadyHandedToAnActivity() async throws {
        try showCollection(status: 200)
        try await selectThePhoto()
        let item = try await toolbarItem("Share")
        let target = try XCTUnwrap(item.target)
        let action = try XCTUnwrap(item.action)
        XCTAssertTrue(UIApplication.shared.sendAction(action, to: target, from: item, for: nil))
        let _: UIActivityViewController = try await presentedController()
        let firstFile = try XCTUnwrap(observation.files.first)
        XCTAssertTrue(FileManager.default.fileExists(atPath: firstFile.path))
        let repeated = expectation(description: "A covered share action must not prepare a second file")
        repeated.isInverted = true
        observation.unexpectedPreparation = repeated

        // Exercise the original mounted action again before its sheet has
        // dismissed; it must still read the current presentation state.
        XCTAssertTrue(UIApplication.shared.sendAction(action, to: target, from: item, for: nil))
        await fulfillment(of: [repeated], timeout: 0.3)

        XCTAssertEqual(observation.preparations, 1)
        XCTAssertEqual(observation.files, [firstFile])
        XCTAssertTrue(FileManager.default.fileExists(atPath: firstFile.path),
            "Covering the collection must not delete a file still being read by its activity controller")
    }

    private func showCollection(status: Int) throws {
        let session = MockSessionManager()
        try session.setServer("https://collection-sharing.example")
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let transport = URLSession(configuration: configuration)
        self.transport = transport
        let api = APIClient(session: session, urlSession: transport)
        let model = AssetGridViewModel(assetRepo: AssetDetailRepository(api: api),
            albumRepo: AlbumRepository(api: api), loader: { [] })
        let observation = try XCTUnwrap(observation)
        let asset = AssetLite(id: UUID().uuidString, isVideo: false, ratio: 1,
            thumbhash: nil, createdAt: Date(timeIntervalSince1970: 1_700_000_000))
        observation.assetID = asset.id
        let screen = PhotoCollectionScreen(title: "Sharing", layout: .monthly, assets: [asset], phase: .loaded(()),
            actionError: Binding(get: { observation.error }, set: { observation.error = $0 }),
            onRetry: {}, onToggleFavorite: nil, onDelete: { _ in }, shareURLs: { ids in
                observation.preparations += 1
                observation.requestedIDs.append(ids)
                observation.unexpectedPreparation?.fulfill()
                let files = await model.shareURLs(for: ids)
                observation.files.append(contentsOf: files)
                return files
            })
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first(where: { $0.activationState == .foregroundActive }))
        previousKeyWindow = scene.windows.first(where: \.isKeyWindow)
        let host = UIHostingController(rootView: NavigationStack { screen }
            .environment(MockSessionManager() as SessionManager)
            .environment(\.horizontalSizeClass, .compact)
            .environment(\.locale, Locale(identifier: "en_US")))
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        window.rootViewController = host
        window.makeKeyAndVisible()
        host.view.frame = window.bounds
        host.view.layoutIfNeeded()
        self.window = window
        stub(status: status)
    }

    private func stub(status: Int) {
        let id = observation.assetID!
        let bytes = UIGraphicsImageRenderer(size: CGSize(width: 1, height: 1)).image { context in
            UIColor.systemBlue.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 1, height: 1))
        }.pngData()!
        MockURLProtocol.responseProvider = { request in
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertEqual(request.url?.path, "/api/assets/\(id)/original")
            return (status == 200 ? bytes : Data(#"{"message":"Original unavailable"}"#.utf8),
                HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil,
                    headerFields: ["Content-Type": "image/png", "Content-Disposition": "attachment; filename=\"sharing.png\""]), nil)
        }
    }

    private func selectThePhoto() async throws {
        try await activate("Select")
        try await activate("Select All")
    }

    private func toolbarItem(_ title: String) async throws -> UIBarButtonItem {
        await waitUntil("The \(title) toolbar action is available") { [self] in
            guard let root = window?.rootViewController else { return false }
            return self.barItems(root).contains { ($0.title == title || $0.accessibilityLabel == title) && $0.isEnabled }
        }
        let root = try XCTUnwrap(window?.rootViewController)
        return try XCTUnwrap(barItems(root).first { ($0.title == title || $0.accessibilityLabel == title) && $0.isEnabled },
            "Available items: \(barItems(root).map { ($0.title ?? "nil") + "/" + ($0.accessibilityLabel ?? "nil") })")
    }

    private func activate(_ title: String) async throws {
        let item = try await toolbarItem(title)
        let action = try XCTUnwrap(item.action)
        XCTAssertTrue(UIApplication.shared.sendAction(action, to: item.target, from: item, for: nil))
    }

    private func barItems(_ controller: UIViewController) -> [UIBarButtonItem] {
        let groups = controller.navigationItem.leadingItemGroups + controller.navigationItem.centerItemGroups
            + controller.navigationItem.trailingItemGroups
        let own = (controller.navigationItem.leftBarButtonItems ?? []) + (controller.navigationItem.rightBarButtonItems ?? [])
            + (controller.toolbarItems ?? []) + groups.flatMap(\.barButtonItems)
        return own + controller.children.flatMap { barItems($0) }
    }

    private func presentedController<T: UIViewController>() async throws -> T {
        await waitUntil("The \(T.self) presentation appears") { [self] in
            guard let root = window?.rootViewController else { return false }
            return self.findPresented(T.self, from: root) != nil
        }
        let result = try XCTUnwrap(findPresented(T.self, from: try XCTUnwrap(window?.rootViewController)))
        await waitForTransition(result)
        return result
    }

    private func findPresented<T: UIViewController>(_ type: T.Type, from controller: UIViewController) -> T? {
        if let result = controller as? T { return result }
        if let presented = controller.presentedViewController, let result = findPresented(type, from: presented) { return result }
        return controller.children.compactMap { findPresented(type, from: $0) }.first
    }

    private func waitUntil(_ description: String, _ condition: @escaping @MainActor () -> Bool) async {
        let expected = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            if Thread.isMainThread { return MainActor.assumeIsolated { condition() } }
            return DispatchQueue.main.sync { condition() }
        }, object: nil)
        expected.expectationDescription = description
        await fulfillment(of: [expected], timeout: 3)
    }

    private func waitForTransition(_ controller: UIViewController) async {
        guard let coordinator = controller.transitionCoordinator else { return }
        let completed = expectation(description: "The activity/dialog transition completed")
        coordinator.animate(alongsideTransition: nil) { _ in completed.fulfill() }
        await fulfillment(of: [completed], timeout: 3)
    }
}

@MainActor
@Observable
private final class CollectionShareObservation {
    var error: String?
    var assetID: String?
    var preparations = 0
    var requestedIDs: [[String]] = []
    var files: [URL] = []
    var unexpectedPreparation: XCTestExpectation?
}
