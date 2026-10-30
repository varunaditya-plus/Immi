import Foundation
import Observation
import SwiftData
import XCTest
@testable import ImmichApp

@MainActor
final class SearchOptionsTests: XCTestCase {
    private var fixtures: [SearchOptionsFixture] = []
    private var previousPeople: [PersonDTO]?
    private var isolatedStores: [(URL, SwiftDataManager)] = []

    override func setUp() async throws {
        try await super.setUp()
        previousPeople = LocalSnapshot.load([PersonDTO].self, for: LocalSnapshot.Key.peopleList)
    }

    override func tearDown() async throws {
        for fixture in fixtures {
            fixture.model.searchText = ""
            fixture.model.filters = SearchFilters()
            fixture.model.options = .init()
            fixture.model.scheduleSearch()
            await fixture.search.probe.cancelAll()
        }
        fixtures.removeAll()
        for (directory, manager) in isolatedStores {
            try manager.modelContainer.erase()
            try? FileManager.default.removeItem(at: directory)
        }
        isolatedStores.removeAll()
        if let previousPeople { LocalSnapshot.save(previousPeople, for: LocalSnapshot.Key.peopleList) }
        else { LocalSnapshot.remove(LocalSnapshot.Key.peopleList) }
        try await super.tearDown()
    }

    func testOptionSourcesRetryIndependentlyAndSuccessfulEmptyListsAreNotFailures() async {
        let fixture = fixture()
        fixture.people.values = [makePeopleStatePerson("maya", name: "Maya")]
        fixture.search.suggestionsOperation = { type, count in
            if type == "city", count == 1 { throw APIError.notConnected }
            return type == "city" ? ["Paris", "Paris", ""] : []
        }

        await fixture.model.loadFilterOptions()

        XCTAssertFalse(fixture.model.hasLoadedOptions)
        XCTAssertNotNil(fixture.model.optionsError)
        XCTAssertEqual(fixture.model.people.map(\.id), ["maya"])
        XCTAssertTrue(fixture.model.cities.isEmpty)

        await fixture.model.loadFilterOptions()

        XCTAssertTrue(fixture.model.hasLoadedOptions)
        XCTAssertNil(fixture.model.optionsError)
        XCTAssertEqual(fixture.model.cities, ["Paris"])
        XCTAssertEqual(fixture.people.reads, 1)
        XCTAssertEqual(fixture.albums.reads, 1)
        XCTAssertEqual(fixture.search.suggestionReads, ["city": 2, "state": 1, "country": 1])

        await fixture.model.loadFilterOptions()
        XCTAssertEqual(fixture.search.suggestionReads["city"], 2)
        XCTAssertFalse(fixture.model.isLoadingOptions)
    }

    func testAForcedAuthoritativeEmptyDirectoryRemovesStalePeopleAndSelectedTokens() async {
        let fixture = fixture()
        let maya = makePeopleStatePerson("maya", name: "Old Name")
        fixture.people.values = [maya, makePeopleStatePerson("hidden", name: "Hidden", hidden: true)]
        await fixture.model.loadFilterOptions()
        fixture.model.filters.people = [maya]
        XCTAssertEqual(fixture.model.people.map(\.id), [maya.id])
        fixture.people.values = []

        await fixture.model.loadFilterOptions(force: true)

        XCTAssertTrue(fixture.model.people.isEmpty)
        XCTAssertTrue(fixture.model.filters.people.isEmpty)
        XCTAssertTrue(fixture.model.hasLoadedOptions, "An accepted empty directory is a complete result")
        XCTAssertEqual(fixture.people.reads, 2)
        XCTAssertTrue(fixture.people.sizes.allSatisfy { $0 == nil }, "Suggestions need the complete directory, not the Library preview limit")
    }

    func testALaterForcedDirectoryWinsOverAnOlderHeldResponse() async throws {
        let fixture = fixture()
        let old = PeopleStateGate<[PersonDTO]>()
        fixture.people.operation = { count in
            if count == 1 { return try await old.value() }
            return [makePeopleStatePerson("current", name: "Current")]
        }
        let first = Task { await fixture.model.loadFilterOptions() }
        addTeardownBlock { await old.complete(.failure(CancellationError())); await first.value }
        await fulfillment(of: [old.started], timeout: 2)

        await fixture.model.loadFilterOptions(force: true)
        old.complete(.success([makePeopleStatePerson("stale", name: "Stale")]))
        await first.value

        XCTAssertEqual(fixture.model.people.map(\.id), ["current"])
        XCTAssertTrue(fixture.model.hasLoadedOptions)
    }

    func testAcceptedPersonChangesRejectHeldDirectoryAndPreserveTheLatestSelectedName() async {
        let fixture = fixture()
        let original = makePeopleStatePerson("maya", name: "Original")
        fixture.model.people = [original]
        fixture.model.filters.people = [original]
        let held = PeopleStateGate<[PersonDTO]>()
        fixture.people.operation = { _ in try await held.value() }
        let pending = Task { await fixture.model.loadFilterOptions() }
        addTeardownBlock { await held.complete(.failure(CancellationError())); await pending.value }
        await fulfillment(of: [held.started], timeout: 2)
        let renamed = makePeopleStatePerson("maya", name: "Confirmed Name")

        fixture.model.applyPersonUpdate(.init(person: renamed, fields: [.name]))
        held.complete(.success([original]))
        await pending.value

        XCTAssertEqual(fixture.model.people.first?.name, "Confirmed Name")
        XCTAssertEqual(fixture.model.tokens.first?.title, "Confirmed Name")
    }

    func testAFreshDirectoryCanRestoreAPersonUnhiddenByAnotherClient() async {
        let fixture = fixture()
        let person = makePeopleStatePerson("maya", name: "Maya")
        fixture.people.values = [person]
        await fixture.model.loadFilterOptions()
        var hidden = person
        hidden.isHidden = true
        fixture.model.applyPersonUpdate(.init(person: hidden, fields: [.hidden]))
        XCTAssertTrue(fixture.model.people.isEmpty)

        await fixture.model.loadFilterOptions(force: true)

        XCTAssertEqual(fixture.model.people.map(\.id), [person.id])
        XCTAssertEqual(fixture.model.suggestedTokens(for: "Maya").map(\.id), [SearchToken.person(person).id])
    }

    func testAnotherPeopleDirectorysAcceptedHideIsAppliedBeforeAHeldRefreshAndSurvivesItsFailure() async {
        let fixture = fixture()
        let maya = makePeopleStatePerson("maya", name: "Maya")
        let leo = makePeopleStatePerson("leo", name: "Leo")
        fixture.people.values = [maya, leo]
        await fixture.model.loadFilterOptions()
        fixture.model.filters.people = [maya]
        let external = PeopleListViewModel(repo: fixture.people)
        external.people = [maya, leo]
        LocalSnapshot.remove(LocalSnapshot.Key.peopleList)
        external.applyHidden(maya.id, to: true)
        let held = PeopleStateGate<[PersonDTO]>()
        fixture.people.operation = { _ in try await held.value() }
        let pending = Task { await fixture.model.loadFilterOptions(force: true) }
        addTeardownBlock { await held.complete(.failure(CancellationError())); await pending.value }
        await fulfillment(of: [held.started], timeout: 2)

        XCTAssertEqual(fixture.model.people.map(\.id), [leo.id])
        XCTAssertTrue(fixture.model.filters.people.isEmpty)
        XCTAssertTrue(fixture.model.suggestedTokens(for: "Maya").isEmpty)
        held.complete(.failure(APIError.notConnected))
        await pending.value

        XCTAssertEqual(fixture.model.people.map(\.id), [leo.id])
        XCTAssertTrue(fixture.model.suggestedTokens(for: "Maya").isEmpty)
        XCTAssertNotNil(fixture.model.optionsError)
    }

    func testAnotherDirectorysConfirmedRenameUpdatesTokensEvenWhenTheRefreshFails() async {
        let fixture = fixture()
        let original = makePeopleStatePerson("maya", name: "Original")
        fixture.people.values = [original]
        await fixture.model.loadFilterOptions()
        fixture.model.filters.people = [original]
        let external = PeopleListViewModel(repo: fixture.people)
        external.people = [original]
        var renamed = original
        renamed.name = "Confirmed Name"
        LocalSnapshot.remove(LocalSnapshot.Key.peopleList)
        external.applyPersonUpdate(.init(person: renamed, fields: [.name]))
        fixture.people.operation = { _ in throw APIError.notConnected }

        await fixture.model.loadFilterOptions(force: true)

        XCTAssertEqual(fixture.model.people.first?.name, renamed.name)
        XCTAssertEqual(fixture.model.tokens.first?.title, renamed.name)
        XCTAssertTrue(fixture.model.suggestedTokens(for: "Original").isEmpty)
        XCTAssertEqual(fixture.model.suggestedTokens(for: "Confirmed").count, 0,
            "The selected current person is excluded from duplicate suggestions")
    }

    func testAcceptedNestedPersonUpdateSurvivesRepositoryInvalidationAndFailedReloadWithoutKeepingUnconfirmedNames() async {
        let fixture = fixture()
        let original = makePeopleStatePerson("maya", name: "Original")
        let unrelated = makePeopleStatePerson("other", name: "Unconfirmed Other")
        fixture.people.values = [original, unrelated]
        await fixture.model.loadFilterOptions()
        fixture.model.filters.people = [original]
        var renamed = original
        renamed.name = "Confirmed Name"
        LocalSnapshot.remove(LocalSnapshot.Key.peopleList)

        fixture.model.applyPersonUpdate(.init(person: renamed, fields: [.name]))
        fixture.people.operation = { _ in throw APIError.notConnected }
        await fixture.model.loadFilterOptions(force: true)

        XCTAssertEqual(fixture.model.people.map(\.id), [renamed.id])
        XCTAssertEqual(fixture.model.people.first?.name, renamed.name)
        XCTAssertEqual(fixture.model.tokens.first?.title, renamed.name)
        XCTAssertTrue(fixture.model.suggestedTokens(for: unrelated.name).isEmpty)
        XCTAssertNotNil(fixture.model.optionsError)
    }

    func testAcceptedPersonCallbacksAfterAnAlreadyFailedMissingSnapshotRefreshRestoreOnlyTheConfirmedIdentity() async {
        for field in [PersonUpdate.Field.name, .favorite, .thumbnail] {
            let fixture = fixture()
            let original = makePeopleStatePerson("maya", name: "Original")
            let unrelated = makePeopleStatePerson("other", name: "Unconfirmed Other")
            fixture.people.values = [original, unrelated]
            await fixture.model.loadFilterOptions()
            fixture.model.filters.people = [original]
            LocalSnapshot.remove(LocalSnapshot.Key.peopleList)
            fixture.people.operation = { _ in throw APIError.notConnected }
            await fixture.model.loadFilterOptions(force: true)
            XCTAssertTrue(fixture.model.people.isEmpty)
            XCTAssertEqual(fixture.model.tokens.first?.title, String(localized: "1 Person"))
            var accepted = original
            if field == .name { accepted.name = "Confirmed Name" }
            if field == .favorite { accepted.isFavorite = true }
            if field == .thumbnail { accepted.thumbnailPath = "confirmed-face"; accepted.updatedAt = Date(timeIntervalSince1970: 1_800_000_000) }

            fixture.model.applyPersonUpdate(.init(person: accepted, fields: [field]))
            await fixture.model.loadFilterOptions(force: true)

            XCTAssertEqual(fixture.model.people, [accepted])
            XCTAssertEqual(fixture.model.filters.people, [accepted])
            XCTAssertEqual(fixture.model.tokens.first?.title, accepted.name)
            XCTAssertTrue(fixture.model.suggestedTokens(for: unrelated.name).isEmpty)
        }
    }

    func testMissingDirectorySnapshotWithholdsStaleNamesWithoutLosingCriteriaAndAdoptsALaterSnapshotOnFailure() async {
        let fixture = fixture()
        let original = makePeopleStatePerson("maya", name: "Maya")
        fixture.people.values = [original]
        await fixture.model.loadFilterOptions()
        fixture.model.filters = SearchFilters(people: [original], city: "Paris")
        fixture.model.searchText = "Maya"
        LocalSnapshot.remove(LocalSnapshot.Key.peopleList)
        let held = PeopleStateGate<[PersonDTO]>()
        fixture.people.operation = { _ in try await held.value() }
        let pending = Task { await fixture.model.loadFilterOptions(force: true) }
        addTeardownBlock { await held.complete(.failure(CancellationError())); await pending.value }
        await fulfillment(of: [held.started], timeout: 2)

        XCTAssertTrue(fixture.model.people.isEmpty)
        XCTAssertTrue(fixture.model.matchingPeople.isEmpty)
        XCTAssertTrue(fixture.model.suggestedTokens(for: "Maya").isEmpty)
        XCTAssertEqual(fixture.model.filters.people.map(\.id), [original.id])
        XCTAssertEqual(fixture.model.filters.city, "Paris")
        XCTAssertEqual(fixture.model.searchText, "Maya")
        XCTAssertEqual(fixture.model.tokens.first?.title, String(localized: "1 Person"))
        var renamed = original
        renamed.name = "Confirmed Name"
        LocalSnapshot.save([renamed], for: LocalSnapshot.Key.peopleList)
        held.complete(.failure(APIError.notConnected))
        await pending.value

        XCTAssertEqual(fixture.model.people.first?.name, renamed.name)
        XCTAssertEqual(fixture.model.tokens.first?.title, renamed.name)
        XCTAssertEqual(fixture.model.filters.people.map(\.id), [original.id])
        XCTAssertEqual(fixture.model.filters.city, "Paris")
    }

    func testAnInvalidatedValidEmptySnapshotImmediatelyRemovesFormerDirectoryAndTokens() async {
        let fixture = fixture()
        let maya = makePeopleStatePerson("maya", name: "Maya")
        fixture.people.values = [maya]
        await fixture.model.loadFilterOptions()
        fixture.model.filters.people = [maya]
        LocalSnapshot.remove(LocalSnapshot.Key.peopleList)
        LocalSnapshot.save([PersonDTO](), for: LocalSnapshot.Key.peopleList)
        let held = PeopleStateGate<[PersonDTO]>()
        fixture.people.operation = { _ in try await held.value() }
        let pending = Task { await fixture.model.loadFilterOptions(force: true) }
        addTeardownBlock { await held.complete(.failure(CancellationError())); await pending.value }
        await fulfillment(of: [held.started], timeout: 2)

        XCTAssertTrue(fixture.model.people.isEmpty)
        XCTAssertTrue(fixture.model.filters.people.isEmpty)
        held.complete(.failure(APIError.notConnected))
        await pending.value
        XCTAssertTrue(fixture.model.people.isEmpty)
    }

    func testAuthoritativeDirectoryOmissionsRejectOlderPartialCallbacksForSelectedAndUnselectedPeople() async {
        for selected in [false, true] {
            let fixture = fixture()
            let source = makePeopleStatePerson("source", name: "Former Person")
            let target = makePeopleStatePerson("target", name: "Current Person")
            fixture.people.values = [source, target]
            await fixture.model.loadFilterOptions()
            if selected { fixture.model.filters.people = [source] }
            LocalSnapshot.remove(LocalSnapshot.Key.peopleList)
            LocalSnapshot.save([target], for: LocalSnapshot.Key.peopleList)
            fixture.people.operation = { _ in throw APIError.notConnected }
            await fixture.model.loadFilterOptions(force: true)
            var olderFavorite = source
            olderFavorite.isFavorite = true

            fixture.model.applyPersonUpdate(.init(person: source, fields: [.name]))
            fixture.model.applyPersonUpdate(.init(person: olderFavorite, fields: [.favorite]))

            XCTAssertEqual(fixture.model.people.map(\.id), [target.id])
            XCTAssertTrue(fixture.model.filters.people.isEmpty)
            XCTAssertTrue(fixture.model.suggestedTokens(for: source.name).isEmpty)
            fixture.model.searchText = source.name
            XCTAssertTrue(fixture.model.matchingPeople.isEmpty)
        }
    }

    func testAnAuthoritativeOmissionRejectsUnselectedCallbacksEvenAfterThePreviousDirectoryWasWithheld() async {
        let fixture = fixture()
        let source = makePeopleStatePerson("source", name: "Former Person")
        let target = makePeopleStatePerson("target", name: "Current Person")
        fixture.people.values = [source, target]
        await fixture.model.loadFilterOptions()
        LocalSnapshot.remove(LocalSnapshot.Key.peopleList)
        let held = PeopleStateGate<[PersonDTO]>()
        fixture.people.operation = { _ in try await held.value() }
        let pending = Task { await fixture.model.loadFilterOptions(force: true) }
        addTeardownBlock { await held.complete(.failure(CancellationError())); await pending.value }
        await fulfillment(of: [held.started], timeout: 2)

        XCTAssertTrue(fixture.model.people.isEmpty)
        held.complete(.success([target]))
        await pending.value
        fixture.model.applyPersonUpdate(.init(person: source, fields: [.favorite]))
        XCTAssertEqual(fixture.model.people.map(\.id), [target.id])
    }

    func testAFreshVisibleDirectoryCanRestoreAnIdentityPreviouslyOmittedFromTheDirectory() async {
        let fixture = fixture()
        let person = makePeopleStatePerson("person", name: "Previous Name")
        fixture.people.values = [person]
        await fixture.model.loadFilterOptions()
        fixture.people.values = []
        await fixture.model.loadFilterOptions(force: true)
        fixture.model.applyPersonUpdate(.init(person: person, fields: [.favorite]))
        XCTAssertTrue(fixture.model.people.isEmpty)
        let restored = makePeopleStatePerson(person.id, name: "Restored Current Name")
        fixture.people.values = [restored]

        await fixture.model.loadFilterOptions(force: true)

        XCTAssertEqual(fixture.model.people.map(\.id), [restored.id])
        XCTAssertEqual(fixture.model.suggestedTokens(for: "Restored").map(\.title), [restored.name])
    }

    func testLocationOptionReadsRejectHeldSuccessAndFailureAfterCurrentVisibilityChanges() async throws {
        for succeeds in [true, false] {
            let manager = try isolatedStore()
            let fixture = fixture(dataManager: manager)
            let gates = Dictionary(uniqueKeysWithValues: ["city", "state", "country"].map { ($0, PeopleStateGate<[String]>()) })
            fixture.search.suggestionsOperation = { type, _ in try await gates[type]!.value() }
            let pending = Task { await fixture.model.loadFilterOptions() }
            addTeardownBlock {
                for gate in gates.values { await gate.complete(.failure(CancellationError())) }
                await pending.value
            }
            await fulfillment(of: gates.values.map(\.started), timeout: 2)

            try manager.setAssetVisibility([UUID().uuidString], to: succeeds ? "archive" : "locked")
            for (type, gate) in gates {
                gate.complete(succeeds ? .success(["Old \(type)"]) : .failure(APIError.notConnected))
            }
            await pending.value

            XCTAssertTrue(fixture.model.cities.isEmpty)
            XCTAssertTrue(fixture.model.states.isEmpty)
            XCTAssertTrue(fixture.model.countries.isEmpty)
            XCTAssertNil(fixture.model.optionsError, "An obsolete response cannot publish either old suggestions or old errors")
            XCTAssertFalse(fixture.model.hasLoadedOptions)
        }
    }

    func testLocationInvalidationClearsStaleOptionsAndFailedRefreshCannotRestoreThemOrDropCriteria() async throws {
        let manager = try isolatedStore()
        let fixture = fixture(dataManager: manager)
        fixture.search.suggestionsOperation = { type, _ in ["Old \(type)"] }
        await fixture.model.loadFilterOptions()
        XCTAssertTrue(fixture.model.hasLoadedOptions)
        fixture.model.filters = SearchFilters(city: "Selected City", state: "Selected State", country: "Selected Country")
        try manager.setAssetVisibility([UUID().uuidString], to: "locked")

        fixture.model.invalidateLocationOptions()

        XCTAssertTrue(fixture.model.cities.isEmpty)
        XCTAssertTrue(fixture.model.states.isEmpty)
        XCTAssertTrue(fixture.model.countries.isEmpty)
        XCTAssertFalse(fixture.model.hasLoadedOptions)
        fixture.search.suggestionsOperation = { _, _ in throw APIError.notConnected }
        await fixture.model.loadFilterOptions()
        XCTAssertTrue(fixture.model.cities.isEmpty)
        XCTAssertTrue(fixture.model.states.isEmpty)
        XCTAssertTrue(fixture.model.countries.isEmpty)
        XCTAssertEqual(fixture.model.filters.city, "Selected City")
        XCTAssertEqual(fixture.model.filters.state, "Selected State")
        XCTAssertEqual(fixture.model.filters.country, "Selected Country")
        XCTAssertNotNil(fixture.model.optionsError)

        fixture.model.invalidateLocationOptions()
        XCTAssertNil(fixture.model.optionsError)
        fixture.search.suggestionsOperation = { type, _ in type == "city" ? ["Current City"] : [] }
        await fixture.model.loadFilterOptions()

        XCTAssertEqual(fixture.model.cities, ["Current City"])
        XCTAssertTrue(fixture.model.states.isEmpty)
        XCTAssertTrue(fixture.model.countries.isEmpty)
        XCTAssertTrue(fixture.model.hasLoadedOptions)
        XCTAssertNil(fixture.model.optionsError)
        XCTAssertEqual(fixture.people.reads, 1)
        XCTAssertEqual(fixture.albums.reads, 1)
        XCTAssertEqual(fixture.search.suggestionReads, ["city": 3, "state": 3, "country": 3])
    }

    func testAnOlderHeldLocationDirectoryCannotReplaceTheRefreshAfterDeletion() async throws {
        let manager = try isolatedStore()
        let fixture = fixture(dataManager: manager)
        let gates = Dictionary(uniqueKeysWithValues: ["city", "state", "country"].map { ($0, PeopleStateGate<[String]>()) })
        fixture.search.suggestionsOperation = { type, _ in try await gates[type]!.value() }
        let pending = Task { await fixture.model.loadFilterOptions() }
        addTeardownBlock {
            for gate in gates.values { await gate.complete(.failure(CancellationError())) }
            await pending.value
        }
        await fulfillment(of: gates.values.map(\.started), timeout: 2)
        let deleted = UUID().uuidString
        RemovedAssets.shared.remove([deleted], reason: .trashed)
        defer { RemovedAssets.shared.restore([deleted]) }
        fixture.model.invalidateLocationOptions()
        fixture.search.suggestionsOperation = { type, _ in ["Current \(type)"] }

        await fixture.model.loadFilterOptions()
        for (type, gate) in gates { gate.complete(.success(["Old \(type)"])) }
        await pending.value

        XCTAssertEqual(fixture.model.cities, ["Current city"])
        XCTAssertEqual(fixture.model.states, ["Current state"])
        XCTAssertEqual(fixture.model.countries, ["Current country"])
        XCTAssertTrue(fixture.model.hasLoadedOptions)
        XCTAssertNil(fixture.model.optionsError)
    }

    func testDirectoryInvalidationRejectsAHeldResponseWithoutReintroducingRemovedPeople() async {
        let fixture = fixture()
        let held = PeopleStateGate<[PersonDTO]>()
        fixture.people.operation = { _ in try await held.value() }
        let pending = Task { await fixture.model.loadFilterOptions() }
        addTeardownBlock { await held.complete(.failure(CancellationError())); await pending.value }
        await fulfillment(of: [held.started], timeout: 2)

        LocalSnapshot.remove(LocalSnapshot.Key.peopleList)
        held.complete(.success([makePeopleStatePerson("stale", name: "Stale")]))
        await pending.value

        XCTAssertTrue(fixture.model.people.isEmpty)
        XCTAssertFalse(fixture.model.hasLoadedOptions)
    }

    func testCanceledOrPreviousAccountOptionsCannotPublishTheirHeldDirectory() async {
        for changesAccount in [false, true] {
            let fixture = fixture()
            let held = PeopleStateGate<[PersonDTO]>()
            fixture.people.operation = { _ in try await held.value() }
            let pending = Task { await fixture.model.loadFilterOptions() }
            addTeardownBlock { await held.complete(.failure(CancellationError())); await pending.value }
            await fulfillment(of: [held.started], timeout: 2)
            if changesAccount { LocalSnapshot.clearAll() }
            else { pending.cancel() }
            held.complete(.success([makePeopleStatePerson("private-old", name: "Old Account")]))
            await pending.value

            XCTAssertTrue(fixture.model.people.isEmpty)
            XCTAssertTrue(fixture.model.tokens.isEmpty)
            XCTAssertFalse(fixture.model.hasLoadedOptions)
        }
    }

    func testAcceptedAlbumRenameAndDeletionWinOverAHeldOlderAlbumDirectory() async {
        for deleting in [false, true] {
            let fixture = fixture()
            let album = AlbumResponseDTO(id: UUID().uuidString, albumName: "Original", description: nil,
                assetCount: 0, albumThumbnailAssetId: nil, shared: false, createdAt: .distantPast, assets: nil)
            fixture.albums.values = [album]
            await fixture.model.loadFilterOptions()
            fixture.model.filters.album = album
            let held = PeopleStateGate<[AlbumResponseDTO]>()
            fixture.albums.operation = { try await held.value() }
            let pending = Task { await fixture.model.loadFilterOptions(force: true) }
            addTeardownBlock { await held.complete(.failure(CancellationError())); await pending.value }
            await fulfillment(of: [held.started], timeout: 2)

            if deleting { fixture.model.removeAlbum(album.id) }
            else {
                var renamed = album
                renamed.albumName = "Confirmed Name"
                fixture.model.applyAlbumUpdate(renamed)
            }
            held.complete(.success([album]))
            await pending.value

            if deleting {
                XCTAssertTrue(fixture.model.albums.isEmpty)
                XCTAssertNil(fixture.model.filters.album)
            } else {
                XCTAssertEqual(fixture.model.albums.first?.albumName, "Confirmed Name")
                XCTAssertEqual(fixture.model.filters.album?.albumName, "Confirmed Name")
            }
        }
    }

    func testDebounceAndPaginationCaptureOptionsInsteadOfReadingLaterPropertyChanges() async throws {
        let fixture = fixture()
        let original = PhotoSearchOptions(sortOrder: .recentlyAdded, favoritesOnly: true, editedOnly: true)
        fixture.model.searchText = "mountains"
        fixture.model.options = original
        fixture.model.scheduleSearch()
        fixture.model.options = .init()
        _ = try await fixture.search.probe.waitForRequest(0, testCase: self)
        XCTAssertEqual(fixture.search.optionsSent, [original])
        let published = expectation(description: "The debounced search publishes its captured options")
        withObservationTracking { _ = fixture.model.phase } onChange: { published.fulfill() }
        try await fixture.search.probe.succeed(0, ids: ["first"], total: 2, nextPage: "2")
        await fulfillment(of: [published], timeout: 2)

        let page = Task { await fixture.model.loadMore() }
        _ = try await fixture.search.probe.waitForRequest(1, testCase: self)
        XCTAssertEqual(fixture.search.optionsSent, [original, original])
        try await fixture.search.probe.succeed(1, ids: ["second"], total: 2)
        await page.value
        XCTAssertEqual(fixture.model.results.map(\.id), ["first", "second"])
    }

    func testChangingOptionsInvalidatesAnOlderRequestBeforeTheNewDebounceRuns() async throws {
        let fixture = fixture()
        fixture.model.searchText = "mountains"
        let first = Task { await fixture.model.search() }
        _ = try await fixture.search.probe.waitForRequest(0, testCase: self)
        let changed = PhotoSearchOptions(sortOrder: .recentlyAdded, favoritesOnly: true)
        fixture.model.options = changed
        fixture.model.scheduleSearch()
        try await fixture.search.probe.succeed(0, ids: ["stale"], total: 1)
        await first.value
        XCTAssertTrue(fixture.model.results.isEmpty)
        _ = try await fixture.search.probe.waitForRequest(1, testCase: self)
        XCTAssertEqual(fixture.search.optionsSent, [.init(), changed])
        let published = expectation(description: "The replacement search publishes")
        withObservationTracking { _ = fixture.model.phase } onChange: { published.fulfill() }
        try await fixture.search.probe.succeed(1, ids: ["fresh"], total: 1)
        await fulfillment(of: [published], timeout: 2)
        XCTAssertEqual(fixture.model.results.map(\.id), ["fresh"])
    }

    func testFavoritesAndEditedRefinementsCanSearchWithoutAnyTypedQuery() async throws {
        for options in [PhotoSearchOptions(favoritesOnly: true), PhotoSearchOptions(editedOnly: true)] {
            let fixture = fixture()
            fixture.model.options = options
            XCTAssertTrue(fixture.model.hasCriteria)
            let pending = Task { await fixture.model.search() }
            let sent = try await fixture.search.probe.waitForRequest(0, testCase: self)
            XCTAssertNil(sent.request.query)
            XCTAssertEqual(fixture.search.optionsSent, [options])
            try await fixture.search.probe.succeed(0, ids: [], total: 0)
            await pending.value
        }
    }

    func testFirstAndLaterPagesPreserveLivePhotoCompanionIdentity() async throws {
        let fixture = fixture()
        fixture.model.searchText = "Live"
        fixture.search.response = { request in
            let page = request.page ?? 1
            let asset = AssetResponseDTO(id: "photo-\(page)", type: "IMAGE", originalFileName: "live.heic", fileCreatedAt: .distantPast,
                isFavorite: false, isArchived: false, isTrashed: false, duration: nil, thumbhash: nil,
                localDateTime: .distantPast, exifInfo: nil, people: nil, livePhotoVideoId: "companion-\(page)")
            return .init(assets: .init(items: [asset], total: 2, nextPage: page == 1 ? "2" : nil))
        }

        await fixture.model.search()
        await fixture.model.loadMore()

        XCTAssertEqual(fixture.model.results.map(\.livePhotoVideoID), ["companion-1", "companion-2"])
        XCTAssertTrue(fixture.model.results.allSatisfy(\.isLivePhoto))
    }

    func testUnfavoritingInAFavoritesOnlySearchRemovesThePhotoAndAHeldPageCannotRestoreIt() async throws {
        let fixture = fixture()
        let first = makeTestAsset(id: "unfavorited", isFavorite: true)
        let next = makeTestAsset(id: "kept", isFavorite: true)
        let held = PeopleStateGate<SearchResponseDTO>()
        fixture.search.searchOperation = { request in
            if request.page == 1 { return .init(assets: .init(items: [first], total: 2, nextPage: "2")) }
            return try await held.value()
        }
        fixture.model.options = .init(favoritesOnly: true)
        await fixture.model.search()
        XCTAssertEqual(fixture.model.results.map(\.id), [first.id])
        let pending = Task { await fixture.model.loadMore() }
        addTeardownBlock { await held.complete(.failure(CancellationError())); await pending.value }
        await fulfillment(of: [held.started], timeout: 2)

        fixture.model.patchFavorite(first.id, to: false)

        XCTAssertTrue(fixture.model.results.isEmpty)
        XCTAssertEqual(fixture.model.totalResults, 1)
        held.complete(.success(.init(assets: .init(items: [first, next], total: 2, nextPage: nil))))
        await pending.value
        XCTAssertEqual(fixture.model.results.map(\.id), [next.id])
        XCTAssertEqual(fixture.model.totalResults, 1)
    }

    func testFavoritingAgainRestartsTheSameQueryAndRejectsTheOlderHeldPageBeforeRestoringThePhoto() async throws {
        let fixture = fixture()
        let photo = makeTestAsset(id: "favorite-again", isFavorite: true)
        let obsolete = makeTestAsset(id: "obsolete-page", isFavorite: true)
        let oldPage = PeopleStateGate<SearchResponseDTO>()
        let replacement = PeopleStateGate<SearchResponseDTO>()
        var pages: [Int] = []
        fixture.search.searchOperation = { request in
            pages.append(request.page ?? 0)
            if pages.count == 1 { return .init(assets: .init(items: [photo], total: 2, nextPage: "2")) }
            if request.page == 2 { return try await oldPage.value() }
            return try await replacement.value()
        }
        fixture.model.options = .init(favoritesOnly: true)
        await fixture.model.search()
        let pending = Task { await fixture.model.loadMore() }
        addTeardownBlock {
            await oldPage.complete(.failure(CancellationError()))
            await replacement.complete(.failure(CancellationError()))
            await pending.value
        }
        await fulfillment(of: [oldPage.started], timeout: 2)

        fixture.model.patchFavorite(photo.id, to: false)
        XCTAssertTrue(fixture.model.results.isEmpty)
        XCTAssertEqual(fixture.model.totalResults, 1)
        fixture.model.patchFavorite(photo.id, to: true)
        oldPage.complete(.success(.init(assets: .init(items: [photo, obsolete], total: 2, nextPage: nil))))
        await pending.value
        XCTAssertTrue(fixture.model.results.isEmpty, "The former page must not repopulate the restarted query")
        await fulfillment(of: [replacement.started], timeout: 2)
        let published = expectation(description: "The fresh Favorites query restores the matching photo")
        withObservationTracking { _ = fixture.model.phase } onChange: { published.fulfill() }
        replacement.complete(.success(.init(assets: .init(items: [photo], total: 1, nextPage: nil))))
        await fulfillment(of: [published], timeout: 2)

        XCTAssertEqual(pages, [1, 2, 1])
        XCTAssertEqual(fixture.search.optionsSent, Array(repeating: PhotoSearchOptions(favoritesOnly: true), count: 3))
        XCTAssertEqual(fixture.model.results.map(\.id), [photo.id])
        XCTAssertTrue(fixture.model.results.first?.isFavorite == true)
        XCTAssertEqual(fixture.model.totalResults, 1)
    }

    func testAcceptedSearchFavoritesPersistOnlyConfirmedRecentsWithoutAddingOrReorderingViews() async throws {
        let manager = try isolatedStore()
        let suite = "search-favorite-recents-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let owner = BackupQueueOwner(server: "https://search-recents.example/api", userID: "synthetic-user")
        let store = RecentlyViewedStore(owner: owner, defaults: defaults, dataManager: manager)
        let first = makeTestAsset(id: UUID().uuidString), second = makeTestAsset(id: UUID().uuidString)
        let unviewed = makeTestAsset(id: UUID().uuidString)
        store.record(first)
        store.record(second)
        let originalOrder = [second.id, first.id]
        let session = MockSessionManager()
        try session.setServer("https://search-recents.example")
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let transport = URLSession(configuration: configuration)
        defer { transport.invalidateAndCancel(); MockURLProtocol.reset() }
        let api = APIClient(session: session, urlSession: transport)
        let model = SearchViewModel(repo: SearchRepository(api: api),
            assetRepo: AssetDetailRepository(api: api, dataManager: manager), albumRepo: AlbumRepository(api: api),
            dataManager: manager, recentlyViewedStore: store)
        model.results = [first, second, unviewed].map(AssetLite.init)
        var rejectedID: String? = second.id
        var writes: [(String, Bool)] = []
        MockURLProtocol.responseProvider = { request in
            XCTAssertEqual(request.httpMethod, "PUT")
            let id = request.url?.lastPathComponent ?? ""
            XCTAssertEqual(request.url?.path, "/api/assets/\(id)")
            let body = (try? JSONSerialization.jsonObject(with: request.httpBody ?? MockURLProtocol.lastRequestBody ?? Data())) as? [String: Any]
            XCTAssertEqual(Set(body?.keys.map { $0 } ?? []), ["isFavorite"])
            let value = body?["isFavorite"] as? Bool ?? false
            writes.append((id, value))
            let status = id == rejectedID ? 503 : 200
            return (Data("{}".utf8), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil), nil)
        }

        let partial = await model.setFavorite([first.id, second.id, unviewed.id], to: true)

        XCTAssertFalse(partial)
        XCTAssertEqual(writes.map(\.0), [first.id, second.id])
        XCTAssertEqual(writes.map(\.1), [true, true])
        XCTAssertEqual(store.assets.map(\.id), originalOrder)
        XCTAssertTrue(store.assets.last?.isFavorite == true)
        XCTAssertFalse(store.assets.first?.isFavorite ?? true)
        let reopened = RecentlyViewedStore(owner: owner, defaults: defaults, dataManager: manager)
        XCTAssertEqual(reopened.assets.map(\.id), originalOrder)
        XCTAssertTrue(reopened.assets.last?.isFavorite == true)
        XCTAssertFalse(reopened.assets.first?.isFavorite ?? true)

        rejectedID = nil
        let acceptedUnviewed = await model.setFavorite([unviewed.id], to: true)
        XCTAssertTrue(acceptedUnviewed)
        XCTAssertEqual(store.assets.map(\.id), originalOrder, "Favoriting an unviewed result must not invent a visit")
        let current = try XCTUnwrap(model.results.first { $0.id == first.id })
        let reversed = await model.toggleFavorite(current)
        XCTAssertTrue(reversed)
        XCTAssertEqual(writes.map(\.0), [first.id, second.id, unviewed.id, first.id])
        XCTAssertEqual(writes.map(\.1), [true, true, true, false])
        XCTAssertEqual(store.assets.map(\.id), originalOrder)
        XCTAssertFalse(store.assets.last?.isFavorite ?? true)
        XCTAssertFalse(RecentlyViewedStore(owner: owner, defaults: defaults, dataManager: manager).assets.last?.isFavorite ?? true)
    }

    private func fixture(dataManager: SwiftDataManager? = nil) -> SearchOptionsFixture {
        let fixture = SearchOptionsFixture(dataManager: dataManager)
        fixtures.append(fixture)
        return fixture
    }

    private func isolatedStore() throws -> SwiftDataManager {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("search-location-options-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let manager = SwiftDataManager(storeURL: directory.appendingPathComponent("test.store"),
            backupJournalURL: directory.appendingPathComponent("backup.json"))
        isolatedStores.append((directory, manager))
        return manager
    }
}

@MainActor
private final class SearchOptionsFixture {
    let search: OptionsSearchRepository
    let people: OptionsPeopleRepository
    let albums: OptionsAlbumRepository
    let model: SearchViewModel

    init(dataManager: SwiftDataManager? = nil) {
        let api = makeStubAPIClient()
        search = OptionsSearchRepository(api: api)
        people = OptionsPeopleRepository(api: api)
        albums = OptionsAlbumRepository(api: api)
        model = SearchViewModel(repo: search, assetRepo: AssetDetailRepository(api: api), albumRepo: albums,
            peopleRepo: people, dataManager: dataManager)
    }
}

private final class OptionsSearchRepository: SearchRepository {
    let probe = SearchRequestProbe()
    @MainActor var suggestionReads: [String: Int] = [:]
    @MainActor var suggestionsOperation: (String, Int) async throws -> [String] = { _, _ in [] }
    @MainActor var optionsSent: [PhotoSearchOptions] = []
    @MainActor var response: ((SearchRequestDTO) -> SearchResponseDTO)?
    @MainActor var searchOperation: ((SearchRequestDTO) async throws -> SearchResponseDTO)?

    @MainActor
    override func search(_ request: SearchRequestDTO, options: PhotoSearchOptions = .init()) async throws -> SearchResponseDTO {
        optionsSent.append(options)
        if let searchOperation { return try await searchOperation(request) }
        if let response { return response(request) }
        return try await probe.perform(request, endpoint: request.query == nil ? .metadata : .smart)
    }

    override func suggestions(type: String = "city") async throws -> [String] {
        try await suggestionsFor(type)
    }

    @MainActor
    private func suggestionsFor(_ type: String) async throws -> [String] {
        suggestionReads[type, default: 0] += 1
        return try await suggestionsOperation(type, suggestionReads[type]!)
    }
}

private final class OptionsPeopleRepository: PeopleRepository {
    @MainActor var values: [PersonDTO] = []
    @MainActor var reads = 0
    @MainActor var sizes: [Int?] = []
    @MainActor var operation: ((Int) async throws -> [PersonDTO])?

    override func all(size: Int? = nil) async throws -> [PersonDTO] { try await directory(size) }

    @MainActor
    private func directory(_ size: Int?) async throws -> [PersonDTO] {
        reads += 1
        sizes.append(size)
        return try await operation?(reads) ?? values
    }
}

private final class OptionsAlbumRepository: AlbumRepository {
    @MainActor var values: [AlbumResponseDTO] = []
    @MainActor var reads = 0
    @MainActor var operation: (() async throws -> [AlbumResponseDTO])?
    override func all() async throws -> [AlbumResponseDTO] { try await directory() }
    @MainActor private func directory() async throws -> [AlbumResponseDTO] {
        reads += 1
        return try await operation?() ?? values
    }
}
