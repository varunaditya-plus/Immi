import Foundation
import Observation

@MainActor
@Observable
final class OnboardingViewModel {
    var serverText = "" {
        didSet {
            guard let validatedServerText,
                  normalized(serverText) != validatedServerText
            else { return }
            self.validatedServerText = nil
            features = nil
            oauthButtonText = "Sign In with OAuth"
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
    var oauthButtonText = "Sign In with OAuth"
    private(set) var validatedServerText: String?

    private let session: SessionManager

    init(session: SessionManager) {
        self.session = session
        serverText = UserDefaults.standard.string(forKey: Self.lastServerKey) ?? ""
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
        session.compatibilityIssue?.localizedDescription ?? session.authenticationError
    }

    var canConnect: Bool {
        !normalized(serverText).isEmpty
    }

    var canSubmit: Bool {
        validatedServerText != nil && features?.passwordLogin == true
            && !email.isEmpty && !password.isEmpty
    }

    var canSignInWithOIDC: Bool {
        validatedServerText != nil && features?.oauth == true
    }

    /// Tahap pertama hanya menyentuh endpoint publik. Kredensial belum pernah
    /// dikirim ketika alamat salah, server tidak tersedia, atau versinya tidak
    /// kompatibel.
    @discardableResult
    func connectToServer() async -> Bool {
        guard canConnect else { return false }
        phase = .loading
        do {
            try session.setServer(serverText)
            let compatibility = try await session.checkServerCompatibility()
            guard compatibility.features.passwordLogin || compatibility.features.oauth else {
                throw ServerCompatibilityError.authenticationUnavailable
            }
            var configuredButtonText: String?
            if compatibility.features.oauth {
                configuredButtonText = (try? await session.serverConfig())?.oauthButtonText
            }
            let trimmedButtonText = configuredButtonText?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            oauthButtonText = trimmedButtonText.flatMap { $0.isEmpty ? nil : $0 }
                ?? "Sign In with OAuth"
            features = compatibility.features
            validatedServerText = normalized(serverText)
            phase = .loaded(())
            return true
        } catch {
            validatedServerText = nil
            features = nil
            oauthButtonText = "Sign In with OAuth"
            phase = .failed(message(for: error))
            return false
        }
    }

    /// Tahap kedua hanya mengirim kredensial ke server yang sudah lolos tahap
    /// koneksi. Kembali ke halaman server dan mengubah alamat membatalkan gate.
    @discardableResult
    func signIn() async -> Bool {
        guard canSubmit else { return false }
        phase = .loading
        do {
            guard features?.passwordLogin == true else {
                throw ServerCompatibilityError.passwordLoginUnavailable
            }
            try await session.loginPassword(email: email, password: password)

            UserDefaults.standard.set(serverText, forKey: Self.lastServerKey)
            phase = .loaded(())
            return true
        } catch {
            phase = .failed(message(for: error))
            return false
        }
    }

    @discardableResult
    func signInWithOIDC() async -> Bool {
        guard canSignInWithOIDC else { return false }
        phase = .loading
        do {
            try await session.loginOIDC()
            UserDefaults.standard.set(serverText, forKey: Self.lastServerKey)
            phase = .loaded(())
            return true
        } catch {
            if let apiError = error as? APIError, case .unauthorized = apiError {
                phase = .failed(String(localized: "Single sign-on was rejected by the server."))
            } else {
                phase = .failed(message(for: error))
            }
            return false
        }
    }

    func prepareToEditServer() {
        phase = .idle
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
