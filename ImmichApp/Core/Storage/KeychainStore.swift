import Foundation

struct KeychainStore: SessionCredentialStore {
    func save(_ value: String, for key: String) {
        SharedKeychainStore.save(value, for: key)
    }

    func read(_ key: String) -> String? {
        SharedKeychainStore.read(key)
    }

    func delete(_ key: String) {
        SharedKeychainStore.delete(key)
    }
}
