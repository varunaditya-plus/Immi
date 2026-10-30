import SwiftUI
import UIKit
import Vision
import XCTest
@testable import ImmichApp

@MainActor
final class PinPromptFeedbackTests: SimulatorHostedTestCase {
    func testOnlyUnlockRejectionsBecomeIncorrectPINFeedback() async throws {
        MockURLProtocol.reset()
        defer { MockURLProtocol.reset() }
        let session = MockSessionManager()
        try session.setServer("https://pin-feedback.example")
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let repo = PinRepository(api: APIClient(session: session,
            urlSession: URLSession(configuration: configuration)))
        MockURLProtocol.mockData = Data(#"{"message":"Forbidden"}"#.utf8)
        MockURLProtocol.mockResponse = HTTPURLResponse(url: session.baseURL!,
            statusCode: 403, httpVersion: nil, headerFields: nil)

        do {
            try await repo.unlock(pin: "000000")
            XCTFail("Wrong PIN must fail")
        } catch PinUnlockError.incorrectPIN { }
        XCTAssertEqual(MockURLProtocol.lastRequest?.url?.path, "/api/auth/session/unlock")

        do {
            try await repo.createPin("1234")
            XCTFail("Rejected creation must fail")
        } catch APIError.server(let status, let message) {
            XCTAssertEqual(status, 403)
            XCTAssertEqual(message, "Forbidden")
        }
        XCTAssertEqual(MockURLProtocol.lastRequest?.url?.path, "/api/auth/pin-code")
    }

    func testRejectedPINRetainsReadableReasonUntilInputChangesAndRetryCanSucceed() async {
        var attempts = [String]()
        let model = PinPromptModel { pin in
            attempts.append(pin)
            if attempts.count == 1 { throw PinUnlockError.incorrectPIN }
        }
        model.updatePIN("000000")
        await model.submit()

        XCTAssertEqual(model.errorMessage, incorrectPINMessage)
        XCTAssertEqual(model.pin, "")
        XCTAssertFalse(model.isWorking)
        XCTAssertEqual(model.failureCount, 1)
        await model.submit()
        XCTAssertEqual(model.errorMessage, incorrectPINMessage, "An invalid empty submit must not erase feedback")
        XCTAssertEqual(attempts, ["000000"])

        model.updatePIN("12345")
        XCTAssertNil(model.errorMessage)
        await model.submit()
        XCTAssertEqual(attempts, ["000000", "12345"])
        XCTAssertNil(model.errorMessage)
        XCTAssertEqual(model.pin, "")
        XCTAssertFalse(model.isWorking)
    }

    func testServerAndNetworkFailuresAreNotPresentedAsIncorrectPIN() async {
        let cases: [(Error, String)] = [
            (APIError.connectionFailed(URLError(.cannotConnectToHost)), expected(
                "Couldn't reach that server.", "Impossible de joindre ce serveur.")),
            (APIError.connectionFailed(URLError(.timedOut)), expected(
                "The server took too long to respond. Try again.",
                "Le serveur a mis trop de temps à répondre. Réessayez.")),
            (APIError.server(status: 503, message: "PIN service temporarily unavailable"),
                "PIN service temporarily unavailable")
        ]
        for (error, expected) in cases {
            let model = PinPromptModel { _ in throw error }
            model.updatePIN("1234")
            await model.submit()
            XCTAssertEqual(model.errorMessage, expected)
            XCTAssertNotEqual(model.errorMessage, incorrectPINMessage)
            XCTAssertFalse(model.isWorking)
        }
    }

    func testCancellationDoesNotShakeOrDisplayAnError() async {
        for error in [CancellationError() as Error, URLError(.cancelled)] {
            let model = PinPromptModel { _ in throw error }
            model.updatePIN("1234")
            await model.submit()
            XCTAssertNil(model.errorMessage)
            XCTAssertEqual(model.failureCount, 0)
            XCTAssertFalse(model.isWorking)
        }
    }

    func testDismissedSubmissionCannotOverwriteInputOrFeedbackInANewPresentation() async {
        let gate = PinFeedbackGate(started: expectation(description: "Unlock started"))
        let model = PinPromptModel { _ in
            await gate.wait()
            throw PinUnlockError.incorrectPIN
        }
        model.updatePIN("000000")
        let old = Task { await model.submit() }
        await fulfillment(of: [gate.started], timeout: 2)
        model.deactivate()
        XCTAssertFalse(model.isWorking)
        model.activate()
        model.updatePIN("1234")
        gate.resume()
        await old.value

        XCTAssertEqual(model.pin, "1234")
        XCTAssertNil(model.errorMessage)
        XCTAssertEqual(model.failureCount, 0)
        XCTAssertFalse(model.isWorking)
    }

    func testWorkingSubmissionDisablesChangesAndDuplicateRequests() async {
        let gate = PinFeedbackGate(started: expectation(description: "Unlock started"))
        var attempts = [String]()
        let model = PinPromptModel { pin in
            attempts.append(pin)
            await gate.wait()
        }
        model.updatePIN("1234")
        let first = Task { await model.submit() }
        await fulfillment(of: [gate.started], timeout: 2)
        model.updatePIN("9999")
        await model.submit()
        XCTAssertEqual(model.pin, "1234")
        XCTAssertTrue(model.isWorking)
        XCTAssertEqual(attempts, ["1234"])
        gate.resume()
        await first.value
        XCTAssertFalse(model.isWorking)
        XCTAssertEqual(model.pin, "")
    }

    func testActualContinueSubmitsFourDigitsAndSixDigitInputAutomaticallySubmitsOnce() async throws {
        var attempts: [String] = []
        var allowsSubmission = false
        let prematureSubmission = expectation(description: "Four digits wait for Continue")
        prematureSubmission.isInverted = true
        let extraSubmission = expectation(description: "Successful six-digit entry does not submit twice")
        extraSubmission.isInverted = true
        let model = PinPromptModel { pin in
            if !allowsSubmission { prematureSubmission.fulfill() }
            attempts.append(pin)
            if attempts.count > 2 { extraSubmission.fulfill() }
            if pin == "0000" { throw PinUnlockError.incorrectPIN }
        }
        let window = try await host(PinPromptSheet(needsSetup: false, model: model))
        model.updatePIN("0000")

        await fulfillment(of: [prematureSubmission], timeout: 0.2)
        XCTAssertTrue(attempts.isEmpty)
        XCTAssertFalse(model.isWorking)
        allowsSubmission = true
        try await activateAccessibilityButton(named: "Continue", in: window)

        try await waitUntil("The actual Continue action reports a rejected four-digit PIN") {
            attempts == ["0000"] && model.errorMessage == self.incorrectPINMessage && !model.isWorking
        }
        XCTAssertEqual(model.pin, "")
        try await waitUntil("The rejection from Continue remains visible in the prompt") {
            (try? self.visibleText(in: window).contains(self.incorrectPINMessage)) == true
        }

        model.updatePIN("123456")

        try await waitUntil("Six digits submit through the prompt's input observer") {
            attempts == ["0000", "123456"] && model.pin.isEmpty && !model.isWorking
        }
        await fulfillment(of: [extraSubmission], timeout: 0.2)
        XCTAssertEqual(attempts, ["0000", "123456"])
        XCTAssertNil(model.errorMessage)
    }

    func testTheActualPromptRendersPersistentFailureText() async throws {
        let model = PinPromptModel { _ in throw PinUnlockError.incorrectPIN }
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first(where: { $0.activationState == .foregroundActive }))
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        let previous = scene.windows.first(where: \.isKeyWindow)
        let host = UIHostingController(rootView: PinPromptSheet(needsSetup: false, model: model)
            .environment(\.colorScheme, .light))
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previous?.makeKeyAndVisible()
        }
        host.view.frame = window.bounds
        host.view.layoutIfNeeded()
        model.updatePIN("000000")
        await model.submit()
        for _ in 0..<80 {
            if try visibleText(in: host.view).contains(incorrectPINMessage) { return }
            try await Task.sleep(for: .milliseconds(30))
        }
        XCTFail("The failed PIN reason was not rendered in the actual prompt: \(try visibleText(in: host.view))")
    }

    private func visibleText(in view: UIView) throws -> String {
        view.layoutIfNeeded()
        let image = UIGraphicsImageRenderer(bounds: view.bounds).image { _ in
            view.drawHierarchy(in: view.bounds, afterScreenUpdates: true)
        }
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["en-US", "fr-FR"]
        try VNImageRequestHandler(cgImage: XCTUnwrap(image.cgImage)).perform([request])
        return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: " ")
    }

    private var incorrectPINMessage: String {
        expected("Incorrect PIN. Try again.", "Code PIN incorrect. Réessayez.")
    }

    private func expected(_ english: String, _ french: String) -> String {
        Bundle.main.preferredLocalizations.first?.hasPrefix("fr") == true ? french : english
    }
}

@MainActor
private final class PinFeedbackGate {
    let started: XCTestExpectation
    private var continuation: CheckedContinuation<Void, Never>?

    init(started: XCTestExpectation) { self.started = started }
    func wait() async {
        await withCheckedContinuation {
            continuation = $0
            started.fulfill()
        }
    }
    func resume() {
        XCTAssertNotNil(continuation)
        continuation?.resume()
        continuation = nil
    }
}
