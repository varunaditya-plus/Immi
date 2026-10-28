import SwiftUI
import UIKit
import Vision
import XCTest
@testable import ImmichApp

@MainActor
final class CollectionEmptyPresentationTests: XCTestCase {
    private var window: UIWindow?
    private weak var previousKeyWindow: UIWindow?

    override func tearDown() async throws {
        closeHost()
        try await super.tearDown()
    }









    func testConfirmedSameIDMetadataUpdatesRenderedAlbumRowsAndCards() async throws {
        let model = AlbumListViewModel(repo: AlbumRepository(api: makeStubAPIClient()))
        let album = AlbumResponseDTO(id: "metadata-row", albumName: "Old title", description: nil,
            assetCount: 0, albumThumbnailAssetId: nil, shared: false, createdAt: .distantPast, assets: nil)
        model.albums = [album]
        try show(AlbumRowPresentationFixture(model: model))
        let before = try await visibleText()
        XCTAssertEqual(before.components(separatedBy: "Old title").count - 1, 2, before)
        var updated = album
        updated.albumName = "Saved title"
        model.applyAlbumUpdate(updated)
        let after = try await visibleText()
        XCTAssertEqual(after.components(separatedBy: "Saved title").count - 1, 2, after)
        XCTAssertFalse(after.contains("Old title"), after)
    }



    private func show<Content: View>(_ content: Content) throws {
        closeHost()
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first(where: { $0.activationState == .foregroundActive }))
        previousKeyWindow = scene.windows.first(where: \.isKeyWindow)
        let host = UIHostingController(rootView: content
            .environment(MockSessionManager() as SessionManager)
            .environment(\.locale, Locale(identifier: "en_US"))
            .environment(\.colorScheme, .light))
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        window.rootViewController = host
        window.makeKeyAndVisible()
        host.view.frame = window.bounds
        host.view.setNeedsLayout()
        host.view.layoutIfNeeded()
        self.window = window
    }

    private func closeHost() {
        window?.isHidden = true
        window?.rootViewController = nil
        window = nil
        previousKeyWindow?.makeKey()
        previousKeyWindow = nil
    }

    private func visibleText() async throws -> String {
        // Allow SwiftUI's actual layout and drawing to complete before OCR.
        try await Task.sleep(for: .milliseconds(150))
        let window = try XCTUnwrap(window)
        window.layoutIfNeeded()
        let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        let attachment = XCTAttachment(image: image)
        attachment.lifetime = .keepAlways
        add(attachment)
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["en-US"]
        try VNImageRequestHandler(cgImage: try XCTUnwrap(image.cgImage)).perform([request])
        return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: " ")
    }
}

private struct AlbumRowPresentationFixture: View {
    let model: AlbumListViewModel
    var body: some View {
        VStack {
            ForEach(model.albums) { album in
                AlbumRowView(album: album)
                AlbumGridCard(album: album)
                    .frame(width: 240, height: 240)
                    .background(Color.black)
            }
        }
        .padding()
    }
}
