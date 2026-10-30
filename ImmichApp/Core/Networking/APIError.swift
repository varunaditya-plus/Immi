import Foundation

enum APIError: Error, LocalizedError {
    case invalidURL
    case notConnected
    case connectionFailed(URLError)
    case unauthorized
    case decoding(Error)
    case server(status: Int, message: String?)
    case unknown

    var errorDescription: String? {
        switch self {
        case .invalidURL:      return String(localized: "Invalid server address.")
        case .notConnected:    return String(localized: "No internet connection.")
        case .connectionFailed(let error):
            switch error.code {
            case .timedOut:
                return String(localized: "The server took too long to respond. Try again.")
            case .networkConnectionLost:
                return String(localized: "The connection to the server was lost. Try again.")
            case .dataNotAllowed, .internationalRoamingOff:
                return String(localized: "Network access is restricted. Check your connection settings.")
            default:
                return String(localized: "Couldn't reach that server.")
            }
        case .unauthorized:    return String(localized: "Session expired, please sign in again.")
        case .decoding:        return String(localized: "Failed to read data from server.")
        case .server(_, let m):return m ?? String(localized: "A server error occurred.")
        case .unknown:         return String(localized: "An unknown error occurred.")
        }
    }

    /// Server menolak permintaan untuk sebuah aset dengan cara yang berarti aset
    /// itu memang tidak bisa kita baca lagi.
    ///
    /// Immich menjawab "Not found or no asset.read access" dengan status 400,
    /// bukan 404 — jadi keduanya diperlakukan sama. Yang dibandingkan STATUSNYA,
    /// bukan tulisannya: teks itu bahasa Inggris apa adanya dari server dan bisa
    /// berubah kapan saja.
    ///
    /// Sengaja TIDAK memuat 401 (itu soal sesi, bukan satu aset), 403, maupun
    /// 5xx dan kegagalan jaringan — semuanya bisa pulih sendiri, dan membuang
    /// foto dari cache karena server sedang bermasalah tidak bisa dibatalkan
    /// tanpa sync ulang penuh.
    ///
    /// Hanya berarti untuk permintaan yang memang menyebut satu aset; pemanggil
    /// yang tahu itulah yang boleh memakainya.
    var meansAssetIsUnreadable: Bool {
        guard case .server(let status, _) = self else { return false }
        return status == 400 || status == 404
    }
}
