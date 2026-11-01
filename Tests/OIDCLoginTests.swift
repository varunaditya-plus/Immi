import AuthenticationServices
import CryptoKit
import XCTest
@testable import ImmichApp

final class OIDCLoginTests: XCTestCase {
    func testPKCEChallengeMatchesVerifier() throws {
        let request = try OIDCLoginRequest()
        let digest = Data(SHA256.hash(data: Data(request.codeVerifier.utf8)))
        let expected = digest.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        XCTAssertEqual(request.codeChallenge, expected)
        XCTAssertNotEqual(request.state, request.codeVerifier)
    }

    func testCallbackKeepsThreeSlashRedirectAndQuery() throws {
        let request = try OIDCLoginRequest()
        let callback = URL(string: "app.immich:/oauth-callback?code=abc&state=\(request.state)")!
        XCTAssertEqual(
            try request.callbackURL(callback),
            "app.immich:///oauth-callback?code=abc&state=\(request.state)")
    }

    func testRejectsWrongStateAndSchemeBeforeExchange() throws {
        let request = try OIDCLoginRequest()
        let wrongState = URL(string: "app.immich:///oauth-callback?code=abc&state=wrong")!
        XCTAssertThrowsError(try request.callbackURL(wrongState)) { error in
            guard case OIDCLoginError.stateMismatch = error else {
                return XCTFail("Expected state mismatch")
            }
        }
        let wrongScheme = URL(string: "selfphotos:///oauth-callback?code=abc&state=\(request.state)")!
        XCTAssertThrowsError(try request.callbackURL(wrongScheme))
    }
}

@MainActor
final class OIDCWebSessionTests: XCTestCase {
    private let authorizationURL = URL(string: "https://oidc.example/authorize")!
    private let callback = URL(string: "app.immich:///oauth-callback?code=current")!

    func testTaskAndExplicitCancellationDismissOnceAndIgnoreCallbacksFromTheCanceledAttempt() async throws {
        for cancelsTask in [true, false] {
            let fixture = OIDCWebSessionFixture()
            defer { fixture.browser.cancel() }
            let started = expectation(description: "The first browser started")
            fixture.nextStart = started
            let finished = expectation(description: "Canceled authentication returns without a browser callback")
            let pending = Task {
                defer { finished.fulfill() }
                return try await fixture.browser.authenticate(at: authorizationURL)
            }
            await fulfillment(of: [started], timeout: 2)
            let old = try XCTUnwrap(fixture.sessions.first)
            if cancelsTask { pending.cancel() }
            else { fixture.browser.cancel() }
            await fulfillment(of: [finished], timeout: 2)
            XCTAssertEqual(old.cancelCount, 1)
            fixture.browser.cancel()
            do {
                _ = try await pending.value
                XCTFail("Canceled authentication must not return a callback")
            } catch is CancellationError {}

            let restarted = expectation(description: "A new browser can start immediately")
            fixture.nextStart = restarted
            let next = Task { try await fixture.browser.authenticate(at: authorizationURL) }
            await fulfillment(of: [restarted], timeout: 2)
            let current = try XCTUnwrap(fixture.sessions.last)
            XCTAssertEqual(fixture.sessions.count, 2)
            old.complete(URL(string: "app.immich:///oauth-callback?code=obsolete"), error: nil)
            old.complete(nil, error: URLError(.cancelled))
            await Task.yield()
            current.complete(callback, error: nil)

            let accepted = try await next.value
            XCTAssertEqual(accepted, callback)
            XCTAssertEqual(current.cancelCount, 0,
                "A delayed cancellation must not dismiss the replacement browser")
        }
    }

    func testSynchronousCallbackDuringCancelCannotResumeTheContinuationTwice() async throws {
        let fixture = OIDCWebSessionFixture()
        defer { fixture.browser.cancel() }
        let started = expectation(description: "The browser started")
        fixture.nextStart = started
        let pending = Task { try await fixture.browser.authenticate(at: authorizationURL) }
        await fulfillment(of: [started], timeout: 2)
        let session = try XCTUnwrap(fixture.sessions.first)
        session.callsBackOnCancel = true

        fixture.browser.cancel()

        do {
            _ = try await pending.value
            XCTFail("App cancellation must win over the browser's cancellation callback")
        } catch is CancellationError {}
        await Task.yield()
        XCTAssertEqual(session.cancelCount, 1)
    }

    func testFailedStartAndUserCanceledBrowserLeaveTheNextAuthenticationAvailable() async throws {
        let fixture = OIDCWebSessionFixture()
        defer { fixture.browser.cancel() }
        fixture.startSucceeds = false
        do {
            _ = try await fixture.browser.authenticate(at: authorizationURL)
            XCTFail("A browser that cannot start must fail authentication")
        } catch OIDCLoginError.browserUnavailable {}
        fixture.startSucceeds = true
        let started = expectation(description: "Authentication restarts after a failed presentation")
        fixture.nextStart = started
        let pending = Task { try await fixture.browser.authenticate(at: authorizationURL) }
        await fulfillment(of: [started], timeout: 2)
        let current = try XCTUnwrap(fixture.sessions.last)
        current.complete(nil, error: URLError(.cancelled))
        do {
            _ = try await pending.value
            XCTFail("Browser cancellation must reach the waiting caller")
        } catch let error as URLError {
            XCTAssertEqual(error.code, .cancelled)
        }
        XCTAssertEqual(fixture.sessions.count, 2)
        XCTAssertEqual(current.cancelCount, 0)
        let restarted = expectation(description: "Authentication restarts after user cancellation")
        fixture.nextStart = restarted
        let next = Task { try await fixture.browser.authenticate(at: authorizationURL) }
        await fulfillment(of: [restarted], timeout: 2)
        try XCTUnwrap(fixture.sessions.last).complete(callback, error: nil)
        let accepted = try await next.value
        XCTAssertEqual(accepted, callback)
        XCTAssertEqual(fixture.sessions.count, 3)
    }

    func testAlreadyCanceledTaskDoesNotCreateOrPresentABrowser() async throws {
        let fixture = OIDCWebSessionFixture()
        defer { fixture.browser.cancel() }
        let pending = Task { try await fixture.browser.authenticate(at: authorizationURL) }
        pending.cancel()

        do {
            _ = try await pending.value
            XCTFail("Already canceled authentication must not present a browser")
        } catch is CancellationError {}
        XCTAssertTrue(fixture.sessions.isEmpty)
    }
}

@MainActor
final class OIDCWebSessionFixture {
    var sessions: [HeldOIDCAuthenticationSession] = []
    var nextStart: XCTestExpectation?
    var startSucceeds = true
    lazy var browser = OIDCWebSession { [unowned self] url, completion in
        let session = HeldOIDCAuthenticationSession(url: url, completion: completion)
        session.started = nextStart
        session.startSucceeds = startSucceeds
        sessions.append(session)
        return session
    }
}

final class HeldOIDCAuthenticationSession: ASWebAuthenticationSession {
    var started: XCTestExpectation?
    var startSucceeds = true
    var callsBackOnCancel = false
    private(set) var cancelCount = 0
    private let completion: ASWebAuthenticationSession.CompletionHandler

    init(url: URL, completion: @escaping ASWebAuthenticationSession.CompletionHandler) {
        self.completion = completion
        super.init(url: url, callback: .customScheme(OIDCLoginRequest.callbackScheme),
            completionHandler: completion)
    }

    override func start() -> Bool {
        started?.fulfill()
        return startSucceeds
    }

    override func cancel() {
        cancelCount += 1
        if callsBackOnCancel { completion(nil, URLError(.cancelled)) }
    }

    func complete(_ callback: URL?, error: Error?) { completion(callback, error) }
}
