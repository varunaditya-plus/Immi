import Foundation
import XCTest
@testable import ImmichApp

@MainActor
final class RepositoryAccountIsolationTests: XCTestCase {
    override func setUp() async throws {
        LocalSnapshot.clearAll()
        DeletedServerAssetRegistry.shared.clear()
    }

    override func tearDown() async throws {
        LocalSnapshot.clearAll()
        DeletedServerAssetRegistry.shared.clear()
    }

    func testDeleteCannotRecordIntoNextAccountsRegistryAfterResponseWasValidated() async throws {
        let fixture = try MutationResultFixture()
        defer { fixture.cleanup() }
        let repository = AssetDetailRepository(api: fixture.client)
        let deletion = Task { try await repository.delete(["old-photo"]) }
        await fulfillment(of: [fixture.validated], timeout: 2)

        LocalSnapshot.clearAll()
        DeletedServerAssetRegistry.shared.record(["next-account-photo"], permanently: false)
        fixture.gate.release()

        do {
            try await deletion.value
            XCTFail("A stale deletion must not update the current account's registry")
        } catch is CancellationError {
        }
        XCTAssertEqual(DeletedServerAssetRegistry.shared.suppressedIDs, ["next-account-photo"])
    }

    func testCurrentDeleteRecordsSuccessfulServerMutation() async throws {
        let fixture = try MutationResultFixture()
        defer { fixture.cleanup() }
        let repository = AssetDetailRepository(api: fixture.client)
        let deletion = Task { try await repository.delete(["current-photo"]) }
        await fulfillment(of: [fixture.validated], timeout: 2)

        fixture.gate.release()
        try await deletion.value

        XCTAssertEqual(DeletedServerAssetRegistry.shared.suppressedIDs, ["current-photo"])
    }

    func testResolvedDuplicatesCannotRecordIntoNextAccountsRegistry() async throws {
        let fixture = try MutationResultFixture()
        defer { fixture.cleanup() }
        let group = try duplicateGroup()
        let model = DuplicatesViewModel(
            repository: DuplicateRepository(api: fixture.client),
            assetRepository: AssetDetailRepository(api: fixture.client),
            usesResolveEndpoint: true)
        model.groups = [group]
        let resolution = Task { await model.resolve(group, keeping: ["kept-photo"]) }
        await fulfillment(of: [fixture.validated], timeout: 2)

        LocalSnapshot.clearAll()
        DeletedServerAssetRegistry.shared.record(["next-account-photo"], permanently: false)
        fixture.gate.release()
        await resolution.value

        XCTAssertEqual(DeletedServerAssetRegistry.shared.suppressedIDs, ["next-account-photo"])
        XCTAssertEqual(model.groups.map(\.id), [group.id])
    }

    func testCurrentDuplicateResolutionRecordsTrashedAssets() async throws {
        let fixture = try MutationResultFixture()
        defer { fixture.cleanup() }
        let group = try duplicateGroup()
        let model = DuplicatesViewModel(
            repository: DuplicateRepository(api: fixture.client),
            assetRepository: AssetDetailRepository(api: fixture.client),
            usesResolveEndpoint: true)
        model.groups = [group]
        let resolution = Task { await model.resolve(group, keeping: ["kept-photo"]) }
        await fulfillment(of: [fixture.validated], timeout: 2)

        fixture.gate.release()
        await resolution.value

        XCTAssertEqual(DeletedServerAssetRegistry.shared.suppressedIDs, ["trashed-photo"])
        XCTAssertTrue(model.groups.isEmpty)
    }

    private func duplicateGroup() throws -> DuplicateGroupDTO {
        struct Group: Encodable {
            let duplicateId = "group"
            let assets = [makeTestAsset(id: "kept-photo"), makeTestAsset(id: "trashed-photo")]
            let suggestedKeepAssetIds = ["kept-photo"]
        }
        return try JSONDecoder.immich.decode(
            DuplicateGroupDTO.self, from: JSONEncoder.immich.encode(Group()))
    }
}

@MainActor
private final class MutationResultFixture {
    let validated = XCTestExpectation(description: "Server mutation response validated")
    let gate = MutationResultGate()
    let client: HeldValidatedMutationClient
    private let urlSession: URLSession

    init() throws {
        let session = MockSessionManager()
        try session.setServer("https://mutation-account-test.invalid")
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [SuccessfulMutationURLProtocol.self]
        urlSession = URLSession(configuration: configuration)
        client = HeldValidatedMutationClient(
            session: session, urlSession: urlSession, validated: validated, gate: gate)
    }

    func cleanup() { urlSession.invalidateAndCancel() }
}

@MainActor
private final class MutationResultGate {
    private var continuation: CheckedContinuation<Void, Never>?

    func wait() async {
        await withCheckedContinuation { continuation = $0 }
    }

    func release() {
        XCTAssertNotNil(continuation)
        continuation?.resume()
        continuation = nil
    }
}

private final class HeldValidatedMutationClient: APIClient {
    private let validated: XCTestExpectation
    private let gate: MutationResultGate

    @MainActor
    init(session: SessionManager, urlSession: URLSession,
         validated: XCTestExpectation, gate: MutationResultGate) {
        self.validated = validated
        self.gate = gate
        super.init(session: session, urlSession: urlSession)
    }

    // Hold an already validated response at the await boundary. The repository
    // and view model must recheck ownership before mutating shared local state.
    @MainActor
    override func sendVoid(_ endpoint: Endpoint) async throws {
        try await super.sendVoid(endpoint)
        validated.fulfill()
        await gate.wait()
    }

    @MainActor
    override func send<T: Decodable>(_ endpoint: Endpoint) async throws -> T {
        let result: T = try await super.send(endpoint)
        validated.fulfill()
        await gate.wait()
        return result
    }
}

private final class SuccessfulMutationURLProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "mutation-account-test.invalid"
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url,
              ["/api/assets", "/api/duplicates/resolve"].contains(url.path) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!
        let json = url.path == "/api/duplicates/resolve"
            ? #"[{"id":"group","success":true}]"# : "{}"
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(json.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
