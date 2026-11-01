import Observation
import SwiftUI
import UIKit
import XCTest
@testable import ImmichApp

@MainActor
final class DuplicateKeeperPresentationTests: SimulatorHostedTestCase {
    func testRemovingTheOnlyKeeperSelectsACurrentFallbackAndPresentsItsUpdatedConfirmation() async throws {
        let fixture = DuplicateKeeperFixture()
        let window = try await host(DuplicateKeeperHarness(fixture: fixture), style: .dark)
        try await waitForChoice("First.jpg", value: "Keep", in: window)

        fixture.group = DuplicateGroupDTO(duplicateId: fixture.group.id, assets: Array(fixture.photos.dropFirst()),
            suggestedKeepAssetIds: [fixture.photos[1].id])

        try await waitForChoice("Second.jpg", value: "Keep", in: window)
        try await activateAccessibilityButton(named: "Second.jpg", in: window)
        try await waitForChoice("Second.jpg", value: "Keep", in: window)
        try await activateAccessibilityButton(named: "Trash 1", in: window)
        try await assertCurrentResolutionConfirmation(in: window)
        XCTAssertNil(fixture.resolved, "The last visible keeper stays selected while resolution awaits confirmation")
    }

    func testMembershipUpdatesPreserveTheUsersRemainingKeeperBeforeConfirmation() async throws {
        let fixture = DuplicateKeeperFixture()
        let window = try await host(DuplicateKeeperHarness(fixture: fixture))
        try await waitForChoice("First.jpg", value: "Keep", in: window)
        try await activateAccessibilityButton(named: "Third.jpg", in: window)
        try await waitForChoice("Third.jpg", value: "Keep", in: window)

        fixture.group = DuplicateGroupDTO(duplicateId: fixture.group.id, assets: Array(fixture.photos.dropFirst()),
            suggestedKeepAssetIds: [fixture.photos[1].id])

        try await waitUntil("The rendered group removes its former first member and shows its current membership") {
            var visited = Set<ObjectIdentifier>()
            return self.choice(named: "First.jpg", in: window, visited: &visited) == nil
                && self.searchContainsText("2 items · tap to keep or trash", in: window)
        }
        _ = try await screenshot(window)
        try await waitForChoice("Third.jpg", value: "Keep", in: window)
        try await waitForChoice("Second.jpg", value: "Move to Trash", in: window)
        try await activateAccessibilityButton(named: "Trash 1", in: window)
        try await assertCurrentResolutionConfirmation(in: window)
        XCTAssertNil(fixture.resolved, "Changing membership cannot resolve the group before confirmation")
    }

    func testMembershipChangeDismissesAStaleDestructiveConfirmation() async throws {
        let fixture = DuplicateKeeperFixture()
        let window = try await host(DuplicateKeeperHarness(fixture: fixture))
        try await waitForChoice("First.jpg", value: "Keep", in: window)
        try await activateAccessibilityButton(named: "Trash 2", in: window)
        try await waitUntil("The original confirmation is presented") {
            self.presentedAlert(from: window.rootViewController) != nil
        }

        fixture.group = DuplicateGroupDTO(duplicateId: fixture.group.id, assets: Array(fixture.photos.dropFirst()),
            suggestedKeepAssetIds: [fixture.photos[1].id])

        try await waitUntil("Changed membership requires the user to review a fresh confirmation") {
            self.presentedAlert(from: window.rootViewController) == nil
        }
        XCTAssertNil(fixture.resolved)
        try await waitForChoice("Second.jpg", value: "Keep", in: window)
    }

    private func assertCurrentResolutionConfirmation(in window: UIWindow) async throws {
        let alert = try await presentedNativeAlert(in: window)
        XCTAssertEqual(alert.title, "Move 1 item to Trash?")
        XCTAssertEqual(alert.message, "Selected items will be kept. You can restore the others from Trash.")
        let trash = try XCTUnwrap(alert.actions.first { $0.title == "Move to Trash" })
        XCTAssertEqual(trash.style, .destructive)
        XCTAssertTrue(trash.isEnabled)
        let cancel = try XCTUnwrap(alert.actions.first { $0.title == "Cancel" })
        XCTAssertEqual(cancel.style, .cancel)
        XCTAssertTrue(cancel.isEnabled)
    }

    private func waitForChoice(_ name: String, value: String, in window: UIWindow) async throws {
        try await waitUntil("The rendered \(name) choice is \(value)") {
            var visited = Set<ObjectIdentifier>()
            return self.choice(named: name, in: window, visited: &visited)?.accessibilityValue == value
        }
    }

    private func choice(named name: String, in object: NSObject,
                        visited: inout Set<ObjectIdentifier>) -> NSObject? {
        guard visited.insert(ObjectIdentifier(object)).inserted else { return nil }
        if let view = object as? UIView, view.isHidden || view.alpha <= 0 { return nil }
        if object.accessibilityLabel == name, object.accessibilityTraits.contains(.button) { return object }
        if let view = object as? UIView {
            for child in view.subviews {
                if let found = choice(named: name, in: child, visited: &visited) { return found }
            }
        }
        for case let child as NSObject in object.accessibilityElements ?? [] {
            if let found = choice(named: name, in: child, visited: &visited) { return found }
        }
        let count = object.accessibilityElementCount()
        if (1...500).contains(count) {
            for index in 0..<count {
                guard let child = object.accessibilityElement(at: index) as? NSObject else { continue }
                if let found = choice(named: name, in: child, visited: &visited) { return found }
            }
        }
        return nil
    }

    private func presentedAlert(from controller: UIViewController?) -> UIAlertController? {
        guard let controller else { return nil }
        if let alert = controller as? UIAlertController { return alert }
        if let presented = presentedAlert(from: controller.presentedViewController) { return presented }
        return controller.children.compactMap { presentedAlert(from: $0) }.first
    }
}

@MainActor
@Observable
private final class DuplicateKeeperFixture {
    let photos: [AssetResponseDTO]
    var group: DuplicateGroupDTO
    var resolved: Set<String>?

    init() {
        let photos = ["First.jpg", "Second.jpg", "Third.jpg"].map {
            makeTestAsset(id: UUID().uuidString, originalFileName: $0)
        }
        self.photos = photos
        group = DuplicateGroupDTO(duplicateId: UUID().uuidString, assets: photos,
            suggestedKeepAssetIds: [photos[0].id])
    }
}

private struct DuplicateKeeperHarness: View {
    let fixture: DuplicateKeeperFixture

    var body: some View {
        DuplicateGroupCard(group: fixture.group, isWorking: false,
            onResolve: { fixture.resolved = $0 }, onKeepAll: {})
            .padding()
    }
}
