import Observation
import SwiftUI
import UIKit
import XCTest
@testable import ImmichApp

@MainActor
final class NewAlbumPresentationTests: SimulatorHostedTestCase {
    func testNarrowLargeTextAlbumCreationSelectsPhotosAndCreatesInBothAppearances() async throws {
        for style in [UIUserInterfaceStyle.light, .dark] {
            let fixture = NewAlbumFixture()
            let photo = makeTestAsset(id: UUID().uuidString)
            let repo = NewAlbumPhotoRepository(api: APIClient(session: MockSessionManager()), photo: photo)
            let window = try await show(fixture, repo: repo, style: style, largeText: true)
            try await enterName("  Synthetic Album  ", in: window)
            window.endEditing(true)

            try await activateAccessibilityButton(named: "Add Photos", in: window)
            try await waitUntil("The actual picker loads the provided synthetic photo") { repo.requests == 1 }
            try await activateAccessibilityButton(named: PhotoAssetAccessibility.label(for: AssetLite(photo)), in: window)
            try await activateAccessibilityButton(named: "Add", in: window)
            try await waitUntil("The create screen preserves its actual selected-photo count") {
                self.searchContainsText("1 Photo Selected", in: window)
            }
            try await activateAccessibilityButton(named: "Create", in: window)

            try await waitUntil("Create completes the real sheet's save callback and dismissal") { !fixture.isPresented }
            XCTAssertEqual(fixture.creations.map(\.name), ["Synthetic Album"])
            XCTAssertEqual(fixture.creations.map(\.description), [""])
            XCTAssertEqual(fixture.creations.map(\.ids), [[photo.id]])
            window.isHidden = true
        }
    }

    func testRequiredNameAndBusySavePreserveTheFormWhenTheServerErrorIsPresented() async throws {
        let fixture = NewAlbumFixture(), gate = PeopleStateGate<String?>()
        defer { gate.complete(.success(nil)) }
        fixture.save = { try? await gate.value() }
        let window = try await show(fixture)
        try await waitUntil("The empty required name disables Create") { self.createIsDisabled(in: window) }
        try await enterName("   ", in: window)
        XCTAssertTrue(createIsDisabled(in: window))
        try await enterName("Trip", in: window)
        window.endEditing(true)
        try await activateAccessibilityButton(named: "Create", in: window)
        await fulfillment(of: [gate.started], timeout: 2)
        try await waitUntil("An in-flight save disables its Create control") { self.createIsDisabled(in: window) }
        XCTAssertEqual(fixture.creations.count, 1)
        gate.complete(.success("Synthetic server rejection"))
        try await waitUntil("The save failure stays in the form and exposes its actual error") {
            self.searchContainsText("Failed to Create Album", in: window)
                && self.searchContainsText("Synthetic server rejection", in: window)
        }
        let alert = try await presentedNativeAlert(in: window)
        XCTAssertEqual(alert.title, "Failed to Create Album")
        XCTAssertEqual(alert.message, "Synthetic server rejection")
        XCTAssertEqual(alert.preferredStyle, .alert)
        let acknowledge = try XCTUnwrap(alert.actions.first { $0.title == "OK" })
        XCTAssertTrue(acknowledge.isEnabled)
        XCTAssertEqual(acknowledge.style, .cancel)
        let name = try XCTUnwrap(descendants(window).compactMap { $0 as? UITextField }
            .first { $0.placeholder == "Album Name" })
        XCTAssertEqual(name.text, "Trip", "The failed save must preserve the user's form input")
        XCTAssertEqual(fixture.creations.map(\.name), ["Trip"])
        XCTAssertTrue(fixture.isPresented, "Presenting a save error must not dismiss the album form")
    }

    func testPreselectedAssetFlowKeepsDescriptionAndDoesNotOfferAnotherPicker() async throws {
        let fixture = NewAlbumFixture()
        let window = try await show(fixture, allowsAssetSelection: false)
        try await enterName("Album", in: window)
        if let description = descendants(window).compactMap({ $0 as? UITextField }).first(where: { $0.placeholder == "Add Description" }) {
            description.text = "  Server description  "
            description.sendActions(for: .editingChanged)
        } else {
            let description = try XCTUnwrap(descendants(window).compactMap { $0 as? UITextView }.first)
            description.text = "  Server description  "
            description.delegate?.textViewDidChange?(description)
        }
        window.endEditing(true)
        XCTAssertFalse(searchContainsText("Add Photos", in: window))
        try await activateAccessibilityButton(named: "Create", in: window)
        try await waitUntil("The caller with existing selected assets receives its unchanged contract") { !fixture.isPresented }
        XCTAssertEqual(fixture.creations.map(\.description), ["Server description"])
        XCTAssertEqual(fixture.creations.map(\.ids), [[]])
    }

    private func show(_ fixture: NewAlbumFixture, repo: SearchRepository? = nil,
                      style: UIUserInterfaceStyle = .light, largeText: Bool = false,
                      allowsAssetSelection: Bool = true) async throws -> UIWindow {
        let window = try await host(NewAlbumTestPresenter(fixture: fixture, repo: repo,
            allowsAssetSelection: allowsAssetSelection, largeText: largeText), style: style)
        if largeText {
            window.frame = CGRect(x: 0, y: 0, width: 320, height: 640)
            window.rootViewController?.view.frame = window.bounds
        }
        try await waitUntil("The real New Album sheet has mounted its editable name") {
            self.descendants(window).contains { ($0 as? UITextField)?.placeholder == "Album Name" }
        }
        return window
    }

    private func enterName(_ text: String, in window: UIWindow) async throws {
        let field = try XCTUnwrap(descendants(window).compactMap { $0 as? UITextField }
            .first { $0.placeholder == "Album Name" })
        field.text = text
        field.sendActions(for: .editingChanged)
        try await Task.sleep(for: .milliseconds(50))
    }

    private func createIsDisabled(in root: NSObject) -> Bool {
        var seen = Set<ObjectIdentifier>()
        func find(_ object: NSObject, depth: Int) -> Bool {
            guard depth < 40, seen.insert(ObjectIdentifier(object)).inserted else { return false }
            if object.accessibilityLabel == "Create", object.accessibilityTraits.contains(.button) {
                return object.accessibilityTraits.contains(.notEnabled) || (object as? UIControl)?.isEnabled == false
            }
            if let button = object as? UIButton, button.currentTitle == "Create" { return !button.isEnabled }
            if let view = object as? UIView, view.subviews.contains(where: { find($0, depth: depth + 1) }) { return true }
            if let elements = object.accessibilityElements,
               elements.compactMap({ $0 as? NSObject }).contains(where: { find($0, depth: depth + 1) }) { return true }
            let count = object.accessibilityElementCount()
            if (1...500).contains(count) {
                for index in 0..<count {
                    if let child = object.accessibilityElement(at: index) as? NSObject, find(child, depth: depth + 1) { return true }
                }
            }
            return false
        }
        return find(root, depth: 0)
    }

    private func descendants(_ view: UIView) -> [UIView] { [view] + view.subviews.flatMap(descendants) }
}

@MainActor
@Observable
private final class NewAlbumFixture {
    struct Creation { let name: String; let description: String; let ids: [String] }
    var isPresented = true
    var creations: [Creation] = []
    var save: () async -> String? = { nil }
    func create(_ name: String, _ description: String, _ ids: [String]) async -> String? {
        creations.append(Creation(name: name, description: description, ids: ids))
        return await save()
    }
}

private struct NewAlbumTestPresenter: View {
    @Bindable var fixture: NewAlbumFixture
    let repo: SearchRepository?
    let allowsAssetSelection: Bool
    let largeText: Bool
    var body: some View {
        Color.clear.sheet(isPresented: $fixture.isPresented) {
            NewAlbumSheet(allowsAssetSelection: allowsAssetSelection, photoRepository: repo, onCreate: fixture.create)
                .environment(\.dynamicTypeSize, largeText ? .accessibility3 : .large)
        }
    }
}

private final class NewAlbumPhotoRepository: SearchRepository {
    let photo: AssetResponseDTO
    private(set) var requests = 0
    init(api: APIClient, photo: AssetResponseDTO) { self.photo = photo; super.init(api: api) }
    override func allMetadata(_ request: SearchRequestDTO) async throws -> [AssetResponseDTO] {
        requests += 1
        return [photo]
    }
}
