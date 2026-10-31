import Observation
import SwiftData
import SwiftUI
import UIKit
import XCTest
@testable import ImmichApp

@MainActor
final class SearchPresentationTests: SimulatorHostedTestCase {
    private var fixture: WholeSearchFixture?
    private var hostState: WholeSearchHostState?
    private var suite = ""
    private var defaults: UserDefaults!
    private var directory: URL!
    private weak var fixtureManager: SwiftDataManager?
    private weak var fixtureModel: SearchViewModel?
    private weak var fixtureRecents: RecentlyViewedStore?
    private var fixtureContainer: ModelContainer?

    override func setUp() async throws {
        try await super.setUp()
        suite = "whole-search-presentation.\(UUID())"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        fixture?.search.finishAll()
        for window in windows { deactivateNativeSearch(in: window.rootViewController) }
        hostState?.content = nil
        try await waitUntil("Replacing the hosted content unmounts the native Search tabs") {
            self.windows.allSatisfy { self.tabController(in: $0.rootViewController) == nil }
        }
        try await super.tearDown()
        fixture?.releaseDependencies()
        fixture = nil
        hostState = nil
        try await waitUntil("The whole Search screen releases its model, recents and isolated store") {
            self.fixtureManager == nil && self.fixtureModel == nil && self.fixtureRecents == nil
        }
        if fixtureManager != nil {
            let attachment = XCTAttachment(string: "Search model retained: \(fixtureModel != nil); recents retained: \(fixtureRecents != nil); cache retained: \(fixtureManager != nil)")
            attachment.name = "Search owner lifetime"
            attachment.lifetime = .keepAlways
            add(attachment)
        }
        guard fixtureManager == nil else { return }
        try fixtureContainer?.erase()
        fixtureContainer = nil
        try FileManager.default.removeItem(at: directory)
        defaults.removePersistentDomain(forName: suite)
    }

    func testNativeSearchFieldLoadsTheActualGridAndClearingRejectsAHeldOldQuery() async throws {
        let fixture = try makeFixture(holdsResponses: true)
        let window = try await show(fixture)

        try await replaceQuery("mountains", in: window)

        try await waitUntil("Typing in the actual native search field starts its repository request") {
            fixture.search.requests.count == 1
        }
        let first = try XCTUnwrap(fixture.search.requests.first)
        XCTAssertEqual(first.request.query, "mountains")
        XCTAssertEqual(first.request.visibility, "timeline")
        fixture.search.finish(1, assets: [fixture.photo])
        try await waitUntil("The typed query's actual photo appears in the production grid") {
            self.grid(in: window.rootViewController)?.revealCell(for: fixture.photo.id) != nil
        }

        try await replaceQuery("waterfall", in: window)
        try await waitUntil("The next typed query is held in flight") { fixture.search.requests.count == 2 }
        XCTAssertEqual(fixture.search.requests.last?.request.query, "waterfall")
        try await replaceQuery("", in: window)
        try await waitUntil("Clearing the native field restores the empty-query state") {
            !fixture.model.hasCriteria && self.grid(in: window.rootViewController) == nil
        }
        fixture.search.finish(2, assets: [fixture.obsoletePhoto])
        try await waitUntil("The obsolete transport really returns after the native clear") {
            fixture.search.completed.contains(2)
        }
        _ = try await screenshot(window)
        XCTAssertTrue(fixture.model.results.isEmpty)
        XCTAssertEqual(try XCTUnwrap(searchField(in: window)).text, "")
        XCTAssertNil(grid(in: window.rootViewController))
        XCTAssertEqual(fixture.search.requests.count, 2, "Clearing all criteria must not fetch the whole library")
    }

    func testActualSuggestionsCreateNativeTokensAndDeletingOneKeepsTheOtherCriteria() async throws {
        let fixture = try makeFixture()
        let window = try await show(fixture)
        try await activateAccessibilityButton(named: "Paris", in: window)
        try await waitUntil("Choosing the actual place creates a native token and a filter-only request") {
            self.searchField(in: window)?.tokens.count == 1
                && fixture.search.requests.last?.request.city == "Paris"
        }
        XCTAssertNil(fixture.search.requests.last?.request.query)

        try await replaceQuery("Ada", in: window)
        try await activateAccessibilityButton(named: "Ada", in: window)

        try await waitUntil("The actual person suggestion consumes its name while preserving the city token") {
            self.searchField(in: window)?.tokens.count == 2
                && self.searchField(in: window)?.text?.isEmpty == true
                && fixture.search.requests.last?.request.personIds == [fixture.person.id]
                && fixture.search.requests.last?.request.query == nil
        }
        XCTAssertEqual(fixture.search.requests.last?.request.city, "Paris")
        XCTAssertEqual(fixture.model.filters.people.map(\.id), [fixture.person.id])
        let field = try XCTUnwrap(searchField(in: window))
        XCTAssertTrue(field.allowsDeletingTokens)
        let last = field.tokens.count - 1
        let start = field.positionOfToken(at: last)
        let range = try XCTUnwrap(field.textRange(from: start, to: field.textualRange.start))
        XCTAssertEqual(field.tokens(in: range).count, 1, "The native deletion must select one token, excluding the query")
        field.selectedTextRange = range
        field.deleteBackward()

        try await waitUntil("Deleting the actual last token updates the remaining filter request") {
            field.tokens.count == 1 && fixture.model.filters.city == nil
                && fixture.search.requests.last?.request.city == nil
                && fixture.search.requests.last?.request.personIds == [fixture.person.id]
        }
        XCTAssertEqual(fixture.model.filters.people.map(\.id), [fixture.person.id])
        XCTAssertNil(fixture.search.requests.last?.request.query)
    }

    func testCollectionsSegmentOpensTheMatchingAlbumAndClosePreservesNativeSearchCriteria() async throws {
        let fixture = try makeFixture()
        let window = try await show(fixture)
        try await activateAccessibilityButton(named: "Paris", in: window)
        try await waitUntil("The existing place criterion reaches the native field") { self.searchField(in: window)?.tokens.count == 1 }
        try await replaceQuery("Holiday", in: window)
        try await waitUntil("The matching album and query results are available") {
            fixture.model.matchingAlbums.map(\.id) == [fixture.album.id]
                && fixture.search.requests.last?.request.query == "Holiday"
        }
        searchField(in: window)?.resignFirstResponder()

        try await chooseSegment("Collections", in: window)
        try await waitUntil("The Collections control replaces the photo grid with its own result scroll view") {
            self.grid(in: window.rootViewController) == nil && self.collectionResults(in: window) != nil
                && self.searchField(in: window)?.isFirstResponder == false
        }
        let results = try XCTUnwrap(collectionResults(in: window))
        try await activateAccessibilityButton(named: fixture.album.albumName, in: window, within: results)

        var modal: UIViewController?
        try await waitUntil("The album result opens its actual modal navigation destination") {
            modal = self.searchPresentedControllers(in: window.rootViewController).first {
                !($0 is UISearchController) && (self.navigationTitles(in: $0).contains(fixture.album.albumName)
                    || self.searchContainsText(fixture.album.albumName, in: $0.view))
            }
            return modal != nil
        }
        if modal == nil { attachSearchPresentationState(window) }
        let presented = try XCTUnwrap(modal)
        try await activateAccessibilityButton(named: "Close", in: window, within: presented.view)
        try await waitUntil("Closing the destination returns to the same Search screen") {
            !self.searchPresentedControllers(in: window.rootViewController).contains { $0 === presented }
                && self.searchField(in: window)?.text == "Holiday"
        }
        XCTAssertEqual(searchField(in: window)?.tokens.count, 1)
        XCTAssertEqual(fixture.model.filters.city, "Paris")
        XCTAssertEqual(fixture.model.searchText, "Holiday")
        let control = try XCTUnwrap(segment(in: window))
        XCTAssertTrue(control.titleForSegment(at: control.selectedSegmentIndex)?.hasPrefix("Collections") == true)
    }

    func testClearingACollectionsQueryStartsTheNextDiscoverySearchInPhotos() async throws {
        let fixture = try makeFixture()
        let window = try await show(fixture)
        try await activateAccessibilityButton(named: "Paris", in: window)
        try await waitUntil("The native place token is present before the collection query") {
            self.searchField(in: window)?.tokens.count == 1
        }
        try await replaceQuery("Holiday", in: window)
        try await waitUntil("The initial query loads its matching album") {
            fixture.model.matchingAlbums.map(\.id) == [fixture.album.id]
                && self.grid(in: window.rootViewController)?.revealCell(for: fixture.photo.id) != nil
                && fixture.search.requests.last?.request.query == "Holiday"
        }
        searchField(in: window)?.resignFirstResponder()
        try await chooseSegment("Collections", in: window)
        try await waitUntil("The Collections result screen is visible") { self.collectionResults(in: window) != nil }

        let field = try XCTUnwrap(searchField(in: window))
        XCTAssertTrue(field.becomeFirstResponder())
        field.selectedTextRange = field.textRange(from: field.positionOfToken(at: 0), to: field.endOfDocument)
        field.deleteBackward()
        try await waitUntil("Clearing the full native query and tokens restores discovery") {
            !fixture.model.hasCriteria && self.segment(in: window) == nil && field.tokens.isEmpty && field.text?.isEmpty == true
        }
        try await activateAccessibilityButton(named: "Paris", in: window)

        try await waitUntil("The new place search displays its photo results") {
            self.grid(in: window.rootViewController)?.revealCell(for: fixture.photo.id) != nil
                && fixture.search.requests.last?.request.city == "Paris"
        }
        let control = try XCTUnwrap(segment(in: window))
        XCTAssertTrue(control.titleForSegment(at: control.selectedSegmentIndex)?.hasPrefix("Photos") == true)
        XCTAssertEqual(searchField(in: window)?.tokens.count, 1)
        XCTAssertNil(fixture.search.requests.last?.request.query)
        XCTAssertTrue(fixture.model.matchingAlbums.isEmpty)
    }

    func testActualSortAndFilterMenusChangeRequestsAndSelectionCanReturnToTheSameSearch() async throws {
        let fixture = try makeFixture()
        let window = try await show(fixture)
        try await replaceQuery("mountains", in: window)
        try await waitUntil("The real photo result is loaded before using its controls") {
            self.grid(in: window.rootViewController)?.revealCell(for: fixture.photo.id) != nil
        }
        searchField(in: window)?.resignFirstResponder()

        try await activateSearchMenuAction(named: "Sort by Recently Added", in: window)

        try await waitUntil("The actual sort option changes the search engine options") {
            fixture.search.requests.last?.options.sortOrder == .recentlyAdded
        }
        try await activateSearchMenuAction(named: "Favorites", in: window)
        try await waitUntil("The actual Favorites filter reaches the next request without losing the sort or query") {
            fixture.search.requests.last?.options.favoritesOnly == true
        }
        XCTAssertEqual(fixture.search.requests.last?.options.sortOrder, .recentlyAdded)
        XCTAssertEqual(fixture.search.requests.last?.request.query, "mountains")
        try await activateAccessibilityButton(named: "Select", in: window)
        var close: UIBarButtonItem?
        try await waitUntil("The actual selection toolbar exposes its own enabled Close action") {
            close = self.selectionClose(in: window.rootViewController)
            return close != nil
        }
        let item = try XCTUnwrap(close)
        XCTAssertTrue(UIApplication.shared.sendAction(try XCTUnwrap(item.action), to: item.target, from: item, for: nil))
        try await waitUntil("Closing selection restores the actual Select action and the native field") {
            self.searchField(in: window)?.text == "mountains"
                && self.segment(in: window) != nil
        }
        XCTAssertTrue(fixture.model.options.favoritesOnly)
        XCTAssertEqual(fixture.model.options.sortOrder, .recentlyAdded)
        XCTAssertEqual(fixture.model.searchText, "mountains")
    }

    private func makeFixture(holdsResponses: Bool = false) throws -> WholeSearchFixture {
        let manager = SwiftDataManager(storeURL: directory.appendingPathComponent("test.store"),
            backupJournalURL: directory.appendingPathComponent("backup.json"))
        fixtureManager = manager
        fixtureContainer = manager.modelContainer
        let api = makeStubAPIClient()
        let person = PersonDTO(id: UUID().uuidString, name: "Ada", birthDate: nil, thumbnailPath: nil, isHidden: false)
        let album = AlbumResponseDTO(id: UUID().uuidString, albumName: "Holiday", description: nil, assetCount: 0,
            albumThumbnailAssetId: nil, shared: false, createdAt: .distantPast, assets: nil)
        let photo = makeTestAsset(id: UUID().uuidString)
        let search = WholeSearchRepository(api: api, values: [photo], holdsResponses: holdsResponses)
        let model = SearchViewModel(repo: search, assetRepo: AssetDetailRepository(api: api, dataManager: manager),
            albumRepo: WholeSearchAlbumRepository(api: api, values: [album]),
            peopleRepo: WholeSearchPeopleRepository(api: api, values: [person]), dataManager: manager)
        let store = RecentlyViewedStore(owner: BackupQueueOwner(server: "https://search.example/api", userID: "user"),
            defaults: defaults, dataManager: manager)
        fixtureModel = model
        fixtureRecents = store
        let fixture = WholeSearchFixture(model: model, search: search, recents: store,
            person: person, album: album, photo: photo, obsoletePhoto: makeTestAsset(id: UUID().uuidString))
        self.fixture = fixture
        return fixture
    }

    private func show(_ fixture: WholeSearchFixture) async throws -> UIWindow {
        let state = WholeSearchHostState(AnyView(WholeSearchTestHost(model: fixture.model, recents: fixture.recents)))
        hostState = state
        let window = try await host(WholeSearchMountedHost(state: state))
        try await waitUntil("The whole Search screen mounts its native field and complete synthetic options") {
            self.searchField(in: window) != nil && fixture.model.hasLoadedOptions
        }
        return window
    }

    private func replaceQuery(_ text: String, in window: UIWindow) async throws {
        let field = try XCTUnwrap(searchField(in: window))
        XCTAssertTrue(field.becomeFirstResponder())
        // textualRange excludes native tokens; selecting the whole document would erase filters too.
        field.selectedTextRange = field.textualRange
        if text.isEmpty { field.deleteBackward() }
        else { field.insertText(text) }
        try await waitUntil("Native text input updates the SwiftUI query binding") { self.fixture?.model.searchText == text }
    }

    private func searchField(in view: UIView) -> UISearchTextField? {
        guard !view.isHidden, view.alpha > 0 else { return nil }
        if let field = view as? UISearchTextField { return field }
        return view.subviews.lazy.compactMap { self.searchField(in: $0) }.first
    }

    private func segment(in view: UIView) -> UISegmentedControl? {
        if let control = view as? UISegmentedControl,
           (0..<control.numberOfSegments).contains(where: { control.titleForSegment(at: $0)?.hasPrefix("Collections") == true }) {
            return control
        }
        return view.subviews.lazy.compactMap { self.segment(in: $0) }.first
    }

    private func collectionResults(in view: UIView) -> UIScrollView? {
        guard !view.isHidden, view.alpha > 0 else { return nil }
        if let scroll = view as? UIScrollView, !(scroll is UITableView), !(scroll is UICollectionView),
           searchContainsText("Albums", in: scroll) { return scroll }
        return view.subviews.lazy.compactMap { self.collectionResults(in: $0) }.first
    }

    private func chooseSegment(_ title: String, in window: UIWindow) async throws {
        try await waitUntil("The actual Photos/Collections segmented control is visible") { self.segment(in: window) != nil }
        let control = try XCTUnwrap(segment(in: window))
        let index = try XCTUnwrap((0..<control.numberOfSegments).first { control.titleForSegment(at: $0)?.hasPrefix(title) == true })
        XCTAssertTrue(control.isEnabled && control.isEnabledForSegment(at: index))
        control.selectedSegmentIndex = index
        control.sendActions(for: .valueChanged)
        try await waitUntil("The actual segmented control selects \(title)") { self.segment(in: window)?.selectedSegmentIndex == index }
    }

    private func grid(in controller: UIViewController?) -> PhotoGridController? {
        guard let controller else { return nil }
        if let grid = controller as? PhotoGridController { return grid }
        return controller.children.lazy.compactMap { self.grid(in: $0) }.first
    }

    private func navigationTitles(in controller: UIViewController) -> [String] {
        let own = (controller as? UINavigationController)?.viewControllers.compactMap(\.navigationItem.title) ?? []
        return own + controller.children.flatMap { navigationTitles(in: $0) }
    }

    private func selectionClose(in controller: UIViewController?) -> UIBarButtonItem? {
        guard let controller, !(controller is UISearchController) else { return nil }
        let navigation = controller.navigationItem
        let own = (navigation.rightBarButtonItems ?? []) + navigation.trailingItemGroups.flatMap(\.barButtonItems)
        if let close = own.first(where: { ($0.accessibilityLabel == "Close" || $0.title == "Close") && $0.isEnabled }) { return close }
        return controller.children.lazy.compactMap { self.selectionClose(in: $0) }.first
    }

    private func tabController(in controller: UIViewController?) -> UITabBarController? {
        guard let controller else { return nil }
        if let tabs = controller as? UITabBarController { return tabs }
        return controller.children.lazy.compactMap { self.tabController(in: $0) }.first
    }
}

@MainActor
@Observable
private final class WholeSearchHostState {
    var content: AnyView?
    init(_ content: AnyView) { self.content = content }
}

private struct WholeSearchMountedHost: View {
    let state: WholeSearchHostState
    var body: some View {
        if let content = state.content { content }
        else { Color.clear }
    }
}

private struct WholeSearchTestHost: View {
    let model: SearchViewModel
    let recents: RecentlyViewedStore
    @State private var selection = 1

    var body: some View {
        TabView(selection: $selection) {
            Tab("Library", systemImage: "photo", value: 0) { Color.clear }
            Tab(value: 1, role: .search) { SearchView(isActive: true, viewModel: model, recentlyViewedStore: recents) }
        }
    }
}

@MainActor
private final class WholeSearchFixture {
    private var dependencies: (model: SearchViewModel, search: WholeSearchRepository, recents: RecentlyViewedStore)?
    var model: SearchViewModel { dependencies!.model }
    var search: WholeSearchRepository { dependencies!.search }
    var recents: RecentlyViewedStore { dependencies!.recents }
    let person: PersonDTO
    let album: AlbumResponseDTO
    let photo: AssetResponseDTO
    let obsoletePhoto: AssetResponseDTO

    init(model: SearchViewModel, search: WholeSearchRepository, recents: RecentlyViewedStore,
         person: PersonDTO, album: AlbumResponseDTO, photo: AssetResponseDTO, obsoletePhoto: AssetResponseDTO) {
        dependencies = (model, search, recents)
        self.person = person
        self.album = album
        self.photo = photo
        self.obsoletePhoto = obsoletePhoto
    }

    func releaseDependencies() { dependencies = nil }
}

@MainActor
private final class WholeSearchRepository: SearchRepository {
    struct Request { let request: SearchRequestDTO; let options: PhotoSearchOptions }
    private(set) var requests: [Request] = []
    private(set) var completed: Set<Int> = []
    private let values: [AssetResponseDTO]
    private let holdsResponses: Bool
    private var pending: [Int: CheckedContinuation<SearchResponseDTO, Error>] = [:]

    init(api: APIClient, values: [AssetResponseDTO], holdsResponses: Bool) {
        self.values = values
        self.holdsResponses = holdsResponses
        super.init(api: api)
    }

    override func search(_ request: SearchRequestDTO, options: PhotoSearchOptions = .init()) async throws -> SearchResponseDTO {
        requests.append(Request(request: request, options: options))
        let requestID = requests.count
        defer { completed.insert(requestID) }
        if holdsResponses { return try await withCheckedThrowingContinuation { pending[requestID] = $0 } }
        return SearchResponseDTO(assets: .init(items: values, total: values.count, nextPage: nil))
    }

    override func suggestions(type: String = "city") async throws -> [String] { type == "city" ? ["Paris"] : [] }

    func finish(_ request: Int, assets: [AssetResponseDTO]) {
        guard let continuation = pending.removeValue(forKey: request) else { return XCTFail("The held native-search request must exist") }
        continuation.resume(returning: SearchResponseDTO(assets: .init(items: assets, total: assets.count, nextPage: nil)))
    }

    func finishAll() {
        for continuation in pending.values { continuation.resume(throwing: CancellationError()) }
        pending.removeAll()
    }
}

@MainActor
private final class WholeSearchPeopleRepository: PeopleRepository {
    let values: [PersonDTO]
    init(api: APIClient, values: [PersonDTO]) { self.values = values; super.init(api: api) }
    override func all(size: Int? = nil) async throws -> [PersonDTO] { values }
}

@MainActor
private final class WholeSearchAlbumRepository: AlbumRepository {
    let values: [AlbumResponseDTO]
    init(api: APIClient, values: [AlbumResponseDTO]) { self.values = values; super.init(api: api) }
    override func all() async throws -> [AlbumResponseDTO] { values }
}
