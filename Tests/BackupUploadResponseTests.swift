import Foundation
import XCTest
@testable import ImmichApp

final class BackupUploadResponseTests: XCTestCase {
    func testBlankSuccessfulReceiptKeepsTheLastStagedCopyForRecovery() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("backup-upload-response-\(UUID())")
        let temporary = root.appendingPathComponent("tmp"), recovery = root.appendingPathComponent("recovery")
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let ownership = BackupUploadOwnership(
            owner: .init(server: "https://receipt.example/api", userID: "synthetic-user"), generation: UUID())
        let bytes = Data("Only remaining synthetic media copy".utf8)
        for status in [200, 201] {
            for id in ["", " ", "\n\t "] {
                let body = temporary.appendingPathComponent("upload-\(UUID()).multipart")
                try bytes.write(to: body)
                let context = BackupUploadTaskContext(phase: .primaryAsset, localIdentifier: UUID().uuidString,
                    checksum: "synthetic-checksum", bodyPath: body.path, ownership: ownership)
                try BackupTemporaryFiles.record(context, in: temporary)
                let payload = try JSONSerialization.data(withJSONObject: ["id": id, "status": "created"])
                let outcome = Result { try BackupRepository.assetID(from: payload, response: response(status)) }
                let succeeded: Bool
                switch outcome {
                case .success:
                    succeeded = true
                    XCTFail("An empty receipt must not authorize deleting the only staged copy")
                case .failure(let error):
                    succeeded = false
                    XCTAssertTrue(error is DecodingError)
                }

                let preserved = try BackupTemporaryFiles.finish(context, succeeded: succeeded, sourceAvailable: false,
                    in: temporary, recovery: recovery)

                XCTAssertTrue(preserved)
                let saved = recovery.appendingPathComponent(body.lastPathComponent)
                XCTAssertEqual(try Data(contentsOf: saved), bytes)
                XCTAssertTrue(BackupTemporaryFiles.recordedContexts(in: recovery).contains(context))
                XCTAssertFalse(FileManager.default.fileExists(atPath: body.path))
            }
        }
    }

    func testSuccessfulReceiptsKeepOpaqueNonemptyIdentifiersUnchanged() throws {
        for id in ["opaque-server-asset", "CaseSensitiveID", " opaque-with-padding "] {
            for status in ["created", "duplicate"] {
                let payload = try JSONSerialization.data(withJSONObject: ["id": id, "status": status])
                XCTAssertEqual(try BackupRepository.assetID(from: payload, response: response(201)), id)
            }
        }
    }

    private func response(_ status: Int) -> HTTPURLResponse {
        HTTPURLResponse(url: URL(string: "https://receipt.example/api/assets")!, statusCode: status,
            httpVersion: nil, headerFields: nil)!
    }
}
