import Foundation
import SwiftData
import XCTest
@testable import ImmichApp

@MainActor
final class PhotoMapDataTests: XCTestCase {
    private var directory: URL!
    private var store: SwiftDataManager!

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("photo-map-data-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        store = SwiftDataManager(storeURL: directory.appendingPathComponent("test.store"),
            backupJournalURL: directory.appendingPathComponent("backup.json"))
        RemovedAssets.shared.clear()
        DeletedServerAssetRegistry.shared.clear()
    }

    override func tearDown() async throws {
        RemovedAssets.shared.clear()
        DeletedServerAssetRegistry.shared.clear()
        let container = store.modelContainer
        store = nil
        try container.erase()
        try? FileManager.default.removeItem(at: directory)
        try await super.tearDown()
    }

    func testAdmissionKeepsAllPublicPhotosAtTheSameCoordinateAndRejectsInvalidLocations() throws {
        try store.setAssetVisibility(["private"], to: "locked")
        DeletedServerAssetRegistry.shared.record(["deleted"], permanently: true)
        let markers = [marker("private"), marker("first"), marker("second"), marker("first", latitude: 30),
                       marker("deleted"), marker("nan", latitude: .nan), marker("infinity", longitude: .infinity),
                       marker("latitude", latitude: 91), marker("longitude", longitude: -181)]

        let admitted = PhotoMapClustering.admitted(markers, policy: policy)

        XCTAssertEqual(admitted.map(\.id), ["first", "second"])
        XCTAssertEqual(admitted.map(\.lat), [0, 0], "Duplicate IDs cannot move an already admitted photo")
    }

    func testInvalidDuplicateDoesNotHideItsLaterValidCoordinate() {
        let result = PhotoMapClustering.validated([marker("same", latitude: .nan), marker("same", latitude: 25)])
        XCTAssertEqual(result.map(\.lat), [25])
    }

    func testDateLineBoundsAndFittingUseTheShortArcAcrossFijiAndSamoa() throws {
        let fiji = marker("fiji", latitude: -17, longitude: 179.5)
        let samoa = marker("samoa", latitude: -14, longitude: -179.5)
        let bounds = PhotoMapBounds(centerLatitude: -15, centerLongitude: 180, latitudeDelta: 10, longitudeDelta: 5)
        XCTAssertTrue(bounds.contains(fiji))
        XCTAssertTrue(bounds.contains(samoa))
        XCTAssertFalse(bounds.contains(marker("greenwich", latitude: -15, longitude: 0)))
        XCTAssertFalse(bounds.contains(marker("north", latitude: 0, longitude: 180)))
        let fitted = try XCTUnwrap(PhotoMapBounds.fitting([fiji, samoa]))
        XCTAssertLessThan(fitted.longitudeDelta, 2)
        XCTAssertGreaterThan(abs(fitted.centerLongitude), 179)
        XCTAssertTrue(fitted.contains(fiji))
        XCTAssertTrue(fitted.contains(samoa))
    }

    func testZoomChangesClusterDensityWithoutDiscardingMembers() {
        let markers = [marker("a", longitude: 0.01), marker("b", longitude: 0.011), marker("c", longitude: 0.3)]
        let wide = PhotoMapBounds(centerLatitude: 0, centerLongitude: 0, latitudeDelta: 10, longitudeDelta: 10)
        let medium = PhotoMapBounds(centerLatitude: 0, centerLongitude: 0, latitudeDelta: 1, longitudeDelta: 1)
        let tight = PhotoMapBounds(centerLatitude: 0, centerLongitude: 0.0105, latitudeDelta: 1, longitudeDelta: 0.001)
        let merged = PhotoMapClustering.clusters(in: markers, bounds: wide, viewportWidth: 400, viewportHeight: 800)
        let separated = PhotoMapClustering.clusters(in: markers, bounds: medium, viewportWidth: 400, viewportHeight: 800)
        let individual = PhotoMapClustering.clusters(in: markers, bounds: tight, viewportWidth: 400, viewportHeight: 800)

        XCTAssertEqual(merged.map(\.count), [3])
        XCTAssertEqual(separated.map(\.count), [2, 1])
        XCTAssertEqual(Set(separated.flatMap { $0.markers.map(\.id) }), ["a", "b", "c"])
        XCTAssertEqual(individual.map(\.count), [1, 1])
        XCTAssertEqual(Set(individual.flatMap { $0.markers.map(\.id) }), ["a", "b"])
    }

    func testTenThousandCoincidentPhotosProduceOneCountedStackInsteadOfARepresentativeSubset() throws {
        let markers = (0..<10_000).map { marker("photo-\($0)") }
        let clusters = PhotoMapClustering.clusters(in: markers, bounds: world, viewportWidth: 390, viewportHeight: 844)
        let cluster = try XCTUnwrap(clusters.first)
        XCTAssertEqual(clusters.count, 1)
        XCTAssertEqual(cluster.count, 10_000)
        XCTAssertEqual(cluster.memberIDs.count, 10_000)
        XCTAssertEqual(cluster.coverID, "photo-0")
    }

    func testNearbyPhotosAcrossABucketBoundaryProduceOneStableStack() throws {
        let bounds = PhotoMapBounds(centerLatitude: 0, centerLongitude: 0, latitudeDelta: 1, longitudeDelta: 1)
        let markers = [marker("left", longitude: -0.1001), marker("right", longitude: -0.0999)]
        let clusters = PhotoMapClustering.clusters(in: markers, bounds: bounds,
            viewportWidth: 380, viewportHeight: 760)
        let reversed = PhotoMapClustering.clusters(in: Array(markers.reversed()), bounds: bounds,
            viewportWidth: 380, viewportHeight: 760)

        let cluster = try XCTUnwrap(clusters.first)
        XCTAssertEqual(clusters.count, 1, "A screen grid boundary must not split overlapping photo pins")
        XCTAssertEqual(cluster.memberIDs, ["left", "right"])
        XCTAssertEqual(cluster.count, 2)
        XCTAssertEqual(cluster.id, reversed.first?.id)
        XCTAssertEqual(cluster.coverID, "left")
        XCTAssertEqual(reversed.first?.coverID, "right")
    }

    func testMergingRechecksMovedCentroidsAndKeepsEveryPhotoInNonoverlappingStacks() {
        let bounds = PhotoMapBounds(centerLatitude: 0, centerLongitude: 0, latitudeDelta: 1, longitudeDelta: 1)
        let markers = [screenMarker("first", x: 65, y: 65), screenMarker("second", x: 142, y: 65),
                       screenMarker("bridge", x: 100, y: 100), screenMarker("distant", x: 300, y: 700)]
        let clusters = PhotoMapClustering.clusters(in: markers, bounds: bounds,
            viewportWidth: 380, viewportHeight: 760)

        XCTAssertEqual(clusters.map(\.memberIDs), [Set(["first", "second", "bridge"]), Set(["distant"])])
        XCTAssertEqual(clusters.map(\.count), [3, 1])
        XCTAssertEqual(clusters.reduce(0) { $0 + $1.count }, markers.count)
        assertNonoverlapping(clusters, bounds: bounds)
    }

    func testDenseViewportPreservesAllMembersAndSeparatesEveryPublishedPinCenter() {
        let bounds = PhotoMapBounds(centerLatitude: 0, centerLongitude: 0, latitudeDelta: 1, longitudeDelta: 1)
        let markers: [MapMarkerDTO] = (0..<5_000).map { (index: Int) -> MapMarkerDTO in
            let x = Double((index * 37) % 379) + 0.5
            let y = Double((index * 71) % 759) + 0.5
            return screenMarker("photo-\(index)", x: x, y: y)
        }
        let clusters = PhotoMapClustering.clusters(in: markers, bounds: bounds,
            viewportWidth: 380, viewportHeight: 760)
        let reversed = PhotoMapClustering.clusters(in: Array(markers.reversed()), bounds: bounds,
            viewportWidth: 380, viewportHeight: 760)

        XCTAssertGreaterThan(clusters.count, 1)
        XCTAssertEqual(clusters.reduce(0) { $0 + $1.count }, markers.count)
        XCTAssertEqual(Set(clusters.flatMap { $0.memberIDs }), Set(markers.map(\.id)))
        XCTAssertEqual(Set(clusters.map(\.id)), Set(reversed.map(\.id)))
        assertNonoverlapping(clusters, bounds: bounds)
    }

    func testStackIdentityIsIndependentOfResponseOrderWhileTheCoverFollowsTheNewestMarker() throws {
        let a = marker("a"), b = marker("b")
        let forward = try XCTUnwrap(PhotoMapClustering.clusters(in: [a, b], bounds: world,
            viewportWidth: 390, viewportHeight: 844).first)
        let reversed = try XCTUnwrap(PhotoMapClustering.clusters(in: [b, a], bounds: world,
            viewportWidth: 390, viewportHeight: 844).first)
        XCTAssertEqual(forward.id, reversed.id)
        XCTAssertEqual(forward.coverID, "a")
        XCTAssertEqual(reversed.coverID, "b")
    }

    func testDateLineStackStaysAtTheDateLineAndUsesOnlyAnUnambiguousPlaceTitle() throws {
        let a = marker("a", longitude: 179.9, city: "First", state: "Shared State")
        let b = marker("b", longitude: -179.9, city: "Second", state: "Shared State")
        let bounds = PhotoMapBounds(centerLatitude: 0, centerLongitude: 180, latitudeDelta: 10, longitudeDelta: 10)
        let cluster = try XCTUnwrap(PhotoMapClustering.clusters(in: [a, b], bounds: bounds,
            viewportWidth: 390, viewportHeight: 844).first)
        XCTAssertEqual(cluster.count, 2)
        XCTAssertGreaterThan(abs(cluster.longitude), 179)
        XCTAssertEqual(cluster.title, "Shared State")
    }

    func testPolarAndDegenerateViewportInputsRemainFiniteAndKeepValidPhotos() throws {
        let north = marker("north", latitude: 90, longitude: 180)
        let bounds = PhotoMapBounds(centerLatitude: 90, centerLongitude: 180,
            latitudeDelta: .leastNonzeroMagnitude, longitudeDelta: .leastNonzeroMagnitude)
        let cluster = try XCTUnwrap(PhotoMapClustering.clusters(in: [north], bounds: bounds,
            viewportWidth: .greatestFiniteMagnitude, viewportHeight: .nan, cellSize: 0).first)
        XCTAssertEqual(cluster.count, 1)
        XCTAssertTrue(cluster.latitude.isFinite)
        XCTAssertTrue(cluster.longitude.isFinite)
        XCTAssertTrue(PhotoMapBounds.fitting([north])?.contains(north) == true)
    }

    func testSelectedDeviceGPSUsesCanonicalServerMarkersAndDeduplicatesMappedCopies() throws {
        let first = local("first", latitude: -17, longitude: 179.8)
        let second = local("second", latitude: -17, longitude: -179.8)
        let plain = local("unuploaded", latitude: -17, longitude: -179.7)
        let remote = marker("server", latitude: 45, longitude: 12)
        let result = PhotoMapSources.markers(server: [remote], selectedLocal: [first, second, plain],
            mappings: [first.id: remote.id, second.id: remote.id], policy: policy)
        XCTAssertEqual(result.map(\.id), [remote.id, LocalPhotoLibrary.assetID(for: plain.id)])
        XCTAssertEqual(result.first?.lat, 45, "Canonical server coordinates win over its device copies")

        let fallbacks = PhotoMapSources.markers(server: [], selectedLocal: [first, second, plain],
            mappings: [first.id: remote.id, second.id: remote.id], policy: policy)
        XCTAssertEqual(Set(fallbacks.map(\.id)), [remote.id, LocalPhotoLibrary.assetID(for: plain.id)])
        XCTAssertEqual(fallbacks.count, 2)
        let dateLine = PhotoMapBounds(centerLatitude: -17, centerLongitude: 180, latitudeDelta: 1, longitudeDelta: 2)
        XCTAssertTrue(fallbacks.allSatisfy(dateLine.contains))
    }

    func testPrivateMappedDeviceCopiesAndMissingOrInvalidGPSNeverCreateMarkers() throws {
        let privatePhoto = local("private", latitude: 40, longitude: 5)
        try store.linkDeviceAsset(localIdentifier: privatePhoto.id, to: "private-server")
        try store.setAssetVisibility(["private-server"], to: "locked")
        var missing = local("missing", latitude: 40, longitude: 5)
        missing.latitude = nil
        let invalid = local("invalid", latitude: 40, longitude: .nan)
        let result = PhotoMapSources.markers(server: [], selectedLocal: [privatePhoto, missing, invalid],
            mappings: store.serverAssetIDsByLocalIdentifier(), policy: policy)
        XCTAssertTrue(result.isEmpty)
    }

    private var policy: AssetVisibilityPolicy { AssetVisibilityPolicy(scope: .timeline, dataManager: store) }
    private var world: PhotoMapBounds {
        PhotoMapBounds(centerLatitude: 0, centerLongitude: 0, latitudeDelta: 180, longitudeDelta: 360)
    }
    private func screenMarker(_ id: String, x: Double, y: Double) -> MapMarkerDTO {
        let north = mercatorY(0.5), south = mercatorY(-0.5)
        let projectedY = north + y / 760 * (south - north)
        let latitude = atan(sinh(.pi * (1 - 2 * projectedY))) * 180 / .pi
        return marker(id, latitude: latitude, longitude: x / 380 - 0.5)
    }
    private func assertNonoverlapping(_ clusters: [PhotoMapCluster], bounds: PhotoMapBounds,
                                     file: StaticString = #filePath, line: UInt = #line) {
        let north = mercatorY(bounds.north), span = mercatorY(bounds.south) - north
        for (index, first) in clusters.enumerated() {
            for second in clusters.dropFirst(index + 1) {
                let dx = PhotoMapBounds.longitude(first.longitude - second.longitude) / bounds.longitudeDelta * 380
                let dy = (mercatorY(first.latitude) - mercatorY(second.latitude)) / span * 760
                XCTAssertGreaterThanOrEqual(hypot(dx, dy), 76 - 1e-6,
                    "Published pin centers must remain at least one pin width apart", file: file, line: line)
            }
        }
    }
    private func mercatorY(_ latitude: Double) -> Double {
        (1 - log(tan(.pi / 4 + latitude * .pi / 360)) / .pi) / 2
    }
    private func marker(_ id: String, latitude: Double = 0, longitude: Double = 0,
                        city: String? = nil, state: String? = nil) -> MapMarkerDTO {
        MapMarkerDTO(id: id, lat: latitude, lon: longitude, city: city, state: state, country: nil)
    }
    private func local(_ id: String, latitude: Double, longitude: Double) -> LocalPhoto {
        LocalPhoto(id: id, createdAt: .distantPast, modifiedAt: .distantPast, isVideo: false,
            isLivePhoto: false, duration: nil, ratio: 1, latitude: latitude, longitude: longitude)
    }
}
