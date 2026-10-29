struct LoginRequestDTO: Encodable {
    let email: String
    let password: String
}

struct OAuthAuthorizeRequestDTO: Encodable {
    let redirectUri: String
    let state: String
    let codeChallenge: String
}

struct OAuthAuthorizeResponseDTO: Decodable {
    let url: String
}

struct OAuthCallbackRequestDTO: Encodable {
    let url: String
    let state: String
    let codeVerifier: String
}

struct LoginResponseDTO: Decodable {
    let accessToken: String
    let userId: String
    let userEmail: String
    let name: String
    let isAdmin: Bool
    let shouldChangePassword: Bool
    /// Field wajib di OpenAPI v3, opsional di klien agar login ke server lama
    /// tidak rusak hanya karena metadata ini belum tersedia.
    let isOnboarded: Bool?
    let profileImagePath: String?
}
