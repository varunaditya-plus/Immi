import CryptoKit
import Foundation

struct SharedUploadCredential: Equatable, Sendable {
    let apiURL: URL
    let owner: SharedUploadOwner
    let authHeaders: [String: String]
}

enum SharedUploadClientError: LocalizedError {
    case invalidResponse
    case server(status: Int, message: String?)

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            String(localized: "The Immich server returned an invalid response.")
        case .server(let status, let message):
            if let message, !message.isEmpty {
                String(localized: "Immich returned HTTP \(status): \(message)")
            } else {
                String(localized: "Immich returned HTTP \(status).")
            }
        }
    }
}

struct SharedUploadClient: Sendable {
    private let credential: SharedUploadCredential
    private let session: URLSession?
    private let readChunk: @Sendable (FileHandle, Int) throws -> Data?

    init(
        credential: SharedUploadCredential,
        session: URLSession? = nil,
        readChunk: @escaping @Sendable (FileHandle, Int) throws -> Data? = { try $0.read(upToCount: $1) }
    ) {
        self.credential = credential
        self.session = session
        self.readChunk = readChunk
    }

    @discardableResult
    func upload(
        item: SharedUploadItem,
        fileURL: URL,
        bodyDirectory: URL
    ) async throws -> String {
        try Task.checkCancellation()
        let checksum = try await checksum(for: fileURL)
        try Task.checkCancellation()
        let bodyURL = try await makeMultipartBody(
            item: item,
            sourceURL: fileURL,
            directory: bodyDirectory)
        defer { try? FileManager.default.removeItem(at: bodyURL) }
        try Task.checkCancellation()

        let boundary = bodyURL.deletingPathExtension().lastPathComponent
        var request = URLRequest(url: credential.apiURL.appendingPathComponent("assets"))
        request.httpMethod = "POST"
        request.timeoutInterval = 60
        request.setValue(
            "multipart/form-data; boundary=\(boundary)",
            forHTTPHeaderField: "Content-Type")
        request.setValue(checksum, forHTTPHeaderField: "x-immich-checksum")
        credential.authHeaders.forEach {
            request.setValue($1, forHTTPHeaderField: $0)
        }

        let session: URLSession
        if let supplied = self.session {
            session = supplied
        } else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = 60
            configuration.timeoutIntervalForResource = 120
            configuration.waitsForConnectivity = false
            session = URLSession(configuration: configuration)
        }
        defer { if self.session == nil { session.finishTasksAndInvalidate() } }
        try Task.checkCancellation()
        let (data, response) = try await session.upload(for: request, fromFile: bodyURL)

        guard let http = response as? HTTPURLResponse else {
            throw SharedUploadClientError.invalidResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            throw SharedUploadClientError.server(
                status: http.statusCode,
                message: String(data: data, encoding: .utf8))
        }

        struct Response: Decodable { let id: String }
        guard let decoded = try? JSONDecoder().decode(Response.self, from: data) else {
            throw SharedUploadClientError.invalidResponse
        }
        return decoded.id
    }

    private func checksum(for url: URL) async throws -> String {
        try Task.checkCancellation()
        let readChunk = readChunk
        let worker = Task.detached(priority: .utility) {
            try Task.checkCancellation()
            let input = try FileHandle(forReadingFrom: url)
            defer { try? input.close() }
            var hasher = Insecure.SHA1()
            while true {
                let hasMore = try autoreleasepool {
                    try Task.checkCancellation()
                    guard let chunk = try readChunk(input, 1024 * 1024), !chunk.isEmpty else { return false }
                    try Task.checkCancellation()
                    hasher.update(data: chunk)
                    return true
                }
                if !hasMore { break }
            }
            try Task.checkCancellation()
            return hasher.finalize().map { String(format: "%02x", $0) }.joined()
        }
        return try await withTaskCancellationHandler {
            let checksum = try await worker.value
            try Task.checkCancellation()
            return checksum
        } onCancel: {
            worker.cancel()
        }
    }

    /// Nama body adalah boundary-nya juga. Itu menghindari metadata kedua yang
    /// dapat hilang bila extension dihentikan di tengah persiapan.
    private func makeMultipartBody(
        item: SharedUploadItem,
        sourceURL: URL,
        directory: URL
    ) async throws -> URL {
        try Task.checkCancellation()
        let readChunk = readChunk
        let worker = Task.detached(priority: .utility) {
            try Task.checkCancellation()
            let boundary = "Boundary-\(UUID().uuidString)"
            let outputURL = directory.appendingPathComponent(boundary)
                .appendingPathExtension("multipart")
            guard FileManager.default.createFile(atPath: outputURL.path, contents: nil) else {
                throw CocoaError(.fileWriteUnknown)
            }

            do {
                let output = try FileHandle(forWritingTo: outputURL)
                defer { try? output.close() }

                func write(_ string: String) throws {
                    try Task.checkCancellation()
                    try output.write(contentsOf: Data(string.utf8))
                }

                let iso = ISO8601DateFormatter()
                let fields: [(String, String)] = [
                    ("deviceAssetId", "share-\(item.id.uuidString)"),
                    ("deviceId", SharedDeviceIdentity.current),
                    ("fileCreatedAt", iso.string(from: item.createdAt)),
                    ("fileModifiedAt", iso.string(from: item.modifiedAt)),
                    ("filename", item.filename),
                ]
                for (name, value) in fields {
                    try write("--\(boundary)\r\n")
                    try write("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n")
                    try write("\(value)\r\n")
                }

                let safeFilename = item.filename.replacingOccurrences(of: "\"", with: "'")
                try write("--\(boundary)\r\n")
                try write("Content-Disposition: form-data; name=\"assetData\"; filename=\"\(safeFilename)\"\r\n")
                try write("Content-Type: \(item.contentType)\r\n\r\n")

                let input = try FileHandle(forReadingFrom: sourceURL)
                defer { try? input.close() }
                while true {
                    let hasMore = try autoreleasepool {
                        try Task.checkCancellation()
                        guard let chunk = try readChunk(input, 1024 * 1024), !chunk.isEmpty else { return false }
                        try Task.checkCancellation()
                        try output.write(contentsOf: chunk)
                        return true
                    }
                    if !hasMore { break }
                }
                try write("\r\n--\(boundary)--\r\n")
                try Task.checkCancellation()
                return outputURL
            } catch {
                try? FileManager.default.removeItem(at: outputURL)
                throw error
            }
        }
        return try await withTaskCancellationHandler {
            let url = try await worker.value
            do {
                try Task.checkCancellation()
                return url
            } catch {
                try? FileManager.default.removeItem(at: url)
                throw error
            }
        } onCancel: {
            worker.cancel()
        }
    }
}
