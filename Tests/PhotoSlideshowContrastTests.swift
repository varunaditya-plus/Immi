import SwiftUI
import UIKit
import XCTest
@testable import ImmichApp

@MainActor
final class PhotoSlideshowContrastTests: ViewerAdaptiveLayoutTestCase {
    private var slideshows: [PhotoSlideshowState] = []

    override func tearDown() async throws {
        slideshows.forEach { $0.stop() }
        try await super.tearDown()
        slideshows.removeAll()
    }

    func testSlideshowTitleAndCountHaveReadableContrastOverAnActuallyRenderedWhitePhoto() async throws {
        for style in [UIUserInterfaceStyle.light, .dark] {
            let session = MockSessionManager()
            let asset = AssetLite(makeTestAsset(id: UUID().uuidString))
            let loader = WhiteSlideshowPreviewLoader(session: session)
            let state = PhotoSlideshowState(assets: [asset])
            state.togglePlayback()
            slideshows.append(state)
            let window = try await host(PhotoSlideshowView(assets: [asset], session: session,
                prepareShare: { _ in nil }, state: state, previewLoader: loader)
                .environment(session as SessionManager).environment(\.scenePhase, .active), style: style)
            try await waitUntil("The injected white photo is actually loaded") { state.mediaState == .ready }
            let snapshot = try await screenshot(window)
            XCTAssertGreaterThan(try centerLuminance(snapshot), 0.95,
                "Contrast must be checked over the generated white image, not an empty black slide")
            try assertTextContrast("Slideshow", image: snapshot)
            try assertTextContrast("1 of 1", image: snapshot)
        }
    }
}

@MainActor
private final class WhiteSlideshowPreviewLoader: PhotoPreviewLoader {
    private let white = UIGraphicsImageRenderer(size: CGSize(width: 390, height: 844)).image { context in
        UIColor.white.setFill(); context.fill(CGRect(x: 0, y: 0, width: 390, height: 844))
    }
    override func cachedImage(for assetId: String) -> UIImage? { white }
    override func image(for assetId: String) async -> UIImage? { white }
}

