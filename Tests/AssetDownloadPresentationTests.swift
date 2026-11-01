import SwiftUI
import UIKit
import XCTest
@testable import ImmichApp

@MainActor
final class AssetDownloadPresentationTests: SimulatorHostedTestCase {
    private var directories: [URL] = []
    private var repositories: [HeldDownloadRepository] = []

    override func tearDown() async throws {
        repositories.forEach { $0.release() }
        try await waitUntil("Every held viewer download returns before cleanup") {
            self.repositories.allSatisfy { $0.returned }
        }
        try await super.tearDown()
        for repository in repositories {
            LocalSnapshot.remove(LocalSnapshot.Key.assetDetail(repository.detail.id))
            TemporaryMediaStore.remove(repository.file)
        }
        repositories.removeAll()
        for directory in directories { try FileManager.default.removeItem(at: directory) }
        directories.removeAll()
    }

    func testLockedAssetCannotFinishItsHeldDownloadIntoPhotos() async throws {
        try await checkRejectedDownload { fixture in
            try fixture.manager.setAssetVisibility([fixture.repository.detail.id], to: "locked")
        }
    }

    func testTrashedAssetCannotFinishItsHeldDownloadIntoPhotos() async throws {
        try await checkRejectedDownload { fixture in
            fixture.removed.remove([fixture.repository.detail.id], reason: .trashed)
        }
    }

    func testServerChangeCannotFinishItsHeldDownloadIntoPhotos() async throws {
        try await checkRejectedDownload { fixture in
            try fixture.session.setServer("https://viewer-download-after.example")
        }
    }

    func testPagingToAnotherPhotoStillFinishesTheRequestedAuthorizedDownload() async throws {
        let fixture = try await showViewer()
        try await activateSearchMenuAction(named: "Download", in: fixture.window)
        await fulfillment(of: [fixture.repository.started], timeout: 2)
        let pager = try XCTUnwrap(findPager(in: try XCTUnwrap(fixture.window.rootViewController)))
        pager.onPageChanged?(fixture.other)
        fixture.repository.release()

        try await waitUntil("Paging preserves the authorized save of the requested source") { fixture.writes.count == 1 }

        XCTAssertEqual(fixture.writes, [fixture.repository.bytes])
        XCTAssertTrue(fixture.repository.returned)
        try await waitUntil("The completed download cleans its temporary media") {
            !FileManager.default.fileExists(atPath: fixture.repository.file.path)
        }
    }

    private func checkRejectedDownload(_ revoke: (DownloadFixture) throws -> Void) async throws {
        let fixture = try await showViewer()
        try await activateSearchMenuAction(named: "Download", in: fixture.window)
        await fulfillment(of: [fixture.repository.started], timeout: 2)

        try revoke(fixture)
        fixture.repository.release()

        try await waitUntil("The rejected source download returns and cleans its temporary media") {
            fixture.repository.returned && !FileManager.default.fileExists(atPath: fixture.repository.file.path)
        }
        XCTAssertTrue(fixture.writes.isEmpty, "The actual viewer Download action must revalidate its source before calling the Photos saver")
    }

    private func showViewer() async throws -> DownloadFixture {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("viewer-download-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        directories.append(directory)
        let manager = SwiftDataManager(storeURL: directory.appendingPathComponent("test.store"),
            backupJournalURL: directory.appendingPathComponent("backup.json"))
        let session = MockSessionManager()
        try session.setServer("https://viewer-download-before.example")
        let detail = makeTestAsset(id: UUID().uuidString)
        let repository = try HeldDownloadRepository(detail: detail, session: session, directory: directory)
        repositories.append(repository)
        let fixture = DownloadFixture(repository: repository, manager: manager, session: session)
        let policy = AssetVisibilityPolicy(dataManager: manager, removed: fixture.removed)
        let model = AssetDetailViewModel(repo: repository)
        let asset = AssetLite(detail)
        let other = AssetLite(makeTestAsset(id: UUID().uuidString))
        fixture.other = other
        fixture.window = try await host(NavigationStack {
            AssetDetailView(currentAsset: asset, assets: [asset, other], visibilityPolicy: policy,
                isModal: true, viewModel: model, saveDeviceFile: { file, isVideo, isAllowed in
                    XCTAssertTrue(isAllowed())
                    XCTAssertFalse(isVideo)
                    do { fixture.writes.append(try Data(contentsOf: file)) }
                    catch { XCTFail("The Photos saver must receive its downloaded file: \(error)") }
                    return nil
                })
        }.environment(session as SessionManager).environment(\.horizontalSizeClass, .compact))
        try await waitUntil("The viewer metadata loads before its Download action") { model.detail?.id == detail.id }
        return fixture
    }

    private func findPager(in controller: UIViewController) -> PhotoPagerController? {
        if let pager = controller as? PhotoPagerController { return pager }
        return controller.children.lazy.compactMap { self.findPager(in: $0) }.first
    }
}

@MainActor
private final class DownloadFixture {
    let repository: HeldDownloadRepository
    let manager: SwiftDataManager
    let session: MockSessionManager
    let removed = RemovedAssets()
    var writes: [Data] = []
    weak var window: UIWindow!
    var other: AssetLite!

    init(repository: HeldDownloadRepository, manager: SwiftDataManager, session: MockSessionManager) {
        self.repository = repository; self.manager = manager; self.session = session
    }
}

@MainActor
private final class HeldDownloadRepository: AssetDetailRepository {
    let detail: AssetResponseDTO
    let file: URL
    let bytes: Data
    let started = XCTestExpectation(description: "The requested viewer download is held")
    private var continuation: CheckedContinuation<Void, Never>?
    private(set) var returned = false

    init(detail: AssetResponseDTO, session: SessionManager, directory: URL) throws {
        self.detail = detail
        let bytes = Data("downloaded-photo".utf8)
        self.bytes = bytes
        let source = directory.appendingPathComponent("source.png")
        try bytes.write(to: source)
        file = try TemporaryMediaStore.adoptShareFile(at: source, suggestedFilename: "download-\(UUID()).png")
        super.init(api: APIClient(session: session))
    }

    override func fetchAsset(_ id: String) async throws -> AssetResponseDTO {
        guard id == detail.id else { throw APIError.notConnected }
        return detail
    }

    override func downloadCurrentFile(_ id: String, filename: String) async throws -> URL {
        XCTAssertEqual(id, detail.id)
        await withCheckedContinuation { continuation = $0; started.fulfill() }
        returned = true
        return file
    }

    func release() { continuation?.resume(); continuation = nil }
}
