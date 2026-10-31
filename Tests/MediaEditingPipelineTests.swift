import AVFoundation
import CryptoKit
import ImageIO
import SwiftData
import UIKit
import UniformTypeIdentifiers
import XCTest
@testable import ImmichApp

@MainActor
final class MediaEditingPipelineTests: XCTestCase {
    private var directory: URL!
    private var defaultsName = ""
    private var transport: URLSession!
    private var session: PipelineEditingSession!
    private var store: MediaEditStore!
    private var pipeline: MediaEditingPipeline!
    private var api: PipelineEditingAPI!
    private var owned: [URL] = []
    private var assetID = ""
    private let owner = PipelineEditingOwner()
    private var mappingServerIDs: [String] = []
    private var mappingLocalIDs: [String] = []

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("editing-pipeline-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defaultsName = "MediaEditingPipelineTests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: defaultsName))
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        transport = URLSession(configuration: configuration)
        MockURLProtocol.reset()
        let owner = owner
        MockURLProtocol.responseProvider = { request in
            let data: Data
            switch request.url?.path {
            case "/api/server/ping": data = Data("{\"res\":\"pong\"}".utf8)
            case "/api/users/me":
                let user = owner.id
                data = Data("{\"id\":\"\(user)\",\"email\":\"synthetic@example.invalid\",\"name\":\"Synthetic\"}".utf8)
            default: return (nil, nil, URLError(.unsupportedURL))
            }
            return (data, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil), nil)
        }
        let shared = SharedSessionTestStorage()
        session = PipelineEditingSession(urlSession: transport, defaults: defaults,
            dataManager: SwiftDataManager(storeURL: directory.appendingPathComponent("test.store"),
                backupJournalURL: directory.appendingPathComponent("backup.json")),
            credentialStore: PipelineEditingCredentials(), sharedSessionStore: shared.store(), restoresSession: false)
        try session.setServer("https://editing-pipeline.example.invalid")
        try await signIn()
        XCTAssertEqual(session.backupQueueOwner?.userID, owner.id)
        store = MediaEditStore(directory: directory.appendingPathComponent("edits"))
        store.configure(session: session)
        pipeline = MediaEditingPipeline(store: store)
        api = PipelineEditingAPI(session: session)
        assetID = "pipeline-\(UUID())"
        api.data = try imageData()
    }

    override func tearDown() async throws {
        api?.beforeCheck = nil
        api?.dataGate?.release()
        TemporaryMediaStore.remove(owned)
        for serverID in mappingServerIDs {
            let descriptor = FetchDescriptor<BackupRecord>(predicate: #Predicate { $0.assetId == serverID })
            for record in try SwiftDataManager.shared.modelContext.fetch(descriptor) {
                SwiftDataManager.shared.modelContext.delete(record)
            }
        }
        try SwiftDataManager.shared.modelContext.save()
        for localID in mappingLocalIDs { try SwiftDataManager.shared.unlinkDeviceAsset(localIdentifier: localID) }
        LocalSnapshot.remove(LocalSnapshot.Key.assetDetail(assetID))
        transport?.invalidateAndCancel()
        MockURLProtocol.reset()
        UserDefaults.standard.removePersistentDomain(forName: defaultsName)
        try FileManager.default.removeItem(at: directory)
    }

    func testSavedPhotoRewritesServerPreviewToOriginalAndAppliesRealCropAndExposure() async throws {
        try save(editedDocument())
        let data = try await pipeline.imageData(thumbnail(), api: api)
        let request = try XCTUnwrap(api.dataRequests.first)
        XCTAssertEqual(api.dataRequests.count, 1)
        XCTAssertEqual(request.path, "/assets/\(assetID)/thumbnail")
        XCTAssertEqual(request.query.filter { $0.name == "edited" }.map(\.value), ["false"])
        XCTAssertEqual(request.query.filter { $0.name == "cropped" }.map(\.value), ["false"])
        XCTAssertEqual(request.query.filter { $0.name == "size" }.map(\.value), ["preview"])
        let image = try decoded(data)
        XCTAssertEqual([image.width, image.height], [40, 40])
        let pixel = try color(image)
        XCTAssertGreaterThan(pixel[0], 170, "Positive exposure must brighten the original gray crop")
        XCTAssertEqual(pixel[0], pixel[1], accuracy: 3)
        XCTAssertEqual(pixel[1], pixel[2], accuracy: 3)
        XCTAssertEqual(try color(decoded(api.data))[0], 128, accuracy: 3)
    }

    func testNoRecipeKeepsCurrentRequestWhileIdentityOverrideRequestsUneditedMedia() async throws {
        let request = thumbnail()
        let unchanged = try await pipeline.imageData(request, api: api)
        XCTAssertEqual(unchanged, api.data)
        XCTAssertEqual(api.dataRequests.first?.query, request.query)
        try save(MediaEditDocument())
        let identity = try await pipeline.imageData(request, api: api)
        let image = try decoded(identity)
        XCTAssertEqual([image.width, image.height], [80, 40])
        XCTAssertEqual(try color(image)[0], 128, accuracy: 3)
        XCTAssertEqual(api.dataRequests.last?.query.first { $0.name == "edited" }?.value, "false",
            "An explicit identity recipe overrides server edits instead of redisplaying the edited rendition")
        api.dataRequests.removeAll()
        let explicitOriginal = Endpoint(path: request.path, query: [.init(name: "edited", value: "false")])
        let original = try await pipeline.imageData(explicitOriginal, api: api)
        XCTAssertEqual(original, api.data)
        XCTAssertEqual(api.dataRequests.first?.query, explicitOriginal.query)
    }

    func testCurrentFileContainsEditsWhileOriginalDownloadAndSourceStayUnchanged() async throws {
        try save(editedDocument())
        let repository = AssetDetailRepository(api: api)
        let original = try await repository.downloadOriginalFile(assetID, filename: "\(assetID).png")
        owned.append(original)
        let originalBytes = try Data(contentsOf: original)
        let current = try await pipeline.currentFile(original, assetID: assetID, api: api)
        owned.append(current)
        XCTAssertNotEqual(current, original)
        XCTAssertEqual(api.fileRequests.map(\.path), ["/assets/\(assetID)/original"])
        XCTAssertEqual(api.fileRequests.first?.query.first { $0.name == "edited" }?.value, "false")
        XCTAssertEqual(originalBytes, api.data)
        XCTAssertEqual(try Data(contentsOf: original), originalBytes)
        XCTAssertTrue(api.downloads.allSatisfy { !FileManager.default.fileExists(atPath: $0.path) })
        let image = try decoded(Data(contentsOf: current))
        XCTAssertEqual([image.width, image.height], [40, 40])
        XCTAssertGreaterThan(try color(image)[0], 170)
    }

    func testCurrentLiveStillsAreUnpairedJPEGsWhileLoopRemainsADecodableMovie() async throws {
        let motion = try await makeVideoEditingFixture(in: directory)
        let motionBytes = try Data(contentsOf: motion)
        let motionID = "motion-\(UUID())"
        api.fileBytesByID[motionID] = motionBytes
        api.fileMIMETypesByID[motionID] = "video/quicktime"
        let source = directory.appendingPathComponent("original-live.jpg")
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(source as CFURL,
            UTType.jpeg.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try decoded(api.data),
            [kCGImagePropertyMakerAppleDictionary: ["17": UUID().uuidString]] as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        let sourceBytes = try Data(contentsOf: source)
        let input = try XCTUnwrap(CGImageSourceCreateWithURL(source as CFURL, nil))
        let inputProperties = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(input, 0, nil) as? [String: Any])
        XCTAssertNotNil((inputProperties[kCGImagePropertyMakerAppleDictionary as String] as? [String: Any])?["17"])
        for mode in [LivePhotoEditRecipe.Mode.live, .off, .longExposure, .loop] {
            var document = MediaEditDocument(); document.kind = .livePhoto
            document.motionAssetID = motionID; document.live.mode = mode; document.photo[.exposure] = 0.25
            try save(document)
            let before = Set(try managedShareFiles { _ in true })
            let current = try await pipeline.currentFile(source, assetID: assetID, api: api)
            owned.append(current)
            let remaining = Set(try managedShareFiles { _ in true }).subtracting(before)
            XCTAssertEqual(remaining, [current], "Only the single public Current resource should remain owned")
            if mode == .loop {
                let asset = AVURLAsset(url: current)
                let duration = try await asset.load(.duration).seconds
                XCTAssertEqual(duration, 6, accuracy: 0.05)
                let generator = AVAssetImageGenerator(asset: asset)
                generator.appliesPreferredTrackTransform = true
                let frame = try await generator.image(at: .zero).image
                XCTAssertEqual([frame.width, frame.height], [16, 32])
            } else {
                let image = try XCTUnwrap(CGImageSourceCreateWithURL(current as CFURL, nil))
                XCTAssertEqual(CGImageSourceGetType(image) as String?, UTType.jpeg.identifier)
                let properties = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(image, 0, nil) as? [String: Any])
                XCTAssertNil((properties[kCGImagePropertyMakerAppleDictionary as String] as? [String: Any])?["17"],
                    "A standalone exported still cannot claim to have a matching Live Photo movie")
                XCTAssertNotNil(CGImageSourceCreateImageAtIndex(image, 0, nil))
            }
            XCTAssertEqual(try Data(contentsOf: source), sourceBytes)
            XCTAssertEqual(try Data(contentsOf: motion), motionBytes)
            XCTAssertTrue(api.downloads.allSatisfy { !FileManager.default.fileExists(atPath: $0.path) })
            TemporaryMediaStore.remove(current)
        }
    }

    func testEditingOneAssetOnlyChangesThatAssetsCacheKey() throws {
        let other = "other-\(UUID())"
        XCTAssertEqual(pipeline.cacheKey("thumb-a", assetID: assetID, session: session), "thumb-a")
        try save(editedDocument())
        let first = pipeline.cacheKey("thumb-a", assetID: assetID, session: session)
        XCTAssertNotEqual(first, "thumb-a")
        XCTAssertEqual(pipeline.cacheKey("thumb-b", assetID: other, session: session), "thumb-b")
        var replacement = editedDocument(); replacement.photo[.exposure] = -0.5
        try save(replacement)
        let changed = pipeline.cacheKey("thumb-a", assetID: assetID, session: session)
        XCTAssertNotEqual(changed, first)
        try save(editedDocument(), id: other)
        XCTAssertEqual(pipeline.cacheKey("thumb-a", assetID: assetID, session: session), changed)
        XCTAssertNotEqual(pipeline.cacheKey("thumb-b", assetID: other, session: session), "thumb-b")
    }

    func testIdenticalRecipeOnAReplacementOriginalInvalidatesOnlyItsEditedCacheKey() throws {
        let document = editedDocument()
        try save(document)
        let first = pipeline.cacheKey("thumbnail", assetID: assetID, session: session)
        let unrelated = "unrelated-\(UUID())"
        let otherKey = pipeline.cacheKey("other-thumbnail", assetID: unrelated, session: session)
        let token = try store.capture(assetID: assetID, sourceFingerprint: "replacement-original-fixture")
        try store.save(MediaEditRecord(type: MediaEditingPipeline.recordType,
            schemaVersion: MediaEditingPipeline.schemaVersion, sourceFingerprint: token.sourceFingerprint,
            value: document), using: token)

        XCTAssertEqual(try pipeline.savedEdit(for: assetID, session: session)?.document, document)
        XCTAssertNotEqual(pipeline.cacheKey("thumbnail", assetID: assetID, session: session), first,
            "Reusing the recipe must not reuse pixels rendered from a different original")
        XCTAssertEqual(pipeline.cacheKey("other-thumbnail", assetID: unrelated, session: session), otherKey)
    }

    func testMappedAliasesShareTheLocalFallbackAndCanonicalConflictIncludingIdentityOverride() async throws {
        let local = "pipeline-alias-\(UUID())/L0/001"
        let deviceID = LocalPhotoLibrary.assetID(for: local)
        try mapping(local, serverID: assetID)
        let localEdit = editedDocument()
        try save(localEdit, id: deviceID)
        for id in [deviceID, assetID] {
            let saved = try XCTUnwrap(pipeline.savedEdit(for: id, session: session))
            XCTAssertEqual(saved.assetID, deviceID)
            XCTAssertEqual(saved.document, localEdit)
        }
        var serverEdit = editedDocument(); serverEdit.photo[.exposure] = -0.5
        try save(serverEdit)
        for id in [deviceID, assetID] {
            let saved = try XCTUnwrap(pipeline.savedEdit(for: id, session: session))
            XCTAssertEqual(saved.assetID, assetID)
            XCTAssertEqual(saved.document, serverEdit, "Both aliases must choose the same existing canonical recipe")
        }
        try save(MediaEditDocument())
        for id in [deviceID, assetID] {
            XCTAssertTrue(try XCTUnwrap(pipeline.savedEdit(for: id, session: session)).document.isIdentity,
                "Canonical Revert must override the older nonidentity device recipe for both aliases")
        }
        XCTAssertEqual(pipeline.cacheKey("thumbnail", assetID: deviceID, session: session),
            pipeline.cacheKey("thumbnail", assetID: assetID, session: session))
        let original = try await pipeline.imageData(thumbnail(), api: api)
        XCTAssertEqual(try decoded(original).width, 80)
        XCTAssertEqual(try color(decoded(original))[0], 128, accuracy: 3)
    }

    func testRemappingOrUnlinkingAnAliasAfterRenderingRejectsAndCleansTheRealOutput() async throws {
        for unlink in [false, true] {
            let local = "pipeline-late-alias-\(UUID())/L0/001"
            let deviceID = LocalPhotoLibrary.assetID(for: local)
            let serverID = "pipeline-canonical-\(UUID())"
            try mapping(local, serverID: serverID)
            try save(editedDocument(), id: serverID)
            let captured = try XCTUnwrap(pipeline.savedEdit(for: deviceID, session: session))
            let source = directory.appendingPathComponent("\(serverID).png")
            try api.data.write(to: source)
            let bytes = try Data(contentsOf: source)
            var produced: [URL] = []
            api.beforeCheck = { [self] in
                produced = try managedShareFiles { $0.lastPathComponent == source.lastPathComponent }
                if unlink { try SwiftDataManager.shared.unlinkDeviceAsset(localIdentifier: local) }
                else { try mapping(local, serverID: "replacement-\(UUID())") }
            }
            do {
                _ = try await pipeline.currentFile(source, assetID: deviceID, api: api, saved: captured)
                XCTFail("A prepared edit cannot publish bytes under a changed alias")
            } catch { XCTAssertEqual(error as? MediaEditStoreError, .sourceChanged) }
            owned += produced
            XCTAssertEqual(produced.count, 1, "The alias must change after a real file was rendered")
            XCTAssertTrue(produced.allSatisfy { !FileManager.default.fileExists(atPath: $0.path) })
            XCTAssertEqual(try Data(contentsOf: source), bytes)
        }
    }

    private func mapping(_ localID: String, serverID: String) throws {
        mappingLocalIDs.append(localID)
        mappingServerIDs.append(serverID)
        try SwiftDataManager.shared.upsertBackupRecord(assetID: serverID, checksum: "synthetic", localIdentifier: localID)
        XCTAssertEqual(SwiftDataManager.shared.getBackupRecord(localIdentifier: localID)?.assetId, serverID)
    }

    func testSavedEditsSurviveReloginAndStayIsolatedFromAnotherOwner() async throws {
        let document = editedDocument()
        try save(document)
        let firstKey = pipeline.cacheKey("thumbnail", assetID: assetID, session: session)
        owner.id = "owner-b"
        try await signIn()
        XCTAssertNil(try pipeline.savedEdit(for: assetID, session: session))
        XCTAssertEqual(pipeline.cacheKey("thumbnail", assetID: assetID, session: session), "thumbnail")
        owner.id = "owner-a"
        try await signIn()
        XCTAssertEqual(try pipeline.savedEdit(for: assetID, session: session)?.document, document)
        XCTAssertEqual(pipeline.cacheKey("thumbnail", assetID: assetID, session: session), firstKey)
        let reopened = MediaEditingPipeline(store: MediaEditStore(directory: directory.appendingPathComponent("edits")))
        XCTAssertEqual(try reopened.savedEdit(for: assetID, session: session)?.document, document)
    }

    func testDisplayGeometryMatchesRealCropRotationAndFramingFromTheOriginalAspect() async throws {
        var document = MediaEditDocument()
        document.sourceAspectRatio = 2
        document.photo.crop = CGRect(x: 0, y: 0, width: 0.5, height: 1)
        document.photo.quarterTurns = 1
        document.photo.framing = CGRect(x: 0, y: 0, width: 0.5, height: 1)
        try save(document)
        let asset = AssetLite(id: assetID, isVideo: false, ratio: 1 / 3, thumbhash: "original-hash",
            createdAt: Date(timeIntervalSince1970: 1_000), isFavorite: true)

        let displayed = pipeline.displayAsset(asset, session: session)
        let source = try XCTUnwrap(UIImage(data: api.data))
        let rendered = try await PhotoEditRenderer.shared.renderPreview(source, recipe: document.photo)
        let pixels = try XCTUnwrap(rendered.cgImage)

        XCTAssertEqual([pixels.width, pixels.height], [20, 40])
        XCTAssertEqual(displayed.ratio, 0.5, accuracy: 0.0001)
        XCTAssertEqual(displayed.ratio, Double(pixels.width) / Double(pixels.height), accuracy: 0.0001)
        XCTAssertEqual(displayed.id, asset.id)
        XCTAssertEqual(displayed.createdAt, asset.createdAt)
        XCTAssertTrue(displayed.isFavorite)
        XCTAssertEqual(displayed.thumbhash, asset.thumbhash)
        XCTAssertEqual(asset.ratio, 1 / 3, accuracy: 0.0001, "Display geometry must not mutate the server snapshot")
    }

    func testOrientedOriginalAspectMatchesTheEditedFileAndDisplayGeometry() async throws {
        let source = directory.appendingPathComponent("oriented-original.jpg")
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(source as CFURL,
            UTType.jpeg.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try decoded(api.data), [kCGImagePropertyOrientation: 6] as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        let original = try Data(contentsOf: source)
        let aspect = try await MediaEditingPipeline.sourceAspectRatio(source, isVideo: false)
        XCTAssertEqual(aspect, 0.5, accuracy: 0.0001, "EXIF rotation must be applied exactly once")
        var document = MediaEditDocument(); document.sourceAspectRatio = aspect; document.photo.quarterTurns = 1
        try save(document)
        let asset = AssetLite(id: assetID, isVideo: false, ratio: 2, thumbhash: nil, createdAt: .now)
        let displayed = pipeline.displayAsset(asset, session: session)
        let file = try await pipeline.currentFile(source, assetID: assetID, api: api)
        owned.append(file)
        let pixels = try decoded(Data(contentsOf: file))
        XCTAssertEqual([pixels.width, pixels.height], [80, 40])
        XCTAssertEqual(displayed.ratio, 2, accuracy: 0.0001)
        XCTAssertEqual(displayed.ratio, Double(pixels.width) / Double(pixels.height), accuracy: 0.0001)
        XCTAssertEqual(try Data(contentsOf: source), original)
    }

    func testDisplayVideoDurationMatchesActualTrimmedAndRetimedOutput() async throws {
        let source = try await makePagerPlaybackMovie()
        defer { try? FileManager.default.removeItem(at: source) }
        var document = MediaEditDocument(); document.kind = .video
        document.video.trimStart = 1; document.video.trimEnd = 2.5; document.video.rate = 2
        try save(document)
        let asset = AssetLite(id: assetID, isVideo: true, ratio: 1, thumbhash: nil, createdAt: .now,
            duration: 3)
        let displayed = pipeline.displayAsset(asset, session: session)
        let file = try await pipeline.currentFile(source, assetID: assetID, api: api)
        owned.append(file)
        let duration = try await AVURLAsset(url: file).load(.duration).seconds
        XCTAssertEqual(try XCTUnwrap(displayed.duration), 0.75, accuracy: 0.001)
        XCTAssertEqual(duration, 0.75, accuracy: 0.04)
        XCTAssertEqual(asset.duration, 3)
        XCTAssertTrue(displayed.isVideo)
        XCTAssertEqual(displayed.ratio, 1)
    }

    func testOriginalValidationHashesActualFileBytesAndLeavesBothMatchingAndMismatchingSourcesUntouched() async throws {
        let file = directory.appendingPathComponent("original-checksum.png")
        try api.data.write(to: file)
        let before = try Data(contentsOf: file)
        let checksum = Data(Insecure.SHA1.hash(data: before)).base64EncodedString()
        try await MediaEditingPipeline.validateOriginal(file, checksum: checksum)
        XCTAssertEqual(try Data(contentsOf: file), before)
        do {
            try await MediaEditingPipeline.validateOriginal(file, checksum: Data(repeating: 0, count: 20).base64EncodedString())
            XCTFail("A valid SHA1 for a different original must be rejected")
        } catch { XCTAssertEqual(error as? MediaEditStoreError, .sourceChanged) }
        XCTAssertEqual(try Data(contentsOf: file), before)
    }

    func testUnavailableOrUnsupportedChecksumFallsBackWithoutReadingOrChangingTheOriginal() async throws {
        let missing = directory.appendingPathComponent("not-downloaded.png")
        for checksum in [nil, "", "not-base64", Data(repeating: 1, count: 32).base64EncodedString()] as [String?] {
            try await MediaEditingPipeline.validateOriginal(missing, checksum: checksum)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: missing.path))
        let file = directory.appendingPathComponent("known-source.png")
        try api.data.write(to: file)
        try await MediaEditingPipeline.validateOriginal(file, checksum: nil)
        XCTAssertEqual(try Data(contentsOf: file), api.data)
    }

    func testHeldPreviewRejectsChangedRecipeAndChangedSessionInsteadOfReturningOldPixels() async throws {
        for changeSession in [false, true] {
            try save(editedDocument())
            api = PipelineEditingAPI(session: session); api.data = try imageData()
            let gate = PipelineEditingGate(); api.dataGate = gate
            let operation = Task { try await pipeline.imageData(thumbnail(), api: api) }
            await fulfillment(of: [gate.started], timeout: 2)
            if changeSession { try session.setServer("https://replacement-editing.example.invalid") }
            else { var newer = editedDocument(); newer.photo[.exposure] = -0.5; try save(newer) }
            gate.release()
            do { _ = try await operation.value; XCTFail("Held pixels must be rejected after the source context changes") }
            catch is CancellationError { XCTAssertTrue(changeSession) }
            catch { XCTAssertFalse(changeSession); XCTAssertEqual(error as? MediaEditStoreError, .editChanged) }
        }
    }

    func testAChangedOriginalFingerprintRejectsTheSavedRecipe() async throws {
        try save(editedDocument())
        let changed = makeTestAsset(id: assetID, originalFileName: "new-original.png")
        LocalSnapshot.save(changed, for: LocalSnapshot.Key.assetDetail(assetID))
        do { _ = try await pipeline.imageData(thumbnail(), api: api); XCTFail("A recipe cannot render a replacement original") }
        catch { XCTAssertEqual(error as? MediaEditStoreError, .sourceChanged) }
    }

    func testRejectedRenderedFilesAreRemovedWithoutDeletingTheSource() async throws {
        try save(editedDocument())
        let source = directory.appendingPathComponent("\(assetID).png")
        try api.data.write(to: source)
        let bytes = try Data(contentsOf: source)
        var produced: [URL] = []
        api.beforeCheck = { [self] in
            produced = try managedShareFiles { $0.lastPathComponent == source.lastPathComponent }
            try session.setServer("https://replacement-render.example.invalid")
        }
        do { _ = try await pipeline.currentFile(source, assetID: assetID, api: api); XCTFail("The late account change must reject rendered output") }
        catch is CancellationError {}
        owned += produced
        XCTAssertEqual(produced.count, 1, "The invalidation must happen after a real edited file was generated")
        XCTAssertTrue(produced.allSatisfy { !FileManager.default.fileExists(atPath: $0.path) })
        XCTAssertEqual(try Data(contentsOf: source), bytes)
    }

    private func signIn() async throws {
        try await session.checkServerCompatibility()
        try await session.loginApiKey("synthetic-pipeline-test-key")
    }

    private func save(_ document: MediaEditDocument, id: String? = nil) throws {
        let id = id ?? assetID
        let token = try store.capture(assetID: id, sourceFingerprint: "original-fixture")
        try store.save(MediaEditRecord(type: MediaEditingPipeline.recordType,
            schemaVersion: MediaEditingPipeline.schemaVersion, sourceFingerprint: token.sourceFingerprint,
            value: document), using: token)
    }

    private func editedDocument() -> MediaEditDocument {
        var document = MediaEditDocument()
        document.photo.crop = CGRect(x: 0, y: 0, width: 0.5, height: 1)
        document.photo[.exposure] = 0.5
        return document
    }

    private func thumbnail() -> Endpoint {
        Endpoint(path: "/assets/\(assetID)/thumbnail", query: [.init(name: "edited", value: "true"),
            .init(name: "cropped", value: "true"), .init(name: "size", value: "thumbnail")])
    }

    private func imageData() throws -> Data {
        let context = try XCTUnwrap(CGContext(data: nil, width: 80, height: 40, bitsPerComponent: 8, bytesPerRow: 320,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        context.setFillColor(UIColor(red: 128 / 255, green: 128 / 255, blue: 128 / 255, alpha: 1).cgColor)
        context.fill(CGRect(x: 0, y: 0, width: 80, height: 40))
        context.setFillColor(UIColor.red.cgColor); context.fill(CGRect(x: 40, y: 0, width: 40, height: 40))
        return try XCTUnwrap(UIImage(cgImage: try XCTUnwrap(context.makeImage())).pngData())
    }

    private func decoded(_ data: Data) throws -> CGImage {
        try XCTUnwrap(CGImageSourceCreateImageAtIndex(try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil)), 0, nil))
    }

    private func color(_ image: CGImage) throws -> [Double] {
        let context = try XCTUnwrap(CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
            bytesPerRow: image.width * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let pointer = try XCTUnwrap(context.data).assumingMemoryBound(to: UInt8.self)
        let index = (image.height / 2 * image.width + image.width / 4) * 4
        return (0..<3).map { Double(pointer[index + $0]) }
    }
}

@MainActor
private final class PipelineEditingSession: SessionManager {
    override func serverVersion() async throws -> ServerVersionDTO { .init(major: 3, minor: 1, patch: 0) }
    override func features() async throws -> ServerFeaturesDTO {
        .init(smartSearch: true, facialRecognition: true, oauth: false, passwordLogin: true, search: true)
    }
    override func serverConfig() async throws -> ServerConfigDTO {
        try JSONDecoder().decode(ServerConfigDTO.self, from: Data("{}".utf8))
    }
}

private final class PipelineEditingCredentials: SessionCredentialStore {
    private var values: [String: String] = [:]
    func read(_ key: String) -> String? { values[key] }
    func save(_ value: String, for key: String) { values[key] = value }
    func delete(_ key: String) { values[key] = nil }
}

private final class PipelineEditingOwner: @unchecked Sendable {
    private let lock = NSLock()
    private var value = "owner-a"
    var id: String {
        get { lock.withLock { value } }
        set { lock.withLock { value = newValue } }
    }
}

@MainActor
private final class PipelineEditingAPI: APIClient {
    var data = Data()
    var fileBytesByID: [String: Data] = [:]
    var fileMIMETypesByID: [String: String] = [:]
    var dataRequests: [Endpoint] = []
    var fileRequests: [Endpoint] = []
    var downloads: [URL] = []
    var dataGate: PipelineEditingGate?
    var beforeCheck: (() throws -> Void)?
    override func rawData(_ endpoint: Endpoint) async throws -> Data {
        dataRequests.append(endpoint)
        await dataGate?.wait()
        return data
    }
    override func rawFile(_ endpoint: Endpoint) async throws -> DownloadedFile {
        fileRequests.append(endpoint)
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("pipeline-download-\(UUID())")
        let id = String(endpoint.path.split(separator: "/")[1])
        try (fileBytesByID[id] ?? data).write(to: file); downloads.append(file)
        let mime = fileMIMETypesByID[id] ?? "image/png"
        let ext = mime.hasPrefix("video/") ? "mov" : "png"
        let response = HTTPURLResponse(url: URL(string: "https://editing-pipeline.example.invalid\(endpoint.path)")!,
            statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": mime,
                "Content-Disposition": "attachment; filename=\"\(id).\(ext)\""])!
        return DownloadedFile(url: file, response: response)
    }
    override func checkCurrent(_ context: SessionRequestContext) throws {
        let action = beforeCheck; beforeCheck = nil; try action?()
        try super.checkCurrent(context)
    }
}

@MainActor
private final class PipelineEditingGate {
    let started = XCTestExpectation(description: "The original thumbnail bytes are held")
    private var continuation: CheckedContinuation<Void, Never>?
    func wait() async { await withCheckedContinuation { continuation = $0; started.fulfill() } }
    func release() { continuation?.resume(); continuation = nil }
}
