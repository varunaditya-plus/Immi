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

            XCTAssertTrue(file.lastPathComponent.hasSuffix("-" + filename), file.lastPathComponent)
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
        XCTAssertTrue(file.lastPathComponent.hasSuffix("-edited-photo.jpg"))
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
        let source = try sourceFile()
        client.handler = { _ in self.download(source, filename: "../../photo.png", mimeType: "image/png") }
        let file = try await repository.shareFile("asset")
        prepared.append(file)
        XCTAssertEqual(file.deletingLastPathComponent().lastPathComponent, "selfphotos-share")
        XCTAssertEqual(file.pathExtension, "png")
        XCTAssertFalse(FileManager.default.fileExists(atPath: source.path))
        TemporaryMediaStore.remove(file)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
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

    private func sourceFile() throws -> URL {
        let file = directory.appendingPathComponent(UUID().uuidString)
        try Data("original bytes".utf8).write(to: file)
        return file
    }

    private func download(_ source: URL, filename: String? = nil, mimeType: String = "application/octet-stream") -> APIClient.DownloadedFile {
        var headers = ["Content-Type": mimeType]
        if let filename {
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
