import Observation
import XCTest
@testable import ImmichApp

@MainActor
final class SearchRequestLifecycleTests: XCTestCase {
    private var fixtures: [(SearchViewModel, ControlledSearchRepository)] = []

    override func tearDown() async throws {
        for (model, repository) in fixtures {
            model.searchText = ""
            model.filters = SearchFilters()
            model.scheduleSearch()
            await repository.probe.cancelAll()
        }
        fixtures.removeAll()
        try await super.tearDown()
    }

    func testClearingCriteriaImmediatelyResetsPaginationAndRejectsTheLatePage() async throws {
        let (model, repository) = fixture()
        try await loadFirstPage(model, repository: repository)
        let page = Task { await model.loadMore() }
        _ = try await repository.probe.waitForRequest(1, testCase: self)
        XCTAssertTrue(model.isLoadingMore)

        model.searchText = ""
        model.scheduleSearch()

        assertReset(model)
        try await repository.probe.succeed(1, ids: ["late-old-page"], total: 9, nextPage: "3")
        await page.value
        assertReset(model)
    }

    func testNewCriteriaRejectTheOldPageBeforeTheDebounceRuns() async throws {
        let (model, repository) = fixture()
        try await loadFirstPage(model, repository: repository)
        let oldPage = Task { await model.loadMore() }
        _ = try await repository.probe.waitForRequest(1, testCase: self)

        model.searchText = "new query"
        model.filters.city = "Kyoto"
        model.scheduleSearch()

        XCTAssertTrue(model.results.isEmpty)
        XCTAssertEqual(model.totalResults, 0)
        XCTAssertNil(model.nextPage)
        XCTAssertFalse(model.isLoadingMore)
        assertLoading(model)
        try await repository.probe.succeed(1, ids: ["late-old-page"], total: 9, nextPage: "3")
        await oldPage.value
        XCTAssertTrue(model.results.isEmpty)
        XCTAssertNil(model.nextPage)
        let fresh = try await repository.probe.waitForRequest(2, testCase: self)
        XCTAssertEqual(fresh.request.query, "new query")
        XCTAssertEqual(fresh.request.city, "Kyoto")
        XCTAssertEqual(fresh.request.page, 1)
        try await finishScheduledSearch(model, repository: repository, index: 2, ids: ["new-result"])
        XCTAssertEqual(model.results.map(\.id), ["new-result"])
        XCTAssertEqual(model.totalResults, 1)
        assertLoaded(model)
    }

    func testAnOlderFirstPageCannotOverwriteANewerResultEvenForTheSameQuery() async throws {
        for changeQuery in [false, true] {
            let (model, repository) = fixture()
            let old = Task { await model.search() }
            _ = try await repository.probe.waitForRequest(0, testCase: self)
            if changeQuery { model.searchText = "different query" }
            let fresh = Task { await model.search() }
            _ = try await repository.probe.waitForRequest(1, testCase: self)
            try await repository.probe.succeed(1, ids: ["fresh"], total: 4, nextPage: "2")
            await fresh.value

            try await repository.probe.succeed(0, ids: ["stale"], total: 90, nextPage: "7")
            await old.value

            XCTAssertEqual(model.results.map(\.id), ["fresh"])
            XCTAssertEqual(model.totalResults, 4)
            XCTAssertEqual(model.currentPage, 1)
            XCTAssertEqual(model.nextPage, "2")
            XCTAssertNil(model.paginationError)
            assertLoaded(model)
        }
    }

    func testAnOlderFirstPageErrorCannotReplaceTheNewerLoadedResults() async throws {
        let (model, repository) = fixture()
        let old = Task { await model.search() }
        _ = try await repository.probe.waitForRequest(0, testCase: self)
        model.searchText = "new query"
        let fresh = Task { await model.search() }
        _ = try await repository.probe.waitForRequest(1, testCase: self)
        try await repository.probe.succeed(1, ids: ["fresh"], total: 1)
        await fresh.value

        try await repository.probe.fail(0, error: APIError.server(status: 500, message: "Old request failed"))
        await old.value

        XCTAssertEqual(model.results.map(\.id), ["fresh"])
        XCTAssertEqual(model.totalResults, 1)
        XCTAssertNil(model.nextPage)
        assertLoaded(model)
    }

    func testClearingCriteriaRejectsLateFirstPageSuccessAndFailure() async throws {
        for succeeds in [false, true] {
            let (model, repository) = fixture()
            let search = Task { await model.search() }
            _ = try await repository.probe.waitForRequest(0, testCase: self)
            model.searchText = ""
            model.scheduleSearch()
            assertReset(model)

            if succeeds {
                try await repository.probe.succeed(0, ids: ["stale"], total: 8, nextPage: "2")
            } else {
                try await repository.probe.fail(0, error: APIError.server(status: 500, message: "Stale error"))
            }
            await search.value
            assertReset(model)
        }
    }

    func testStaleCancellationCannotResetTheNewerSearch() async throws {
        let (model, repository) = fixture()
        let old = Task { await model.search() }
        _ = try await repository.probe.waitForRequest(0, testCase: self)
        model.searchText = "new query"
        let fresh = Task { await model.search() }
        _ = try await repository.probe.waitForRequest(1, testCase: self)

        try await repository.probe.fail(0, error: CancellationError())
        await old.value

        assertLoading(model)
        XCTAssertTrue(model.results.isEmpty)
        try await repository.probe.succeed(1, ids: ["fresh"], total: 1)
        await fresh.value
        XCTAssertEqual(model.results.map(\.id), ["fresh"])
        assertLoaded(model)
    }

    func testCanceledCurrentSearchIgnoresALateResponseAndCanRetry() async throws {
        let (model, repository) = fixture()
        let canceled = Task { await model.search() }
        _ = try await repository.probe.waitForRequest(0, testCase: self)
        canceled.cancel()
        try await repository.probe.succeed(0, ids: ["canceled"], total: 9, nextPage: "2")
        await canceled.value
        assertReset(model)

        let retried = Task { await model.search() }
        let retry = try await repository.probe.waitForRequest(1, testCase: self)
        XCTAssertEqual(retry.request.query, "original query")
        XCTAssertEqual(retry.request.page, 1)
        try await repository.probe.succeed(1, ids: ["retried"], total: 1)
        await retried.value
        XCTAssertEqual(model.results.map(\.id), ["retried"])
        assertLoaded(model)
    }

    func testAlreadyCanceledSearchReturnsToIdleWithoutSendingARequest() async {
        let (model, repository) = fixture()
        let completed = XCTestExpectation(description: "Already-canceled search returned")
        let canceled = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            await model.search()
            completed.fulfill()
        }

        await fulfillment(of: [completed], timeout: 2)
        let requests = await repository.probe.requests
        XCTAssertTrue(requests.isEmpty)
        await repository.probe.cancelAll()
        await canceled.value
        assertReset(model)
    }

    func testDirectSearchCancelsTheQueuedDebouncedSearch() async throws {
        let (model, repository) = fixture()
        model.scheduleSearch()
        let direct = Task { await model.search() }
        _ = try await repository.probe.waitForRequest(0, testCase: self)
        try await repository.probe.succeed(0, ids: ["direct"], total: 1)
        await direct.value
        let duplicate = XCTestExpectation(description: "Canceled debounce must not issue another search")
        duplicate.isInverted = true
        await repository.probe.observe(1, expectation: duplicate)

        await fulfillment(of: [duplicate], timeout: 0.5)

        let requests = await repository.probe.requests
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(model.results.map(\.id), ["direct"])
        assertLoaded(model)
    }

    func testScheduledSearchUsesTheCriteriaCapturedWhenItWasScheduled() async throws {
        let (model, repository) = fixture()
        model.searchText = "  mountains  "
        model.filters.city = "Paris"
        model.filters.mediaType = .video
        model.scheduleSearch()
        model.searchText = "changed without scheduling"
        model.filters.city = "London"
        model.filters.mediaType = .image

        let request = try await repository.probe.waitForRequest(0, testCase: self)

        XCTAssertEqual(request.endpoint, .smart)
        XCTAssertEqual(request.request.query, "mountains")
        XCTAssertEqual(request.request.city, "Paris")
        XCTAssertEqual(request.request.type, "VIDEO")
        XCTAssertEqual(request.request.page, 1)
        try await finishScheduledSearch(model, repository: repository, index: 0, ids: ["mountain"])
        XCTAssertEqual(model.results.map(\.id), ["mountain"])
        assertLoaded(model)
    }

    func testPaginationReusesTheOriginalQueryAndEveryFilter() async throws {
        let (model, repository) = fixture()
        model.searchText = "  mountains  "
        model.filters.city = "Paris"
        model.filters.mediaType = .video
        model.filters.people = [PersonDTO(id: "person-a", name: "A", birthDate: nil, thumbnailPath: nil, isHidden: false)]
        model.filters.dateRange = .year(2024)
        let first = Task { await model.search() }
        let original = try await repository.probe.waitForRequest(0, testCase: self)
        try await repository.probe.succeed(0, ids: ["first"], total: 2, nextPage: "2")
        await first.value
        model.searchText = ""
        model.filters.city = "London"
        model.filters.mediaType = .image
        model.filters.people = []
        model.filters.dateRange = .lastMonth

        let page = Task { await model.loadMore() }
        let subsequent = try await repository.probe.waitForRequest(1, testCase: self)

        XCTAssertEqual(subsequent.endpoint, .smart)
        XCTAssertEqual(subsequent.request.query, "mountains")
        XCTAssertEqual(subsequent.request.city, "Paris")
        XCTAssertEqual(subsequent.request.type, "VIDEO")
        XCTAssertEqual(subsequent.request.personIds, ["person-a"])
        XCTAssertEqual(subsequent.request.takenAfter, original.request.takenAfter)
        XCTAssertEqual(subsequent.request.takenBefore, original.request.takenBefore)
        XCTAssertEqual(subsequent.request.size, original.request.size)
        XCTAssertEqual(subsequent.request.withExif, original.request.withExif)
        XCTAssertEqual(subsequent.request.page, 2)
        try await repository.probe.succeed(1, ids: ["second"], total: 2)
        await page.value
        XCTAssertEqual(model.results.map(\.id), ["first", "second"])
        assertLoaded(model)
    }

    func testFilterOnlyPaginationKeepsItsMetadataEndpointAndOriginalFilters() async throws {
        let (model, repository) = fixture()
        model.searchText = ""
        model.filters.city = "Kyoto"
        model.filters.mediaType = .video
        model.filters.dateRange = .year(2020)
        let first = Task { await model.search() }
        let original = try await repository.probe.waitForRequest(0, testCase: self)
        XCTAssertEqual(original.endpoint, .metadata)
        XCTAssertNil(original.request.query)
        XCTAssertEqual(original.request.city, "Kyoto")
        XCTAssertEqual(original.request.type, "VIDEO")
        try await repository.probe.succeed(0, ids: ["metadata-first"], total: 2, nextPage: "2")
        await first.value
        model.searchText = "typed after the request"
        model.filters.city = "Paris"
        model.filters.mediaType = .image
        model.filters.dateRange = .lastMonth

        let page = Task { await model.loadMore() }
        let subsequent = try await repository.probe.waitForRequest(1, testCase: self)

        XCTAssertEqual(subsequent.endpoint, .metadata)
        XCTAssertNil(subsequent.request.query)
        XCTAssertEqual(subsequent.request.city, "Kyoto")
        XCTAssertEqual(subsequent.request.type, "VIDEO")
        XCTAssertEqual(subsequent.request.takenAfter, original.request.takenAfter)
        XCTAssertEqual(subsequent.request.takenBefore, original.request.takenBefore)
        XCTAssertEqual(subsequent.request.page, 2)
        try await repository.probe.succeed(1, ids: ["metadata-second"], total: 2)
        await page.value
        XCTAssertEqual(model.results.map(\.id), ["metadata-first", "metadata-second"])
        XCTAssertEqual(model.totalResults, 2)
        assertLoaded(model)
    }

    func testSearchingWithoutCriteriaClearsLoadedResultsWithoutAnotherRequest() async throws {
        let (model, repository) = fixture()
        try await loadFirstPage(model, repository: repository)
        model.searchText = "  "
        model.filters = SearchFilters()

        await model.search()

        assertReset(model)
        let requests = await repository.probe.requests
        XCTAssertEqual(requests.count, 1)
    }

    func testAnEmptyTerminalResponseIsASuccessfulSearchWithNoResults() async throws {
        let (model, repository) = fixture()
        let search = Task { await model.search() }
        _ = try await repository.probe.waitForRequest(0, testCase: self)
        try await repository.probe.succeed(0, ids: [], total: 0)

        await search.value

        XCTAssertTrue(model.results.isEmpty)
        XCTAssertEqual(model.totalResults, 0)
        XCTAssertNil(model.nextPage)
        XCTAssertNil(model.paginationError)
        XCTAssertFalse(model.isLoadingMore)
        assertLoaded(model)
    }

    func testRejectedFirstPagesShowTheirActualFailureAndCanRetryFromPageOne() async throws {
        let cases: [(ids: [String], nextPage: String?, transportFailure: Bool)] = [
            (["invalid-cursor"], "not-a-page", false),
            (["nonadvancing-cursor"], "1", false),
            ([], "2", false),
            ([], nil, true),
        ]
        for item in cases {
            let (model, repository) = fixture()
            let failed = Task { await model.search() }
            _ = try await repository.probe.waitForRequest(0, testCase: self)
            if item.transportFailure {
                try await repository.probe.fail(0, error: APIError.server(status: 503, message: "Search unavailable"))
            } else {
                try await repository.probe.succeed(0, ids: item.ids, total: 8, nextPage: item.nextPage)
            }
            await failed.value
            let expected = item.transportFailure ? "Search unavailable"
                : String(localized: "Search returned an incomplete page. Please try again.")
            if case .failed(let message) = model.phase {
                XCTAssertEqual(message, expected)
            } else {
                XCTFail("A rejected first page must show its failure")
            }
            XCTAssertTrue(model.results.isEmpty)
            XCTAssertEqual(model.totalResults, 0)
            XCTAssertEqual(model.currentPage, 1)
            XCTAssertNil(model.nextPage)
            XCTAssertNil(model.paginationError)
            XCTAssertFalse(model.isLoadingMore)

            let retried = Task { await model.search() }
            let request = try await repository.probe.waitForRequest(1, testCase: self)
            XCTAssertEqual(request.request.page, 1)
            try await repository.probe.succeed(1, ids: ["retried"], total: 1)
            await retried.value
            XCTAssertEqual(model.results.map(\.id), ["retried"])
            XCTAssertEqual(model.totalResults, 1)
            assertLoaded(model)
        }
    }

    private func fixture() -> (SearchViewModel, ControlledSearchRepository) {
        let api = makeStubAPIClient()
        let repository = ControlledSearchRepository(api: api)
        let model = SearchViewModel(
            repo: repository, assetRepo: AssetDetailRepository(api: api), albumRepo: AlbumRepository(api: api))
        model.searchText = "original query"
        fixtures.append((model, repository))
        return (model, repository)
    }

    private func loadFirstPage(_ model: SearchViewModel, repository: ControlledSearchRepository) async throws {
        let search = Task { await model.search() }
        _ = try await repository.probe.waitForRequest(0, testCase: self)
        try await repository.probe.succeed(0, ids: ["first"], total: 3, nextPage: "2")
        await search.value
        XCTAssertEqual(model.results.map(\.id), ["first"])
        XCTAssertEqual(model.nextPage, "2")
        assertLoaded(model)
    }

    private func finishScheduledSearch(
        _ model: SearchViewModel, repository: ControlledSearchRepository, index: Int, ids: [String]
    ) async throws {
        let changed = XCTestExpectation(description: "Scheduled search publishes its response")
        withObservationTracking { _ = model.phase } onChange: { changed.fulfill() }
        try await repository.probe.succeed(index, ids: ids, total: ids.count)
        await fulfillment(of: [changed], timeout: 2)
    }

    private func assertReset(_ model: SearchViewModel, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(model.results.isEmpty, file: file, line: line)
        XCTAssertEqual(model.totalResults, 0, file: file, line: line)
        XCTAssertEqual(model.currentPage, 1, file: file, line: line)
        XCTAssertNil(model.nextPage, file: file, line: line)
        XCTAssertFalse(model.isLoadingMore, file: file, line: line)
        XCTAssertNil(model.paginationError, file: file, line: line)
        guard case .idle = model.phase else { return XCTFail("Expected an idle reset", file: file, line: line) }
    }

    private func assertLoaded(_ model: SearchViewModel, file: StaticString = #filePath, line: UInt = #line) {
        guard case .loaded = model.phase else { return XCTFail("Expected loaded results", file: file, line: line) }
    }

    private func assertLoading(_ model: SearchViewModel, file: StaticString = #filePath, line: UInt = #line) {
        guard case .loading = model.phase else { return XCTFail("Expected the active search to remain loading", file: file, line: line) }
    }
}
