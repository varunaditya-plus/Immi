import AVFoundation
import SwiftUI
import UIKit
import XCTest
@testable import ImmichApp

@MainActor
final class TrashPlaybackMenuTests: SimulatorHostedTestCase {
    private var pagers: [PhotoPagerController] = []
    private var movies: [URL] = []

    override func tearDown() async throws {
        pagers.forEach { $0.stopAllPlayback() }
        try await super.tearDown()
        pagers.removeAll()
        for movie in movies { try FileManager.default.removeItem(at: movie) }
        movies.removeAll()
    }

    func testCompactTrashVideoMenuChangesActualPlaybackWithoutExposingAssetMutations() async throws {
        try await assertPlaybackMenu(width: 390, sizeClass: .compact)
    }

    func testRegularTrashVideoMenuChangesActualPlaybackWithoutExposingAssetMutations() async throws {
        try await assertPlaybackMenu(width: 1024, sizeClass: .regular)
    }

    private func assertPlaybackMenu(width: CGFloat, sizeClass: UserInterfaceSizeClass) async throws {
        let movie = try await makePagerPlaybackMovie()
        movies.append(movie)
        let asset = AssetLite(id: UUID().uuidString, isVideo: true, ratio: 1, thumbhash: nil,
            createdAt: .now, duration: 3)
        var mutations: [String] = []
        let actions = TrashViewerActions(restore: { _ in mutations.append("restore"); return false },
            deletePermanently: { _ in mutations.append("delete"); return false })
        let window = try await host(NavigationStack {
            AssetDetailView(currentAsset: asset, assets: [asset],
                visibilityPolicy: AssetVisibilityPolicy(removalScope: .trash), isModal: true, trashActions: actions)
        }.environment(\.horizontalSizeClass, sizeClass))
        window.frame = CGRect(x: 0, y: 0, width: width, height: 844)
        window.rootViewController?.view.frame = window.bounds
        window.layoutIfNeeded()
        var mountedPager: PhotoPagerController?
        try await waitUntil("The actual trash viewer mounts its video pager and playback bar") {
            mountedPager = self.pager(in: window.rootViewController)
            return mountedPager != nil && self.descendants(window).contains { $0.accessibilityIdentifier == "video.playPause" }
        }
        let pager = try XCTUnwrap(mountedPager)
        pagers.append(pager)
        let cell = try XCTUnwrap(descendants(window).compactMap { $0 as? PhotoPagerCell }.first)
        let loader = TrashPlaybackFixtureLoader(movie: movie)
        defer { withExtendedLifetime(loader) {} }
        cell.configure(with: asset, loader: loader)
        let play = try XCTUnwrap(descendants(window).compactMap { $0 as? UIButton }.first {
            $0.accessibilityIdentifier == "video.playPause"
        })
        play.sendActions(for: .touchUpInside)
        try await waitUntil("The mounted trash video loads the generated movie into its real player") {
            self.player(in: cell)?.currentItem?.status == .readyToPlay && cell.playbackState.isPlaying
                && pager.playbackOptions.availableRates.contains(2)
        }
        play.sendActions(for: .touchUpInside)
        let player = try XCTUnwrap(player(in: cell))
        XCTAssertEqual(player.timeControlStatus, .paused)

        try await activateAccessibilityButton(named: "More", in: window)
        var actualMenu: UIMenu?
        var actualInteraction: UIContextMenuInteraction?
        try await waitUntil("The visible trash More menu exposes its production playback actions") {
            for view in self.descendants(window) {
                for interaction in view.interactions.compactMap({ $0 as? UIContextMenuInteraction }) {
                    interaction.updateVisibleMenu { menu in
                        if self.menuActions(in: menu).contains(where: { $0.title == "Loop Video" }) {
                            actualMenu = menu; actualInteraction = interaction
                        }
                        return menu
                    }
                }
            }
            return actualMenu != nil
        }
        let menu = try XCTUnwrap(actualMenu)
        let allowed = Set(pager.playbackOptions.availableRates.map { String(format: "%g×", $0) } + ["Loop Video"])
        XCTAssertEqual(Set(menuActions(in: menu).map(\.title)), allowed,
            "Trash More must contain playback choices only, with no ordinary asset mutations")
        actualInteraction?.dismissMenu()

        try await activateSearchMenuAction(named: "2×", in: window)
        try await waitUntil("The actual speed menu updates the selected cell and real player") {
            cell.playbackState.rate == 2 && pager.playbackOptions.rate == 2 && player.defaultRate == 2
        }
        try await activateSearchMenuAction(named: "Loop Video", in: window)
        try await waitUntil("The actual loop menu updates the selected cell and observed menu state") {
            cell.playbackState.isLooping && pager.playbackOptions.isLooping
        }
        let slider = try XCTUnwrap(descendants(window).compactMap { $0 as? UISlider }.first {
            $0.accessibilityIdentifier == "video.position"
        })
        slider.sendActions(for: .touchDown)
        slider.value = 0.9
        slider.sendActions(for: .valueChanged)
        slider.sendActions(for: .touchUpInside)
        try await waitUntil("The real playback slider seeks close to the movie's end") {
            abs(player.currentTime().seconds - 2.7) < 0.12
        }
        play.sendActions(for: .touchUpInside)
        try await waitUntil("The selected speed is used by the real running player") { player.rate == 2 }
        try await waitUntil("The enabled loop choice restarts the real movie after its end") {
            player.currentTime().seconds < 0.5 && player.timeControlStatus == .playing
        }
        play.sendActions(for: .touchUpInside)
        try await activateSearchMenuAction(named: "Loop Video", in: window)
        try await waitUntil("The same menu can turn looping off again") {
            !cell.playbackState.isLooping && !pager.playbackOptions.isLooping
        }
        XCTAssertTrue(mutations.isEmpty, "Playback must never restore or permanently delete the trash asset")
    }

    private func descendants(_ view: UIView) -> [UIView] { [view] + view.subviews.flatMap(descendants) }

    private func pager(in controller: UIViewController?) -> PhotoPagerController? {
        guard let controller else { return nil }
        if let pager = controller as? PhotoPagerController { return pager }
        return controller.children.lazy.compactMap { self.pager(in: $0) }.first
    }

    private func menuActions(in menu: UIMenu) -> [UIAction] {
        menu.children.flatMap { item -> [UIAction] in
            if let action = item as? UIAction, !action.attributes.contains(.hidden) { return [action] }
            if let menu = item as? UIMenu { return menuActions(in: menu) }
            return []
        }
    }

    private func player(in view: UIView) -> AVPlayer? {
        func find(_ layer: CALayer) -> AVPlayer? {
            if let player = (layer as? AVPlayerLayer)?.player { return player }
            return layer.sublayers?.lazy.compactMap(find).first
        }
        return find(view.layer)
    }
}

@MainActor
private final class TrashPlaybackFixtureLoader: PhotoPreviewLoader {
    let movie: URL
    init(movie: URL) {
        self.movie = movie
        super.init(session: MockSessionManager())
    }
    override func cachedImage(for assetId: String) -> UIImage? { UIImage(systemName: "video") }
    override func hasPreview(for assetId: String) -> Bool { true }
    override func playbackAsset(for assetId: String) async -> AVAsset? { AVURLAsset(url: movie) }
}
