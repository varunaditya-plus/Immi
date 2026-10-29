import MapKit
import SwiftUI
import UIKit
import XCTest
@testable import ImmichApp

@MainActor
final class AssetInfoPanelPresentationTests: XCTestCase {
    private var windows: [UIWindow] = []
    private weak var previousKeyWindow: UIWindow?
    private var snapshotIDs: [String] = []

    override func tearDown() async throws {
        for window in windows {
            window.isHidden = true
            window.rootViewController = nil
        }
        windows.removeAll()
        previousKeyWindow?.makeKey()
        previousKeyWindow = nil
        for id in snapshotIDs { LocalSnapshot.remove(LocalSnapshot.Key.assetDetail(id)) }
        snapshotIDs.removeAll()
    }

    func testOpenPanelFollowsCompactWindowRotationAndResizing() async throws {
        try await checkResize(sizeClass: .compact)
    }

    func testOpenPanelFollowsRegularWindowRotationAndResizing() async throws {
        try await checkResize(sizeClass: .regular)
    }

    func testDifferentViewerWindowsUseTheirOwnPanelDimensions() async throws {
        let first = try showViewer(size: CGSize(width: 390, height: 844), sizeClass: .compact)
        let firstPanel = try await openPanel(in: first)
        let second = try showViewer(size: CGSize(width: 600, height: 400), sizeClass: .regular)
        let secondPanel = try await openPanel(in: second)

        XCTAssertGreaterThan(firstPanel.bounds.height, secondPanel.bounds.height + 100)
        XCTAssertLessThanOrEqual(secondPanel.bounds.height, second.bounds.height * 0.75 + 1)
        XCTAssertGreaterThan(firstPanel.bounds.height, 0)
    }

    func testExpandedPanelRemainsScrollableWhenCaptionReflowsAfterResize() async throws {
        let caption = "A long description of this photograph and the people and places we remember from our journey together."
        let window = try showViewer(size: CGSize(width: 1000, height: 800), sizeClass: .regular,
            caption: caption)
        let panel = try await openPanel(in: window)
        try await Task.sleep(for: .milliseconds(500))
        let field = try XCTUnwrap(descendant(of: UITextView.self, in: window))
        XCTAssertTrue(field.becomeFirstResponder())
        try await waitUntil("The expanded panel scrolls") { panel.isScrollEnabled }
        let wideHeaderHeight = field.bounds.height
        resize(window, to: CGSize(width: 270, height: 800))
        try await waitUntil("The caption wraps in the narrower window") {
            field.bounds.height > wideHeaderHeight + 20
        }
        try await Task.sleep(for: .milliseconds(500))
        XCTAssertTrue(panel.isScrollEnabled, "A resized expanded panel must still allow scrolling and map interaction")
    }

    private func descendant<T: UIView>(of type: T.Type, in view: UIView) -> T? {
        if let match = view as? T { return match }
        return view.subviews.compactMap { descendant(of: type, in: $0) }.first
    }

    private func checkResize(sizeClass: UserInterfaceSizeClass) async throws {
        let window = try showViewer(size: CGSize(width: 390, height: 844), sizeClass: sizeClass)
        let panel = try await openPanel(in: window)
        let portraitHeight = panel.bounds.height
        XCTAssertGreaterThan(portraitHeight, 200)
        resize(window, to: CGSize(width: 844, height: 390))
        try await waitUntil("The open panel fits the resized viewer") {
            panel.bounds.height > 0 && panel.bounds.height <= 390 * 0.75 + 1
        }
        XCTAssertLessThan(panel.bounds.height, portraitHeight)
        let landscapeHeight = panel.bounds.height
        resize(window, to: CGSize(width: 500, height: 650))
        try await waitUntil("The medium detent follows a larger window") { panel.bounds.height > landscapeHeight + 30 }
        XCTAssertLessThanOrEqual(panel.bounds.height, 650 * 0.75 + 1)
    }

    private func showViewer(size: CGSize, sizeClass: UserInterfaceSizeClass, caption: String? = nil) throws -> UIWindow {
        let detail = makeTestAsset(id: UUID().uuidString, exifInfo: ExifDTO(make: nil, model: nil,
            exifImageWidth: nil, exifImageHeight: nil, orientation: nil, fileSizeInByte: nil,
            dateTimeOriginal: nil, latitude: 41.3874, longitude: 2.1686, city: nil, state: nil,
            country: nil, lensModel: nil, fNumber: nil, focalLength: nil, iso: nil,
            exposureTime: nil, description: caption))
        snapshotIDs.append(detail.id)
        LocalSnapshot.save(detail, for: LocalSnapshot.Key.assetDetail(detail.id))
        let session = MockSessionManager()
        let model = AssetDetailViewModel(repo: PanelDetailRepository(detail: detail, session: session))
        let asset = AssetLite(detail)
        let viewer = AssetDetailView(currentAsset: asset, assets: [asset], isModal: true, viewModel: model)
        let host = UIHostingController(rootView: NavigationStack { viewer }
            .environment(session as SessionManager)
            .environment(\.horizontalSizeClass, sizeClass)
            .environment(\.locale, Locale(identifier: "en_US")))
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first(where: { $0.activationState == .foregroundActive }))
        if windows.isEmpty { previousKeyWindow = scene.windows.first(where: \.isKeyWindow) }
        let window = UIWindow(windowScene: scene)
        window.rootViewController = host
        resize(window, to: size)
        window.makeKeyAndVisible()
        host.view.layoutIfNeeded()
        windows.append(window)
        return window
    }

    private func resize(_ window: UIWindow, to size: CGSize) {
        window.frame = CGRect(origin: .zero, size: size)
        window.rootViewController?.view.frame = window.bounds
        window.rootViewController?.view.setNeedsLayout()
        window.rootViewController?.view.layoutIfNeeded()
    }

    private func openPanel(in window: UIWindow) async throws -> UIScrollView {
        let root = try XCTUnwrap(window.rootViewController)
        try await waitUntil("The viewer's Info action is available") {
            self.barItems(in: root).contains { ($0.title == "Info" || $0.accessibilityLabel == "Info") && $0.isEnabled }
        }
        let item = try XCTUnwrap(barItems(in: root).first { ($0.title == "Info" || $0.accessibilityLabel == "Info") && $0.isEnabled })
        let action = try XCTUnwrap(item.action)
        XCTAssertTrue(UIApplication.shared.sendAction(action, to: item.target, from: item, for: nil))
        try await waitUntil("The info panel opens") {
            self.panelScroll(in: window).map { $0.bounds.height > 0 } ?? false
        }
        return try XCTUnwrap(panelScroll(in: window))
    }

    private func barItems(in controller: UIViewController) -> [UIBarButtonItem] {
        let item = controller.navigationItem
        let groups = item.leadingItemGroups + item.centerItemGroups + item.trailingItemGroups
        return (item.leftBarButtonItems ?? []) + (item.rightBarButtonItems ?? [])
            + (controller.toolbarItems ?? []) + groups.flatMap(\.barButtonItems)
            + controller.children.flatMap { barItems(in: $0) }
    }

    private func panelScroll(in view: UIView) -> UIScrollView? {
        if let map = view as? MKMapView {
            var ancestor = map.superview
            while let current = ancestor {
                if let scroll = current as? UIScrollView { return scroll }
                ancestor = current.superview
            }
        }
        return view.subviews.compactMap { panelScroll(in: $0) }.first
    }

    private func waitUntil(_ message: String, _ condition: @MainActor () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(3)
        while !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(condition(), message)
    }
}

@MainActor
private final class PanelDetailRepository: AssetDetailRepository {
    let detail: AssetResponseDTO

    init(detail: AssetResponseDTO, session: SessionManager) {
        self.detail = detail
        super.init(api: APIClient(session: session))
    }

    override func fetchAsset(_ id: String) async throws -> AssetResponseDTO {
        XCTAssertEqual(id, detail.id)
        return detail
    }
}
