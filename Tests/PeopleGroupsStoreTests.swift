import XCTest
@testable import ImmichApp

@MainActor
final class PeopleGroupsStoreTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suite = ""

    override func setUp() async throws {
        try await super.setUp()
        suite = "people-groups.\(UUID())"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suite)
        try await super.tearDown()
    }

    func testCreationRequiresDistinctPeopleAndEditsPreserveIdentity() throws {
        let store = store()
        XCTAssertNil(store.save(name: "Invalid", personIDs: ["a", "a", ""]))
        let group = try XCTUnwrap(store.save(name: "  Family  ", personIDs: ["a", "b", "a"]))
        XCTAssertEqual(group.name, "Family")
        XCTAssertEqual(group.personIDs, ["a", "b"])

        let edited = try XCTUnwrap(store.save(id: group.id, name: "Friends", personIDs: ["b", "c"]))

        XCTAssertEqual(edited.id, group.id)
        XCTAssertEqual(store.groups, [edited])
        XCTAssertEqual(self.store().groups, [edited])
    }

    func testGroupsAndTheirOrderStayScopedToAccountAndServer() throws {
        let store = store()
        let first = try XCTUnwrap(store.save(name: "First", personIDs: ["a", "b"]))
        let second = try XCTUnwrap(store.save(name: "Second", personIDs: ["a", "c"]))
        store.setOrder([second.id, second.id, "missing", first.id])

        XCTAssertEqual(self.store().groups.map(\.id), [second.id, first.id])
        XCTAssertTrue(self.store(user: "another").groups.isEmpty)
        XCTAssertTrue(self.store(server: "https://other.example/api").groups.isEmpty)
    }

    func testSeparateScreensMergeUnrelatedChangesAndDoNotResurrectDeletedGroups() throws {
        let firstScreen = store()
        let secondScreen = store()
        let first = try XCTUnwrap(firstScreen.save(name: "First", personIDs: ["a", "b"]))
        let second = try XCTUnwrap(secondScreen.save(name: "Second", personIDs: ["a", "c"]))
        firstScreen.setOrder([second.id, first.id])
        secondScreen.remove(first.id)

        XCTAssertNil(firstScreen.save(id: first.id, name: "Late edit", personIDs: ["a", "b"]))
        XCTAssertEqual(store().groups.map(\.id), [second.id])
        XCTAssertEqual(store().groups.first?.name, "Second")
    }

    func testStaleCoverCannotOverwriteEditedMembershipOrReviveADeletedGroup() throws {
        let first = store()
        let second = store()
        let group = try XCTUnwrap(first.save(name: "Group", personIDs: ["a", "b"]))
        _ = second.save(id: group.id, name: "Edited", personIDs: ["a", "c"])

        XCTAssertFalse(first.setKeyPhoto("stale", in: group.id, expectedPeople: ["a", "b"]))
        XCTAssertNil(store().group(group.id)?.keyPhotoID)
        XCTAssertTrue(first.setKeyPhoto("current", in: group.id, expectedPeople: ["c", "a"]))
        XCTAssertEqual(store().group(group.id)?.keyPhotoID, "current")
        second.remove(group.id)
        XCTAssertFalse(first.setKeyPhoto("late", in: group.id, expectedPeople: ["a", "c"]))
        XCTAssertTrue(store().groups.isEmpty)
    }

    func testExpiredStoreHidesItsGroupsAndRejectsLateWrites() throws {
        let old = store()
        let group = try XCTUnwrap(old.save(name: "Saved", personIDs: ["a", "b"]))
        LocalSnapshot.clearAll()

        XCTAssertTrue(old.groups.isEmpty)
        XCTAssertNil(old.save(name: "Late", personIDs: ["a", "b"]))
        XCTAssertFalse(old.setKeyPhoto("late", in: group.id, expectedPeople: group.personIDs))
        old.remove(group.id)
        XCTAssertEqual(store().groups.map(\.id), [group.id])
    }

    func testDefaultGroupNamesFollowCurrentPeopleWithoutLeakingHiddenMembers() throws {
        let group = try XCTUnwrap(store().save(name: "", personIDs: ["a", "b"]))
        let people = [person("a", name: "Ada"), person("b", name: "Ben")]
        XCTAssertTrue(group.title(in: people).contains("Ada"))
        XCTAssertTrue(group.title(in: people).contains("Ben"))
        let renamed = [person("a", name: "Alex"), person("b", name: "Ben")]
        XCTAssertTrue(group.title(in: renamed).contains("Alex"))
        XCTAssertFalse(group.title(in: renamed).contains("Ada"))
        XCTAssertFalse(group.isAvailable(in: [people[0]]))
        XCTAssertEqual(group.title(in: [people[0]]), String(localized: "Group Unavailable"))
        XCTAssertFalse(group.isAvailable(in: [people[0], person("b", hidden: true)]))
    }

    func testCardDropUsesLatestGroupsAndRejectsUnknownOrExpiredIDs() throws {
        let firstScreen = store()
        let secondScreen = store()
        let first = try XCTUnwrap(firstScreen.save(name: "First", personIDs: ["a", "b"]))
        let second = try XCTUnwrap(secondScreen.save(name: "Second", personIDs: ["a", "c"]))
        let third = try XCTUnwrap(secondScreen.save(name: "Third", personIDs: ["b", "c"]))

        XCTAssertTrue(firstScreen.move(first.id, to: third.id))
        XCTAssertEqual(store().groups.map(\.id), [second.id, third.id, first.id])
        XCTAssertFalse(firstScreen.move("external-text", to: first.id))
        XCTAssertFalse(firstScreen.move(second.id, to: "deleted-target"))
        secondScreen.remove(second.id)
        XCTAssertFalse(firstScreen.move(second.id, to: first.id))
        XCTAssertEqual(store().groups.map(\.id), [third.id, first.id])
        LocalSnapshot.clearAll()
        XCTAssertFalse(firstScreen.move(third.id, to: first.id))
        XCTAssertEqual(store().groups.map(\.id), [third.id, first.id])
    }

    func testAcceptedIdentityMergesRemapGroupsWithoutTouchingFailedSourcesOrOrder() throws {
        let first = store()
        let stale = store()
        let group = try XCTUnwrap(first.save(name: "Family", personIDs: ["accepted", "failed", "target"], keyPhotoID: "cover"))
        let untouched = try XCTUnwrap(first.save(name: "Other", personIDs: ["failed", "other"], keyPhotoID: "other-cover"))
        first.setOrder([untouched.id, group.id])

        stale.remapMergedPeople(["accepted"], into: "target")

        let restored = store()
        XCTAssertEqual(restored.groups.map(\.id), [untouched.id, group.id])
        XCTAssertEqual(restored.group(group.id)?.name, "Family")
        XCTAssertEqual(restored.group(group.id)?.personIDs, ["target", "failed"])
        XCTAssertNil(restored.group(group.id)?.keyPhotoID)
        XCTAssertEqual(restored.group(untouched.id)?.personIDs, ["failed", "other"])
        XCTAssertEqual(restored.group(untouched.id)?.keyPhotoID, "other-cover")
        XCTAssertNil(first.save(id: group.id, name: "Stale edit", personIDs: group.personIDs, expectedPeople: group.personIDs),
            "An open editor cannot restore identities that were merged away")
    }

    func testMergedSingleIdentityGroupRemainsReachableAndExpiredRemappingCannotWrite() throws {
        let current = store()
        let group = try XCTUnwrap(current.save(name: "Saved group", personIDs: ["duplicate", "target"], keyPhotoID: "cover"))
        current.remapMergedPeople(["duplicate"], into: "target")
        let merged = try XCTUnwrap(store().group(group.id))
        XCTAssertEqual(merged.personIDs, ["target"])
        XCTAssertTrue(merged.isAvailable(in: [person("target", name: "Alex")]))
        XCTAssertNotNil(current.save(id: group.id, name: "Renamed", personIDs: ["target"], expectedPeople: ["target"]))
        LocalSnapshot.clearAll()

        current.remapMergedPeople(["target"], into: "other-account")

        XCTAssertEqual(store().group(group.id)?.personIDs, ["target"])
        XCTAssertEqual(store().group(group.id)?.name, "Renamed")
    }

    private func store(server: String = "https://synthetic.example/api", user: String = "user") -> PeopleGroupsStore {
        PeopleGroupsStore(owner: BackupQueueOwner(server: server, userID: user), defaults: defaults)
    }

    private func person(_ id: String, name: String = "", hidden: Bool = false) -> PersonDTO {
        PersonDTO(id: id, name: name, birthDate: nil, thumbnailPath: nil, isHidden: hidden)
    }
}
