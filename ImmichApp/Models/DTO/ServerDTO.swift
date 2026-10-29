struct ServerPingDTO: Decodable {
    let res: String
}

/// Bentuk resmi jawaban `GET /server/version`.
///
/// `prerelease` baru menjadi field wajib pada kontrak v3. Tetap opsional di
/// sini agar aplikasi bisa membaca jawaban server v2, sesuai rentang
/// kompatibilitas mobile yang didokumentasikan Immich.
struct ServerVersionDTO: Decodable, Equatable, Sendable {
    let major: Int
    let minor: Int
    let patch: Int
    let prerelease: Int?

    init(major: Int, minor: Int, patch: Int, prerelease: Int? = nil) {
        self.major = major
        self.minor = minor
        self.patch = patch
        self.prerelease = prerelease
    }

    var displayName: String {
        let stable = "v\(major).\(minor).\(patch)"
        return prerelease.map { "\(stable)-\($0)" } ?? stable
    }
}

struct ServerFeaturesDTO: Decodable, Equatable, Sendable {
    let smartSearch: Bool
    let facialRecognition: Bool
    let oauth: Bool
    let passwordLogin: Bool
    let search: Bool

    // Seluruh capability wajib pada ServerFeaturesDto v3. Nilai bawaan false
    // menjaga kompatibilitas dengan server lama yang belum mengirim fieldnya.
    let configFile: Bool
    let duplicateDetection: Bool
    let email: Bool
    let importFaces: Bool
    let map: Bool
    let oauthAutoLaunch: Bool
    let ocr: Bool
    let realtimeTranscoding: Bool
    let reverseGeocoding: Bool
    let sidecar: Bool
    let trash: Bool

    init(
        smartSearch: Bool,
        facialRecognition: Bool,
        oauth: Bool,
        passwordLogin: Bool,
        search: Bool,
        configFile: Bool = false,
        duplicateDetection: Bool = false,
        email: Bool = false,
        importFaces: Bool = false,
        map: Bool = false,
        oauthAutoLaunch: Bool = false,
        ocr: Bool = false,
        realtimeTranscoding: Bool = false,
        reverseGeocoding: Bool = false,
        sidecar: Bool = false,
        trash: Bool = false
    ) {
        self.smartSearch = smartSearch
        self.facialRecognition = facialRecognition
        self.oauth = oauth
        self.passwordLogin = passwordLogin
        self.search = search
        self.configFile = configFile
        self.duplicateDetection = duplicateDetection
        self.email = email
        self.importFaces = importFaces
        self.map = map
        self.oauthAutoLaunch = oauthAutoLaunch
        self.ocr = ocr
        self.realtimeTranscoding = realtimeTranscoding
        self.reverseGeocoding = reverseGeocoding
        self.sidecar = sidecar
        self.trash = trash
    }

    private enum CodingKeys: String, CodingKey {
        case smartSearch, facialRecognition, oauth, passwordLogin, search
        case configFile, duplicateDetection, email, importFaces, map
        case oauthAutoLaunch, ocr, realtimeTranscoding, reverseGeocoding
        case sidecar, trash
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            smartSearch: try c.decodeIfPresent(Bool.self, forKey: .smartSearch) ?? false,
            facialRecognition: try c.decodeIfPresent(Bool.self, forKey: .facialRecognition) ?? false,
            oauth: try c.decodeIfPresent(Bool.self, forKey: .oauth) ?? false,
            passwordLogin: try c.decodeIfPresent(Bool.self, forKey: .passwordLogin) ?? false,
            search: try c.decodeIfPresent(Bool.self, forKey: .search) ?? false,
            configFile: try c.decodeIfPresent(Bool.self, forKey: .configFile) ?? false,
            duplicateDetection: try c.decodeIfPresent(Bool.self, forKey: .duplicateDetection) ?? false,
            email: try c.decodeIfPresent(Bool.self, forKey: .email) ?? false,
            importFaces: try c.decodeIfPresent(Bool.self, forKey: .importFaces) ?? false,
            map: try c.decodeIfPresent(Bool.self, forKey: .map) ?? false,
            oauthAutoLaunch: try c.decodeIfPresent(Bool.self, forKey: .oauthAutoLaunch) ?? false,
            ocr: try c.decodeIfPresent(Bool.self, forKey: .ocr) ?? false,
            realtimeTranscoding: try c.decodeIfPresent(Bool.self, forKey: .realtimeTranscoding) ?? false,
            reverseGeocoding: try c.decodeIfPresent(Bool.self, forKey: .reverseGeocoding) ?? false,
            sidecar: try c.decodeIfPresent(Bool.self, forKey: .sidecar) ?? false,
            trash: try c.decodeIfPresent(Bool.self, forKey: .trash) ?? false)
    }
}

struct ServerAboutDTO: Decodable {
    let version: String
    let versionUrl: String?
}

struct ServerConfigDTO: Decodable {
    let externalDomain: String?
    let isInitialized: Bool?
    let isOnboarded: Bool?
    let loginPageMessage: String?
    let maintenanceMode: Bool?
    let oauthButtonText: String?
    let trashDays: Int?
}

struct ServerStorageDTO: Decodable {
    // diskUse/diskSize di API berupa string terformat ("1TB");
    // varian *Raw yang berupa byte count.
    let diskUse: String?
    let diskSize: String?
    let diskUseRaw: Int?
    let diskSizeRaw: Int?
    let diskUsagePercentage: Double?
}
