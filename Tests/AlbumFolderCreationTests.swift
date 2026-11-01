import SwiftUI
import UIKit
import Vision
import XCTest
@testable import ImmichApp

@MainActor
final class AlbumFolderCreationTests: SimulatorHostedTestCase {
    private var previousAlbums: [AlbumResponseDTO]?
    private var previousLayout: Any?
    private var previousCustomOrder: Any?
    private var suite: String?

    override func setUp() {
        previousAlbums = LocalSnapshot.load([AlbumResponseDTO].self, for: LocalSnapshot.Key.albumsList)
        previousLayout = UserDefaults.standard.object(forKey: "albumsLayout")
        previousCustomOrder = UserDefaults.standard.object(forKey: "albumsCustomOrder")
        UserDefaults.standard.set("grid", forKey: "albumsLayout")
    }

    override func tearDown() async throws {
        try await super.tearDown()
        if let previousAlbums { LocalSnapshot.save(previousAlbums, for: LocalSnapshot.Key.albumsList) }
        else { LocalSnapshot.remove(LocalSnapshot.Key.albumsList) }
        if let previousLayout { UserDefaults.standard.set(previousLayout, forKey: "albumsLayout") }
        else { UserDefaults.standard.removeObject(forKey: "albumsLayout") }
        if let previousCustomOrder { UserDefaults.standard.set(previousCustomOrder, forKey: "albumsCustomOrder") }
        else { UserDefaults.standard.removeObject(forKey: "albumsCustomOrder") }
        if let suite { UserDefaults.standard.removePersistentDomain(forName: suite) }
    }

    func testCreatingAnAlbumInsideAFolderKeepsItsSharedAlbumsVisible() async throws {
        try await checkCreation(inFolder: true)
    }

    func testCreatingAnAlbumFromSharedScopeAtTheRootShowsTheNewPersonalAlbum() async throws {
        try await checkCreation(inFolder: false)
    }

    func testSharedGridKeepsAlbumsFromNestedPersonalFoldersVisible() async throws {
        try await checkSharedFolderVisibility(customOrder: true, style: .light)
    }

    func testSortedSharedListKeepsAlbumsFromNestedPersonalFoldersVisibleInDarkMode() async throws {
        UserDefaults.standard.set("list", forKey: "albumsLayout")
        try await checkSharedFolderVisibility(customOrder: false, style: .dark)
    }

    func testSharedCreateMenuPresentsAnEditableNativeFolderAlertWithoutSavingBeforeConfirmation() async throws {
        let organization = try makeOrganization()
        let repository = FolderCreationRepository(api: makeStubAPIClient())
        let model = AlbumListViewModel(repo: repository)
        let window = try await host(NavigationStack {
            AlbumsListView(viewModel: model, initialScope: .shared, organizationStore: organization)
        })
        try await waitUntil("The real shared scope finishes loading") { model.hasLoadedAlbums }
        try await activateSearchMenuAction(named: "New Folder", in: window, menuButton: "Create")
        let alert = try await presentedNativeAlert(in: window)
        XCTAssertEqual(alert.title, "New Folder")
        XCTAssertEqual(alert.message, "Folders are saved on this device.")
        XCTAssertEqual(alert.preferredStyle, .alert)
        let field = try XCTUnwrap(alert.textFields?.first)
        XCTAssertEqual(field.placeholder, "Folder Name")
        XCTAssertTrue(field.text?.isEmpty != false)
        let create = try XCTUnwrap(alert.actions.first { $0.title == "Create" })
        XCTAssertFalse(create.isEnabled, "An empty folder name cannot be submitted")
        let cancel = try XCTUnwrap(alert.actions.first { $0.title == "Cancel" })
        XCTAssertEqual(cancel.style, .cancel)
        XCTAssertTrue(cancel.isEnabled)
        XCTAssertTrue(organization.value.folders.isEmpty)

        field.text = "Created folder"
        field.sendActions(for: .editingChanged)
        try await waitUntil("The actual folder-name input enables the native Create action") {
            alert.actions.first { $0.title == "Create" }?.isEnabled == true
        }
        XCTAssertEqual(field.text, "Created folder")
        XCTAssertTrue(organization.value.folders.isEmpty, "Editing a folder name must not save before confirmation")
    }

    func testSharedReorderSheetUsesSharedAlbumsAcrossFoldersAndPreservesPersonalOrder() async throws {
        let organization = try makeOrganization()
        let folder = try XCTUnwrap(organization.createFolder(name: "Private folder", parentID: nil))
        let shared = AlbumResponseDTO(id: UUID().uuidString, albumName: "Shared mountain", description: nil,
            assetCount: 0, albumThumbnailAssetId: nil, shared: true, createdAt: .distantPast, assets: nil)
        let personal = AlbumResponseDTO(id: UUID().uuidString, albumName: "Personal beach", description: nil,
            assetCount: 0, albumThumbnailAssetId: nil, shared: false, createdAt: .distantPast, assets: nil)
        organization.moveAlbum(shared.id, to: folder.id)
        let personalOrder = [AlbumOrganization.albumEntry(personal.id), AlbumOrganization.folderEntry(folder.id)]
        organization.setContainerOrder(personalOrder, in: nil)
        let repository = FolderCreationRepository(api: makeStubAPIClient())
        repository.albums = [personal, shared]
        let model = AlbumListViewModel(repo: repository)
        let window = try await host(NavigationStack {
            AlbumsListView(viewModel: model, initialScope: .shared, organizationStore: organization)
        })
        try await waitUntil("The shared scope has loaded") { model.hasLoadedAlbums }
        try await activateSearchMenuAction(named: "Reorder Albums", in: window)
        try await waitUntil("The real reorder sheet is presented") {
            self.presentedController(from: window.rootViewController) != nil
        }
        let text = try await renderedText(in: window, containing: ["Reorder Albums", "Shared mountain"])
        XCTAssertTrue(text.contains("Shared mountain"), text)
        XCTAssertFalse(text.contains("Personal beach"), text)
        XCTAssertFalse(text.contains("Private folder"), text)
        try await activateAccessibilityButton(named: "Done", in: window)
        XCTAssertEqual(organization.value.containerOrders[AlbumOrganization.sharedContainer],
            [AlbumOrganization.albumEntry(shared.id)])
        XCTAssertEqual(organization.value.containerOrders["root"], personalOrder)
        XCTAssertEqual(organization.value.albumFolders[shared.id], folder.id)
    }

    private func checkSharedFolderVisibility(customOrder: Bool, style: UIUserInterfaceStyle) async throws {
        UserDefaults.standard.set(customOrder, forKey: "albumsCustomOrder")
        let organization = try makeOrganization()
        let parent = try XCTUnwrap(organization.createFolder(name: "Trips folder", parentID: nil))
        let child = try XCTUnwrap(organization.createFolder(name: "Nested folder", parentID: parent.id))
        let shared = AlbumResponseDTO(id: UUID().uuidString, albumName: "Shared mountain", description: nil,
            assetCount: 0, albumThumbnailAssetId: nil, shared: true, createdAt: .distantPast, assets: nil)
        let personal = AlbumResponseDTO(id: UUID().uuidString, albumName: "Personal beach", description: nil,
            assetCount: 0, albumThumbnailAssetId: nil, shared: false, createdAt: .distantPast, assets: nil)
        organization.moveAlbum(shared.id, to: child.id)
        let repository = FolderCreationRepository(api: makeStubAPIClient())
        repository.albums = [shared, personal]
        let model = AlbumListViewModel(repo: repository)
        let window = try await host(NavigationStack {
            AlbumsListView(viewModel: model, initialScope: .shared, organizationStore: organization)
        }, style: style)
        try await waitUntil("The shared album browser loads the fixture") { model.hasLoadedAlbums }
        let text = try await renderedText(in: window, containing: ["Shared mountain"])
        XCTAssertTrue(text.contains("Shared mountain"), "Shared albums must remain reachable after a move: \(text)")
        XCTAssertFalse(text.contains("Personal beach"), text)
        XCTAssertFalse(text.contains("Trips folder"), text)
        XCTAssertEqual(organization.value.albumFolders[shared.id], child.id,
            "Showing Shared must preserve the user's Personal folder organization")
    }

    private func makeOrganization() throws -> AlbumsOrganizationStore {
        let suite = "album-folder-creation.\(UUID().uuidString)"
        self.suite = suite
        return AlbumsOrganizationStore(owner: BackupQueueOwner(server: "https://synthetic.example/api", userID: "test"),
            defaults: try XCTUnwrap(UserDefaults(suiteName: suite)))
    }

    private func checkCreation(inFolder: Bool) async throws {
        let suite = "album-folder-creation.\(UUID().uuidString)"
        self.suite = suite
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let organization = AlbumsOrganizationStore(
            owner: BackupQueueOwner(server: "https://synthetic.example/api", userID: "test"), defaults: defaults)
        let folderID = inFolder ? try XCTUnwrap(organization.createFolder(name: "Trips", parentID: nil)).id : nil
        let shared = AlbumResponseDTO(id: UUID().uuidString, albumName: "Shared trip", description: nil,
            assetCount: 0, albumThumbnailAssetId: nil, shared: true, createdAt: .distantPast, assets: nil)
        organization.moveAlbum(shared.id, to: folderID)
        let repository = FolderCreationRepository(api: makeStubAPIClient())
        repository.albums = [shared]
        let model = AlbumListViewModel(repo: repository)
        let window = try await host(NavigationStack {
            AlbumsListView(viewModel: model, initialScope: inFolder ? .all : .shared,
                organizationStore: organization, folderID: folderID)
        })
        try await waitUntil("The album browser has loaded its real folder membership") { model.hasLoadedAlbums }
        var text = try await renderedText(in: window, containing: ["Shared trip"])
        XCTAssertTrue(text.contains("Shared trip"), text)
        model.showCreateSheet = true
        try await waitUntil("The actual New Album form finishes presenting") {
            guard let form = self.presentedController(from: window.rootViewController) else { return false }
            return form.transitionCoordinator == nil && self.nameField(in: form.view) != nil
        }
        let form = try XCTUnwrap(presentedController(from: window.rootViewController))
        let name = try XCTUnwrap(nameField(in: form.view))
        name.text = "Created album"
        name.sendActions(for: .editingChanged)

        try await activateAccessibilityButton(named: "Create", in: window, within: form.view)

        try await waitUntil("Creation through the form adds the new album") { repository.created != nil }
        try await waitUntil("The successful form closes") { self.nameField(in: window) == nil }
        text = try await renderedText(in: window, containing: inFolder ? ["Shared trip", "Created album"] : ["Created album"])
        XCTAssertTrue(text.contains("Created album"), text)
        XCTAssertEqual(model.albums.count, 2)
        let created = try XCTUnwrap(repository.created)
        XCTAssertEqual(organization.value.albumFolders[created.id], folderID)
        if inFolder {
            XCTAssertTrue(text.contains("Shared trip"), "Creating a private album cannot hide shared members of a folder: \(text)")
        } else {
            XCTAssertFalse(text.contains("Shared trip"), "Root creation must switch to Personal: \(text)")
        }
    }

    private func nameField(in view: UIView) -> UITextField? {
        if let field = view as? UITextField, field.placeholder == "Album Name" { return field }
        return view.subviews.lazy.compactMap { self.nameField(in: $0) }.first
    }

    private func presentedController(from controller: UIViewController?) -> UIViewController? {
        guard let presented = controller?.presentedViewController else { return nil }
        return presentedController(from: presented) ?? presented
    }

    private func renderedText(in window: UIWindow, containing expected: [String]) async throws -> String {
        let deadline = Date().addingTimeInterval(4)
        var text = ""
        repeat {
            let image = try await screenshot(window)
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.recognitionLanguages = ["en-US"]
            try VNImageRequestHandler(cgImage: try XCTUnwrap(image.cgImage)).perform([request])
            text = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: " ")
            if expected.allSatisfy({ text.contains($0) }) { break }
        } while Date() < deadline
        return text
    }
}

private final class FolderCreationRepository: AlbumRepository {
    var albums: [AlbumResponseDTO] = []
    var created: AlbumResponseDTO?

    override func all() async throws -> [AlbumResponseDTO] { albums }

    override func create(name: String, description: String?, assetIds: [String]) async throws -> AlbumResponseDTO {
        let album = AlbumResponseDTO(id: UUID().uuidString, albumName: name, description: description,
            assetCount: 0, albumThumbnailAssetId: nil, shared: false, createdAt: Date(), assets: nil)
        created = album
        albums.append(album)
        return album
    }

    override func recentAssetIDs(in albumID: String, limit: Int, includeArchived: Bool = true) async throws -> [String] { [] }
}
