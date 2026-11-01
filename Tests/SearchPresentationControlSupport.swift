import UIKit
import XCTest
@testable import ImmichApp

@MainActor
extension SimulatorHostedTestCase {
    func activateSearchMenuAction(named title: String, in window: UIWindow, menuButton: String = "More") async throws {
        try await activateAccessibilityButton(named: menuButton, in: window)
        var source: (UIControl, UIAction, UIContextMenuInteraction)?
        try await waitUntil("The actual \(menuButton) menu contains its enabled \(title) action") {
            for view in self.searchPresentationViews(in: window) {
                for interaction in view.interactions.compactMap({ $0 as? UIContextMenuInteraction }) {
                    interaction.updateVisibleMenu { menu in
                        if let control = interaction.view as? UIControl,
                           let action = self.searchMenuAction(named: title, in: menu) {
                            source = (control, action, interaction)
                        }
                        return menu
                    }
                }
            }
            return source != nil
        }
        if source == nil { attachSearchPresentationState(window) }
        let (control, action, interaction) = try XCTUnwrap(source,
            "Menu tests must dispatch the actual production UIAction through its mounted control")
        XCTAssertTrue(control.isEnabled)
        XCTAssertFalse(action.attributes.contains(.disabled))
        interaction.dismissMenu()
        control.sendAction(action)
    }

    func activateNativeAlertAction(named title: String, in window: UIWindow) async throws {
        var presented: UIAlertController?
        try await waitUntil("The actual confirmation finishes presenting before its \(title) action") {
            presented = self.searchPresentedControllers(in: window.rootViewController).compactMap { $0 as? UIAlertController }.first
            return presented?.view.window === window && presented?.transitionCoordinator == nil && presented?.isBeingPresented == false
        }
        let alert = try XCTUnwrap(presented)
        let action = try XCTUnwrap(alert.actions.first { $0.title == title })
        XCTAssertTrue(action.isEnabled)
        if let button = searchPresentationViews(in: alert.view).compactMap({ $0 as? UIButton }).first(where: {
            $0.currentTitle == title || $0.configuration?.title == title || $0.accessibilityLabel == title
        }) {
            XCTAssertTrue(button.isEnabled)
            button.sendActions(for: .touchUpInside)
        } else {
            alert.preferredAction = action
            var returnCommand: UIKeyCommand?
            try await waitUntil("The native confirmation registers its public Return command") {
                returnCommand = alert.keyCommands?.first { $0.input == "\r" }
                return returnCommand != nil
            }
            if returnCommand == nil {
                let fields = (alert.textFields ?? []).map {
                    "firstResponder=\($0.isFirstResponder) hasText=\($0.hasText) delegate=\(String(describing: $0.delegate)) commands=\(($0.keyCommands ?? []).compactMap(\.input))"
                }
                let diagnostic = XCTAttachment(string: "keyWindow=\(alert.view.window?.isKeyWindow == true) enabled=\(action.isEnabled) fields=\(fields)")
                diagnostic.name = "Native confirmation input readiness"
                diagnostic.lifetime = .keepAlways
                add(diagnostic)
            }
            let command = try XCTUnwrap(returnCommand,
                "The native confirmation must expose its public Return command")
            XCTAssertTrue(UIApplication.shared.sendAction(try XCTUnwrap(command.action), to: alert, from: command, for: nil))
        }
        try await waitUntil("The native \(title) confirmation finishes dismissing") {
            !self.searchPresentedControllers(in: window.rootViewController).contains { $0 === alert }
        }
    }

    func deactivateNativeSearch(in controller: UIViewController?) {
        guard let controller else { return }
        controller.viewIfLoaded?.endEditing(true)
        controller.navigationItem.searchController?.isActive = false
        controller.navigationItem.searchController = nil
        if let search = controller as? UISearchController { search.isActive = false }
        for child in controller.children { deactivateNativeSearch(in: child) }
        deactivateNativeSearch(in: controller.presentedViewController)
    }

    func searchPresentedControllers(in controller: UIViewController?) -> [UIViewController] {
        guard let controller else { return [] }
        let presented = controller.presentedViewController.map { [$0] + searchPresentedControllers(in: $0) } ?? []
        return presented + controller.children.flatMap { searchPresentedControllers(in: $0) }
    }

    func attachSearchPresentationState(_ window: UIWindow) {
        let lines = searchPresentationViews(in: window).map { view in
            let interactions = view.interactions.map { String(describing: type(of: $0)) }.joined(separator: ",")
            return "\(type(of: view)) label=\(view.accessibilityLabel ?? "") frame=\(view.frame) interactions=\(interactions)"
        }
        let attachment = XCTAttachment(string: lines.joined(separator: "\n"))
        attachment.name = "Search public UIKit hierarchy"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func searchContainsText(_ text: String, in root: NSObject) -> Bool {
        var visited = Set<ObjectIdentifier>()
        func contains(_ object: NSObject, depth: Int) -> Bool {
            guard depth < 40, visited.insert(ObjectIdentifier(object)).inserted else { return false }
            if let view = object as? UIView, view.isHidden || view.alpha <= 0 { return false }
            if object.accessibilityLabel == text || (object as? UILabel)?.text == text { return true }
            if let view = object as? UIView, view.subviews.contains(where: { contains($0, depth: depth + 1) }) { return true }
            if let elements = object.accessibilityElements,
               elements.compactMap({ $0 as? NSObject }).contains(where: { contains($0, depth: depth + 1) }) { return true }
            let count = object.accessibilityElementCount()
            if (1...500).contains(count) {
                for index in 0..<count {
                    if let child = object.accessibilityElement(at: index) as? NSObject, contains(child, depth: depth + 1) { return true }
                }
            }
            return false
        }
        return contains(root, depth: 0)
    }

    private func searchMenuAction(named title: String, in menu: UIMenu) -> UIAction? {
        for child in menu.children {
            if let action = child as? UIAction, action.title == title,
               !action.attributes.contains(.disabled), !action.attributes.contains(.hidden) { return action }
            if let submenu = child as? UIMenu, let action = searchMenuAction(named: title, in: submenu) { return action }
        }
        return nil
    }

    private func searchPresentationViews(in view: UIView) -> [UIView] {
        guard !view.isHidden, view.alpha > 0 else { return [] }
        return [view] + view.subviews.flatMap { searchPresentationViews(in: $0) }
    }
}
