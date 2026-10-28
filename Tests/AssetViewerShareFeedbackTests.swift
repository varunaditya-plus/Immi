import SwiftUI
import UIKit
import Vision
import XCTest
@testable import ImmichApp

@MainActor
final class AssetViewerShareFeedbackTests: XCTestCase {
    private var window: UIWindow?
    private weak var previousKeyWindow: UIWindow?
    private var transport: URLSession?
    private var files: [URL] = []

    override func setUp() async throws {
        MockURLProtocol.reset()
        RemovedAssets.shared.clear()
        DeletedServerAssetRegistry.shared.clear()
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
        TemporaryMediaStore.remove(files)
        files.removeAll()
        MockURLProtocol.reset()
        RemovedAssets.shared.clear()
        DeletedServerAssetRegistry.shared.clear()
    }

    func testRepeatedMountedShareActionKeepsTheActivitysOriginalFile() async throws {
        let asset = photo(UUID().uuidString)
        let response = ViewerShareHTTP(assetID: asset.id)
        _ = try showViewer(asset, response: response)
        let item = try await shareToolbarItem()
        let target = try XCTUnwrap(item.target)
        let action = try XCTUnwrap(item.action)
        XCTAssertTrue(UIApplication.shared.sendAction(action, to: target, from: item, for: nil))
        let activity = try await presentedActivity()
        XCTAssertNotNil(activity.presentingViewController ?? activity.parent?.presentingViewController)
        let prepared = try preparedFiles(named: response.filename)
        files.append(contentsOf: prepared)
        XCTAssertEqual(prepared.count, 1)
        let firstFile = try XCTUnwrap(prepared.first)
        XCTAssertEqual(try Data(contentsOf: firstFile), response.bytes)
        XCTAssertEqual(response.downloadCount, 1)

        let repeated = expectation(description: "A mounted Share action cannot download again while its activity owns the file")
        repeated.isInverted = true
        response.rejectAdditionalDownloads(with: repeated)
        XCTAssertTrue(UIApplication.shared.sendAction(action, to: target, from: item, for: nil))
        await fulfillment(of: [repeated], timeout: 0.3)

        files.append(contentsOf: try preparedFiles(named: response.filename))
        XCTAssertEqual(response.downloadCount, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: firstFile.path),
            "The displayed activity must retain its file until completion or dismissal")
        XCTAssertTrue(findActivity(from: try XCTUnwrap(window?.rootViewController)) === activity)
    }

    func testFailedServerShareShowsAToastAndCanRetrySuccessfully() async throws {
        let asset = photo(UUID().uuidString)
        let response = ViewerShareHTTP(assetID: asset.id, status: 503)
        let model = try showViewer(asset, response: response)
        try await activateShare()
        await waitUntil("The failed original download reports a Share failure") { model.actionError != nil }
        XCTAssertEqual(model.actionError?.message, "Original unavailable")
        let text = try await visibleText()
        XCTAssertTrue(text.contains("Original unavailable"), text)
        XCTAssertEqual(response.downloadCount, 1)
        XCTAssertNil(findActivity(from: try XCTUnwrap(window?.rootViewController)))

        response.setStatus(200)
        try await activateShare()
        _ = try await presentedActivity()
        let prepared = try preparedFiles(named: response.filename)
        files.append(contentsOf: prepared)
        XCTAssertEqual(prepared.count, 1)
        XCTAssertEqual(try Data(contentsOf: try XCTUnwrap(prepared.first)), response.bytes)
        XCTAssertEqual(response.downloadCount, 2)
        XCTAssertNil(model.actionError)
    }

    private func showViewer(_ asset: AssetLite, response: ViewerShareHTTP) throws -> AssetDetailViewModel {
        let session = MockSessionManager()
        try session.setServer("https://viewer-sharing.example")
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let transport = URLSession(configuration: configuration)
        self.transport = transport
        let api = APIClient(session: session, urlSession: transport)
        let model = AssetDetailViewModel(repo: AssetDetailRepository(api: api))
        MockURLProtocol.responseProvider = { response.respond(to: $0) }
        let viewer = AssetDetailView(currentAsset: asset, assets: [asset], isModal: true, viewModel: model)
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first(where: { $0.activationState == .foregroundActive }))
        previousKeyWindow = scene.windows.first(where: \.isKeyWindow)
        let host = UIHostingController(rootView: NavigationStack { viewer }
            .environment(session as SessionManager)
            .environment(\.horizontalSizeClass, .compact)
            .environment(\.locale, Locale(identifier: "en_US"))
            .environment(\.colorScheme, .light))
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        window.rootViewController = host
        window.makeKeyAndVisible()
        host.view.frame = window.bounds
        host.view.layoutIfNeeded()
        self.window = window
        return model
    }

    private func photo(_ id: String) -> AssetLite {
        AssetLite(id: id, isVideo: false, ratio: 1, thumbhash: nil,
            createdAt: Date(timeIntervalSince1970: 1_700_000_000))
    }

    private func preparedFiles(named filename: String) throws -> [URL] {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("selfphotos-share", isDirectory: true)
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasSuffix("-" + filename) }
    }

    private func shareToolbarItem() async throws -> UIBarButtonItem {
        await waitUntil("The visible Share toolbar action is enabled") { [self] in
            guard let root = window?.rootViewController else { return false }
            return self.barItems(root).contains { ($0.title == "Share" || $0.accessibilityLabel == "Share") && $0.isEnabled }
        }
        let items = barItems(try XCTUnwrap(window?.rootViewController))
        return try XCTUnwrap(items.first { ($0.title == "Share" || $0.accessibilityLabel == "Share") && $0.isEnabled },
            "Available items: \(items.map { ($0.title ?? "nil") + "/" + ($0.accessibilityLabel ?? "nil") })")
    }

    private func activateShare() async throws {
        let item = try await shareToolbarItem()
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

    private func presentedActivity() async throws -> UIActivityViewController {
        await waitUntil("The Share activity appears") { [self] in
            guard let root = window?.rootViewController else { return false }
            return self.findActivity(from: root) != nil
        }
        let activity = try XCTUnwrap(findActivity(from: try XCTUnwrap(window?.rootViewController)))
        await waitForTransition(activity)
        return activity
    }

    private func findActivity(from controller: UIViewController) -> UIActivityViewController? {
        if let result = controller as? UIActivityViewController { return result }
        if let presented = controller.presentedViewController, let result = findActivity(from: presented) { return result }
        return controller.children.compactMap { findActivity(from: $0) }.first
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
        let completed = expectation(description: "The activity transition completed")
        coordinator.animate(alongsideTransition: nil) { _ in completed.fulfill() }
        await fulfillment(of: [completed], timeout: 3)
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

private final class ViewerShareHTTP {
    let filename = "viewer-share-\(UUID().uuidString).png"
    let bytes: Data
    private let assetID: String
    private let lock = NSLock()
    private var downloads = 0
    private var status: Int
    private var unexpectedDownload: XCTestExpectation?

    @MainActor
    init(assetID: String, status: Int = 200) {
        self.assetID = assetID
        self.status = status
        bytes = UIGraphicsImageRenderer(size: CGSize(width: 1, height: 1)).image { context in
            UIColor.systemBlue.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 1, height: 1))
        }.pngData()!
    }

    var downloadCount: Int { lock.withLock { downloads } }

    func setStatus(_ value: Int) {
        lock.withLock { status = value }
    }

    func rejectAdditionalDownloads(with expectation: XCTestExpectation) {
        lock.withLock { unexpectedDownload = expectation }
    }

    func respond(to request: URLRequest) -> (Data?, URLResponse?, Error?) {
        XCTAssertEqual(request.httpMethod, "GET")
        let isOriginal = request.url?.path == "/api/assets/\(assetID)/original"
        if isOriginal {
            let unexpected = lock.withLock {
                downloads += 1
                return unexpectedDownload
            }
            unexpected?.fulfill()
        } else {
            XCTAssertEqual(request.url?.path, "/api/assets/\(assetID)")
        }
        let responseStatus = isOriginal ? lock.withLock { status } : 503
        let isMedia = isOriginal && responseStatus == 200
        let message = isOriginal ? "Original unavailable" : "Metadata unavailable"
        let data = isMedia ? bytes : Data("{\"message\":\"\(message)\"}".utf8)
        return (data, HTTPURLResponse(url: request.url!, statusCode: responseStatus,
            httpVersion: nil, headerFields: ["Content-Type": isMedia ? "image/png" : "application/json",
                "Content-Disposition": "attachment; filename=\"\(filename)\""]), nil)
    }
}
