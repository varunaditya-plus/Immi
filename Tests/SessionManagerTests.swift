import Foundation
import XCTest
@testable import ImmichApp

@MainActor
final class SessionManagerTests: XCTestCase {
    func testLoginCannotSendCredentialsToAServerChangedDuringCleanup() async throws {
        for entry in CleanupLoginEntry.allCases {
            let fixture = try SessionFixture()
            defer { fixture.cleanup() }
            let replacement = SessionTestServer()
            defer { replacement.close() }
            let session = cleanupWaitingSession(fixture)
            fixture.server.respond(to: "/server/features", status: 200,
                json: #"{"passwordLogin":true,"oauth":true}"#)
            replacement.respond(to: "/server/features", status: 200,
                json: #"{"passwordLogin":true,"oauth":true}"#)
            try session.setServer(fixture.server.baseURL.absoluteString)
            try await session.checkServerCompatibility()
            let login = Task { try await entry.login(session) }
            defer { login.cancel(); session.finishCleanupWait() }
            await fulfillment(of: [session.cleanupStarted], timeout: 2)

            try session.setServer(replacement.baseURL.absoluteString)
            try await session.checkServerCompatibility()
            session.finishCleanupWait()

            do {
                try await login.value
                XCTFail("The \(entry) login must reject a changed destination")
            } catch is CancellationError {}
            for path in ["/auth/login", "/oauth/authorize", "/users/me"] {
                XCTAssertFalse(replacement.hasRequested(path), "Credentials cannot reach the replacement server")
                XCTAssertFalse(fixture.server.hasRequested(path))
            }
            XCTAssertFalse(session.isLoggedIn)
            XCTAssertNil(fixture.credentials.read("token"))
        }
    }

    func testCurrentLoginsContinueAfterCleanupWithoutChangingTheirDestination() async throws {
        for entry in CleanupLoginEntry.allCases {
            let fixture = try SessionFixture()
            defer { fixture.cleanup() }
            let session = cleanupWaitingSession(fixture)
            fixture.server.respond(to: "/server/features", status: 200,
                json: #"{"passwordLogin":true,"oauth":true}"#)
            fixture.server.respond(to: "/oauth/authorize", status: 401)
            try session.setServer(fixture.server.baseURL.absoluteString)
            try await session.checkServerCompatibility()
            let login = Task { try await entry.login(session) }
            defer { login.cancel(); session.finishCleanupWait() }
            await fulfillment(of: [session.cleanupStarted], timeout: 2)

            session.finishCleanupWait()

            if entry == .oidc {
                do {
                    try await login.value
                    XCTFail("The fixture rejects OAuth before opening a browser")
                } catch APIError.unauthorized {}
                XCTAssertTrue(fixture.server.hasRequested("/oauth/authorize"))
            } else {
                try await login.value
                XCTAssertTrue(session.isLoggedIn)
                XCTAssertEqual(session.currentUser?.id, fixture.server.userID)
                XCTAssertTrue(fixture.server.hasRequested("/users/me"))
                let expected = entry == .password ? "Bearer initial-token" : nil
                XCTAssertEqual(fixture.server.header("Authorization", for: "/users/me"), expected)
                if entry == .apiKey {
                    XCTAssertEqual(fixture.server.header("x-api-key", for: "/users/me"), "cleanup-test-key")
                }
            }
            XCTAssertEqual(session.baseURL, fixture.server.baseURL.appendingPathComponent("api"))
        }
    }

    func testCanceledLoginsDoNotSendCredentialsAfterCleanupFinishes() async throws {
        for entry in CleanupLoginEntry.allCases {
            let fixture = try SessionFixture()
            defer { fixture.cleanup() }
            let session = cleanupWaitingSession(fixture)
            fixture.server.respond(to: "/server/features", status: 200,
                json: #"{"passwordLogin":true,"oauth":true}"#)
            try session.setServer(fixture.server.baseURL.absoluteString)
            try await session.checkServerCompatibility()
            let login = Task { try await entry.login(session) }
            defer { login.cancel(); session.finishCleanupWait() }
            await fulfillment(of: [session.cleanupStarted], timeout: 2)

            login.cancel()
            session.finishCleanupWait()

            do {
                try await login.value
                XCTFail("A canceled \(entry) login must not continue after cleanup")
            } catch is CancellationError {}
            XCTAssertFalse(session.isLoggedIn)
            for path in ["/auth/login", "/oauth/authorize", "/users/me"] {
                XCTAssertFalse(fixture.server.hasRequested(path))
            }
        }
    }

    private func cleanupWaitingSession(_ fixture: SessionFixture) -> CleanupWaitingSession {
        CleanupWaitingSession(urlSession: fixture.urlSession, defaults: fixture.defaults,
            dataManager: fixture.dataManager, credentialStore: fixture.credentials,
            sharedSessionStore: fixture.sharedSessionStore, restoresSession: false)
    }

    func testLeavingOnboardingCancelsLoginBeforeCredentialsOrAccountPublication() async throws {
        for waitsForCleanup in [true, false] {
            for editsAddress in [true, false] {
                let fixture = try SessionFixture()
                defer { fixture.cleanup() }
                let waiting = waitsForCleanup ? cleanupWaitingSession(fixture) : nil
                let session: SessionManager = waiting ?? fixture.session
                let model = OnboardingViewModel(session: session)
                model.serverText = fixture.server.baseURL.absoluteString
                model.email = "person@example.com"
                model.password = "password"
                let connected = await model.connectToServer()
                XCTAssertTrue(connected)
                let started = waiting?.cleanupStarted ?? expectation(description: "The candidate profile is pending")
                if !waitsForCleanup { fixture.server.hold("/users/me", started: started) }
                let login = Task { await model.signIn() }
                defer {
                    login.cancel()
                    waiting?.finishCleanupWait()
                    fixture.server.release("/users/me", status: 200, json: fixture.server.profileJSON)
                }
                await fulfillment(of: [started], timeout: 2)

                if editsAddress { model.serverText = "https://another-server.example" }
                else { model.prepareToEditServer() }
                waiting?.finishCleanupWait()
                fixture.server.release("/users/me", status: 200, json: fixture.server.profileJSON)
                let accepted = await login.value

                XCTAssertFalse(accepted)
                XCTAssertFalse(session.isLoggedIn)
                XCTAssertNil(session.currentUser)
                XCTAssertNil(fixture.credentials.read("token"))
                XCTAssertNil(fixture.sharedSessionStore.load())
                if waitsForCleanup {
                    XCTAssertFalse(fixture.server.hasRequested("/auth/login"))
                }
            }
        }
    }

    func testCancelingOnboardingDoesNotInvalidateAnEstablishedSession() async throws {
        let fixture = try SessionFixture()
        defer { fixture.cleanup() }
        try await fixture.signIn()
        let context = fixture.session.snapshot
        let shared = try XCTUnwrap(fixture.sharedSessionStore.load())

        fixture.session.cancelAuthentication()

        XCTAssertTrue(fixture.session.isLoggedIn)
        XCTAssertEqual(fixture.session.snapshot, context)
        XCTAssertEqual(fixture.sharedSessionStore.credential(for: shared)?.authHeaders,
            fixture.session.authHeaders)
    }

    func testAuthenticated401ExpiresSessionAndRemovesCredentials() async throws {
        let fixture = try SessionFixture()
        defer { fixture.cleanup() }
        try await fixture.signIn()
        let client = APIClient(session: fixture.session, urlSession: fixture.urlSession)
        fixture.server.respond(to: "/test/private", status: 401)

        do {
            try await client.sendVoid(.init(path: "/test/private"))
            XCTFail("An authenticated 401 must fail the request")
        } catch APIError.unauthorized {
            // The same response must also invalidate the authenticated session.
        }

        XCTAssertFalse(fixture.session.isLoggedIn)
        XCTAssertTrue(fixture.session.authHeaders.isEmpty)
        XCTAssertNil(fixture.credentials.read("token"))
        XCTAssertNil(fixture.credentials.read("mode"))
        XCTAssertEqual(fixture.session.authenticationError, APIError.unauthorized.localizedDescription)
    }

    func testRawData401ExpiresAuthenticatedSession() async throws {
        let fixture = try SessionFixture()
        defer { fixture.cleanup() }
        try await fixture.signIn()
        let client = APIClient(session: fixture.session, urlSession: fixture.urlSession)
        fixture.server.respond(to: "/test/private", status: 401)

        do {
            _ = try await client.rawData(.init(path: "/test/private"))
            XCTFail("An authenticated image/data request must reject 401")
        } catch APIError.unauthorized {}

        XCTAssertFalse(fixture.session.isLoggedIn)
        XCTAssertTrue(fixture.session.authHeaders.isEmpty)
        XCTAssertNil(fixture.credentials.read("token"))
    }

    func testRawFile401ExpiresAuthenticatedSession() async throws {
        let fixture = try SessionFixture()
        defer { fixture.cleanup() }
        try await fixture.signIn()
        let client = APIClient(session: fixture.session, urlSession: fixture.urlSession)
        fixture.server.respond(to: "/test/private", status: 401)

        do {
            _ = try await client.rawFile(.init(path: "/test/private"))
            XCTFail("An authenticated download must reject 401")
        } catch APIError.unauthorized {}

        XCTAssertFalse(fixture.session.isLoggedIn)
        XCTAssertTrue(fixture.session.authHeaders.isEmpty)
        XCTAssertNil(fixture.credentials.read("token"))
    }

    func testStream401ExpiresAuthenticatedSession() async throws {
        let fixture = try SessionFixture()
        defer { fixture.cleanup() }
        try await fixture.signIn()
        let client = APIClient(session: fixture.session, urlSession: fixture.urlSession)
        fixture.server.respond(to: "/sync/stream", status: 401)

        do {
            _ = try await client.streamLines(.init(path: "/sync/stream", method: .post))
            XCTFail("An authenticated stream request must reject 401")
        } catch APIError.unauthorized {}

        XCTAssertFalse(fixture.session.isLoggedIn)
        XCTAssertTrue(fixture.session.authHeaders.isEmpty)
        XCTAssertNil(fixture.credentials.read("token"))
    }

    func testSameAccountReauthenticationPreservesOfflineData() async throws {
        let fixture = try SessionFixture()
        defer { fixture.cleanup() }
        try await fixture.signIn()
        try fixture.seedAccountData()
        let generation = fixture.session.accountGeneration
        let owner = fixture.session.accountOwner
        await fixture.expireSession()

        fixture.server.token = "renewed-token"
        try await fixture.session.loginPassword(email: "person@example.com", password: "password")

        XCTAssertTrue(fixture.session.isLoggedIn)
        XCTAssertEqual(fixture.session.accountOwner, owner)
        XCTAssertEqual(fixture.session.accountGeneration, generation)
        XCTAssertEqual(fixture.session.authHeaders["Authorization"], "Bearer renewed-token")
        XCTAssertEqual(fixture.credentials.read("token"), "renewed-token")
        fixture.assertAccountDataExists()
    }

    func testDifferentUserClearsPreviousAccountDataBeforeLoginCompletes() async throws {
        let fixture = try SessionFixture()
        defer { fixture.cleanup() }
        try await fixture.signIn()
        try fixture.seedAccountData()
        let generation = fixture.session.accountGeneration
        await fixture.expireSession()

        fixture.server.userID = "another-user"
        fixture.server.token = "another-token"
        try await fixture.session.loginPassword(email: "another@example.com", password: "password")

        XCTAssertTrue(fixture.session.isLoggedIn)
        XCTAssertEqual(fixture.session.currentUser?.id, "another-user")
        XCTAssertEqual(fixture.session.accountOwner?.userID, "another-user")
        XCTAssertNotEqual(fixture.session.accountGeneration, generation)
        fixture.assertAccountDataIsEmpty()
    }

    func testAPIKeyLoginClearsDifferentAccountAndUsesCandidateKey() async throws {
        let fixture = try SessionFixture()
        defer { fixture.cleanup() }
        try await fixture.signIn()
        try fixture.seedAccountData()
        await fixture.expireSession()
        fixture.server.userID = "api-key-user"

        try await fixture.session.loginApiKey("candidate-api-key")

        XCTAssertTrue(fixture.session.isLoggedIn)
        XCTAssertEqual(fixture.session.currentUser?.id, "api-key-user")
        XCTAssertEqual(fixture.server.header("x-api-key", for: "/users/me"), "candidate-api-key")
        XCTAssertEqual(fixture.session.authHeaders, ["x-api-key": "candidate-api-key"])
        XCTAssertEqual(fixture.credentials.read("token"), "candidate-api-key")
        XCTAssertEqual(fixture.credentials.read("mode"), "apiKey")
        fixture.assertAccountDataIsEmpty()
    }

    func testSameAccountReauthenticationAfterRelaunchPreservesOfflineData() async throws {
        let fixture = try SessionFixture()
        defer { fixture.cleanup() }
        try await fixture.signIn()
        try fixture.seedAccountData()
        let owner = fixture.session.accountOwner
        await fixture.expireSession()
        let restored = fixture.makeSession(restoresSession: true)

        try await restored.checkServerCompatibility()
        fixture.server.token = "renewed-token"
        try await restored.loginPassword(email: "person@example.com", password: "password")

        XCTAssertTrue(restored.isLoggedIn)
        XCTAssertEqual(restored.accountOwner, owner)
        fixture.assertAccountDataExists()
    }

    func testDifferentServerClearsDataEvenWhenUserIDMatchesAfterRelaunch() async throws {
        let fixture = try SessionFixture()
        defer { fixture.cleanup() }
        try await fixture.signIn()
        try fixture.seedAccountData()
        await fixture.expireSession()

        // Expiry removes the token. The next process still needs the previous
        // owner to decide whether these cached assets belong to the next login.
        let restored = fixture.makeSession(restoresSession: true)
        XCTAssertFalse(restored.isLoggedIn)
        let otherServer = SessionTestServer()
        defer { otherServer.close() }
        otherServer.userID = fixture.server.userID
        try restored.setServer(otherServer.baseURL.absoluteString)
        try await restored.checkServerCompatibility()
        try await restored.loginPassword(email: "person@example.com", password: "password")

        XCTAssertEqual(restored.currentUser?.id, fixture.server.userID)
        XCTAssertEqual(restored.accountOwner?.server, otherServer.baseURL.appendingPathComponent("api").absoluteString)
        fixture.assertAccountDataIsEmpty()
    }

    func testProfileFailureDoesNotPublishCandidateCredentials() async throws {
        let fixture = try SessionFixture()
        defer { fixture.cleanup() }
        try fixture.session.setServer(fixture.server.baseURL.absoluteString)
        try await fixture.session.checkServerCompatibility()
        let started = expectation(description: "Candidate profile request started")
        fixture.server.hold("/users/me", started: started)
        let login = Task {
            try await fixture.session.loginPassword(email: "person@example.com", password: "password")
        }
        await fulfillment(of: [started], timeout: 3)

        XCTAssertFalse(fixture.session.isLoggedIn)
        XCTAssertNil(fixture.session.currentUser)
        XCTAssertTrue(fixture.session.authHeaders.isEmpty)
        XCTAssertNil(fixture.credentials.read("token"))
        XCTAssertEqual(fixture.server.header("Authorization", for: "/users/me"), "Bearer initial-token")

        fixture.server.release("/users/me", status: 500)
        await assertFails(login)
        XCTAssertFalse(fixture.session.isLoggedIn)
        XCTAssertNil(fixture.session.currentUser)
        XCTAssertTrue(fixture.session.authHeaders.isEmpty)
        XCTAssertNil(fixture.credentials.read("token"))
        XCTAssertNil(fixture.session.accountOwner)
    }

    func testFailedLoginDoesNotReplaceExistingSession() async throws {
        let fixture = try SessionFixture()
        defer { fixture.cleanup() }
        try await fixture.signIn()
        try fixture.seedAccountData()
        let headers = fixture.session.authHeaders
        let owner = fixture.session.accountOwner
        fixture.server.respond(to: "/auth/login", status: 401)

        do {
            try await fixture.session.loginPassword(email: "wrong@example.com", password: "wrong")
            XCTFail("Invalid credentials must fail")
        } catch APIError.unauthorized {}

        XCTAssertTrue(fixture.session.isLoggedIn)
        XCTAssertEqual(fixture.session.authHeaders, headers)
        XCTAssertEqual(fixture.session.accountOwner, owner)
        XCTAssertEqual(fixture.credentials.read("token"), "initial-token")
        fixture.assertAccountDataExists()
    }

    func testStale401CannotExpireRenewedSessionForSameAccount() async throws {
        let fixture = try SessionFixture()
        defer { fixture.cleanup() }
        try await fixture.signIn()
        let client = APIClient(session: fixture.session, urlSession: fixture.urlSession)
        let started = expectation(description: "Old authenticated request started")
        fixture.server.hold("/test/held", started: started)
        let oldRequest = Task { try await client.sendVoid(.init(path: "/test/held")) }
        await fulfillment(of: [started], timeout: 3)
        await fixture.expireSession()
        fixture.server.token = "renewed-token"
        try await fixture.session.loginPassword(email: "person@example.com", password: "password")

        fixture.server.release("/test/held", status: 401)
        await assertFails(oldRequest)

        XCTAssertTrue(fixture.session.isLoggedIn)
        XCTAssertEqual(fixture.session.authHeaders["Authorization"], "Bearer renewed-token")
        XCTAssertEqual(fixture.credentials.read("token"), "renewed-token")
    }

    func testStale401FromAnotherSessionInstanceCannotDeleteRenewedToken() async throws {
        let fixture = try SessionFixture()
        defer { fixture.cleanup() }
        try await fixture.signIn()
        let sibling = fixture.makeSession(restoresSession: true)
        let client = APIClient(session: sibling, urlSession: fixture.urlSession)
        let started = expectation(description: "Sibling session request started")
        fixture.server.hold("/test/held", started: started)
        let oldRequest = Task { try await client.sendVoid(.init(path: "/test/held")) }
        await fulfillment(of: [started], timeout: 3)
        await fixture.expireSession()
        fixture.server.token = "renewed-token"
        try await fixture.session.loginPassword(email: "person@example.com", password: "password")

        fixture.server.release("/test/held", status: 401)
        await assertFails(oldRequest)

        XCTAssertTrue(fixture.session.isLoggedIn)
        XCTAssertEqual(fixture.session.authHeaders["Authorization"], "Bearer renewed-token")
        XCTAssertEqual(fixture.credentials.read("token"), "renewed-token")
        XCTAssertEqual(fixture.credentials.read("mode"), "bearer")
    }

    func testStale401FromDifferentAuthModeCannotDeleteCurrentCredentials() async throws {
        let fixture = try SessionFixture()
        defer { fixture.cleanup() }
        try await fixture.signIn()
        let sibling = fixture.makeSession(restoresSession: true)
        let client = APIClient(session: sibling, urlSession: fixture.urlSession)
        let started = expectation(description: "Old bearer request started")
        fixture.server.hold("/test/held", started: started)
        let oldRequest = Task { try await client.sendVoid(.init(path: "/test/held")) }
        await fulfillment(of: [started], timeout: 3)
        await fixture.expireSession()
        try await fixture.session.loginApiKey("initial-token")

        fixture.server.release("/test/held", status: 401)
        await assertFails(oldRequest)

        XCTAssertTrue(fixture.session.isLoggedIn)
        XCTAssertEqual(fixture.session.authHeaders, ["x-api-key": "initial-token"])
        XCTAssertEqual(fixture.credentials.read("token"), "initial-token")
        XCTAssertEqual(fixture.credentials.read("mode"), "apiKey")
    }

    func testStaleCompatibilityFailureCannotSignOutRenewedSession() async throws {
        for usesAPIKey in [false, true] {
            let fixture = try SessionFixture()
            defer { fixture.cleanup() }
            try await fixture.signIn()
            try fixture.seedAccountData()
            let background = fixture.makeSession(restoresSession: true)
            let generation = fixture.session.accountGeneration
            let started = expectation(description: "Background version request started")
            fixture.server.hold("/server/version", started: started)
            let restoration = Task { await background.restore() }
            await fulfillment(of: [started], timeout: 3)
            await fixture.expireSession()
            if usesAPIKey {
                // The token value stays the same; only its authentication mode changes.
                try await fixture.session.loginApiKey("initial-token")
            } else {
                fixture.server.token = "renewed-token"
                try await fixture.session.loginPassword(email: "person@example.com", password: "password")
            }

            fixture.server.release("/server/version", status: 200, json: #"{"major":4,"minor":0,"patch":0}"#)
            await restoration.value

            XCTAssertTrue(fixture.session.isLoggedIn)
            XCTAssertEqual(fixture.credentials.read("token"), usesAPIKey ? "initial-token" : "renewed-token")
            XCTAssertEqual(fixture.credentials.read("mode"), usesAPIKey ? "apiKey" : "bearer")
            XCTAssertEqual(fixture.session.accountGeneration, generation)
            XCTAssertNil(fixture.session.compatibilityIssue)
            fixture.assertAccountDataExists()
        }
    }

    func testCurrent401StillSignsOutAfterAnotherSessionRemovedTheStoredToken() async throws {
        let fixture = try SessionFixture()
        defer { fixture.cleanup() }
        try await fixture.signIn()
        let sibling = fixture.makeSession(restoresSession: true)
        await sibling.expireIfCurrent(sibling.snapshot)
        XCTAssertNil(fixture.credentials.read("token"))
        XCTAssertTrue(fixture.session.isLoggedIn)
        let client = APIClient(session: fixture.session, urlSession: fixture.urlSession)
        fixture.server.respond(to: "/test/private", status: 401)

        do {
            try await client.sendVoid(.init(path: "/test/private"))
            XCTFail("The primary session's rejected credential must expire")
        } catch APIError.unauthorized {}

        XCTAssertFalse(fixture.session.isLoggedIn)
        XCTAssertTrue(fixture.session.authHeaders.isEmpty)
        XCTAssertEqual(fixture.session.authenticationError, APIError.unauthorized.localizedDescription)
    }

    func testAccountCleanupFailureDoesNotPublishNewAccountOrLoseBackupMappings() async throws {
        let fixture = try SessionFixture()
        defer { fixture.cleanup() }
        try await fixture.signIn()
        try fixture.seedAccountData()
        await fixture.expireSession()
        let journalURL = fixture.directory.appendingPathComponent("backup.json")
        try FileManager.default.removeItem(at: journalURL)
        try FileManager.default.createDirectory(at: journalURL, withIntermediateDirectories: true)
        fixture.server.userID = "another-user"
        fixture.server.token = "another-token"

        await assertFails(Task {
            try await fixture.session.loginPassword(email: "another@example.com", password: "password")
        })

        XCTAssertFalse(fixture.session.isLoggedIn)
        XCTAssertTrue(fixture.session.authHeaders.isEmpty)
        XCTAssertNil(fixture.credentials.read("token"))
        XCTAssertNotEqual(fixture.session.currentUser?.id, "another-user")
        XCTAssertNotEqual(fixture.session.accountOwner?.userID, "another-user")
        XCTAssertEqual(fixture.dataManager.cachedAssetCount(), 1)
        XCTAssertEqual(fixture.dataManager.getBackupRecord(localIdentifier: "local-photo")?.assetId, "private-photo")
    }

    func testStaleSuccessCannotReturnDataFromPreviousAccount() async throws {
        let fixture = try SessionFixture()
        defer { fixture.cleanup() }
        try await fixture.signIn()
        let client = APIClient(session: fixture.session, urlSession: fixture.urlSession)
        let started = expectation(description: "Previous account request started")
        fixture.server.hold("/test/held", started: started)
        let oldRequest = Task { try await client.rawData(.init(path: "/test/held")) }
        await fulfillment(of: [started], timeout: 3)
        await fixture.expireSession()
        fixture.server.userID = "another-user"
        fixture.server.token = "another-token"
        try await fixture.session.loginPassword(email: "another@example.com", password: "password")

        fixture.server.release("/test/held", status: 200, json: #"{"private":"previous-account"}"#)
        await assertFails(oldRequest)
        XCTAssertTrue(fixture.session.isLoggedIn)
        XCTAssertEqual(fixture.session.currentUser?.id, "another-user")
    }

    func testStaleDownloadedFileCannotReturnPreviousAccountsMedia() async throws {
        let fixture = try SessionFixture()
        defer { fixture.cleanup() }
        try await fixture.signIn()
        let client = APIClient(session: fixture.session, urlSession: fixture.urlSession)
        let started = expectation(description: "Previous account download started")
        fixture.server.hold("/test/held-download", started: started)
        let oldDownload = Task { try await client.rawFile(.init(path: "/test/held-download")) }
        await fulfillment(of: [started], timeout: 3)
        await fixture.expireSession()
        fixture.server.userID = "another-user"
        fixture.server.token = "another-token"
        try await fixture.session.loginPassword(email: "another@example.com", password: "password")

        fixture.server.release("/test/held-download", status: 200, json: "previous-account-media")
        do {
            let download = try await oldDownload.value
            try? FileManager.default.removeItem(at: download.url)
            XCTFail("A successful old-account transfer must not publish a media file")
        } catch {
            XCTAssertTrue(error is CancellationError, "Unexpected error: \(error)")
        }
        XCTAssertTrue(fixture.session.isLoggedIn)
        XCTAssertEqual(fixture.session.currentUser?.id, "another-user")
        XCTAssertEqual(fixture.credentials.read("token"), "another-token")

        // Current-account downloads must remain usable after rejecting the old one.
        fixture.server.respond(to: "/test/current-download", status: 200, json: "current-account-media")
        let currentClient = APIClient(session: fixture.session, urlSession: fixture.urlSession)
        let currentDownload = try await currentClient.rawFile(.init(path: "/test/current-download"))
        defer { try? FileManager.default.removeItem(at: currentDownload.url) }
        XCTAssertEqual(try Data(contentsOf: currentDownload.url), Data("current-account-media".utf8))
        XCTAssertEqual(currentDownload.response.statusCode, 200)
        XCTAssertEqual(fixture.server.header("Authorization", for: "/test/current-download"), "Bearer another-token")
    }

    func testStaleLoginCannotReplaceLoginOnAnotherServer() async throws {
        let fixture = try SessionFixture()
        defer { fixture.cleanup() }
        try fixture.session.setServer(fixture.server.baseURL.absoluteString)
        try await fixture.session.checkServerCompatibility()
        let started = expectation(description: "Old candidate profile request started")
        fixture.server.hold("/users/me", started: started)
        let oldLogin = Task {
            try await fixture.session.loginPassword(email: "first@example.com", password: "password")
        }
        await fulfillment(of: [started], timeout: 3)
        let otherServer = SessionTestServer()
        defer { otherServer.close() }
        otherServer.userID = "new-server-user"
        otherServer.token = "new-server-token"
        try fixture.session.setServer(otherServer.baseURL.absoluteString)
        try await fixture.session.checkServerCompatibility()
        try await fixture.session.loginPassword(email: "second@example.com", password: "password")

        fixture.server.release("/users/me", status: 200, json: fixture.server.profileJSON)
        await assertFails(oldLogin)
        XCTAssertTrue(fixture.session.isLoggedIn)
        XCTAssertEqual(fixture.session.currentUser?.id, "new-server-user")
        XCTAssertEqual(fixture.credentials.read("token"), "new-server-token")
        XCTAssertEqual(fixture.session.baseURL?.host, otherServer.baseURL.host)
    }

    func testOfflineFailureKeepsAuthenticatedSession() async throws {
        let fixture = try SessionFixture()
        defer { fixture.cleanup() }
        try await fixture.signIn()
        let client = APIClient(session: fixture.session, urlSession: fixture.urlSession)
        fixture.server.fail("/test/private", with: URLError(.notConnectedToInternet))

        do {
            try await client.sendVoid(.init(path: "/test/private"))
            XCTFail("The offline request must fail")
        } catch APIError.notConnected {}

        XCTAssertTrue(fixture.session.isLoggedIn)
        XCTAssertEqual(fixture.credentials.read("token"), "initial-token")
    }

    func testUnauthenticated401DoesNotInvalidateAccountGeneration() async throws {
        let fixture = try SessionFixture()
        defer { fixture.cleanup() }
        try fixture.session.setServer(fixture.server.baseURL.absoluteString)
        let generation = fixture.session.accountGeneration
        let client = APIClient(session: fixture.session, urlSession: fixture.urlSession)
        fixture.server.respond(to: "/server/ping", status: 401)

        do {
            let _: ServerPingDTO = try await client.send(.init(path: "/server/ping"))
            XCTFail("The public request must fail")
        } catch APIError.unauthorized {}

        XCTAssertFalse(fixture.session.isLoggedIn)
        XCTAssertEqual(fixture.session.accountGeneration, generation)
        XCTAssertEqual(fixture.session.baseURL?.host, fixture.server.baseURL.host)
    }

    func testPublicEndpoint401DoesNotExpireAuthenticatedSession() async throws {
        let fixture = try SessionFixture()
        defer { fixture.cleanup() }
        try await fixture.signIn()
        fixture.server.respond(to: "/server/config", status: 401)

        do {
            _ = try await fixture.session.serverConfig()
            XCTFail("The rejected public request must fail")
        } catch APIError.unauthorized {}

        XCTAssertTrue(fixture.session.isLoggedIn)
        XCTAssertEqual(fixture.credentials.read("token"), "initial-token")
        XCTAssertNil(fixture.server.header("Authorization", for: "/server/config"))
    }

    func testPublic401DuringRestoreDoesNotExpireAuthenticatedSession() async throws {
        let fixture = try SessionFixture()
        defer { fixture.cleanup() }
        try await fixture.signIn()
        let restored = fixture.makeSession(restoresSession: true)
        fixture.server.respond(to: "/server/ping", status: 401)

        await restored.restore()

        XCTAssertTrue(restored.isLoggedIn)
        XCTAssertEqual(restored.authHeaders["Authorization"], "Bearer initial-token")
        XCTAssertEqual(fixture.credentials.read("token"), "initial-token")
        XCTAssertNil(fixture.server.header("Authorization", for: "/server/ping"))
    }

    func testRestoreCompatibilityFailureRemainsAvailableToOnboarding() async throws {
        let fixture = try SessionFixture()
        defer { fixture.cleanup() }
        try await fixture.signIn()
        fixture.server.respond(to: "/server/version", status: 200, json: #"{"major":4,"minor":0,"patch":0}"#)
        let restored = fixture.makeSession(restoresSession: true)
        let onboarding = OnboardingViewModel(session: restored)
        XCTAssertNil(onboarding.sessionErrorMessage)

        await restored.restore()

        XCTAssertFalse(restored.isLoggedIn)
        let error = ServerCompatibilityError.appTooOld(found: ServerVersionDTO(major: 4, minor: 0, patch: 0))
        XCTAssertEqual(restored.compatibilityIssue, error)
        XCTAssertEqual(onboarding.sessionErrorMessage, error.localizedDescription)
    }

    func testChangingServerSignsOutAndInvalidatesExistingRequests() async throws {
        let fixture = try SessionFixture()
        defer { fixture.cleanup() }
        try await fixture.signIn()
        let context = fixture.session.snapshot
        let owner = fixture.session.accountOwner
        let otherServer = SessionTestServer()
        defer { otherServer.close() }

        try fixture.session.setServer(otherServer.baseURL.absoluteString)

        XCTAssertFalse(fixture.session.isLoggedIn)
        XCTAssertTrue(fixture.session.authHeaders.isEmpty)
        XCTAssertNil(fixture.credentials.read("token"))
        XCTAssertNil(fixture.credentials.read("mode"))
        XCTAssertEqual(fixture.session.accountOwner, owner)
        XCTAssertThrowsError(try fixture.session.checkCurrent(context))
    }

    func testStoredOwnerMustMatchProfileAndServerBeforeRestoringLogin() async throws {
        let fixture = try SessionFixture()
        defer { fixture.cleanup() }
        try await fixture.signIn()
        XCTAssertTrue(fixture.makeSession(restoresSession: true).isLoggedIn)
        let server = try XCTUnwrap(fixture.session.baseURL).absoluteString
        for owner in [
            BackupQueueOwner(server: "https://unrelated.invalid/api", userID: "initial-user"),
            BackupQueueOwner(server: server, userID: "another-user"),
        ] {
            fixture.defaults.set(try JSONEncoder().encode(owner), forKey: "session.accountOwner")

            let restored = fixture.makeSession(restoresSession: true)

            XCTAssertFalse(restored.isLoggedIn)
            XCTAssertTrue(restored.authHeaders.isEmpty)
        }
    }

    func testLoginPublishesItsValidatedTokenWithoutReadingAnotherGlobalToken() async throws {
        let fixture = try SessionFixture()
        defer { fixture.cleanup() }
        try await fixture.signIn()
        let captured = try XCTUnwrap(fixture.sharedSessionStore.load())

        fixture.credentials.save("unrelated-global-token", for: "token")

        let credential = try XCTUnwrap(fixture.sharedSessionStore.credential(for: captured))
        XCTAssertEqual(credential.owner.userID, "initial-user")
        XCTAssertEqual(credential.apiURL, fixture.session.baseURL)
        XCTAssertEqual(credential.authHeaders, fixture.session.authHeaders)
        XCTAssertEqual(credential.authHeaders, ["Authorization": "Bearer initial-token"])
    }

    func testSharedCredentialExpiryRenewalAuthModeChangeAndLogoutFollowTheValidatedSession() async throws {
        let fixture = try SessionFixture()
        defer { fixture.cleanup() }
        try await fixture.signIn()
        let bearer = try XCTUnwrap(fixture.sharedSessionStore.load())
        await fixture.expireSession()
        XCTAssertNil(fixture.sharedSessionStore.credential(for: bearer))

        fixture.server.token = "renewed-token"
        try await fixture.session.loginPassword(email: "person@example.com", password: "password")

        XCTAssertEqual(fixture.sharedSessionStore.load(), bearer)
        XCTAssertEqual(fixture.sharedSessionStore.credential(for: bearer)?.authHeaders,
            ["Authorization": "Bearer renewed-token"])
        await fixture.expireSession()
        try await fixture.session.loginApiKey("candidate-api-key")
        XCTAssertNil(fixture.sharedSessionStore.credential(for: bearer))
        let keySession = try XCTUnwrap(fixture.sharedSessionStore.load())
        XCTAssertEqual(keySession.authMode, "apiKey")
        XCTAssertEqual(fixture.sharedSessionStore.credential(for: keySession)?.authHeaders,
            ["x-api-key": "candidate-api-key"])

        await fixture.session.logout()

        XCTAssertNil(fixture.sharedSessionStore.load())
        XCTAssertNil(fixture.sharedSessionStore.credential(for: keySession))
    }

    func testChangingServerClearsThePublishedSharedCredential() async throws {
        let fixture = try SessionFixture()
        defer { fixture.cleanup() }
        try await fixture.signIn()
        let captured = try XCTUnwrap(fixture.sharedSessionStore.load())

        try fixture.session.setServer("https://another-share.example")

        XCTAssertNil(fixture.sharedSessionStore.load())
        XCTAssertNil(fixture.sharedSessionStore.credential(for: captured))
    }

    func testLateRestoredProfileCannotReplaceRenewedSharedCredentials() async throws {
        let fixture = try SessionFixture()
        defer { fixture.cleanup() }
        try await fixture.signIn()
        let captured = try XCTUnwrap(fixture.sharedSessionStore.load())
        let restored = fixture.makeSession(restoresSession: true)
        let started = expectation(description: "Older restored session is awaiting its profile")
        fixture.server.hold("/users/me", started: started)
        let restoration = Task { await restored.restore(configureBackup: false) }
        await fulfillment(of: [started], timeout: 2)
        XCTAssertEqual(fixture.server.header("Authorization", for: "/users/me"), "Bearer initial-token")
        fixture.server.respond(to: "/users/me", status: 200, json: fixture.server.profileJSON)
        await fixture.expireSession()
        fixture.server.token = "renewed-token"
        try await fixture.session.loginPassword(email: "person@example.com", password: "password")
        XCTAssertEqual(fixture.sharedSessionStore.credential(for: captured)?.authHeaders,
            ["Authorization": "Bearer renewed-token"])

        fixture.server.release("/users/me", status: 200, json: fixture.server.profileJSON)
        await restoration.value

        XCTAssertEqual(restored.authHeaders, ["Authorization": "Bearer initial-token"],
            "The older instance still carries its original credentials")
        XCTAssertEqual(fixture.credentials.read("token"), "renewed-token")
        XCTAssertEqual(fixture.sharedSessionStore.credential(for: captured)?.authHeaders,
            ["Authorization": "Bearer renewed-token"])
    }

    func testLegacyRestoreWaitsForTheServerToConfirmTheCredentialOwner() async throws {
        let fixture = try SessionFixture()
        defer { fixture.cleanup() }
        try await fixture.signIn()
        fixture.sharedSessionStore.clear()
        let restored = fixture.makeSession(restoresSession: true)
        XCTAssertTrue(restored.isLoggedIn)
        XCTAssertNil(fixture.sharedSessionStore.load(), "Cached identity cannot verify a legacy token's owner")

        await restored.restore(configureBackup: false)

        let snapshot = try XCTUnwrap(fixture.sharedSessionStore.load())
        XCTAssertEqual(snapshot.userID, "initial-user")
        XCTAssertEqual(fixture.sharedSessionStore.credential(for: snapshot)?.authHeaders, restored.authHeaders)
    }

    func testLegacyRestoreCannotPublishATokenForAnotherCachedOwner() async throws {
        let fixture = try SessionFixture()
        defer { fixture.cleanup() }
        try await fixture.signIn()
        fixture.sharedSessionStore.clear()
        fixture.credentials.save("other-user-token", for: "token")
        fixture.server.userID = "other-user"
        let restored = fixture.makeSession(restoresSession: true)
        XCTAssertNil(fixture.sharedSessionStore.load())

        await restored.restore(configureBackup: false)

        XCTAssertFalse(restored.isLoggedIn)
        XCTAssertNil(fixture.sharedSessionStore.load())
    }

    private func assertFails<T>(_ task: Task<T, Error>, file: StaticString = #filePath, line: UInt = #line) async {
        do {
            _ = try await task.value
            XCTFail("A stale or rejected request must not succeed", file: file, line: line)
        } catch {}
    }
}

@MainActor
private final class SessionFixture {
    let directory: URL
    let defaultsName = "SessionManagerTests.\(UUID().uuidString)"
    let defaults: UserDefaults
    let credentials = MemorySessionCredentials()
    let sharedCredentials = SharedSessionTestStorage()
    lazy var sharedSessionStore = sharedCredentials.store()
    let dataManager: SwiftDataManager
    let server = SessionTestServer()
    let urlSession: URLSession
    let snapshotKey = "session-test-\(UUID().uuidString)"
    lazy var session = makeSession(restoresSession: false)

    init() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("session-tests-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defaults = try XCTUnwrap(UserDefaults(suiteName: defaultsName))
        dataManager = SwiftDataManager(
            storeURL: directory.appendingPathComponent("test.store"),
            backupJournalURL: directory.appendingPathComponent("backup.json"))
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [SessionTestURLProtocol.self]
        urlSession = URLSession(configuration: configuration)
    }

    func makeSession(restoresSession: Bool) -> SessionManager {
        SessionManager(
            urlSession: urlSession,
            defaults: defaults,
            dataManager: dataManager,
            credentialStore: credentials,
            sharedSessionStore: sharedSessionStore,
            restoresSession: restoresSession)
    }

    func signIn() async throws {
        try session.setServer(server.baseURL.absoluteString)
        try await session.checkServerCompatibility()
        try await session.loginPassword(email: "person@example.com", password: "password")
    }

    func expireSession() async {
        await session.expireIfCurrent(session.snapshot)
        XCTAssertFalse(session.isLoggedIn)
    }

    func seedAccountData() throws {
        try dataManager.insertOrUpdateCachedAsset(CachedAsset(id: "private-photo", assetId: "private-photo", type: "IMAGE"))
        try dataManager.upsertBackupRecord(assetID: "private-photo", checksum: "private-checksum", localIdentifier: "local-photo")
        let syncState = dataManager.getSyncState()
        syncState.lastFullSyncAt = Date(timeIntervalSince1970: 1_700_000_000)
        try dataManager.updateSyncState(syncState)
        LocalSnapshot.save(["private-photo"], for: snapshotKey)
    }

    func assertAccountDataExists(file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(dataManager.cachedAssetCount(), 1, file: file, line: line)
        XCTAssertEqual(dataManager.serverAssetIDsByLocalIdentifier(), ["local-photo": "private-photo"], file: file, line: line)
        XCTAssertNotNil(dataManager.getSyncState().lastFullSyncAt, file: file, line: line)
        XCTAssertEqual(LocalSnapshot.load([String].self, for: snapshotKey), ["private-photo"], file: file, line: line)
    }

    func assertAccountDataIsEmpty(file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(dataManager.cachedAssetCount(), 0, file: file, line: line)
        XCTAssertTrue(dataManager.uploadedLocalIdentifiers().isEmpty, file: file, line: line)
        XCTAssertNil(dataManager.getSyncState().lastFullSyncAt, file: file, line: line)
        XCTAssertNil(LocalSnapshot.load([String].self, for: snapshotKey), file: file, line: line)
    }

    func cleanup() {
        urlSession.invalidateAndCancel()
        server.close()
        LocalSnapshot.remove(snapshotKey)
        defaults.removePersistentDomain(forName: defaultsName)
        try? FileManager.default.removeItem(at: directory)
    }
}

private final class MemorySessionCredentials: SessionCredentialStore {
    private var values: [String: String] = [:]
    func read(_ key: String) -> String? { values[key] }
    func save(_ value: String, for key: String) { values[key] = value }
    func delete(_ key: String) { values[key] = nil }
}

private final class SessionTestServer: @unchecked Sendable {
    enum Reply {
        case response(Int, String)
        case failure(Error)
        case held(XCTestExpectation)
    }

    let baseURL = URL(string: "https://session-\(UUID().uuidString.lowercased()).invalid")!
    private let lock = NSRecursiveLock()
    private var currentUserID = "initial-user"
    private var currentToken = "initial-token"
    var userID: String {
        get { lock.lock(); defer { lock.unlock() }; return currentUserID }
        set { lock.lock(); defer { lock.unlock() }; currentUserID = newValue }
    }
    var token: String {
        get { lock.lock(); defer { lock.unlock() }; return currentToken }
        set { lock.lock(); defer { lock.unlock() }; currentToken = newValue }
    }
    private var replies: [String: Reply] = [:]
    private var heldRequests: [String: SessionTestURLProtocol] = [:]
    private var requests: [String: URLRequest] = [:]

    init() { SessionTestURLProtocol.register(self) }

    var profileJSON: String { #"{"id":"\#(userID)","email":"person@example.com","name":"Person"}"# }

    func respond(to path: String, status: Int, json: String = "{}") { set(.response(status, json), for: path) }
    func fail(_ path: String, with error: Error) { set(.failure(error), for: path) }
    func hold(_ path: String, started: XCTestExpectation) { set(.held(started), for: path) }

    private func set(_ reply: Reply, for path: String) {
        lock.lock()
        replies["/api" + path] = reply
        lock.unlock()
    }

    func header(_ name: String, for path: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return requests["/api" + path]?.value(forHTTPHeaderField: name)
    }

    func hasRequested(_ path: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return requests["/api" + path] != nil
    }

    func release(_ path: String, status: Int, json: String = "{}") {
        lock.lock()
        let request = heldRequests.removeValue(forKey: "/api" + path)
        lock.unlock()
        request?.complete(status: status, json: json)
    }

    func receive(_ request: SessionTestURLProtocol) {
        let path = request.request.url!.path
        lock.lock()
        requests[path] = request.request
        let reply = replies[path] ?? defaultReply(for: path)
        if case .held = reply { heldRequests[path] = request }
        lock.unlock()
        switch reply {
        case let .response(status, json): request.complete(status: status, json: json)
        case let .failure(error): request.client?.urlProtocol(request, didFailWithError: error)
        case let .held(started): started.fulfill()
        }
    }

    private func defaultReply(for path: String) -> Reply {
        switch path {
        case "/api/server/ping": return .response(200, #"{"res":"pong"}"#)
        case "/api/server/version": return .response(200, #"{"major":3,"minor":1,"patch":0}"#)
        case "/api/server/features":
            return .response(200, #"{"passwordLogin":true,"oauth":false,"smartSearch":true,"facialRecognition":true,"search":true}"#)
        case "/api/auth/login":
            return .response(200, #"{"accessToken":"\#(token)","userId":"\#(userID)","userEmail":"person@example.com","name":"Person","isAdmin":false,"shouldChangePassword":false}"#)
        case "/api/users/me": return .response(200, profileJSON)
        case "/api/auth/validateToken", "/api/auth/logout": return .response(200, "{}")
        default: return .response(404, "{}")
        }
    }

    func close() {
        SessionTestURLProtocol.unregister(self)
        lock.lock()
        let pending = Array(heldRequests.values)
        heldRequests.removeAll()
        lock.unlock()
        pending.forEach { $0.client?.urlProtocol($0, didFailWithError: URLError(.cancelled)) }
    }
}

private final class SessionTestURLProtocol: URLProtocol {
    private static let lock = NSLock()
    private static var servers: [String: SessionTestServer] = [:]

    static func register(_ server: SessionTestServer) {
        lock.lock()
        servers[server.baseURL.host!] = server
        lock.unlock()
    }

    static func unregister(_ server: SessionTestServer) {
        lock.lock()
        servers[server.baseURL.host!] = nil
        lock.unlock()
    }

    private static func server(for request: URLRequest) -> SessionTestServer? {
        lock.lock()
        defer { lock.unlock() }
        return request.url?.host.flatMap { servers[$0] }
    }

    override class func canInit(with request: URLRequest) -> Bool { server(for: request) != nil }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() { Self.server(for: request)?.receive(self) }
    override func stopLoading() {}

    func complete(status: Int, json: String) {
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(json.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
}

@MainActor
private final class CleanupWaitingSession: SessionManager {
    let cleanupStarted = XCTestExpectation(description: "Login is waiting for account cleanup")
    private var continuation: CheckedContinuation<Void, Never>?

    override func waitForCleanup() async throws {
        await withCheckedContinuation {
            continuation = $0
            cleanupStarted.fulfill()
        }
    }

    func finishCleanupWait() {
        continuation?.resume()
        continuation = nil
    }
}

private enum CleanupLoginEntry: CaseIterable {
    case password, apiKey, oidc

    @MainActor
    func login(_ session: SessionManager) async throws {
        switch self {
        case .password: try await session.loginPassword(email: "person@example.com", password: "password")
        case .apiKey: try await session.loginApiKey("cleanup-test-key")
        case .oidc: try await session.loginOIDC()
        }
    }
}
