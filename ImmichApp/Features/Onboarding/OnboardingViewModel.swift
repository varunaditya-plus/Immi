import Foundation
import Observation

@MainActor
@Observable
final class OnboardingViewModel {
    var serverText: String {
        didSet {
            guard normalized(serverText) != normalized(oldValue) else { return }
            session.cancelAuthentication()
            attemptID = UUID()
            clearValidation()
            showsSessionErrors = false
            phase = .idle
        }
    }
    var email = ""
    var password = ""
    var phase: LoadingPhase<Void> = .idle

    /// Kemampuan server, baru diketahui SETELAH alamatnya berhasil dihubungi.
    ///
    /// Dipakai untuk menyembunyikan tab yang tidak berlaku — mis. server
    /// OAuth-only yang mematikan login kata sandi.
    var features: ServerFeaturesDTO?
    var oauthButtonText = String(localized: "Sign In with OAuth")
    private(set) var validatedServerText: String?

    private let session: SessionManager
    private var attemptID = UUID()
    private var validatedContext: SessionRequestContext?
    private var showsSessionErrors = false

    init(session: SessionManager) {
        self.session = session
        serverText = UserDefaults.standard.string(forKey: Self.lastServerKey) ?? ""
        showsSessionErrors = true
    }

    /// Alamat server terakhir yang BERHASIL dipakai.
    ///
    /// Diisikan lagi saat percobaan login biasa dibuka ulang, tetapi ikut
    /// dibuang saat logout penuh bersama data akun lainnya.
    private static let lastServerKey = "onboarding.lastServer"

    static func clearStoredServer() {
        UserDefaults.standard.removeObject(forKey: lastServerKey)
    }

    var sessionErrorMessage: String? {
        guard showsSessionErrors else { return nil }
        return session.compatibilityIssue?.localizedDescription ?? session.authenticationError
    }

    var canConnect: Bool {
        !normalized(serverText).isEmpty
    }

    var canSubmit: Bool {
        hasValidatedServer && features?.passwordLogin == true
            && !email.isEmpty && !password.isEmpty
    }

    var canSignInWithOIDC: Bool {
        hasValidatedServer && features?.oauth == true
    }

    /// Tahap pertama hanya menyentuh endpoint publik. Kredensial belum pernah
    /// dikirim ketika alamat salah, server tidak tersedia, atau versinya tidak
    /// kompatibel.
    @discardableResult
    func connectToServer() async -> Bool {
        guard canConnect else { return false }
        let server = normalized(serverText)
        let attempt = UUID()
        attemptID = attempt
        clearValidation()
        showsSessionErrors = false
        phase = .loading
        do {
            try session.setServer(server)
            let context = session.snapshot
            let compatibility = try await session.checkServerCompatibility()
            try checkConnection(attempt, server: server, context: context)
            guard compatibility.features.passwordLogin || compatibility.features.oauth else {
                throw ServerCompatibilityError.authenticationUnavailable
            }
            var configuredButtonText: String?
            if compatibility.features.oauth {
                configuredButtonText = (try? await session.serverConfig())?.oauthButtonText
                try checkConnection(attempt, server: server, context: context)
            }
            let trimmedButtonText = configuredButtonText?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            oauthButtonText = trimmedButtonText.flatMap { $0.isEmpty ? nil : $0 }
                ?? String(localized: "Sign In with OAuth")
            features = compatibility.features
            validatedServerText = server
            validatedContext = context
            phase = .loaded(())
            return true
        } catch {
            guard isCurrentAttempt(attempt, server: server) else { return false }
            clearValidation()
            phase = error is CancellationError ? .idle : .failed(message(for: error))
            return false
        }
    }

    /// Tahap kedua hanya mengirim kredensial ke server yang sudah lolos tahap
    /// koneksi. Kembali ke halaman server dan mengubah alamat membatalkan gate.
    @discardableResult
    func signIn() async -> Bool {
        guard canSubmit, let server = validatedServerText,
              let apiURL = validatedContext?.baseURL else { return false }
        let attempt = UUID()
        attemptID = attempt
        phase = .loading
        do {
            try await session.loginPassword(email: email, password: password)
            guard canPublishSignIn(attempt, server: server, apiURL: apiURL) else { return false }
            UserDefaults.standard.set(server, forKey: Self.lastServerKey)
            phase = .loaded(())
            return true
        } catch {
            guard canPublishSignIn(attempt, server: server, apiURL: apiURL) else { return false }
            phase = .failed(message(for: error))
            return false
        }
    }

    @discardableResult
    func signInWithOIDC() async -> Bool {
        guard canSignInWithOIDC, let server = validatedServerText,
              let apiURL = validatedContext?.baseURL else { return false }
        let attempt = UUID()
        attemptID = attempt
        phase = .loading
        do {
            try await session.loginOIDC()
            guard canPublishSignIn(attempt, server: server, apiURL: apiURL) else { return false }
            UserDefaults.standard.set(server, forKey: Self.lastServerKey)
            phase = .loaded(())
            return true
        } catch {
            guard canPublishSignIn(attempt, server: server, apiURL: apiURL) else { return false }
            if let apiError = error as? APIError, case .unauthorized = apiError {
                phase = .failed(String(localized: "Single sign-on was rejected by the server."))
            } else {
                phase = .failed(message(for: error))
            }
            return false
        }
    }

    func prepareToEditServer() {
        session.cancelAuthentication()
        attemptID = UUID()
        clearValidation()
        phase = .idle
    }

    private var hasValidatedServer: Bool {
        guard let validatedServerText, let validatedContext else { return false }
        return normalized(serverText) == validatedServerText
            && session.baseURL == validatedContext.baseURL
            && session.accountGeneration == validatedContext.accountGeneration
    }

    private func clearValidation() {
        validatedServerText = nil
        validatedContext = nil
        features = nil
        oauthButtonText = String(localized: "Sign In with OAuth")
    }

    private func isCurrentAttempt(_ attempt: UUID, server: String) -> Bool {
        attemptID == attempt && normalized(serverText) == server
    }

    private func checkConnection(
        _ attempt: UUID, server: String, context: SessionRequestContext
    ) throws {
        try Task.checkCancellation()
        guard isCurrentAttempt(attempt, server: server) else { throw CancellationError() }
        try session.checkCurrent(context)
    }

    private func canPublishSignIn(_ attempt: UUID, server: String, apiURL: URL) -> Bool {
        guard isCurrentAttempt(attempt, server: server) else { return false }
        guard session.baseURL == apiURL else {
            clearValidation()
            phase = .idle
            return false
        }
        return true
    }

    private func normalized(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Galat sambungan dan galat kredensial dibedakan: keduanya menuntut
    /// perbaikan di kolom yang berbeda.
    private func message(for error: Error) -> String {
        guard let apiError = error as? APIError else {
            return error.localizedDescription
        }
        switch apiError {
        case .unauthorized:
            return String(localized: "Wrong email or password.")
        case .notConnected:
            return String(localized: "No internet connection.")
        case .invalidURL:
            return String(localized: "That server address doesn't look right.")
        default:
            return apiError.errorDescription
                ?? String(localized: "Couldn't reach that server.")
        }
    }
}
