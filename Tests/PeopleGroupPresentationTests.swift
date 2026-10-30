import SwiftUI
import UIKit
import Vision
import XCTest
@testable import ImmichApp

@MainActor
final class PeopleGroupPresentationTests: SimulatorHostedTestCase {
    private var suite = ""
    private var defaults: UserDefaults!

    override func setUp() async throws {
        try await super.setUp()
        suite = "people-group-presentation.\(UUID())"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    }

    override func tearDown() async throws {
        try await super.tearDown()
        defaults.removePersistentDomain(forName: suite)
    }

    func testStagedGroupCreationSelectsPeopleThenEditsMembersBeforeSaving() async throws {
        let store = store()
        let people = [person("a", name: "Ada"), person("b", name: "Ben"), person("c", name: "Chris")]
        let window = try await host(GroupEditorTestHost(people: people, store: store))
        try await activateAccessibilityButton(named: "Ada", in: window)
        try await activateAccessibilityButton(named: "Ben", in: window)
        XCTAssertNil(nameField(in: window), "Creation starts by choosing people, before the name form")
        XCTAssertTrue(store.groups.isEmpty, "Selecting people alone must not create a saved group")
        let form = try XCTUnwrap(window.rootViewController?.presentedViewController)
        try await activateAccessibilityButton(named: "Done", in: window, within: form.view)
        try await waitUntil("The selected people advance to the actual name form") { self.nameField(in: window) != nil }
        XCTAssertTrue(store.groups.isEmpty, "Completing the member picker must still wait for Create")
        let field = try XCTUnwrap(nameField(in: window))
        field.text = "Family"
        field.sendActions(for: .editingChanged)
        try await activateAccessibilityButton(named: "Add People", in: window, within: form.view)
        let picker = try await memberPicker(from: form)
        try await activateAccessibilityButton(named: "Chris", in: window, within: picker.view)
        try await activateAccessibilityButton(named: "Done", in: window, within: picker.view)
        try await waitUntil("The confirmed additional member appears as a removable portrait") {
            self.removalButton(named: "Chris", in: window) != nil
        }
        try await removeMember(named: "Ben", in: window)
        try await waitUntil("Removing a portrait updates the draft before saving") {
            self.removalButton(named: "Ben", in: window) == nil
        }
        try await activateAccessibilityButton(named: "Create", in: window, within: form.view)

        try await waitUntil("Creating the group stores exactly the selected identities") { store.groups.count == 1 }
        let group = try XCTUnwrap(store.groups.first)
        XCTAssertEqual(group.name, "Family")
        XCTAssertEqual(Set(group.personIDs), ["a", "c"])
        XCTAssertEqual(self.store().groups, [group])
        try await waitUntil("The successful group form closes") { self.nameField(in: window) == nil }
    }

    func testEditingGroupUsesRemovablePortraitsAndCancelDoesNotApplyAddedPeople() async throws {
        let store = store()
        let people = [person("a", name: "Ada"), person("b", name: "Ben"), person("c", name: "Chris")]
        let group = try XCTUnwrap(store.save(name: "Family", personIDs: ["a", "b"]))
        let window = try await host(GroupEditorTestHost(group: group, people: people, store: store))
        try await waitUntil("Editing opens the existing name and removable portraits directly") {
            self.nameField(in: window) != nil && self.removalButton(named: "Ben", in: window) != nil
        }
        let form = try XCTUnwrap(window.rootViewController?.presentedViewController)
        try await removeMember(named: "Ben", in: window)
        try await activateAccessibilityButton(named: "Add People", in: window, within: form.view)
        let canceledPicker = try await memberPicker(from: form)
        try await activateAccessibilityButton(named: "Chris", in: window, within: canceledPicker.view)
        try await activateAccessibilityButton(named: "Cancel", in: window, within: canceledPicker.view)
        try await waitUntil("Cancel dismisses the member picker without applying its draft") {
            form.presentedViewController == nil
        }
        XCTAssertNil(removalButton(named: "Chris", in: window))
        XCTAssertEqual(store.groups, [group], "Member edits stay local until the editor's Done action")
        try await activateAccessibilityButton(named: "Add People", in: window, within: form.view)
        let savedPicker = try await memberPicker(from: form)
        try await activateAccessibilityButton(named: "Chris", in: window, within: savedPicker.view)
        try await activateAccessibilityButton(named: "Done", in: window, within: savedPicker.view)
        try await waitUntil("Done applies the member picker draft to the editor") {
            self.removalButton(named: "Chris", in: window) != nil
        }
        try await activateAccessibilityButton(named: "Done", in: window, within: form.view)
        try await waitUntil("Saving preserves the group identity and the confirmed member changes") {
            store.group(group.id)?.personIDs == ["a", "c"]
        }
        XCTAssertEqual(store.group(group.id)?.name, "Family")
        XCTAssertEqual(self.store().group(group.id), store.group(group.id))
    }

    func testDeletingGroupPresentsItsActualConfirmationWithoutChangingTheStoredGroup() async throws {
        let store = store()
        let people = [person("a", name: "Ada"), person("b", name: "Ben")]
        let group = try XCTUnwrap(store.save(name: "Family", personIDs: ["a", "b"]))
        let window = try await host(NavigationStack { PeopleGroupsSection(people: people, store: store) })
        var action: UIAccessibilityCustomAction?
        try await waitUntil("The real group card exposes its Delete Group action") {
            var visited = Set<ObjectIdentifier>()
            action = self.customAction(in: window, visited: &visited, depth: 0)
            return action != nil
        }
        let delete = try XCTUnwrap(action)
        if let handler = delete.actionHandler { XCTAssertTrue(handler(delete)) }
        else {
            XCTAssertTrue(UIApplication.shared.sendAction(delete.selector, to: try XCTUnwrap(delete.target), from: delete, for: nil))
        }
        try await waitUntil("The card presents its own delete confirmation") {
            self.presentedAlert(from: window.rootViewController) != nil
        }
        let confirmation = try XCTUnwrap(presentedAlert(from: window.rootViewController))
        try await waitUntil("The native confirmation finishes presenting") {
            !confirmation.isBeingPresented && confirmation.view.window != nil
        }
        XCTAssertEqual(confirmation.title, "Delete Group?")
        XCTAssertEqual(confirmation.message, "The photos will stay in your library.")
        XCTAssertEqual(confirmation.actions.map(\.title), ["Delete Group", "Cancel"])
        XCTAssertEqual(confirmation.actions.first?.style, .destructive)
        XCTAssertTrue(try XCTUnwrap(confirmation.actions.first).isEnabled)
        XCTAssertEqual(confirmation.actions.last?.style, .cancel)
        XCTAssertEqual(store.groups, [group], "Opening a confirmation must leave the group intact")
        XCTAssertEqual(self.store().groups, [group], "An unconfirmed deletion must not change persisted groups")
    }

    func testMissingGroupMemberShowsUnavailableInsteadOfAnotherPersonsPhotos() async throws {
        let store = store()
        let group = try XCTUnwrap(store.save(name: "Family", personIDs: ["a", "missing"]))
        let window = try await host(NavigationStack {
            PeopleGroupDetailView(groupID: group.id, people: [person("a", name: "Ada")], store: store)
        })
        let image = try await screenshot(window)
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["en-US"]
        try VNImageRequestHandler(cgImage: try XCTUnwrap(image.cgImage)).perform([request])
        let text = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: " ")
        XCTAssertTrue(text.contains("Group Unavailable"), text)
        XCTAssertFalse(text.contains("Family"), "Unavailable members must not be replaced with a broader named gallery")
        XCTAssertEqual(store.groups.map(\.id), [group.id], "A missing member does not delete the saved group")
    }

    private func store() -> PeopleGroupsStore {
        PeopleGroupsStore(owner: BackupQueueOwner(server: "https://synthetic.example/api", userID: "user"), defaults: defaults)
    }

    private func person(_ id: String, name: String) -> PersonDTO {
        PersonDTO(id: id, name: name, birthDate: nil, thumbnailPath: nil, isHidden: false)
    }

    private func nameField(in view: UIView) -> UITextField? {
        if let field = view as? UITextField, field.placeholder == "Group Name" { return field }
        return view.subviews.lazy.compactMap { self.nameField(in: $0) }.first
    }

    private func removeMember(named name: String, in window: UIWindow) async throws {
        let button = try XCTUnwrap(removalButton(named: name, in: window), "The real member portrait must expose its remove action")
        if let control = button as? UIControl { control.performPrimaryAction() }
        else { XCTAssertTrue(button.accessibilityActivate(), "The actual member removal must activate") }
    }

    private func memberPicker(from form: UIViewController) async throws -> UIViewController {
        try await waitUntil("The member picker is actually presented over the name form") {
            form.presentedViewController?.view.window != nil && form.presentedViewController?.isBeingPresented == false
        }
        return try XCTUnwrap(form.presentedViewController)
    }

    private func removalButton(named name: String, in root: NSObject) -> NSObject? {
        var visited = Set<ObjectIdentifier>()
        func find(_ object: NSObject, depth: Int) -> NSObject? {
            guard depth < 40, visited.insert(ObjectIdentifier(object)).inserted else { return nil }
            if let view = object as? UIView, view.isHidden || view.alpha <= 0 { return nil }
            if object.accessibilityLabel == "Remove", object.accessibilityValue == name,
               object.accessibilityTraits.contains(.button) { return object }
            if let view = object as? UIView {
                for child in view.subviews { if let result = find(child, depth: depth + 1) { return result } }
            }
            if let elements = object.accessibilityElements {
                for case let child as NSObject in elements {
                    if let result = find(child, depth: depth + 1) { return result }
                }
            }
            let count = object.accessibilityElementCount()
            if (1...500).contains(count) {
                for index in 0..<count {
                    if let child = object.accessibilityElement(at: index) as? NSObject,
                       let result = find(child, depth: depth + 1) { return result }
                }
            }
            return nil
        }
        return find(root, depth: 0)
    }

    private func presentedAlert(from controller: UIViewController?) -> UIAlertController? {
        guard let controller else { return nil }
        if let alert = controller as? UIAlertController { return alert }
        if let alert = presentedAlert(from: controller.presentedViewController) { return alert }
        return controller.children.compactMap { presentedAlert(from: $0) }.first
    }

    private func customAction(in object: NSObject, visited: inout Set<ObjectIdentifier>, depth: Int) -> UIAccessibilityCustomAction? {
        guard depth < 40, visited.insert(ObjectIdentifier(object)).inserted else { return nil }
        if let view = object as? UIView, view.isHidden || view.alpha == 0 { return nil }
        if let action = object.accessibilityCustomActions?.first(where: { $0.name == "Delete Group" }) { return action }
        if let view = object as? UIView {
            for child in view.subviews {
                if let action = customAction(in: child, visited: &visited, depth: depth + 1) { return action }
            }
        }
        if let elements = object.accessibilityElements {
            for case let child as NSObject in elements {
                if let action = customAction(in: child, visited: &visited, depth: depth + 1) { return action }
            }
        }
        let count = object.accessibilityElementCount()
        if (1...500).contains(count) {
            for index in 0..<count {
                if let child = object.accessibilityElement(at: index) as? NSObject,
                   let action = customAction(in: child, visited: &visited, depth: depth + 1) { return action }
            }
        }
        return nil
    }
}

private struct GroupEditorTestHost: View {
    var group: PeopleGroup? = nil
    let people: [PersonDTO]
    let store: PeopleGroupsStore
    @State private var showsEditor = true
    var body: some View {
        Color.clear.sheet(isPresented: $showsEditor) { PeopleGroupEditor(group: group, people: people, store: store) }
    }
}
