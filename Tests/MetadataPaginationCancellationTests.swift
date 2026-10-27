import XCTest
@testable import ImmichApp

@MainActor
final class MetadataPaginationCancellationTests: XCTestCase {
    func testCanceledQueryDoesNotStartFetchingPages() async {
        let repository = HeldMetadataPageRepository(heldPage: nil)
        let work = Task { try await repository.allMetadata(SearchRequestDTO(size: 100)) }
        work.cancel()

        do {
            _ = try await work.value
            XCTFail("A canceled query must not start a page request")
        } catch is CancellationError {
            // Cancellation is checked before the transport boundary.
        } catch {
            XCTFail("Expected cancellation, received \(error)")
        }
        XCTAssertTrue(repository.pages.isEmpty)
    }

    func testCancellationDuringTheFirstPageRejectsItsLateResponse() async throws {
        try await cancelHeldQuery(page: 1)
    }

    func testCancellationDuringALaterPageDoesNotReturnAPartialCollection() async throws {
        try await cancelHeldQuery(page: 2)
    }

    private func cancelHeldQuery(page: Int) async throws {
        let repository = HeldMetadataPageRepository(heldPage: page)
        let work = Task { try await repository.allMetadata(SearchRequestDTO(size: 100)) }
        defer { work.cancel(); repository.cancelIfWaiting() }
        await fulfillment(of: [repository.started], timeout: 2)

        work.cancel()
        repository.resolve()
        do {
            _ = try await work.value
            XCTFail("A transport that returns after cancellation must not publish a complete collection")
        } catch is CancellationError {
            // The real pagination helper checks cancellation after each page.
        }
        XCTAssertEqual(repository.pages, Array(1...page))

        let retried = try await repository.allMetadata(SearchRequestDTO(size: 100))
        XCTAssertEqual(retried.map(\.id), (1...page).map { "asset-\($0)" })
        XCTAssertEqual(repository.pages, Array(1...page) + Array(1...page))
    }
}

/// Only the page transport is held. The real allMetadata implementation runs
/// unchanged, including its continuation and cancellation decisions.
@MainActor
private final class HeldMetadataPageRepository: SearchRepository {
    let started = XCTestExpectation(description: "A metadata page reached the transport boundary")
    private(set) var pages: [Int] = []
    private let heldPage: Int?
    private var shouldHold = true
    private var continuation: CheckedContinuation<SearchResponseDTO, Error>?

    init(heldPage: Int?) {
        self.heldPage = heldPage
        super.init(api: makeStubAPIClient())
    }

    override func metadataSearch(_ request: SearchRequestDTO) async throws -> SearchResponseDTO {
        let page = request.page ?? 1
        pages.append(page)
        if shouldHold, page == heldPage {
            shouldHold = false
            return try await withCheckedThrowingContinuation { continuation in
                self.continuation = continuation
                started.fulfill()
            }
        }
        return response(page: page)
    }

    func resolve() {
        guard let continuation, let heldPage else {
            return XCTFail("The canceled query did not reach its held page")
        }
        self.continuation = nil
        continuation.resume(returning: response(page: heldPage))
    }

    func cancelIfWaiting() {
        continuation?.resume(throwing: CancellationError())
        continuation = nil
    }

    private func response(page: Int) -> SearchResponseDTO {
        let lastPage = heldPage ?? 1
        return SearchResponseDTO(assets: .init(
            items: [makeTestAsset(id: "asset-\(page)")], total: 1,
            nextPage: page < lastPage ? String(page + 1) : nil))
    }
}
