import SwiftUI
import UIKit
import XCTest
@testable import ImmichApp

@MainActor
final class PersonSharedLinkPresentationTests: SimulatorHostedTestCase {
    private var drivers: [PersonLinkDriver] = []
    private var photoIDs: [String] = []
    private var personIDs: [String] = []

    override func tearDown() async throws {
        drivers.forEach { $0.gate.complete(.failure(CancellationError())) }
        try await super.tearDown()
        try SwiftDataManager.shared.setAssetVisibility(photoIDs, to: "timeline")
        RemovedAssets.shared.restore(photoIDs)
        for id in personIDs { LocalSnapshot.remove(LocalSnapshot.Key.person(id)) }
        drivers.removeAll()
        photoIDs.removeAll()
        personIDs.removeAll()
    }

    func testLockedPhotoCannotPublishItsHeldPersonShareLink() async throws {
        try await rejectedLink { try SwiftDataManager.shared.setAssetVisibility([$0.photoID], to: "locked") }
    }

    func testTrashedPhotoCannotPublishItsHeldPersonShareLink() async throws {
        try await rejectedLink { RemovedAssets.shared.remove([$0.photoID], reason: .trashed) }
    }

    func testChangedServerCannotPublishItsHeldPersonShareLink() async throws {
        try await rejectedLink { try $0.session.setServer("https://person-link-after.example") }
    }

    func testExpiredAccountCannotPublishItsHeldPersonShareLink() async throws {
        try await rejectedLink { _ in LocalSnapshot.clearAll() }
    }

    func testAuthorizedPersonShareLinkOpensAndClosesWhenItsPhotoBecomesPrivate() async throws {
        let fixture = try await show()
        try await startLink(fixture)
        fixture.driver.gate.complete(.success(try link()))
        try await waitUntil("An authorized person link opens the real activity sheet") { self.activity(in: fixture.window.rootViewController) != nil }
        XCTAssertEqual(fixture.driver.requests, [[fixture.photoID]])

        try SwiftDataManager.shared.setAssetVisibility([fixture.photoID], to: "locked")

        try await waitUntil("Making the photo private closes its already presented link") { self.activity(in: fixture.window.rootViewController) == nil }
    }

    private func rejectedLink(_ revoke: (PersonLinkFixture) throws -> Void) async throws {
        let fixture = try await show()
        try await startLink(fixture)
        try revoke(fixture)
        fixture.driver.gate.complete(.success(try link()))
        try await waitUntil("The held local repository has returned its synthetic link") { fixture.driver.returned }
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertNil(activity(in: fixture.window.rootViewController), "A completed stale link must not reach an activity sheet")
        XCTAssertEqual(fixture.driver.requests, [[fixture.photoID]])
    }

    private func show() async throws -> PersonLinkFixture {
        let photo = makeTestAsset(id: UUID().uuidString)
        let person = makePeopleStatePerson(UUID().uuidString, name: "Synthetic Person")
        photoIDs.append(photo.id)
        personIDs.append(person.id)
        let session = MockSessionManager()
        try session.setServer("https://person-link-before.example")
        let driver = PersonLinkDriver()
        drivers.append(driver)
        let api = APIClient(session: session)
        let people = PersonLinkPeopleRepository(api: api, person: person, photo: photo)
        let links = PersonLinkRepository(api: api, driver: driver)
        let window = try await host(NavigationStack {
            PersonDetailView(person: person, repo: people, sharedLinkRepository: links)
        }.environment(session as SessionManager))
        try await waitUntil("The real person collection contains its synthetic photo") {
            self.grid(in: window.rootViewController)?.revealCell(for: photo.id) != nil
        }
        return PersonLinkFixture(window: window, session: session, driver: driver, photoID: photo.id)
    }

    private func startLink(_ fixture: PersonLinkFixture) async throws {
        try await activateAccessibilityButton(named: "Select", in: fixture.window)
        let grid = try XCTUnwrap(grid(in: fixture.window.rootViewController))
        let collection = try XCTUnwrap(grid.view.subviews.compactMap { $0 as? UICollectionView }.first)
        try await waitUntil("The actual person grid enters selection mode") { collection.isEditing }
        let path = try XCTUnwrap(grid.revealCell(for: fixture.photoID))
        collection.selectItem(at: path, animated: false, scrollPosition: [])
        grid.collectionView(collection, didSelectItemAt: path)
        try await activateSearchMenuAction(named: "Share Link", in: fixture.window)
        await fulfillment(of: [fixture.driver.gate.started], timeout: 2)
    }

    private func grid(in controller: UIViewController?) -> PhotoGridController? {
        guard let controller else { return nil }
        if let grid = controller as? PhotoGridController { return grid }
        return controller.children.lazy.compactMap { self.grid(in: $0) }.first
    }

    private func activity(in controller: UIViewController?) -> UIActivityViewController? {
        guard let controller else { return nil }
        if let activity = controller as? UIActivityViewController { return activity }
        if let activity = activity(in: controller.presentedViewController) { return activity }
        return controller.children.lazy.compactMap { self.activity(in: $0) }.first
    }

    private func link() throws -> SharedLinkDTO {
        try JSONDecoder.immich.decode(SharedLinkDTO.self, from: Data(#"{"id":"synthetic-link","key":"synthetic-key","type":"INDIVIDUAL"}"#.utf8))
    }
}

private struct PersonLinkFixture {
    let window: UIWindow
    let session: MockSessionManager
    let driver: PersonLinkDriver
    let photoID: String
}

@MainActor
private final class PersonLinkDriver {
    let gate = PeopleStateGate<SharedLinkDTO>()
    private(set) var requests: [[String]] = []
    private(set) var returned = false
    func create(_ ids: [String]) async throws -> SharedLinkDTO {
        requests.append(ids)
        defer { returned = true }
        return try await gate.value()
    }
}

private final class PersonLinkRepository: SharedLinkRepository {
    let driver: PersonLinkDriver
    init(api: APIClient, driver: PersonLinkDriver) { self.driver = driver; super.init(api: api) }
    override func create(assetIds: [String]) async throws -> SharedLinkDTO { try await driver.create(assetIds) }
}

private final class PersonLinkPeopleRepository: PeopleRepository {
    let person: PersonDTO
    let photo: AssetResponseDTO
    init(api: APIClient, person: PersonDTO, photo: AssetResponseDTO) {
        self.person = person; self.photo = photo
        super.init(api: api)
    }
    override func detail(_ id: String) async throws -> PersonDTO { person }
    override func assets(personId: String) async throws -> [AssetResponseDTO] { [photo] }
}
