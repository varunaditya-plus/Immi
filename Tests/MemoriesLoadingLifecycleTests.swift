import XCTest
@testable import ImmichApp

@MainActor
final class MemoriesLoadingLifecycleTests: XCTestCase {
    func testCancelledInitialMemoryLoadRestoresIdleSoTheRetainedScreenCanRetry() async throws {
        let gate = PeopleStateGate<[MemoryDTO]>(), driver = MemoryLoadDriver()
        defer { gate.complete(.failure(CancellationError())) }
        driver.fetch = { try await gate.value() }
        let model = model(driver)
        let pending = Task { await model.loadMemories() }
        await fulfillment(of: [gate.started], timeout: 2)
        pending.cancel()
        gate.complete(.success([]))
        await pending.value

        XCTAssertTrue(model.phase.isIdle, "The screen only automatically starts an idle model when it reappears")
        driver.fetch = { [] }
        await model.loadMemories()
        XCTAssertNotNil(model.phase.value)
        XCTAssertTrue(model.stories.isEmpty)
        XCTAssertEqual(driver.requests, 2)
    }

    func testCancelledRetryRestoresItsPreviousFailureInsteadOfStrandingASpinner() async throws {
        let gate = PeopleStateGate<[MemoryDTO]>(), driver = MemoryLoadDriver()
        defer { gate.complete(.failure(CancellationError())) }
        driver.fetch = { throw APIError.notConnected }
        let model = model(driver)
        await model.loadMemories()
        let error = try XCTUnwrap(model.phase.errorMessage)
        driver.fetch = { try await gate.value() }
        let pending = Task { await model.retry() }
        await fulfillment(of: [gate.started], timeout: 2)
        pending.cancel()
        gate.complete(.failure(CancellationError()))
        await pending.value

        XCTAssertEqual(model.phase.errorMessage, error)
        XCTAssertFalse(model.phase.isLoading)
    }

    func testOlderMemorySuccessOrFailureCannotReplaceANewerAcceptedLoad() async throws {
        for fails in [false, true] {
            let gate = PeopleStateGate<[MemoryDTO]>(), driver = MemoryLoadDriver()
            defer { gate.complete(.failure(CancellationError())) }
            driver.fetch = { try await gate.value() }
            let model = model(driver)
            let older = Task { await model.loadMemories() }
            await fulfillment(of: [gate.started], timeout: 2)
            driver.fetch = { [] }
            await model.loadMemories()
            if fails { gate.complete(.failure(APIError.notConnected)) }
            else {
                let stale = try memory()
                XCTAssertEqual(MemoryStory.build(from: [stale], limit: 1).count, 1,
                    "The delayed payload must contain a real current-day memory to detect stale publication")
                gate.complete(.success([stale]))
            }
            await older.value

            XCTAssertNotNil(model.phase.value)
            XCTAssertTrue(model.stories.isEmpty, "The accepted empty response cannot be replaced by a delayed older memory")
            XCTAssertNil(model.phase.errorMessage)
        }
    }

    func testAlreadyCancelledLoadDoesNotSendARequestOrChangeItsPhase() async {
        let driver = MemoryLoadDriver(), model = model(driver)
        let pending = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            await model.loadMemories()
        }
        await pending.value
        XCTAssertTrue(model.phase.isIdle)
        XCTAssertEqual(driver.requests, 0)
    }

    private func memory() throws -> MemoryDTO {
        var localCalendar = Calendar(identifier: .gregorian)
        localCalendar.timeZone = .current
        let today = localCalendar.dateComponents([.month, .day], from: .now)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .gmt
        let date = try XCTUnwrap(calendar.date(from: DateComponents(year: 2020, month: today.month, day: today.day)))
        return MemoryDTO(id: UUID().uuidString, type: "on_this_day", memoryAt: date,
            assets: [makeTestAsset(id: UUID().uuidString)], data: MemoryDataDTO(year: 2020))
    }

    private func model(_ driver: MemoryLoadDriver) -> MemoriesViewModel {
        let api = APIClient(session: MockSessionManager())
        return MemoriesViewModel(repo: MemoryLoadRepository(api: api, driver: driver), assetRepo: AssetDetailRepository(api: api))
    }
}

@MainActor
private final class MemoryLoadDriver {
    var fetch: () async throws -> [MemoryDTO] = { [] }
    private(set) var requests = 0
    func load() async throws -> [MemoryDTO] { requests += 1; return try await fetch() }
}

private final class MemoryLoadRepository: MemoriesRepository {
    let driver: MemoryLoadDriver
    init(api: APIClient, driver: MemoryLoadDriver) { self.driver = driver; super.init(api: api) }
    override func getMemories() async throws -> [MemoryDTO] { try await driver.load() }
}
