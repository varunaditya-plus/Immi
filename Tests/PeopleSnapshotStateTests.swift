import Foundation
import Observation
import XCTest
@testable import ImmichApp

@MainActor
final class PeopleSnapshotStateTests: XCTestCase {
    private var closeGates: [() -> Void] = []
    private var workers: [Task<Void, Never>] = []

    override func setUp() async throws {
        try await super.setUp()
        LocalSnapshot.clearAll()
    }

    override func tearDown() async throws {
        for worker in workers { worker.cancel() }
        closeGates.forEach { $0() }
        for worker in workers { await worker.value }
        workers.removeAll()
        closeGates.removeAll()
        LocalSnapshot.clearAll()
        try await super.tearDown()
    }

    func testASecondModelPublishesFreshPeopleAlreadySavedByAnotherModel() async {
        let driver = PeopleStateDriver()
        let fresh = [makePeopleStatePerson(name: "Fresh server name")]
        driver.fetch = { fresh }
        let repository = PeopleStateRepository(driver: driver)
        let stale = PeopleListViewModel(repo: repository)
        stale.people = [makePeopleStatePerson(name: "Stale in-memory name")]
        stale.phase = .loaded(())
        let other = PeopleListViewModel(repo: repository)
        await other.loadPeople()
        XCTAssertFalse(LocalSnapshot.save(fresh, for: LocalSnapshot.Key.peopleList))
        let changed = expectation(description: "Changed person metadata is observable even when its ID is unchanged")
        withObservationTracking { _ = stale.people } onChange: { changed.fulfill() }

        await stale.loadPeople()
        await fulfillment(of: [changed], timeout: 2)

        XCTAssertEqual(stale.people, fresh)
        XCTAssertEqual(LocalSnapshot.load([PersonDTO].self, for: LocalSnapshot.Key.peopleList), fresh)
        XCTAssertEqual(driver.fetchCount, 2)
        XCTAssertNotNil(stale.phase.value)
    }

    func testAnAlreadyCachedEmptyResponseClearsAStaleNonemptyList() async {
        let driver = PeopleStateDriver()
        let model = PeopleListViewModel(repo: PeopleStateRepository(driver: driver))
        model.people = [makePeopleStatePerson()]
        model.phase = .loaded(())
        LocalSnapshot.save([PersonDTO](), for: LocalSnapshot.Key.peopleList)
        XCTAssertFalse(LocalSnapshot.save([PersonDTO](), for: LocalSnapshot.Key.peopleList))

        await model.loadPeople()

        XCTAssertTrue(model.people.isEmpty)
        XCTAssertNotNil(model.phase.value)
    }

    func testAuthoritativeEmptyResultDoesNotRestoreStaleDiskRowsOnTheNextLoad() async {
        let held: PeopleStateGate<[PersonDTO]> = gate()
        let driver = PeopleStateDriver()
        let model = PeopleListViewModel(repo: PeopleStateRepository(driver: driver))
        await model.loadPeople()
        XCTAssertTrue(model.people.isEmpty)
        XCTAssertNotNil(model.phase.value)
        // Another model can leave older bytes on disk. They cannot overrule
        // this model's already accepted empty server response.
        LocalSnapshot.save([makePeopleStatePerson(name: "Stale disk name")], for: LocalSnapshot.Key.peopleList)
        driver.fetch = { try await held.value() }
        let refresh = worker { await model.loadPeople() }
        await fulfillment(of: [held.started], timeout: 2)

        XCTAssertTrue(model.people.isEmpty, "Refresh must keep the accepted empty result visible")
        XCTAssertNotNil(model.phase.value)
        held.complete(.failure(APIError.notConnected))
        await refresh.value

        XCTAssertTrue(model.people.isEmpty)
        XCTAssertNotNil(model.phase.value)
        XCTAssertNil(model.phase.errorMessage)
    }

    func testLatestResponseOwnsTheListAndSnapshot() async {
        let old: PeopleStateGate<[PersonDTO]> = gate()
        let fresh: PeopleStateGate<[PersonDTO]> = gate()
        let driver = PeopleStateDriver()
        driver.fetch = { try await (driver.fetchCount == 1 ? old : fresh).value() }
        let model = PeopleListViewModel(repo: PeopleStateRepository(driver: driver))
        let first = worker { await model.loadPeople() }
        await fulfillment(of: [old.started], timeout: 2)
        let second = worker { await model.loadPeople() }
        await fulfillment(of: [fresh.started], timeout: 2)
        let newest = [makePeopleStatePerson("new", name: "Newest")]
        fresh.complete(.success(newest))
        await second.value
        old.complete(.success([makePeopleStatePerson("old")]))
        await first.value

        XCTAssertEqual(model.people, newest)
        XCTAssertEqual(LocalSnapshot.load([PersonDTO].self, for: LocalSnapshot.Key.peopleList), newest)
        XCTAssertNotNil(model.phase.value)
    }

    func testOldFailureCannotReplaceANewerSuccessfulPhase() async {
        let old: PeopleStateGate<[PersonDTO]> = gate()
        let driver = PeopleStateDriver()
        let newest = [makePeopleStatePerson("new")]
        driver.fetch = { driver.fetchCount == 1 ? try await old.value() : newest }
        let model = PeopleListViewModel(repo: PeopleStateRepository(driver: driver))
        let first = worker { await model.loadPeople() }
        await fulfillment(of: [old.started], timeout: 2)
        await model.loadPeople()
        old.complete(.failure(APIError.notConnected))
        await first.value

        XCTAssertEqual(model.people, newest)
        XCTAssertNotNil(model.phase.value)
        XCTAssertNil(model.phase.errorMessage)
    }

    func testCanceledSuccessCannotPublishOrPersistAndLeavesNoLoadingPhase() async {
        let held: PeopleStateGate<[PersonDTO]> = gate()
        let driver = PeopleStateDriver()
        driver.fetch = { try await held.value() }
        let model = PeopleListViewModel(repo: PeopleStateRepository(driver: driver))
        let load = worker { await model.loadPeople() }
        await fulfillment(of: [held.started], timeout: 2)
        load.cancel()
        held.complete(.success([makePeopleStatePerson("canceled")]))
        await load.value

        XCTAssertTrue(model.people.isEmpty)
        XCTAssertTrue(model.phase.isIdle)
        XCTAssertNil(LocalSnapshot.load([PersonDTO].self, for: LocalSnapshot.Key.peopleList))
    }

    func testCachedEmptySnapshotRemainsAValidResultOnFailure() async {
        let driver = PeopleStateDriver()
        driver.fetch = { throw APIError.notConnected }
        LocalSnapshot.save([PersonDTO](), for: LocalSnapshot.Key.peopleList)
        let model = PeopleListViewModel(repo: PeopleStateRepository(driver: driver))

        await model.loadPeople()

        XCTAssertTrue(model.people.isEmpty)
        XCTAssertNotNil(model.phase.value)
        XCTAssertNil(model.phase.errorMessage)
    }

    func testCancellationPreservesAnAuthoritativeEmptyResultWithoutADiskSnapshot() async {
        let held: PeopleStateGate<[PersonDTO]> = gate()
        let driver = PeopleStateDriver()
        let model = PeopleListViewModel(repo: PeopleStateRepository(driver: driver))
        await model.loadPeople()
        LocalSnapshot.remove(LocalSnapshot.Key.peopleList)
        driver.fetch = { try await held.value() }
        let refresh = worker { await model.loadPeople() }
        await fulfillment(of: [held.started], timeout: 2)
        XCTAssertNotNil(model.phase.value)
        refresh.cancel()
        held.complete(.success([makePeopleStatePerson("canceled")]))
        await refresh.value

        XCTAssertTrue(model.people.isEmpty)
        XCTAssertNotNil(model.phase.value)
        XCTAssertNil(LocalSnapshot.load([PersonDTO].self, for: LocalSnapshot.Key.peopleList))
    }

    func testCanceledRetryPreservesItsPreviousFailure() async {
        let held: PeopleStateGate<[PersonDTO]> = gate()
        let driver = PeopleStateDriver()
        driver.fetch = { throw APIError.notConnected }
        let model = PeopleListViewModel(repo: PeopleStateRepository(driver: driver))
        await model.loadPeople()
        let failure = model.phase.errorMessage
        XCTAssertNotNil(failure)
        driver.fetch = { try await held.value() }
        let retry = worker { await model.loadPeople() }
        await fulfillment(of: [held.started], timeout: 2)
        retry.cancel()
        held.complete(.failure(CancellationError()))
        await retry.value

        XCTAssertEqual(model.phase.errorMessage, failure)
        XCTAssertFalse(model.phase.isLoading)
    }

    func testCallbacksForAnAbsentPersonStillInvalidateAnOlderList() async {
        for rename in [true, false] {
            LocalSnapshot.clearAll()
            let held: PeopleStateGate<[PersonDTO]> = gate()
            let driver = PeopleStateDriver()
            driver.fetch = { try await held.value() }
            let model = PeopleListViewModel(repo: PeopleStateRepository(driver: driver))
            let load = worker { await model.loadPeople() }
            await fulfillment(of: [held.started], timeout: 2)
            if rename { model.applyRename("person", to: "Accepted name") }
            else { model.applyHidden("person", to: true) }
            held.complete(.success([makePeopleStatePerson()]))
            await load.value

            XCTAssertTrue(model.people.isEmpty)
            XCTAssertTrue(model.phase.isIdle)
            XCTAssertNil(LocalSnapshot.load([PersonDTO].self, for: LocalSnapshot.Key.peopleList))
            let current = [makePeopleStatePerson(name: "Accepted name", hidden: true)]
            driver.fetch = { current }
            await model.loadPeople()
            XCTAssertEqual(model.people, current, "A new response after the callback remains usable")
        }
    }

    func testConfirmedRenameCannotBeUndoneByAHeldListResponse() async {
        let held: PeopleStateGate<[PersonDTO]> = gate()
        let driver = PeopleStateDriver()
        driver.fetch = { try await held.value() }
        let model = PeopleListViewModel(repo: PeopleStateRepository(driver: driver))
        model.people = [makePeopleStatePerson()]
        model.phase = .loaded(())
        let load = worker { await model.loadPeople() }
        await fulfillment(of: [held.started], timeout: 2)

        model.applyRename("person", to: "Confirmed rename")
        held.complete(.success([makePeopleStatePerson()]))
        await load.value

        XCTAssertEqual(model.people.first?.name, "Confirmed rename")
        XCTAssertEqual(LocalSnapshot.load([PersonDTO].self, for: LocalSnapshot.Key.peopleList)?.first?.name, "Confirmed rename")
        XCTAssertNotNil(model.phase.value)
        driver.fetch = { [makePeopleStatePerson(name: "Later server rename")] }
        await model.loadPeople()
        XCTAssertEqual(model.people.first?.name, "Later server rename", "A newly admitted response must still be able to publish")
    }

    func testConfirmedHiddenMutationInvalidatesAnOlderFailedLoad() async {
        let held: PeopleStateGate<[PersonDTO]> = gate()
        let driver = PeopleStateDriver()
        driver.fetch = { try await held.value() }
        let model = PeopleListViewModel(repo: PeopleStateRepository(driver: driver))
        model.people = [makePeopleStatePerson()]
        model.phase = .loaded(())
        let load = worker { await model.loadPeople() }
        await fulfillment(of: [held.started], timeout: 2)

        model.applyHidden("person", to: true)
        held.complete(.failure(APIError.notConnected))
        await load.value

        XCTAssertEqual(model.people.first?.isHidden, true)
        XCTAssertEqual(LocalSnapshot.load([PersonDTO].self, for: LocalSnapshot.Key.peopleList)?.first?.isHidden, true)
        XCTAssertNotNil(model.phase.value)
    }

    func testSuccessfulHiddenRequestSurvivesAnOlderListCompletion() async {
        let list: PeopleStateGate<[PersonDTO]> = gate()
        let hide: PeopleStateGate<Void> = gate()
        let driver = PeopleStateDriver()
        driver.fetch = { try await list.value() }
        driver.hide = { _, _ in try await hide.value() }
        let model = PeopleListViewModel(repo: PeopleStateRepository(driver: driver))
        model.people = [makePeopleStatePerson()]
        model.phase = .loaded(())
        let load = worker { await model.loadPeople() }
        await fulfillment(of: [list.started], timeout: 2)
        let mutation = worker { await model.setHidden("person", to: true) }
        await fulfillment(of: [hide.started], timeout: 2)
        hide.complete(.success(()))
        await mutation.value
        list.complete(.success([makePeopleStatePerson()]))
        await load.value

        XCTAssertEqual(driver.hiddenChanges.map(\.id), ["person"])
        XCTAssertEqual(driver.hiddenChanges.map(\.value), [true])
        XCTAssertEqual(model.people.first?.isHidden, true)
        XCTAssertEqual(LocalSnapshot.load([PersonDTO].self, for: LocalSnapshot.Key.peopleList)?.first?.isHidden, true)
    }

    func testFailedHiddenRequestDoesNotInvalidateAPendingValidListResponse() async {
        let list: PeopleStateGate<[PersonDTO]> = gate()
        let hide: PeopleStateGate<Void> = gate()
        let driver = PeopleStateDriver()
        driver.fetch = { try await list.value() }
        driver.hide = { _, _ in try await hide.value() }
        let model = PeopleListViewModel(repo: PeopleStateRepository(driver: driver))
        model.people = [makePeopleStatePerson()]
        model.phase = .loaded(())
        let load = worker { await model.loadPeople() }
        await fulfillment(of: [list.started], timeout: 2)
        let mutation = worker { await model.setHidden("person", to: true) }
        await fulfillment(of: [hide.started], timeout: 2)
        hide.complete(.failure(APIError.notConnected))
        await mutation.value
        let fresh = [makePeopleStatePerson(name: "Confirmed server name")]
        list.complete(.success(fresh))
        await load.value

        XCTAssertEqual(model.people, fresh)
        XCTAssertEqual(LocalSnapshot.load([PersonDTO].self, for: LocalSnapshot.Key.peopleList), fresh)
        XCTAssertEqual(driver.hiddenChanges.count, 1)
    }

    func testCallbackReplacesAnOlderPendingHiddenRequest() async {
        let held: PeopleStateGate<Void> = gate()
        let driver = PeopleStateDriver()
        driver.hide = { _, _ in try await held.value() }
        let model = PeopleListViewModel(repo: PeopleStateRepository(driver: driver))
        model.people = [makePeopleStatePerson()]
        let mutation = worker { await model.setHidden("person", to: true) }
        await fulfillment(of: [held.started], timeout: 2)

        model.applyHidden("person", to: false)
        held.complete(.success(()))
        await mutation.value

        XCTAssertEqual(model.people.first?.isHidden, false)
        XCTAssertEqual(LocalSnapshot.load([PersonDTO].self, for: LocalSnapshot.Key.peopleList)?.first?.isHidden, false)
    }

    func testCanceledHiddenRequestCannotPublish() async {
        let held: PeopleStateGate<Void> = gate()
        let driver = PeopleStateDriver()
        driver.hide = { _, _ in try await held.value() }
        let model = PeopleListViewModel(repo: PeopleStateRepository(driver: driver))
        model.people = [makePeopleStatePerson()]
        let mutation = worker { await model.setHidden("person", to: true) }
        await fulfillment(of: [held.started], timeout: 2)
        mutation.cancel()
        held.complete(.success(()))
        await mutation.value

        XCTAssertEqual(model.people.first?.isHidden, false)
        XCTAssertNil(LocalSnapshot.load([PersonDTO].self, for: LocalSnapshot.Key.peopleList))
    }

    func testAccountChangeRejectsAnOlderHiddenResponse() async {
        let held: PeopleStateGate<Void> = gate()
        let driver = PeopleStateDriver()
        driver.hide = { _, _ in try await held.value() }
        let model = PeopleListViewModel(repo: PeopleStateRepository(driver: driver))
        model.people = [makePeopleStatePerson()]
        let mutation = worker { await model.setHidden("person", to: true) }
        await fulfillment(of: [held.started], timeout: 2)
        LocalSnapshot.clearAll()
        let next = [makePeopleStatePerson(name: "Next account")]
        LocalSnapshot.save(next, for: LocalSnapshot.Key.peopleList)
        held.complete(.success(()))
        await mutation.value

        XCTAssertEqual(model.people.first?.isHidden, false)
        XCTAssertEqual(LocalSnapshot.load([PersonDTO].self, for: LocalSnapshot.Key.peopleList), next)
    }

    func testAccountChangeRejectsPendingAndLocalMutationWrites() async {
        let held: PeopleStateGate<[PersonDTO]> = gate()
        let driver = PeopleStateDriver()
        driver.fetch = { try await held.value() }
        let model = PeopleListViewModel(repo: PeopleStateRepository(driver: driver))
        let load = worker { await model.loadPeople() }
        await fulfillment(of: [held.started], timeout: 2)
        LocalSnapshot.clearAll()
        let next = [makePeopleStatePerson("next", name: "Next account")]
        LocalSnapshot.save(next, for: LocalSnapshot.Key.peopleList)

        model.applyRename("person", to: "Previous account rename")
        model.applyHidden("person", to: true)
        held.complete(.success([makePeopleStatePerson()]))
        await load.value

        XCTAssertTrue(model.people.isEmpty)
        XCTAssertEqual(LocalSnapshot.load([PersonDTO].self, for: LocalSnapshot.Key.peopleList), next)
    }

    private func gate<Value>() -> PeopleStateGate<Value> {
        let gate = PeopleStateGate<Value>()
        closeGates.append { gate.complete(.failure(CancellationError())) }
        return gate
    }

    private func worker(_ operation: @escaping @MainActor () async -> Void) -> Task<Void, Never> {
        let task = Task { await operation() }
        workers.append(task)
        return task
    }
}
