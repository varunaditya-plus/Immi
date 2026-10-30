import SwiftUI
import UIKit
import Vision
import XCTest
@testable import ImmichApp

@MainActor
final class PeopleDirectoryPresentationTests: SimulatorHostedTestCase {
    private var previousPeople: [PersonDTO]?
    private var previousDiscovery: [PersonDTO]?

    override func setUp() {
        previousPeople = LocalSnapshot.load([PersonDTO].self, for: LocalSnapshot.Key.peopleList)
        previousDiscovery = LocalSnapshot.load([PersonDTO].self, for: "people.hidden")
    }

    override func tearDown() async throws {
        try await super.tearDown()
        if let previousPeople { LocalSnapshot.save(previousPeople, for: LocalSnapshot.Key.peopleList) }
        else { LocalSnapshot.remove(LocalSnapshot.Key.peopleList) }
        if let previousDiscovery { LocalSnapshot.save(previousDiscovery, for: "people.hidden") }
        else { LocalSnapshot.remove("people.hidden") }
    }



    func testActualNameEditorSavesOnlyTheSubmittedNameAndPreservesANewerFavorite() async throws {
        let original = person("Original Name")
        let repository = DirectoryPresentationRepository(people: [original])
        let model = PeopleListViewModel(repo: repository)
        await model.loadPeople()
        let editor = PersonDetailState(person: original)
        await model.setFavorite(original.id, to: true)
        var updates: [PersonUpdate] = []
        let window = try await host(IdentityEditorPresenter(editor: PersonIdentityEditor(
            person: original, repository: repository, detailState: editor, onUpdated: { update in
                updates.append(update)
                model.applyPersonUpdate(update)
            })))
        try await waitForEditor(in: window)
        let field = try XCTUnwrap(nameField(in: window))
        field.text = "Submitted Name"
        field.sendActions(for: .editingChanged)
        let form = try XCTUnwrap(presentedController(from: window.rootViewController))
        try await activateAccessibilityButton(named: "Done", in: window, within: form.view)
        try await waitUntil("The real form saves the name and dismisses") {
            model.people.first?.name == "Submitted Name" && self.nameField(in: window) == nil
        }
        XCTAssertEqual(repository.renames.map(\.name), ["Submitted Name"])
        XCTAssertEqual(model.people.first?.isFavorite, true, "The editor opened before Favorite completed")
        XCTAssertEqual(updates.first?.fields, [.name])
        let saved = LocalSnapshot.load([PersonDTO].self, for: LocalSnapshot.Key.peopleList)
        XCTAssertEqual(saved?.first?.name, "Submitted Name")
        XCTAssertEqual(saved?.first?.isFavorite, true)
    }

    func testRejectedNameEditKeepsTheFormAndConfirmedMetadata() async throws {
        let original = person("Confirmed Name", favorite: true)
        let repository = DirectoryPresentationRepository(people: [original])
        repository.rejectRename = true
        let detail = PersonDetailState(person: original)
        var callbacks: [PersonUpdate] = []
        let window = try await host(IdentityEditorPresenter(editor: PersonIdentityEditor(
            person: original, repository: repository, detailState: detail, onUpdated: { callbacks.append($0) })))
        try await waitForEditor(in: window)
        let field = try XCTUnwrap(nameField(in: window))
        field.text = "Rejected Name"
        field.sendActions(for: .editingChanged)
        let form = try XCTUnwrap(presentedController(from: window.rootViewController))
        try await activateAccessibilityButton(named: "Done", in: window, within: form.view)
        try await waitUntil("The repository saw the submitted name") { repository.renames.count == 1 }
        try await assertReadOnlyAlert(in: window)
        let text = try await renderedText(in: window)
        XCTAssertTrue(text.contains("Action Failed"), text)
        XCTAssertNotNil(nameField(in: window), "Failure must keep the editable name available for a retry")
        XCTAssertTrue(callbacks.isEmpty)
        XCTAssertEqual(repository.people.first?.name, original.name)
        XCTAssertEqual(repository.people.first?.isFavorite, true)
        XCTAssertNil(detail.actionError, "Rename errors belong to the editor rather than its parent")
    }

    func testAcceptedEditorRenameStillPublishesAndDismissesAfterAConcurrentFavoriteFailure() async throws {
        let original = person("Original Name")
        let repository = DirectoryPresentationRepository(people: [original])
        let favoriteGate = PeopleStateGate<Void>()
        let renameGate = PeopleStateGate<Void>()
        repository.favoriteOperation = { _, _ in try await favoriteGate.value() }
        repository.renameOperation = { _, _ in try await renameGate.value() }
        let detail = PersonDetailState(person: original)
        let favorite = Task { await detail.setFavorite(true, using: repository) }
        addTeardownBlock {
            await favoriteGate.complete(.failure(CancellationError()))
            await renameGate.complete(.failure(CancellationError()))
            await favorite.value
        }
        await fulfillment(of: [favoriteGate.started], timeout: 2)
        var updates: [PersonUpdate] = []
        let window = try await host(IdentityEditorPresenter(editor: PersonIdentityEditor(
            person: original, repository: repository, detailState: detail, onUpdated: { updates.append($0) })))
        try await waitForEditor(in: window)
        let field = try XCTUnwrap(nameField(in: window))
        field.text = "Accepted Name"
        field.sendActions(for: .editingChanged)
        let editor = try XCTUnwrap(presentedController(from: window.rootViewController))
        try await activateAccessibilityButton(named: "Done", in: window, within: editor.view)
        await fulfillment(of: [renameGate.started], timeout: 2)

        favoriteGate.complete(.failure(APIError.server(status: 403, message: "Favorite denied")))
        await favorite.value
        let favoriteError = try XCTUnwrap(detail.actionError)
        XCTAssertTrue(favoriteError.contains("Favorite denied"), favoriteError)
        XCTAssertNotNil(nameField(in: window), "The actual rename is still pending")
        renameGate.complete(.success(()))

        try await waitUntil("An accepted rename publishes its own result and dismisses the actual editor") {
            updates.count == 1 && self.nameField(in: window) == nil
        }
        XCTAssertEqual(updates.first?.fields, [.name])
        XCTAssertEqual(updates.first?.person.name, "Accepted Name")
        XCTAssertEqual(detail.person.name, "Accepted Name")
        XCTAssertEqual(detail.person.isFavorite, false)
        XCTAssertEqual(detail.actionError, favoriteError, "Rename success cannot consume unrelated favorite feedback")
        XCTAssertEqual(repository.renames.map(\.name), ["Accepted Name"])
    }



    func testRejectedHiddenPeopleShowKeepsTheConfirmedDirectoryAndExposesTheError() async throws {
        let shown = person("Visible Test"), hidden = person("Hidden Test", hidden: true)
        let repository = DirectoryPresentationRepository(people: [shown, hidden])
        let directory = PeopleListViewModel(repo: repository)
        await directory.loadPeople()
        repository.rejectHidden = true
        var callbacks: [PersonUpdate] = []
        let window = try await host(PeopleDiscoveryView(repository: repository, mode: .hidden) { update in
            callbacks.append(update)
            directory.applyPersonUpdate(update)
        })
        try await activateAccessibilityButton(named: "Show", in: window)
        try await waitUntil("The first actual Show action was rejected") { repository.hiddenChanges.count == 1 }
        try await assertReadOnlyAlert(in: window)
        let text = try await renderedText(in: window)
        XCTAssertTrue(text.contains("Action Failed"), text)
        XCTAssertEqual(directory.people.map(\.id), [shown.id])
        XCTAssertTrue(callbacks.isEmpty)
        XCTAssertEqual(repository.hiddenChanges.map(\.value), [false])
        XCTAssertEqual(repository.people.first(where: { $0.id == hidden.id })?.isHidden, true)
    }

    func testAcceptedHiddenPeopleShowRestoresTheDirectoryAndRemovesTheActualHiddenRow() async throws {
        let shown = person("Visible Test"), hidden = person("Hidden Test", hidden: true)
        let repository = DirectoryPresentationRepository(people: [shown, hidden])
        let directory = PeopleListViewModel(repo: repository)
        await directory.loadPeople()
        var callbacks: [PersonUpdate] = []
        let window = try await host(PeopleDiscoveryView(repository: repository, mode: .hidden) { update in
            callbacks.append(update)
            directory.applyPersonUpdate(update)
        })
        try await activateAccessibilityButton(named: "Show", in: window)
        try await waitUntil("Accepted Show brings the hidden person back to the ordinary directory") {
            directory.people.contains { $0.id == hidden.id && !$0.isHidden }
        }
        let text = try await renderedText(in: window)
        XCTAssertTrue(text.contains("No Hidden People"), text)
        XCTAssertFalse(text.contains(hidden.name), text)
        XCTAssertEqual(repository.hiddenChanges.map(\.value), [false])
        XCTAssertEqual(callbacks.count, 1)
        XCTAssertEqual(callbacks.first?.fields, [.hidden])
    }

    func testMountedCustomReorderUsesLivePeopleAndCannotSaveANewlyHiddenPerson() async throws {
        let maya = person("Maya Test"), leo = person("Leo Test")
        let repository = DirectoryPresentationRepository(people: [maya, leo])
        let model = PeopleListViewModel(repo: repository)
        await model.loadPeople()
        var saved: [String]?
        let window = try await host(PeopleReorderSheet(people: { model.people }) { saved = $0 })
        var text = try await renderedText(in: window)
        XCTAssertTrue(text.contains(maya.name) && text.contains(leo.name), text)

        model.applyHidden(leo.id, to: true)

        text = try await renderedText(in: window)
        XCTAssertTrue(text.contains(maya.name), text)
        XCTAssertFalse(text.contains(leo.name), "Hidden identities must disappear from the mounted reorder sheet: \(text)")
        try await activateAccessibilityButton(named: "Done", in: window)
        XCTAssertEqual(saved, [maya.id])
    }

    private func person(_ name: String, favorite: Bool = false, hidden: Bool = false) -> PersonDTO {
        PersonDTO(id: UUID().uuidString, name: name, birthDate: nil, thumbnailPath: nil,
            isHidden: hidden, isFavorite: favorite)
    }

    private func nameField(in view: UIView) -> UITextField? {
        if let field = view as? UITextField, field.placeholder == "Name This Person" { return field }
        return view.subviews.lazy.compactMap { self.nameField(in: $0) }.first
    }

    private func waitForEditor(in window: UIWindow) async throws {
        try await waitUntil("The actual name editor finishes presenting") {
            guard let form = self.presentedController(from: window.rootViewController) else { return false }
            return form.transitionCoordinator == nil && self.nameField(in: form.view) != nil
        }
    }

    private func assertReadOnlyAlert(in window: UIWindow) async throws {
        try await waitUntil("The actual failure alert finishes presenting") {
            guard let alert = self.presentedController(from: window.rootViewController) as? UIAlertController else { return false }
            return alert.transitionCoordinator == nil
        }
        let alert = try XCTUnwrap(presentedController(from: window.rootViewController) as? UIAlertController)
        XCTAssertEqual(alert.title, "Action Failed")
        XCTAssertTrue(alert.message?.contains("Read only") == true, alert.message ?? "Missing error message")
        XCTAssertEqual(alert.actions.map(\.title), ["OK"])
        XCTAssertTrue(try XCTUnwrap(alert.actions.first).isEnabled)
    }

    private func presentedController(from controller: UIViewController?) -> UIViewController? {
        guard let presented = controller?.presentedViewController else { return nil }
        return presentedController(from: presented) ?? presented
    }

    private func renderedText(in window: UIWindow) async throws -> String {
        let image = try await screenshot(window)
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["en-US"]
        try VNImageRequestHandler(cgImage: try XCTUnwrap(image.cgImage)).perform([request])
        return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: " ")
    }
}

private struct IdentityEditorPresenter: View {
    let editor: PersonIdentityEditor
    @State private var isPresented = true
    var body: some View { Color.clear.sheet(isPresented: $isPresented) { editor } }
}

private final class DirectoryPresentationRepository: PeopleRepository {
    var people: [PersonDTO]
    var rejectFavorite = false
    var rejectRename = false
    var rejectHidden = false
    var favoriteOperation: ((String, Bool) async throws -> Void)?
    var renameOperation: ((String, String) async throws -> Void)?
    var favoriteChanges: [(id: String, value: Bool)] = []
    var hiddenChanges: [(id: String, value: Bool)] = []
    var renames: [(id: String, name: String)] = []

    @MainActor
    init(people: [PersonDTO]) {
        self.people = people
        super.init(api: makeStubAPIClient())
    }

    override func all(size: Int? = nil) async throws -> [PersonDTO] { people.filter { !$0.isHidden } }
    override func allIncludingHidden() async throws -> [PersonDTO] { people }
    override func setFavorite(_ id: String, to value: Bool) async throws {
        favoriteChanges.append((id, value))
        try await favoriteOperation?(id, value)
        if rejectFavorite { throw APIError.server(status: 403, message: "Read only") }
        if let index = people.firstIndex(where: { $0.id == id }) { people[index].isFavorite = value }
    }
    override func rename(_ id: String, to name: String) async throws {
        renames.append((id, name))
        try await renameOperation?(id, name)
        if rejectRename { throw APIError.server(status: 403, message: "Read only") }
        if let index = people.firstIndex(where: { $0.id == id }) { people[index].name = name }
    }
    override func setHidden(_ id: String, to value: Bool) async throws {
        hiddenChanges.append((id, value))
        if rejectHidden { throw APIError.server(status: 403, message: "Read only") }
        if let index = people.firstIndex(where: { $0.id == id }) { people[index].isHidden = value }
    }
}
