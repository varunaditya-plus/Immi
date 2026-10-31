import CryptoKit
import Foundation
import Observation

enum MediaEditStoreError: LocalizedError, Equatable {
    case accountUnavailable, contextChanged, sourceChanged, editChanged, unsupportedRecord, corruptRecord

    var errorDescription: String? {
        switch self {
        case .accountUnavailable: String(localized: "Sign in to access your saved edits.")
        case .contextChanged: String(localized: "The account changed. Open the editor again.")
        case .sourceChanged: String(localized: "The original media changed. Open the editor again.")
        case .editChanged: String(localized: "These edits changed in another editor. Open the editor again.")
        case .unsupportedRecord: String(localized: "These saved edits use an unsupported format. Update the app before changing them.")
        case .corruptRecord: String(localized: "Saved edits could not be read. The original media is unchanged.")
        }
    }
}

struct MediaEditRecord: Codable, Equatable, Sendable {
    let type: String
    let schemaVersion: Int
    let sourceFingerprint: String
    let payload: Data

    init(type: String, schemaVersion: Int, sourceFingerprint: String, payload: Data) {
        self.type = type
        self.schemaVersion = schemaVersion
        self.sourceFingerprint = sourceFingerprint
        self.payload = payload
    }

    init<Value: Encodable>(type: String, schemaVersion: Int, sourceFingerprint: String, value: Value) throws {
        self.init(type: type, schemaVersion: schemaVersion, sourceFingerprint: sourceFingerprint,
            payload: try JSONEncoder().encode(value))
    }

    func decode<Value: Decodable>(_ type: Value.Type, supportedSchemaVersion: Int) throws -> Value {
        guard schemaVersion > 0, schemaVersion <= supportedSchemaVersion else { throw MediaEditStoreError.unsupportedRecord }
        do { return try JSONDecoder().decode(type, from: payload) }
        catch { throw MediaEditStoreError.corruptRecord }
    }
}

@MainActor
@Observable
final class MediaEditStore {
    static let shared = MediaEditStore()

    struct Access: Equatable, Sendable {
        let owner: BackupQueueOwner
        let requestRevision: UUID
        let generation: UUID
    }

    struct Revision: Hashable, Sendable {
        fileprivate let owner: String?
        fileprivate let request: UUID?
        fileprivate let generation: UUID?
        fileprivate let content: UUID
    }

    struct Token: Sendable {
        let assetID: String
        let sourceFingerprint: String
        fileprivate let context: Context
        fileprivate let fileDigest: String?
    }

    fileprivate struct Context: Equatable, Sendable {
        let ownerKey: String
        let requestRevision: UUID
        let generation: UUID
    }

    private struct Header: Decodable { let formatVersion: Int }
    private struct Envelope: Codable {
        let formatVersion: Int
        let revision: UUID
        let isDeleted: Bool
        let record: MediaEditRecord?
    }

    @ObservationIgnored private let directory: URL
    @ObservationIgnored private var access: @MainActor () -> Access?
    @ObservationIgnored private weak var configuredSession: SessionManager?
    private var contentRevision = UUID()

    init(directory: URL? = nil, access: @escaping @MainActor () -> Access? = { nil }) {
        self.directory = directory ?? URL.applicationSupportDirectory.appendingPathComponent("media-edits", isDirectory: true)
        self.access = access
    }

    func configure(session: SessionManager) {
        guard configuredSession !== session else { return }
        configuredSession = session
        access = { [weak session] in
            guard let session, session.isLoggedIn, let owner = session.backupQueueOwner else { return nil }
            return Access(owner: owner, requestRevision: session.requestRevision, generation: session.accountGeneration)
        }
        contentRevision = UUID()
    }

    var revision: Revision {
        let context = try? currentContext()
        return Revision(owner: context?.ownerKey, request: context?.requestRevision,
            generation: context?.generation, content: contentRevision)
    }

    func capture(assetID: String, sourceFingerprint: String) throws -> Token {
        guard !assetID.isEmpty, !sourceFingerprint.isEmpty else { throw MediaEditStoreError.sourceChanged }
        let context = try currentContext()
        let data = try contents(at: url(assetID: assetID, context: context))
        if let data { _ = try decode(data) }
        try validate(context)
        return Token(assetID: assetID, sourceFingerprint: sourceFingerprint, context: context,
            fileDigest: data.map(Self.digest))
    }

    func read(assetID: String) throws -> MediaEditRecord? {
        let context = try currentContext()
        let data = try contents(at: url(assetID: assetID, context: context))
        let record = try data.flatMap(decode)
        try validate(context)
        return record
    }

    func read(using token: Token) throws -> MediaEditRecord? {
        try checkedContents(token).flatMap(decode)
    }

    func save(_ record: MediaEditRecord, using token: Token,
              isCurrent: @MainActor () -> Bool = { true }) throws {
        let existing = try checkedContents(token, isCurrent: isCurrent).flatMap(decode)
        guard record.sourceFingerprint == token.sourceFingerprint else { throw MediaEditStoreError.sourceChanged }
        try validate(record)
        if let existing {
            guard existing.type == record.type, existing.schemaVersion <= record.schemaVersion else {
                throw MediaEditStoreError.unsupportedRecord
            }
        }
        if existing == record { return }
        try write(record, using: token, isCurrent: isCurrent)
    }

    func remove(using token: Token, type: String, supportedSchemaVersion: Int,
                isCurrent: @MainActor () -> Bool = { true }) throws {
        if let data = try checkedContents(token, isCurrent: isCurrent) {
            guard let record = try decode(data) else { return }
            guard record.type == type, record.schemaVersion <= supportedSchemaVersion else {
                throw MediaEditStoreError.unsupportedRecord
            }
        }
        // Keeping a tombstone prevents an older unsaved editor from resurrecting reverted edits.
        try write(nil, using: token, isCurrent: isCurrent)
    }

    private func write(_ record: MediaEditRecord?, using token: Token, isCurrent: @MainActor () -> Bool) throws {
        let data = try JSONEncoder().encode(Envelope(formatVersion: 1, revision: UUID(), isDeleted: record == nil, record: record))
        let destination = url(assetID: token.assetID, context: token.context)
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true,
            attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
        try validate(token.context)
        guard isCurrent() else { throw MediaEditStoreError.sourceChanged }
        try data.write(to: destination, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        contentRevision = UUID()
    }

    private func checkedContents(_ token: Token, isCurrent: @MainActor () -> Bool = { true }) throws -> Data? {
        try validate(token.context)
        guard isCurrent() else { throw MediaEditStoreError.sourceChanged }
        let data = try contents(at: url(assetID: token.assetID, context: token.context))
        guard data.map(Self.digest) == token.fileDigest else { throw MediaEditStoreError.editChanged }
        return data
    }

    private func currentContext() throws -> Context {
        guard let current = access() else { throw MediaEditStoreError.accountUnavailable }
        let ownerKey = try Self.ownerKey(current.owner)
        return Context(ownerKey: ownerKey, requestRevision: current.requestRevision, generation: current.generation)
    }

    private func validate(_ context: Context) throws {
        guard try currentContext() == context else { throw MediaEditStoreError.contextChanged }
    }

    private func url(assetID: String, context: Context) -> URL {
        directory.appendingPathComponent(context.ownerKey, isDirectory: true)
            .appendingPathComponent(Self.digest(Data(assetID.utf8)) + ".json")
    }

    private func contents(at url: URL) throws -> Data? {
        do { return try Data(contentsOf: url) }
        catch let error as CocoaError where error.code == .fileReadNoSuchFile { return nil }
    }

    private func decode(_ data: Data) throws -> MediaEditRecord? {
        do {
            let decoder = JSONDecoder()
            guard try decoder.decode(Header.self, from: data).formatVersion == 1 else {
                throw MediaEditStoreError.unsupportedRecord
            }
            let envelope = try decoder.decode(Envelope.self, from: data)
            guard envelope.isDeleted == (envelope.record == nil) else { throw MediaEditStoreError.corruptRecord }
            if let record = envelope.record { try validate(record) }
            return envelope.record
        } catch let error as MediaEditStoreError { throw error }
        catch { throw MediaEditStoreError.corruptRecord }
    }

    private func validate(_ record: MediaEditRecord) throws {
        guard !record.type.isEmpty, record.schemaVersion > 0, !record.sourceFingerprint.isEmpty, !record.payload.isEmpty,
              (try? JSONSerialization.jsonObject(with: record.payload, options: .fragmentsAllowed)) != nil else {
            throw MediaEditStoreError.corruptRecord
        }
    }

    private static func ownerKey(_ owner: BackupQueueOwner) throws -> String {
        guard !owner.userID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              var parts = URLComponents(string: owner.server), let scheme = parts.scheme?.lowercased(),
              ["http", "https"].contains(scheme), let host = parts.host, !host.isEmpty,
              parts.user == nil, parts.password == nil, parts.query == nil, parts.fragment == nil else {
            throw MediaEditStoreError.accountUnavailable
        }
        parts.scheme = scheme
        parts.host = host.lowercased()
        if parts.port == (scheme == "https" ? 443 : 80) { parts.port = nil }
        var path = parts.percentEncodedPath
        while path.hasSuffix("/") { path.removeLast() }
        if path.hasSuffix("/api") { path.removeLast(4) }
        parts.percentEncodedPath = path + "/api"
        guard let server = parts.url?.absoluteString else { throw MediaEditStoreError.accountUnavailable }
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return digest(try encoder.encode(BackupQueueOwner(server: server, userID: owner.userID)))
    }

    private static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
