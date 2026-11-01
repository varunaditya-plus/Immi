import SwiftUI
import UIKit
import Vision
import XCTest
@testable import ImmichApp

@MainActor
final class OnboardingLayoutTests: SimulatorHostedTestCase {
    private var savedServer: Any?

    override func setUp() async throws {
        try await super.setUp()
        savedServer = UserDefaults.standard.object(forKey: "onboarding.lastServer")
        UserDefaults.standard.set("https://photos.example.test", forKey: "onboarding.lastServer")
    }

    override func tearDown() async throws {
        UserDefaults.standard.set(savedServer, forKey: "onboarding.lastServer")
        try await super.tearDown()
    }

    func testServerAndSignInButtonsFitAccessibilityTextInBothAppearances() async throws {
        for style in [UIUserInterfaceStyle.light, .dark] {
            let session = MockSessionManager()
            session.shouldSucceedPing = true
            let window = try await host(OnboardingView().environment(session as SessionManager)
                .dynamicTypeSize(.accessibility5), style: style)
            window.frame.size = CGSize(width: 320, height: 568)
            window.rootViewController?.view.frame = window.bounds
            try await assertCompleteAction("Continue", in: window)
            try await activateAccessibilityButton(named: "Continue", in: window)
            try await waitUntil("Server validation presents the actual credentials page") {
                session.featuresCallCount == 1 && self.findAction("Sign In", in: window) != nil
            }
            XCTAssertEqual(session.pingCallCount, 1)
            XCTAssertEqual(session.versionCallCount, 1)
            XCTAssertEqual(session.featuresCallCount, 1)
            try await assertCompleteAction("Sign In", in: window)
            XCTAssertEqual(session.loginPasswordCallCount, 0)
            window.isHidden = true
        }
    }

    private func assertCompleteAction(_ title: String, in window: UIWindow) async throws {
        try await waitUntil("The onboarding navigation transition has settled") {
            self.navigationControllers(in: window.rootViewController).allSatisfy { $0.transitionCoordinator == nil }
        }
        var button: NSObject?
        try await waitUntil("The actual \(title) action is laid out") {
            button = self.findAction(title, in: self.activeContent(in: window))
            return button != nil
        }
        var action = try XCTUnwrap(button)
        let content = activeContent(in: window)
        let scroll = try XCTUnwrap(actionScrollView(for: action, in: content, window: window),
            "The current onboarding page must own a visible vertical scrolling viewport")
        for _ in 0..<12 {
            action = findAction(title, in: content) ?? action
            let frame = window.convert(action.accessibilityFrame, from: nil)
            let viewport = scroll.convert(scroll.bounds, to: window).intersection(window.bounds)
            if viewport.contains(frame) { break }
            scroll.scrollRectToVisible(scroll.convert(frame, from: window).insetBy(dx: 0, dy: -8), animated: false)
            window.layoutIfNeeded()
            try await Task.sleep(for: .milliseconds(20))
        }
        let image = try await screenshot(window)
        action = findAction(title, in: content) ?? action
        let frame = window.convert(action.accessibilityFrame, from: nil)
        let diagnostic = "\(title): action=\(type(of: action)) frame=\(frame), window=\(window.bounds), "
            + "scroll=\(scroll.convert(scroll.bounds, to: window)), content=\(scroll.contentSize), offset=\(scroll.contentOffset)"
        let font = UIFont.preferredFont(forTextStyle: .body,
            compatibleWith: UITraitCollection(preferredContentSizeCategory: .accessibilityExtraExtraExtraLarge))
        XCTAssertGreaterThanOrEqual(frame.height, font.lineHeight,
            "The action must grow with its font rather than clipping a fixed-height label")
        XCTAssertTrue(window.bounds.insetBy(dx: -1, dy: -1).contains(frame), diagnostic)
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        try VNImageRequestHandler(cgImage: XCTUnwrap(image.cgImage)).perform([request])
        let visible = (request.results ?? []).contains {
            $0.topCandidates(1).first?.string == title &&
            CGRect(x: $0.boundingBox.minX * window.bounds.width,
                   y: (1 - $0.boundingBox.maxY) * window.bounds.height,
                   width: $0.boundingBox.width * window.bounds.width,
                   height: $0.boundingBox.height * window.bounds.height).intersects(frame)
        }
        let recognized = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
        XCTAssertTrue(visible, "The complete rendered action title must be visible inside its button. \(diagnostic); OCR=\(recognized)")
    }

    private func activeContent(in window: UIWindow) -> UIView {
        navigationControllers(in: window.rootViewController).last?.visibleViewController?.view ?? window
    }

    private func navigationControllers(in controller: UIViewController?) -> [UINavigationController] {
        guard let controller else { return [] }
        return (controller as? UINavigationController).map { [$0] }
            ?? controller.children.flatMap { navigationControllers(in: $0) }
    }

    private func actionScrollView(for action: NSObject, in content: UIView, window: UIWindow) -> UIScrollView? {
        var container: Any? = action
        var visited = Set<ObjectIdentifier>()
        while let object = container as? NSObject, visited.insert(ObjectIdentifier(object)).inserted {
            if let view = object as? UIView {
                var ancestor: UIView? = view
                while let current = ancestor {
                    if let scroll = current as? UIScrollView, scroll.window === window { return scroll }
                    ancestor = current.superview
                }
                break
            }
            container = (object as? UIAccessibilityElement)?.accessibilityContainer
        }
        return descendants(content).compactMap { $0 as? UIScrollView }.first {
            $0.window === window && !$0.isHidden && $0.alpha > 0 && $0.bounds.width > window.bounds.width * 0.7
                && $0.convert($0.bounds, to: window).intersects(window.bounds)
        }
    }

    private func findAction(_ title: String, in object: NSObject, depth: Int = 0) -> NSObject? {
        guard depth < 35 else { return nil }
        if object.accessibilityLabel == title, object.accessibilityTraits.contains(.button) { return object }
        if let view = object as? UIView {
            for child in view.subviews {
                if let found = findAction(title, in: child, depth: depth + 1) { return found }
            }
        }
        if let elements = object.accessibilityElements {
            for case let child as NSObject in elements {
                if let found = findAction(title, in: child, depth: depth + 1) { return found }
            }
        }
        let count = object.accessibilityElementCount()
        if (1...500).contains(count) {
            for index in 0..<count {
                if let child = object.accessibilityElement(at: index) as? NSObject,
                   let found = findAction(title, in: child, depth: depth + 1) { return found }
            }
        }
        return nil
    }

    private func descendants(_ view: UIView) -> [UIView] {
        guard !view.isHidden, view.alpha > 0 else { return [] }
        return [view] + view.subviews.flatMap(descendants)
    }
}
