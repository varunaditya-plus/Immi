import Observation
import XCTest
@testable import ImmichApp

@MainActor
final class PhotoMapSnapshotTests: XCTestCase {
    override func setUp() async throws {
        try await super.setUp()
        LocalSnapshot.remove(LocalSnapshot.Key.places)
    }

    override func tearDown() async throws {
        LocalSnapshot.remove(LocalSnapshot.Key.places)
        try await super.tearDown()
    }

    func testCachedMarkersAreImmediatelyAvailableWithoutLoading() {
        let saved = marker("cached")
        LocalSnapshot.save([saved], for: LocalSnapshot.Key.places)
        let model = PhotoMapViewModel()
        XCTAssertEqual(model.markers, [saved])
        XCTAssertFalse(model.isLoading)
        XCTAssertNil(model.loadError)
    }

    func testCachedEmptyResponseRemainsValidWhileOffline() async {
        LocalSnapshot.save([MapMarkerDTO](), for: LocalSnapshot.Key.places)
        let model = PhotoMapViewModel()
        await model.load { throw APIError.unknown }
        XCTAssertTrue(model.markers.isEmpty)
        XCTAssertFalse(model.isLoading)
        XCTAssertNil(model.loadError)
        XCTAssertEqual(cached(), [])
    }

    func testFreshMetadataPublishesAndNotifiesWhenAnotherInstanceAlreadySavedIt() async {
        LocalSnapshot.save([marker("same", latitude: 1, city: "Old")], for: LocalSnapshot.Key.places)
        let model = PhotoMapViewModel()
        let fresh = marker("same", latitude: 42, city: "Fresh")
        LocalSnapshot.save([fresh], for: LocalSnapshot.Key.places)
        XCTAssertFalse(LocalSnapshot.save([fresh], for: LocalSnapshot.Key.places))
        let probe = MapPublicationProbe()
        withObservationTracking { _ = model.markers } onChange: {
            MainActor.assumeIsolated { probe.changed = true }
        }
        await model.load { [fresh] }
        XCTAssertEqual(model.markers, [fresh])
        XCTAssertTrue(probe.changed, "The map must redraw changed coordinates and labels")
        XCTAssertEqual(cached(), [fresh])
    }

    func testAuthoritativeEmptyResponseClearsPreviouslyDisplayedAndCachedMarkers() async {
        LocalSnapshot.save([marker("removed")], for: LocalSnapshot.Key.places)
        let model = PhotoMapViewModel()
        await model.load { [] }
        XCTAssertTrue(model.markers.isEmpty)
        XCTAssertEqual(cached(), [])
        XCTAssertNil(model.loadError)
        XCTAssertFalse(model.isLoading)
    }

    func testFailedRefreshPreservesExistingMarkersAndSnapshot() async {
        let saved = marker("saved")
        LocalSnapshot.save([saved], for: LocalSnapshot.Key.places)
        let model = PhotoMapViewModel()
        await model.load { throw APIError.unknown }
        XCTAssertEqual(model.markers, [saved])
        XCTAssertEqual(cached(), [saved])
        XCTAssertNil(model.loadError)
        XCTAssertFalse(model.isLoading)
    }

    func testInitialFailureIsVisibleAndRetryClearsErrorWhileLoading() async {
        let model = PhotoMapViewModel()
        await model.load { throw APIError.unknown }
        XCTAssertNotNil(model.loadError)
        XCTAssertFalse(model.isLoading)
        let response = MapResponseGate()
        let retry = Task { await model.load { try await response.value() } }
        addTeardownBlock { await response.complete(.failure(CancellationError())); await retry.value }
        await fulfillment(of: [response.started], timeout: 2)
        XCTAssertNil(model.loadError)
        XCTAssertTrue(model.isLoading)
        response.complete(.success([marker("retry")]))
        await retry.value
        XCTAssertEqual(model.markers.map(\.id), ["retry"])
        XCTAssertEqual(cached()?.map(\.id), ["retry"])
        XCTAssertFalse(model.isLoading)
    }

    func testOlderSuccessOrFailureCannotReplaceANewerResponse() async {
        for fails in [false, true] {
            LocalSnapshot.remove(LocalSnapshot.Key.places)
            let model = PhotoMapViewModel()
            let response = MapResponseGate()
            let old = Task { await model.load { try await response.value() } }
            addTeardownBlock { await response.complete(.failure(CancellationError())); await old.value }
            await fulfillment(of: [response.started], timeout: 2)
            await model.load { [self.marker("current")] }
            response.complete(fails ? .failure(APIError.unknown) : .success([marker("obsolete")]))
            await old.value
            XCTAssertEqual(model.markers.map(\.id), ["current"])
            XCTAssertEqual(cached()?.map(\.id), ["current"])
            XCTAssertNil(model.loadError)
            XCTAssertFalse(model.isLoading)
        }
    }

    func testOlderCompletionCannotStopANewerRequestsLoadingIndicator() async {
        let model = PhotoMapViewModel()
        let first = MapResponseGate()
        let second = MapResponseGate()
        let old = Task { await model.load { try await first.value() } }
        addTeardownBlock { await first.complete(.failure(CancellationError())); await old.value }
        await fulfillment(of: [first.started], timeout: 2)
        let current = Task { await model.load { try await second.value() } }
        addTeardownBlock {
            await first.complete(.failure(CancellationError()))
            await second.complete(.failure(CancellationError()))
            await old.value
            await current.value
        }
        await fulfillment(of: [second.started], timeout: 2)
        first.complete(.success([marker("obsolete")]))
        await old.value
        XCTAssertTrue(model.isLoading)
        XCTAssertTrue(model.markers.isEmpty)
        XCTAssertNil(cached())
        second.complete(.success([marker("current")]))
        await current.value
        XCTAssertFalse(model.isLoading)
        XCTAssertEqual(model.markers.map(\.id), ["current"])
    }

    func testAlreadyCanceledCallerDoesNotBeginFetching() async {
        let model = PhotoMapViewModel()
        let entry = MapResponseGate()
        var fetchCalls = 0
        let task = Task {
            _ = try? await entry.value()
            await model.load { fetchCalls += 1; return [self.marker("canceled")] }
        }
        addTeardownBlock { await entry.complete(.failure(CancellationError())); await task.value }
        await fulfillment(of: [entry.started], timeout: 2)
        task.cancel()
        entry.complete(.success([]))
        await task.value
        XCTAssertEqual(fetchCalls, 0)
        XCTAssertTrue(model.markers.isEmpty)
        XCTAssertNil(cached())
    }

    func testCancellationRejectsAResponseFromANoncooperativeFetcher() async {
        let saved = marker("saved")
        LocalSnapshot.save([saved], for: LocalSnapshot.Key.places)
        let model = PhotoMapViewModel()
        let response = MapResponseGate()
        let task = Task { await model.load { try await response.value() } }
        addTeardownBlock { await response.complete(.failure(CancellationError())); await task.value }
        await fulfillment(of: [response.started], timeout: 2)
        task.cancel()
        response.complete(.success([marker("canceled")]))
        await task.value
        XCTAssertEqual(model.markers, [saved])
        XCTAssertEqual(cached(), [saved])
        XCTAssertNil(model.loadError)
        XCTAssertFalse(model.isLoading)
    }

    func testAccountChangeRejectsHeldResponseAndFurtherLoads() async {
        let model = PhotoMapViewModel()
        let response = MapResponseGate()
        let old = Task { await model.load { try await response.value() } }
        addTeardownBlock { await response.complete(.failure(CancellationError())); await old.value }
        await fulfillment(of: [response.started], timeout: 2)
        LocalSnapshot.clearAll()
        let next = marker("next-account")
        LocalSnapshot.save([next], for: LocalSnapshot.Key.places)
        response.complete(.success([marker("old-account")]))
        await old.value
        var calls = 0
        await model.load { calls += 1; return [] }
        XCTAssertFalse(model.isCurrentAccount)
        XCTAssertTrue(model.markers.isEmpty)
        XCTAssertEqual(cached(), [next])
        XCTAssertEqual(calls, 0)
    }

    func testDiskWriteFailureDoesNotDiscardFetchedMarkers() async throws {
        let file = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("immich-snapshots/places.markers.json")
        try FileManager.default.createDirectory(at: file, withIntermediateDirectories: true)
        let model = PhotoMapViewModel()
        let fresh = marker("fresh")
        await model.load { [fresh] }
        XCTAssertEqual(model.markers, [fresh])
        XCTAssertNil(model.loadError)
        XCTAssertFalse(model.isLoading)
        XCTAssertNil(cached(), "The blocked snapshot write really failed")
    }

    private func cached() -> [MapMarkerDTO]? {
        LocalSnapshot.load([MapMarkerDTO].self, for: LocalSnapshot.Key.places)
    }

    private func marker(_ id: String, latitude: Double = 1, city: String? = nil) -> MapMarkerDTO {
        .init(id: id, lat: latitude, lon: 2, city: city, state: nil, country: nil)
    }
}

@MainActor
private final class MapPublicationProbe { var changed = false }

@MainActor
private final class MapResponseGate {
    let started = XCTestExpectation(description: "A map request is held")
    private var hasStarted = false
    private var result: Result<[MapMarkerDTO], Error>?
    private var continuations: [CheckedContinuation<[MapMarkerDTO], Error>] = []

    func value() async throws -> [MapMarkerDTO] {
        if !hasStarted {
            hasStarted = true
            started.fulfill()
        }
        if let result { return try result.get() }
        return try await withCheckedThrowingContinuation { continuations.append($0) }
    }

    func complete(_ value: Result<[MapMarkerDTO], Error>) {
        guard result == nil else { return }
        result = value
        let pending = continuations
        continuations = []
        pending.forEach { $0.resume(with: value) }
    }
}
