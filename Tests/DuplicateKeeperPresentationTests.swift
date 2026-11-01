import Observation
import SwiftUI
import UIKit
import XCTest
@testable import ImmichApp

@MainActor
final class DuplicateKeeperPresentationTests: SimulatorHostedTestCase {
    func testRemovingTheOnlyKeeperSelectsACurrentFallbackAndKeepsResolutionUsable() async throws {
        let fixture = DuplicateKeeperFixture()
        let window = try await host(DuplicateKeeperHarness(fixture: fixture), style: .dark)
        try await waitForChoice("First.jpg", value: "Keep", in: window)

        fixture.group = DuplicateGroupDTO(duplicateId: fixture.group.id, assets: Array(fixture.photos.dropFirst()),
            suggestedKeepAssetIds: [fixture.photos[1].id])

        try await waitForChoice("Second.jpg", value: "Keep", in: window)
        try await activateAccessibilityButton(named: "Second.jpg", in: window)
        try await waitForChoice("Second.jpg", value: "Keep", in: window)
        try await activateAccessibilityButton(named: "Trash 1", in: window)
        try await activateAccessibilityButton(named: "Move to Trash", in: window)
        XCTAssertEqual(fixture.resolved, [fixture.photos[1].id], "The last visible keeper must remain selected")
    }

    func testMembershipUpdatesPreserveTheUsersRemainingKeeper() async throws {
        let fixture = DuplicateKeeperFixture()
        let window = try await host(DuplicateKeeperHarness(fixture: fixture))
        try await waitForChoice("First.jpg", value: "Keep", in: window)
        try await activateAccessibilityButton(named: "Third.jpg", in: window)
        try await waitForChoice("Third.jpg", value: "Keep", in: window)

        fixture.group = DuplicateGroupDTO(duplicateId: fixture.group.id, assets: Array(fixture.photos.dropFirst()),
            suggestedKeepAssetIds: [fixture.photos[1].id])

        try await waitForChoice("Third.jpg", value: "Keep", in: window)
        try await waitForChoice("Second.jpg", value: "Move to Trash", in: window)
        try await activateAccessibilityButton(named: "Trash 1", in: window)
        try await activateAccessibilityButton(named: "Move to Trash", in: window)
        XCTAssertEqual(fixture.resolved, [fixture.photos[2].id])
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
