import Foundation

class MemoriesRepository {
    private let api: APIClient
    private let dataManager: SwiftDataManager?
    private let recordsVisibility: Bool

    init(api: APIClient, dataManager: SwiftDataManager? = nil, recordsVisibility: Bool = true) {
        self.api = api
        self.dataManager = dataManager
        self.recordsVisibility = recordsVisibility
    }

    func getMemories() async throws -> [MemoryDTO] {
        let visibility = recordsVisibility ? await AssetVisibilityRequest(api: api, dataManager: dataManager) : nil
        // GET /memories mengembalikan array polos, bukan {memories: [...]}.
        let memories: [MemoryDTO] = try await api.send(.init(path: "/memories"))
        await visibility?.record(memories.flatMap(\.assets))
        return memories
    }
}
