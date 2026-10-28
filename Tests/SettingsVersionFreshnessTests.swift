import Observation
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

    func testAnOlderHeldAboutResponseCannotReplaceANewerCompletedRefresh() async throws {
        for cancelOlder in [false, true] {
            let repository = repository()
            let model = SettingsViewModel(repo: repository)
            let old = FreshVersionGate()
            repository.aboutGate = old
            repository.currentVersion = "v3.1.0"
            repository.availableVersion = "v3.2.0"
            let previous = Task { await model.loadServerInfo() }
            addTeardownBlock { await old.release(); await previous.value }
            await fulfillment(of: [old.started], timeout: 2)

            repository.aboutGate = nil
            repository.currentVersion = "v3.4.0"
            repository.availableVersion = "v3.3.0"
            await model.loadServerInfo()
            XCTAssertEqual(model.serverInfo?.version, "v3.4.0")
            XCTAssertEqual(model.latestVersion, "v3.3.0")
            if cancelOlder { previous.cancel() }
            old.release()
            await previous.value

            XCTAssertEqual(model.serverInfo?.version, "v3.4.0")
            XCTAssertEqual(model.latestVersion, "v3.3.0")
            XCTAssertFalse(model.isUpdateAvailable, "The obsolete server response must not restore a downgrade recommendation")
            if case .loaded = model.serverPhase {} else { XCTFail("The newer loaded phase must survive the older completion") }
        }
    }

    func testRequiredFieldsAreNotPublishedWhileOptionalMetadataIsStillPending() async throws {
        let repository = repository()
        let model = SettingsViewModel(repo: repository)
        await model.loadServerInfo()
        XCTAssertEqual(model.serverInfo?.version, "v3.1.0")
        let held = FreshVersionGate()
        repository.statsGate = held
        repository.currentVersion = "v3.3.0"
        repository.availableVersion = "v3.4.0"
        repository.storageLabel = "new-storage"
        repository.statsTotal = 2
        let aboutRead = expectation(description: "The new required about response is ready")
        repository.onAboutRead = { aboutRead.fulfill() }
        let partialPublication = expectation(description: "Required fields must not publish before optional results")
        partialPublication.isInverted = true
        withObservationTracking {
            _ = model.serverInfo?.version
        } onChange: {
            MainActor.assumeIsolated {
                if !held.isReleased { partialPublication.fulfill() }
            }
        }
        let refresh = Task { await model.loadServerInfo() }
        addTeardownBlock { await held.release(); await refresh.value }
        await fulfillment(of: [held.started, aboutRead], timeout: 2)
        await fulfillment(of: [partialPublication], timeout: 0.05)

        XCTAssertTrue(model.serverPhase.isLoading)
        XCTAssertEqual(model.serverInfo?.version, "v3.1.0")
        XCTAssertEqual(model.storage?.diskUse, "previous-storage")
        XCTAssertEqual(model.assetStats?.total, 1)
        XCTAssertNil(model.latestVersion)
        held.release()
        await refresh.value

        XCTAssertEqual(model.serverInfo?.version, "v3.3.0")
        XCTAssertEqual(model.storage?.diskUse, "new-storage")
        XCTAssertEqual(model.assetStats?.total, 2)
        XCTAssertEqual(model.latestVersion, "v3.4.0")
        XCTAssertTrue(model.isUpdateAvailable)
    }

    func testACanceledCurrentRequestCannotPublishARepositoryResponseThatIgnoresCancellation() async throws {
        let repository = repository()
        let model = SettingsViewModel(repo: repository)
        await model.loadServerInfo()
        let held = FreshVersionGate()
        repository.aboutGate = held
        repository.currentVersion = "v3.3.0"
        repository.availableVersion = "v3.4.0"
        let refresh = Task { await model.loadServerInfo() }
        addTeardownBlock { await held.release(); await refresh.value }
        await fulfillment(of: [held.started], timeout: 2)
        refresh.cancel()
        held.release()
        await refresh.value

        XCTAssertEqual(model.serverInfo?.version, "v3.1.0")
        XCTAssertNil(model.latestVersion)
        XCTAssertFalse(model.isUpdateAvailable)
        XCTAssertNil(model.serverPhase.errorMessage)
        if case .idle = model.serverPhase {} else { XCTFail("Cancellation must leave a nonloading, nonerror phase") }
    }

    func testAnOlderFailureCannotReplaceANewerLoadedVersionWithAnError() async throws {
        let repository = repository()
        let model = SettingsViewModel(repo: repository)
        let old = FreshVersionGate()
        repository.aboutGate = old
        repository.aboutError = APIError.server(status: 500, message: "obsolete about failure")
        let previous = Task { await model.loadServerInfo() }
        addTeardownBlock { await old.release(); await previous.value }
        await fulfillment(of: [old.started], timeout: 2)
        repository.aboutGate = nil
        repository.aboutError = nil
        repository.currentVersion = "v3.4.0"
        repository.availableVersion = "v3.5.0"

        await model.loadServerInfo()
        XCTAssertTrue(model.isUpdateAvailable)
        old.release()
        await previous.value

        XCTAssertEqual(model.serverInfo?.version, "v3.4.0")
        XCTAssertEqual(model.latestVersion, "v3.5.0")
        XCTAssertTrue(model.isUpdateAvailable)
        XCTAssertNil(model.serverPhase.errorMessage)
        if case .loaded = model.serverPhase {} else { XCTFail("An obsolete failure cannot replace the newer loaded phase") }
    }

    func testAnAlreadyCanceledCallerCannotWithdrawTheCurrentRecommendation() async throws {
        let repository = repository()
        let model = SettingsViewModel(repo: repository)
        await model.loadServerInfo()
        XCTAssertTrue(model.isUpdateAvailable)
        let admission = FreshVersionGate()
        repository.currentVersion = "v3.4.0"
        repository.availableVersion = "v3.5.0"
        let canceled = Task {
            await admission.wait()
            await model.loadServerInfo()
        }
        addTeardownBlock { await admission.release(); await canceled.value }
        await fulfillment(of: [admission.started], timeout: 2)
        canceled.cancel()
        admission.release()
        await canceled.value

        XCTAssertEqual(model.serverInfo?.version, "v3.1.0")
        XCTAssertEqual(model.latestVersion, "v3.2.0")
        XCTAssertTrue(model.isUpdateAvailable)
        if case .loaded = model.serverPhase {} else { XCTFail("An unadmitted caller must leave the current phase alone") }
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
    var statsGate: FreshVersionGate?
    var storageLabel = "previous-storage"
    var statsTotal = 1
    var onAboutRead: (() -> Void)?

    override func getServerInfo() async throws -> ServerAboutDTO {
        let version = currentVersion
        let error = aboutError
        if let aboutGate { await aboutGate.wait() }
        onAboutRead?()
        if let error { throw error }
        return .init(version: version, versionUrl: nil)
    }

    override func getStorageInfo() async throws -> ServerStorageDTO {
        if let storageError { throw storageError }
        return .init(diskUse: storageLabel, diskSize: nil, diskUseRaw: nil, diskSizeRaw: nil, diskUsagePercentage: nil)
    }

    override func getAssetStats() async throws -> AssetStatsDTO {
        let total = statsTotal
        if let statsGate { await statsGate.wait() }
        return .init(images: total, videos: 0, total: total)
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
    var isReleased: Bool { released }

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
