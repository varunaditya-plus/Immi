import Foundation
import SwiftData
import XCTest
@testable import ImmichApp

@MainActor
final class PhotoSearchRepositoryTests: XCTestCase {
    private var directory: URL!
    private var store: SwiftDataManager!
    private var gates: [PhotoSearchResponseGate] = []
    private var tasks: [Task<SearchResponseDTO, Error>] = []

    override func setUp() async throws {
        try await super.setUp()
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("photo-search-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        store = SwiftDataManager(storeURL: directory.appendingPathComponent("test.store"),
            backupJournalURL: directory.appendingPathComponent("backup.json"))
        RemovedAssets.shared.clear()
        DeletedServerAssetRegistry.shared.clear()
    }

    override func tearDown() async throws {
        for gate in gates { gate.finish(.failure(CancellationError())) }
        for task in tasks { _ = try? await task.value }
        PhotoSearchURLProtocol.handler = nil
        gates.removeAll()
        tasks.removeAll()
        RemovedAssets.shared.clear()
        DeletedServerAssetRegistry.shared.clear()
        let container = store.modelContainer
        store = nil
        try container.erase()
        try? FileManager.default.removeItem(at: directory)
        try await super.tearDown()
    }

    func testRealTransportUnionsCompleteIndependentTextSourcesAndKeepsEveryFilter() async throws {
        let api = try api()
        let log = PhotoSearchRequestLog()
        let oldest = asset("not-favorite", captured: 1, favorite: false, edited: true)
        let unedited = asset("not-edited", captured: 2, favorite: true, edited: false)
        let caption = asset("caption-only", captured: 3, favorite: true, edited: true)
        let filename = asset("filename-only", captured: 4, favorite: true, edited: true)
        let text = asset("ocr-only", captured: 5, favorite: true, edited: true)
        PhotoSearchURLProtocol.handler = { request, bytes in
            let body = try log.record(request, data: bytes)
            switch (request.url?.lastPathComponent, body["page"] as? Int) {
            case ("smart", 1): return try Self.data([oldest], next: "5")
            case ("smart", 5): return try Self.data([oldest, unedited])
            default:
                if body["description"] != nil { return try Self.data([caption, unedited]) }
                if body["originalFileName"] != nil { return try Self.data([filename, caption]) }
                if body["ocr"] != nil { return try Self.data([text]) }
                throw URLError(.unsupportedURL)
            }
        }
        let repository = PhotoSearchRepository(api: api, dataManager: store)
        var request = SearchRequestDTO(query: "receipt", page: 1, albumIds: ["album"], type: "VIDEO",
            takenAfter: "2020-01-01T00:00:00Z", takenBefore: "2030-01-01T00:00:00Z",
            city: "Barcelona", state: "Catalonia", country: "Spain", personIds: ["person-a", "person-b"], size: 1)
        request.exclusiveTakenBefore = request.takenBefore
        let options = PhotoSearchOptions(favoritesOnly: true, editedOnly: true)

        let first = try await repository.search(request, options: options)
        request.page = 2
        let second = try await repository.search(request, options: options)
        request.page = 3
        let third = try await repository.search(request, options: options)

        XCTAssertEqual(first.assets.items.map(\.id), [text.id])
        XCTAssertEqual(second.assets.items.map(\.id), [filename.id])
        XCTAssertEqual(third.assets.items.map(\.id), [caption.id])
        XCTAssertEqual(first.assets.total, 3)
        XCTAssertEqual(first.assets.nextPage, "2")
        XCTAssertNil(third.assets.nextPage)
        XCTAssertNil(first.incompleteSources)
        let entries = log.entries
        XCTAssertEqual(entries.count, 4, "Local result pages must reuse the complete metadata union and bounded visual matches")
        for entry in entries {
            let body = entry.body
            XCTAssertEqual(body["albumIds"] as? [String], ["album"])
            XCTAssertEqual(body["personIds"] as? [String], ["person-a", "person-b"])
            XCTAssertEqual(body["city"] as? String, "Barcelona")
            XCTAssertEqual(body["state"] as? String, "Catalonia")
            XCTAssertEqual(body["country"] as? String, "Spain")
            XCTAssertEqual(body["type"] as? String, "VIDEO")
            XCTAssertEqual(body["isFavorite"] as? Bool, true)
            XCTAssertEqual(body["takenAfter"] as? String, request.takenAfter)
            XCTAssertEqual(body["takenBefore"] as? String, request.takenBefore)
            XCTAssertEqual(body["visibility"] as? String, "timeline")
            XCTAssertEqual(body["withExif"] as? Bool, true)
            XCTAssertEqual(body["size"] as? Int, entry.path.hasSuffix("/smart") ? PhotoSearchRepository.semanticResultLimit : 1_000)
            XCTAssertNil(body["exclusiveTakenBefore"])
            XCTAssertNil(body["filter"], "The adapter must retain the compatible legacy request shape")
            let textFields = ["query", "description", "originalFileName", "ocr"].filter { body[$0] != nil }
            XCTAssertEqual(textFields.count, 1, "Independent text matches must be unioned rather than intersected")
            XCTAssertEqual(body[textFields[0]] as? String, "receipt")
            XCTAssertEqual(entry.path.hasSuffix("/smart"), textFields == ["query"])
        }
    }

    func testTypedPatternCharactersMatchLiteralMetadataWithoutChangingVisualOrOCRText() async throws {
        let api = try api()
        let repository = PhotoSearchRepository(api: api, dataManager: store)
        let cases = [
            ("IMG_1234", #"IMG\_1234"#, "IMGX1234"),
            ("100% paid", #"100\% paid"#, "1000 paid"),
            (#"folder\photo"#, #"folder\\photo"#, "folderphoto"),
            (#"100%_paid\receipt"#, #"100\%\_paid\\receipt"#, "1000Xpaidreceipt"),
        ]
        for (query, escaped, unrelated) in cases {
            let log = PhotoSearchRequestLog()
            let literal = asset("literal", captured: 1)
            let embedded = asset("embedded", captured: 2)
            let decoy = asset("unrelated", captured: 3)
            let candidates = [(query, literal), ("prefix \(query) suffix", embedded), (unrelated, decoy)]
            PhotoSearchURLProtocol.handler = { request, bytes in
                let body = try log.record(request, data: bytes)
                guard let pattern = (body["description"] ?? body["originalFileName"]) as? String else {
                    return try Self.data([])
                }
                let matches = try candidates.filter { try Self.matchesLegacyPattern(pattern, value: $0.0) }.map(\.1)
                return try Self.data(matches)
            }

            let result = try await repository.search(SearchRequestDTO(query: query))

            XCTAssertEqual(result.assets.items.map(\.id), [embedded.id, literal.id], query)
            XCTAssertEqual(result.assets.total, 2)
            XCTAssertNil(result.incompleteSources)
            let entries = log.entries
            XCTAssertEqual(entries.count, 4)
            XCTAssertEqual(entries.compactMap { $0.body["description"] as? String }, [escaped])
            XCTAssertEqual(entries.compactMap { $0.body["originalFileName"] as? String }, [escaped])
            XCTAssertEqual(entries.compactMap { $0.body["query"] as? String }, [query])
            XCTAssertEqual(entries.compactMap { $0.body["ocr"] as? String }, [query])
        }
    }

    func testExplicitLegacyMetadataPatternsRetainTheirOriginalContract() async throws {
        let api = try api()
        let repository = PhotoSearchRepository(api: api, dataManager: store)
        let log = PhotoSearchRequestLog()
        PhotoSearchURLProtocol.handler = { request, bytes in
            _ = try log.record(request, data: bytes)
            return try Self.data([])
        }
        let request = SearchRequestDTO(description: #"trip_%\photo"#,
            originalFileName: #"IMG_%\2024"#, ocr: "invoice_100%")

        _ = try await repository.search(request)

        let entry = try XCTUnwrap(log.entries.first)
        XCTAssertEqual(log.entries.count, 1)
        XCTAssertTrue(entry.path.hasSuffix("/metadata"))
        XCTAssertNil(entry.body["query"])
        XCTAssertEqual(entry.body["description"] as? String, request.description)
        XCTAssertEqual(entry.body["originalFileName"] as? String, request.originalFileName)
        XCTAssertEqual(entry.body["ocr"] as? String, request.ocr)
    }

    func testVisualSearchStopsAtItsRankedLimitWhileEveryExactMetadataSourceFollowsItsContinuation() async throws {
        let (repository, source) = try scripted()
        var smartPages: [Int] = []
        var metadataPages: [String: [Int]] = [:]
        source.handler = { request, smart in
            if smart {
                smartPages.append(request.page ?? 0)
                XCTAssertEqual(request.size, PhotoSearchRepository.semanticResultLimit)
                return request.page == 1
                    ? Self.response([self.asset("top-visual", captured: 1)], next: "2")
                    : Self.response([self.asset("unrelated-tail", captured: 100)])
            }
            let kind = request.description != nil ? "caption" : request.originalFileName != nil ? "filename" : "ocr"
            metadataPages[kind, default: []].append(request.page ?? 0)
            XCTAssertEqual(request.size, 1_000)
            return request.page == 1
                ? Self.response([self.asset("\(kind)-first", captured: 2)], next: "4")
                : Self.response([self.asset("\(kind)-last", captured: 3)])
        }

        let result = try await repository.search(SearchRequestDTO(query: "receipt"))

        XCTAssertEqual(smartPages, [1], "Paging semantic ranks would eventually admit unrelated photos from the whole library")
        XCTAssertEqual(metadataPages, ["caption": [1, 4], "filename": [1, 4], "ocr": [1, 4]])
        XCTAssertEqual(Set(result.assets.items.map(\.id)), ["top-visual", "caption-first", "caption-last",
            "filename-first", "filename-last", "ocr-first", "ocr-last"])
        XCTAssertEqual(result.assets.total, 7)
        XCTAssertEqual(result.assets.items.last?.id, "top-visual", "Global date sorting follows collection of every exact match")
        XCTAssertNil(result.incompleteSources, "A deliberately bounded visual contribution is not a failed source")
    }

    func testRecentlyAddedSortUsesEverySourcePageBeforeReturningTheFirstResultPage() async throws {
        let (repository, source) = try scripted()
        var queriedPages: [Int] = []
        source.handler = { request, smart in
            XCTAssertFalse(smart)
            queriedPages.append(request.page ?? 0)
            return request.page == 1
                ? Self.response([self.asset("new-capture", captured: 20, added: 1)], next: "4")
                : Self.response([self.asset("old-capture-new-import", captured: 1, added: 20)])
        }
        let first = try await repository.search(SearchRequestDTO(size: 1),
            options: PhotoSearchOptions(sortOrder: .recentlyAdded))

        XCTAssertEqual(first.assets.items.map(\.id), ["old-capture-new-import"])
        XCTAssertEqual(first.assets.total, 2)
        XCTAssertEqual(queriedPages, [1, 4])
    }

    func testFailedLaterTextPageDiscardsThatPartialStreamAndExplicitRefreshRetriesIt() async throws {
        let (repository, source) = try scripted()
        var shouldFail = true
        var captionPages: [Int] = []
        source.handler = { request, smart in
            if smart { return Self.response([self.asset("smart", captured: 1)]) }
            if request.description != nil {
                captionPages.append(request.page ?? 0)
                if request.page == 1 { return Self.response([self.asset("partial-caption", captured: 3)], next: "2") }
                if shouldFail { throw APIError.notConnected }
                return Self.response([self.asset("last-caption", captured: 4)])
            }
            return Self.response([self.asset("text", captured: 2)])
        }
        let request = SearchRequestDTO(query: "picnic")
        let partial = try await repository.search(request)
        XCTAssertEqual(partial.assets.items.map(\.id), ["text", "smart"])
        XCTAssertEqual(partial.incompleteSources, ["caption"])
        XCTAssertFalse(partial.assets.items.contains { $0.id == "partial-caption" })

        shouldFail = false
        let complete = try await repository.search(request)

        XCTAssertEqual(complete.assets.items.map(\.id), ["last-caption", "partial-caption", "text", "smart"])
        XCTAssertNil(complete.incompleteSources)
        XCTAssertEqual(captionPages, [1, 2, 1, 2])
    }

    func testAllSourcesFailInsteadOfPublishingAnEmptySuccessfulSearch() async throws {
        let (repository, source) = try scripted()
        var sources = 0
        source.handler = { _, _ in sources += 1; throw APIError.notConnected }

        do {
            _ = try await repository.search(SearchRequestDTO(query: "receipt"))
            XCTFail("An unavailable search must not look like no matching photos")
        } catch APIError.notConnected {}
        catch { XCTFail("Expected the source error, received \(error)") }
        XCTAssertEqual(sources, 4)
    }

    func testOneCompleteEmptySourceCanReportPartialResultsWithoutInventingMatches() async throws {
        let (repository, source) = try scripted()
        source.handler = { _, smart in
            if smart { return Self.response([]) }
            throw APIError.notConnected
        }

        let result = try await repository.search(SearchRequestDTO(query: "unmatched"))

        XCTAssertTrue(result.assets.items.isEmpty)
        XCTAssertEqual(result.assets.total, 0)
        XCTAssertEqual(result.incompleteSources, ["caption", "filename", "ocr"])
    }

    func testInvalidOrRepeatedContinuationsCannotPublishAPartialMetadataIndex() async throws {
        for continuation in ["1", "invalid", "2"] {
            let (repository, source) = try scripted()
            var pages: [Int] = []
            source.handler = { request, _ in
                pages.append(request.page ?? 0)
                return Self.response([self.asset("repeated", captured: 1)],
                    next: request.page == 1 ? continuation : "3")
            }
            do {
                _ = try await repository.search(SearchRequestDTO(city: "Barcelona"))
                XCTFail("A broken continuation must not return the first page as a complete search")
            } catch PhotoSearchError.incompletePage {}
            catch { XCTFail("Expected incomplete-page error, received \(error)") }
            XCTAssertEqual(pages, continuation == "2" ? [1, 2] : [1])
        }
    }

    func testCachedPagesRecheckPrivacyWithoutShiftingPastUnseenPhotos() async throws {
        let (repository, source) = try scripted()
        var queries = 0
        source.handler = { _, _ in
            queries += 1
            return Self.response((0..<5).map { self.asset("photo-\($0)", captured: Double(5 - $0)) })
        }
        var request = SearchRequestDTO(size: 1)
        let first = try await repository.search(request)
        XCTAssertEqual(first.assets.items.map(\.id), ["photo-0"])
        try store.setAssetVisibility(["photo-0", "photo-1", "photo-2"], to: "locked")
        request.page = 2

        let next = try await repository.search(request)
        XCTAssertEqual(next.assets.items.map(\.id), ["photo-3"])
        XCTAssertEqual(next.assets.total, 2)
        XCTAssertEqual(next.assets.nextPage, "5", "Empty private windows must advance without losing an unseen photo")
        request.page = 5
        let last = try await repository.search(request)
        XCTAssertEqual(last.assets.items.map(\.id), ["photo-4"])
        XCTAssertNil(last.assets.nextPage)
        XCTAssertEqual(queries, 1)
    }

    func testPrivateAndTrashedMetadataNeverEnterTheCompleteIndex() async throws {
        let (repository, source) = try scripted()
        var locked = asset("locked", captured: 4)
        locked.visibility = "locked"
        let archived = makeTestAsset(id: "archive", isArchived: true)
        let trash = makeTestAsset(id: "trash", isTrashed: true)
        try store.setAssetVisibility(["stale-public"], to: "locked")
        source.handler = { _, _ in
            Self.response([locked, archived, trash, self.asset("stale-public", captured: 3), self.asset("public", captured: 1)])
        }

        let result = try await repository.search(SearchRequestDTO())

        XCTAssertEqual(result.assets.items.map(\.id), ["public"])
        XCTAssertEqual(result.assets.total, 1)
    }

    func testARefreshDefeatsAnOlderNoncooperativeResponseAndItsCachePublication() async throws {
        let (repository, source) = try scripted()
        let held = gate()
        var queries = 0
        source.handler = { _, _ in
            queries += 1
            if queries == 1 { return try await held.value() }
            return Self.response([self.asset("current-first", captured: 3), self.asset("current-last", captured: 2)])
        }
        let request = SearchRequestDTO(size: 1)
        let old = Task { try await repository.search(request) }
        tasks.append(old)
        await fulfillment(of: [held.started], timeout: 2)

        let current = try await repository.search(request)
        held.finish(.success(Self.response([asset("obsolete", captured: 100)])))
        await expectCancellation { try await old.value }
        var next = request
        next.page = 2
        let last = try await repository.search(next)

        XCTAssertEqual(current.assets.items.map(\.id), ["current-first"])
        XCTAssertEqual(last.assets.items.map(\.id), ["current-last"])
        XCTAssertEqual(queries, 2)
    }

    func testAContextOrAccountChangeRejectsHeldResultsAndExistingCachedPages() async throws {
        for changesAccount in [false, true] {
            let session = MockSessionManager()
            try session.setServer("https://search-context.example")
            let api = APIClient(session: session)
            let source = ScriptedPhotoSearchRepository(api: api)
            let repository = PhotoSearchRepository(api: api, dataManager: store, source: source)
            let held = gate()
            source.handler = { _, _ in try await held.value() }
            let pending = Task { try await repository.search(SearchRequestDTO(size: 1)) }
            tasks.append(pending)
            await fulfillment(of: [held.started], timeout: 2)

            if changesAccount { LocalSnapshot.clearAll() }
            else { try session.setServer("https://different-search-context.example") }
            held.finish(.success(Self.response([asset("old-account", captured: 1)])))

            await expectCancellation { try await pending.value }
            do {
                _ = try await repository.search(SearchRequestDTO(page: 2, size: 1))
                XCTFail("A stale adapter cannot serve a cached page in the new context")
            } catch is CancellationError {}
            catch PhotoSearchError.missingCachedSearch {}
            catch { XCTFail("Expected cancellation or invalidated cache, received \(error)") }
        }
    }

    func testCachedPagesCannotCrossAServerContextChangeWithoutAnAccountReset() async throws {
        let session = MockSessionManager()
        try session.setServer("https://old-search-context.example")
        let api = APIClient(session: session)
        let source = ScriptedPhotoSearchRepository(api: api)
        source.handler = { _, _ in
            Self.response([self.asset("first-server", captured: 2), self.asset("last-server", captured: 1)])
        }
        let repository = PhotoSearchRepository(api: api, dataManager: store, source: source)
        _ = try await repository.search(SearchRequestDTO(size: 1))

        try session.setServer("https://new-search-context.example")

        await expectCancellation { try await repository.search(SearchRequestDTO(page: 2, size: 1)) }
    }

    func testAPrivacyMutationWhileSourcesAreHeldIsAppliedBeforeTheIndexPublishes() async throws {
        let (repository, source) = try scripted()
        let held = gate()
        source.handler = { _, _ in try await held.value() }
        let pending = Task { try await repository.search(SearchRequestDTO()) }
        tasks.append(pending)
        await fulfillment(of: [held.started], timeout: 2)
        try store.setAssetVisibility(["changed-private"], to: "locked")
        held.finish(.success(Self.response([asset("changed-private", captured: 2), asset("kept", captured: 1)])))

        let result = try await pending.value

        XCTAssertEqual(result.assets.items.map(\.id), ["kept"])
        XCTAssertEqual(result.assets.total, 1)
    }

    func testCallerCancellationCannotPopulateTheIndexFromANoncooperativeSource() async throws {
        let (repository, source) = try scripted()
        let held = gate()
        source.handler = { _, _ in try await held.value() }
        let pending = Task { try await repository.search(SearchRequestDTO()) }
        tasks.append(pending)
        await fulfillment(of: [held.started], timeout: 2)
        pending.cancel()
        held.finish(.success(Self.response([asset("obsolete", captured: 1)])))

        await expectCancellation { try await pending.value }
        source.handler = { _, _ in Self.response([self.asset("fresh", captured: 2)]) }
        let fresh = try await repository.search(SearchRequestDTO())
        XCTAssertEqual(fresh.assets.items.map(\.id), ["fresh"])
    }

    func testExactCalendarUpperBoundKeepsFractionalLastMomentAndExcludesNextMidnight() async throws {
        let (repository, source) = try scripted()
        let end = Date(timeIntervalSince1970: 1_800_000_000)
        source.handler = { _, _ in
            Self.response([self.asset("last-moment", captured: end.timeIntervalSince1970 - 0.0001),
                self.asset("next-midnight", captured: end.timeIntervalSince1970),
                self.asset("later", captured: end.timeIntervalSince1970 + 1)])
        }
        var request = SearchRequestDTO(takenBefore: ISO8601DateFormatter.immichFractional.string(from: end))
        request.exclusiveTakenBefore = request.takenBefore

        let result = try await repository.search(request)

        XCTAssertEqual(result.assets.items.map(\.id), ["last-moment"])
    }

    func testUnavailableClassificationAndImportDatesFailClearlyInsteadOfInventingRefinements() async throws {
        let (repository, source) = try scripted()
        source.handler = { _, _ in Self.response([self.asset("legacy", captured: 1)]) }
        do {
            _ = try await repository.search(SearchRequestDTO(), options: PhotoSearchOptions(editedOnly: true))
            XCTFail("Unknown edit flags cannot be treated as unedited")
        } catch PhotoSearchError.missingEditInformation {}
        do {
            _ = try await repository.search(SearchRequestDTO(), options: PhotoSearchOptions(sortOrder: .recentlyAdded))
            XCTFail("Capture dates cannot pretend to be import dates")
        } catch PhotoSearchError.missingAddedDates {}
    }

    func testExactCountsRequireTheSameQueryOptionsAndLiveAccountContext() async throws {
        let api = try api()
        let source = ScriptedPhotoSearchRepository(api: api)
        source.handler = { _, _ in
            Self.response([self.asset("count-a", captured: 2), self.asset("count-b", captured: 1)])
        }
        let repository = PhotoSearchRepository(api: api, dataManager: store, source: source)
        let request = SearchRequestDTO(city: "Barcelona")
        XCTAssertNil(repository.exactResultCount(for: request, options: .init(), excluding: []))
        _ = try await repository.search(request)

        XCTAssertEqual(repository.exactResultCount(for: request, options: .init(), excluding: ["count-a"]), 1)
        XCTAssertNil(repository.exactResultCount(for: SearchRequestDTO(city: "Jakarta"), options: .init(), excluding: []))
        XCTAssertNil(repository.exactResultCount(for: request,
            options: PhotoSearchOptions(sortOrder: .recentlyAdded), excluding: []))
        try api.session.setServer("https://changed-count-context.example")
        XCTAssertNil(repository.exactResultCount(for: request, options: .init(), excluding: []))
        LocalSnapshot.clearAll()
        XCTAssertNil(repository.exactResultCount(for: request, options: .init(), excluding: []))
    }

    private func api() throws -> APIClient {
        let session = MockSessionManager()
        try session.setServer("https://photo-search.example")
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [PhotoSearchURLProtocol.self]
        return APIClient(session: session, urlSession: URLSession(configuration: configuration))
    }

    private func scripted() throws -> (PhotoSearchRepository, ScriptedPhotoSearchRepository) {
        let api = try api()
        let source = ScriptedPhotoSearchRepository(api: api)
        return (PhotoSearchRepository(api: api, dataManager: store, source: source), source)
    }

    private func gate() -> PhotoSearchResponseGate {
        let value = PhotoSearchResponseGate()
        gates.append(value)
        return value
    }

    private func asset(_ id: String, captured: Double, added: Double? = nil,
                       favorite: Bool = false, edited: Bool? = nil) -> AssetResponseDTO {
        var asset = makeTestAsset(id: id, type: "VIDEO", isFavorite: favorite)
        asset.fileCreatedAt = Date(timeIntervalSince1970: captured < 100 ? 1_700_000_000 + captured : captured)
        asset.addedAt = added.map { Date(timeIntervalSince1970: 1_700_000_000 + $0) }
        asset.isEdited = edited
        return asset
    }

    private func expectCancellation(_ operation: () async throws -> SearchResponseDTO,
                                    file: StaticString = #filePath, line: UInt = #line) async {
        do { _ = try await operation(); XCTFail("Obsolete searches must not publish results", file: file, line: line) }
        catch is CancellationError {}
        catch { XCTFail("Expected cancellation, received \(error)", file: file, line: line) }
    }

    private nonisolated static func response(_ items: [AssetResponseDTO], next: String? = nil) -> SearchResponseDTO {
        SearchResponseDTO(assets: .init(items: items, total: items.count, nextPage: next))
    }

    private nonisolated static func matchesLegacyPattern(_ pattern: String, value: String) throws -> Bool {
        var expression = "^.*"
        var characters = pattern.makeIterator()
        while let character = characters.next() {
            switch character {
            case "\\":
                guard let literal = characters.next() else { throw URLError(.badServerResponse) }
                expression += NSRegularExpression.escapedPattern(for: String(literal))
            case "%": expression += ".*"
            case "_": expression += "."
            default: expression += NSRegularExpression.escapedPattern(for: String(character))
            }
        }
        expression += ".*$"
        let regex = try NSRegularExpression(pattern: expression, options: [.caseInsensitive, .dotMatchesLineSeparators])
        return regex.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)) != nil
    }

    private nonisolated static func data(_ items: [AssetResponseDTO], next: String? = nil) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let values = try JSONSerialization.jsonObject(with: encoder.encode(items))
        return try JSONSerialization.data(withJSONObject: ["assets": [
            "items": values, "total": items.count, "nextPage": next as Any? ?? NSNull(),
        ]])
    }
}

private final class ScriptedPhotoSearchRepository: SearchRepository {
    @MainActor var handler: (SearchRequestDTO, Bool) async throws -> SearchResponseDTO = { _, _ in
        throw URLError(.unsupportedURL)
    }
    override func smartSearch(_ request: SearchRequestDTO) async throws -> SearchResponseDTO { try await handler(request, true) }
    override func metadataSearch(_ request: SearchRequestDTO) async throws -> SearchResponseDTO { try await handler(request, false) }
}

@MainActor
private final class PhotoSearchResponseGate {
    let started = XCTestExpectation(description: "The complete search source is held")
    private var continuation: CheckedContinuation<SearchResponseDTO, Error>?
    private var result: Result<SearchResponseDTO, Error>?

    func value() async throws -> SearchResponseDTO {
        if let result { return try result.get() }
        return try await withCheckedThrowingContinuation {
            continuation = $0
            started.fulfill()
        }
    }

    func finish(_ result: Result<SearchResponseDTO, Error>) {
        self.result = result
        continuation?.resume(with: result)
        continuation = nil
    }
}

private final class PhotoSearchRequestLog {
    struct Entry { let path: String; let body: [String: Any] }
    private let lock = NSLock()
    private var recorded: [Entry] = []
    var entries: [Entry] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }
    func record(_ request: URLRequest, data: Data) throws -> [String: Any] {
        let body = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
        lock.lock()
        recorded.append(Entry(path: request.url?.path ?? "", body: body))
        lock.unlock()
        return body
    }
}

private final class PhotoSearchURLProtocol: URLProtocol {
    static var handler: ((URLRequest, Data) throws -> Data)?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            guard let handler = Self.handler else { throw URLError(.unsupportedURL) }
            var body = request.httpBody ?? Data()
            if body.isEmpty, let stream = request.httpBodyStream {
                stream.open()
                defer { stream.close() }
                var buffer = [UInt8](repeating: 0, count: 4_096)
                while stream.hasBytesAvailable {
                    let count = stream.read(&buffer, maxLength: buffer.count)
                    if count <= 0 { break }
                    body.append(contentsOf: buffer.prefix(count))
                }
            }
            let bytes = try handler(request, body)
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: bytes)
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}
