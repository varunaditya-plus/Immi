import XCTest
@testable import ImmichApp

final class ServerCompatibilityTests: XCTestCase {
    func testCurrentMajorIsCompatible() {
        let report = report(for:
            ServerVersionDTO(major: 3, minor: 1, patch: 0))

        XCTAssertEqual(report.status, .compatible)
        XCTAssertNil(ServerCompatibilityError.incompatibleReport(report))
    }

    func testPreviousMajorIsCompatibleLegacy() {
        let report = report(for:
            ServerVersionDTO(major: 2, minor: 7, patch: 4))

        XCTAssertEqual(report.status, .compatibleLegacy)
        XCTAssertNil(ServerCompatibilityError.incompatibleReport(report))
    }

    func testOlderMajorRequiresServerUpgrade() {
        let report = report(for:
            ServerVersionDTO(major: 1, minor: 143, patch: 0))

        XCTAssertEqual(report.status, .serverUpgradeRequired)
        XCTAssertEqual(ServerCompatibilityError.incompatibleReport(report), .serverTooOld(found: report.version))
    }

    func testFutureMajorRequiresAppUpgrade() {
        let report = report(for:
            ServerVersionDTO(major: 4, minor: 0, patch: 0))

        XCTAssertEqual(report.status, .appUpgradeRequired)
        XCTAssertEqual(ServerCompatibilityError.incompatibleReport(report), .appTooOld(found: report.version))
    }

    func testPrereleaseVersionFormatting() {
        let version = ServerVersionDTO(major: 3, minor: 2, patch: 0, prerelease: 3)
        XCTAssertEqual(version.displayName, "v3.2.0-3")
    }

    func testDecodesOfficialV3VersionResponse() throws {
        let json = Data(#"{"major":3,"minor":1,"patch":0,"prerelease":null}"#.utf8)
        let version = try JSONDecoder().decode(ServerVersionDTO.self, from: json)

        XCTAssertEqual(version, ServerVersionDTO(major: 3, minor: 1, patch: 0))
    }

    func testDecodesV2ResponseWithoutPrereleaseField() throws {
        let json = Data(#"{"major":2,"minor":7,"patch":4}"#.utf8)
        let version = try JSONDecoder().decode(ServerVersionDTO.self, from: json)

        XCTAssertEqual(version, ServerVersionDTO(major: 2, minor: 7, patch: 4))
    }

    private func report(for version: ServerVersionDTO) -> ServerCompatibilityReport {
        ServerCompatibilityReport(version: version,
            features: ServerFeaturesDTO(smartSearch: true, facialRecognition: true,
                oauth: false, passwordLogin: true, search: true),
            status: ServerCompatibilityPolicy.evaluate(version))
    }
}
