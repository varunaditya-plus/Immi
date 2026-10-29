import Photos
import SwiftUI
import XCTest
@testable import ImmichApp

@MainActor
final class SyncStatusLocalizationTests: XCTestCase {
    private var directories: [URL] = []
    private var defaultsNames: [String] = []

    override func tearDown() async throws {
        for directory in directories { try? FileManager.default.removeItem(at: directory) }
        for name in defaultsNames { UserDefaults.standard.removePersistentDomain(forName: name) }
        directories.removeAll()
        defaultsNames.removeAll()
        try await super.tearDown()
    }

    func testJobTitlesRenderUsingTheViewLocale() throws {
        let french = try frenchBundle()
        let keys = ["Sync Local", "Sync Remote", "Sync Cloud IDs", "Hash Assets"]
        let expected = keys.map { frenchValue($0, bundle: french) }
        let actualView = VStack {
            ForEach(SyncStatusJob.allCases) { job in Text(job.title) }
        }
        let expectedView = VStack {
            ForEach(Array(expected.enumerated()), id: \.offset) { Text(verbatim: $0.element) }
        }

        let expectedImage = try render(expectedView)
        XCTAssertNotEqual(expectedImage, try render(Color.clear), "The renderer must draw the translated text")
        XCTAssertEqual(try render(actualView), expectedImage,
            "Job titles must render the French catalog values instead of raw English strings")
    }

    func testIdleAndRunningSubtitlesRenderUsingTheViewLocale() throws {
        let french = try frenchBundle()
        let expected = ["Tap to run job", "Running…"].map { frenchValue($0, bundle: french) }
        let actualView = VStack {
            SyncStatusJobState.idle.subtitle
            SyncStatusJobState.running.subtitle
        }
        let expectedView = VStack {
            ForEach(Array(expected.enumerated()), id: \.offset) { Text(verbatim: $0.element) }
        }

        XCTAssertEqual(try render(actualView), try render(expectedView),
            "The job's static subtitle must use the view's locale")
    }

    func testLocalScanResultsUseLocalizedSingularAndPluralMessages() async throws {
        let usesFrench = Bundle.main.preferredLocalizations.first?.hasPrefix("fr") == true
        for amount in [0, 1, 2] {
            let fixture = try fixture(authorization: .authorized, assets: amount)

            await fixture.model.run(.syncLocal, appSync: nil)

            guard case .succeeded(_, let message) = fixture.model.state(for: .syncLocal) else {
                return XCTFail("The readable local scan must succeed")
            }
            let expected: String
            if usesFrench {
                expected = amount < 2 ? "\(amount) élément local analysé" : "\(amount) éléments locaux analysés"
            } else {
                expected = amount == 1 ? "Scanned 1 local asset" : "Scanned \(amount) local assets"
            }
            XCTAssertEqual(message, expected)
            XCTAssertEqual(fixture.access.preparations, 1)
            XCTAssertEqual(fixture.model.localAssets, amount)
            XCTAssertEqual(fixture.model.completionFeedback, 1)
            XCTAssertNil(fixture.model.runningJob)
        }
    }

    func testDeniedMaintenanceJobsUseLocalizedErrorsWithoutPreparing() async throws {
        let french = try frenchBundle()
        let usesFrench = Bundle.main.preferredLocalizations.first?.hasPrefix("fr") == true
        let cases: [(SyncStatusJob, String)] = [
            (.syncLocal, "Allow Photos access before syncing local assets."),
            (.syncCloudIDs, "Allow Photos access before syncing cloud IDs."),
            (.hashAssets, "Allow Photos access before hashing assets.")
        ]
        for (job, key) in cases {
            let fixture = try fixture(authorization: .denied)

            await fixture.model.run(job, appSync: nil)

            guard case .failed(let message) = fixture.model.state(for: job) else {
                return XCTFail("Denied Photos access must fail the maintenance job")
            }
            XCTAssertEqual(message, usesFrench ? frenchValue(key, bundle: french) : key)
            XCTAssertEqual(fixture.access.preparations, 0)
            XCTAssertEqual(fixture.model.completionFeedback, 0)
            XCTAssertNil(fixture.model.runningJob)
        }
    }

    func testInferredLocalStatusUsesTheCompiledTranslation() async throws {
        let fixture = try fixture(authorization: .authorized, assets: 2)
        let key = "Local library is available"
        let french = try frenchBundle()

        await fixture.model.loadIfNeeded()

        guard case .succeeded(nil, let message) = fixture.model.state(for: .syncLocal) else {
            return XCTFail("An authorized local library must report its existing status")
        }
        let expected = Bundle.main.preferredLocalizations.first?.hasPrefix("fr") == true
            ? frenchValue(key, bundle: french) : key
        XCTAssertEqual(message, expected)
        XCTAssertEqual(fixture.access.preparations, 0)
        XCTAssertEqual(fixture.model.completionFeedback, 0)
    }

    func testBusyAppSyncUsesLocalizedProgressAndTheStatusJobKeepsIt() async throws {
        let fixture = try fixture(authorization: .authorized)
        let api = LocalizedSyncOfflineAPI(session: MockSessionManager())
        let sync = SyncViewModel(repo: SyncRepository(api: api, dataManager: fixture.dataManager),
            dataManager: fixture.dataManager)
        sync.isSyncing = true
        let key = "A sync job is already running"
        let french = try frenchBundle()
        let expected = Bundle.main.preferredLocalizations.first?.hasPrefix("fr") == true
            ? frenchValue(key, bundle: french) : key

        let deltaSucceeded = await sync.performDeltaSync()
        XCTAssertFalse(deltaSucceeded)
        XCTAssertEqual(sync.syncProgress, expected)

        await fixture.model.run(.syncRemote, appSync: sync)

        guard case .failed(let message) = fixture.model.state(for: .syncRemote) else {
            return XCTFail("An already-running app sync must be reported by the status job")
        }
        XCTAssertEqual(message, expected)
        XCTAssertEqual(sync.syncProgress, expected)
        XCTAssertTrue(sync.isSyncing, "The refused job must not release another sync's running state")
        XCTAssertEqual(fixture.model.completionFeedback, 0)
        XCTAssertNil(fixture.model.runningJob)
    }

    private func render<Content: View>(_ content: Content) throws -> Data {
        let renderer = ImageRenderer(content: content
            .font(.body)
            .foregroundStyle(.black)
            .frame(width: 500, height: 300)
            .background(Color.white)
            .environment(\.locale, Locale(identifier: "fr")))
        renderer.scale = 1
        return try XCTUnwrap(renderer.uiImage?.pngData())
    }

    private func frenchBundle() throws -> Bundle {
        let url = try XCTUnwrap(Bundle.main.url(forResource: "fr", withExtension: "lproj"))
        return try XCTUnwrap(Bundle(url: url))
    }

    private func frenchValue(_ key: String, bundle: Bundle) -> String {
        let value = bundle.localizedString(forKey: key, value: "MISSING", table: nil)
        XCTAssertNotEqual(value, "MISSING", key)
        XCTAssertNotEqual(value, key, "This test requires a translated French value for \(key)")
        return value
    }

    private func fixture(authorization: PHAuthorizationStatus, assets: Int = 0) throws -> (
        model: SyncStatusViewModel, access: LocalizedSyncPhotosAccess, dataManager: SwiftDataManager
    ) {
        let name = "sync-status-localization-\(UUID())"
        defaultsNames.append(name)
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        directories.append(directory)
        let dataManager = SwiftDataManager(storeURL: directory.appendingPathComponent("test.store"),
            backupJournalURL: directory.appendingPathComponent("backup.json"))
        let access = LocalizedSyncPhotosAccess()
        let library = LocalPhotoLibrary(defaults: defaults, reader: .init(
            authorizationStatus: { authorization },
            requestAuthorization: { XCTFail("An established permission must not prompt again"); return authorization },
            statusCounts: { .init(assets: assets, albums: 1) }))
        let session = MockSessionManager()
        let model = SyncStatusViewModel(session: session, library: library, dataManager: dataManager,
            api: LocalizedSyncOfflineAPI(session: session), prepareLocal: { access.preparations += 1 })
        return (model, access, dataManager)
    }
}

@MainActor
private final class LocalizedSyncPhotosAccess {
    var preparations = 0
}

@MainActor
private final class LocalizedSyncOfflineAPI: APIClient {
    override func send<T: Decodable>(_ endpoint: Endpoint) async throws -> T { throw APIError.notConnected }
}
