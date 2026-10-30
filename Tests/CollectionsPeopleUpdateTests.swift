import XCTest
@testable import ImmichApp

@MainActor
final class CollectionsPeopleUpdateTests: XCTestCase {
    private var previousPeople: [PersonDTO]?

    override func setUp() {
        previousPeople = LocalSnapshot.load([PersonDTO].self, for: LocalSnapshot.Key.libraryPeople)
        MockURLProtocol.reset()
    }

    override func tearDown() {
        if let previousPeople { LocalSnapshot.save(previousPeople, for: LocalSnapshot.Key.libraryPeople) }
        else { LocalSnapshot.remove(LocalSnapshot.Key.libraryPeople) }
        MockURLProtocol.reset()
    }

    func testPreviewKeepsAcceptedFavoritesWhenAnOlderEditorRenamesThePerson() {
        let model = makeModel()
        var person = person("person", name: "Original")
        person.isFavorite = true
        model.people = [person]
        var editor = person
        editor.name = "Updated"
        editor.isFavorite = false

        model.applyPersonUpdate(PersonUpdate(person: editor, fields: [.name]))

        XCTAssertEqual(model.people.first?.name, "Updated")
        XCTAssertEqual(model.people.first?.isFavorite, true)
        let saved = LocalSnapshot.load([PersonDTO].self, for: LocalSnapshot.Key.libraryPeople)
        XCTAssertEqual(saved?.first?.name, "Updated")
        XCTAssertEqual(saved?.first?.isFavorite, true)
        editor.isHidden = true
        model.applyPersonUpdate(PersonUpdate(person: editor, fields: [.hidden]))
        XCTAssertTrue(model.people.isEmpty)
    }

    func testAnOlderPreviewResponseCannotRestoreAcceptedMergeSourcesOrUndoNewMetadata() async {
        let repository = PreviewPeopleRepository(api: makeStubAPIClient())
        let gate = PreviewPeopleGate()
        repository.gate = gate
        let model = makeModel(repository)
        let original = [person("target", name: "Original"), person("merged"), person("failed")]
        LocalSnapshot.save(original, for: LocalSnapshot.Key.libraryPeople)
        let load = Task { await model.load() }
        addTeardownBlock { await gate.finish(original); await load.value }
        await fulfillment(of: [gate.started], timeout: 2)
        var updated = original[0]
        updated.name = "Current name"
        model.applyPersonUpdate(PersonUpdate(person: updated, fields: [.name]))
        model.applyPeopleMerge(["merged"])

        gate.finish(original)
        await load.value

        XCTAssertEqual(model.people.map(\.id), ["target", "failed"])
        XCTAssertEqual(model.people.first?.name, "Current name")
        let saved = LocalSnapshot.load([PersonDTO].self, for: LocalSnapshot.Key.libraryPeople)
        XCTAssertEqual(saved?.map(\.id), ["target", "failed"])
        XCTAssertEqual(saved?.first?.name, "Current name")

        var oldEditor = original[1]
        oldEditor.name = "Late accepted rename"
        oldEditor.updatedAt = Date()
        for field in [PersonUpdate.Field.name, .thumbnail] {
            model.applyPersonUpdate(PersonUpdate(person: oldEditor, fields: [field]))
            XCTAssertEqual(model.people.map(\.id), ["target", "failed"])
            XCTAssertEqual(LocalSnapshot.load([PersonDTO].self, for: LocalSnapshot.Key.libraryPeople)?.map(\.id),
                ["target", "failed"], "A late source callback cannot resurrect the merged preview")
        }
        var retainedEditor = original[2]
        retainedEditor.name = "Still editable"
        model.applyPersonUpdate(PersonUpdate(person: retainedEditor, fields: [.name]))
        XCTAssertEqual(model.people.last?.name, "Still editable")
        XCTAssertEqual(LocalSnapshot.load([PersonDTO].self, for: LocalSnapshot.Key.libraryPeople)?.last?.name,
            "Still editable", "Only accepted merge source IDs are retired")
    }

    private func makeModel(_ repository: PeopleRepository? = nil) -> LibraryViewModel {
        let api = makeStubAPIClient()
        return LibraryViewModel(memoriesRepo: MemoriesRepository(api: api), albumRepo: AlbumRepository(api: api),
            peopleRepo: repository ?? PeopleRepository(api: api), searchRepo: SearchRepository(api: api),
            assetRepo: AssetDetailRepository(api: api))
    }

    private func person(_ id: String, name: String = "Name") -> PersonDTO {
        PersonDTO(id: id, name: name, birthDate: nil, thumbnailPath: nil, isHidden: false, isFavorite: false)
    }
}

@MainActor
private final class PreviewPeopleRepository: PeopleRepository {
    var gate: PreviewPeopleGate?
    override func all(size: Int? = nil) async throws -> [PersonDTO] { await gate?.value() ?? [] }
}

@MainActor
private final class PreviewPeopleGate {
    let started = XCTestExpectation(description: "The older Collections preview is held")
    private var continuation: CheckedContinuation<[PersonDTO], Never>?
    func value() async -> [PersonDTO] {
        await withCheckedContinuation { continuation = $0; started.fulfill() }
    }
    func finish(_ people: [PersonDTO]) { continuation?.resume(returning: people); continuation = nil }
}
