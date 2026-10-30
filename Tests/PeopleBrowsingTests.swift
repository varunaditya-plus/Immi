import Foundation
import XCTest
@testable import ImmichApp

@MainActor
final class PeopleBrowsingTests: XCTestCase {
    private var suites: [String] = []

    override func setUp() { LocalSnapshot.clearAll(); MockURLProtocol.reset() }
    override func tearDown() {
        LocalSnapshot.clearAll()
        MockURLProtocol.reset()
        suites.forEach { UserDefaults.standard.removePersistentDomain(forName: $0) }
    }

    func testLegacyPersonSnapshotsStillDecodeWithoutFavoriteOrVersionFields() throws {
        let data = Data(#"{"id":"person","name":"Maya","birthDate":null,"thumbnailPath":"face.jpg","isHidden":false}"#.utf8)
        let person = try JSONDecoder.immich.decode(PersonDTO.self, from: data)
        XCTAssertNil(person.isFavorite)
        XCTAssertNil(person.updatedAt)
        XCTAssertEqual(person.name, "Maya")
    }

    func testFavoriteIsPersistedOnlyAfterAcceptanceAndCannotBeUndoneByAnOlderDirectory() async throws {
        let repository = PeopleBrowsingRepository(api: makeStubAPIClient())
        let original = person("original")
        repository.directory = [original]
        let model = PeopleListViewModel(repo: repository)
        await model.loadPeople()
        let gate = PeopleStateGate<[PersonDTO]>()
        repository.read = { try await gate.value() }
        let loading = Task { await model.loadPeople() }
        addTeardownBlock { await gate.complete(.failure(CancellationError())); await loading.value }
        await fulfillment(of: [gate.started], timeout: 2)

        await model.setFavorite(original.id, to: true)
        gate.complete(.success([original]))
        await loading.value

        XCTAssertEqual(repository.favorites.map(\.id), [original.id])
        XCTAssertEqual(repository.favorites.map(\.value), [true])
        XCTAssertEqual(model.people.first?.isFavorite, true)
        XCTAssertEqual(LocalSnapshot.load([PersonDTO].self, for: LocalSnapshot.Key.peopleList)?.first?.isFavorite, true)
        repository.favorite = { _, _ in throw APIError.server(status: 403, message: "Read only") }
        await model.setFavorite(original.id, to: false)
        XCTAssertEqual(model.people.first?.isFavorite, true)
        XCTAssertNotNil(model.actionError)
    }

    func testHiddenDiscoveryDoesNotReplaceTheOrdinaryPeopleSnapshot() async throws {
        let repository = PeopleBrowsingRepository(api: makeStubAPIClient())
        let shown = person("shown"), hidden = person("hidden", hidden: true)
        repository.directory = [shown]
        repository.withHidden = [shown, hidden]
        let ordinary = PeopleListViewModel(repo: repository)
        let discovery = PeopleListViewModel(repo: repository, includesHidden: true)
        await ordinary.loadPeople()
        await discovery.loadPeople()

        XCTAssertEqual(discovery.people.map(\.id), [shown.id, hidden.id])
        XCTAssertEqual(LocalSnapshot.load([PersonDTO].self, for: LocalSnapshot.Key.peopleList)?.map(\.id), [shown.id])
        await discovery.setHidden(hidden.id, to: false)
        let revealed = try XCTUnwrap(discovery.people.first { $0.id == hidden.id })
        ordinary.applyPersonUpdate(PersonUpdate(person: revealed, fields: [.hidden]))
        XCTAssertEqual(ordinary.people.map(\.id), [shown.id, hidden.id])
        XCTAssertEqual(ordinary.people.last?.isHidden, false)
    }

    func testMergeKeepsRejectedPeopleAndInvalidatesOnlyConfirmedMembershipSnapshots() async {
        let repository = PeopleBrowsingRepository(api: makeStubAPIClient())
        let target = person("target"), accepted = person("accepted"), rejected = person("rejected")
        repository.directory = [target, accepted, rejected]
        repository.mergeResults = [result(accepted.id, true), result(rejected.id, false)]
        repository.canonical = target
        let model = PeopleListViewModel(repo: repository)
        await model.loadPeople()
        let photo = AssetLite(id: "photo", isVideo: false, ratio: 1, thumbhash: nil, createdAt: .distantPast)
        for id in [target.id, accepted.id, rejected.id] {
            LocalSnapshot.save([photo], for: LocalSnapshot.Key.person(id))
        }

        let complete = await model.merge([accepted.id, rejected.id], into: target.id)

        XCTAssertEqual(complete?.acceptedIDs, [accepted.id])
        XCTAssertEqual(complete?.failedIDs, [rejected.id])
        XCTAssertEqual(Set(model.people.map(\.id)), [target.id, rejected.id])
        XCTAssertNotNil(model.actionError)
        XCTAssertNil(LocalSnapshot.load([AssetLite].self, for: LocalSnapshot.Key.person(accepted.id)))
        XCTAssertNil(LocalSnapshot.load([AssetLite].self, for: LocalSnapshot.Key.person(target.id)))
        XCTAssertNotNil(LocalSnapshot.load([AssetLite].self, for: LocalSnapshot.Key.person(rejected.id)))
        XCTAssertEqual(repository.merges.first?.target, target.id)
        XCTAssertEqual(Set(repository.merges.first?.sources ?? []), [accepted.id, rejected.id])
    }

    func testAccountChangeRejectsLateFavoriteAndMergeResults() async {
        for merging in [false, true] {
            let repository = PeopleBrowsingRepository(api: makeStubAPIClient())
            let a = person("a"), b = person("b")
            repository.directory = [a, b]
            let favoriteGate = PeopleStateGate<Void>()
            let mergeGate = PeopleStateGate<[BulkIDResponseDTO]>()
            repository.favorite = { _, _ in try await favoriteGate.value() }
            repository.mergeOperation = { _, _ in try await mergeGate.value() }
            let model = PeopleListViewModel(repo: repository)
            await model.loadPeople()
            let task = Task {
                if merging { _ = await model.merge([b.id], into: a.id) }
                else { await model.setFavorite(a.id, to: true) }
            }
            addTeardownBlock {
                await favoriteGate.complete(.failure(CancellationError()))
                await mergeGate.complete(.failure(CancellationError()))
                await task.value
            }
            await fulfillment(of: [merging ? mergeGate.started : favoriteGate.started], timeout: 2)
            LocalSnapshot.clearAll()
            let next = person("next")
            LocalSnapshot.save([next], for: LocalSnapshot.Key.peopleList)
            if merging { mergeGate.complete(.success([result(b.id, true)])) }
            else { favoriteGate.complete(.success(())) }
            await task.value
            XCTAssertEqual(model.people.map(\.id), [a.id, b.id])
            XCTAssertEqual(model.people.first?.isFavorite, false)
            XCTAssertEqual(LocalSnapshot.load([PersonDTO].self, for: LocalSnapshot.Key.peopleList)?.map(\.id), [next.id])
        }
    }

    func testAcceptedMergeSourcesCannotBeRestoredByLateEditorCallbacks() async throws {
        let repository = PeopleBrowsingRepository(api: makeStubAPIClient())
        let target = person("target"), source = person("source"), rejected = person("rejected")
        repository.directory = [target, source, rejected]
        repository.canonical = target
        repository.mergeResults = [result(source.id, true), result(rejected.id, false)]
        let model = PeopleListViewModel(repo: repository)
        await model.loadPeople()

        let mergeResult = await model.merge([source.id, rejected.id], into: target.id)
        XCTAssertEqual(mergeResult?.acceptedIDs, [source.id])
        XCTAssertEqual(mergeResult?.failedIDs, [rejected.id])
        var lateEditor = source
        lateEditor.name = "Late accepted rename"
        lateEditor.updatedAt = Date()
        for field in [PersonUpdate.Field.name, .thumbnail] {
            model.applyPersonUpdate(PersonUpdate(person: lateEditor, fields: [field]))
            XCTAssertEqual(model.people.map(\.id), [target.id, rejected.id])
            XCTAssertEqual(LocalSnapshot.load([PersonDTO].self, for: LocalSnapshot.Key.peopleList)?.map(\.id),
                [target.id, rejected.id], "An accepted merge source must stay absent after a late editor callback")
        }
        var retainedEditor = rejected
        retainedEditor.name = "Still editable"
        model.applyPersonUpdate(PersonUpdate(person: retainedEditor, fields: [.name]))
        XCTAssertEqual(model.people.last?.name, "Still editable", "Rejected sources remain real editable people")
        let saved = try XCTUnwrap(LocalSnapshot.load([PersonDTO].self, for: LocalSnapshot.Key.peopleList))
        XCTAssertEqual(saved.map(\.id), [target.id, rejected.id])
        XCTAssertEqual(saved.last?.name, "Still editable")
    }

    func testPickerOwnedMergeFailuresPreserveAnUnrelatedFavoriteError() async throws {
        for throwsFailure in [false, true] {
            let repository = PeopleBrowsingRepository(api: makeStubAPIClient())
            let target = person("target"), source = person("source")
            repository.directory = [target, source]
            repository.canonical = target
            repository.favorite = { _, _ in throw APIError.server(status: 403, message: "Favorite denied") }
            let gate = PeopleStateGate<[BulkIDResponseDTO]>()
            repository.mergeOperation = { _, _ in try await gate.value() }
            let model = PeopleListViewModel(repo: repository)
            await model.loadPeople()
            model.actionError = "An earlier directory error"
            let merging = Task { await model.merge([source.id], into: target.id, reportsFailure: false) }
            addTeardownBlock { await gate.complete(.failure(CancellationError())); _ = await merging.value }
            await fulfillment(of: [gate.started], timeout: 2)
            XCTAssertEqual(model.actionError, "An earlier directory error", "A sheet-owned operation cannot clear unrelated feedback")

            let favorited = await model.setFavorite(target.id, to: true)
            XCTAssertFalse(favorited)
            let favoriteError = try XCTUnwrap(model.actionError)
            XCTAssertTrue(favoriteError.contains("Favorite denied"), favoriteError)
            if throwsFailure { gate.complete(.failure(APIError.server(status: 500, message: "Merge denied"))) }
            else { gate.complete(.success([result(source.id, false)])) }
            let mergeResult = await merging.value

            if throwsFailure { XCTAssertNil(mergeResult) }
            else { XCTAssertEqual(mergeResult?.failedIDs, [source.id]) }
            XCTAssertEqual(model.actionError, favoriteError, "The merge picker owns its failure alert")
            XCTAssertEqual(model.people.map(\.id), [target.id, source.id])
            XCTAssertEqual(model.people.first?.isFavorite, false)
        }
    }

    func testCustomOrderingIsAccountScopedAndDoesNotLoseAConcurrentSortChange() throws {
        let suite = "people-order-\(UUID())"
        suites.append(suite)
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let owner = BackupQueueOwner(server: "https://synthetic.example", userID: "first")
        let first = PeopleOrganizationStore(owner: owner, defaults: defaults)
        let other = PeopleOrganizationStore(owner: owner, defaults: defaults)
        first.setOrder(["c", "a", "c"])
        other.setSort(.name)
        let restored = PeopleOrganizationStore(owner: owner, defaults: defaults)
        XCTAssertEqual(restored.value.order, ["c", "a"])
        XCTAssertEqual(restored.value.sort, .name)
        let c = person("c", name: "Zoe"), a = person("a", name: "Ada"), b = person("b", name: "Ben")
        XCTAssertEqual(restored.value.ordered([c, b, a]).map(\.id), [a.id, b.id, c.id])
        restored.setSort(.custom)
        XCTAssertEqual(restored.value.ordered([b, a, c]).map(\.id), [c.id, a.id, b.id])
        XCTAssertTrue(restored.move(b.id, before: c.id, people: [a, b, c]))
        XCTAssertEqual(restored.value.order, [b.id, c.id, a.id])
        XCTAssertFalse(restored.move("unknown", before: a.id, people: [a, b, c]))
        var favorite = a
        favorite.isFavorite = true
        XCTAssertFalse(restored.move(b.id, before: a.id, people: [favorite, b, c]), "Dragging cannot change favorite membership")
        restored.setOrder(["c", "a"])
        let stranger = PeopleOrganizationStore(owner: .init(server: owner.server, userID: "second"), defaults: defaults)
        XCTAssertTrue(stranger.value.order.isEmpty)
        LocalSnapshot.clearAll()
        first.setOrder(["rejected"])
        XCTAssertEqual(PeopleOrganizationStore(owner: owner, defaults: defaults).value.order, ["c", "a"])
    }

    func testKeyPhotoRequiresAnAdmittedServerMemberAndRejectsLateAccountResults() async throws {
        let repository = PeopleBrowsingRepository(api: makeStubAPIClient())
        let state = PersonDetailState(person: person("person"))
        let member = AssetLite(id: UUID().uuidString, isVideo: false, ratio: 1, thumbhash: nil, createdAt: .distantPast)
        let invalid = await state.chooseKeyPhoto("not-a-member", from: [member], using: repository)
        XCTAssertNotNil(invalid)
        XCTAssertTrue(repository.keyPhotos.isEmpty)
        let accepted = await state.chooseKeyPhoto(member.id, from: [member], using: repository)
        XCTAssertNil(accepted)
        XCTAssertEqual(repository.keyPhotos.map(\.asset), [member.id])
        let version = try XCTUnwrap(state.person.updatedAt)
        let gate = PeopleStateGate<Void>()
        repository.keyPhoto = { _, _ in try await gate.value() }
        let changing = Task { await state.chooseKeyPhoto(member.id, from: [member], using: repository) }
        addTeardownBlock { await gate.complete(.failure(CancellationError())); _ = await changing.value }
        await fulfillment(of: [gate.started], timeout: 2)
        LocalSnapshot.clearAll()
        gate.complete(.success(()))
        _ = await changing.value
        XCTAssertEqual(state.person.updatedAt, version)
    }

    func testOldEditorRenameAndKeyPhotoCallbacksCannotUndoAnAcceptedFavoriteOrName() async throws {
        let repository = PeopleBrowsingRepository(api: makeStubAPIClient())
        let original = person("person")
        repository.directory = [original]
        let model = PeopleListViewModel(repo: repository)
        await model.loadPeople()
        let editor = PersonDetailState(person: original)
        await model.setFavorite(original.id, to: true)
        editor.renameDraft = "Accepted editor name"
        let rename = try XCTUnwrap(editor.prepareRename())
        let renamed = await editor.saveRename(rename, using: repository)
        XCTAssertEqual(renamed, .saved)
        guard renamed == .saved else { return }
        model.applyPersonUpdate(PersonUpdate(person: editor.person, fields: [.name]))
        XCTAssertEqual(model.people.first?.name, "Accepted editor name")
        XCTAssertEqual(model.people.first?.isFavorite, true)

        var newer = original
        newer.name = "Newer name elsewhere"
        model.applyPersonUpdate(PersonUpdate(person: newer, fields: [.name]))
        let member = AssetLite(id: UUID().uuidString, isVideo: false, ratio: 1, thumbhash: nil, createdAt: .distantPast)
        let error = await editor.chooseKeyPhoto(member.id, from: [member], using: repository) { update in
            XCTAssertEqual(update.fields, [.thumbnail])
            model.applyPersonUpdate(update)
        }
        XCTAssertNil(error)
        XCTAssertEqual(model.people.first?.name, "Newer name elsewhere")
        XCTAssertEqual(model.people.first?.isFavorite, true)
        XCTAssertNotNil(model.people.first?.updatedAt)
    }

    private func person(_ id: String, name: String = "Maya", hidden: Bool = false) -> PersonDTO {
        PersonDTO(id: id, name: name, birthDate: nil, thumbnailPath: "face", isHidden: hidden, isFavorite: false)
    }
    private func result(_ id: String, _ success: Bool) -> BulkIDResponseDTO {
        BulkIDResponseDTO(id: id, success: success, error: success ? nil : "forbidden", errorMessage: nil)
    }
}

private final class PeopleBrowsingRepository: PeopleRepository {
    var directory: [PersonDTO] = []
    var withHidden: [PersonDTO] = []
    var canonical: PersonDTO?
    var read: (() async throws -> [PersonDTO])?
    var favorite: (String, Bool) async throws -> Void = { _, _ in }
    var keyPhoto: (String, String) async throws -> Void = { _, _ in }
    var mergeOperation: (([String], String) async throws -> [BulkIDResponseDTO])?
    var mergeResults: [BulkIDResponseDTO] = []
    var favorites: [(id: String, value: Bool)] = []
    var keyPhotos: [(person: String, asset: String)] = []
    var merges: [(sources: [String], target: String)] = []

    override func all(size: Int? = nil) async throws -> [PersonDTO] { try await read?() ?? directory }
    override func allIncludingHidden() async throws -> [PersonDTO] { withHidden }
    override func setHidden(_ id: String, to value: Bool) async throws {}
    override func rename(_ id: String, to name: String) async throws {}
    override func setFavorite(_ id: String, to value: Bool) async throws {
        favorites.append((id, value)); try await favorite(id, value)
    }
    override func setKeyPhoto(_ id: String, assetID: String) async throws {
        keyPhotos.append((id, assetID)); try await keyPhoto(id, assetID)
    }
    override func merge(_ sourceIDs: [String], into targetID: String) async throws -> [BulkIDResponseDTO] {
        merges.append((sourceIDs, targetID))
        return try await mergeOperation?(sourceIDs, targetID) ?? mergeResults
    }
    override func detail(_ id: String) async throws -> PersonDTO {
        guard let canonical else { throw URLError(.resourceUnavailable) }
        return canonical
    }
}
