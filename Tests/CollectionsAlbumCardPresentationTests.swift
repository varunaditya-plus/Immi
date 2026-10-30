import SwiftUI
import UIKit
import Vision
import XCTest
@testable import ImmichApp

@MainActor
final class CollectionsAlbumCardPresentationTests: SimulatorHostedTestCase {
    private var previousAlbums: [AlbumResponseDTO]?

    override func setUp() {
        previousAlbums = LocalSnapshot.load([AlbumResponseDTO].self, for: LocalSnapshot.Key.libraryAlbums)
    }

    override func tearDown() async throws {
        try await super.tearDown()
        if let previousAlbums { LocalSnapshot.save(previousAlbums, for: LocalSnapshot.Key.libraryAlbums) }
        else { LocalSnapshot.remove(LocalSnapshot.Key.libraryAlbums) }
    }

    func testSharedCardOutsideRecentAlbumsOwnsItsTargetedNativeDeleteConfirmation() async throws {
        let fixture = try await sharedCard()
        let alert = try await requestDelete(in: fixture.window)

        XCTAssertTrue(alert.title?.contains(fixture.target.albumName) == true)
        XCTAssertTrue(fixture.repository.deleted.isEmpty, "Presenting an anchored confirmation must not delete anything")
        XCTAssertEqual(fixture.model.albums.count, 21)
        let source = try XCTUnwrap(alert.popoverPresentationController?.sourceView)
        XCTAssertNotNil(source.window, "The shared tile must supply a live popover anchor")
        XCTAssertFalse(source.bounds.isEmpty)
    }

    func testSmallRecentDayCardKeepsLongLocalizedCaptionVisibleAtLargestAccessibilitySize() async throws {
        let date = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-09-28T12:00:00Z"))
        let photos = (0..<42).map { _ in
            AssetLite(id: UUID().uuidString, isVideo: false, ratio: 1, thumbhash: nil, createdAt: date)
        }
        let day = RecentDayCollection(start: date, end: date.addingTimeInterval(86_400), assets: photos)
        let window = try await host(RecentDayCard(day: day, width: 120, height: 132)
            .environment(\.locale, Locale(identifier: "fr_FR"))
            .environment(\.dynamicTypeSize, .accessibility5))
        let image = try await screenshot(window)
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["fr-FR"]
        try VNImageRequestHandler(cgImage: try XCTUnwrap(image.cgImage)).perform([request])
        let caption = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: " ").lowercased()

        XCTAssertTrue(caption.contains("septembre"), caption)
        XCTAssertTrue(caption.contains("42"), caption)
    }

    private struct Fixture {
        let model: LibraryViewModel
        let repository: CollectionsCardAlbumRepository
        let target: AlbumResponseDTO
        let window: UIWindow
    }

    private func sharedCard() async throws -> Fixture {
        let api = APIClient(session: MockSessionManager())
        let repository = CollectionsCardAlbumRepository(api: api)
        let model = LibraryViewModel(memoriesRepo: MemoriesRepository(api: api), albumRepo: repository,
            peopleRepo: PeopleRepository(api: api), searchRepo: SearchRepository(api: api),
            assetRepo: AssetDetailRepository(api: api))
        let target = album("shared-\(UUID())", shared: true)
        model.albums = (0..<20).map { album("personal-\($0)") } + [target]
        XCTAssertFalse(model.recentAlbums.contains { $0.id == target.id },
            "This regression must not have a confirmation host in the recent-album row")
        let window = try await host(NavigationStack {
            HStack {
                LibraryView().sharedAlbumCards(using: model, width: 120)
            }
        }.environment(\.horizontalSizeClass, .compact))
        if let scene = window.windowScene {
            window.frame = scene.effectiveGeometry.coordinateSpace.bounds
            window.rootViewController?.view.frame = window.bounds
            window.layoutIfNeeded()
        }
        return Fixture(model: model, repository: repository, target: target, window: window)
    }

    private func requestDelete(in window: UIWindow) async throws -> UIAlertController {
        var action: UIAccessibilityCustomAction?
        try await waitUntil("The rendered shared card exposes its real Delete Album action") {
            var visited = Set<ObjectIdentifier>()
            action = self.findDeleteAction(in: window, visited: &visited, depth: 0)
            return action != nil
        }
        let renderedAction = try XCTUnwrap(action)
        if let handler = renderedAction.actionHandler {
            XCTAssertTrue(handler(renderedAction))
        } else {
            let target = try XCTUnwrap(renderedAction.target)
            XCTAssertTrue(UIApplication.shared.sendAction(renderedAction.selector, to: target, from: renderedAction, for: nil))
        }
        try await waitUntil("The card owns a visible native delete confirmation") {
            self.presentedAlert(from: window.rootViewController) != nil
        }
        let alert = try XCTUnwrap(presentedAlert(from: window.rootViewController))
        if let transition = alert.transitionCoordinator {
            await withCheckedContinuation { continuation in
                let accepted = transition.animate(alongsideTransition: nil) { _ in continuation.resume() }
                if !accepted { continuation.resume() }
            }
        }
        try await waitUntil("The native sheet has completed presentation before activation") {
            !alert.isBeingPresented && alert.view.window != nil && alert.view.isUserInteractionEnabled
        }
        let diagnostic = XCTAttachment(string: alertHierarchy(alert.view))
        diagnostic.name = "Native shared-album confirmation controls"
        diagnostic.lifetime = .keepAlways
        add(diagnostic)
        XCTAssertEqual(alert.actions.map(\.title), ["Delete Album", "Cancel"])
        XCTAssertEqual(alert.actions.first?.style, .destructive)
        XCTAssertEqual(alert.message, "The photos will stay in your library.")
        return alert
    }

    private func alertHierarchy(_ view: UIView, depth: Int = 0) -> String {
        let events = (view as? UIControl).map { String(describing: $0.allControlEvents) } ?? "none"
        let frame = view.convert(view.bounds, to: view.window)
        let row = String(repeating: " ", count: depth) + "\(type(of: view)) label=\(view.accessibilityLabel ?? "nil") frame=\(frame) AX=\(view.isAccessibilityElement) events=\(events)\n"
        return row + view.subviews.map { alertHierarchy($0, depth: depth + 1) }.joined()
    }

    private func presentedAlert(from controller: UIViewController?) -> UIAlertController? {
        guard let controller else { return nil }
        if let alert = controller as? UIAlertController { return alert }
        if let presented = presentedAlert(from: controller.presentedViewController) { return presented }
        return controller.children.compactMap { presentedAlert(from: $0) }.first
    }

    private func findDeleteAction(in object: NSObject, visited: inout Set<ObjectIdentifier>, depth: Int) -> UIAccessibilityCustomAction? {
        guard depth < 40, visited.insert(ObjectIdentifier(object)).inserted else { return nil }
        if let view = object as? UIView, view.isHidden || view.alpha <= 0 { return nil }
        if let action = object.accessibilityCustomActions?.first(where: { $0.name == "Delete Album" }) { return action }
        if let view = object as? UIView {
            for child in view.subviews {
                if let action = findDeleteAction(in: child, visited: &visited, depth: depth + 1) { return action }
            }
        }
        if let children = object.accessibilityElements {
            for case let child as NSObject in children {
                if let action = findDeleteAction(in: child, visited: &visited, depth: depth + 1) { return action }
            }
        }
        let count = object.accessibilityElementCount()
        if (1...500).contains(count) {
            for index in 0..<count {
                guard let child = object.accessibilityElement(at: index) as? NSObject else { continue }
                if let action = findDeleteAction(in: child, visited: &visited, depth: depth + 1) { return action }
            }
        }
        return nil
    }

    private func album(_ id: String, shared: Bool = false) -> AlbumResponseDTO {
        AlbumResponseDTO(id: id, albumName: id, description: nil, assetCount: 0,
            albumThumbnailAssetId: nil, shared: shared, createdAt: .distantPast, assets: nil)
    }
}

private final class CollectionsCardAlbumRepository: AlbumRepository {
    var deleted: [String] = []
    override func delete(_ id: String) async throws { deleted.append(id) }
}
