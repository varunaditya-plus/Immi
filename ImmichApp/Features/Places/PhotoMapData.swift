import CryptoKit
import Foundation

struct PhotoMapBounds: Equatable {
    let centerLatitude: Double
    let centerLongitude: Double
    let latitudeDelta: Double
    let longitudeDelta: Double

    init(centerLatitude: Double, centerLongitude: Double, latitudeDelta: Double, longitudeDelta: Double) {
        self.centerLatitude = centerLatitude.isFinite ? min(90, max(-90, centerLatitude)) : 0
        self.centerLongitude = centerLongitude.isFinite ? Self.longitude(centerLongitude) : 0
        self.latitudeDelta = latitudeDelta.isFinite && latitudeDelta > 0 ? min(180, max(1e-7, latitudeDelta)) : 180
        self.longitudeDelta = longitudeDelta.isFinite && longitudeDelta > 0 ? min(360, max(1e-7, longitudeDelta)) : 360
    }

    var north: Double { min(90, centerLatitude + latitudeDelta / 2) }
    var south: Double { max(-90, centerLatitude - latitudeDelta / 2) }

    func contains(_ marker: MapMarkerDTO) -> Bool {
        guard PhotoMapClustering.isValid(marker), marker.lat >= south, marker.lat <= north else { return false }
        return longitudeDelta == 360 || abs(Self.longitude(marker.lon - centerLongitude)) <= longitudeDelta / 2 + 1e-9
    }

    static func fitting(_ markers: [MapMarkerDTO]) -> Self? {
        let markers = PhotoMapClustering.validated(markers)
        guard let first = markers.first else { return nil }
        let latitudes = markers.map(\.lat)
        let low = latitudes.min() ?? first.lat, high = latitudes.max() ?? first.lat
        let longitudes = markers.map { $0.lon < 0 ? $0.lon + 360 : $0.lon }.sorted()
        var largestGap = -Double.infinity
        var arcStart = longitudes[0]
        for index in longitudes.indices {
            let next = index + 1 < longitudes.count ? longitudes[index + 1] : longitudes[0] + 360
            let gap = next - longitudes[index]
            if gap > largestGap {
                largestGap = gap
                arcStart = next.truncatingRemainder(dividingBy: 360)
            }
        }
        let arc = 360 - largestGap
        return Self(centerLatitude: (low + high) / 2, centerLongitude: arcStart + arc / 2,
            latitudeDelta: max(0.03, (high - low) * 1.25), longitudeDelta: max(0.03, arc * 1.25))
    }

    static func longitude(_ value: Double) -> Double {
        let remainder = (value + 180).truncatingRemainder(dividingBy: 360)
        return (remainder < 0 ? remainder + 360 : remainder) - 180
    }
}

struct PhotoMapCluster: Identifiable, Equatable {
    let id: String
    let markers: [MapMarkerDTO]
    let latitude: Double
    let longitude: Double

    var coverID: String { markers[0].id }
    var count: Int { markers.count }
    var memberIDs: Set<String> { Set(markers.map(\.id)) }

    var title: String {
        for field in [\MapMarkerDTO.city, \.state, \.country] {
            let values = markers.map { $0[keyPath: field]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "" }
            if let first = values.first, !first.isEmpty, values.allSatisfy({ $0 == first }) { return first }
        }
        return String(localized: "Photos")
    }

    fileprivate init(markers: [MapMarkerDTO], centerLongitude: Double) {
        self.markers = markers
        id = SHA256.hash(data: Data(markers.map(\.id).sorted().joined(separator: "\0").utf8))
            .map { String(format: "%02x", $0) }.joined()
        latitude = markers.map(\.lat).reduce(0, +) / Double(markers.count)
        // Average on the visible longitude arc so a Fiji/Samoa group stays at
        // the date line instead of moving its thumbnail to Greenwich.
        let offset = markers.map { PhotoMapBounds.longitude($0.lon - centerLongitude) }.reduce(0, +)
        longitude = PhotoMapBounds.longitude(centerLongitude + offset / Double(markers.count))
    }
}

enum PhotoMapClustering {
    static func isValid(_ marker: MapMarkerDTO) -> Bool {
        !marker.id.isEmpty && marker.lat.isFinite && marker.lon.isFinite
            && (-90...90).contains(marker.lat) && (-180...180).contains(marker.lon)
    }

    static func validated(_ markers: [MapMarkerDTO]) -> [MapMarkerDTO] {
        var seen = Set<String>()
        return markers.filter { isValid($0) && seen.insert($0.id).inserted }
    }

    @MainActor
    static func admitted(_ markers: [MapMarkerDTO], policy: AssetVisibilityPolicy) -> [MapMarkerDTO] {
        validated(markers).filter { policy.allows(id: $0.id) }
    }

    static func clusters(
        in markers: [MapMarkerDTO], bounds: PhotoMapBounds, viewportWidth: Double,
        viewportHeight: Double, cellSize: Double = 76
    ) -> [PhotoMapCluster] {
        struct Cell: Hashable { let x: Int; let y: Int }
        struct Stack {
            var id: Int
            var cells: [Cell]
            var count: Int
            var latitudeSum: Double
            var longitudeOffsetSum: Double
        }
        let width = viewportWidth.isFinite && viewportWidth > 0 ? min(100_000, viewportWidth) : 390
        let height = viewportHeight.isFinite && viewportHeight > 0 ? min(100_000, viewportHeight) : 844
        let size = cellSize.isFinite && cellSize >= 44 ? cellSize : 76
        let north = mercatorY(bounds.north), south = mercatorY(bounds.south)
        let verticalSpan = max(1e-12, south - north)
        var cells: [Cell: [MapMarkerDTO]] = [:]
        var originalOrder: [String: Int] = [:]
        for (index, marker) in validated(markers).enumerated() where bounds.contains(marker) {
            let x = (PhotoMapBounds.longitude(marker.lon - bounds.centerLongitude) / bounds.longitudeDelta + 0.5) * width
            let y = (mercatorY(marker.lat) - north) / verticalSpan * height
            let cell = Cell(x: Int(floor(x / size)), y: Int(floor(y / size)))
            originalOrder[marker.id] = index
            cells[cell, default: []].append(marker)
        }

        func point(_ stack: Stack) -> (x: Double, y: Double) {
            let latitude = stack.latitudeSum / Double(stack.count)
            let longitudeOffset = stack.longitudeOffsetSum / Double(stack.count)
            return ((longitudeOffset / bounds.longitudeDelta + 0.5) * width,
                    (mercatorY(latitude) - north) / verticalSpan * height)
        }
        func cell(at point: (x: Double, y: Double)) -> Cell {
            Cell(x: Int(floor(point.x / size)), y: Int(floor(point.y / size)))
        }
        var stacks: [Int: Stack] = [:]
        var nearby: [Cell: Set<Int>] = [:]
        let orderedCells = cells.keys.sorted { $0.y == $1.y ? $0.x < $1.x : $0.y < $1.y }
        for (index, initialCell) in orderedCells.enumerated() {
            guard let members = cells[initialCell]?.sorted(by: { $0.id < $1.id }) else { continue }
            var current = Stack(id: index, cells: [initialCell], count: members.count,
                latitudeSum: members.map(\.lat).reduce(0, +),
                longitudeOffsetSum: members.map { PhotoMapBounds.longitude($0.lon - bounds.centerLongitude) }.reduce(0, +))
            while true {
                let center = point(current), location = cell(at: center)
                var closest: (id: Int, squaredDistance: Double)?
                for x in (location.x - 1)...(location.x + 1) {
                    for y in (location.y - 1)...(location.y + 1) {
                        for id in nearby[Cell(x: x, y: y)] ?? [] {
                            guard let other = stacks[id] else { continue }
                            let otherCenter = point(other)
                            let dx = center.x - otherCenter.x, dy = center.y - otherCenter.y
                            let distance = dx * dx + dy * dy
                            guard distance < size * size else { continue }
                            if let previous = closest {
                                if distance < previous.squaredDistance
                                    || (distance == previous.squaredDistance && id < previous.id) {
                                    closest = (id, distance)
                                }
                            } else {
                                closest = (id, distance)
                            }
                        }
                    }
                }
                if let closest, let other = stacks.removeValue(forKey: closest.id) {
                    let previousLocation = cell(at: point(other))
                    nearby[previousLocation]?.remove(other.id)
                    if nearby[previousLocation]?.isEmpty == true { nearby.removeValue(forKey: previousLocation) }
                    current.id = min(current.id, other.id)
                    current.cells.append(contentsOf: other.cells)
                    current.count += other.count
                    current.latitudeSum += other.latitudeSum
                    current.longitudeOffsetSum += other.longitudeOffsetSum
                    // Moving a weighted center can bring another stack into range.
                    // Recheck its neighbors before publishing a non-overlapping pin.
                    continue
                }
                stacks[current.id] = current
                nearby[location, default: []].insert(current.id)
                break
            }
        }
        return stacks.values.map { stack in
            let members = stack.cells.flatMap { cells[$0] ?? [] }.sorted {
                originalOrder[$0.id, default: Int.max] < originalOrder[$1.id, default: Int.max]
            }
            return PhotoMapCluster(markers: members, centerLongitude: bounds.centerLongitude)
        }.sorted {
            originalOrder[$0.coverID, default: Int.max] < originalOrder[$1.coverID, default: Int.max]
        }
    }

    private static func mercatorY(_ latitude: Double) -> Double {
        let radians = min(85.05112878, max(-85.05112878, latitude)) * .pi / 180
        return (1 - log(tan(.pi / 4 + radians / 2)) / .pi) / 2
    }
}

@MainActor
enum PhotoMapSources {
    static func markers(
        server: [MapMarkerDTO], selectedLocal: [LocalPhoto], mappings: [String: String],
        policy: AssetVisibilityPolicy
    ) -> [MapMarkerDTO] {
        var result = PhotoMapClustering.validated(server)
        let serverIDs = Set(result.map(\.id))
        let local = selectedLocal.sorted { $0.createdAt == $1.createdAt ? $0.id < $1.id : $0.createdAt > $1.createdAt }
        for photo in local {
            let localID = LocalPhotoLibrary.assetID(for: photo.id)
            guard policy.allows(id: localID) else { continue }
            let id = canonicalID(localID, mappings: mappings)
            if serverIDs.contains(id) { continue }
            guard let latitude = photo.latitude, let longitude = photo.longitude else { continue }
            result.append(MapMarkerDTO(id: id, lat: latitude, lon: longitude,
                city: nil, state: nil, country: nil))
        }
        return PhotoMapClustering.admitted(result, policy: policy)
    }

    static func canonicalID(_ id: String, mappings: [String: String]) -> String {
        guard LocalPhotoLibrary.isLocal(id),
              let mapped = mappings[LocalPhotoLibrary.localIdentifier(from: id)],
              !mapped.isEmpty, !LocalPhotoLibrary.isLocal(mapped) else { return id }
        return mapped
    }
}

@MainActor
final class PhotoMapAssetRepository {
    private let api: APIClient
    private let repository: SearchRepository

    init(api: APIClient, dataManager: SwiftDataManager? = nil) {
        self.api = api
        repository = SearchRepository(api: api, dataManager: dataManager)
    }

    func allAssets() async throws -> [AssetLite] {
        let context = api.session.snapshot
        let generation = LocalSnapshot.generation
        let loaded = try await repository.allMetadata(SearchRequestDTO(order: "desc", size: 1_000))
        try Task.checkCancellation()
        try api.checkCurrent(context)
        guard generation == LocalSnapshot.generation else { throw CancellationError() }
        return loaded.filter(\.isTimelineVisible).map(AssetLite.init)
    }
}
