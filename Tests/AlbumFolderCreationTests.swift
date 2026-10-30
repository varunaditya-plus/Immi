import SwiftUI
import UIKit
import Vision
import XCTest
@testable import ImmichApp

@MainActor
final class AlbumFolderCreationTests: SimulatorHostedTestCase {
    private var previousAlbums: [AlbumResponseDTO]?
    private var previousLayout: Any?
    private var suite: String?

    override func setUp() {
        previousAlbums = LocalSnapshot.load([AlbumResponseDTO].self, for: LocalSnapshot.Key.albumsList)
        previousLayout = UserDefaults.standard.object(forKey: "albumsLayout")
        UserDefaults.standard.set("grid", forKey: "albumsLayout")
    }

    override func tearDown() async throws {
        try await super.tearDown()
        if let previousAlbums { LocalSnapshot.save(previousAlbums, for: LocalSnapshot.Key.albumsList) }
        else { LocalSnapshot.remove(LocalSnapshot.Key.albumsList) }
        if let previousLayout { UserDefaults.standard.set(previousLayout, forKey: "albumsLayout") }
        else { UserDefaults.standard.removeObject(forKey: "albumsLayout") }
        if let suite { UserDefaults.standard.removePersistentDomain(forName: suite) }
    }

    func testCreatingAnAlbumInsideAFolderKeepsItsSharedAlbumsVisible() async throws {
        try await checkCreation(inFolder: true)
    }

    func testCreatingAnAlbumFromSharedScopeAtTheRootShowsTheNewPersonalAlbum() async throws {
        try await checkCreation(inFolder: false)
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
