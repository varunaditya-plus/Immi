import Foundation
import Observation
import XCTest
@testable import ImmichApp

@MainActor
final class PersonDetailStateTests: XCTestCase {
    private var closeGates: [() -> Void] = []
    private var workers: [Task<Void, Never>] = []

    override func setUp() async throws {
        try await super.setUp()
        LocalSnapshot.clearAll()
    }

    override func tearDown() async throws {
        for task in workers { task.cancel() }
        closeGates.forEach { $0() }
        for task in workers { await task.value }
        workers.removeAll()
        closeGates.removeAll()
        LocalSnapshot.clearAll()
        try await super.tearDown()
    }

    func testEditingTheBoundDraftDuringSaveCannotPublishAnUnsubmittedName() async throws {
        let held: PeopleStateGate<Void> = gate()
        let driver = PeopleStateDriver()
        driver.rename = { _, _ in try await held.value() }
        let repository = PeopleStateRepository(driver: driver)
        let list = PeopleListViewModel(repo: repository)
        list.people = [makePeopleStatePerson()]
        let state = PersonDetailState(person: makePeopleStatePerson())
        state.renameDraft = "Submitted name"
        let request = try XCTUnwrap(state.prepareRename())
        var published: [(String, String)] = []
        let changed = expectation(description: "The actual detail title publishes the accepted name")
        withObservationTracking { _ = state.person } onChange: { changed.fulfill() }
        let save = worker {
            await state.saveRename(request, using: repository) { id, name in
                list.applyRename(id, to: name)
                published.append((id, name))
            }
        }
        await fulfillment(of: [held.started], timeout: 2)

        state.renameDraft = "Edited but never submitted"
        held.complete(.success(()))
        await save.value
        await fulfillment(of: [changed], timeout: 2)

        XCTAssertEqual(driver.renames.map(\.name), ["Submitted name"])
        XCTAssertEqual(state.person.name, "Submitted name")
        XCTAssertEqual(state.renameDraft, "Edited but never submitted", "Unsaved editing remains separate from accepted metadata")
        XCTAssertEqual(published.map { $0.0 }, ["person"])
        XCTAssertEqual(published.map { $0.1 }, ["Submitted name"])
        XCTAssertEqual(list.people.first?.name, "Submitted name")
        XCTAssertEqual(LocalSnapshot.load([PersonDTO].self, for: LocalSnapshot.Key.peopleList)?.first?.name, "Submitted name")
        XCTAssertNil(state.actionError)
    }

    func testAnOlderSubmissionCannotStartAfterANewerSaveWasAdmitted() async throws {
        let driver = PeopleStateDriver()
        let state = PersonDetailState(person: makePeopleStatePerson())
        state.renameDraft = "First"
        let first = try XCTUnwrap(state.prepareRename())
        state.renameDraft = "Second"
        let second = try XCTUnwrap(state.prepareRename())
        let repository = PeopleStateRepository(driver: driver)

        await state.saveRename(first, using: repository)
        await state.saveRename(second, using: repository)

        XCTAssertEqual(state.person.name, "Second")
        XCTAssertEqual(driver.renames.map(\.name), ["Second"])
    }

    func testLateSuccessCannotReplaceANewerAcceptedRename() async throws {
        let held: PeopleStateGate<Void> = gate()
        let driver = PeopleStateDriver()
        driver.rename = { _, name in if name == "First" { try await held.value() } }
        let state = PersonDetailState(person: makePeopleStatePerson())
        let repository = PeopleStateRepository(driver: driver)
        state.renameDraft = "First"
        let first = try XCTUnwrap(state.prepareRename())
        var published: [String] = []
        let old = worker { await state.saveRename(first, using: repository) { _, name in published.append(name) } }
        await fulfillment(of: [held.started], timeout: 2)
        state.renameDraft = "Second"
        let second = try XCTUnwrap(state.prepareRename())

        await state.saveRename(second, using: repository) { _, name in published.append(name) }
        held.complete(.success(()))
        await old.value

        XCTAssertEqual(state.person.name, "Second")
        XCTAssertEqual(published, ["Second"])
        XCTAssertEqual(driver.renames.map(\.name), ["First", "Second"])
    }

    func testLateFailureCannotSurfaceAfterANewerAcceptedRename() async throws {
        let held: PeopleStateGate<Void> = gate()
        let driver = PeopleStateDriver()
        driver.rename = { _, name in if name == "First" { try await held.value() } }
        let state = PersonDetailState(person: makePeopleStatePerson())
        let repository = PeopleStateRepository(driver: driver)
        state.renameDraft = "First"
        let first = try XCTUnwrap(state.prepareRename())
        let old = worker { await state.saveRename(first, using: repository) }
        await fulfillment(of: [held.started], timeout: 2)
        state.renameDraft = "Second"
        let second = try XCTUnwrap(state.prepareRename())
        await state.saveRename(second, using: repository)
        held.complete(.failure(APIError.notConnected))
        await old.value

        XCTAssertEqual(state.person.name, "Second")
        XCTAssertNil(state.actionError)
    }

    func testCurrentFailureLeavesThePersonAndCallbackUnchanged() async throws {
        let driver = PeopleStateDriver()
        driver.rename = { _, _ in throw APIError.notConnected }
        let state = PersonDetailState(person: makePeopleStatePerson())
        state.renameDraft = "Rejected"
        let request = try XCTUnwrap(state.prepareRename())
        var callbacks = 0

        await state.saveRename(request, using: PeopleStateRepository(driver: driver)) { _, _ in callbacks += 1 }

        XCTAssertEqual(state.person.name, "Original")
        XCTAssertEqual(state.renameDraft, "Rejected")
        XCTAssertNotNil(state.actionError)
        XCTAssertEqual(callbacks, 0)
        XCTAssertEqual(driver.renames.map(\.name), ["Rejected"])
    }

    func testRepositoryCancellationDoesNotBecomeAnActionError() async throws {
        let driver = PeopleStateDriver()
        driver.rename = { _, _ in throw CancellationError() }
        let state = PersonDetailState(person: makePeopleStatePerson())
        let request = try XCTUnwrap(state.prepareRename())

        await state.saveRename(request, using: PeopleStateRepository(driver: driver))

        XCTAssertEqual(state.person.name, "Original")
        XCTAssertNil(state.actionError)
        XCTAssertEqual(driver.renames.count, 1)
    }

    func testCancellationAfterRequestStartsSuppressesItsLateSuccess() async throws {
        let held: PeopleStateGate<Void> = gate()
        let driver = PeopleStateDriver()
        driver.rename = { _, _ in try await held.value() }
        let state = PersonDetailState(person: makePeopleStatePerson())
        state.renameDraft = "Canceled"
        let request = try XCTUnwrap(state.prepareRename())
        let repository = PeopleStateRepository(driver: driver)
        var callbacks = 0
        let save = worker { await state.saveRename(request, using: repository) { _, _ in callbacks += 1 } }
        await fulfillment(of: [held.started], timeout: 2)
        save.cancel()
        held.complete(.success(()))
        await save.value

        XCTAssertEqual(state.person.name, "Original")
        XCTAssertNil(state.actionError)
        XCTAssertEqual(callbacks, 0)
    }

    func testAnAlreadyCanceledCallerCannotSendAnAdmittedRename() async throws {
        let driver = PeopleStateDriver()
        let state = PersonDetailState(person: makePeopleStatePerson())
        state.renameDraft = "Canceled"
        let request = try XCTUnwrap(state.prepareRename())
        let repository = PeopleStateRepository(driver: driver)
        let save = worker { await state.saveRename(request, using: repository) }
        save.cancel()
        await save.value

        XCTAssertEqual(state.person.name, "Original")
        XCTAssertTrue(driver.renames.isEmpty)
    }

    func testAccountChangeBeforeExecutionPreventsTheOldSubmissionFromBeingSent() async throws {
        let driver = PeopleStateDriver()
        let state = PersonDetailState(person: makePeopleStatePerson())
        state.renameDraft = "Previous account"
        let request = try XCTUnwrap(state.prepareRename())
        LocalSnapshot.clearAll()

        await state.saveRename(request, using: PeopleStateRepository(driver: driver))

        XCTAssertEqual(state.person.name, "Original")
        XCTAssertNil(state.prepareRename(), "An abandoned account's state cannot admit new edits")
        XCTAssertTrue(driver.renames.isEmpty)
    }

    func testAccountChangeDuringTheRequestProtectsTheReplacementStateAndSnapshot() async throws {
        let held: PeopleStateGate<Void> = gate()
        let driver = PeopleStateDriver()
        driver.rename = { _, _ in try await held.value() }
        let state = PersonDetailState(person: makePeopleStatePerson())
        state.renameDraft = "Previous account"
        let request = try XCTUnwrap(state.prepareRename())
        let repository = PeopleStateRepository(driver: driver)
        var callbacks = 0
        let old = worker { await state.saveRename(request, using: repository) { _, _ in callbacks += 1 } }
        await fulfillment(of: [held.started], timeout: 2)
        LocalSnapshot.clearAll()
        let next = [makePeopleStatePerson(name: "Next account")]
        LocalSnapshot.save(next, for: LocalSnapshot.Key.peopleList)
        let replacement = PersonDetailState(person: next[0])
        held.complete(.success(()))
        await old.value

        XCTAssertEqual(state.person.name, "Original")
        XCTAssertEqual(replacement.person.name, "Next account")
        XCTAssertEqual(callbacks, 0)
        XCTAssertEqual(LocalSnapshot.load([PersonDTO].self, for: LocalSnapshot.Key.peopleList), next)
    }

    func testARequestCannotRenameAnotherPersonsState() async throws {
        let driver = PeopleStateDriver()
        let first = PersonDetailState(person: makePeopleStatePerson("first"))
        first.renameDraft = "First person edit"
        let request = try XCTUnwrap(first.prepareRename())
        let other = PersonDetailState(person: makePeopleStatePerson("other", name: "Other person"))

        await other.saveRename(request, using: PeopleStateRepository(driver: driver))

        XCTAssertEqual(other.person.name, "Other person")
        XCTAssertTrue(driver.renames.isEmpty)
    }

    func testEmptyDraftDoesNotSupersedeAnExistingSubmission() async throws {
        let driver = PeopleStateDriver()
        let state = PersonDetailState(person: makePeopleStatePerson())
        state.renameDraft = "Valid"
        let accepted = try XCTUnwrap(state.prepareRename())
        state.renameDraft = ""

        XCTAssertNil(state.prepareRename())
        await state.saveRename(accepted, using: PeopleStateRepository(driver: driver))

        XCTAssertEqual(state.person.name, "Valid")
        XCTAssertEqual(driver.renames.map(\.name), ["Valid"])
    }

    func testLateDetailResponseCannotUndoAConfirmedRename() async throws {
        let held: PeopleStateGate<PersonDTO> = gate()
        let driver = PeopleStateDriver()
        driver.fetchDetail = { _ in try await held.value() }
        let state = PersonDetailState(person: makePeopleStatePerson())
        let repository = PeopleStateRepository(driver: driver)
        let load = worker { await state.loadDetail(using: repository) }
        await fulfillment(of: [held.started], timeout: 2)
        state.renameDraft = "Saved while detail was loading"
        let request = try XCTUnwrap(state.prepareRename())
        await state.saveRename(request, using: repository)
        held.complete(.success(makePeopleStatePerson(name: "Old detail")))
        await load.value

        XCTAssertEqual(state.person.name, "Saved while detail was loading")
        XCTAssertEqual(driver.detailIDs, ["person"])
    }

    func testNewlyRequestedDetailCanStillPublishServerMetadataWithoutReplacingTheDraft() async {
        let driver = PeopleStateDriver()
        driver.fetchDetail = { _ in makePeopleStatePerson(name: "Server refreshed", hidden: true) }
        let state = PersonDetailState(person: makePeopleStatePerson())
        state.renameDraft = "Unsaved draft"

        await state.loadDetail(using: PeopleStateRepository(driver: driver))

        XCTAssertEqual(state.person.name, "Server refreshed")
        XCTAssertEqual(state.person.isHidden, true)
        XCTAssertEqual(state.renameDraft, "Unsaved draft")
    }

    func testOlderDetailCannotReplaceANewerResponse() async {
        let held: PeopleStateGate<PersonDTO> = gate()
        let driver = PeopleStateDriver()
        driver.fetchDetail = { _ in
            driver.detailIDs.count == 1 ? try await held.value() : makePeopleStatePerson(name: "Newest detail")
        }
        let state = PersonDetailState(person: makePeopleStatePerson())
        let repository = PeopleStateRepository(driver: driver)
        let old = worker { await state.loadDetail(using: repository) }
        await fulfillment(of: [held.started], timeout: 2)
        await state.loadDetail(using: repository)
        held.complete(.success(makePeopleStatePerson(name: "Old detail")))
        await old.value

        XCTAssertEqual(state.person.name, "Newest detail")
    }

    func testWrongPersonOrCrossAccountDetailCannotPublish() async {
        let held: PeopleStateGate<PersonDTO> = gate()
        let driver = PeopleStateDriver()
        driver.fetchDetail = { _ in makePeopleStatePerson("different-person", name: "Wrong endpoint result") }
        let state = PersonDetailState(person: makePeopleStatePerson())
        let repository = PeopleStateRepository(driver: driver)
        await state.loadDetail(using: repository)
        XCTAssertEqual(state.person.name, "Original")
        driver.fetchDetail = { _ in try await held.value() }
        let old = worker { await state.loadDetail(using: repository) }
        await fulfillment(of: [held.started], timeout: 2)
        LocalSnapshot.clearAll()
        held.complete(.success(makePeopleStatePerson(name: "Old account detail")))
        await old.value

        XCTAssertEqual(state.person.name, "Original")
    }

    func testHiddenMutationPreservesTheSavedNameAndRejectsOlderDetailMetadata() async throws {
        let held: PeopleStateGate<PersonDTO> = gate()
        let driver = PeopleStateDriver()
        driver.fetchDetail = { _ in try await held.value() }
        let state = PersonDetailState(person: makePeopleStatePerson())
        let repository = PeopleStateRepository(driver: driver)
        let load = worker { await state.loadDetail(using: repository) }
        await fulfillment(of: [held.started], timeout: 2)
        state.renameDraft = "Saved name"
        let request = try XCTUnwrap(state.prepareRename())
        await state.saveRename(request, using: repository)
        var hidden: [Bool] = []
        await state.toggleHidden(using: repository) { _, value in hidden.append(value) }
        held.complete(.success(makePeopleStatePerson()))
        await load.value

        XCTAssertEqual(state.person.name, "Saved name")
        XCTAssertEqual(state.person.isHidden, true)
        XCTAssertEqual(hidden, [true])
        XCTAssertEqual(driver.hiddenChanges.map(\.value), [true])
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
