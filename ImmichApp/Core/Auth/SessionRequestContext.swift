import Foundation

struct SessionRequestContext: Equatable, Sendable {
    let baseURL: URL?
    let authHeaders: [String: String]
    let revision: UUID
    let accountGeneration: UUID
    let isAuthenticated: Bool
}

protocol SessionCredentialStore {
    func read(_ key: String) -> String?
    func save(_ value: String, for key: String)
    func delete(_ key: String)
}
