import XCTest
@testable import ImmichApp

@MainActor
final class DeviceCopyDeletionTests: XCTestCase {
    func testManualRemovalVerifiesCopiesAndPreservesServerUploadRecords() async throws {
        let fixture = try FreeUpSpaceServiceTests.Fixture()
        defer { fixture.close() }

        let removed = try await DeviceCopyDeletion.perform(
            localIdentifiers: ["device:local-a", "local-a"], using: fixture.service())

        XCTAssertEqual(removed, 1)
        XCTAssertEqual(fixture.library.deletions, 1)
        XCTAssertEqual(fixture.api.downloads.count, 2, "Manual cleanup verifies both review and removal")
        XCTAssertNil(fixture.reopenStore().serverAssetIDsByLocalIdentifier()["local-a"])
        XCTAssertNotNil(fixture.reopenStore().getBackupRecord(deviceAssetId: "historical-a"))
        XCTAssertTrue(fixture.server.requests.allSatisfy { $0.httpMethod == "GET" })
    }

    func testUnverifiableSelectionCannotSilentlyDeleteTheVerifiedSubset() async throws {
        let fixture = try FreeUpSpaceServiceTests.Fixture(ids: ["a", "b"])
        defer { fixture.close() }
        fixture.server.reply("/assets/server-b/original", bytes: Data(), status: 404)

        do {
            _ = try await DeviceCopyDeletion.perform(
                localIdentifiers: ["local-a", "local-b"], using: fixture.service())
            XCTFail("The entire manual selection must be verified before removal")
        } catch DeviceCopySafetyError.copiesChanged { }

        XCTAssertEqual(fixture.library.deletions, 0)
        XCTAssertEqual(fixture.counter.value, 0)
        XCTAssertEqual(fixture.store.serverAssetIDsByLocalIdentifier().count, 2)
        XCTAssertEqual(fixture.api.downloads.count, 1, "The valid first copy was actually checked")
    }

    func testQueuedManualActionCannotAdoptTheNextAccount() async throws {
        let fixture = try FreeUpSpaceServiceTests.Fixture()
        defer { fixture.close() }
        let admittedService = fixture.service()
        let removal = Task {
            try await DeviceCopyDeletion.perform(localIdentifiers: ["local-a"], using: admittedService)
        }
        fixture.session.testOwner = BackupQueueOwner(server: fixture.session.baseURL!.absoluteString, userID: "next-user")

        do {
            _ = try await removal.value
            XCTFail("A queued action must retain its original account")
        } catch is CancellationError { }

        XCTAssertTrue(fixture.server.requests.isEmpty)
        XCTAssertTrue(fixture.library.requests.isEmpty)
        XCTAssertEqual(fixture.library.deletions, 0)
        XCTAssertEqual(fixture.store.serverAssetIDsByLocalIdentifier()["local-a"], "server-a")
    }
}
