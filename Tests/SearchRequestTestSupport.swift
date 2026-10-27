import Foundation
import XCTest
@testable import ImmichApp

struct SearchRecordedRequest {
    enum Endpoint: Equatable { case smart, metadata }
    let request: SearchRequestDTO
    let endpoint: Endpoint
}

/// Holds responses until the test explicitly releases them. Cancellation does
/// not release a response, so the model must reject late completions itself.
actor SearchRequestProbe {
    private(set) var requests: [SearchRecordedRequest] = []
    private var pending: [Int: CheckedContinuation<SearchResponseDTO, Error>] = [:]
    private var observers: [Int: [XCTestExpectation]] = [:]
    private var isClosed = false

    func perform(_ request: SearchRequestDTO, endpoint: SearchRecordedRequest.Endpoint) async throws -> SearchResponseDTO {
        guard !isClosed else { throw CancellationError() }
        let index = requests.count
        requests.append(SearchRecordedRequest(request: request, endpoint: endpoint))
        return try await withCheckedThrowingContinuation { continuation in
            pending[index] = continuation
            for expectation in observers.removeValue(forKey: index) ?? [] { expectation.fulfill() }
        }
    }

    @MainActor
    func waitForRequest(
        _ index: Int, testCase: XCTestCase,
        file: StaticString = #filePath, line: UInt = #line
    ) async throws -> SearchRecordedRequest {
        let observed = XCTestExpectation(description: "Search request \(index) arrived")
        await observe(index, expectation: observed)
        await testCase.fulfillment(of: [observed], timeout: 2)
        let recorded = await request(at: index)
        return try XCTUnwrap(recorded, "Expected request \(index)", file: file, line: line)
    }

    func observe(_ index: Int, expectation: XCTestExpectation) {
        if requests.indices.contains(index) { expectation.fulfill() }
        else { observers[index, default: []].append(expectation) }
    }

    private func request(at index: Int) -> SearchRecordedRequest? {
        requests.indices.contains(index) ? requests[index] : nil
    }

    func succeed(_ index: Int, ids: [String], total: Int, nextPage: String? = nil) throws {
        let response = SearchResponseDTO(assets: .init(
            items: ids.map { makeTestAsset(id: $0) }, total: total, nextPage: nextPage))
        try continuation(at: index).resume(returning: response)
    }

    func fail(_ index: Int, error: Error) throws {
        try continuation(at: index).resume(throwing: error)
    }

    private func continuation(at index: Int) throws -> CheckedContinuation<SearchResponseDTO, Error> {
        guard let continuation = pending.removeValue(forKey: index) else {
            throw ProbeError.noPendingRequest(index)
        }
        return continuation
    }

    func cancelAll() {
        isClosed = true
        observers.removeAll()
        let running = Array(pending.values)
        pending.removeAll()
        for continuation in running { continuation.resume(throwing: CancellationError()) }
    }

    private enum ProbeError: Error { case noPendingRequest(Int) }
}

final class ControlledSearchRepository: SearchRepository {
    let probe = SearchRequestProbe()

    override func smartSearch(_ request: SearchRequestDTO) async throws -> SearchResponseDTO {
        try await probe.perform(request, endpoint: .smart)
    }

    override func metadataSearch(_ request: SearchRequestDTO) async throws -> SearchResponseDTO {
        try await probe.perform(request, endpoint: .metadata)
    }
}
