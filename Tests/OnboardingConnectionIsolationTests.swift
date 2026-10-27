import XCTest
@testable import ImmichApp

@MainActor
final class OnboardingConnectionIsolationTests: XCTestCase {
    private var sessions: [HeldOnboardingSession] = []

    override func setUp() async throws {
        try await super.setUp()
        OnboardingViewModel.clearStoredServer()
    }

    override func tearDown() async throws {
        sessions.forEach { $0.cancelPendingResponses() }
        sessions.removeAll()
        OnboardingViewModel.clearStoredServer()
        try await super.tearDown()
    }

    func testEditingPendingAddressRejectsItsSuccessAndFailure() async throws {
        for succeeds in [true, false] {
            let (model, session) = fixture()
            let connection = Task { await model.connectToServer() }
            try await session.waitForRequest(0, kind: .compatibility, testCase: self)

            model.serverText = "https://edited.example.com"
            assertUnvalidated(model)
            if succeeds { try session.completeCompatibility(0, oauth: false) }
            else { try session.fail(0) }

            let connected = await connection.value
            XCTAssertFalse(connected)
            assertUnvalidated(model)
            let passwordSignIn = await model.signIn()
            let oauthSignIn = await model.signInWithOIDC()
            XCTAssertFalse(passwordSignIn)
            XCTAssertFalse(oauthSignIn)
            XCTAssertTrue(session.passwordServers.isEmpty)
            XCTAssertTrue(session.oauthServers.isEmpty)
        }
    }

    func testIncompatibleResponseAfterEditingCannotShowTheOldServerBanner() async throws {
        let (model, session) = fixture()
        session.usesRealCompatibilityCheck = true
        session.shouldSucceedPing = true
        let connection = Task { await model.connectToServer() }
        try await session.waitForRequest(0, kind: .version, testCase: self)

        model.serverText = "https://edited.example.com"
        try session.completeVersion(0, major: 1)
        let connected = await connection.value

        XCTAssertFalse(connected)
        XCTAssertNil(session.compatibilityIssue, "The abandoned check must not publish its incompatible report")
        XCTAssertNil(model.sessionErrorMessage)
        assertUnvalidated(model)
    }

    func testInitialSessionErrorsAreVisibleUntilTheAddressChanges() {
        let compatibilityError = ServerCompatibilityError.appTooOld(
            found: ServerVersionDTO(major: 4, minor: 0, patch: 0))
        for compatibility in [false, true] {
            let session = InitialMessageSession()
            session.initialCompatibilityIssue = compatibility ? compatibilityError : nil
            session.initialAuthenticationError = APIError.unauthorized.localizedDescription
            let model = OnboardingViewModel(session: session)
            let expected = compatibility ? compatibilityError.localizedDescription
                : APIError.unauthorized.localizedDescription

            XCTAssertEqual(model.sessionErrorMessage, expected)
            model.serverText = "https://edited.example.com"
            XCTAssertNil(model.sessionErrorMessage)
        }
    }

    func testNewConnectionClearsTheInitialSessionBannerBeforeItsResponse() async throws {
        UserDefaults.standard.set("https://original.example.com", forKey: "onboarding.lastServer")
        let session = InitialMessageSession()
        sessions.append(session)
        session.initialAuthenticationError = APIError.unauthorized.localizedDescription
        let model = OnboardingViewModel(session: session)
        XCTAssertEqual(model.serverText, "https://original.example.com")
        XCTAssertEqual(session.cancelAuthenticationCalls, 0,
                       "Restoring the saved address must not act like a user edit")
        XCTAssertNotNil(model.sessionErrorMessage)
        let connection = Task { await model.connectToServer() }
        try await session.waitForRequest(0, kind: .compatibility, testCase: self)
        XCTAssertNil(model.sessionErrorMessage)

        try session.completeCompatibility(0, oauth: false)
        let connected = await connection.value

        XCTAssertTrue(connected)
        XCTAssertNil(model.sessionErrorMessage)
        XCTAssertNotNil(session.authenticationError, "The model must not keep reading the old session error")
    }

    func testChangingAwayAndBackStillRejectsTheOriginalResponse() async throws {
        let (model, session) = fixture()
        let connection = Task { await model.connectToServer() }
        try await session.waitForRequest(0, kind: .compatibility, testCase: self)
        let original = model.serverText
        model.serverText = "https://edited.example.com"
        model.serverText = original
        try session.completeCompatibility(0, oauth: false)

        let connected = await connection.value
        XCTAssertFalse(connected)
        assertUnvalidated(model)

        try await connect(model, session: session, request: 1)
        XCTAssertTrue(model.canSubmit, "A fresh check of the same address must remain usable")
    }

    func testOlderSuccessCannotReplaceTheNewerFailureForTheSameAddress() async throws {
        let (model, session) = fixture()
        let old = Task { await model.connectToServer() }
        try await session.waitForRequest(0, kind: .compatibility, testCase: self)
        let fresh = Task { await model.connectToServer() }
        try await session.waitForRequest(1, kind: .compatibility, testCase: self)
        try session.fail(1)
        let freshConnected = await fresh.value
        XCTAssertFalse(freshConnected)
        let expectedError = model.phase.errorMessage
        XCTAssertNotNil(expectedError)

        try session.completeCompatibility(0, oauth: false)
        let oldConnected = await old.value
        XCTAssertFalse(oldConnected)
        XCTAssertEqual(model.phase.errorMessage, expectedError)
        XCTAssertNil(model.features)
        XCTAssertNil(model.validatedServerText)
        XCTAssertEqual(session.requests.count, 2)
    }

    func testOlderFailureCannotClearTheNewerValidatedConnection() async throws {
        let (model, session) = fixture()
        let old = Task { await model.connectToServer() }
        try await session.waitForRequest(0, kind: .compatibility, testCase: self)
        model.serverText = "https://new.example.com"
        try await connect(model, session: session, request: 1)

        try session.fail(0)
        let oldConnected = await old.value
        XCTAssertFalse(oldConnected)
        XCTAssertEqual(model.validatedServerText, "https://new.example.com")
        XCTAssertTrue(model.canSubmit)
        assertLoaded(model)
    }

    func testEditingWhileConfigIsPendingRejectsItsSuccessAndFailure() async throws {
        for succeeds in [true, false] {
            let (model, session) = fixture()
            let connection = Task { await model.connectToServer() }
            try await session.waitForRequest(0, kind: .compatibility, testCase: self)
            try session.completeCompatibility(0)
            try await session.waitForRequest(1, kind: .config, testCase: self)

            model.serverText = "https://edited.example.com"
            if succeeds { try session.completeConfig(1, button: "Stale SSO") }
            else { try session.fail(1) }
            let connected = await connection.value

            XCTAssertFalse(connected)
            assertUnvalidated(model)
            XCTAssertEqual(model.oauthButtonText, "Sign In with OAuth")
        }
    }

    func testOlderConfigCannotOverrideTheNewerConnectionForTheSameAddress() async throws {
        let (model, session) = fixture()
        let old = Task { await model.connectToServer() }
        try await session.waitForRequest(0, kind: .compatibility, testCase: self)
        try session.completeCompatibility(0)
        try await session.waitForRequest(1, kind: .config, testCase: self)
        let fresh = Task { await model.connectToServer() }
        try await session.waitForRequest(2, kind: .compatibility, testCase: self)
        try session.completeCompatibility(2)
        try await session.waitForRequest(3, kind: .config, testCase: self)
        try session.completeConfig(3, button: "Current SSO")
        let freshConnected = await fresh.value
        XCTAssertTrue(freshConnected)

        try session.completeConfig(1, button: "Stale SSO")
        let oldConnected = await old.value
        XCTAssertFalse(oldConnected)
        XCTAssertEqual(model.oauthButtonText, "Current SSO")
        XCTAssertTrue(model.canSignInWithOIDC)
        assertLoaded(model)
    }

    func testSessionAddressChangeDuringAResponseCannotValidateTheText() async throws {
        let (model, session) = fixture()
        let connection = Task { await model.connectToServer() }
        try await session.waitForRequest(0, kind: .compatibility, testCase: self)
        try session.setServer("https://other.example.com")
        try session.completeCompatibility(0, oauth: false)

        let connected = await connection.value
        XCTAssertFalse(connected)
        assertUnvalidated(model)
    }

    func testSessionAddressChangeAfterValidationBlocksBothSignInMethods() async throws {
        let (model, session) = fixture()
        try await connect(model, session: session, request: 0, oauth: true)
        XCTAssertTrue(model.canSubmit)
        XCTAssertTrue(model.canSignInWithOIDC)
        try session.setServer("https://other.example.com")

        XCTAssertFalse(model.canSubmit)
        XCTAssertFalse(model.canSignInWithOIDC)
        let passwordSignIn = await model.signIn()
        let oauthSignIn = await model.signInWithOIDC()
        XCTAssertFalse(passwordSignIn)
        XCTAssertFalse(oauthSignIn)
        XCTAssertTrue(session.passwordServers.isEmpty)
        XCTAssertTrue(session.oauthServers.isEmpty)
    }

    func testWhitespaceEditsAllowCurrentResponseAndPersistTheValidatedAddress() async throws {
        let (model, session) = fixture()
        let connection = Task { await model.connectToServer() }
        try await session.waitForRequest(0, kind: .compatibility, testCase: self)
        let cancellations = session.cancelAuthenticationCalls
        model.serverText = " \nhttps://original.example.com \n"
        XCTAssertEqual(session.cancelAuthenticationCalls, cancellations)
        try session.completeCompatibility(0, oauth: false)
        let connected = await connection.value
        XCTAssertTrue(connected)
        XCTAssertTrue(model.canSubmit)

        session.shouldSucceedLogin = true
        let signedIn = await model.signIn()
        XCTAssertTrue(signedIn)
        XCTAssertEqual(session.passwordServers, [URL(string: "https://original.example.com/api")!])
        XCTAssertEqual(UserDefaults.standard.string(forKey: "onboarding.lastServer"),
                       "https://original.example.com")
    }

    func testCancelledConnectionCannotValidateAndFreshRetryCanSucceed() async throws {
        let (model, session) = fixture()
        let cancelled = Task { await model.connectToServer() }
        try await session.waitForRequest(0, kind: .compatibility, testCase: self)
        cancelled.cancel()
        try session.completeCompatibility(0, oauth: false)
        let connected = await cancelled.value
        XCTAssertFalse(connected)
        assertUnvalidated(model)

        try await connect(model, session: session, request: 1)
        XCTAssertTrue(model.canSubmit)
    }

    func testRejectedCredentialsCanBeRetriedWithoutAnotherConnectionCheck() async throws {
        let (model, session) = fixture()
        try await connect(model, session: session, request: 0)
        let rejected = await model.signIn()
        XCTAssertFalse(rejected)
        XCTAssertNotNil(model.phase.errorMessage)
        XCTAssertTrue(model.canSubmit)

        session.shouldSucceedLogin = true
        let accepted = await model.signIn()
        XCTAssertTrue(accepted)
        XCTAssertEqual(session.requests.count, 1)
        XCTAssertEqual(session.passwordServers.count, 2)
        XCTAssertEqual(Set(session.passwordServers), [URL(string: "https://original.example.com/api")!])
    }

    func testBackAndAddressEditsCancelAuthenticationAndRejectLateLoginUIWrites() async throws {
        let (model, session) = fixture()
        try await connect(model, session: session, request: 0)
        session.holdsPasswordLogin = true
        session.shouldSucceedLogin = true
        let login = Task { await model.signIn() }
        try await session.waitForRequest(1, kind: .passwordLogin, testCase: self)
        let cancellations = session.cancelAuthenticationCalls

        model.prepareToEditServer()
        XCTAssertEqual(session.cancelAuthenticationCalls, cancellations + 1)
        model.serverText = "https://edited.example.com"
        XCTAssertEqual(session.cancelAuthenticationCalls, cancellations + 2)
        try session.completePasswordLogin(1)
        let signedIn = await login.value

        // The mock releases success despite cancellation to exercise the VM's
        // own late callback guard. Real SessionManager cancellation is tested
        // with a held transport response in SessionManagerTests.
        XCTAssertFalse(signedIn)
        assertUnvalidated(model)
        XCTAssertNil(UserDefaults.standard.string(forKey: "onboarding.lastServer"))
    }

    func testBackRejectsQueuedPasswordAndOAuthLoginsUntilAFreshConnection() async throws {
        for usesOAuth in [false, true] {
            OnboardingViewModel.clearStoredServer()
            let (model, session) = fixture()
            try await connect(model, session: session, request: 0, oauth: true)
            session.shouldSucceedLogin = true
            session.shouldSucceedOIDC = true
            var started = false
            let queued = Task { @MainActor in
                started = true
                return usesOAuth ? await model.signInWithOIDC() : await model.signIn()
            }

            // This actor has not yielded since queuing the login, so Back runs
            // before the login enters either model method.
            XCTAssertFalse(started)
            model.prepareToEditServer()
            assertUnvalidated(model)
            let signedIn = await queued.value

            XCTAssertTrue(started)
            XCTAssertFalse(signedIn)
            XCTAssertEqual(session.loginPasswordCallCount, 0)
            XCTAssertEqual(session.loginOIDCCallCount, 0)
            XCTAssertFalse(session.isLoggedIn)
            XCTAssertNil(UserDefaults.standard.string(forKey: "onboarding.lastServer"))

            try await connect(model, session: session, request: 2, oauth: true)
            let freshSignIn = usesOAuth ? await model.signInWithOIDC() : await model.signIn()
            XCTAssertTrue(freshSignIn)
            XCTAssertEqual(session.passwordServers.count, usesOAuth ? 0 : 1)
            XCTAssertEqual(session.oauthServers.count, usesOAuth ? 1 : 0)
            XCTAssertTrue(session.isLoggedIn)
            XCTAssertEqual(UserDefaults.standard.string(forKey: "onboarding.lastServer"),
                           "https://original.example.com")
        }
    }

    private func fixture() -> (OnboardingViewModel, HeldOnboardingSession) {
        let session = HeldOnboardingSession()
        sessions.append(session)
        let model = OnboardingViewModel(session: session)
        model.serverText = "https://original.example.com"
        model.email = "user@example.com"
        model.password = "password"
        return (model, session)
    }

    private func connect(
        _ model: OnboardingViewModel, session: HeldOnboardingSession,
        request: Int, oauth: Bool = false
    ) async throws {
        let connection = Task { await model.connectToServer() }
        try await session.waitForRequest(request, kind: .compatibility, testCase: self)
        try session.completeCompatibility(request, oauth: oauth)
        if oauth {
            try await session.waitForRequest(request + 1, kind: .config, testCase: self)
            try session.completeConfig(request + 1, button: "SSO")
        }
        let connected = await connection.value
        XCTAssertTrue(connected)
        assertLoaded(model)
    }

    private func assertUnvalidated(
        _ model: OnboardingViewModel, file: StaticString = #filePath, line: UInt = #line
    ) {
        XCTAssertNil(model.validatedServerText, file: file, line: line)
        XCTAssertNil(model.features, file: file, line: line)
        XCTAssertFalse(model.canSubmit, file: file, line: line)
        XCTAssertFalse(model.canSignInWithOIDC, file: file, line: line)
        if case .idle = model.phase {} else { XCTFail("Expected idle phase", file: file, line: line) }
    }

    private func assertLoaded(
        _ model: OnboardingViewModel, file: StaticString = #filePath, line: UInt = #line
    ) {
        if case .loaded = model.phase {} else { XCTFail("Expected loaded phase", file: file, line: line) }
    }
}

/// Deliberately ignores cancellation until the test releases a response.
@MainActor
private class HeldOnboardingSession: MockSessionManager {
    enum Kind: Equatable { case compatibility, config, version, passwordLogin }
    private enum Reply {
        case compatibility(ServerCompatibilityReport), config(ServerConfigDTO), version(ServerVersionDTO), passwordLogin
    }
    var usesRealCompatibilityCheck = false
    var holdsPasswordLogin = false
    private(set) var cancelAuthenticationCalls = 0
    private(set) var requests: [Kind] = []
    private(set) var passwordServers: [URL] = []
    private(set) var oauthServers: [URL] = []
    private var pending: [Int: CheckedContinuation<Reply, Error>] = [:]
    private var observers: [Int: XCTestExpectation] = [:]

    override func checkServerCompatibility() async throws -> ServerCompatibilityReport {
        if usesRealCompatibilityCheck { return try await super.checkServerCompatibility() }
        guard case .compatibility(let report) = try await response(for: .compatibility) else {
            throw APIError.unknown
        }
        return report
    }

    override func serverVersion() async throws -> ServerVersionDTO {
        guard case .version(let version) = try await response(for: .version) else { throw APIError.unknown }
        return version
    }

    override func serverConfig() async throws -> ServerConfigDTO {
        guard case .config(let config) = try await response(for: .config) else { throw APIError.unknown }
        return config
    }

    override func loginPassword(email: String, password: String) async throws {
        if let baseURL { passwordServers.append(baseURL) }
        // Real authentication advances the request revision before sending.
        if let baseURL { try setServer(baseURL.deletingLastPathComponent().absoluteString) }
        if holdsPasswordLogin {
            guard case .passwordLogin = try await response(for: .passwordLogin) else { throw APIError.unknown }
        }
        try await super.loginPassword(email: email, password: password)
    }

    override func cancelAuthentication() {
        cancelAuthenticationCalls += 1
        super.cancelAuthentication()
    }

    override func loginOIDC() async throws {
        if let baseURL { oauthServers.append(baseURL) }
        try await super.loginOIDC()
    }

    private func response(for kind: Kind) async throws -> Reply {
        let index = requests.count
        requests.append(kind)
        return try await withCheckedThrowingContinuation { continuation in
            pending[index] = continuation
            observers.removeValue(forKey: index)?.fulfill()
        }
    }

    func waitForRequest(_ index: Int, kind: Kind, testCase: XCTestCase) async throws {
        let observed = XCTestExpectation(description: "Onboarding request \(index) arrived")
        if requests.indices.contains(index) { observed.fulfill() }
        else { observers[index] = observed }
        await testCase.fulfillment(of: [observed], timeout: 2)
        let request = try XCTUnwrap(requests.indices.contains(index) ? requests[index] : nil)
        XCTAssertEqual(request, kind)
    }

    func completeCompatibility(_ index: Int, oauth: Bool = true) throws {
        let version = ServerVersionDTO(major: 3, minor: 0, patch: 0)
        let report = ServerCompatibilityReport(
            version: version,
            features: ServerFeaturesDTO(smartSearch: true, facialRecognition: true,
                                        oauth: oauth, passwordLogin: true, search: true),
            status: ServerCompatibilityPolicy.evaluate(version))
        try takeResponse(index).resume(returning: .compatibility(report))
    }

    func completeConfig(_ index: Int, button: String) throws {
        let config = try JSONDecoder().decode(ServerConfigDTO.self,
            from: JSONEncoder().encode(["oauthButtonText": button]))
        try takeResponse(index).resume(returning: .config(config))
    }

    func completeVersion(_ index: Int, major: Int) throws {
        try takeResponse(index).resume(returning: .version(ServerVersionDTO(major: major, minor: 0, patch: 0)))
    }

    func completePasswordLogin(_ index: Int) throws {
        try takeResponse(index).resume(returning: .passwordLogin)
    }

    func fail(_ index: Int) throws {
        try takeResponse(index).resume(throwing: APIError.server(status: 500, message: "Connection failed"))
    }

    private func takeResponse(_ index: Int) throws -> CheckedContinuation<Reply, Error> {
        try XCTUnwrap(pending.removeValue(forKey: index), "No pending response \(index)")
    }

    func cancelPendingResponses() {
        let responses = Array(pending.values)
        pending.removeAll()
        observers.removeAll()
        responses.forEach { $0.resume(throwing: CancellationError()) }
    }
}

@MainActor
private final class InitialMessageSession: HeldOnboardingSession {
    var initialCompatibilityIssue: ServerCompatibilityError?
    var initialAuthenticationError: String?

    override var compatibilityIssue: ServerCompatibilityError? { initialCompatibilityIssue }
    override var authenticationError: String? { initialAuthenticationError }
}
