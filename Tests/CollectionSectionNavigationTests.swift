import Observation
import SwiftUI
import UIKit
import XCTest
@testable import ImmichApp

@MainActor
final class CollectionSectionNavigationTests: SimulatorHostedTestCase {
    func testHeadingOpensTheCollectionWithoutCollapsingItsCards() async throws {
        let state = SectionExpansionState()
        let window = try await section(state)

        try await activateAccessibilityButton(named: "Albums", in: window)
        try await waitUntil("The heading pushes the actual collection destination") {
            self.navigation(in: window.rootViewController)?.topViewController?.navigationItem.title == "Albums"
        }
        XCTAssertTrue(state.expanded, "The heading must not activate the separate collapse control")
    }

    func testExplicitCollapseAndExpandActionsDoNotNavigate() async throws {
        let state = SectionExpansionState()
        let window = try await section(state)

        try await activateAccessibilityButton(named: "Collapse Albums", in: window)
        try await waitUntil("The actual collapse button updates expansion") { !state.expanded }
        XCTAssertEqual(navigation(in: window.rootViewController)?.viewControllers.count, 1)
        try await activateAccessibilityButton(named: "Expand Albums", in: window)
        try await waitUntil("The same real control can expand again") { state.expanded }
        XCTAssertEqual(navigation(in: window.rootViewController)?.viewControllers.count, 1)
    }

    func testPinnedHeadingAndCollapseHaveDistinctRealActions() async throws {
        let api = APIClient(session: MockSessionManager())
        let model = LibraryViewModel(memoriesRepo: MemoriesRepository(api: api), albumRepo: AlbumRepository(api: api),
            peopleRepo: PeopleRepository(api: api), searchRepo: SearchRepository(api: api), assetRepo: AssetDetailRepository(api: api),
            localPhotos: { [] })
        let window = try await host(LibraryView(isActive: false, viewModel: model))

        try await activateAccessibilityButton(named: "Collapse Pinned", in: window)
        XCTAssertEqual(navigation(in: window.rootViewController)?.viewControllers.count, 1)
        try await activateAccessibilityButton(named: "Expand Pinned", in: window)
        XCTAssertEqual(navigation(in: window.rootViewController)?.viewControllers.count, 1)
        try await activateAccessibilityButton(named: "Pinned", in: window)
        try await waitUntil("The Pinned heading opens its collection instead of collapsing it") {
            self.navigation(in: window.rootViewController)?.topViewController?.navigationItem.title == "Pinned"
        }
    }

    func testFeaturedPhotoExposesItsMediaLabelAndOpensTheViewer() async throws {
        let date = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-09-28T12:00:00Z"))
        let photo = AssetLite(id: UUID().uuidString, isVideo: false, ratio: 1,
            thumbhash: nil, createdAt: date, isFavorite: true)
        let window = try await host(NavigationStack {
            FeaturedPhotoCards(assets: [photo], width: 120) { _ in EmptyView() }
        })

        try await activateAccessibilityButton(named: PhotoAssetAccessibility.label(for: photo), in: window)
        try await waitUntil("The labeled Featured photo opens its actual viewer") {
            self.navigation(in: window.rootViewController)?.viewControllers.count == 2
        }
    }

    private func section(_ state: SectionExpansionState) async throws -> UIWindow {
        try await host(NavigationStack {
            CollectionSection(title: "Albums",
                isExpanded: Binding(get: { state.expanded }, set: { state.expanded = $0 }),
                isEmpty: false, contentHeight: 120,
                destination: { Text("Album destination").navigationTitle("Albums") },
                content: { RoundedRectangle(cornerRadius: 18).fill(.gray).frame(width: 120, height: 120) })
        })
    }

    private func navigation(in controller: UIViewController?) -> UINavigationController? {
        guard let controller else { return nil }
        if let navigation = controller as? UINavigationController { return navigation }
        return controller.children.compactMap { navigation(in: $0) }.first
    }
}

@MainActor
@Observable
private final class SectionExpansionState {
    var expanded = true
}
