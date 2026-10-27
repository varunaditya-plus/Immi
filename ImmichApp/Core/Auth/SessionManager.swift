import Foundation
import Observation

@MainActor
@Observable
class SessionManager {
    enum AuthMode: String { case bearer, apiKey }

    private(set) var baseURL: URL?
    private(set) var currentUser: UserResponseDTO?
    private(set) var serverCompatibility: ServerCompatibilityReport?
    private(set) var compatibilityIssue: ServerCompatibilityError?
    var isLoggedIn: Bool = false
    private(set) var authenticationError: String?
    private(set) var accountOwner: BackupQueueOwner?
    // Shared with background SessionManager instances and cached screen models.
    var accountGeneration: UUID { LocalSnapshot.generation }
    private(set) var requestRevision = UUID()

    private let defaults: UserDefaults
    private let dataManager: SwiftDataManager
    private let credentialStore: any SessionCredentialStore
    private let urlSession: URLSession?
    private var cleanupTask: Task<Void, Error>?
    private var authenticationAttempt: UUID?

    private var serverInput: String?
    private var token: String?
    private var mode: AuthMode = .bearer

    private var hasCurrentCredentials: Bool {
        guard let token else { return false }
        return credentialStore.read("token") == token
            && credentialStore.read("mode") == mode.rawValue
    }

    var authHeaders: [String: String] {
        guard let token else { return [:] }
        return mode == .bearer ? ["Authorization": "Bearer \(token)"]
                               : ["x-api-key": token]
    }

    var backupQueueOwner: BackupQueueOwner? {
        guard let baseURL, let userID = currentUser?.id else { return nil }
        return BackupQueueOwner(server: baseURL.absoluteString, userID: userID)
    }

    var snapshot: SessionRequestContext {
        SessionRequestContext(
            baseURL: baseURL, authHeaders: authHeaders,
            revision: requestRevision, accountGeneration: accountGeneration,
            isAuthenticated: isLoggedIn)
    }

    private func invalidateRequests() {
        requestRevision = UUID()
    }

    @ObservationIgnored private var cachedImageAPI: APIClient?
    var imageAPI: APIClient {
        if let cachedImageAPI { return cachedImageAPI }
        let client = APIClient(session: self, urlSession: urlSession ?? URLSession(
            configuration: APIClient.imageSessionConfiguration))
        cachedImageAPI = client
        return client
    }

    private var api: APIClient { APIClient(session: self, urlSession: urlSession) }
    @ObservationIgnored private let oidcBrowser = OIDCWebSession()

    init(
        urlSession: URLSession? = nil,
        defaults: UserDefaults = .standard,
        dataManager: SwiftDataManager? = nil,
        credentialStore: any SessionCredentialStore = KeychainStore(),
        restoresSession: Bool = true
    ) {
        self.urlSession = urlSession
        self.defaults = defaults
        self.dataManager = dataManager ?? .shared
        self.credentialStore = credentialStore
        if restoresSession { loadStoredSession() }
    }

    /// Sesi tersimpan dibaca SECARA SINKRON di init, bukan menunggu `restore()`.
    ///
    /// `restore()` berjalan asinkron dan menunggu jawaban server. Selama itu
    /// `isLoggedIn` masih false, jadi router sempat menampilkan halaman masuk
    /// lalu berpindah sendiri ke Photos begitu jawabannya datang — kedipan yang
    /// terlihat setiap kali aplikasi dibuka.
    ///
    /// Keychain sudah cukup untuk tahu pernah ada sesi; keabsahannya diperiksa
    /// belakangan oleh `restore()`.
    private func loadStoredSession() {
        if let data = defaults.data(forKey: Self.ownerKey) {
            accountOwner = try? JSONDecoder().decode(BackupQueueOwner.self, from: data)
        }
        if let data = defaults.data(forKey: Self.userKey) {
            currentUser = try? JSONDecoder().decode(UserResponseDTO.self, from: data)
        }
        guard var server = credentialStore.read("serverURL") else { return }
        if server.hasSuffix("/api") { server.removeLast(4) }
        guard (try? setServer(server)) != nil else { return }
        // Migrate ownership before an expired token sends the user to onboarding.
        if accountOwner == nil, let owner = backupQueueOwner {
            accountOwner = owner
            persistOwner()
        }
        guard let accountOwner, let currentUser,
              accountOwner.server == baseURL?.absoluteString,
              accountOwner.userID == currentUser.id else {
            SharedSessionStore.clear()
            return
        }
        guard let token = credentialStore.read("token"),
              let mode = credentialStore.read("mode").flatMap(AuthMode.init)
        else { return }
        applyAuth(token: token, mode: mode)
        isLoggedIn = true
        persistSharedSessionIfPossible()
    }

    func setServer(_ raw: String) throws {
        var s = raw.trimmingCharacters(in: .whitespaces)
        if !s.hasPrefix("http") { s = "https://" + s }
        while s.hasSuffix("/") { s.removeLast() }
        guard let url = URL(string: s + "/api") else { throw APIError.invalidURL }
        if baseURL != url {
            if isLoggedIn {
                isLoggedIn = false
                authenticationAttempt = nil
                ["token", "mode"].forEach(credentialStore.delete)
                SharedSessionStore.clear()
                BackupService.shared.pauseForAuthentication()
                SharedUploadService.shared.cancel()
            }
            token = nil
            serverCompatibility = nil
            compatibilityIssue = nil
        }
        serverInput = s
        baseURL = url
        invalidateRequests()
    }

    func ping() async throws { let _: ServerPingDTO = try await api.send(.init(path: "/server/ping", requiresAuthentication: false)) }
    func serverVersion() async throws -> ServerVersionDTO { try await api.send(.init(path: "/server/version", requiresAuthentication: false)) }
    func features() async throws -> ServerFeaturesDTO { try await api.send(.init(path: "/server/features", requiresAuthentication: false)) }
    func serverConfig() async throws -> ServerConfigDTO { try await api.send(.init(path: "/server/config", requiresAuthentication: false)) }

    /// Menjalankan urutan pemeriksaan publik sebelum kredensial pernah dikirim.
    ///
    /// Ping sendiri hanya membuktikan ada proses Immich di alamat tersebut. Ia
    /// tidak membuktikan kontrak endpoint berikutnya cocok dengan aplikasi.
    /// Karena itu versi dan capability wajib berhasil dibaca, lalu major-nya
    /// harus berada dalam matriks yang didukung.
    @discardableResult
    func checkServerCompatibility() async throws -> ServerCompatibilityReport {
        let context = snapshot
        try await ping()
        try checkCurrent(context)
        let version = try await serverVersion()
        let features = try await features()
        try checkCurrent(context)
        let report = ServerCompatibilityReport(
            version: version,
            features: features,
            status: ServerCompatibilityPolicy.evaluate(version))

        serverCompatibility = report
        compatibilityIssue = ServerCompatibilityError.incompatibleReport(report)

        if let compatibilityIssue { throw compatibilityIssue }
        return report
    }

    func loginPassword(email: String, password: String) async throws {
        try await waitForCleanup()
        try requireCompatibleServer(passwordLogin: true)
        let attempt = beginAuthentication()
        defer { finishAttempt(attempt) }
        let context = snapshot
        let endpoint = Endpoint.json("/auth/login", method: .post,
            body: LoginRequestDTO(email: email, password: password),
            requiresAuthentication: false)
        let response: LoginResponseDTO = try await api.send(endpoint)
        try await completeLogin(token: response.accessToken, mode: .bearer,
            context: context, attempt: attempt)
    }

    func loginOIDC() async throws {
        try await waitForCleanup()
        try requireCompatibleServer(passwordLogin: false)
        guard serverCompatibility?.features.oauth == true else {
            throw ServerCompatibilityError.oauthUnavailable
        }
        let attempt = beginAuthentication()
        defer { finishAttempt(attempt) }
        let context = snapshot
        let request = try OIDCLoginRequest()
        let authorize: OAuthAuthorizeResponseDTO = try await api.send(
            .json("/oauth/authorize", method: .post, body: OAuthAuthorizeRequestDTO(
                redirectUri: OIDCLoginRequest.redirectURI,
                state: request.state,
                codeChallenge: request.codeChallenge), requiresAuthentication: false))
        guard let authorizationURL = URL(string: authorize.url) else {
            throw OIDCLoginError.invalidAuthorizationURL
        }
        let callback = try await oidcBrowser.authenticate(at: authorizationURL)
        try checkCurrent(context)
        let normalizedCallback = try request.callbackURL(callback)
        let response: LoginResponseDTO = try await api.send(
            .json("/oauth/callback", method: .post, body: OAuthCallbackRequestDTO(
                url: normalizedCallback,
                state: request.state,
                codeVerifier: request.codeVerifier), requiresAuthentication: false))
        try await completeLogin(token: response.accessToken, mode: .bearer,
            context: context, attempt: attempt)
    }

    func loginApiKey(_ key: String) async throws {
        try await waitForCleanup()
        try requireCompatibleServer(passwordLogin: false)
        let attempt = beginAuthentication()
        defer { finishAttempt(attempt) }
        try await completeLogin(token: key, mode: .apiKey, context: snapshot, attempt: attempt)
    }

    private func beginAuthentication() -> UUID {
        let attempt = UUID()
        authenticationAttempt = attempt
        invalidateRequests()
        return attempt
    }

    private func finishAttempt(_ attempt: UUID) {
        if authenticationAttempt == attempt { authenticationAttempt = nil }
    }

    private func completeLogin(
        token: String, mode: AuthMode, context: SessionRequestContext, attempt: UUID
    ) async throws {
        let headers = mode == .bearer ? ["Authorization": "Bearer \(token)"] : ["x-api-key": token]
        let client = APIClient(session: self, urlSession: urlSession, authHeaders: headers)
        let user: UserResponseDTO = try await client.send(.init(path: "/users/me"))
        try checkCurrent(context)
        guard let baseURL else { throw APIError.invalidURL }
        let owner = BackupQueueOwner(server: baseURL.absoluteString, userID: user.id)
        if accountOwner != owner {
            try await clearAccountData()
        }
        guard authenticationAttempt == attempt, self.baseURL == context.baseURL else {
            throw CancellationError()
        }
        accountOwner = owner
        currentUser = user
        authenticationError = nil
        compatibilityIssue = nil
        applyAuth(token: token, mode: mode)
        storeUser(user)
        persistOwner()
        persist()
        isLoggedIn = true
        invalidateRequests()
        BackupService.shared.configure(session: self)
    }

    func checkCurrent(_ context: SessionRequestContext) throws {
        guard context.revision == requestRevision,
              context.accountGeneration == accountGeneration else { throw CancellationError() }
    }

    /// Pertahanan lapis kedua untuk pemanggil selain onboarding. Dengan ini
    /// tidak ada jalur internal yang bisa langsung mengirim kredensial tanpa
    /// menjalankan compatibility gate lebih dahulu.
    private func requireCompatibleServer(passwordLogin: Bool) throws {
        guard let report = serverCompatibility else {
            throw ServerCompatibilityError.checkRequired
        }
        if let error = ServerCompatibilityError.incompatibleReport(report) {
            throw error
        }
        if passwordLogin, !report.features.passwordLogin {
            throw ServerCompatibilityError.passwordLoginUnavailable
        }
    }

    private func fetchMe() async throws {
        let context = snapshot
        let user: UserResponseDTO = try await api.send(.init(path: "/users/me"))
        try checkCurrent(context)
        if let accountOwner,
           accountOwner != BackupQueueOwner(server: baseURL?.absoluteString ?? "", userID: user.id) {
            await expireIfCurrent(context)
            throw APIError.unauthorized
        }
        currentUser = user
        storeUser(user)
    }

    // MARK: - Profil tersimpan

    private static let userKey = "session.currentUser"
    private static let ownerKey = "session.accountOwner"

    /// Profil disimpan di perangkat dan dibaca kembali di `init`.
    ///
    /// Tanpa ini, avatar di toolbar memulai setiap peluncuran sebagai "?" lalu
    /// berganti sendiri begitu `/users/me` menjawab — dan fotonya, yang byte-nya
    /// sebenarnya sudah ada di cache disk, tidak bisa dicari karena kunci
    /// cache-nya ikut hilang bersama profilnya.
    ///
    /// Bukan rahasia, jadi UserDefaults; token tetap di Keychain.
    private func storeUser(_ user: UserResponseDTO) {
        guard let data = try? JSONEncoder().encode(user) else { return }
        defaults.set(data, forKey: Self.userKey)
    }

    private func persistOwner() {
        guard let accountOwner, let data = try? JSONEncoder().encode(accountOwner) else { return }
        defaults.set(data, forKey: Self.ownerKey)
    }

    /// Memeriksa sesi yang sudah dipulihkan di init dan mengisi data pengguna.
    ///
    /// Hanya penolakan TEGAS dari server yang mengeluarkan pengguna. Gagal karena
    /// jaringan tidak: sesinya mungkin masih sah, dan memaksa masuk ulang setiap
    /// kali sinyal hilang jelas bukan yang diinginkan.
    func restore(configureBackup: Bool = true) async {
        guard isLoggedIn else { return }
        let context = snapshot
        let cacheGeneration = LocalSnapshot.generation
        defer {
            if configureBackup, isLoggedIn, hasCurrentCredentials,
               cacheGeneration == LocalSnapshot.generation,
               (try? checkCurrent(context)) != nil {
                BackupService.shared.configure(session: self)
            }
        }
        do {
            try await checkServerCompatibility()
            try await validate()
            try await fetchMe()
        } catch let error as ServerCompatibilityError {
            // Sesi lama tidak boleh membawa pengguna masuk ke kumpulan endpoint
            // yang sudah diketahui tidak kompatibel. Logout juga membuang cache
            // akun agar data pengguna lama tidak sempat terlihat pada login
            // berikutnya; pesannya dipasang kembali setelah cleanup.
            guard hasCurrentCredentials,
                  (try? checkCurrent(context)) != nil else { return }
            await logout(compatibilityIssue: error)
        } catch {
            // Offline: sesi tersimpan tetap dipakai.
        }
    }

    private func validate() async throws { try await api.sendVoid(.init(path: "/auth/validateToken", method: .post)) }

    /// Token sesi Immich tidak memiliki endpoint refresh pada kontrak API.
    /// Karena itu 401 membutuhkan login ulang, tetapi bukan alasan untuk
    /// membuang queue, pilihan album, atau mapping aset yang sudah diunggah.
    /// Setelah login berhasil, `BackupService.configure` melepas state
    /// `waitingForAuthentication` secara otomatis.
    func expireIfCurrent(_ context: SessionRequestContext) async {
        guard context.isAuthenticated, isLoggedIn, let token,
              (try? checkCurrent(context)) != nil else { return }
        // Another instance may already have expired this token. A replacement
        // token must never be removed by that instance's delayed response.
        if let storedToken = credentialStore.read("token"),
           storedToken != token || credentialStore.read("mode") != mode.rawValue { return }
        let ownership = BackupService.shared.uploadOwnership
        let headers = authHeaders
        ["token", "mode"].forEach(credentialStore.delete)
        SharedSessionStore.clear()
        AppLaunchState.shared.reset()
        self.token = nil
        isLoggedIn = false
        authenticationError = APIError.unauthorized.localizedDescription
        authenticationAttempt = nil
        invalidateRequests()
        BackupService.shared.pauseForAuthentication()
        SharedUploadService.shared.cancel()
        await BackupUploader.shared.cancelAll(ownership: ownership, authHeaders: headers)
    }

    func expireForBackgroundUpload() async {
        await expireIfCurrent(snapshot)
    }

    /// Mengambil ulang data pengguna dari server, diam-diam.
    ///
    /// Dipanggil setiap kali Library dan sheet pengaturan dibuka: inilah cara
    /// aplikasi tahu foto profilnya sudah diganti di server. Penanda
    /// perubahannya ikut berganti, kunci cache avatarnya ikut berganti, dan
    /// hanya pada saat itulah gambarnya diunduh lagi — sisa waktunya jawabannya
    /// sama persis dan avatar tetap dijawab dari cache.
    ///
    /// Kegagalan DIABAIKAN: ini penyegaran latar, dan data yang sudah ada masih
    /// benar sampai jawaban baru datang.
    func refreshUser() async {
        guard isLoggedIn, !isRefreshingUser else { return }
        isRefreshingUser = true
        defer { isRefreshingUser = false }
        try? await fetchMe()
    }

    /// Penjaga supaya dua layar yang muncul berbarengan tidak menembak
    /// `/users/me` dua kali. Sengaja tidak diamati: ini pembukuan internal.
    @ObservationIgnored private var isRefreshingUser = false

    func logout(compatibilityIssue: ServerCompatibilityError? = nil) async {
        // Bentuk request lengkap SEBELUM sesi dikosongkan. Dengan begitu logout
        // server tetap bisa berjalan tanpa mempertahankan token/base URL di
        // `SessionManager` selama cleanup lokal berlangsung.
        var remoteLogoutRequest: URLRequest?
        if let baseURL {
            var request = URLRequest(url: baseURL.appendingPathComponent("/auth/logout"))
            request.httpMethod = "POST"
            authHeaders.forEach { request.setValue($1, forHTTPHeaderField: $0) }
            remoteLogoutRequest = request
        }
        if let remoteLogoutRequest {
            Task.detached {
                _ = try? await URLSession.shared.data(for: remoteLogoutRequest)
            }
        }

        authenticationAttempt = nil
        OnboardingViewModel.clearStoredServer()
        ["serverURL", "token", "mode"].forEach(credentialStore.delete)
        token = nil
        isLoggedIn = false
        serverCompatibility = nil
        self.compatibilityIssue = compatibilityIssue
        authenticationError = nil
        serverInput = nil
        baseURL = nil
        invalidateRequests()
        do { try await clearAccountData() } catch {
            authenticationError = error.localizedDescription
        }
    }

    private func waitForCleanup() async throws {
        if let cleanupTask { try await cleanupTask.value }
    }

    private func clearAccountData() async throws {
        if let cleanupTask { return try await cleanupTask.value }
        let ownership = BackupQueueStore.shared.ownership
        let headers = authHeaders
        ["token", "mode"].forEach(credentialStore.delete)
        token = nil
        isLoggedIn = false
        cachedImageAPI = nil
        invalidateRequests()
        AppLaunchState.shared.reset()
        SharedSessionStore.clear()
        LocalSnapshot.clearAll()
        AlbumCoverStore.shared.clear()
        WidgetSnapshotExporter.clear()
        LocalPhotoLibrary.shared.resetForLogout()
        BackupService.shared.resetForLogout()
        SharedUploadService.shared.cancel()
        let cleanup = Task { @MainActor in
            await BackupUploader.shared.cancelAll(
                ownership: ownership, authHeaders: headers.isEmpty ? nil : headers)
            try self.dataManager.clearAllAccountData()
            AssistiveAccessPreferences.clearSelectedAlbum()
            DeletedServerAssetRegistry.shared.clear()
            RemovedAssets.shared.clear()
            UnreadableAssets.shared.clear()
            ThumbHash.clearCache()
            await ImageCache.shared.clear()
            URLCache.shared.removeAllCachedResponses()
            HTTPCookieStorage.shared.removeCookies(since: .distantPast)
            self.currentUser = nil
            self.accountOwner = nil
            self.defaults.removeObject(forKey: Self.userKey)
            self.defaults.removeObject(forKey: Self.ownerKey)
        }
        cleanupTask = cleanup
        defer { cleanupTask = nil }
        try await cleanup.value
    }

    private func applyAuth(token: String, mode: AuthMode) {
        self.token = token
        self.mode = mode
        invalidateRequests()
    }
    private func persist() {
        if let serverInput { credentialStore.save(serverInput, for: "serverURL") }
        if let token { credentialStore.save(token, for: "token") }
        credentialStore.save(mode.rawValue, for: "mode")
        persistSharedSessionIfPossible()
    }

    /// Extension hanya menerima URL API, id pemilik antrean, dan jenis header
    /// lewat App Group. Token tetap berada di shared Keychain.
    private func persistSharedSessionIfPossible() {
        guard let baseURL, let userID = currentUser?.id else { return }
        SharedSessionStore.save(
            apiURL: baseURL,
            userID: userID,
            authMode: mode.rawValue)
    }
}
