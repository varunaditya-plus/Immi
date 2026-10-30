import SwiftUI
import UIKit
import XCTest
@testable import ImmichApp

@MainActor
final class SimulatorAppearanceRegressionTests: SimulatorHostedTestCase {
    func testContrastSamplingUsesTheRenderedTextCoordinates() throws {
        let image = UIGraphicsImageRenderer(size: CGSize(width: 260, height: 120)).image { context in
            UIColor.white.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 260, height: 120))
            UIColor.black.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 260, height: 60))
            ("SAMPLE" as NSString).draw(at: CGPoint(x: 10, y: 10), withAttributes: [
                .font: UIFont.boldSystemFont(ofSize: 32), .foregroundColor: UIColor.white,
            ])
        }
        try assertTextContrast("SAMPLE", image: image)
    }

    func testEmptyAlbumCaptionHasReadableContrastOnActualLightAndDarkBackgrounds() async throws {
        let album = AlbumResponseDTO(id: UUID().uuidString, albumName: "Empty Album", description: nil,
            assetCount: 0, albumThumbnailAssetId: nil, shared: false, createdAt: .distantPast, assets: nil)
        for style in [UIUserInterfaceStyle.light, .dark] {
            let window = try await host(AlbumGridCard(album: album).frame(width: 240, height: 240)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(.systemBackground)), style: style)
            try assertTextContrast("Empty Album", image: await screenshot(window))
        }
    }

    func testNarrowAlbumCaptionKeepsContrastWithAccessibilityText() async throws {
        let album = AlbumResponseDTO(id: UUID().uuidString, albumName: "QA", description: nil,
            assetCount: 0, albumThumbnailAssetId: nil, shared: false, createdAt: .distantPast, assets: nil)
        let window = try await host(AlbumGridCard(album: album).frame(width: 160, height: 160)
            .dynamicTypeSize(.accessibility3)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(.systemBackground)))
        try assertTextContrast("QA", image: await screenshot(window))
    }
}
