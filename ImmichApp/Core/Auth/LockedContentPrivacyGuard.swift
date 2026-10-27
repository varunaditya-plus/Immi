import SwiftUI
import UIKit

/// Covers UIKit presentations before the scene snapshot, while SwiftUI removes
/// the unlocked folder and its viewer. The cover outlives that subtree until
/// the scene is active and its private presentations have been dismissed.
struct LockedContentPrivacyGuard: UIViewRepresentable {
    var onDeactivate: @MainActor @Sendable () -> Void

    func makeUIView(context: Context) -> LockedContentPrivacyAnchor {
        LockedContentPrivacyAnchor { onDeactivate() }
    }

    func updateUIView(_ view: LockedContentPrivacyAnchor, context: Context) {
        view.onDeactivate = { onDeactivate() }
    }

    static func dismantleUIView(_ view: LockedContentPrivacyAnchor, coordinator: ()) {
        view.stopObserving()
    }
}

@MainActor
final class LockedContentPrivacyAnchor: UIView {
    var onDeactivate: @MainActor @Sendable () -> Void
    private var observer: NSObjectProtocol?
    private weak var privacyCover: LockedContentPrivacyCover?

    init(onDeactivate: @escaping @MainActor @Sendable () -> Void) {
        self.onDeactivate = onDeactivate
        super.init(frame: .zero)
        isUserInteractionEnabled = false
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        stopObserving()
        guard let window else {
            privacyCover?.privateSubtreeDidDisappear()
            return
        }
        let notification = window.windowScene == nil
            ? UIApplication.willResignActiveNotification : UIScene.willDeactivateNotification
        observer = NotificationCenter.default.addObserver(
            forName: notification, object: window.windowScene, queue: .main
        ) { [weak self, weak window] _ in
            MainActor.assumeIsolated {
                guard let self, let window else { return }
                self.privacyCover = LockedContentPrivacyCover.install(in: window, anchor: self)
                self.onDeactivate()
            }
        }
    }

    func stopObserving() {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
    }

    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }
}

@MainActor
private final class LockedContentPrivacyCover: UIView {
    private var observer: NSObjectProtocol?
    private weak var privatePresentation: UIViewController?
    private weak var privateAnchor: LockedContentPrivacyAnchor?
    private var isSceneActive = false
    private var hasDismissedPresentation = false

    static func install(in window: UIWindow, anchor: LockedContentPrivacyAnchor) -> LockedContentPrivacyCover {
        if let existing = window.subviews.compactMap({ $0 as? LockedContentPrivacyCover }).first {
            existing.isSceneActive = false
            return existing
        }
        let cover = LockedContentPrivacyCover(frame: window.bounds)
        cover.privateAnchor = anchor
        cover.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        cover.backgroundColor = .systemBackground
        cover.isOpaque = true
        cover.accessibilityIdentifier = "lockedContentPrivacyCover"
        cover.isAccessibilityElement = true
        cover.accessibilityLabel = String(localized: "Locked")
        cover.privatePresentation = presenter(in: window.rootViewController)?.presentedViewController
        window.addSubview(cover)
        let notification = window.windowScene == nil
            ? UIApplication.didBecomeActiveNotification : UIScene.didActivateNotification
        cover.observer = NotificationCenter.default.addObserver(
            forName: notification, object: window.windowScene, queue: .main
        ) { [weak cover] _ in
            MainActor.assumeIsolated { cover?.dismissPrivateContent() }
        }
        // Hide the presented viewer as well as covering it. Dismissal may have
        // to wait for an interactive zoom or presentation transition to finish.
        cover.privatePresentation?.view.isHidden = true
        return cover
    }

    private func dismissPrivateContent() {
        isSceneActive = true
        // Capture the old viewer once. A new PIN prompt may already have been
        // presented on activation and must not be dismissed as private content.
        guard let content = privatePresentation, content.presentingViewController != nil else {
            hasDismissedPresentation = true
            removeIfReady()
            return
        }
        if let transition = content.transitionCoordinator {
            let scheduled = transition.animate(alongsideTransition: nil) { [weak self] _ in
                self?.dismissPrivateContent()
            }
            if scheduled { return }
        }
        content.dismiss(animated: false) { [weak self] in
            self?.hasDismissedPresentation = true
            self?.removeIfReady()
        }
    }

    func privateSubtreeDidDisappear() {
        removeIfReady()
    }

    private func removeIfReady() {
        guard isSceneActive, hasDismissedPresentation, privateAnchor?.window == nil else { return }
        removeFromSuperview()
    }

    private static func presenter(in controller: UIViewController?) -> UIViewController? {
        guard let controller else { return nil }
        if controller.presentedViewController != nil { return controller }
        for child in controller.children {
            if let presenter = presenter(in: child) { return presenter }
        }
        return nil
    }

    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }
}
