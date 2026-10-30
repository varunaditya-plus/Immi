import Foundation
import XCTest
@testable import ImmichApp

@MainActor
final class CollectionsPreferencesTests: XCTestCase {
    private var suiteName = ""
    private var defaults: UserDefaults!

    override func setUp() {
        suiteName = "collections-preferences-\(UUID())"
        defaults = UserDefaults(suiteName: suiteName)!
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
    }

    func testReorderLayoutPinsAndCollapsedMemoriesSurviveRelaunch() {
        let owner = BackupQueueOwner(server: "https://photos.example/api", userID: "alice")
        let first = CollectionsPreferencesStore(owner: owner, defaults: defaults)
        var choices = CollectionsPreferences()
        choices.sectionOrder = [.albums] + choices.sectionOrder.filter { $0 != .albums }
        choices.layout = .large
        choices.pinnedCollections = [.album("holiday"), .favorites]
        choices.collapseAll()
        first.save(choices)

        let relaunched = CollectionsPreferencesStore(owner: owner, defaults: defaults).load()

        XCTAssertEqual(relaunched, choices)
        XCTAssertEqual(relaunched.sectionOrder.first, .albums)
        XCTAssertTrue(relaunched.collapsedSections.contains(.memories), "Relaunch must not force a user's collapsed Memories open")
        XCTAssertEqual(relaunched.pinnedCollections, [.album("holiday"), .favorites])
        var shown = relaunched
        shown.showAll()
        XCTAssertTrue(shown.collapsedSections.isEmpty)
        XCTAssertEqual(shown.layout, .large)
        XCTAssertEqual(shown.sectionOrder, choices.sectionOrder)
    }

    func testPreferencesAreScopedByBothServerAndUser() {
        let alice = BackupQueueOwner(server: "https://one.example/api", userID: "alice")
        let bob = BackupQueueOwner(server: "https://one.example/api", userID: "bob")
        let otherServer = BackupQueueOwner(server: "https://two.example/api", userID: "alice")
        var custom = CollectionsPreferences()
        custom.layout = .small
        custom.pinnedCollections = [.album("private-album")]
        CollectionsPreferencesStore(owner: alice, defaults: defaults).save(custom)

        XCTAssertEqual(CollectionsPreferencesStore(owner: bob, defaults: defaults).load(), CollectionsPreferences())
        XCTAssertEqual(CollectionsPreferencesStore(owner: otherServer, defaults: defaults).load(), CollectionsPreferences())
        XCTAssertEqual(CollectionsPreferencesStore(owner: alice, defaults: defaults).load(), custom)
    }

    func testAnonymousViewsDoNotPersistAnotherAccountsAlbumReferences() {
        var custom = CollectionsPreferences()
        custom.pinnedCollections = [.album("private-album")]
        CollectionsPreferencesStore(owner: nil, defaults: defaults).save(custom)

        XCTAssertEqual(CollectionsPreferencesStore(owner: nil, defaults: defaults).load(), CollectionsPreferences())
        XCTAssertTrue(defaults.dictionaryRepresentation().keys.filter { $0.hasPrefix("collections.preferences") }.isEmpty)
    }

    func testOldAccountGenerationCannotWriteNewPreferences() {
        let owner = BackupQueueOwner(server: "https://photos.example/api", userID: "alice")
        let old = CollectionsPreferencesStore(owner: owner, defaults: defaults)
        var original = CollectionsPreferences()
        original.layout = .small
        old.save(original)
        LocalSnapshot.clearAll()
        var late = original
        late.pinnedCollections = [.album("late-private-album")]
        old.save(late)

        XCTAssertEqual(CollectionsPreferencesStore(owner: owner, defaults: defaults).load(), original)
    }

    func testDecodingRetainsKnownOrderAndAddsNewSectionsWithoutDuplicates() throws {
        let bytes = Data(#"{"sectionOrder":["albums","unknown-future","albums","pinned"],"collapsedSections":["memories","unknown"],"pinnedCollections":["album:holiday","invalid","favorites","favorites"],"layout":"future-layout"}"#.utf8)

        let result = try JSONDecoder().decode(CollectionsPreferences.self, from: bytes)

        XCTAssertEqual(Array(result.sectionOrder.prefix(2)), [.albums, .pinned])
        XCTAssertEqual(Set(result.sectionOrder), Set(CollectionsSection.allCases))
        XCTAssertEqual(result.sectionOrder.count, CollectionsSection.allCases.count)
        XCTAssertEqual(result.collapsedSections, [.memories])
        XCTAssertEqual(result.pinnedCollections, [.album("holiday"), .favorites])
        XCTAssertEqual(result.layout, .mixed)
    }

    func testAnIntentionallyEmptyPinnedListStaysEmpty() throws {
        let result = try JSONDecoder().decode(CollectionsPreferences.self, from: Data(#"{"pinnedCollections":[]}"#.utf8))
        XCTAssertTrue(result.pinnedCollections.isEmpty)
        let roundTrip = try JSONDecoder().decode(CollectionsPreferences.self, from: JSONEncoder().encode(result))
        XCTAssertTrue(roundTrip.pinnedCollections.isEmpty)
    }

    func testLegacyExpansionMigratesOnceIntoTheActiveAccount() {
        defaults.set("albums,people", forKey: "library.expandedRows")
        let owner = BackupQueueOwner(server: "https://photos.example/api", userID: "alice")
        let migrated = CollectionsPreferencesStore(owner: owner, defaults: defaults).load()

        XCTAssertFalse(migrated.collapsedSections.contains(.memories), "The old setting never persisted a Memories choice")
        XCTAssertTrue(migrated.collapsedSections.contains(.featured))
        XCTAssertFalse(migrated.collapsedSections.contains(.albums))
        XCTAssertFalse(migrated.collapsedSections.contains(.people))
        XCTAssertNil(defaults.object(forKey: "library.expandedRows"))
        XCTAssertEqual(CollectionsPreferencesStore(owner: owner, defaults: defaults).load(), migrated)
        XCTAssertEqual(CollectionsPreferencesStore(owner: .init(server: owner.server, userID: "bob"), defaults: defaults).load(),
            CollectionsPreferences())
    }

    func testConfirmedAlbumRemovalOnlyPrunesMissingAlbumPins() {
        var choices = CollectionsPreferences()
        choices.pinnedCollections = [.favorites, .album("removed"), .map, .album("kept")]

        choices.removeMissingAlbums(["kept", "not-pinned"])

        XCTAssertEqual(choices.pinnedCollections, [.favorites, .map, .album("kept")])
        XCTAssertEqual(choices.sectionOrder, CollectionsSection.allCases)
    }
}
