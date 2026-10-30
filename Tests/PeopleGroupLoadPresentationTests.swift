import Observation
import SwiftUI
import UIKit
import XCTest
@testable import ImmichApp

@MainActor
final class PeopleGroupLoadPresentationTests: SimulatorHostedTestCase {
    private var driver: GroupPhotoLoadDriver?

    override func tearDown() async throws {
        driver?.finishAll()
        try await super.tearDown()
        try await waitUntil("Every held group-photo request finishes before the next test") {
            self.driver?.activeCount == 0
        }
        driver = nil
    }

    func testLatestKeyPhotoRetryKeepsItsCandidatesWhenAnOlderRetryFinishes() async throws {
        let driver = GroupPhotoLoadDriver()
        self.driver = driver
        let window = try await host(GroupPhotoPickerTestHost(driver: driver))
        try await waitUntil("The failed initial request exposes the actual Retry button") {
            self.button(named: "Retry", in: window) != nil
        }
        let retry = try XCTUnwrap(button(named: "Retry", in: window))

        try activate(retry)
        try activate(retry)
        try await waitUntil("Both real Retry actions begin requests for the same group") { driver.requests.count == 3 }
        XCTAssertEqual(driver.requests, Array(repeating: ["a", "b"], count: 3))
        let current = photo("current-retry", day: 2), obsolete = photo("obsolete-retry", day: 1)
        driver.finish(3, with: .success([current]))
        try await waitUntil("The newest request supplies the visible key-photo candidate") {
            self.button(named: self.photoLabel(current), in: window) != nil
        }

        driver.finish(2, with: .success([obsolete]))

        try await waitUntil("The older source actually returns after the current candidate is visible") {
            driver.completed.contains(2)
        }
        _ = try await screenshot(window)
        XCTAssertNotNil(button(named: photoLabel(current), in: window))
        XCTAssertNil(button(named: photoLabel(obsolete), in: window), "A stale Retry must not replace newer candidates")
        try await activateAccessibilityButton(named: photoLabel(current), in: window)
        try await activateAccessibilityButton(named: "Done", in: window)
        try await waitUntil("Done saves the selected candidate through the actual picker") { driver.savedIDs == [current.id] }
    }

    func testChangedGroupKeepsItsCandidatesWhenAnOlderRetryFails() async throws {
        let driver = GroupPhotoLoadDriver()
        self.driver = driver
        let window = try await host(GroupPhotoPickerTestHost(driver: driver))
        try await activateAccessibilityButton(named: "Retry", in: window)
        try await waitUntil("The original group's Retry is held in flight") { driver.requests.count == 2 }

        driver.personIDs = ["a", "c"]
        try await waitUntil("Changing group members starts a replacement request") { driver.requests.count == 3 }
        XCTAssertEqual(driver.requests, [["a", "b"], ["a", "b"], ["a", "c"]])
        let current = photo("changed-group", day: 3)
        driver.finish(3, with: .success([current]))
        try await waitUntil("The new group's actual key-photo button appears") {
            self.button(named: self.photoLabel(current), in: window) != nil
        }

        driver.finish(2, with: .failure(URLError(.badServerResponse)))

        try await waitUntil("The obsolete Retry error reaches the picker after the replacement succeeds") {
            driver.completed.contains(2)
        }
        _ = try await screenshot(window)
        XCTAssertNotNil(button(named: photoLabel(current), in: window))
        XCTAssertNil(button(named: "Retry", in: window), "A previous group's error must not hide the new group's photos")
        try await activateAccessibilityButton(named: photoLabel(current), in: window)
        try await activateAccessibilityButton(named: "Done", in: window)
        try await waitUntil("Only a candidate from the current members is saved") { driver.savedIDs == [current.id] }
    }

    private func photo(_ id: String, day: Int) -> AssetLite {
        AssetLite(id: id, isVideo: false, ratio: 1, thumbhash: nil,
            createdAt: Date(timeIntervalSince1970: 1_793_188_800 + Double(day * 86_400)))
    }

    private func photoLabel(_ asset: AssetLite) -> String {
        asset.createdAt.formatted(.dateTime.year().month().day().locale(Locale(identifier: "en_US")))
    }

    private func button(named title: String, in root: NSObject) -> NSObject? {
        var visited = Set<ObjectIdentifier>()
        func find(_ object: NSObject, depth: Int) -> NSObject? {
            guard depth < 40, visited.insert(ObjectIdentifier(object)).inserted else { return nil }
            if let view = object as? UIView, view.isHidden || view.alpha <= 0 { return nil }
            if let control = object as? UIControl, !control.isEnabled { return nil }
            if object.accessibilityLabel == title, object.accessibilityTraits.contains(.button),
               !object.accessibilityTraits.contains(.notEnabled) { return object }
            if let view = object as? UIView {
                for child in view.subviews { if let result = find(child, depth: depth + 1) { return result } }
            }
            if let elements = object.accessibilityElements {
                for case let child as NSObject in elements {
                    if let result = find(child, depth: depth + 1) { return result }
                }
            }
            let count = object.accessibilityElementCount()
            if (1...500).contains(count) {
                for index in 0..<count {
                    if let child = object.accessibilityElement(at: index) as? NSObject,
                       let result = find(child, depth: depth + 1) { return result }
                }
            }
            return nil
        }
        return find(root, depth: 0)
    }

    private func activate(_ button: NSObject) throws {
        if let control = button as? UIControl { control.performPrimaryAction() }
        else {
            let activated = button.accessibilityActivate()
            XCTAssertTrue(activated, "The actual Retry button must activate")
            guard activated else { throw URLError(.unsupportedURL) }
        }
    }
}

@MainActor
@Observable
private final class GroupPhotoLoadDriver {
    var personIDs = ["a", "b"]
    var savedIDs: [String] = []
    private(set) var requests: [[String]] = []
    private(set) var completed: Set<Int> = []
    @ObservationIgnored private var pending: [Int: CheckedContinuation<[AssetLite], Error>] = [:]
    var activeCount: Int { requests.count - completed.count }

    func load(_ personIDs: [String]) async throws -> [AssetLite] {
        requests.append(personIDs)
        let request = requests.count
        defer { completed.insert(request) }
        if request == 1 { throw URLError(.notConnectedToInternet) }
        return try await withCheckedThrowingContinuation { pending[request] = $0 }
    }

    func finish(_ request: Int, with result: Result<[AssetLite], Error>) {
        guard let continuation = pending.removeValue(forKey: request) else {
            XCTFail("The held group-photo request \(request) must exist before it completes")
            return
        }
        continuation.resume(with: result)
    }

    func finishAll() {
        for request in Array(pending.keys) { finish(request, with: .failure(CancellationError())) }
    }
}

private struct GroupPhotoPickerTestHost: View {
    let driver: GroupPhotoLoadDriver

    var body: some View {
        PeopleGroupKeyPhotoPicker(personIDs: driver.personIDs, selectedID: nil,
            assetLoader: { try await driver.load($0) }) { id in
            driver.savedIDs.append(id)
            return nil
        }
    }
}
