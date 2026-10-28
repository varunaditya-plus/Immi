import XCTest
@testable import ImmichApp

@MainActor
final class TimelineOriginalSharingTests: XCTestCase {
    private var directory: URL!
    private var manager: SwiftDataManager!
    private var api: APIClient!
    private var transport: URLSession!
    private var files: [URL] = []

    override func setUp() async throws {
        MockURLProtocol.reset()
        RemovedAssets.shared.clear()
        DeletedServerAssetRegistry.shared.clear()
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("timeline-original-sharing-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        manager = SwiftDataManager(storeURL: directory.appendingPathComponent("test.store"),
            backupJournalURL: directory.appendingPathComponent("backup.json"))
        let session = MockSessionManager()
        try session.setServer("https://timeline-share.example")
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        transport = URLSession(configuration: configuration)
        api = APIClient(session: session, urlSession: transport)
    }

    override func tearDown() async throws {
        transport.invalidateAndCancel()
        transport = nil
        api = nil
        manager = nil
        TemporaryMediaStore.remove(files)
        files.removeAll()
        try? FileManager.default.removeItem(at: directory)
        directory = nil
        RemovedAssets.shared.clear()
        DeletedServerAssetRegistry.shared.clear()
        MockURLProtocol.reset()
    }

    func testSingleDeviceOnlyAndMappedTilesShareTheirLocalOriginalWithoutServerRequests() async throws {
        for mapped in [false, true] {
            let localID = "local-\(mapped)"
            if mapped { try manager.linkDeviceAsset(localIdentifier: localID, to: "server-\(mapped)") }
            let source = try localFile(localID)
            let capture = LocalSharingCapture()
            let model = model { id in
                capture.ids.append(id)
                return (source, "\(localID).heic")
            }
            MockURLProtocol.responseProvider = { request in
                XCTFail("A locally available original must not request server media: \(request)")
                return (nil, nil, URLError(.unsupportedURL))
            }

            let shared = await model.shareURL(for: photo("device:\(localID)", origin: .device))
            let file = try XCTUnwrap(shared)
            files.append(file)

            XCTAssertEqual(capture.ids, ["device:\(localID)"])
            XCTAssertEqual(try Data(contentsOf: file), Data(localID.utf8))
            XCTAssertTrue(file.lastPathComponent.hasSuffix("-\(localID).heic"))
            XCTAssertFalse(FileManager.default.fileExists(atPath: source.path))
            XCTAssertNil(MockURLProtocol.lastRequest)
            XCTAssertNil(model.actionError)
        }
    }

    func testMixedBulkSharingPreservesInputOrderAndNeverSendsDeviceIDsToTheServer() async throws {
        try manager.linkDeviceAsset(localIdentifier: "mapped", to: "mapped-server")
        let onlySource = try localFile("only-local"), mappedSource = try localFile("mapped-local")
        let capture = LocalSharingCapture()
        let model = model { id in
            capture.ids.append(id)
            return id == "device:only" ? (onlySource, "only.heic") : (mappedSource, "mapped.mov")
        }
        var requests: [String] = []
        MockURLProtocol.responseProvider = { request in
            requests.append(request.url!.path)
            return Self.serverResponse(request)
        }

        let result = await model.shareURLs(for: ["device:only", "server-video", "device:mapped"])
        files.append(contentsOf: result)

        XCTAssertEqual(requests, ["/api/assets/server-video/original"])
        XCTAssertEqual(capture.ids, ["device:only", "device:mapped"])
        XCTAssertEqual(result.map(\.pathExtension), ["heic", "mp4", "mov"])
        XCTAssertEqual(try result.map { try Data(contentsOf: $0) },
            [Data("only-local".utf8), Data("server-original".utf8), Data("mapped-local".utf8)])
        XCTAssertFalse(FileManager.default.fileExists(atPath: onlySource.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: mappedSource.path))
    }

    func testUnavailableMappedLocalOriginalFallsBackToItsCurrentServerID() async throws {
        try manager.linkDeviceAsset(localIdentifier: "mapped", to: "current-server")
        let capture = LocalSharingCapture()
        let model = model { capture.ids.append($0); return nil }
        MockURLProtocol.responseProvider = { request in
            XCTAssertEqual(request.url?.path, "/api/assets/current-server/original")
            return Self.serverResponse(request)
        }

        let shared = await model.shareURL(for: photo("device:mapped", origin: .device))
        let result = try XCTUnwrap(shared)
        files.append(result)

        XCTAssertEqual(capture.ids, ["device:mapped"])
        XCTAssertEqual(try Data(contentsOf: result), Data("server-original".utf8))
        XCTAssertEqual(result.pathExtension, "mp4")
        XCTAssertNil(model.actionError)
    }

    func testSingleServerFallbackDiscardsLatePrivateOriginalAfterItsMappingChanges() async throws {
        for unlinks in [false, true] {
            try await assertObsoleteMappedFallbackIsDiscarded(bulk: false, unlinks: unlinks)
        }
    }

    func testBulkServerFallbackDiscardsLatePrivateOriginalAndPreparedPrefixAfterItsMappingChanges() async throws {
        for unlinks in [false, true] {
            try await assertObsoleteMappedFallbackIsDiscarded(bulk: true, unlinks: unlinks)
        }
    }

    func testUnavailableDeviceOnlyOriginalFailsWithoutInventingAServerRequest() async {
        let model = model { _ in nil }
        MockURLProtocol.responseProvider = { request in
            XCTFail("An unmapped local ID is not a server asset: \(request)")
            return (nil, nil, URLError(.unsupportedURL))
        }

        let result = await model.shareURL(for: photo("device:missing", origin: .device))

        XCTAssertNil(result)
        XCTAssertNotNil(model.actionError)
        XCTAssertNil(MockURLProtocol.lastRequest)
    }

    func testAccountPrivacyAndCancellationChangesRemoveLateLocalExportsWithoutErrors() async throws {
        for invalidation in ["account", "privacy", "cancel"] {
            let id = "held-\(invalidation)"
            try manager.linkDeviceAsset(localIdentifier: id, to: "server-\(id)")
            let source = try localFile(id)
            let gate = LocalOriginalSharingGate()
            let model = model { _ in await gate.wait(); return (source, "\(id).heic") }
            let task = Task { await model.shareURL(for: photo("device:\(id)", origin: .both)) }
            addTeardownBlock { await gate.release(); _ = await task.value }
            await fulfillment(of: [gate.started], timeout: 2)
            switch invalidation {
            case "account": LocalSnapshot.clearAll()
            case "privacy": try manager.setAssetVisibility(["server-\(id)"], to: "locked")
            default: task.cancel()
            }
            gate.release()
            let result = await task.value
            if let result { files.append(result) }

            XCTAssertNil(result, invalidation)
            XCTAssertNil(model.actionError, invalidation)
            XCTAssertFalse(FileManager.default.fileExists(atPath: source.path), invalidation)
            XCTAssertNil(MockURLProtocol.lastRequest, invalidation)
        }
    }

    func testPrivateMappedPhotosDoNotStartLocalExportsOrServerRequests() async throws {
        try manager.linkDeviceAsset(localIdentifier: "private", to: "private-server")
        try manager.setAssetVisibility(["private-server"], to: "locked")
        let capture = LocalSharingCapture()
        let model = model { capture.ids.append($0); XCTFail("Private originals must not be exported"); return nil }

        let single = await model.shareURL(for: photo("device:private", origin: .both))
        let multiple = await model.shareURLs(for: ["device:private"])

        XCTAssertNil(single)
        XCTAssertTrue(multiple.isEmpty)
        XCTAssertTrue(capture.ids.isEmpty)
        XCTAssertNil(MockURLProtocol.lastRequest)
        XCTAssertNil(model.actionError)
    }

    private func assertObsoleteMappedFallbackIsDiscarded(bulk: Bool, unlinks: Bool) async throws {
        let token = UUID().uuidString
        let localID = "held-\(token)"
        let displayID = LocalPhotoLibrary.assetID(for: localID)
        let originalServerID = "old-\(token)"
        let prefixID = "prefix-\(token)"
        try manager.linkDeviceAsset(localIdentifier: localID, to: originalServerID)
        let capture = LocalSharingCapture()
        let model = model { capture.ids.append($0); return nil }
        let started = expectation(description: "The mapped original download is held")
        let release = DispatchSemaphore(value: 0)
        var requests: [String] = []
        MockURLProtocol.responseProvider = { request in
            let path = request.url?.path ?? ""
            requests.append(path)
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertNil(request.url?.query)
            XCTAssertFalse(path.contains("device:"))
            if path == "/api/assets/\(originalServerID)/original" {
                started.fulfill()
                guard release.wait(timeout: .now() + 5) == .success else {
                    return (nil, nil, URLError(.timedOut))
                }
            } else {
                XCTAssertTrue(bulk)
                XCTAssertEqual(path, "/api/assets/\(prefixID)/original")
            }
            return (Data(path.utf8), HTTPURLResponse(url: request.url!, statusCode: 200,
                httpVersion: nil, headerFields: ["Content-Type": "video/mp4",
                    "Content-Disposition": "attachment; filename=\"\(token)-\(path.contains(prefixID) ? "prefix" : "private").mp4\""]), nil)
        }
        let task = Task { () -> [URL] in
            if bulk { return await model.shareURLs(for: [prefixID, displayID]) }
            if let file = await model.shareURL(for: photo(displayID, origin: .both)) { return [file] }
            return []
        }
        addTeardownBlock { release.signal(); _ = await task.value }
        await fulfillment(of: [started], timeout: 2)
        let shareDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("selfphotos-share")
        if bulk {
            let prefix = try FileManager.default.contentsOfDirectory(at: shareDirectory, includingPropertiesForKeys: nil)
                .filter { $0.lastPathComponent.contains(token) }
            XCTAssertEqual(prefix.count, 1, "The batch prefix must be prepared before the mapping changes")
            files.append(contentsOf: prefix)
        }
        if unlinks { try manager.unlinkDeviceAsset(localIdentifier: localID) }
        else {
            try manager.upsertBackupRecord(assetID: "replacement-\(token)", checksum: "replacement", localIdentifier: localID)
        }
        try manager.setAssetVisibility([originalServerID], to: "locked")
        XCTAssertTrue(AssetVisibilityPolicy(scope: .timeline, dataManager: manager).allows(id: displayID),
            "The display ID now resolves elsewhere; its privacy check cannot authorize the old server file")
        release.signal()
        let result = await task.value
        files.append(contentsOf: result)

        XCTAssertTrue(result.isEmpty, "A stale server original must not be returned under a changed display identity")
        XCTAssertNil(model.actionError, "Discarding an obsolete share must remain silent")
        XCTAssertEqual(capture.ids, [displayID])
        XCTAssertEqual(requests, (bulk ? ["/api/assets/\(prefixID)/original"] : [])
            + ["/api/assets/\(originalServerID)/original"])
        let remaining = (try? FileManager.default.contentsOfDirectory(at: shareDirectory, includingPropertiesForKeys: nil))?
            .filter { $0.lastPathComponent.contains(token) } ?? []
        files.append(contentsOf: remaining)
        XCTAssertTrue(remaining.isEmpty, "The obsolete original and any prepared prefix must be removed")
    }

    private func model(
        original: @escaping @MainActor (String) async -> (url: URL, filename: String)?
    ) -> TimelineViewModel {
        TimelineViewModel(dataManager: manager, assetRepo: AssetDetailRepository(api: api, dataManager: manager),
            localOriginalFile: original, localPhotos: { [] })
    }

    private func photo(_ id: String, origin: AssetOrigin) -> AssetLite {
        AssetLite(id: id, isVideo: false, ratio: 1, thumbhash: nil,
            createdAt: .distantPast, origin: origin)
    }

    private func localFile(_ contents: String) throws -> URL {
        let url = directory.appendingPathComponent(UUID().uuidString)
        try Data(contents.utf8).write(to: url)
        return url
    }

    private nonisolated static func serverResponse(_ request: URLRequest) -> (Data?, URLResponse?, Error?) {
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertNil(request.url?.query)
        XCTAssertFalse(request.url!.path.contains("device:"))
        return (Data("server-original".utf8), HTTPURLResponse(url: request.url!, statusCode: 200,
            httpVersion: nil, headerFields: ["Content-Type": "video/mp4",
                "Content-Disposition": "attachment; filename=\"server.mp4\""]), nil)
    }
}

@MainActor
private final class LocalSharingCapture { var ids: [String] = [] }

@MainActor
private final class LocalOriginalSharingGate {
    let started = XCTestExpectation(description: "The local original is held before export completion")
    private var continuation: CheckedContinuation<Void, Never>?
    func wait() async { await withCheckedContinuation { continuation = $0; started.fulfill() } }
    func release() { continuation?.resume(); continuation = nil }
}
