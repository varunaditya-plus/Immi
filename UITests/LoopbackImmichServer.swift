import Foundation
import Network
import UIKit

final class LoopbackImmichServer: @unchecked Sendable {
    struct Creation: Equatable {
        let name: String
        let description: String?
        let assetIDs: [String]
    }
    struct Resolution: Equatable {
        let groupID: String
        let keepIDs: Set<String>
        let trashIDs: Set<String>
    }
    struct Snapshot {
        let creations: [Creation]
        let albumNames: [String]
        let resolutions: [Resolution]
        let dismissedGroups: [String]
        let trashedIDs: Set<String>
        let duplicateReads: Int
        let creationIsHeld: Bool
        let uploadRequests: Int
        let unexpectedRequests: [String]
    }
    private struct Group {
        let id: String
        var members: [String]
        var suggested: [String]
    }
    private struct Album {
        let id: String
        let name: String
        let description: String?
        let shared: Bool
        let assetIDs: [String]
    }
    private struct Request {
        let method: String
        let path: String
        let query: [String: String]
        let headers: [String: String]
    }
    private struct Response {
        let status: Int
        let data: Data
        var type = "application/json"
    }

    static let email = "uitest@example.test"
    static let password = "synthetic-password"
    static let keepGroupID = "20000000-0000-0000-0000-000000000001"
    static let changingGroupID = "20000000-0000-0000-0000-000000000002"
    static let fallbackGroupID = "20000000-0000-0000-0000-000000000003"
    static let sharedAlbumName = "Shared Trip"
    static let names = ["Keep A.jpg", "Keep B.jpg", "First.jpg", "Second.jpg", "Third.jpg",
                        "Fallback First.jpg", "Fallback Second.jpg", "Fallback Third.jpg"]
    static func assetID(_ name: String) -> String {
        let index = names.firstIndex(of: name)!
        return String(format: "10000000-0000-0000-0000-%012d", index + 1)
    }

    private let queue = DispatchQueue(label: "ui-test.loopback-server")
    private let ownerID = UUID().uuidString
    private let image: Data
    private let date = "2026-10-31T12:00:00.000Z"
    private var listener: NWListener?
    private var connections: [UUID: NWConnection] = [:]
    private var groups: [Group] = []
    private var albums: [Album] = []
    private var creations: [Creation] = []
    private var resolutions: [Resolution] = []
    private var dismissedGroups: [String] = []
    private var trashedIDs: Set<String> = []
    private var duplicateReads = 0
    private var uploadRequests = 0
    private var unexpectedRequests: [String] = []
    private var holdCreation = false
    private var pendingCreation: (UUID, NWConnection)?

    @MainActor
    init() throws {
        let fixture = UIGraphicsImageRenderer(size: CGSize(width: 300, height: 200)).image { context in
            UIColor.systemTeal.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 300, height: 200))
            UIColor.systemOrange.setFill()
            context.fill(CGRect(x: 90, y: 60, width: 120, height: 80))
        }
        guard let jpeg = fixture.jpegData(compressionQuality: 0.7) else { throw URLError(.cannotDecodeContentData) }
        image = jpeg
        groups = [Group(id: Self.keepGroupID, members: Array(Self.names[0..<2]).map(Self.assetID),
                        suggested: [Self.assetID("Keep A.jpg")]),
                  Group(id: Self.changingGroupID, members: Array(Self.names[2..<5]).map(Self.assetID),
                        suggested: [Self.assetID("First.jpg")]),
                  Group(id: Self.fallbackGroupID, members: Array(Self.names[5..<8]).map(Self.assetID),
                        suggested: [Self.assetID("Fallback First.jpg")])]
        albums = [Album(id: UUID().uuidString, name: "Personal Trip", description: "Synthetic photos", shared: false,
                        assetIDs: Array(Self.names[0..<3]).map(Self.assetID)),
                  Album(id: UUID().uuidString, name: Self.sharedAlbumName, description: "Synthetic shared photos", shared: true,
                        assetIDs: Array(Self.names[2..<5]).map(Self.assetID))]
    }

    func start() async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do {
                    let parameters = NWParameters.tcp
                    parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
                    let listener = try NWListener(using: parameters)
                    self.listener = listener
                    var completed = false
                    listener.stateUpdateHandler = { state in
                        guard !completed else { return }
                        switch state {
                        case .ready:
                            guard let port = listener.port,
                                  let url = URL(string: "http://127.0.0.1:\(port.rawValue)") else { return }
                            completed = true
                            continuation.resume(returning: url)
                        case .failed(let error):
                            completed = true
                            continuation.resume(throwing: error)
                        default: break
                        }
                    }
                    listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
                    listener.start(queue: self.queue)
                } catch { continuation.resume(throwing: error) }
            }
        }
    }

    func stop() {
        queue.sync {
            listener?.stateUpdateHandler = nil
            listener?.newConnectionHandler = nil
            listener?.cancel()
            listener = nil
            connections.values.forEach { $0.cancel() }
            connections.removeAll()
            pendingCreation = nil
        }
    }

    func snapshot() -> Snapshot {
        queue.sync {
            Snapshot(creations: creations, albumNames: albums.map(\.name), resolutions: resolutions,
                dismissedGroups: dismissedGroups, trashedIDs: trashedIDs, duplicateReads: duplicateReads,
                creationIsHeld: pendingCreation != nil, uploadRequests: uploadRequests, unexpectedRequests: unexpectedRequests)
        }
    }

    func replaceMembers(in groupID: String, with names: [String], suggesting suggested: [String]) {
        queue.sync {
            guard let index = groups.firstIndex(where: { $0.id == groupID }) else { return }
            groups[index].members = names.map(Self.assetID)
            groups[index].suggested = suggested.map(Self.assetID)
        }
    }

    func holdAndFailNextAlbumCreation() { queue.sync { holdCreation = true } }
    func releaseFailedAlbumCreation() {
        queue.sync {
            guard let (id, connection) = pendingCreation else { return }
            pendingCreation = nil
            respond(error(503, "Synthetic album creation failure"), to: connection, id: id)
        }
    }

    private func accept(_ connection: NWConnection) {
        let id = UUID()
        connections[id] = connection
        connection.stateUpdateHandler = { [weak self] state in
            if case .failed = state { self?.connections.removeValue(forKey: id) }
            if case .cancelled = state { self?.connections.removeValue(forKey: id) }
        }
        connection.start(queue: queue)
        receiveHeader(Data(), from: connection, id: id)
    }

    // Read the header alone so upload rejection never consumes a photo body.
    private func receiveHeader(_ prefix: Data, from connection: NWConnection, id: UUID) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1) { [weak self] data, _, ended, failure in
            guard let self else { return }
            var header = prefix
            if let data { header.append(data) }
            guard failure == nil, !ended || data?.isEmpty == false, header.count < 32_768 else {
                connection.cancel(); return
            }
            guard header.suffix(4) == Data("\r\n\r\n".utf8) else {
                self.receiveHeader(header, from: connection, id: id); return
            }
            guard let request = self.parseHeader(header) else {
                self.respond(self.error(400, "Invalid request"), to: connection, id: id); return
            }
            if request.headers["content-type"]?.lowercased().contains("multipart/") == true
                || request.method == "POST" && ["/api/assets", "/api/asset/upload", "/api/users/profile-image"].contains(request.path) {
                self.uploadRequests += 1
                self.respond(self.error(403, "Uploads are disabled"), to: connection, id: id)
                return
            }
            guard request.headers["transfer-encoding"] == nil,
                  let length = Int(request.headers["content-length"] ?? "0"), (0...65_536).contains(length) else {
                self.respond(self.error(413, "Expected bounded JSON"), to: connection, id: id); return
            }
            self.receiveBody(Data(), remaining: length, request: request, from: connection, id: id)
        }
    }

    private func receiveBody(_ prefix: Data, remaining: Int, request: Request, from connection: NWConnection, id: UUID) {
        guard remaining > 0 else {
            let body: [String: Any]
            if prefix.isEmpty { body = [:] }
            else if let value = (try? JSONSerialization.jsonObject(with: prefix)) as? [String: Any] { body = value }
            else {
                unexpectedRequests.append("\(request.method) \(request.path), expected JSON object")
                respond(error(400, "Expected JSON object"), to: connection, id: id)
                return
            }
            if request.method == "POST", request.path == "/api/albums", holdCreation,
               request.headers["authorization"] == "Bearer ui-test-session" {
                holdCreation = false
                creations.append(creation(body))
                pendingCreation = (id, connection)
                return
            }
            respond(route(request, body: body), to: connection, id: id)
            return
        }
        connection.receive(minimumIncompleteLength: 1, maximumLength: remaining) { [weak self] data, _, ended, failure in
            guard let self, failure == nil, let data, !data.isEmpty else { connection.cancel(); return }
            var body = prefix
            body.append(data)
            let left = remaining - data.count
            guard !ended || left == 0 else { connection.cancel(); return }
            self.receiveBody(body, remaining: left, request: request, from: connection, id: id)
        }
    }

    private func parseHeader(_ data: Data) -> Request? {
        guard let text = String(data: data, encoding: .utf8) else { return nil }
        let lines = text.components(separatedBy: "\r\n")
        let first = (lines.first ?? "").split(separator: " ")
        guard first.count == 3, let url = URLComponents(string: "http://127.0.0.1" + String(first[1])) else { return nil }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            headers[String(line[..<colon]).lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        let query = Dictionary((url.queryItems ?? []).map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { _, last in last })
        return Request(method: String(first[0]), path: url.path, query: query, headers: headers)
    }

    private func route(_ request: Request, body: [String: Any]) -> Response {
        let path = request.path
        let method = request.method
        let expectedMethods = [
            "/api/server/ping": "GET", "/api/server/version": "GET", "/api/server/features": "GET",
            "/api/server/config": "GET", "/api/auth/login": "POST", "/api/auth/validateToken": "POST",
            "/api/auth/logout": "POST", "/api/users/me": "GET", "/api/users": "GET", "/api/people": "GET",
            "/api/memories": "GET", "/api/map/markers": "GET", "/api/shared-links": "GET",
            "/api/search/explore": "GET", "/api/search/suggestions": "GET", "/api/activities": "GET",
            "/api/server/about": "GET", "/api/server/storage": "GET", "/api/server/version-check": "GET",
            "/api/auth/status": "GET", "/api/assets/statistics": "GET", "/api/sync/stream": "POST",
            "/api/sync/ack": "POST", "/api/search/metadata": "POST", "/api/search/smart": "POST",
            "/api/duplicates": "GET", "/api/duplicates/resolve": "POST"]
        if let expected = expectedMethods[path], expected != method {
            unexpectedRequests.append("\(method) \(path), expected \(expected)")
            return error(405, "Unexpected HTTP method")
        }
        switch path {
        case "/api/server/ping": return json(["res": "pong"])
        case "/api/server/version": return json(["major": 3, "minor": 0, "patch": 0])
        case "/api/server/features": return json(["passwordLogin": true, "oauth": false, "search": true,
            "duplicateDetection": true, "trash": true, "map": true, "facialRecognition": true])
        case "/api/server/config": return json(["isInitialized": true, "isOnboarded": true, "trashDays": 30])
        case "/api/auth/login":
            guard method == "POST", body["email"] as? String == Self.email,
                  body["password"] as? String == Self.password else { return error(401, "Invalid synthetic credentials") }
            return json(["accessToken": "ui-test-session", "userId": ownerID, "userEmail": Self.email,
                "name": "Synthetic UI Library", "isAdmin": false, "shouldChangePassword": false, "isOnboarded": true])
        default: break
        }
        guard request.headers["authorization"] == "Bearer ui-test-session" else { return error(401, "Authentication required") }
        switch path {
        case "/api/auth/validateToken", "/api/auth/logout", "/api/sync/ack": return json([:])
        case "/api/users/me": return json(["id": ownerID, "email": Self.email, "name": "Synthetic UI Library", "profileImagePath": ""])
        case "/api/users", "/api/memories", "/api/map/markers", "/api/shared-links", "/api/search/explore", "/api/search/suggestions", "/api/activities": return json([])
        case "/api/people": return json(["people": [], "hasNextPage": false])
        case "/api/server/about": return json(["version": "v3.0.0"])
        case "/api/server/storage": return json(["diskUseRaw": 0, "diskSizeRaw": 1_000_000_000])
        case "/api/server/version-check": return json(["releaseVersion": "v3.0.0", "checkedAt": date])
        case "/api/auth/status": return json(["pinCode": true, "isElevated": false])
        case "/api/assets/statistics":
            let count = Self.names.count - trashedIDs.count
            return json(["images": count, "videos": 0, "total": count])
        case "/api/sync/stream":
            var lines = Self.names.enumerated().map { index, name -> [String: Any] in
                var value = asset(Self.assetID(name))
                value["ownerId"] = ownerID
                value["width"] = 300
                value["height"] = 200
                value["deletedAt"] = trashedIDs.contains(Self.assetID(name)) ? date : NSNull()
                return ["type": "AssetV2", "data": value, "ack": "AssetV2|\(index + 1)"]
            }
            lines.append(["type": "SyncCompleteV1", "data": [:], "ack": "SyncCompleteV1|1"])
            let data = lines.reduce(into: Data()) { result, value in
                result.append((try? JSONSerialization.data(withJSONObject: value)) ?? Data())
                result.append(10)
            }
            return Response(status: 200, data: data, type: "application/x-ndjson")
        case "/api/search/metadata", "/api/search/smart":
            var ids = Self.names.map(Self.assetID).filter { body["withDeleted"] as? Bool == true || !trashedIDs.contains($0) }
            if let scope = body["albumIds"] as? [String] {
                let admitted = Set(albums.filter { scope.contains($0.id) }.flatMap(\.assetIDs))
                ids.removeAll { !admitted.contains($0) }
            }
            if body["isFavorite"] as? Bool == true || body["visibility"] as? String == "archive" { ids = [] }
            if let type = body["type"] as? String, type != "IMAGE" { ids = [] }
            let size = max(1, body["size"] as? Int ?? 100), page = max(1, body["page"] as? Int ?? 1)
            let start = min(ids.count, (page - 1) * size), end = min(ids.count, start + size)
            return json(["assets": ["items": ids[start..<end].map(asset), "total": ids.count,
                "nextPage": end < ids.count ? String(page + 1) as Any : NSNull()]])
        case "/api/albums":
            if method == "GET" {
                return json(albums.filter { request.query["assetId"].map($0.assetIDs.contains) ?? true }.map(album))
            }
            if method == "POST" {
                let submitted = creation(body)
                creations.append(submitted)
                guard !submitted.name.isEmpty else { return error(400, "Album name required") }
                let value = Album(id: UUID().uuidString, name: submitted.name, description: submitted.description,
                    shared: false, assetIDs: submitted.assetIDs)
                albums.append(value)
                return json(album(value), status: 201)
            }
        case "/api/duplicates":
            duplicateReads += 1
            return json(groups.map { ["duplicateId": $0.id, "assets": $0.members.map(asset), "suggestedKeepAssetIds": $0.suggested] })
        case "/api/duplicates/resolve":
            guard method == "POST", let submitted = body["groups"] as? [[String: Any]], submitted.count == 1,
                  let item = submitted.first, let id = item["duplicateId"] as? String,
                  let index = groups.firstIndex(where: { $0.id == id }),
                  let kept = item["keepAssetIds"] as? [String], let trashed = item["trashAssetIds"] as? [String],
                  !kept.isEmpty, !trashed.isEmpty, Set(kept).isDisjoint(with: Set(trashed)),
                  Set(kept + trashed) == Set(groups[index].members) else { return error(400, "Invalid current duplicate partition") }
            resolutions.append(Resolution(groupID: id, keepIDs: Set(kept), trashIDs: Set(trashed)))
            trashedIDs.formUnion(trashed)
            groups.remove(at: index)
            return json([["id": id, "success": true]])
        default: break
        }
        let parts = path.split(separator: "/").map(String.init)
        if parts.count >= 3, parts[1] == "assets", Self.names.map(Self.assetID).contains(parts[2]) {
            guard method == "GET" else {
                unexpectedRequests.append("\(method) \(path), expected GET")
                return error(405, "Unexpected asset method")
            }
            if parts.last == "thumbnail" || parts.last == "original" { return Response(status: 200, data: image, type: "image/jpeg") }
            if parts.count == 3 { return json(asset(parts[2])) }
        }
        if parts.count == 3, parts[1] == "albums", let value = albums.first(where: { $0.id == parts[2] }) {
            guard method == "GET" else {
                unexpectedRequests.append("\(method) \(path), expected GET")
                return error(405, "Unexpected album method")
            }
            return json(album(value))
        }
        if method == "DELETE", parts.count == 3, parts[1] == "duplicates", groups.contains(where: { $0.id == parts[2] }) {
            dismissedGroups.append(parts[2])
            groups.removeAll { $0.id == parts[2] }
            return json([:])
        }
        unexpectedRequests.append("\(method) \(path)")
        return error(404, "Unsupported synthetic route")
    }

    private func asset(_ id: String) -> [String: Any] {
        ["id": id, "type": "IMAGE", "originalFileName": Self.names.first { Self.assetID($0) == id } ?? "Fixture.jpg",
         "ownerId": ownerID, "checksum": Data(id.utf8).base64EncodedString(), "fileCreatedAt": date,
         "fileModifiedAt": date, "createdAt": date, "localDateTime": date, "isFavorite": false,
         "isArchived": false, "isEdited": false, "isTrashed": trashedIDs.contains(id), "visibility": "timeline",
         "exifInfo": ["exifImageWidth": 300, "exifImageHeight": 200], "people": []]
    }
    private func album(_ value: Album) -> [String: Any] {
        let ids = value.assetIDs.filter { !trashedIDs.contains($0) }
        return ["id": value.id, "albumName": value.name, "description": value.description ?? "",
            "assetCount": ids.count, "shared": value.shared,
            "albumThumbnailAssetId": ids.first.map { $0 as Any } ?? NSNull(), "createdAt": date, "updatedAt": date,
            "albumUsers": [["user": ["id": ownerID], "role": "owner"]]]
    }
    private func creation(_ body: [String: Any]) -> Creation {
        Creation(name: body["albumName"] as? String ?? "", description: body["description"] as? String,
            assetIDs: body["assetIds"] as? [String] ?? [])
    }
    private func json(_ value: Any, status: Int = 200) -> Response {
        Response(status: status, data: (try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])) ?? Data())
    }
    private func error(_ status: Int, _ message: String) -> Response { json(["statusCode": status, "message": message, "error": message], status: status) }
    private func respond(_ response: Response, to connection: NWConnection, id: UUID) {
        var data = Data("HTTP/1.1 \(response.status) Response\r\nContent-Type: \(response.type)\r\nContent-Length: \(response.data.count)\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n".utf8)
        data.append(response.data)
        connection.send(content: data, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { [weak self] _ in
            connection.cancel()
            self?.connections.removeValue(forKey: id)
        })
    }
}
