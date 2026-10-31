import Foundation

@MainActor
final class PhotoSearchRepository: SearchRepository {
    static let semanticResultLimit = 100

    private enum Source: String {
        case smart, caption, filename, ocr, metadata
    }

    private struct Query: Equatable {
        let request: SearchRequestDTO
        let options: PhotoSearchOptions
    }

    private struct Cache {
        let query: Query
        let context: SessionRequestContext
        let items: [AssetResponseDTO]
        let incompleteSources: [String]?
    }

    private struct StreamResult {
        let source: Source
        let result: Result<[AssetResponseDTO], Error>
    }

    private let api: APIClient
    private let source: SearchRepository
    private let dataManager: SwiftDataManager
    private let snapshotGeneration = LocalSnapshot.generation
    private var requestID = UUID()
    private var cache: Cache?

    init(api: APIClient, dataManager: SwiftDataManager? = nil, source: SearchRepository? = nil) {
        self.api = api
        self.dataManager = dataManager ?? .shared
        self.source = source ?? SearchRepository(api: api, dataManager: dataManager)
        super.init(api: api, dataManager: dataManager)
    }

    override func search(_ request: SearchRequestDTO, options: PhotoSearchOptions = .init()) async throws -> SearchResponseDTO {
        try Task.checkCancellation()
        let context = api.session.snapshot
        try checkCurrent(context)
        let page = max(1, request.page ?? 1)
        if page == 1 {
            requestID = UUID()
            cache = nil
        }
        let query = query(for: request, options: options)
        let normalized = query.request
        let pageSize = normalized.size ?? 100
        if page > 1 {
            guard let cache, cache.query == query else { throw PhotoSearchError.missingCachedSearch }
            try checkCurrent(cache.context)
            return try response(cache, page: page, pageSize: pageSize)
        }

        let currentRequest = requestID
        let sources: [Source] = normalized.query == nil ? [.metadata] : [.smart, .caption, .filename, .ocr]
        let streams = try await withThrowingTaskGroup(of: StreamResult.self) { group in
            for source in sources {
                group.addTask { @MainActor in
                    do {
                        let items = try await self.allAssets(query.request, source: source,
                            requestID: currentRequest, context: context)
                        return StreamResult(source: source, result: .success(items))
                    } catch is CancellationError {
                        throw CancellationError()
                    } catch {
                        return StreamResult(source: source, result: .failure(error))
                    }
                }
            }
            var results: [Source: Result<[AssetResponseDTO], Error>] = [:]
            for try await result in group { results[result.source] = result.result }
            return results
        }
        try checkCurrent(context, requestID: currentRequest)
        var items: [AssetResponseDTO] = []
        var positions: [String: Int] = [:]
        var failures: [String] = []
        var firstError: Error?
        var successfulSources = 0
        for source in sources {
            guard let result = streams[source] else { continue }
            switch result {
            case .success(let assets):
                successfulSources += 1
                for asset in assets {
                    if let index = positions[asset.id] {
                        if items[index].addedAt == nil { items[index].addedAt = asset.addedAt }
                        if items[index].isEdited == nil { items[index].isEdited = asset.isEdited }
                        if items[index].exifInfo == nil { items[index].exifInfo = asset.exifInfo }
                    } else {
                        positions[asset.id] = items.count
                        items.append(asset)
                    }
                }
            case .failure(let error):
                failures.append(source.rawValue)
                if firstError == nil { firstError = error }
            }
        }
        guard successfulSources > 0 else { throw firstError ?? PhotoSearchError.incompletePage }
        items = try refined(items, request: normalized, options: options)
        try checkCurrent(context, requestID: currentRequest)
        let completed = Cache(query: query, context: context, items: items, incompleteSources: failures.isEmpty ? nil : failures)
        cache = completed
        return try response(completed, page: 1, pageSize: pageSize)
    }

    override func exactResultCount(for request: SearchRequestDTO, options: PhotoSearchOptions,
                                   excluding ids: Set<String>) -> Int? {
        guard snapshotGeneration == LocalSnapshot.generation, let cache,
              cache.query == query(for: request, options: options),
              (try? api.checkCurrent(cache.context)) != nil else { return nil }
        let policy = AssetVisibilityPolicy(scope: .timeline, dataManager: dataManager)
        return cache.items.lazy.filter { !ids.contains($0.id) && policy.allows(id: $0.id) }.count
    }

    private func query(for request: SearchRequestDTO, options: PhotoSearchOptions) -> Query {
        var normalized = request
        normalized.query = request.query?.trimmingCharacters(in: .whitespacesAndNewlines)
        if normalized.query?.isEmpty == true { normalized.query = nil }
        if options.favoritesOnly { normalized.isFavorite = true }
        normalized.page = 1
        normalized.size = min(1_000, max(1, request.size ?? 100))
        return Query(request: normalized, options: options)
    }

    private func allAssets(_ initial: SearchRequestDTO, source: Source, requestID: UUID,
                           context: SessionRequestContext) async throws -> [AssetResponseDTO] {
        var request = initial
        request.page = 1
        request.size = source == .smart ? Self.semanticResultLimit : 1_000
        request.visibility = "timeline"
        // Legacy withExif uses an inner join and omits photos awaiting EXIF extraction.
        request.withExif = false
        if let text = request.query {
            // Legacy caption and filename fields are ILIKE patterns, while typed text is literal.
            let pattern = text.replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "%", with: "\\%")
                .replacingOccurrences(of: "_", with: "\\_")
            request.query = nil
            request.description = nil
            request.originalFileName = nil
            request.ocr = nil
            switch source {
            case .smart: request.query = text
            case .caption: request.description = pattern
            case .filename: request.originalFileName = pattern
            case .ocr: request.ocr = text
            case .metadata: break
            }
        }
        var items: [AssetResponseDTO] = []
        var seen = Set<String>()
        while true {
            try checkCurrent(context, requestID: requestID)
            let response = source == .smart
                ? try await self.source.smartSearch(request)
                : try await self.source.metadataSearch(request)
            try checkCurrent(context, requestID: requestID)
            let previousCount = seen.count
            for item in response.assets.items where seen.insert(item.id).inserted { items.append(item) }
            // Smart search ranks the entire indexed library without a similarity cutoff.
            // Keep its top matches rather than treating every indexed photo as a match.
            if source == .smart { return Array(items.prefix(Self.semanticResultLimit)) }
            guard let nextPage = response.assets.nextPage else { return items }
            guard seen.count > previousCount, let next = Int(nextPage), next > (request.page ?? 1) else {
                throw PhotoSearchError.incompletePage
            }
            request.page = next
        }
    }

    private func refined(_ assets: [AssetResponseDTO], request: SearchRequestDTO,
                         options: PhotoSearchOptions) throws -> [AssetResponseDTO] {
        let policy = AssetVisibilityPolicy(scope: .timeline, dataManager: dataManager)
        var assets = assets.filter { $0.isTimelineVisible && policy.allows(id: $0.id) }
        if let raw = request.exclusiveTakenBefore {
            guard let end = ISO8601DateFormatter.immichFractional.date(from: raw)
                    ?? ISO8601DateFormatter.immichPlain.date(from: raw) else { throw URLError(.badURL) }
            assets.removeAll { $0.fileCreatedAt >= end }
        }
        if options.sortOrder == .recentlyAdded, assets.contains(where: { $0.addedAt == nil }) {
            throw PhotoSearchError.missingAddedDates
        }
        if options.editedOnly, assets.contains(where: {
            MediaEditingPipeline.shared.effectiveEdited($0.id, fallback: $0.isEdited, session: api.session) == nil
        }) {
            throw PhotoSearchError.missingEditInformation
        }
        let metadata = Dictionary(uniqueKeysWithValues: assets.map {
            ($0.id, LibraryAssetMetadata(addedAt: $0.addedAt, isEdited: options.editedOnly ? MediaEditingPipeline.shared.effectiveEdited($0.id, fallback: $0.isEdited,
                session: api.session) : $0.isEdited, isFavorite: $0.isFavorite))
        })
        let ordered = LibraryPresentation.assets(assets.map(AssetLite.init), options: options.libraryOptions,
            metadata: metadata).reversed()
        let byID = Dictionary(uniqueKeysWithValues: assets.map { ($0.id, $0) })
        return ordered.compactMap { byID[$0.id] }
    }

    private func response(_ cache: Cache, page: Int, pageSize: Int) throws -> SearchResponseDTO {
        let policy = AssetVisibilityPolicy(scope: .timeline, dataManager: dataManager)
        let offset = (page - 1).multipliedReportingOverflow(by: pageSize)
        guard !offset.overflow else { throw PhotoSearchError.incompletePage }
        var start = min(offset.partialValue, cache.items.count)
        var currentPage = page
        while true {
            let end = min(start + pageSize, cache.items.count)
            let items = cache.items[start..<end].filter { policy.allows(id: $0.id) }
            if !items.isEmpty || end == cache.items.count {
                return SearchResponseDTO(assets: .init(items: items,
                    total: cache.items.lazy.filter { policy.allows(id: $0.id) }.count,
                    nextPage: end < cache.items.count ? String(currentPage + 1) : nil),
                    incompleteSources: cache.incompleteSources)
            }
            // Preserve cached page boundaries when earlier photos become private.
            start = end
            currentPage += 1
        }
    }

    private func checkCurrent(_ context: SessionRequestContext, requestID: UUID? = nil) throws {
        try Task.checkCancellation()
        try api.checkCurrent(context)
        guard snapshotGeneration == LocalSnapshot.generation,
              requestID.map({ $0 == self.requestID }) ?? true else { throw CancellationError() }
    }
}
