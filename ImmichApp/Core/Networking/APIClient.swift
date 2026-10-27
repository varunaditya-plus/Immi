import Foundation

class APIClient {
    let session: SessionManager
    private let urlSession: URLSession
    private let accountGeneration: UUID
    private let authHeaders: [String: String]?

    private static let foregroundSession = URLSession(configuration: NetworkResponseCache.configuration())

    @MainActor
    init(session: SessionManager, urlSession: URLSession? = nil, authHeaders: [String: String]? = nil) {
        self.session = session
        self.urlSession = urlSession ?? Self.foregroundSession
        self.accountGeneration = session.accountGeneration
        self.authHeaders = authHeaders
    }

    @MainActor
    func checkCurrent(_ context: SessionRequestContext) throws {
        guard accountGeneration == session.accountGeneration else { throw CancellationError() }
        try session.checkCurrent(context)
    }

    /// Session khusus byte gambar.
    ///
    /// `URLCache` DIMATIKAN di sini. Kita sudah menyimpan byte-nya sendiri di
    /// disk; membiarkan URLSession menyimpannya lagi berarti setiap thumbnail
    /// ditulis dua kali dan mengaduk cache bersama milik seluruh proses.
    ///
    /// Batas koneksi per host dinaikkan karena thumbnail itu kecil dan banyak —
    /// enam koneksi bawaan membuat antreannya jauh lebih panjang dari perlunya.
    static let imageSessionConfiguration: URLSessionConfiguration = {
        let config = NetworkResponseCache.configuration()
        config.httpMaximumConnectionsPerHost = 8
        config.timeoutIntervalForRequest = 20
        config.timeoutIntervalForResource = 60
        return config
    }()

    @MainActor
    func send<T: Decodable>(_ endpoint: Endpoint) async throws -> T {
        let (data, http, context) = try await perform(endpoint)
        try await validate(http, data, context: context, endpoint: endpoint)
        let value: T
        do { value = try await Self.decode(data) }
        catch { throw APIError.decoding(error) }
        try checkCurrent(context)
        return value
    }

    private nonisolated static func decode<T: Decodable>(_ data: Data) async throws -> T {
        try JSONDecoder.immich.decode(T.self, from: data)
    }

    @MainActor
    func sendVoid(_ endpoint: Endpoint) async throws {
        let (data, http, context) = try await perform(endpoint)
        try await validate(http, data, context: context, endpoint: endpoint)
    }

    @MainActor
    func rawData(_ endpoint: Endpoint) async throws -> Data {
        let (data, http, context) = try await perform(endpoint)
        try await validate(http, data, context: context, endpoint: endpoint)
        return data
    }

    /// Mengunduh respons langsung ke file sementara.
    ///
    /// Jalur ini dipakai untuk original photo/video. `data(for:)` menahan
    /// seluruh video di RAM sebelum satu byte pun dapat disimpan ke Photos.
    @MainActor
    func rawFile(_ endpoint: Endpoint) async throws -> URL {
        let (request, context) = try makeRequest(endpoint)
        do {
            let (temporaryURL, response) = try await urlSession.download(for: request)
            defer { try? FileManager.default.removeItem(at: temporaryURL) }
            guard let http = response as? HTTPURLResponse else { throw APIError.unknown }
            let errorData = (200..<300).contains(http.statusCode)
                ? Data() : ((try? Data(contentsOf: temporaryURL)) ?? Data())
            try await validate(http, errorData, context: context, endpoint: endpoint)

            let destination = FileManager.default.temporaryDirectory
                .appendingPathComponent("download-\(UUID().uuidString)")
            try FileManager.default.moveItem(at: temporaryURL, to: destination)
            return destination
        } catch let error as URLError where Self.meansOffline(error.code) {
            throw APIError.notConnected
        }
    }

    /// Respons JSON Lines (mis. /sync/stream): satu objek JSON per baris.
    @MainActor
    func streamLines(_ endpoint: Endpoint) async throws -> AsyncLineSequence<URLSession.AsyncBytes> {
        let (req, context) = try makeRequest(endpoint)
        let result: (URLSession.AsyncBytes, URLResponse)
        do {
            result = try await urlSession.bytes(for: req)
        } catch let e as URLError where Self.meansOffline(e.code) {
            throw APIError.notConnected
        }
        let (bytes, resp) = result
        guard let http = resp as? HTTPURLResponse else { throw APIError.unknown }
        try await validate(http, Data(), context: context, endpoint: endpoint)
        return bytes.lines
    }

    /// "Tidak sampai ke server" — LEBIH LUAS dari sekadar tidak ada internet.
    ///
    /// Sebelumnya hanya `.notConnectedToInternet` yang dikenali, dan itu kasus
    /// yang justru paling jarang: server Immich biasanya di jaringan sendiri.
    /// Keluar dari jangkauan Wi‑Fi rumah menghasilkan `.cannotConnectToHost`
    /// atau `.timedOut`, dan keduanya dulu lolos sebagai `URLError` mentah —
    /// lapisan di atasnya tidak bisa membedakan "sedang di luar" dari "ada yang
    /// rusak", dan menampilkan pesan gagal yang membingungkan untuk keadaan yang
    /// sepenuhnya wajar.
    private static func meansOffline(_ code: URLError.Code) -> Bool {
        switch code {
        case .notConnectedToInternet, .networkConnectionLost, .cannotConnectToHost,
             .cannotFindHost, .timedOut, .dataNotAllowed, .internationalRoamingOff:
            return true
        default:
            return false
        }
    }

    @MainActor
    private func perform(_ endpoint: Endpoint) async throws -> (Data, HTTPURLResponse, SessionRequestContext) {
        let (req, context) = try makeRequest(endpoint)
        do {
            let (data, resp) = try await urlSession.data(for: req)
            guard let http = resp as? HTTPURLResponse else { throw APIError.unknown }
            return (data, http, context)
        } catch let e as URLError where Self.meansOffline(e.code) {
            throw APIError.notConnected
        }
    }

    @MainActor
    private func makeRequest(_ endpoint: Endpoint) throws -> (URLRequest, SessionRequestContext) {
        let context = session.snapshot
        try checkCurrent(context)
        let baseURL = context.baseURL
        let headers = authHeaders ?? (endpoint.requiresAuthentication ? context.authHeaders : [:])
        guard let baseURL else { throw APIError.invalidURL }
        var comps = URLComponents(url: baseURL.appendingPathComponent(endpoint.path),
                                  resolvingAgainstBaseURL: false)
        if !endpoint.query.isEmpty { comps?.queryItems = endpoint.query }
        guard let url = comps?.url else { throw APIError.invalidURL }

        var req = URLRequest(url: url)
        req.httpMethod = endpoint.method.rawValue
        req.httpBody = endpoint.body
        if endpoint.body != nil {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
        for (k, v) in endpoint.extraHeaders { req.setValue(v, forHTTPHeaderField: k) }
        return (req, context)
    }

    @MainActor
    private func validate(
        _ http: HTTPURLResponse, _ data: Data,
        context: SessionRequestContext, endpoint: Endpoint
    ) async throws {
        try checkCurrent(context)
        switch http.statusCode {
        case 200..<300: return
        case 401:
            if authHeaders == nil, endpoint.requiresAuthentication {
                await session.expireIfCurrent(context)
            }
            throw APIError.unauthorized
        default:
            let msg = (try? JSONDecoder().decode(ServerErrorDTO.self, from: data))?.message
            throw APIError.server(status: http.statusCode, message: msg)
        }
    }
}

struct ServerErrorDTO: Decodable { let message: String? }

extension JSONDecoder {
    static let immich: JSONDecoder = {
        let d = JSONDecoder()
        // `AssetResponseDto.duration` pada API Immich adalah milidetik. DTO
        // menormalisasikannya ke detik untuk AVFoundation dan label durasi.
        d.userInfo[.immichAssetDurationIsMilliseconds] = true
        d.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let raw = try container.decode(String.self)
            if let date = ISO8601DateFormatter.immichFractional.date(from: raw)
                ?? ISO8601DateFormatter.immichPlain.date(from: raw)
                ?? DateFormatter.immichDateOnly.date(from: raw) {
                return date
            }
            throw DecodingError.dataCorruptedError(
                in: container, debugDescription: "Invalid ISO8601 date: \(raw)")
        }
        return d
    }()
}

extension ISO8601DateFormatter {
    // Immich mengirim tanggal dengan pecahan detik ("2024-01-01T12:00:00.000Z"),
    // beberapa field tanpa pecahan, dan birthDate berformat tanggal saja.
    static let immichFractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    static let immichPlain: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()
}

extension DateFormatter {
    static let immichDateOnly: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(secondsFromGMT: 0)
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()
}

extension JSONEncoder {
    static let immich: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }()
}
