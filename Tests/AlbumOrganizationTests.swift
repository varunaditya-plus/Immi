import XCTest
@testable import ImmichApp

@MainActor
final class AlbumOrganizationTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suite: String!

    override func setUp() async throws {
        try await super.setUp()
        suite = "AlbumOrganizationTests.\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suite)
        try await super.tearDown()
    }

    func testFoldersMoveAlbumReferencesAndDeletingFolderKeepsItsAlbumsAndChildren() throws {
        let store = store()
        let parent = try XCTUnwrap(store.createFolder(name: "  Holidays  ", parentID: nil))
        let child = try XCTUnwrap(store.createFolder(name: "Summer", parentID: parent.id))
        let albums = [album("a"), album("b")]
        store.moveAlbum("a", to: parent.id)
        store.moveAlbum("b", to: child.id)

        XCTAssertEqual(parent.name, "Holidays")
        XCTAssertTrue(store.orderedAlbums(albums).isEmpty)
        XCTAssertEqual(store.orderedAlbums(albums, in: parent.id).map(\.id), ["a"])
        XCTAssertEqual(store.orderedAlbums(albums, in: child.id).map(\.id), ["b"])
        store.removeFolder(parent.id)

        XCTAssertEqual(store.orderedAlbums(albums).map(\.id), ["a"])
        XCTAssertEqual(store.value.childFolders(of: nil).map(\.id), [child.id])
        XCTAssertEqual(store.orderedAlbums(albums, in: child.id).map(\.id), ["b"])
        XCTAssertEqual(albums.map(\.assetCount), [3, 3])
    }

    func testCustomOrderSurvivesRelaunchAndKeepsNewAlbumsReachable() throws {
        let original = store()
        let folder = try XCTUnwrap(original.createFolder(name: "Work", parentID: nil))
        original.moveAlbum("inside", to: folder.id)
        original.setContainerOrder(["album:b", "album:a", "album:b"], in: nil)
        let restored = store()

        XCTAssertEqual(restored.value.folders, [folder])
        XCTAssertEqual(restored.value.containerOrders["root"], ["album:b", "album:a"])
        XCTAssertEqual(restored.orderedAlbums([album("new"), album("a"), album("b"), album("inside")]).map(\.id),
                       ["b", "a", "new"])
        XCTAssertEqual(restored.orderedAlbums([album("inside")], in: folder.id).map(\.id), ["inside"])
    }

    func testFolderAndAlbumNamesDoNotCrossServersOrAccounts() throws {
        let original = store()
        let folder = try XCTUnwrap(original.createFolder(name: "Private name", parentID: nil))
        original.moveAlbum("same-id", to: folder.id)
        let otherUser = store(user: "other")
        let otherServer = store(server: "https://second.example/api")

        XCTAssertTrue(otherUser.value.folders.isEmpty)
        XCTAssertTrue(otherServer.value.folders.isEmpty)
        XCTAssertEqual(otherUser.orderedAlbums([album("same-id")]).map(\.id), ["same-id"])
        XCTAssertEqual(otherServer.orderedAlbums([album("same-id")]).map(\.id), ["same-id"])
        XCTAssertEqual(store().value.folders.map(\.name), ["Private name"])
    }

    func testExpiredStoreCannotWriteAfterAccountGenerationChanges() throws {
        let expired = store()
        _ = expired.createFolder(name: "Saved", parentID: nil)
        LocalSnapshot.clearAll()
        let current = store()

        XCTAssertNil(expired.createFolder(name: "Late", parentID: nil))
        expired.setPhotoSort(.custom, albumID: "album")
        expired.moveAlbum("album", to: nil)

        XCTAssertEqual(current.value.folders.map(\.name), ["Saved"])
        XCTAssertEqual(store().value, current.value)
        XCTAssertNil(store().value.photoSorts["album"])
    }

    func testCustomPhotoOrderFiltersOnlyAfterOrderingAndReconcilesMembership() {
        let store = store()
        let a = photo("a", date: 1)
        let b = photo("b", date: 2, favorite: true)
        let c = photo("c", date: 3, video: true)
        let added = photo("new", date: 0)
        store.setPhotoOrder(["c", "removed", "a", "b", "a"], albumID: "album")

        XCTAssertEqual(store.value.orderedPhotos([added, b, c, a], albumID: "album").map(\.id), ["c", "a", "b", "new"])
        store.setPhotoFilter(.favorites, albumID: "album")
        XCTAssertEqual(store.value.orderedPhotos([added, b, c, a], albumID: "album").map(\.id), ["b"])
        store.setPhotoFilter(.videos, albumID: "album")
        XCTAssertEqual(store.value.orderedPhotos([added, b, c, a], albumID: "album").map(\.id), ["c"])
        store.setPhotoFilter(.photos, albumID: "album")
        XCTAssertEqual(store.value.orderedPhotos([added, b, c, a], albumID: "album").map(\.id), ["a", "b", "new"])
        store.setPhotoFilter(.all, albumID: "album")
        store.setPhotoSort(.newestFirst, albumID: "album")
        XCTAssertEqual(store.value.orderedPhotos([added, b, c, a], albumID: "album").map(\.id), ["c", "b", "a", "new"])
        XCTAssertEqual(self.store().value.photoSorts["album"], .newestFirst)
    }

    func testRemovingAlbumClearsItsLocalOrganizationWithoutDeletingOtherPreferences() throws {
        let store = store()
        let folder = try XCTUnwrap(store.createFolder(name: "Keep", parentID: nil))
        store.moveAlbum("deleted", to: folder.id)
        store.setPhotoOrder(["photo"], albumID: "deleted")
        store.setPhotoFilter(.favorites, albumID: "deleted")
        store.setContainerOrder(["album:deleted", "album:kept"], in: nil)
        store.removeAlbum("deleted")

        XCTAssertNil(store.value.albumFolders["deleted"])
        XCTAssertNil(store.value.photoOrders["deleted"])
        XCTAssertNil(store.value.photoFilters["deleted"])
        XCTAssertNil(store.value.photoSorts["deleted"])
        XCTAssertEqual(store.value.containerOrders["root"], ["album:kept"])
        XCTAssertEqual(store.value.folders, [folder])
    }

    func testEmptyNamesAndUnknownDestinationsDoNotCreateUnreachableAlbums() {
        let store = store()
        XCTAssertNil(store.createFolder(name: " \n ", parentID: nil))
        XCTAssertNil(store.createFolder(name: "Invalid parent", parentID: "missing"))
        store.moveAlbum("a", to: "missing")
        XCTAssertEqual(store.orderedAlbums([album("a")]).map(\.id), ["a"])
        XCTAssertTrue(store.value.folders.isEmpty)
    }

    func testAuthoritativeAlbumReconciliationRemovesStaleReferencesButKeepsFolders() throws {
        let store = store()
        let folder = try XCTUnwrap(store.createFolder(name: "Keep folder", parentID: nil))
        store.moveAlbum("removed", to: folder.id)
        store.setPhotoOrder(["private-photo"], albumID: "removed")
        store.setPhotoFilter(.favorites, albumID: "removed")
        store.setContainerOrder(["album:removed", "album:kept", "folder:\(folder.id)"], in: nil)
        store.reconcileAlbums(["kept"])

        XCTAssertNil(store.value.albumFolders["removed"])
        XCTAssertNil(store.value.photoOrders["removed"])
        XCTAssertNil(store.value.photoSorts["removed"])
        XCTAssertNil(store.value.photoFilters["removed"])
        XCTAssertEqual(store.value.containerOrders["root"], ["album:kept", "folder:\(folder.id)"])
        XCTAssertEqual(store.value.folders, [folder])
    }

    private func store(server: String = "https://first.example/api", user: String = "owner") -> AlbumsOrganizationStore {
        AlbumsOrganizationStore(owner: BackupQueueOwner(server: server, userID: user), defaults: defaults)
    }

    private func album(_ id: String) -> AlbumResponseDTO {
        .init(id: id, albumName: id, description: nil, assetCount: 3, albumThumbnailAssetId: nil,
              shared: false, createdAt: .distantPast, assets: nil)
    }

    private func photo(_ id: String, date: TimeInterval, favorite: Bool = false, video: Bool = false) -> AssetLite {
        AssetLite(id: id, isVideo: video, ratio: 1, thumbhash: nil,
                  createdAt: Date(timeIntervalSince1970: date), isFavorite: favorite)
    }
}
