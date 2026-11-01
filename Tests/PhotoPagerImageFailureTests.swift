import SwiftUI
import UIKit
import XCTest
@testable import ImmichApp

@MainActor
final class PhotoPagerImageFailureTests: SimulatorHostedTestCase {
    private var cells: [PhotoPagerCell] = []
    private var gates: [PeopleStateGate<UIImage?>] = []

    override func tearDown() async throws {
        cells.forEach { $0.prepareForReuse() }
        gates.forEach { $0.complete(.success(nil)) }
        try await super.tearDown()
        cells.removeAll()
        gates.removeAll()
    }

    func testFailedStillShowsAReadableRetryAndItsActualActionLoadsThePreviewInBothAppearances() async throws {
        for style in [UIUserInterfaceStyle.light, .dark] {
            let photo = AssetLite(makeTestAsset(id: UUID().uuidString))
            let image = image(.green)
            let loader = ImageFailurePreviewLoader()
            loader.load = { [weak loader] _ in loader?.requests.count == 1 ? nil : image }
            let (cell, window) = try await show(photo, loader: loader, style: style)
            try await waitUntil("A failed still exposes its actual Retry control") {
                self.searchContainsText("Photo Unavailable", in: cell) && self.retry(in: cell)?.isHidden == false
            }
            let button = try XCTUnwrap(retry(in: cell))
            XCTAssertTrue(button.isEnabled)
            XCTAssertTrue(window.bounds.intersects(button.convert(button.bounds, to: window)))
            _ = try await screenshot(window)

            button.sendActions(for: .touchUpInside)

            try await waitUntil("The real Retry action installs the successful preview") {
                self.images(in: cell).contains { $0 === image }
            }
            XCTAssertEqual(loader.requests, [photo.id, photo.id])
            XCTAssertFalse(searchContainsText("Photo Unavailable", in: cell))
        }
    }

    func testLateFailureFromARetriedPhotoCannotCoverTheNextPhotosSuccessfulPreview() async throws {
        let first = AssetLite(makeTestAsset(id: UUID().uuidString))
        let next = AssetLite(makeTestAsset(id: UUID().uuidString))
        let gate = PeopleStateGate<UIImage?>(); gates.append(gate)
        let nextImage = image(.blue)
        let loader = ImageFailurePreviewLoader()
        loader.load = { [weak loader] id in
            if id == next.id { return nextImage }
            return loader?.requests.count == 1 ? nil : try? await gate.value()
        }
        let (cell, _) = try await show(first, loader: loader)
        try await waitUntil("The failed first photo exposes Retry") { self.searchContainsText("Photo Unavailable", in: cell) }
        try XCTUnwrap(retry(in: cell)).sendActions(for: .touchUpInside)
        await fulfillment(of: [gate.started], timeout: 2)

        cell.configure(with: next, loader: loader)
        try await waitUntil("The next photo renders while the previous retry is held") {
            self.images(in: cell).contains { $0 === nextImage }
        }
        gate.complete(.success(nil))
        try await waitUntil("The old retry has returned through its cancellation guard") { loader.returns == 3 }

        XCTAssertFalse(searchContainsText("Photo Unavailable", in: cell))
        XCTAssertTrue(images(in: cell).contains { $0 === nextImage })
        XCTAssertEqual(loader.requests, [first.id, first.id, next.id])
    }

    func testARecoveredFullPreviewCacheClearsTheSamePhotosFailureWithoutAnotherRequest() async throws {
        let photo = AssetLite(makeTestAsset(id: UUID().uuidString))
        let loader = ImageFailurePreviewLoader()
        let (cell, _) = try await show(photo, loader: loader)
        try await waitUntil("The initial missing preview exposes its real failure") {
            self.searchContainsText("Photo Unavailable", in: cell)
        }
        let recovered = image(.green)
        loader.cached = recovered
        loader.fullPreview = true

        cell.configure(with: photo, loader: loader)

        try await waitUntil("A full cached recovery replaces the failure with its actual image") {
            self.images(in: cell).contains { $0 === recovered }
                && !self.searchContainsText("Photo Unavailable", in: cell)
        }
        XCTAssertEqual(loader.requests, [photo.id])
    }

    private func show(_ asset: AssetLite, loader: ImageFailurePreviewLoader,
                      style: UIUserInterfaceStyle = .light) async throws -> (PhotoPagerCell, UIWindow) {
        let cell = PhotoPagerCell(frame: .zero)
        cells.append(cell)
        let window = try await host(ImageFailureCellHost(cell: cell), style: style)
        cell.configure(with: asset, loader: loader)
        return (cell, window)
    }

    private func views(_ view: UIView) -> [UIView] {
        guard !view.isHidden, view.alpha > 0 else { return [] }
        return [view] + view.subviews.flatMap(views)
    }
    private func retry(in cell: PhotoPagerCell) -> UIButton? {
        views(cell).compactMap { $0 as? UIButton }.first { $0.accessibilityIdentifier == "photoPlaybackRetry" }
    }
    private func images(in cell: PhotoPagerCell) -> [UIImage] { views(cell).compactMap { ($0 as? UIImageView)?.image } }
    private func image(_ color: UIColor) -> UIImage {
        UIGraphicsImageRenderer(size: CGSize(width: 80, height: 60)).image { context in
            color.setFill(); context.fill(CGRect(x: 0, y: 0, width: 80, height: 60))
        }
    }
}

@MainActor
private final class ImageFailurePreviewLoader: PhotoPreviewLoader {
    var load: (String) async -> UIImage? = { _ in nil }
    var cached: UIImage?
    var fullPreview = false
    private(set) var requests: [String] = []
    private(set) var returns = 0

    init() { super.init(session: MockSessionManager()) }
    override func cachedImage(for assetId: String) -> UIImage? { cached }
    override func hasPreview(for assetId: String) -> Bool { fullPreview }
    override func image(for assetId: String) async -> UIImage? {
        requests.append(assetId)
        defer { returns += 1 }
        return await load(assetId)
    }
}

private struct ImageFailureCellHost: UIViewRepresentable {
    let cell: PhotoPagerCell
    func makeUIView(context: Context) -> PhotoPagerCell { cell }
    func updateUIView(_ uiView: PhotoPagerCell, context: Context) {}
}
