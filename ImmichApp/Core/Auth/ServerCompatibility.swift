import Foundation

/// Rentang kontrak API yang benar-benar dibawa build aplikasi ini.
///
/// Immich mendokumentasikan bahwa aplikasi mobile biasanya mendukung major
/// server saat ini dan satu major sebelumnya. Kontrak aplikasi sudah berada di
/// API v3, sehingga v2 adalah batas kompatibilitas lama dan v4 harus menunggu
/// aplikasi yang membawa kontrak v4.
enum ServerCompatibilityPolicy {
    static let apiMajor = 3
    static let minimumServerMajor = apiMajor - 1

    static var supportedRangeDescription: String {
        "v\(minimumServerMajor)–v\(apiMajor)"
    }

    static func evaluate(_ version: ServerVersionDTO) -> ServerCompatibilityStatus {
        if version.major < minimumServerMajor { return .serverUpgradeRequired }
        if version.major > apiMajor { return .appUpgradeRequired }
        if version.major == minimumServerMajor { return .compatibleLegacy }
        return .compatible
    }
}

enum ServerCompatibilityStatus: Equatable, Sendable {
    case compatible
    case compatibleLegacy
    case serverUpgradeRequired
    case appUpgradeRequired

    var title: String {
        switch self {
        case .compatible: String(localized: "Compatible")
        case .compatibleLegacy: String(localized: "Compatible (Legacy)")
        case .serverUpgradeRequired: String(localized: "Server Update Required")
        case .appUpgradeRequired: String(localized: "App Update Required")
        }
    }
}

struct ServerCompatibilityReport: Equatable, Sendable {
    let version: ServerVersionDTO
    let features: ServerFeaturesDTO
    let status: ServerCompatibilityStatus
}

enum ServerCompatibilityError: LocalizedError, Equatable {
    case checkRequired
    case serverTooOld(found: ServerVersionDTO)
    case appTooOld(found: ServerVersionDTO)
    case passwordLoginUnavailable
    case oauthUnavailable
    case authenticationUnavailable

    var errorDescription: String? {
        switch self {
        case .checkRequired:
            return String(
                localized: "The server compatibility check must finish before signing in.")
        case .serverTooOld(let found):
            return String(
                localized: "Server \(found.displayName) is too old for this app. Update Immich Server to v\(ServerCompatibilityPolicy.minimumServerMajor) or newer.")
        case .appTooOld(let found):
            return String(
                localized: "Server \(found.displayName) is newer than this app supports. Update the app before signing in.")
        case .passwordLoginUnavailable:
            return String(
                localized: "Password login is disabled on this server.")
        case .oauthUnavailable:
            return String(localized: "Single sign-on is disabled on this server.")
        case .authenticationUnavailable:
            return String(localized: "This server does not offer a supported sign-in method.")
        }
    }

    static func incompatibleReport(_ report: ServerCompatibilityReport) -> Self? {
        switch report.status {
        case .compatible, .compatibleLegacy: nil
        case .serverUpgradeRequired: .serverTooOld(found: report.version)
        case .appUpgradeRequired: .appTooOld(found: report.version)
        }
    }
}
