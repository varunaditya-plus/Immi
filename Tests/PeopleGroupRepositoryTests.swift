import XCTest
@testable import ImmichApp

@MainActor
final class PeopleGroupRepositoryTests: XCTestCase {
    func testCompletePagedQueryRequiresEveryPersonAndDistinguishesAdditionalPeople() async throws {
        let a = UUID().uuidString, b = UUID().uuidString, c = UUID().uuidString
        let strict = asset("strict", people: [a, b], offset: 1)
        let extra = asset("extra", people: [a, b, c], offset: 3)
        let last = asset("last-page", people: [b, a], offset: 2)
        let repository = GroupSearchRepository(api: makeStubAPIClient(), recordsVisibility: false)
        repository.pages = [
            1: page([strict, asset("one-person", people: [a]), asset("archive", people: [a, b], visibility: "archive")], next: "2"),
            2: page([extra, last, asset("trash", people: [a, b], trashed: true)])
        ]
        let groups = PeopleGroupRepository(repository: repository)

        let onlyGroup = try await groups.assets(personIDs: [a, b, a], includingOtherPeople: false)

        XCTAssertEqual(onlyGroup.map(\.id), [last.id, strict.id])
        XCTAssertEqual(repository.requests.map(\.page), [1, 2])
        for request in repository.requests {
            let body = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(request)) as? [String: Any])
            XCTAssertEqual(body["withPeople"] as? Bool, true)
            XCTAssertEqual(Set(try XCTUnwrap(body["personIds"] as? [String])), [a, b])
            XCTAssertEqual(body["visibility"] as? String, "timeline")
        }

        let withOthers = try await groups.assets(personIDs: [a, b], includingOtherPeople: true)

        XCTAssertEqual(withOthers.map(\.id), [extra.id, last.id, strict.id])
        XCTAssertFalse(withOthers.contains { $0.id == "one-person" || $0.id == "archive" || $0.id == "trash" })
    }

    func testMissingIdentityMetadataReportsCompatibilityInsteadOfShowingAWrongGroup() async throws {
        let a = UUID().uuidString, b = UUID().uuidString
        let search = GroupSearchRepository(api: makeStubAPIClient(), recordsVisibility: false)
        search.pages = [1: page([asset("unknown", people: nil)])]

        for includesOthers in [false, true] {
            do {
                _ = try await PeopleGroupRepository(repository: search).assets(personIDs: [a, b], includingOtherPeople: includesOthers)
                XCTFail("Missing identity metadata cannot establish group membership")
            } catch let error as APIError {
                XCTAssertEqual(error.errorDescription, String(localized: "The server did not provide people information for group photos."))
            }
        }
    }

    func testHiddenRequiredIdentityIsNotAdmittedEvenWithOtherPeopleEnabled() throws {
        let dto = AssetResponseDTO(id: UUID().uuidString, type: "IMAGE", originalFileName: "synthetic.png",
            fileCreatedAt: .distantPast, isFavorite: false, isArchived: false, isTrashed: false,
            duration: nil, thumbhash: nil, localDateTime: .distantPast, exifInfo: nil,
            people: [person("a"), person("b", hidden: true)])
        XCTAssertFalse(try PeopleGroupMembership.includes(dto, people: ["a", "b"], includingOtherPeople: true))
    }

    func testMissingMembersNeverRequestTheWholeLibrary() async throws {
        let search = GroupSearchRepository(api: makeStubAPIClient(), recordsVisibility: false)
        let repository = PeopleGroupRepository(repository: search)

        let empty = try await repository.assets(personIDs: [], includingOtherPeople: true)
        let missing = try await repository.assets(personIDs: ["", ""], includingOtherPeople: false)

        XCTAssertTrue(empty.isEmpty)
        XCTAssertTrue(missing.isEmpty)
        XCTAssertTrue(search.requests.isEmpty)
    }

    func testGroupCollapsedByAnIdentityMergeCanQueryItsCanonicalPerson() async throws {
        let personID = UUID().uuidString
        let only = asset("solo", people: [personID])
        let search = GroupSearchRepository(api: makeStubAPIClient(), recordsVisibility: false)
        search.pages = [1: page([only, asset("with-others", people: [personID, UUID().uuidString])])]

        let loaded = try await PeopleGroupRepository(repository: search)
            .assets(personIDs: [personID], includingOtherPeople: false)

        XCTAssertEqual(loaded.map(\.id), [only.id])
        XCTAssertEqual(search.requests.first?.personIds, [personID])
    }

    func testAccountChangeRejectsHeldGroupResults() async throws {
        let held = GroupQueryGate()
        let search = GroupSearchRepository(api: makeStubAPIClient(), recordsVisibility: false)
        search.gate = held
        let repository = PeopleGroupRepository(repository: search)
        let task = Task { try await repository.assets(personIDs: ["a", "b"], includingOtherPeople: false) }
        let empty = page([])
        addTeardownBlock { await held.finish(empty); _ = try? await task.value }
        await fulfillment(of: [held.started], timeout: 2)
        LocalSnapshot.clearAll()
        held.finish(page([asset("late", people: ["a", "b"])]))

        do {
            _ = try await task.value
            XCTFail("The previous account's group result must be discarded")
        } catch is CancellationError {} catch { XCTFail("Unexpected error: \(error)") }
    }

    func testCorrectingEitherPersonRejectsHeldGroupMembershipWithoutAnAccountChange() async throws {
        let people = [UUID().uuidString, UUID().uuidString]
        for changedPerson in people {
            let held = GroupQueryGate()
            let search = GroupSearchRepository(api: makeStubAPIClient(), recordsVisibility: false)
            search.gate = held
            let repository = PeopleGroupRepository(repository: search)
            let generation = LocalSnapshot.generation
            let task = Task { try await repository.assets(personIDs: people, includingOtherPeople: false) }
            let empty = page([])
            addTeardownBlock { await held.finish(empty); _ = try? await task.value }
            await fulfillment(of: [held.started], timeout: 2)

            LocalSnapshot.remove(LocalSnapshot.Key.person(changedPerson))
            held.finish(page([asset("stale-membership", people: people)]))

            do {
                _ = try await task.value
                XCTFail("A confirmed face reassignment must invalidate old group membership")
            } catch is CancellationError {} catch { XCTFail("Unexpected error: \(error)") }
            XCTAssertEqual(LocalSnapshot.generation, generation,
                "This regression must exercise person invalidation independently of account isolation")
        }
    }

    private func page(_ assets: [AssetResponseDTO], next: String? = nil) -> SearchResponseDTO {
        SearchResponseDTO(assets: .init(items: assets, total: assets.count, nextPage: next))
    }

    private func asset(_ id: String, people: [String]?, offset: Double = 0,
                       visibility: String = "timeline", trashed: Bool = false) -> AssetResponseDTO {
        let date = Date(timeIntervalSince1970: 1_793_188_800 + offset)
        return AssetResponseDTO(id: id, type: "IMAGE", originalFileName: "synthetic.png", fileCreatedAt: date,
            isFavorite: false, isArchived: visibility == "archive", isTrashed: trashed,
            duration: nil, thumbhash: nil, localDateTime: date, exifInfo: nil, people: people?.map { person($0) },
            visibility: visibility)
    }

    private func person(_ id: String, hidden: Bool = false) -> PersonDTO {
        PersonDTO(id: id, name: id, birthDate: nil, thumbnailPath: nil, isHidden: hidden)
    }
}

private final class GroupSearchRepository: SearchRepository {
    var pages: [Int: SearchResponseDTO] = [:]
    var requests: [SearchRequestDTO] = []
    var gate: GroupQueryGate?

    override func metadataPage(_ request: SearchRequestDTO) async throws -> SearchResponseDTO {
        requests.append(request)
        if let gate { return await gate.value() }
        return pages[request.page ?? 1] ?? SearchResponseDTO(assets: .init(items: [], total: 0, nextPage: nil))
    }
}

@MainActor
private final class GroupQueryGate {
    let started = XCTestExpectation(description: "A group metadata response is held")
    private var continuation: CheckedContinuation<SearchResponseDTO, Never>?
    func value() async -> SearchResponseDTO {
        await withCheckedContinuation { continuation = $0; started.fulfill() }
    }
    func finish(_ response: SearchResponseDTO) { continuation?.resume(returning: response); continuation = nil }
}
