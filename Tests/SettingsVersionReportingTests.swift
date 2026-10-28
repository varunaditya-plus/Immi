import XCTest
@testable import ImmichApp

@MainActor
final class SettingsVersionReportingTests: XCTestCase {
    func testLaterMajorMinorAndPatchReleasesOfferAnUpdate() {
        let viewModel = viewModel()
        for (current, latest) in [
            ("v2.9.0", "v2.10.0"),
            ("2.10.9", "2.10.10"),
            ("2.99.99", "3.0.0"),
            ("3.0.0", "v3.0.1"),
        ] {
            setVersions(viewModel, current: current, latest: latest)
            XCTAssertTrue(viewModel.isUpdateAvailable, "\(current) should update to \(latest)")
        }
    }

    func testLaterInstalledVersionsAreNeverOfferedAnOlderRelease() {
        let viewModel = viewModel()
        for (current, latest) in [
            ("v2.10.0", "v2.9.0"),
            ("2.10.10", "2.10.9"),
            ("3.0.0", "2.99.99"),
            ("v3.0.1", "3.0.0"),
        ] {
            setVersions(viewModel, current: current, latest: latest)
            XCTAssertFalse(viewModel.isUpdateAvailable, "\(current) must not downgrade to \(latest)")
        }
    }

    func testPrefixAndBuildMetadataDoNotMakeAnEquivalentReleaseLookNew() {
        let viewModel = viewModel()
        for (current, latest) in [
            ("3.1.0", "v3.1.0"),
            ("v3.1.0", "3.1.0"),
            ("v3.1.0", "v3.1.0"),
            ("3.1.0+local.123", "v3.1.0+release.456"),
            ("3.1.0-rc.2+local", "3.1.0-rc.2+published"),
        ] {
            setVersions(viewModel, current: current, latest: latest)
            XCTAssertFalse(viewModel.isUpdateAvailable, "\(current) and \(latest) have equal precedence")
        }
    }

    func testStableReleaseSupersedesItsPrereleaseWithoutOfferingTheReverse() {
        let viewModel = viewModel()
        for prerelease in ["3.1.0-1", "3.1.0-rc.2", "3.1.0-dev+commit.abc"] {
            setVersions(viewModel, current: prerelease, latest: "v3.1.0")
            XCTAssertTrue(viewModel.isUpdateAvailable)
            setVersions(viewModel, current: "v3.1.0", latest: prerelease)
            XCTAssertFalse(viewModel.isUpdateAvailable)
        }
    }

    func testPrereleaseOrderingUsesSemanticVersionRules() {
        let viewModel = viewModel()
        // Ascending precedence from https://semver.org/#spec-item-11.
        let releases = [
            "1.0.0-alpha", "1.0.0-alpha.1", "1.0.0-alpha.beta", "1.0.0-beta",
            "1.0.0-beta.2", "1.0.0-beta.11", "1.0.0-rc.1", "1.0.0",
        ]
        for (currentIndex, current) in releases.enumerated() {
            for (latestIndex, latest) in releases.enumerated() {
                setVersions(viewModel, current: current, latest: latest)
                XCTAssertEqual(viewModel.isUpdateAvailable, latestIndex > currentIndex,
                    "Incorrect precedence for installed \(current), available \(latest)")
            }
        }
        // Alphanumeric identifiers compare lexically, rather than by their embedded digits.
        setVersions(viewModel, current: "3.1.0-alpha2", latest: "3.1.0-alpha10")
        XCTAssertFalse(viewModel.isUpdateAvailable)
        setVersions(viewModel, current: "3.1.0-alpha10", latest: "3.1.0-alpha2")
        XCTAssertTrue(viewModel.isUpdateAvailable)
    }

    func testNewerDevelopmentServerIsNotOfferedAnOlderStableRelease() {
        let viewModel = viewModel()
        for current in ["v3.2.0-dev", "3.2.0-rc.0", "3.1.1-dev+abc", "4.0.0-1"] {
            setVersions(viewModel, current: current, latest: "v3.1.0")
            XCTAssertFalse(viewModel.isUpdateAvailable)
        }
    }

    func testUnknownOrInvalidVersionsDoNotClaimAnUpdateIsAvailable() {
        let viewModel = viewModel()
        for invalid in [
            "", "dev", "main", "nightly", "3.1", "3.1.0.1", "v", "vv3.1.0",
            "03.1.0", "3.01.0", "3.1.00", "-3.1.0", "3.1.0-", "3.1.0-01",
            "3.1.0-rc..1", "3.1.0+", "3.1.0+one+two", "3.1.0+one..two",
            "3.1.0 release", "3.1.0-β", "3.1.0+build_1",
        ] {
            setVersions(viewModel, current: invalid, latest: "9.0.0")
            XCTAssertFalse(viewModel.isUpdateAvailable, "Unknown installed version: \(invalid)")
            setVersions(viewModel, current: "1.0.0", latest: invalid)
            XCTAssertFalse(viewModel.isUpdateAvailable, "Unknown available version: \(invalid)")
        }
        viewModel.serverInfo = nil
        viewModel.latestVersion = "9.0.0"
        XCTAssertFalse(viewModel.isUpdateAvailable)
        viewModel.serverInfo = .init(version: "1.0.0", versionUrl: nil)
        viewModel.latestVersion = nil
        XCTAssertFalse(viewModel.isUpdateAvailable)
    }

    func testLargeNumericComponentsAndIdentifiersCompareWithoutOverflow() {
        let viewModel = viewModel()
        for (current, latest) in [
            ("3.1.999999999999999999999999", "3.1.1000000000000000000000000"),
            ("3.1.0-999999999999999999999999", "3.1.0-1000000000000000000000000"),
        ] {
            setVersions(viewModel, current: current, latest: latest)
            XCTAssertTrue(viewModel.isUpdateAvailable)
            setVersions(viewModel, current: latest, latest: current)
            XCTAssertFalse(viewModel.isUpdateAvailable)
        }
    }

    func testLoadedServerResponsesUseVersionOrderAndClearADisabledVersionCheck() async {
        let repository = VersionReportingRepository(api: APIClient(session: MockSessionManager()))
        let viewModel = SettingsViewModel(repo: repository)

        await viewModel.loadServerInfo()

        XCTAssertEqual(viewModel.serverInfo?.version, "v3.1.0")
        XCTAssertEqual(viewModel.latestVersion, "v3.2.0")
        XCTAssertTrue(viewModel.isUpdateAvailable)
        if case .loaded = viewModel.serverPhase {} else { XCTFail("Expected server information to load") }

        repository.current = "v3.3.0-dev"
        await viewModel.loadServerInfo()
        XCTAssertEqual(viewModel.serverInfo?.version, "v3.3.0-dev")
        XCTAssertFalse(viewModel.isUpdateAvailable)

        repository.versionCheckError = APIError.unknown
        await viewModel.loadServerInfo()
        XCTAssertNil(viewModel.latestVersion)
        XCTAssertFalse(viewModel.isUpdateAvailable)
        if case .loaded = viewModel.serverPhase {} else { XCTFail("Optional version checks must not fail server information") }
    }

    private func viewModel() -> SettingsViewModel {
        SettingsViewModel(repo: SettingsRepository(api: APIClient(session: MockSessionManager())))
    }

    private func setVersions(_ viewModel: SettingsViewModel, current: String, latest: String) {
        viewModel.serverInfo = .init(version: current, versionUrl: nil)
        viewModel.latestVersion = latest
    }
}

private final class VersionReportingRepository: SettingsRepository {
    var current = "v3.1.0"
    var versionCheckError: Error?

    override func getServerInfo() async throws -> ServerAboutDTO {
        .init(version: current, versionUrl: nil)
    }

    override func getStorageInfo() async throws -> ServerStorageDTO {
        .init(diskUse: nil, diskSize: nil, diskUseRaw: nil, diskSizeRaw: nil, diskUsagePercentage: nil)
    }

    override func getAssetStats() async throws -> AssetStatsDTO {
        .init(images: 1, videos: 1, total: 2)
    }

    override func getVersionCheck() async throws -> VersionCheckDTO {
        if let versionCheckError { throw versionCheckError }
        return .init(checkedAt: nil, releaseVersion: "v3.2.0")
    }
}
