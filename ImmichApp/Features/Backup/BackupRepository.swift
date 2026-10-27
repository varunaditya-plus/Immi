import CryptoKit
import Foundation

class BackupRepository {
    private let api: APIClient

    init(api: APIClient) {
        self.api = api
    }

    /// SHA1 file secara bertahap—video ratusan MB tidak dimuat utuh ke RAM.
    func checksum(forFile url: URL) async throws -> String {
        try await Task.detached(priority: .utility) {
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }

            var hasher = Insecure.SHA1()
            while let chunk = try handle.read(upToCount: 1024 * 1024), !chunk.isEmpty {
                try Task.checkCancellation()
                hasher.update(data: chunk)
            }
            return hasher.finalize()
                .map { String(format: "%02x", $0) }
                .joined()
        }.value
    }

    /// POST /assets/bulk-upload-check menerima {assets: [{id, checksum}]} dan
    /// menjawab {results: [{id, action, reason, ...}]}. Mengembalikan id yang
    /// ditolak karena duplikat.
    /// Untuk jalur UNGGAH: cukup tahu mana yang sudah ada, tanpa peduli id
    /// servernya.
    ///
    /// Sengaja tidak lewat `duplicateMatches`: yang itu membuang entri tanpa
    /// `assetId`, dan `assetId` adalah field opsional. Foto yang dilaporkan
    /// duplikat tanpa menyebut pasangannya akan lolos dari saringan dan
    /// diunggah ulang.
    func checkDuplicates(_ candidates: [(id: String, checksum: String)]) async throws -> Set<String> {
        Set(try await rawResults(candidates)
            .filter { $0.action == "reject" && $0.reason == "duplicate" }
            .map { $0.id })
    }

    /// Sama dengan `checkDuplicates`, tapi membawa serta ID ASET SERVER-nya.
    ///
    /// Jawaban duplikat menyertakan `assetId` — foto mana di server yang isinya
    /// sama. Itu yang membuat pencocokan ini bisa disimpan sebagai `BackupRecord`
    /// dan dipakai ulang: tanpa id itu, yang diketahui cuma "sudah ada di suatu
    /// tempat", dan lencana "ada di keduanya" tidak tahu petak mana yang harus
    /// ditandai.
    func duplicateMatches(
        _ candidates: [(id: String, checksum: String)]
    ) async throws -> [(localID: String, serverAssetID: String)] {
        try await rawResults(candidates).compactMap { entry in
            guard entry.action == "reject", entry.reason == "duplicate",
                  let assetId = entry.assetId
            else { return nil }
            return (entry.id, assetId)
        }
    }

    struct BulkCheckResult: Decodable {
        let id: String
        let action: String
        let reason: String?
        /// Aset server yang isinya sama. OPSIONAL — server tidak selalu
        /// menyebutkannya.
        let assetId: String?
    }

    private func rawResults(
        _ candidates: [(id: String, checksum: String)]
    ) async throws -> [BulkCheckResult] {
        struct AssetCheck: Encodable { let id: String; let checksum: String }
        struct Body: Encodable { let assets: [AssetCheck] }
        struct Response: Decodable { let results: [BulkCheckResult] }

        let body = Body(assets: candidates.map { AssetCheck(id: $0.id, checksum: $0.checksum) })
        let response: Response = try await api.send(
            .json("/assets/bulk-upload-check", method: .post, body: body))
        return response.results
    }

    /// Permintaan unggah beserta badannya yang sudah ditulis KE BERKAS.
    struct PreparedUpload {
        let request: URLRequest
        /// Badan multipart di direktori sementara. Pemanggil yang membuangnya —
        /// sesi latar baru selesai memakainya jauh setelah fungsi ini pulang.
        let bodyFile: URL
    }

    /// Merakit permintaan multipart, menaruh badannya di berkas.
    ///
    /// **Berkas, bukan `Data`, dan itu syarat dari iOS.** `URLSession` latar
    /// hanya menerima `uploadTask(with:fromFile:)`; varian yang menerima `Data`
    /// dijawab dengan pengecualian saat dijalankan. Alasannya masuk akal:
    /// unggahannya diteruskan ke daemon sistem yang hidup di luar proses
    /// aplikasi ini, dan daemon itu perlu sesuatu yang bisa dibacanya sendiri
    /// setelah aplikasinya tidak ada lagi.
    ///
    /// Jalur biasa ikut memakainya — dua perakit multipart untuk satu endpoint
    /// hanya menunggu keduanya menyimpang.
    func makeUploadRequest(
        fileURL: URL,
        filename: String,
        checksum: String,
        deviceAssetId: String,
        createdAt: Date,
        modifiedAt: Date,
        additionalFields: [String: String] = [:]
    ) async throws -> PreparedUpload {
        let context = await api.session.snapshot
        let baseURL = context.baseURL
        let authHeaders = context.authHeaders
        guard let baseURL else { throw APIError.invalidURL }

        let boundary = "Boundary-\(UUID().uuidString)"
        var request = URLRequest(url: baseURL.appendingPathComponent("/assets"))
        request.httpMethod = "POST"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.setValue(checksum, forHTTPHeaderField: "x-immich-checksum")

        for (k, v) in authHeaders {
            request.setValue(v, forHTTPHeaderField: k)
        }

        var fields = [
            ("deviceAssetId", deviceAssetId),
            ("deviceId", DeviceIdentity.current),
            ("fileCreatedAt", ISO8601DateFormatter().string(from: createdAt)),
            ("fileModifiedAt", ISO8601DateFormatter().string(from: modifiedAt)),
            ("filename", filename),
        ]
        // Field pasangan Live Photo (`visibility` untuk motion video dan
        // `livePhotoVideoId` untuk still image) memakai multipart yang sama
        // dengan upload biasa. Urutan dibuat stabil agar request mudah diaudit
        // dan contract test tidak bergantung pada urutan Dictionary.
        fields.append(contentsOf: additionalFields.sorted { $0.key < $1.key })

        // Badan multipart ditulis per potongan di luar main actor. Dengan ini
        // sebuah video hanya punya buffer 1 MB, bukan dua salinan penuh di RAM.
        let bodyFile = try await Task.detached(priority: .utility) {
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("upload-\(UUID().uuidString).multipart")
            do {
                guard FileManager.default.createFile(atPath: url.path, contents: nil)
                else { throw APIError.unknown }
                let output = try FileHandle(forWritingTo: url)
                defer { try? output.close() }

                func write(_ string: String) throws {
                    guard let data = string.data(using: .utf8) else { throw APIError.unknown }
                    try output.write(contentsOf: data)
                }

                for (name, value) in fields {
                    try write("--\(boundary)\r\n")
                    try write("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n")
                    try write("\(value)\r\n")
                }

                try write("--\(boundary)\r\n")
                try write("Content-Disposition: form-data; name=\"assetData\"; filename=\"\(filename)\"\r\n")
                try write("Content-Type: application/octet-stream\r\n\r\n")

                let input = try FileHandle(forReadingFrom: fileURL)
                defer { try? input.close() }
                while let chunk = try input.read(upToCount: 1024 * 1024), !chunk.isEmpty {
                    try Task.checkCancellation()
                    try output.write(contentsOf: chunk)
                }
                try write("\r\n--\(boundary)--\r\n")
                return url
            } catch {
                try? FileManager.default.removeItem(at: url)
                throw error
            }
        }.value

        return PreparedUpload(request: request, bodyFile: bodyFile)
    }

    /// Membaca id aset dari jawaban server, atau melempar alasannya.
    ///
    /// `static` supaya sesi latar bisa memakainya juga: saat jawabannya datang,
    /// aplikasinya mungkin baru saja diluncurkan ulang oleh sistem dan tidak
    /// punya repository apa pun yang masih hidup.
    static func assetID(from data: Data, response: URLResponse?) throws -> String {
        guard let httpResponse = response as? HTTPURLResponse else {
            throw APIError.server(status: -1, message: nil)
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            // Badan jawabannya IKUT dilempar.
            //
            // Immich menjelaskan penolakannya di situ — kredensial kedaluwarsa,
            // format tidak didukung, kuota habis. Membuangnya menyisakan sebuah
            // angka, dan angka itu tidak memberi tahu siapa pun apa yang harus
            // diperbaiki.
            throw APIError.server(
                status: httpResponse.statusCode,
                message: String(data: data, encoding: .utf8))
        }

        struct UploadResponse: Decodable {
            let id: String
            let status: String?
        }
        return try JSONDecoder.immich.decode(UploadResponse.self, from: data).id
    }

    func getStorageInfo() async throws -> ServerStorageDTO {
        try await api.send(.init(path: "/server/storage"))
    }
}
