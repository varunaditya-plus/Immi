import XCTest
@testable import ImmichApp

@MainActor
final class SettingsVersionFreshnessTests: XCTestCase {
    func testFreshAboutVersionTakesPriorityOverTheLoginTimeCompatibilityVersion() async {
        let repository = repository()
        repository.currentVersion = "v3.3.0-rc.1"
        let model = SettingsViewModel(repo: repository)
        let loginVersion = ServerVersionDTO(major: 3, minor: 1, patch: 0)

        await model.loadServerInfo()

        XCTAssertEqual(model.serverInfo?.version, "v3.3.0-rc.1")
        XCTAssertEqual(model.displayedServerVersion(fallback: loginVersion), "v3.3.0-rc.1")
        XCTAssertEqual(model.displayedServerVersion(fallback: nil), "v3.3.0-rc.1")
    }

    func testCompatibilityVersionIsUsedOnlyUntilAboutInformationIsAvailable() {
        let model = SettingsViewModel(repo: repository())

        XCTAssertNil(model.displayedServerVersion(fallback: nil))
        XCTAssertEqual(model.displayedServerVersion(fallback: .init(major: 3, minor: 1, patch: 0)), "v3.1.0")
        XCTAssertEqual(model.displayedServerVersion(fallback: .init(major: 3, minor: 1, patch: 0, prerelease: 2)), "v3.1.0-2")
    }

    func testRefreshWithdrawsAnOldRecommendationBeforeTheNewAboutRequestCompletes() async throws {
        let repository = repository()
        let model = SettingsViewModel(repo: repository)
        await model.loadServerInfo()
        XCTAssertTrue(model.isUpdateAvailable)
        XCTAssertEqual(model.latestVersion, "v3.2.0")
        let held = FreshVersionGate()
        repository.aboutGate = held
        repository.currentVersion = "v3.3.0"
        let refresh = Task { await model.loadServerInfo() }
        addTeardownBlock { await held.release(); await refresh.value }
        await fulfillment(of: [held.started], timeout: 2)

        XCTAssertTrue(model.serverPhase.isLoading)
        XCTAssertNil(model.latestVersion, "A recommendation from the previous read cannot remain authoritative")
        XCTAssertFalse(model.isUpdateAvailable)
        XCTAssertEqual(model.displayedServerVersion(fallback: nil), "v3.1.0", "The last known version can still be displayed")
        held.release()
        await refresh.value

        XCTAssertEqual(model.serverInfo?.version, "v3.3.0")
        XCTAssertEqual(model.latestVersion, "v3.2.0")
        XCTAssertFalse(model.isUpdateAvailable, "The newly installed server must not be offered a downgrade")
        XCTAssertEqual(model.displayedServerVersion(fallback: .init(major: 3, minor: 1, patch: 0)), "v3.3.0")
    }

    func testFailedStorageRefreshCannotKeepRecommendingAnOlderRelease() async {
        let repository = repository()
        let model = SettingsViewModel(repo: repository)
        await model.loadServerInfo()
        XCTAssertTrue(model.isUpdateAvailable)
        repository.currentVersion = "v3.3.0"
        repository.storageError = APIError.notConnected

        await model.loadServerInfo()

        XCTAssertNotNil(model.serverPhase.errorMessage)
        XCTAssertNil(model.latestVersion)
        XCTAssertFalse(model.isUpdateAvailable)
        XCTAssertEqual(model.displayedServerVersion(fallback: nil), "v3.1.0", "A failed refresh preserves the last known display")

        repository.storageError = nil
        await model.loadServerInfo()
        XCTAssertEqual(model.displayedServerVersion(fallback: nil), "v3.3.0")
        XCTAssertFalse(model.isUpdateAvailable)
    }

    func testFailedAboutRefreshCannotReuseThePreviousUpdateRecommendation() async {
        let repository = repository()
        let model = SettingsViewModel(repo: repository)
        await model.loadServerInfo()
        XCTAssertTrue(model.isUpdateAvailable)
        repository.aboutError = APIError.notConnected

        await model.loadServerInfo()

        XCTAssertNotNil(model.serverPhase.errorMessage)
        XCTAssertNil(model.latestVersion)
        XCTAssertFalse(model.isUpdateAvailable)
        XCTAssertEqual(model.displayedServerVersion(fallback: nil), "v3.1.0")

        repository.aboutError = nil
        repository.currentVersion = "v3.2.0"
        repository.availableVersion = "v3.3.0"
        await model.loadServerInfo()
        XCTAssertNil(model.serverPhase.errorMessage)
        XCTAssertEqual(model.displayedServerVersion(fallback: nil), "v3.2.0")
        XCTAssertTrue(model.isUpdateAvailable, "A successful later refresh can publish a new recommendation")
    }

    func testDisabledAndFailedOptionalVersionChecksPreserveFreshServerInformation() async {
        let repository = repository()
        let model = SettingsViewModel(repo: repository)
        await model.loadServerInfo()
        XCTAssertTrue(model.isUpdateAvailable)
        repository.currentVersion = "v3.3.0"
        repository.availableVersion = nil

        await model.loadServerInfo()

        XCTAssertNil(model.serverPhase.errorMessage)
        XCTAssertEqual(model.serverInfo?.version, "v3.3.0")
        XCTAssertEqual(model.displayedServerVersion(fallback: .init(major: 3, minor: 1, patch: 0)), "v3.3.0")
        XCTAssertNil(model.latestVersion)
        XCTAssertFalse(model.isUpdateAvailable)

        repository.currentVersion = "v3.4.0"
        repository.availableVersion = "v3.5.0"
        repository.versionCheckError = APIError.notConnected
        await model.loadServerInfo()
        XCTAssertNil(model.serverPhase.errorMessage)
        XCTAssertEqual(model.serverInfo?.version, "v3.4.0")
        XCTAssertNil(model.latestVersion)
        XCTAssertFalse(model.isUpdateAvailable)
    }

    private func repository() -> FreshVersionRepository {
        FreshVersionRepository(api: APIClient(session: MockSessionManager()))
    }
}

private final class FreshVersionRepository: SettingsRepository {
    var currentVersion = "v3.1.0"
    var availableVersion: String? = "v3.2.0"
    var storageError: Error?
    var aboutError: Error?
    var versionCheckError: Error?
    var aboutGate: FreshVersionGate?

    override func getServerInfo() async throws -> ServerAboutDTO {
        let version = currentVersion
        if let aboutError { throw aboutError }
        if let aboutGate { await aboutGate.wait() }
        return .init(version: version, versionUrl: nil)
    }

    override func getStorageInfo() async throws -> ServerStorageDTO {
        if let storageError { throw storageError }
        return .init(diskUse: nil, diskSize: nil, diskUseRaw: nil, diskSizeRaw: nil, diskUsagePercentage: nil)
    }

    override func getAssetStats() async throws -> AssetStatsDTO {
        .init(images: 1, videos: 0, total: 1)
    }

    override func getVersionCheck() async throws -> VersionCheckDTO {
        if let versionCheckError { throw versionCheckError }
        return .init(checkedAt: nil, releaseVersion: availableVersion)
    }
}

@MainActor
private final class FreshVersionGate {
    let started = XCTestExpectation(description: "A version refresh is held before about returns")
    private var continuation: CheckedContinuation<Void, Never>?
    private var released = false

    func wait() async {
        guard !released else { return }
        await withCheckedContinuation { continuation = $0; started.fulfill() }
    }

    func release() {
        released = true
        continuation?.resume()
        continuation = nil
    }
}
