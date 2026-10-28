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
