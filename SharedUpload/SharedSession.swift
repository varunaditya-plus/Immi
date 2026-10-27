import Foundation
import Security

enum SelfPhotosSharedContainer {
    static let appGroup = "group.xyz.0xmwehehe.ImmichApp"
    static let keychainAccessGroup = "5KQGTJX2K7.xyz.0xmwehehe.ImmichApp.shared"

    static var defaults: UserDefaults {
        UserDefaults(suiteName: appGroup) ?? .standard
    }

    static var rootURL: URL? {
        FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: appGroup)
    }
}

/// Keychain yang dapat dibaca aplikasi utama dan Share Extension.
///
/// Entri lama SelfPhotos tidak memakai access group. `read` memigrasikannya
/// saat aplikasi utama pertama kali dibuka setelah pembaruan; extension tidak
/// pernah menerima salinan token di UserDefaults atau berkas App Group.
enum SharedKeychainStore {
    /// Publish the complete extension credential as one Keychain value.
    static func saveData(_ data: Data, for key: String) -> Bool {
        let query = baseQuery(key, shared: true)
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecSuccess { return true }
        guard status == errSecItemNotFound else { return false }
        var item = query
        item.merge(attributes) { _, value in value }
        let added = SecItemAdd(item as CFDictionary, nil)
        if added == errSecDuplicateItem {
            return SecItemUpdate(query as CFDictionary, attributes as CFDictionary) == errSecSuccess
        }
        return added == errSecSuccess
    }

    static func readData(_ key: String) -> Data? {
        data(for: key, shared: true)
    }

    static func save(_ value: String, for key: String) {
        let data = Data(value.utf8)
        let query = baseQuery(key, shared: true)
        SecItemDelete(query as CFDictionary)
        var add = query
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly

        // Hosted unit tests do not carry the app's keychain entitlement. Keep
        // the legacy fallback there without weakening the shipping app path.
        if SecItemAdd(add as CFDictionary, nil) != errSecSuccess {
            saveLegacy(data, for: key)
        }
    }

    static func read(_ key: String) -> String? {
        if let shared = read(key, shared: true) { return shared }
        guard let legacy = read(key, shared: false) else { return nil }
        save(legacy, for: key)
        return legacy
    }

    static func delete(_ key: String) {
        SecItemDelete(baseQuery(key, shared: true) as CFDictionary)
        SecItemDelete(baseQuery(key, shared: false) as CFDictionary)
    }

    private static func baseQuery(_ key: String, shared: Bool) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key,
        ]
        if shared {
            query[kSecAttrAccessGroup as String] = SelfPhotosSharedContainer.keychainAccessGroup
        }
        return query
    }

    private static func read(_ key: String, shared: Bool) -> String? {
        guard let data = data(for: key, shared: shared) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func data(for key: String, shared: Bool) -> Data? {
        var query = baseQuery(key, shared: shared)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data
        else { return nil }
        return data
    }

    private static func saveLegacy(_ data: Data, for key: String) {
        let query = baseQuery(key, shared: false)
        SecItemDelete(query as CFDictionary)
        var add = query
        add[kSecValueData as String] = data
        SecItemAdd(add as CFDictionary, nil)
    }
}

struct SharedImmichSession: Codable, Equatable, Sendable {
    let apiURL: URL
    let userID: String
    let authMode: String

    var displayServerURL: String {
        var value = apiURL.absoluteString
        if value.hasSuffix("/api") { value.removeLast(4) }
        while value.hasSuffix("/") { value.removeLast() }
        return value
    }

    var owner: SharedUploadOwner {
        SharedUploadOwner(server: apiURL.absoluteString, userID: userID)
    }

    func credential() -> SharedUploadCredential? {
        SharedSessionStore.shared.credential(for: self)
    }
}

final class SharedSessionStore {
    static let shared = SharedSessionStore()

    private static let credentialKey = "share.credential.v1"
    private static let legacySessionKey = "share.session.v1"

    private struct Record: Codable {
        let session: SharedImmichSession
        let token: String

        var isValid: Bool {
            !token.isEmpty && !session.userID.isEmpty
                && session.apiURL.host != nil
                && ["http", "https"].contains(session.apiURL.scheme?.lowercased() ?? "")
                && ["bearer", "apiKey"].contains(session.authMode)
        }
    }

    private let read: () -> Data?
    private let write: (Data) -> Bool
    private let remove: () -> Void

    private convenience init() {
        self.init(
            read: { SharedKeychainStore.readData(Self.credentialKey) },
            write: { SharedKeychainStore.saveData($0, for: Self.credentialKey) },
            remove: { SharedKeychainStore.delete(Self.credentialKey) })
    }

    init(read: @escaping () -> Data?, write: @escaping (Data) -> Bool, remove: @escaping () -> Void) {
        self.read = read
        self.write = write
        self.remove = remove
    }

    @discardableResult
    func save(apiURL: URL, userID: String, authMode: String, token: String) -> Bool {
        let record = Record(session: SharedImmichSession(
            apiURL: apiURL, userID: userID, authMode: authMode), token: token)
        guard record.isValid, let data = try? JSONEncoder().encode(record), write(data) else {
            clear()
            return false
        }
        SelfPhotosSharedContainer.defaults.removeObject(forKey: Self.legacySessionKey)
        return true
    }

    func load() -> SharedImmichSession? {
        record()?.session
    }

    func credential(for expected: SharedImmichSession) -> SharedUploadCredential? {
        guard let record = record(), record.session == expected else { return nil }
        return SharedUploadCredential(
            apiURL: record.session.apiURL,
            owner: record.session.owner,
            authHeaders: record.session.authMode == "apiKey"
                ? ["x-api-key": record.token]
                : ["Authorization": "Bearer \(record.token)"])
    }

    func clear() {
        remove()
        SelfPhotosSharedContainer.defaults.removeObject(forKey: Self.legacySessionKey)
    }

    private func record() -> Record? {
        guard let data = read(), let record = try? JSONDecoder().decode(Record.self, from: data),
              record.isValid else { return nil }
        return record
    }
}

enum SharedDeviceIdentity {
    private static let key = "device.identity"

    static let current: String = {
        let defaults = SelfPhotosSharedContainer.defaults
        if let existing = defaults.string(forKey: key), !existing.isEmpty {
            return existing
        }

        // Migrate the value written by versions before Share Extension support.
        if let legacy = UserDefaults.standard.string(forKey: key), !legacy.isEmpty {
            defaults.set(legacy, forKey: key)
            return legacy
        }

        let fresh = UUID().uuidString
        defaults.set(fresh, forKey: key)
        return fresh
    }()
}
