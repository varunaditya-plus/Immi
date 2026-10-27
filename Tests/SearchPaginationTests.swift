import XCTest
@testable import ImmichApp

@MainActor
final class SearchPaginationTests: XCTestCase {
    private var repositories: [ControlledSearchRepository] = []

    override func tearDown() async throws {
        for repository in repositories { await repository.probe.cancelAll() }
        repositories.removeAll()
        try await super.tearDown()
    }

    func testSuccessfulPageUsesTheServerContinuationAndFinishesLoading() async throws {
        let (model, repository) = try await loadedModel(nextPage: "3")
        let task = Task { await model.loadMore() }
        let request = try await repository.probe.waitForRequest(1, testCase: self)
        XCTAssertEqual(request.request.page, 3)
        XCTAssertEqual(request.request.query, "mountains")
        XCTAssertTrue(model.isLoadingMore)
        XCTAssertEqual(model.results.map(\.id), ["a", "b"])

        try await repository.probe.succeed(1, ids: ["c", "d"], total: 4, nextPage: nil)
        await task.value

        XCTAssertEqual(model.results.map(\.id), ["a", "b", "c", "d"])
        XCTAssertEqual(model.totalResults, 4)
        XCTAssertEqual(model.currentPage, 3)
        XCTAssertNil(model.nextPage)
        XCTAssertFalse(model.isLoadingMore)
        XCTAssertNil(model.paginationError)
        assertLoaded(model)
    }

    func testRepeatedReachEndEventsShareOnePendingPageRequest() async throws {
        let (model, repository) = try await loadedModel()
        let task = Task { await model.loadMore() }
        _ = try await repository.probe.waitForRequest(1, testCase: self)

        guard await assertIgnoredLoadMore(model, repository: repository, requestCount: 2) else { return }
        guard await assertIgnoredLoadMore(model, repository: repository, requestCount: 2) else { return }

        let pendingRequests = await repository.probe.requests
        XCTAssertEqual(pendingRequests.count, 2)
        XCTAssertTrue(model.isLoadingMore)
        try await repository.probe.succeed(1, ids: ["c", "d"], total: 4, nextPage: nil)
        await task.value
        guard await assertIgnoredLoadMore(model, repository: repository, requestCount: 2) else { return }
        let completedRequests = await repository.probe.requests
        XCTAssertEqual(completedRequests.count, 2)
        XCTAssertEqual(model.results.map(\.id), ["a", "b", "c", "d"])
    }

    func testPageFailureKeepsResultsAndRequiresExplicitRetryOfTheSamePage() async throws {
        let (model, repository) = try await loadedModel()
        let task = Task { await model.loadMore() }
        _ = try await repository.probe.waitForRequest(1, testCase: self)
        try await repository.probe.fail(1, error: APIError.server(status: 503, message: "Page unavailable"))
        await task.value

        XCTAssertEqual(model.results.map(\.id), ["a", "b"])
        XCTAssertEqual(model.totalResults, 4)
        XCTAssertEqual(model.currentPage, 1)
        XCTAssertEqual(model.nextPage, "2")
        XCTAssertEqual(model.paginationError, "Page unavailable")
        XCTAssertFalse(model.isLoadingMore)
        assertLoaded(model)
        guard await assertIgnoredLoadMore(model, repository: repository, requestCount: 2) else { return }
        let failedRequests = await repository.probe.requests
        XCTAssertEqual(failedRequests.count, 2, "Prefetch must not repeatedly retry a failed page")

        let retry = Task { await model.retryLoadMore() }
        let retried = try await repository.probe.waitForRequest(2, testCase: self)
        XCTAssertEqual(retried.request.page, 2)
        XCTAssertEqual(retried.request.query, "mountains")
        XCTAssertTrue(model.isLoadingMore)
        try await repository.probe.succeed(2, ids: ["c", "d"], total: 4, nextPage: nil)
        await retry.value

        XCTAssertEqual(model.results.map(\.id), ["a", "b", "c", "d"])
        XCTAssertNil(model.paginationError)
        XCTAssertNil(model.nextPage)
        XCTAssertFalse(model.isLoadingMore)
        assertLoaded(model)
    }

    func testFailedRetryKeepsTheSameContinuationAndUpdatesFailureFeedback() async throws {
        let (model, repository) = try await loadedModel()
        let task = Task { await model.loadMore() }
        _ = try await repository.probe.waitForRequest(1, testCase: self)
        try await repository.probe.fail(1, error: APIError.server(status: 503, message: "First failure"))
        await task.value

        let retry = Task { await model.retryLoadMore() }
        let request = try await repository.probe.waitForRequest(2, testCase: self)
        XCTAssertEqual(request.request.page, 2)
        try await repository.probe.fail(2, error: APIError.server(status: 503, message: "Still unavailable"))
        await retry.value

        XCTAssertEqual(model.results.map(\.id), ["a", "b"])
        XCTAssertEqual(model.currentPage, 1)
        XCTAssertEqual(model.nextPage, "2")
        XCTAssertEqual(model.paginationError, "Still unavailable")
        XCTAssertFalse(model.isLoadingMore)
        assertLoaded(model)
    }

    func testCanceledPageIgnoresALateResponseAndAllowsAnotherAttempt() async throws {
        let (model, repository) = try await loadedModel()
        let task = Task { await model.loadMore() }
        _ = try await repository.probe.waitForRequest(1, testCase: self)
        task.cancel()
        try await repository.probe.succeed(1, ids: ["c"], total: 4, nextPage: "3")
        await task.value

        XCTAssertEqual(model.results.map(\.id), ["a", "b"])
        XCTAssertEqual(model.currentPage, 1)
        XCTAssertEqual(model.nextPage, "2")
        XCTAssertNil(model.paginationError)
        XCTAssertFalse(model.isLoadingMore)
        let retry = Task { await model.loadMore() }
        let request = try await repository.probe.waitForRequest(2, testCase: self)
        XCTAssertEqual(request.request.page, 2)
        try await repository.probe.succeed(2, ids: ["c", "d"], total: 4, nextPage: nil)
        await retry.value
        XCTAssertEqual(model.results.map(\.id), ["a", "b", "c", "d"])
        assertLoaded(model)
    }

    func testAlreadyCanceledPageTaskDoesNotSendARequestOrLeaveLoadingState() async throws {
        let (model, repository) = try await loadedModel()
        let completed = XCTestExpectation(description: "Canceled page task returned")
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            await model.loadMore()
            completed.fulfill()
        }
        await fulfillment(of: [completed], timeout: 2)
        let requests = await repository.probe.requests
        XCTAssertEqual(requests.count, 1)
        await repository.probe.cancelAll()
        await task.value

        XCTAssertEqual(model.results.map(\.id), ["a", "b"])
        XCTAssertEqual(model.currentPage, 1)
        XCTAssertEqual(model.nextPage, "2")
        XCTAssertFalse(model.isLoadingMore)
        XCTAssertNil(model.paginationError)
        assertLoaded(model)
    }

    func testOldPageSuccessCannotChangeOrUnlockANewerPendingPage() async throws {
        try await assertStaleCompletion(fails: false)
    }

    func testOldPageFailureCannotPublishAnErrorOrUnlockANewerPendingPage() async throws {
        try await assertStaleCompletion(fails: true)
    }

    func testDuplicateIDsAreRemovedWithinAndAcrossPages() async throws {
        let (model, repository) = try await loadedModel(firstIDs: ["a", "a", "b"])
        XCTAssertEqual(model.results.map(\.id), ["a", "b"])
        let task = Task { await model.loadMore() }
        _ = try await repository.probe.waitForRequest(1, testCase: self)
        try await repository.probe.succeed(1, ids: ["b", "c", "c", "d", "a"], total: 4, nextPage: nil)
        await task.value

        XCTAssertEqual(model.results.map(\.id), ["a", "b", "c", "d"])
        XCTAssertNil(model.paginationError)
        XCTAssertFalse(model.isLoadingMore)
    }

    func testPageLocalTotalCannotBeSmallerThanTheMergedResults() async throws {
        let (model, repository) = try await loadedModel(firstTotal: 2)
        XCTAssertEqual(model.totalResults, 2)
        let task = Task { await model.loadMore() }
        _ = try await repository.probe.waitForRequest(1, testCase: self)
        try await repository.probe.succeed(1, ids: ["c", "d"], total: 2, nextPage: "3")
        await task.value

        XCTAssertEqual(model.results.map(\.id), ["a", "b", "c", "d"])
        XCTAssertEqual(model.totalResults, 4)
        XCTAssertEqual(model.nextPage, "3")
        XCTAssertNil(model.paginationError)
        assertLoaded(model)
    }

    func testDuplicateOnlyPageCanAdvanceToALaterPageWithNewResults() async throws {
        let (model, repository) = try await loadedModel()
        let secondPage = Task { await model.loadMore() }
        _ = try await repository.probe.waitForRequest(1, testCase: self)
        try await repository.probe.succeed(1, ids: ["a", "b", "a"], total: 2, nextPage: "3")
        await secondPage.value
        XCTAssertEqual(model.results.map(\.id), ["a", "b"])
        XCTAssertEqual(model.currentPage, 2)
        XCTAssertEqual(model.nextPage, "3")
        XCTAssertNil(model.paginationError)

        let thirdPage = Task { await model.loadMore() }
        let request = try await repository.probe.waitForRequest(2, testCase: self)
        XCTAssertEqual(request.request.page, 3)
        try await repository.probe.succeed(2, ids: ["c", "d"], total: 2, nextPage: nil)
        await thirdPage.value

        XCTAssertEqual(model.results.map(\.id), ["a", "b", "c", "d"])
        XCTAssertEqual(model.totalResults, 4)
        XCTAssertNil(model.nextPage)
        XCTAssertNil(model.paginationError)
        assertLoaded(model)
    }

    func testInvalidReturnedContinuationKeepsTheLastAcceptedPageAndCanRetry() async throws {
        for invalid in ["not-a-page", "0", "-2", "1", "2"] {
            let (model, repository) = try await loadedModel()
            let task = Task { await model.loadMore() }
            _ = try await repository.probe.waitForRequest(1, testCase: self)
            try await repository.probe.succeed(1, ids: ["c"], total: 4, nextPage: invalid)
            await task.value

            XCTAssertEqual(model.results.map(\.id), ["a", "b"], "Invalid cursor: \(invalid)")
            XCTAssertEqual(model.currentPage, 1)
            XCTAssertEqual(model.nextPage, "2")
            XCTAssertEqual(model.paginationError,
                String(localized: "Search returned an incomplete page. Please try again."))
            XCTAssertFalse(model.isLoadingMore)
            assertLoaded(model)
            let retry = Task { await model.retryLoadMore() }
            let request = try await repository.probe.waitForRequest(2, testCase: self)
            XCTAssertEqual(request.request.page, 2)
            try await repository.probe.succeed(2, ids: ["c", "d"], total: 4, nextPage: nil)
            await retry.value
            XCTAssertEqual(model.results.map(\.id), ["a", "b", "c", "d"])
            XCTAssertNil(model.paginationError)
        }
    }

    func testEmptyPageWithMoreResultsReportsFailureInsteadOfAdvancing() async throws {
        let (model, repository) = try await loadedModel()
        let task = Task { await model.loadMore() }
        _ = try await repository.probe.waitForRequest(1, testCase: self)
        try await repository.probe.succeed(1, ids: [], total: 4, nextPage: "3")
        await task.value

        XCTAssertEqual(model.results.map(\.id), ["a", "b"])
        XCTAssertEqual(model.currentPage, 1)
        XCTAssertEqual(model.nextPage, "2")
        XCTAssertEqual(model.paginationError,
            String(localized: "Search returned an incomplete page. Please try again."))
        XCTAssertFalse(model.isLoadingMore)
        assertLoaded(model)
    }

    func testEmptyTerminalPageEndsPaginationWithoutAnError() async throws {
        let (model, repository) = try await loadedModel(firstTotal: 99)
        let task = Task { await model.loadMore() }
        _ = try await repository.probe.waitForRequest(1, testCase: self)
        try await repository.probe.succeed(1, ids: [], total: 2, nextPage: nil)
        await task.value

        XCTAssertEqual(model.results.map(\.id), ["a", "b"])
        XCTAssertEqual(model.totalResults, 2, "The terminal page establishes the complete unique result count")
        XCTAssertEqual(model.currentPage, 2)
        XCTAssertNil(model.nextPage)
        XCTAssertNil(model.paginationError)
        XCTAssertFalse(model.isLoadingMore)
        assertLoaded(model)
    }

    private func assertStaleCompletion(fails: Bool) async throws {
        let (model, repository) = try await loadedModel()
        let oldPage = Task { await model.loadMore() }
        _ = try await repository.probe.waitForRequest(1, testCase: self)
        model.searchText = "beach"
        let newSearch = Task { await model.search() }
        let searchRequest = try await repository.probe.waitForRequest(2, testCase: self)
        XCTAssertEqual(searchRequest.request.query, "beach")
        try await repository.probe.succeed(2, ids: ["new-a"], total: 2, nextPage: "2")
        await newSearch.value
        XCTAssertFalse(model.isLoadingMore)
        let newPage = Task { await model.loadMore() }
        let pageRequest = try await repository.probe.waitForRequest(3, testCase: self)
        XCTAssertEqual(pageRequest.request.query, "beach")
        XCTAssertEqual(pageRequest.request.page, 2)
        XCTAssertTrue(model.isLoadingMore)

        if fails {
            try await repository.probe.fail(1, error: APIError.server(status: 503, message: "Old page failure"))
        } else {
            try await repository.probe.succeed(1, ids: ["old-c"], total: 4, nextPage: "3")
        }
        await oldPage.value

        XCTAssertEqual(model.results.map(\.id), ["new-a"])
        XCTAssertEqual(model.currentPage, 1)
        XCTAssertEqual(model.nextPage, "2")
        XCTAssertNil(model.paginationError)
        XCTAssertTrue(model.isLoadingMore, "Finishing an old request must not release the newer request's loader")
        guard await assertIgnoredLoadMore(model, repository: repository, requestCount: 4) else { return }
        let requests = await repository.probe.requests
        XCTAssertEqual(requests.count, 4)
        try await repository.probe.succeed(3, ids: ["new-b"], total: 2, nextPage: nil)
        await newPage.value
        XCTAssertEqual(model.results.map(\.id), ["new-a", "new-b"])
        XCTAssertFalse(model.isLoadingMore)
        XCTAssertNil(model.paginationError)
        assertLoaded(model)
    }

    private func loadedModel(
        firstIDs: [String] = ["a", "b"], nextPage: String = "2", firstTotal: Int = 4
    ) async throws -> (SearchViewModel, ControlledSearchRepository) {
        let api = makeStubAPIClient()
        let repository = ControlledSearchRepository(api: api)
        repositories.append(repository)
        let model = SearchViewModel(
            repo: repository, assetRepo: AssetDetailRepository(api: api), albumRepo: AlbumRepository(api: api))
        model.searchText = "mountains"
        let task = Task { await model.search() }
        let request = try await repository.probe.waitForRequest(0, testCase: self)
        XCTAssertEqual(request.request.page, 1)
        try await repository.probe.succeed(0, ids: firstIDs, total: firstTotal, nextPage: nextPage)
        await task.value
        assertLoaded(model)
        return (model, repository)
    }

    private func assertIgnoredLoadMore(
        _ model: SearchViewModel, repository: ControlledSearchRepository, requestCount: Int
    ) async -> Bool {
        let completed = XCTestExpectation(description: "Ignored pagination trigger returned")
        var didComplete = false
        let task = Task {
            await model.loadMore()
            didComplete = true
            completed.fulfill()
        }
        await fulfillment(of: [completed], timeout: 2)
        let requests = await repository.probe.requests
        XCTAssertEqual(requests.count, requestCount)
        guard didComplete, requests.count == requestCount else {
            task.cancel()
            await repository.probe.cancelAll()
            return false
        }
        await task.value
        return true
    }

    private func assertLoaded(_ model: SearchViewModel, file: StaticString = #filePath, line: UInt = #line) {
        guard case .loaded = model.phase else {
            return XCTFail("Pagination must preserve the loaded grid", file: file, line: line)
        }
    }
}
