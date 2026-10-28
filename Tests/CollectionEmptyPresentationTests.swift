import SwiftUI
import UIKit
import Vision
import XCTest
@testable import ImmichApp

@MainActor
final class CollectionEmptyPresentationTests: XCTestCase {
    private var window: UIWindow?
    private weak var previousKeyWindow: UIWindow?
    private var repositories: [ControlledSearchRepository] = []

    override func tearDown() async throws {
        closeHost()
        for repository in repositories { await repository.probe.cancelAll() }
        repositories.removeAll()
        try await super.tearDown()
    }

    func testRemovingEveryLoadedResultKeepsLoadMoreVisibleAndNextPageReachable() async throws {
        let (model, repository) = try await searchedModel()
        model.removeLocally(["first"])
        XCTAssertTrue(model.results.isEmpty)
        XCTAssertEqual(model.nextPage, "2")
        try show(SearchPresentationFixture(model: model))
        var text = try await visibleText()
        XCTAssertTrue(text.contains("Load More"), text)
        XCTAssertFalse(text.contains("No Results"), text)

        let page = Task { await model.loadMore() }
        _ = try await repository.probe.waitForRequest(1, testCase: self)
        text = try await visibleText()
        XCTAssertTrue(text.contains("Loading More"), text)
        try await repository.probe.fail(1, error: APIError.server(status: 503, message: "Page unavailable"))
        await page.value
        text = try await visibleText()
        XCTAssertTrue(text.contains("Page unavailable"), text)
        XCTAssertTrue(text.contains("Retry"), text)
        XCTAssertFalse(text.contains("No Results"), text)

        closeHost()
        let retry = Task { await model.retryLoadMore() }
        let request = try await repository.probe.waitForRequest(2, testCase: self)
        XCTAssertEqual(request.request.page, 2)
        try await repository.probe.succeed(2, ids: ["remaining"], total: 2)
        await retry.value
        XCTAssertEqual(model.results.map(\.id), ["remaining"])
        XCTAssertNil(model.nextPage)
    }

    func testOnlyATerminalEmptySearchShowsNoResults() async throws {
        let (model, _) = try await searchedModel(nextPage: nil)
        model.removeLocally(["first"])
        try show(SearchPresentationFixture(model: model))
        let text = try await visibleText()
        XCTAssertTrue(text.contains("No Results"), text)
        XCTAssertFalse(text.contains("Load More"), text)
        XCTAssertFalse(text.contains("Retry"), text)
    }

    func testSharedEmptyScopeExplainsSharingAndOffersAllAlbumsInsteadOfCreation() async throws {
        let model = AlbumListViewModel(repo: AlbumRepository(api: makeStubAPIClient()))
        model.albums = [.init(id: "personal", albumName: "Personal", description: nil, assetCount: 0,
            albumThumbnailAssetId: nil, shared: false, createdAt: .distantPast, assets: nil)]
        let view = AlbumsListView(viewModel: model)
        try show(view.emptyState(model, scope: .shared))
        let text = try await visibleText()
        XCTAssertTrue(text.contains("No Shared Albums"), text)
        XCTAssertTrue(text.contains("View All Albums"), text)
        XCTAssertFalse(text.contains("Create Album"), text)
        XCTAssertFalse(model.showCreateSheet)
        XCTAssertEqual(model.albums.map(\.id), ["personal"])
    }

    func testUnfilteredEmptyAlbumsStillOfferCreation() async throws {
        let model = AlbumListViewModel(repo: AlbumRepository(api: makeStubAPIClient()))
        let view = AlbumsListView(viewModel: model)
        try show(view.emptyState(model, scope: .all))
        let text = try await visibleText()
        XCTAssertTrue(text.contains("No Albums"), text)
        XCTAssertTrue(text.contains("Create Album"), text)
        XCTAssertFalse(text.contains("No Shared Albums"), text)
        XCTAssertFalse(text.contains("View All Albums"), text)
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

    private func searchedModel(nextPage: String? = "2") async throws -> (SearchViewModel, ControlledSearchRepository) {
        let api = makeStubAPIClient()
        let repository = ControlledSearchRepository(api: api)
        repositories.append(repository)
        let model = SearchViewModel(repo: repository, assetRepo: AssetDetailRepository(api: api),
            albumRepo: AlbumRepository(api: api))
        model.searchText = "mountains"
        let search = Task { await model.search() }
        _ = try await repository.probe.waitForRequest(0, testCase: self)
        try await repository.probe.succeed(0, ids: ["first"], total: nextPage == nil ? 1 : 2, nextPage: nextPage)
        await search.value
        return (model, repository)
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

private struct SearchPresentationFixture: View {
    let model: SearchViewModel
    @State private var isSelecting = false
    @State private var selectedIDs: Set<String> = []
    var body: some View {
        SearchView(isActive: false).results(model, isSelecting: $isSelecting, selectedIDs: $selectedIDs)
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
