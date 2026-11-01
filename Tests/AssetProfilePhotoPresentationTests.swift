import SwiftData
import SwiftUI
import UIKit
import XCTest
@testable import ImmichApp

@MainActor
final class AssetProfilePhotoPresentationTests: SimulatorHostedTestCase {
    private var fixtures: [ProfilePhotoFixture] = []
    private var converters: [PeopleStateGate<Data?>] = []

    override func tearDown() async throws {
        converters.forEach { $0.complete(.success(nil)) }
        fixtures.forEach { $0.repository.upload.complete(.failure(CancellationError())) }
        try await waitUntil("All requested profile preparations finish before cleanup") {
            self.fixtures.allSatisfy { $0.repository.downloads == 0 || !FileManager.default.fileExists(atPath: $0.repository.file.path) }
        }
        try await super.tearDown()
        for fixture in fixtures {
            LocalSnapshot.remove(LocalSnapshot.Key.assetDetail(fixture.repository.detail.id))
            for id in [fixture.repository.detail.id, fixture.other.id] {
                for (kind, size) in [("thumbnail", 600), ("preview", 2048)] {
                    ImageMemoryCache.shared.remove(for: ImageCache.memoryKey("\(id)-\(kind)", size))
                }
            }
            TemporaryMediaStore.remove(fixture.repository.file)
            try fixture.manager.modelContainer.erase()
            try FileManager.default.removeItem(at: fixture.directory)
        }
        fixtures.removeAll()
        converters.removeAll()
    }

    func testCurrentProfileActionConvertsTheActualPhotoToSquareJPEGUploadsAndRefreshesTheUser() async throws {
        let fixture = try await showViewer()
        fixture.repository.upload.complete(.success(()))

        try await activateSearchMenuAction(named: "Set as Profile Photo", in: fixture.window)

        try await waitUntil("The normal profile action uploads and refreshes the current user") { fixture.session.refreshes == 1 }
        XCTAssertEqual(fixture.repository.uploads.count, 1)
        let image = try XCTUnwrap(UIImage(data: try XCTUnwrap(fixture.repository.uploads.first)))
        XCTAssertEqual(image.size.width, 60)
        XCTAssertEqual(image.size.height, 60)
        XCTAssertEqual(fixture.repository.uploads.first?.prefix(2), Data([0xff, 0xd8]))
        XCTAssertEqual(fixture.repository.filenames, ["profile.jpg"])
        XCTAssertNil(fixture.model.actionError)
        try await waitUntil("The completed profile action removes its prepared source") {
            !FileManager.default.fileExists(atPath: fixture.repository.file.path)
        }
    }

    func testHeldConversionCannotUploadAfterTheSameServerGetsANewRequestRevision() async throws {
        try await checkHeldConversion { fixture in try fixture.session.setServer(ProfilePhotoFixture.server) }
    }

    func testHeldConversionCannotUploadAfterThePhotoBecomesPrivate() async throws {
        try await checkHeldConversion { fixture in
            try fixture.manager.setAssetVisibility([fixture.repository.detail.id], to: "locked")
        }
    }

    func testHeldConversionCannotUploadAfterTheSelectedSourceChanges() async throws {
        try await checkHeldConversion { fixture in
            let pager = try XCTUnwrap(self.pager(in: fixture.window.rootViewController))
            pager.onPageChanged?(fixture.other)
        }
    }

    func testAStaleConversionFailureCannotPublishFeedbackInTheNewSession() async throws {
        try await checkHeldConversion(result: nil) { fixture in try fixture.session.setServer(ProfilePhotoFixture.server) }
    }

    func testAStaleSuccessfulUploadCannotRefreshTheReplacementSession() async throws {
        try await checkHeldUpload(result: .success(()))
    }

    func testAStaleUploadFailureCannotPublishFeedbackInTheReplacementSession() async throws {
        try await checkHeldUpload(result: .failure(APIError.server(status: 500, message: "Obsolete upload failure")))
    }

    func testCurrentUploadFailureStillPublishesFeedbackWithoutRefreshingTheUser() async throws {
        let fixture = try await showViewer()
        fixture.repository.upload.complete(.failure(APIError.server(status: 500, message: "Current upload failure")))

        try await activateSearchMenuAction(named: "Set as Profile Photo", in: fixture.window)

        try await waitUntil("The admitted profile upload reports its real failure") { fixture.model.actionError != nil }
        XCTAssertEqual(fixture.repository.uploads.count, 1)
        XCTAssertEqual(fixture.session.refreshes, 0)
    }

    private func checkHeldConversion(result: Data? = Data([0xff, 0xd8, 0xff]),
                                     revoke: (ProfilePhotoFixture) throws -> Void) async throws {
        let held = PeopleStateGate<Data?>()
        converters.append(held)
        let fixture = try await showViewer(converter: { file in
            XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
            return try? await held.value()
        })
        try await activateSearchMenuAction(named: "Set as Profile Photo", in: fixture.window)
        await fulfillment(of: [held.started], timeout: 2)
        XCTAssertEqual(fixture.repository.downloads, 1)
        XCTAssertTrue(fixture.repository.uploads.isEmpty)
        let generation = LocalSnapshot.generation

        try revoke(fixture)
        XCTAssertEqual(LocalSnapshot.generation, generation)
        held.complete(.success(result))

        try await waitUntil("The invalidated profile conversion returns and its file is removed") {
            !FileManager.default.fileExists(atPath: fixture.repository.file.path)
        }
        XCTAssertTrue(fixture.repository.uploads.isEmpty)
        XCTAssertEqual(fixture.session.refreshes, 0)
        XCTAssertNil(fixture.model.actionError)
    }

    private func checkHeldUpload(result: Result<Void, Error>) async throws {
        let fixture = try await showViewer()
        try await activateSearchMenuAction(named: "Set as Profile Photo", in: fixture.window)
        await fulfillment(of: [fixture.repository.upload.started], timeout: 2)
        XCTAssertEqual(fixture.repository.uploads.count, 1)
        let generation = LocalSnapshot.generation, context = fixture.session.snapshot

        try fixture.session.setServer(ProfilePhotoFixture.server)
        XCTAssertEqual(LocalSnapshot.generation, generation)
        XCTAssertNotEqual(fixture.session.snapshot, context)
        fixture.repository.upload.complete(result)

        try await waitUntil("The stale upload response finishes without retaining the source") {
            !FileManager.default.fileExists(atPath: fixture.repository.file.path)
        }
        XCTAssertEqual(fixture.repository.uploads.count, 1)
        XCTAssertEqual(fixture.session.refreshes, 0)
        XCTAssertNil(fixture.model.actionError)
    }

    private func showViewer(converter: (@MainActor (URL) async -> Data?)? = nil) async throws -> ProfilePhotoFixture {
        let fixture = try ProfilePhotoFixture()
        fixtures.append(fixture)
        let image = try XCTUnwrap(UIImage(data: fixture.repository.bytes))
        for id in [fixture.repository.detail.id, fixture.other.id] {
            for (kind, size) in [("thumbnail", 600), ("preview", 2048)] {
                ImageMemoryCache.shared.insert(image, for: ImageCache.memoryKey("\(id)-\(kind)", size))
            }
        }
        let asset = AssetLite(fixture.repository.detail)
        fixture.window = try await host(NavigationStack {
            AssetDetailView(currentAsset: asset, assets: [asset, fixture.other],
                visibilityPolicy: AssetVisibilityPolicy(dataManager: fixture.manager),
                isModal: true, viewModel: fixture.model, profileImageData: converter)
        }.environment(fixture.session as SessionManager).environment(\.horizontalSizeClass, .compact))
        try await waitUntil("The real viewer metadata is ready before the profile action") {
            fixture.model.detail?.id == asset.id
        }
        return fixture
    }

    private func pager(in controller: UIViewController?) -> PhotoPagerController? {
        guard let controller else { return nil }
        if let pager = controller as? PhotoPagerController { return pager }
        return controller.children.lazy.compactMap { self.pager(in: $0) }.first
    }
}

@MainActor
private final class ProfilePhotoFixture {
    static let server = "https://profile-action.example.invalid"
    let directory: URL
    let manager: SwiftDataManager
    let session: ProfilePhotoSession
    let repository: ProfilePhotoRepository
    let model: AssetDetailViewModel
    let other = AssetLite(makeTestAsset(id: UUID().uuidString))
    weak var window: UIWindow!

    init() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("profile-action-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        manager = SwiftDataManager(storeURL: directory.appendingPathComponent("test.store"),
            backupJournalURL: directory.appendingPathComponent("backup.json"))
        session = ProfilePhotoSession()
        try session.setServer(Self.server)
        session.isLoggedIn = true
        repository = try ProfilePhotoRepository(session: session, directory: directory)
        model = AssetDetailViewModel(repo: repository)
    }
}

@MainActor
private final class ProfilePhotoSession: MockSessionManager {
    private(set) var refreshes = 0
    override func refreshUser() async { refreshes += 1 }
}

@MainActor
private final class ProfilePhotoRepository: AssetDetailRepository {
    let detail = makeTestAsset(id: UUID().uuidString)
    let file: URL
    let bytes: Data
    let upload: PeopleStateGate<Void>
    private(set) var downloads = 0
    private(set) var uploads: [Data] = []
    private(set) var filenames: [String] = []

    init(session: SessionManager, directory: URL) throws {
        upload = PeopleStateGate<Void>()
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        bytes = try XCTUnwrap(UIGraphicsImageRenderer(size: CGSize(width: 90, height: 60), format: format).image { context in
            UIColor.green.setFill(); context.fill(CGRect(x: 0, y: 0, width: 90, height: 60))
        }.pngData())
        let source = directory.appendingPathComponent("source.png")
        try bytes.write(to: source)
        file = try TemporaryMediaStore.adoptShareFile(at: source, suggestedFilename: "Profile Source.png")
        super.init(api: APIClient(session: session))
    }

    override func fetchAsset(_ id: String) async throws -> AssetResponseDTO {
        guard id == detail.id else { throw APIError.notConnected }
        return detail
    }

    override func downloadCurrentFile(_ id: String, filename: String) async throws -> URL {
        XCTAssertEqual(id, detail.id)
        downloads += 1
        return file
    }

    override func setProfileImage(_ data: Data, filename: String) async throws {
        uploads.append(data)
        filenames.append(filename)
        try await upload.value()
    }
}
