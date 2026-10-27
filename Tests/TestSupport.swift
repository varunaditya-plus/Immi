import Foundation
import XCTest
@testable import ImmichApp

/// Shared SessionManager mock used by APIClientTests and OnboardingViewModelTests.
/// Subclasses the real (non-final) SessionManager and overrides the network-touching
/// methods so no request ever leaves the process.
@MainActor
class MockSessionManager: SessionManager {
    /// When set, replaces the real auth headers (used to verify header attachment).
    var testAuthHeaders: [String: String]?

    var shouldSucceedPing = false
    var shouldSucceedLogin = false
    var shouldSucceedApiKey = false
    var shouldSucceedOIDC = false
    var mockVersion = ServerVersionDTO(major: 3, minor: 0, patch: 0)
    var mockFeatures: ServerFeaturesDTO? = ServerFeaturesDTO(
        smartSearch: true,
        facialRecognition: true,
        oauth: false,
        passwordLogin: true,
        search: true)
    var mockOAuthButtonText: String?
    var shouldFailServerConfig = false

    private(set) var pingCallCount = 0
    private(set) var versionCallCount = 0
    private(set) var featuresCallCount = 0
    private(set) var serverConfigCallCount = 0
    private(set) var loginPasswordCallCount = 0
    private(set) var loginApiKeyCallCount = 0
    private(set) var loginOIDCCallCount = 0

    /// Mulai dari keadaan keluar akun, apa pun isi keychain simulator.
    ///
    /// `SessionManager.init` memulihkan sesi tersimpan secara sinkron; tanpa ini
    /// sisa sesi dari kali terakhir aplikasi dijalankan bisa membuat test lulus
    /// atau gagal tanpa ada hubungannya dengan yang sedang diuji.
    init() {
        super.init(restoresSession: false)
    }

    override var authHeaders: [String: String] {
        testAuthHeaders ?? super.authHeaders
    }

    override func ping() async throws {
        pingCallCount += 1
        guard shouldSucceedPing else {
            throw APIError.server(status: 500, message: "ping failed")
        }
    }

    override func features() async throws -> ServerFeaturesDTO {
        featuresCallCount += 1
        guard let mockFeatures else { throw APIError.unknown }
        return mockFeatures
    }

    override func serverConfig() async throws -> ServerConfigDTO {
        serverConfigCallCount += 1
        guard !shouldFailServerConfig else { throw APIError.unknown }
        let object = ["oauthButtonText": mockOAuthButtonText ?? ""]
        return try JSONDecoder().decode(
            ServerConfigDTO.self,
            from: JSONEncoder().encode(object))
    }

    override func serverVersion() async throws -> ServerVersionDTO {
        versionCallCount += 1
        return mockVersion
    }

    override func loginPassword(email: String, password: String) async throws {
        loginPasswordCallCount += 1
        guard shouldSucceedLogin else { throw APIError.unauthorized }
        isLoggedIn = true
    }

    override func loginApiKey(_ key: String) async throws {
        loginApiKeyCallCount += 1
        guard shouldSucceedApiKey else { throw APIError.unauthorized }
        isLoggedIn = true
    }

    override func loginOIDC() async throws {
        loginOIDCCallCount += 1
        guard shouldSucceedOIDC else { throw APIError.unauthorized }
        isLoggedIn = true
    }
}

/// APIClient wired to a fresh SessionManager. Repository mocks override every
/// method that would touch this client, so it never performs a request.
@MainActor
func makeStubAPIClient() -> APIClient {
    APIClient(session: SessionManager())
}

/// Convenience factory for AssetResponseDTO (the memberwise init is verbose).
func makeTestAsset(
    id: String = "asset-123",
    type: String = "IMAGE",
    originalFileName: String = "photo.jpg",
    isFavorite: Bool = false,
    isArchived: Bool = false,
    isTrashed: Bool = false,
    duration: Double? = nil,
    thumbhash: String? = nil,
    exifInfo: ExifDTO? = nil,
    people: [PersonDTO]? = nil
) -> AssetResponseDTO {
    AssetResponseDTO(
        id: id,
        type: type,
        originalFileName: originalFileName,
        fileCreatedAt: Date(),
        isFavorite: isFavorite,
        isArchived: isArchived,
        isTrashed: isTrashed,
        duration: duration,
        thumbhash: thumbhash,
        localDateTime: Date(),
        exifInfo: exifInfo,
        people: people
    )
}
