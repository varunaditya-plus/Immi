import AuthenticationServices
import CryptoKit
import Foundation
import Security
import UIKit

enum OIDCLoginError: LocalizedError {
    case randomGenerationFailed
    case invalidAuthorizationURL
    case invalidCallback
    case stateMismatch
    case browserUnavailable
    case serverChanged

    var errorDescription: String? {
        switch self {
        case .randomGenerationFailed:
            String(localized: "Could not start secure sign-in. Please try again.")
        case .invalidAuthorizationURL:
            String(localized: "The server returned an invalid sign-in URL.")
        case .invalidCallback:
            String(localized: "The sign-in provider did not return a valid callback.")
        case .stateMismatch:
            String(localized: "The sign-in response did not match this request. Please try again.")
        case .browserUnavailable:
            String(localized: "Could not open the sign-in browser.")
        case .serverChanged:
            String(localized: "The server changed during sign-in. Please connect and try again.")
        }
    }
}

struct OIDCLoginRequest {
    static let callbackScheme = "app.immich"
    static let redirectURI = "app.immich:///oauth-callback"

    let state: String
    let codeVerifier: String

    init() throws {
        state = try Self.randomString()
        codeVerifier = try Self.randomString()
    }

    var codeChallenge: String {
        Self.base64URL(Data(SHA256.hash(data: Data(codeVerifier.utf8))))
    }

    func callbackURL(_ url: URL) throws -> String {
        guard url.scheme?.lowercased() == Self.callbackScheme,
              url.host == nil,
              url.path == "/oauth-callback",
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        else { throw OIDCLoginError.invalidCallback }

        let returnedState = components.queryItems?.first(where: { $0.name == "state" })?.value
        guard returnedState == state else { throw OIDCLoginError.stateMismatch }
        guard components.queryItems?.contains(where: { $0.name == "code" && !($0.value ?? "").isEmpty }) == true
        else { throw OIDCLoginError.invalidCallback }

        // Foundation normalizes a hostless custom scheme to one slash. Immich
        // expects the same three-slash redirect URI used at authorization.
        let suffix = url.absoluteString.dropFirst("app.immich:".count)
        return Self.callbackScheme + ":///" + String(suffix.drop(while: { $0 == "/" }))
    }

    private static func randomString() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess
        else { throw OIDCLoginError.randomGenerationFailed }
        return base64URL(Data(bytes))
    }

    private static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

@MainActor
final class OIDCWebSession: NSObject, ASWebAuthenticationPresentationContextProviding {
    typealias SessionFactory = (URL, @escaping ASWebAuthenticationSession.CompletionHandler) -> ASWebAuthenticationSession

    private struct Authentication {
        let id: UUID
        let session: ASWebAuthenticationSession
        let continuation: CheckedContinuation<URL, Error>
    }

    private let makeSession: SessionFactory
    private var activeSession: Authentication?

    init(makeSession: SessionFactory? = nil) {
        self.makeSession = makeSession ?? { url, completion in
            ASWebAuthenticationSession(url: url,
                callback: .customScheme(OIDCLoginRequest.callbackScheme), completionHandler: completion)
        }
        super.init()
    }

    func authenticate(at url: URL) async throws -> URL {
        try Task.checkCancellation()
        guard ["https", "http"].contains(url.scheme?.lowercased() ?? "")
        else { throw OIDCLoginError.invalidAuthorizationURL }
        guard activeSession == nil else { throw OIDCLoginError.browserUnavailable }

        let attempt = UUID()
        let callback = try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                let session = makeSession(url) { [weak self] callback, error in
                    Task { @MainActor in
                        let result: Result<URL, Error>
                        if let error { result = .failure(error) }
                        else if let callback { result = .success(callback) }
                        else { result = .failure(OIDCLoginError.invalidCallback) }
                        self?.finish(attempt, result: result)
                    }
                }
                session.presentationContextProvider = self
                activeSession = Authentication(id: attempt, session: session, continuation: continuation)
                if !session.start() {
                    finish(attempt, result: .failure(OIDCLoginError.browserUnavailable))
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                guard self?.activeSession?.id == attempt else { return }
                self?.cancel()
            }
        }
        try Task.checkCancellation()
        return callback
    }

    func cancel() {
        guard let activeSession else { return }
        self.activeSession = nil
        activeSession.session.cancel()
        activeSession.continuation.resume(throwing: CancellationError())
    }

    private func finish(_ attempt: UUID, result: Result<URL, Error>) {
        guard let activeSession, activeSession.id == attempt else { return }
        self.activeSession = nil
        activeSession.continuation.resume(with: result)
    }

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        let windowScenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        if let keyWindow = windowScenes.flatMap(\.windows).first(where: \.isKeyWindow) {
            return keyWindow
        }

        guard let windowScene = windowScenes.first else {
            fatalError("A connected window scene is required to present the OIDC login session.")
        }
        return windowScene.windows.first ?? ASPresentationAnchor(windowScene: windowScene)
    }
}
