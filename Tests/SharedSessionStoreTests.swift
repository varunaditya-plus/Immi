import XCTest
@testable import ImmichApp

final class SharedSessionStoreTests: XCTestCase {
    private let server = URL(string: "https://share.example/api")!

    func testBoundCredentialRoundTripsAndRenewsForTheSameOwner() throws {
        let memory = SharedSessionTestStorage()
        let store = memory.store()
        XCTAssertTrue(store.save(apiURL: server, userID: "first", authMode: "bearer", token: "first-token"))
        let captured = try XCTUnwrap(store.load())
        XCTAssertEqual(captured.owner, SharedUploadOwner(server: server.absoluteString, userID: "first"))
        XCTAssertEqual(store.credential(for: captured)?.authHeaders, ["Authorization": "Bearer first-token"])

        XCTAssertTrue(store.save(apiURL: server, userID: "first", authMode: "bearer", token: "renewed-token"))

        XCTAssertEqual(store.load(), captured)
        XCTAssertEqual(store.credential(for: captured)?.authHeaders, ["Authorization": "Bearer renewed-token"])
        let stored = try XCTUnwrap(JSONSerialization.jsonObject(with: try XCTUnwrap(memory.data)) as? [String: Any])
        XCTAssertEqual(stored["token"] as? String, "renewed-token")
        let display = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(captured)) as? [String: Any])
        XCTAssertNil(display["token"], "The captured display snapshot must not carry credentials")
    }

    func testStaleOwnerServerAndAuthModeCannotUseTheReplacementToken() throws {
        for replacement in [
            SharedImmichSession(apiURL: server, userID: "second", authMode: "bearer"),
            SharedImmichSession(apiURL: URL(string: "https://other.example/api")!, userID: "first", authMode: "bearer"),
            SharedImmichSession(apiURL: server, userID: "first", authMode: "apiKey"),
        ] {
            let memory = SharedSessionTestStorage()
            let store = memory.store()
            XCTAssertTrue(store.save(apiURL: server, userID: "first", authMode: "bearer", token: "previous-token"))
            let captured = try XCTUnwrap(store.load())

            XCTAssertTrue(store.save(apiURL: replacement.apiURL, userID: replacement.userID,
                authMode: replacement.authMode, token: "replacement-token"))

            XCTAssertNil(store.credential(for: captured))
            XCTAssertEqual(store.load(), replacement)
            let current = try XCTUnwrap(store.credential(for: replacement))
            XCTAssertEqual(current.apiURL, replacement.apiURL)
            XCTAssertEqual(current.owner, replacement.owner)
            XCTAssertEqual(current.authHeaders, replacement.authMode == "apiKey"
                ? ["x-api-key": "replacement-token"] : ["Authorization": "Bearer replacement-token"])
        }
    }

    func testPublicationDuringCredentialLookupCannotMixTheOldOwnerWithTheNewToken() throws {
        let memory = SharedSessionTestStorage()
        let store = memory.store()
        XCTAssertTrue(store.save(apiURL: server, userID: "first", authMode: "bearer", token: "first-token"))
        let captured = try XCTUnwrap(store.load())
        memory.beforeRead = {
            XCTAssertTrue(store.save(apiURL: self.server, userID: "second", authMode: "apiKey", token: "second-key"))
        }

        XCTAssertNil(store.credential(for: captured))

        let current = try XCTUnwrap(store.load())
        XCTAssertEqual(current.userID, "second")
        XCTAssertEqual(store.credential(for: current)?.authHeaders, ["x-api-key": "second-key"])
    }

    func testReadersSeeCoherentCredentialsOnBothSidesOfPublication() throws {
        let memory = SharedSessionTestStorage()
        let store = memory.store()
        XCTAssertTrue(store.save(apiURL: server, userID: "first", authMode: "bearer", token: "first-token"))
        let previous = try XCTUnwrap(store.load())
        let replacement = SharedImmichSession(apiURL: server, userID: "second", authMode: "apiKey")
        memory.beforeWrite = {
            XCTAssertEqual(store.load(), previous)
            XCTAssertEqual(store.credential(for: previous)?.authHeaders, ["Authorization": "Bearer first-token"])
            XCTAssertNil(store.credential(for: replacement))
        }
        memory.afterWrite = {
            XCTAssertEqual(store.load(), replacement)
            XCTAssertNil(store.credential(for: previous))
            XCTAssertEqual(store.credential(for: replacement)?.authHeaders, ["x-api-key": "second-key"])
        }

        XCTAssertTrue(store.save(apiURL: server, userID: "second", authMode: "apiKey", token: "second-key"))
        XCTAssertEqual(memory.writes, 2, "Each publication must replace one complete record")
    }

    func testLogoutAndLogoutDuringLookupRejectTheCapturedSession() throws {
        for duringLookup in [false, true] {
            let memory = SharedSessionTestStorage()
            let store = memory.store()
            XCTAssertTrue(store.save(apiURL: server, userID: "first", authMode: "bearer", token: "first-token"))
            let captured = try XCTUnwrap(store.load())
            if duringLookup { memory.beforeRead = { store.clear() } }
            else { store.clear() }

            XCTAssertNil(store.credential(for: captured))
            XCTAssertNil(store.load())
            XCTAssertNil(memory.data)
        }
    }

    func testReadAndWriteFailuresDoNotExposeCredentials() throws {
        let memory = SharedSessionTestStorage()
        let store = memory.store()
        XCTAssertTrue(store.save(apiURL: server, userID: "first", authMode: "bearer", token: "first-token"))
        let captured = try XCTUnwrap(store.load())
        memory.failReads = true
        XCTAssertNil(store.load())
        XCTAssertNil(store.credential(for: captured))
        memory.failReads = false
        XCTAssertNotNil(store.credential(for: captured), "Restored access must still read a coherent record")
        memory.failWrites = true

        XCTAssertFalse(store.save(apiURL: server, userID: "second", authMode: "bearer", token: "second-token"))

        XCTAssertNil(memory.data, "A failed publication must retire the previous credential")
        XCTAssertNil(store.load())
        XCTAssertNil(store.credential(for: captured))
    }

    func testMalformedLegacyAndInvalidRecordsFailClosed() throws {
        let memory = SharedSessionTestStorage()
        let store = memory.store()
        XCTAssertTrue(store.save(apiURL: server, userID: "first", authMode: "bearer", token: "first-token"))
        let captured = try XCTUnwrap(store.load())
        let valid = try XCTUnwrap(memory.data)
        var malformed: [Data] = [Data("not JSON".utf8), try JSONEncoder().encode(captured)]
        for field in ["token", "userID", "authMode", "apiURL"] {
            var object = try XCTUnwrap(JSONSerialization.jsonObject(with: valid) as? [String: Any])
            if field == "token" { object[field] = "" }
            else {
                var session = try XCTUnwrap(object["session"] as? [String: Any])
                session[field] = field == "authMode" ? "unknown" : ""
                object["session"] = session
            }
            malformed.append(try JSONSerialization.data(withJSONObject: object))
        }
        for data in malformed {
            memory.data = data
            XCTAssertNil(store.load())
            XCTAssertNil(store.credential(for: captured))
        }
    }

    func testActualKeychainAddUpdateAndDeletionKeepTheWholeCredentialTogether() throws {
        let key = "shared-session-test-\(UUID().uuidString)"
        defer { SharedKeychainStore.delete(key) }
        // Signed Simulator tests use the same shared access group as the app
        // and extensions; no alternate storage path is used here.
        let store = SharedSessionStore(
            read: { SharedKeychainStore.readData(key) },
            write: { SharedKeychainStore.saveData($0, for: key) },
            remove: { SharedKeychainStore.delete(key) })
        XCTAssertNil(store.load())
        XCTAssertTrue(store.save(apiURL: server, userID: "first", authMode: "bearer", token: "first-token"))
        let captured = try XCTUnwrap(store.load())
        XCTAssertEqual(store.credential(for: captured)?.authHeaders, ["Authorization": "Bearer first-token"])

        XCTAssertTrue(store.save(apiURL: server, userID: "second", authMode: "apiKey", token: "second-key"))

        XCTAssertNil(store.credential(for: captured))
        let replacement = try XCTUnwrap(store.load())
        XCTAssertEqual(replacement.userID, "second")
        XCTAssertEqual(store.credential(for: replacement)?.authHeaders, ["x-api-key": "second-key"])
        store.clear()
        XCTAssertNil(SharedKeychainStore.readData(key))
        XCTAssertNil(store.credential(for: replacement))
    }
}

final class SharedSessionTestStorage {
    var data: Data?
    var failReads = false
    var failWrites = false
    var beforeRead: (() -> Void)?
    var beforeWrite: (() -> Void)?
    var afterWrite: (() -> Void)?
    private(set) var writes = 0

    func store() -> SharedSessionStore {
        SharedSessionStore(read: {
            let callback = self.beforeRead
            self.beforeRead = nil
            callback?()
            return self.failReads ? nil : self.data
        }, write: { data in
            self.beforeWrite?()
            guard !self.failWrites else { return false }
            self.writes += 1
            self.data = data
            self.afterWrite?()
            return true
        }, remove: { self.data = nil })
    }
}
