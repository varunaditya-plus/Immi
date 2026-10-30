import XCTest
@testable import ImmichApp

@MainActor
final class MediaFileRepositoryTests: XCTestCase {
    private var directory: URL!
    private var client: MediaFileStubClient!
    private var repository: AssetDetailRepository!
    private var prepared: [URL] = []

    override func setUp() async throws {
        try await super.setUp()
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("MediaFileTests-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        client = MediaFileStubClient(session: MockSessionManager())
        repository = AssetDetailRepository(api: client)
    }

    override func tearDown() async throws {
        client.handler = nil
        repository = nil
        client = nil
        TemporaryMediaStore.remove(prepared)
        prepared.removeAll()
        try? FileManager.default.removeItem(at: directory)
        try await super.tearDown()
    }

    func testSharesPreserveOriginalNamesFormatsAndBytesWithoutMetadataRequests() async throws {
        for filename in ["photo.HEIC", "image.png", "scan.tiff", "raw.DNG", "movie.mp4", "holiday clip.mkv", "café.jpeg"] {
            let source = try sourceFile()
            client.handler = { endpoint in
                XCTAssertEqual(endpoint.path, "/assets/asset/original")
                XCTAssertTrue(endpoint.query.isEmpty, "Ordinary sharing must preserve the unedited-original contract")
                return self.download(source, filename: filename)
            }

            let file = try await repository.shareFile("asset")
            prepared.append(file)

            XCTAssertEqual(file.lastPathComponent, filename)
            XCTAssertEqual(try Data(contentsOf: file), Data("original bytes".utf8))
            XCTAssertFalse(FileManager.default.fileExists(atPath: source.path))
        }
        XCTAssertEqual(client.requests.count, 7)
    }

    func testEditedDownloadUsesReturnedFilenameInsteadOfTheOriginalExtension() async throws {
        let source = try sourceFile()
        client.handler = { endpoint in
            XCTAssertEqual(endpoint.query.first(where: { $0.name == "edited" })?.value, "true")
            return self.download(source, filename: "edited-photo.jpg", mimeType: "image/jpeg")
        }

        let file = try await repository.downloadOriginalFile("asset", filename: "original.HEIC")
        prepared.append(file)

        XCTAssertEqual(file.pathExtension, "jpg")
        XCTAssertEqual(file.lastPathComponent, "edited-photo.jpg")
        XCTAssertEqual(try Data(contentsOf: file), Data("original bytes".utf8))
    }

    func testMissingDispositionUsesTheReturnedMIMETypeRatherThanGuessingJPEGOrMOV() async throws {
        for (mimeType, expectedExtension) in [("image/png", "png"), ("image/heic", "heic"), ("video/mp4", "mp4")] {
            let source = try sourceFile()
            client.handler = { _ in self.download(source, mimeType: mimeType) }

            let file = try await repository.shareFile("asset")
            prepared.append(file)

            XCTAssertEqual(file.pathExtension, expectedExtension)
            XCTAssertEqual(try Data(contentsOf: file), Data("original bytes".utf8))
        }
    }

    func testUnknownMIMEDoesNotInventAnImageExtension() async throws {
        let source = try sourceFile()
        client.handler = { _ in self.download(source, mimeType: "application/octet-stream") }
        let file = try await repository.shareFile("unknown-format")
        prepared.append(file)
        XCTAssertTrue(file.pathExtension.isEmpty)
        XCTAssertEqual(try Data(contentsOf: file), Data("original bytes".utf8))
    }

    func testFilenameFromTheServerCannotEscapeTheManagedDirectory() async throws {
        for filename in ["../../photo.png", #"..\..\photo.png"#, #"C:\Photos\photo.png"#] {
            let source = try sourceFile()
            client.handler = { _ in self.download(source, filename: filename, mimeType: "image/png") }
            let file = try await repository.shareFile("asset")
            prepared.append(file)
            XCTAssertEqual(file.deletingLastPathComponent().deletingLastPathComponent().lastPathComponent, "selfphotos-share")
            XCTAssertEqual(file.lastPathComponent, "photo.png")
            XCTAssertEqual(file.pathExtension, "png")
            XCTAssertFalse(FileManager.default.fileExists(atPath: source.path))
            TemporaryMediaStore.remove(file)
            XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
            XCTAssertFalse(FileManager.default.fileExists(atPath: file.deletingLastPathComponent().path))
        }
    }

    func testQuotedFilenamesPreserveSemicolonsAndEscapedQuotesWithoutDirectoryPrefixes() async throws {
        for (header, expected) in [
            (#"attachment; filename="../../holiday; portrait.png""#, "holiday; portrait.png"),
            (#"attachment; filename="..\..\photo \"QA\".png""#, "photo \"QA\".png"),
            (#"attachment; filename="photo; filename*=UTF-8''literal.png""#, "photo; filename*=UTF-8''literal.png"),
            (#"attachment; filename="fallback.png"; filename*=UTF-8'en'..%2F..%2Fcaf%C3%A9%20photo.png"#, "café photo.png"),
        ] {
            let source = try sourceFile()
            client.handler = { _ in self.download(source, mimeType: "image/png", disposition: header) }

            let file = try await repository.shareFile("asset")
            prepared.append(file)

            XCTAssertEqual(file.lastPathComponent, expected)
            XCTAssertEqual(try Data(contentsOf: file), Data("original bytes".utf8))
        }
    }

    func testCanceledLateDownloadIsRemovedInsteadOfBeingReturned() async throws {
        let source = try sourceFile()
        let started = XCTestExpectation(description: "Download started")
        var continuation: CheckedContinuation<APIClient.DownloadedFile, Error>?
        client.handler = { _ in
            try await withCheckedThrowingContinuation { held in
                continuation = held
                started.fulfill()
            }
        }
        let task = Task { try await repository.shareFile("asset") }
        await fulfillment(of: [started], timeout: 2)
        task.cancel()
        let held = try XCTUnwrap(continuation)
        held.resume(returning: download(source, filename: "movie.mp4"))
        do {
            let file = try await task.value
            prepared.append(file)
            XCTFail("A canceled preparation must not return media")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: source.path))
    }

    func testLateDownloadFromPreviousAccountIsRemovedInsteadOfBeingAdopted() async throws {
        let source = try sourceFile()
        let started = expectation(description: "Previous account media download started")
        var continuation: CheckedContinuation<APIClient.DownloadedFile, Error>?
        defer { continuation?.resume(throwing: CancellationError()) }
        client.handler = { _ in
            try await withCheckedThrowingContinuation {
                continuation = $0
                started.fulfill()
            }
        }
        let task = Task { try await repository.shareFile("asset") }
        await fulfillment(of: [started], timeout: 2)

        LocalSnapshot.clearAll()
        let held = try XCTUnwrap(continuation)
        continuation = nil
        held.resume(returning: download(source, filename: "previous-account.mp4"))
        do {
            let file = try await task.value
            prepared.append(file)
            XCTFail("An old-account transfer must not become a shareable file")
        } catch {
            XCTAssertTrue(error is CancellationError, "Unexpected error: \(error)")
        }
        XCTAssertEqual(client.requests.map(\.path), ["/assets/asset/original"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: source.path))
    }

    func testChangedAccountContextDuringBatchRemovesItsPreparedPrefixAndStopsDownloading() async throws {
        let token = "batch-context-\(UUID())"
        let firstSource = try sourceFile()
        let secondSource = try sourceFile()
        var preparedPrefix: [URL] = []
        client.handler = { endpoint in
            if endpoint.path == "/assets/first/original" {
                return self.download(firstSource, filename: "\(token)-first.heic")
            }
            XCTAssertEqual(endpoint.path, "/assets/second/original")
            preparedPrefix = try managedShareFiles { $0.lastPathComponent.contains(token) }
            self.prepared.append(contentsOf: preparedPrefix)
            try self.client.session.setServer("https://next-account.example.com")
            return self.download(secondSource, filename: "\(token)-second.mp4")
        }

        let files = await repository.shareFiles(["first", "second", "third"])
        prepared.append(contentsOf: files)

        XCTAssertEqual(preparedPrefix.count, 1, "The first file must be prepared before the account changes")
        XCTAssertTrue(files.isEmpty)
        XCTAssertEqual(client.requests.map(\.path), ["/assets/first/original", "/assets/second/original"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: firstSource.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: secondSource.path))
        XCTAssertTrue(preparedPrefix.allSatisfy { !FileManager.default.fileExists(atPath: $0.path) })
        let remaining = try managedShareFiles { $0.lastPathComponent.contains(token) }
        prepared.append(contentsOf: remaining)
        XCTAssertTrue(remaining.isEmpty)
    }

    private func sourceFile() throws -> URL {
        let file = directory.appendingPathComponent(UUID().uuidString)
        try Data("original bytes".utf8).write(to: file)
        return file
    }

    private func download(_ source: URL, filename: String? = nil, mimeType: String = "application/octet-stream",
                          disposition: String? = nil) -> APIClient.DownloadedFile {
        var headers = ["Content-Type": mimeType]
        if let disposition { headers["Content-Disposition"] = disposition }
        else if let filename {
            headers["Content-Disposition"] = "inline; filename*=UTF-8''" + filename.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed)!
        }
        let response = HTTPURLResponse(url: URL(string: "https://media.example.com/api/assets/asset/original")!,
            statusCode: 200, httpVersion: nil, headerFields: headers)!
        return .init(url: source, response: response)
    }
}

private final class MediaFileStubClient: APIClient {
    var handler: ((Endpoint) async throws -> DownloadedFile)!
    var requests: [Endpoint] = []

    override func rawFile(_ endpoint: Endpoint) async throws -> DownloadedFile {
        requests.append(endpoint)
        return try await handler(endpoint)
    }

    override func rawData(_ endpoint: Endpoint) async throws -> Data {
        XCTFail("Media sharing must use the file download path")
        throw APIError.unknown
    }
}
