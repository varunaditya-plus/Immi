import Foundation
import XCTest
@testable import ImmichApp

@MainActor
final class SearchSuggestionsTests: XCTestCase {
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

    func testEntitySuggestionsAreDeterministicDeduplicatedAndExcludeHiddenSelectedOrUnnamedPeople() {
        let maya = makePeopleStatePerson("maya", name: "Maya")
        let hidden = makePeopleStatePerson("hidden", name: "Maya Hidden", hidden: true)
        let unnamed = makePeopleStatePerson("unnamed", name: "")
        let result = SearchSuggestions.tokens(for: "ma", people: [hidden, maya, unnamed, maya],
            cities: ["Madrid", "Madrid"], states: ["Maharashtra"], countries: ["Malaysia"], albums: [])
        let entities = result.filter { if case .date = $0 { false } else { true } }
        XCTAssertEqual(entities.map(\.title), ["Madrid", "Maharashtra", "Malaysia", "Maya"])
        XCTAssertEqual(Set(result.map(\.id)).count, result.count)
        let selected = SearchSuggestions.tokens(for: "Maya", people: [maya, hidden], cities: [], states: [],
            countries: [], albums: [], selected: [.person(maya)])
        XCTAssertTrue(selected.isEmpty)
    }

    func testDateSuggestionsRecognizeValidLeapDaysMonthsAndYearsWithoutNormalizingInvalidDays() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "UTC"))
        let now = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 11, day: 1)))
        let suggestions: (String) -> [SearchToken] = { query in
            SearchSuggestions.tokens(for: query, people: [], cities: [], states: [], countries: [], albums: [],
                now: now, calendar: calendar, locale: Locale(identifier: "en_US"))
        }
        XCTAssertTrue(suggestions("2024").contains(.date(.year(2024))))
        XCTAssertTrue(suggestions("February 2024").contains(.date(.month(year: 2024, month: 2))))
        let leap = try XCTUnwrap(calendar.date(from: DateComponents(year: 2024, month: 2, day: 29)))
        XCTAssertTrue(suggestions("2024-02-29").contains(.date(.day(leap))))
        XCTAssertTrue(suggestions("2023-02-29").isEmpty)
        XCTAssertEqual(SearchSuggestions.remainingQuery("2024-02-29", after: .date(.day(leap)),
            now: now, calendar: calendar, locale: Locale(identifier: "en_US")), "")
    }

    func testPartialMonthSuggestionsRetainPersonAndPlaceAlternativesAndExcludeSelectedDates() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "UTC"))
        let now = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 11, day: 1)))
        let selena = makePeopleStatePerson("selena", name: "Selena")
        let september = SearchToken.date(.month(year: 2026, month: 9))
        let suggestions = SearchSuggestions.tokens(for: "se", people: [selena], cities: ["Sevilla"], states: [],
            countries: [], albums: [], now: now, calendar: calendar, locale: Locale(identifier: "en_US"))
        XCTAssertEqual(Set(suggestions.map(\.id)), [september.id, SearchToken.person(selena).id, SearchToken.city("Sevilla").id])
        let selected = SearchSuggestions.tokens(for: "SE", people: [selena], cities: ["Sevilla"], states: [],
            countries: [], albums: [], selected: [september], now: now, calendar: calendar, locale: Locale(identifier: "en_US"))
        XCTAssertEqual(Set(selected.map(\.id)), [SearchToken.person(selena).id, SearchToken.city("Sevilla").id])
        let tooShort = SearchSuggestions.tokens(for: "s", people: [], cities: [], states: [], countries: [], albums: [],
            now: now, calendar: calendar, locale: Locale(identifier: "en_US"))
        XCTAssertFalse(tooShort.contains { if case .date(.month) = $0 { true } else { false } })
    }

    func testMonthPrefixesUseTheRequestedLocaleAndPreserveAnExplicitYear() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "UTC"))
        let now = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 11, day: 1)))
        func suggestions(_ query: String, locale: String) -> [SearchToken] {
            SearchSuggestions.tokens(for: query, people: [], cities: [], states: [], countries: [], albums: [],
                now: now, calendar: calendar, locale: Locale(identifier: locale))
        }
        XCTAssertTrue(suggestions("sep", locale: "es_ES").contains(.date(.month(year: 2026, month: 9))))
        XCTAssertTrue(suggestions("SE 2024", locale: "en_US").contains(.date(.month(year: 2024, month: 9))))
        XCTAssertTrue(suggestions("2024 September", locale: "en_US").contains(.date(.month(year: 2024, month: 9))))
        XCTAssertTrue(suggestions("fev", locale: "fr_FR").contains(.date(.month(year: 2026, month: 2))),
            "Typing without the accent must still suggest février")
    }

    func testRelativeDayPrefixesUseTheSuppliedClockAndCalendar() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "America/New_York"))
        let now = try XCTUnwrap(calendar.date(from: DateComponents(year: 2024, month: 3, day: 10, hour: 12)))
        let today = calendar.startOfDay(for: now)
        let yesterday = try XCTUnwrap(calendar.date(byAdding: .day, value: -1, to: today))
        for (label, expected) in [(String(localized: "Today"), today), (String(localized: "Yesterday"), yesterday)] {
            let result = SearchSuggestions.tokens(for: String(label.prefix(2)), people: [], cities: [], states: [],
                countries: [], albums: [], now: now, calendar: calendar, locale: .current)
            XCTAssertTrue(result.contains(.date(.day(expected))))
        }
    }

    func testCommittedTextRecognizesCompleteDatesAndMediaWithoutGuessingPartialPrefixes() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "America/New_York"))
        let now = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 11, day: 1, hour: 12)))
        let leap = try XCTUnwrap(calendar.date(from: DateComponents(year: 2024, month: 2, day: 29)))
        let today = calendar.startOfDay(for: now)
        let yesterday = try XCTUnwrap(calendar.date(byAdding: .day, value: -1, to: today))
        let cases: [(String, SearchToken)] = [
            ("2024", .date(.year(2024))), ("September", .date(.month(year: 2026, month: 9))),
            ("September 2024", .date(.month(year: 2024, month: 9))),
            ("2024-02-29", .date(.day(leap))), ("2/29/2024", .date(.day(leap))),
            ("February 29, 2024", .date(.day(leap))), ("29 February 2024", .date(.day(leap))),
            ("Today", .date(.day(today))), ("Yesterday", .date(.day(yesterday))),
            ("Photos", .media(.image)), ("videos", .media(.video)), ("Live Photos", .media(.live)),
        ]
        for (text, expected) in cases {
            XCTAssertEqual(SearchSuggestions.committedToken(for: text, now: now, calendar: calendar,
                locale: Locale(identifier: "en_US")), expected, text)
        }
        for text in ["se", "ma", "Sep", "Feb 2024", "2023-02-29", "2024-02-30", "+999", "2024 hiking",
                     "January in Paris", "Last Month", "This Year", "Live", "photo", "video"] {
            XCTAssertNil(SearchSuggestions.committedToken(for: text, now: now, calendar: calendar,
                locale: Locale(identifier: "en_US")), text)
        }
        XCTAssertEqual(SearchSuggestions.committedToken(for: "29/02/2024", now: now, calendar: calendar,
            locale: Locale(identifier: "en_GB")), .date(.day(leap)))
    }

    func testCommittedYearAndFullDatesUseMetadataRequestsAndPreserveIndependentCriteria() async throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "UTC"))
        let now = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 11, day: 1)))
        for text in ["2024", "2024-02-29", "2/29/2024"] {
            let (model, repository) = fixture()
            let person = makePeopleStatePerson("ada", name: "Ada")
            let album = AlbumResponseDTO(id: "holiday", albumName: "Holiday", description: nil, assetCount: 0,
                albumThumbnailAssetId: nil, shared: false, createdAt: .distantPast, assets: nil)
            model.filters = SearchFilters(people: [person], city: "Paris", country: "France", album: album, mediaType: .live)

            XCTAssertEqual(model.commitSearchText(text, now: now, calendar: calendar, locale: Locale(identifier: "en_US")), "")
            let pending = Task { await model.search() }
            let sent = try await repository.probe.waitForRequest(0, testCase: self)

            XCTAssertEqual(sent.endpoint, .metadata)
            XCTAssertNil(sent.request.query)
            XCTAssertEqual(sent.request.personIds, [person.id])
            XCTAssertEqual(sent.request.albumIds, [album.id])
            XCTAssertEqual(sent.request.city, "Paris")
            XCTAssertEqual(sent.request.country, "France")
            XCTAssertEqual(sent.request.type, "IMAGE")
            XCTAssertEqual(sent.request.isMotion, true)
            XCTAssertNotNil(sent.request.takenAfter)
            XCTAssertNotNil(sent.request.exclusiveTakenBefore)
            try await repository.probe.succeed(0, ids: [], total: 0)
            await pending.value
        }
    }

    func testCommittedWrittenDatesFollowTheLocaleAndRejectInvalidCalendarDays() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "UTC"))
        let now = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 11, day: 1)))
        let leap = try XCTUnwrap(calendar.date(from: DateComponents(year: 2024, month: 2, day: 29)))
        let cases = [
            ("zh_Hans_CN", "2024年2月29日", "2023年2月29日", "2024年2月30日"),
            ("de_DE", "29. Februar 2024", "29. Februar 2023", "30. Februar 2024"),
            ("es_ES", "29 de febrero de 2024", "29 de febrero de 2023", "30 de febrero de 2024"),
        ]
        for (locale, valid, nonLeap, invalidDay) in cases {
            XCTAssertEqual(SearchSuggestions.committedToken(for: valid, now: now, calendar: calendar,
                locale: Locale(identifier: locale)), .date(.day(leap)), valid)
            XCTAssertNil(SearchSuggestions.committedToken(for: nonLeap, now: now, calendar: calendar,
                locale: Locale(identifier: locale)), nonLeap)
            XCTAssertNil(SearchSuggestions.committedToken(for: invalidDay, now: now, calendar: calendar,
                locale: Locale(identifier: locale)), invalidDay)
        }
    }

    func testCommittedPartialAndAmbiguousNamesStayDescriptiveSmartQueries() async throws {
        for text in ["se", "ma", "May", "2024", "2024 beach"] {
            let (model, repository) = fixture()
            let may = makePeopleStatePerson("may", name: "May")
            model.people = [may]
            model.albums = [AlbumResponseDTO(id: "year-album", albumName: "2024", description: nil, assetCount: 0,
                albumThumbnailAssetId: nil, shared: false, createdAt: .distantPast, assets: nil)]
            model.filters = SearchFilters(people: [may], city: "Paris", mediaType: .video)

            XCTAssertEqual(model.commitSearchText(text), text)
            let pending = Task { await model.search() }
            let sent = try await repository.probe.waitForRequest(0, testCase: self)

            XCTAssertEqual(sent.endpoint, .smart)
            XCTAssertEqual(sent.request.query, text)
            XCTAssertEqual(sent.request.personIds, [may.id])
            XCTAssertEqual(sent.request.city, "Paris")
            XCTAssertEqual(sent.request.type, "VIDEO")
            XCTAssertNil(sent.request.takenAfter)
            try await repository.probe.succeed(0, ids: [], total: 0)
            await pending.value
        }
    }

    func testCommittedMediaKeepsAnExistingDateAndPlaceInsteadOfSendingItsLabelToSmartSearch() async throws {
        let (model, repository) = fixture()
        model.filters = SearchFilters(city: "Paris", dateRange: .year(2024))

        XCTAssertEqual(model.commitSearchText("Live Photos", locale: Locale(identifier: "en_US")), "")
        let pending = Task { await model.search() }
        let sent = try await repository.probe.waitForRequest(0, testCase: self)

        XCTAssertEqual(sent.endpoint, .metadata)
        XCTAssertNil(sent.request.query)
        XCTAssertEqual(sent.request.type, "IMAGE")
        XCTAssertEqual(sent.request.isMotion, true)
        XCTAssertEqual(sent.request.city, "Paris")
        XCTAssertNotNil(sent.request.takenAfter)
        XCTAssertNotNil(sent.request.exclusiveTakenBefore)
        try await repository.probe.succeed(0, ids: [], total: 0)
        await pending.value
    }

    func testChoosingAPersonConsumesOnlyThatNameAndPreservesExistingCriteriaInTheActualRequest() async throws {
        let (model, repository) = fixture()
        let maya = makePeopleStatePerson("maya", name: "Maya")
        model.people = [maya]
        model.filters = SearchFilters(city: "Paris", dateRange: .year(2024), mediaType: .video)
        model.searchText = "Maya hiking"

        XCTAssertEqual(model.applySuggestion(.person(maya), consuming: "Maya hiking"), "hiking")
        let pending = Task { await model.search() }
        let request = try await repository.probe.waitForRequest(0, testCase: self)

        XCTAssertEqual(request.request.query, "hiking")
        XCTAssertEqual(request.request.personIds, ["maya"])
        XCTAssertEqual(request.request.city, "Paris")
        XCTAssertEqual(request.request.type, "VIDEO")
        XCTAssertNotNil(request.request.takenAfter)
        XCTAssertNotNil(request.request.exclusiveTakenBefore)
        try await repository.probe.succeed(0, ids: [], total: 0)
        await pending.value
    }

    func testRemovingOneTokenDoesNotDiscardOtherTokensOrTheDescriptiveQuery() async throws {
        let (model, repository) = fixture()
        let maya = makePeopleStatePerson("maya", name: "Maya")
        model.people = [maya]
        model.filters = SearchFilters(people: [maya], city: "Paris", country: "France", dateRange: .year(2024), mediaType: .live)
        model.searchText = "mountains"

        model.setTokens(model.tokens.filter { $0.id != SearchToken.city("Paris").id })
        let pending = Task { await model.search() }
        let request = try await repository.probe.waitForRequest(0, testCase: self)

        XCTAssertEqual(request.request.query, "mountains")
        XCTAssertNil(request.request.city)
        XCTAssertEqual(request.request.country, "France")
        XCTAssertEqual(request.request.personIds, ["maya"])
        XCTAssertEqual(request.request.isMotion, true)
        XCTAssertNotNil(request.request.takenAfter)
        try await repository.probe.succeed(0, ids: [], total: 0)
        await pending.value
    }

    func testPartialEntitySelectionConsumesItsPrefixButUnrelatedAndNewerInputRemain() {
        let person = SearchToken.person(makePeopleStatePerson("maya", name: "Maya"))
        XCTAssertEqual(SearchSuggestions.remainingQuery("May", after: person), "")
        XCTAssertEqual(SearchSuggestions.remainingQuery("mountains", after: person), "mountains")
        let ann = SearchToken.person(makePeopleStatePerson("ann", name: "Ann"))
        XCTAssertEqual(SearchSuggestions.remainingQuery("anniversary", after: ann), "anniversary")
        let (model, _) = fixture()
        model.people = [makePeopleStatePerson("maya", name: "Maya")]
        model.searchText = "newer input"
        XCTAssertEqual(model.applySuggestion(person, consuming: "May"), "newer input")
        XCTAssertEqual(model.filters.people.map(\.id), ["maya"])
    }

    func testRejectedPersonSuggestionsPreserveTheQueryCriteriaAndHeldSearch() async throws {
        for isHidden in [false, true] {
            let (model, repository) = fixture()
            let maya = makePeopleStatePerson("maya", name: "Maya")
            model.people = [maya]
            model.searchText = "May"
            let filters = SearchFilters(city: "Paris", country: "France", dateRange: .year(2024), mediaType: .video)
            model.filters = filters
            let pending = Task { await model.search() }
            let sent = try await repository.probe.waitForRequest(0, testCase: self)
            XCTAssertEqual(sent.request.query, "May")

            if isHidden {
                var hidden = maya
                hidden.isHidden = true
                model.applyPersonUpdate(.init(person: hidden, fields: [.hidden]))
            } else {
                model.people = []
            }
            XCTAssertEqual(model.applySuggestion(.person(maya), consuming: "May"), "May")

            XCTAssertEqual(model.searchText, "May")
            XCTAssertEqual(model.filters, filters)
            try await repository.probe.succeed(0, ids: ["current-result"], total: 1)
            await pending.value
            XCTAssertEqual(model.results.map(\.id), ["current-result"], "A rejected queued suggestion must not invalidate the current request")
            XCTAssertEqual(model.totalResults, 1)
            let requests = await repository.probe.requests
            XCTAssertEqual(requests.count, 1)
        }
    }

    func testRejectedAlbumSuggestionPreservesAnotherScopeAndTheHeldSearch() async throws {
        let (model, repository) = fixture()
        let removed = AlbumResponseDTO(id: "removed", albumName: "Holiday", description: nil, assetCount: 0,
            albumThumbnailAssetId: nil, shared: false, createdAt: .distantPast, assets: nil)
        let current = AlbumResponseDTO(id: "current", albumName: "Current", description: nil, assetCount: 0,
            albumThumbnailAssetId: nil, shared: false, createdAt: .distantPast, assets: nil)
        model.albums = [removed, current]
        model.searchText = "Holiday"
        let filters = SearchFilters(city: "Paris", album: current, dateRange: .year(2024), mediaType: .live)
        model.filters = filters
        let pending = Task { await model.search() }
        let sent = try await repository.probe.waitForRequest(0, testCase: self)
        XCTAssertEqual(sent.request.query, "Holiday")
        XCTAssertEqual(sent.request.albumIds, [current.id])
        model.removeAlbum(removed.id)

        XCTAssertEqual(model.applySuggestion(.album(removed), consuming: "Holiday"), "Holiday")

        XCTAssertEqual(model.searchText, "Holiday")
        XCTAssertEqual(model.filters, filters)
        try await repository.probe.succeed(0, ids: ["scoped-result"], total: 1)
        await pending.value
        XCTAssertEqual(model.results.map(\.id), ["scoped-result"], "A rejected album must not replace the live query or remove an independent scope")
        XCTAssertEqual(model.totalResults, 1)
        let requests = await repository.probe.requests
        XCTAssertEqual(requests.count, 1)
    }

    func testAConfirmedHideCannotBeRestoredByStaleTokens() {
        let (model, _) = fixture()
        let source = makePeopleStatePerson("source", name: "Maya")
        let target = makePeopleStatePerson("target", name: "Maya Current")
        model.people = [source, target]
        model.filters.people = [source]
        let stale = model.tokens
        var hidden = source
        hidden.isHidden = true
        model.applyPersonUpdate(.init(person: hidden, fields: [.hidden]))
        model.setTokens(stale)
        XCTAssertTrue(model.filters.people.isEmpty)
        XCTAssertEqual(model.people.map(\.id), [target.id])
    }

    func testLateNameAndFavoriteCallbacksCannotUnhideAPersonButAnExplicitUnhideCan() {
        let (model, _) = fixture()
        let original = makePeopleStatePerson("maya", name: "Maya")
        model.people = [original]
        model.filters.people = [original]
        var hidden = original
        hidden.isHidden = true
        model.applyPersonUpdate(.init(person: hidden, fields: [.hidden]))
        var renamed = original
        renamed.name = "Late Name"
        var favorite = original
        favorite.isFavorite = true

        model.applyPersonUpdate(.init(person: renamed, fields: [.name]))
        model.applyPersonUpdate(.init(person: favorite, fields: [.favorite]))

        XCTAssertTrue(model.people.isEmpty)
        XCTAssertTrue(model.filters.people.isEmpty)
        XCTAssertTrue(model.suggestedTokens(for: "Maya").isEmpty)

        model.applyPersonUpdate(.init(person: original, fields: [.hidden]))
        XCTAssertEqual(model.people.map(\.id), [original.id])
        XCTAssertEqual(model.suggestedTokens(for: "Maya").map(\.id), [SearchToken.person(original).id])
    }

    private func fixture() -> (SearchViewModel, ControlledSearchRepository) {
        let api = makeStubAPIClient()
        let repository = ControlledSearchRepository(api: api)
        let model = SearchViewModel(repo: repository, assetRepo: AssetDetailRepository(api: api), albumRepo: AlbumRepository(api: api))
        fixtures.append((model, repository))
        return (model, repository)
    }
}
