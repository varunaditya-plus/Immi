import MapKit
import SwiftData
import SwiftUI
import UIKit
import XCTest
@testable import ImmichApp

@MainActor
final class PhotoMapPresentationTests: SimulatorHostedTestCase {
    private var previousMarkers: [MapMarkerDTO]?
    private var previousStyle: Any?
    private var directory: URL?
    private weak var fixtureModel: PhotoMapViewModel?
    private weak var fixtureManager: SwiftDataManager?
    private var fixtureContainer: ModelContainer?
    private var deletedIDs: [String] = []

    override func setUp() {
        previousMarkers = LocalSnapshot.load([MapMarkerDTO].self, for: LocalSnapshot.Key.places)
        LocalSnapshot.remove(LocalSnapshot.Key.places)
        previousStyle = UserDefaults.standard.object(forKey: "photoMap.style")
        UserDefaults.standard.set(PhotoMapStyle.explore.rawValue, forKey: "photoMap.style")
    }

    override func tearDown() async throws {
        try await super.tearDown()
        try await waitUntil("Hosted map owners release their isolated store before erasure") {
            self.fixtureModel == nil && self.fixtureManager == nil
        }
        guard fixtureModel == nil, fixtureManager == nil else { return }
        try fixtureContainer?.erase()
        fixtureContainer = nil
        if let directory { try? FileManager.default.removeItem(at: directory) }
        if let previousMarkers { LocalSnapshot.save(previousMarkers, for: LocalSnapshot.Key.places) }
        else { LocalSnapshot.remove(LocalSnapshot.Key.places) }
        if let previousStyle { UserDefaults.standard.set(previousStyle, forKey: "photoMap.style") }
        else { UserDefaults.standard.removeObject(forKey: "photoMap.style") }
        DeletedServerAssetRegistry.shared.restore(deletedIDs)
    }

    func testCountedMapStackOpensEveryPhotoThroughItsActualButton() async throws {
        let model = try model()
        let photos = (0..<260).map { photo("photo-\($0)") }
        let markers = photos.map { marker($0.id, city: "Synthetic Stack") }
        var metadataQueries = 0
        let window = try await host(NavigationStack {
            PhotoMapView(initialBounds: bounds, model: model, markerLoader: { markers }, assetLoader: {
                metadataQueries += 1
                return photos
            })
        })
        try await waitUntil("The actual map thumbnail exposes the complete location count") {
            self.button(named: "Synthetic Stack", value: String(localized: "\(260) items"), in: window) != nil
        }
        let stack = try XCTUnwrap(button(named: "Synthetic Stack", value: String(localized: "\(260) items"), in: window))

        try activate(stack)

        try await waitUntil("The real stack button loads every location member into the collection") {
            self.photoCount(in: window) == 260
        }
        let grid = try XCTUnwrap(gridController(in: window.rootViewController))
        XCTAssertNotNil(grid.revealCell(for: photos[0].id))
        XCTAssertNotNil(grid.revealCell(for: photos[259].id))
        XCTAssertEqual(metadataQueries, 1)
        _ = try await screenshot(window)
    }

    func testScopedMapShowsNearbyPhotosOnlyInsideItsViewportAndCanRestoreTheOriginalScope() async throws {
        let model = try model()
        let chosen = photo("chosen"), nearby = photo("nearby"), distant = photo("distant")
        let markers = [marker(chosen.id), marker(nearby.id, longitude: 0.001), marker(distant.id, longitude: 40)]
        let window = try await host(NavigationStack {
            PhotoMapView(assetIDs: [chosen.id], initialBounds: bounds, model: model,
                markerLoader: { markers }, assetLoader: { [chosen, nearby, distant] })
        })
        try await waitUntil("The selected collection initially contains just its own map marker") {
            model.markers.count == 3 && self.modeControl(in: window) != nil
        }

        try await activateAccessibilityButton(named: "Show Nearby Photos", in: window)
        try await chooseMode("Grid", in: window)

        try await waitUntil("Nearby browsing includes the second visible location, excluding the distant photo") {
            self.photoCount(in: window) == 2
        }
        let nearbyGrid = try XCTUnwrap(gridController(in: window.rootViewController))
        XCTAssertNotNil(nearbyGrid.revealCell(for: chosen.id))
        XCTAssertNotNil(nearbyGrid.revealCell(for: nearby.id))
        XCTAssertNil(nearbyGrid.revealCell(for: distant.id))

        try await chooseMode("Map", in: window)
        try await waitUntil("The segmented control restores the actual MapKit surface") {
            self.gridController(in: window.rootViewController) == nil && self.mapView(in: window) != nil
        }
        try await activateAccessibilityButton(named: "Hide Nearby Photos", in: window)
        try await chooseMode("Grid", in: window)
        try await waitUntil("Hiding nearby restores the original collection membership") {
            self.photoCount(in: window) == 1
        }
        XCTAssertNotNil(try XCTUnwrap(gridController(in: window.rootViewController)).revealCell(for: chosen.id))
    }

    func testMovingTheActualMapCameraChangesGridMembershipAndSurvivesReturningToTheMap() async throws {
        let model = try model()
        let original = photo("original-viewport")
        let movedA = photo("moved-viewport-a"), movedB = photo("moved-viewport-b")
        let markers = [marker(original.id, city: "First Viewport"),
                       marker(movedA.id, longitude: 40, city: "Second Viewport"),
                       marker(movedB.id, longitude: 40.001, city: "Second Viewport")]
        var metadataQueries = 0
        let window = try await host(NavigationStack {
            PhotoMapView(initialBounds: bounds, model: model, markerLoader: { markers }, assetLoader: {
                metadataQueries += 1
                return [original, movedA, movedB]
            })
        })
        try await waitUntil("The real map initially shows only the first viewport's photo") {
            self.button(named: "First Viewport", value: String(localized: "\(1) items"), in: window) != nil
        }
        let map = try XCTUnwrap(mapView(in: window))
        let destination = PhotoMapBounds(centerLatitude: 0, centerLongitude: 40.0005,
            latitudeDelta: 1, longitudeDelta: 1)

        map.setRegion(destination.region, animated: false)

        try await waitUntil("MapKit camera completion updates the production viewport and counted annotations") {
            self.button(named: "Second Viewport", value: String(localized: "\(2) items"), in: window) != nil
                && self.button(named: "First Viewport", in: window) == nil
        }
        let movedRegion = map.region
        XCTAssertEqual(movedRegion.center.longitude, 40.0005, accuracy: 0.01)
        try await chooseMode("Grid", in: window)
        try await waitUntil("The real Grid control uses the moved viewport rather than the original region") {
            self.photoCount(in: window) == 2
        }
        let grid = try XCTUnwrap(gridController(in: window.rootViewController))
        XCTAssertNotNil(grid.revealCell(for: movedA.id))
        XCTAssertNotNil(grid.revealCell(for: movedB.id))
        XCTAssertNil(grid.revealCell(for: original.id))
        XCTAssertEqual(metadataQueries, 1)

        try await chooseMode("Map", in: window)
        try await waitUntil("Returning from Grid preserves the moved camera's center and zoom") {
            guard self.gridController(in: window.rootViewController) == nil,
                  let restored = self.mapView(in: window) else { return false }
            return abs(restored.region.center.longitude - movedRegion.center.longitude) < 0.01
                && abs(restored.region.center.latitude - movedRegion.center.latitude) < 0.01
                && abs(restored.region.span.longitudeDelta - movedRegion.span.longitudeDelta)
                    < max(0.01, movedRegion.span.longitudeDelta * 0.05)
        }
        _ = try await screenshot(window)
    }

    func testChooseMapPersistsSatelliteAndAppliesItToTheActualMap() async throws {
        let model = try model()
        let window = try await host(NavigationStack {
            PhotoMapView(initialBounds: bounds, model: model,
                markerLoader: { [self.marker("photo")] }, assetLoader: { [self.photo("photo")] })
        })
        try await activateAccessibilityButton(named: "Choose Map", in: window)
        try await waitUntil("The actual Choose Map sheet finishes presentation") {
            let sheet = self.presentedController(from: window.rootViewController)
            return sheet != nil && sheet?.transitionCoordinator == nil
        }
        let sheet = try XCTUnwrap(presentedController(from: window.rootViewController))

        try await activateAccessibilityButton(named: "Satellite", in: window, within: sheet.view)

        try await waitUntil("Satellite selection persists through the production binding") {
            UserDefaults.standard.string(forKey: "photoMap.style") == PhotoMapStyle.satellite.rawValue
        }
        try await waitUntil("The rendered Satellite option updates its selected accessibility trait") {
            self.button(named: "Satellite", in: sheet.view)?.accessibilityTraits.contains(.selected) == true
        }
        try await activateAccessibilityButton(named: "Close", in: window, within: sheet.view)
        try await waitUntil("The main map uses the imagery configuration after the sheet closes") {
            guard self.presentedController(from: window.rootViewController) == nil,
                  let map = self.mapView(in: window.rootViewController?.view) else { return false }
            return map.preferredConfiguration is MKImageryMapConfiguration
        }
        _ = try await screenshot(window)
    }

    func testGlobalMapStackCanExpandNearbyPhotosAndRestoreItsOriginalMembers() async throws {
        let model = try model()
        let chosen = photo("chosen-stack"), nearby = photo("neighboring-stack")
        let markers = [marker(chosen.id, city: "Chosen Stack"),
                       marker(nearby.id, longitude: 0.4, city: "Other Stack")]
        let window = try await host(NavigationStack {
            PhotoMapView(initialBounds: bounds, model: model, markerLoader: { markers },
                assetLoader: { [chosen, nearby] })
        })
        try await waitUntil("The global map exposes the chosen location's real thumbnail") {
            self.button(named: "Chosen Stack", value: String(localized: "\(1) items"), in: window) != nil
        }
        try activate(try XCTUnwrap(button(named: "Chosen Stack", value: String(localized: "\(1) items"), in: window)))
        try await waitUntil("Selecting a global map stack scopes the collection to its own members") {
            self.photoCount(in: window) == 1
        }

        try await activateAccessibilityButton(named: "Show Nearby Photos", in: window)
        try await waitUntil("Nearby expansion includes the other visible location") { self.photoCount(in: window) == 2 }
        try await activateAccessibilityButton(named: "Hide Nearby Photos", in: window)
        try await waitUntil("Hiding nearby restores the tapped stack instead of losing its original scope") {
            self.photoCount(in: window) == 1
        }
        XCTAssertNotNil(try XCTUnwrap(gridController(in: window.rootViewController)).revealCell(for: chosen.id))
        XCTAssertNil(try XCTUnwrap(gridController(in: window.rootViewController)).revealCell(for: nearby.id))
    }

    func testCachedMapRefreshFailureKeepsItsStackAndTheActualRetryUpdatesIt() async throws {
        let cached = marker("cached", city: "Cached Place")
        LocalSnapshot.save([cached], for: LocalSnapshot.Key.places)
        let model = try model()
        var markerQueries = 0
        var metadataQueries = 0
        let window = try await host(NavigationStack {
            PhotoMapView(initialBounds: bounds, model: model, markerLoader: {
                markerQueries += 1
                if markerQueries == 1 { throw APIError.notConnected }
                return [self.marker("fresh", city: "Fresh Place")]
            }, assetLoader: { metadataQueries += 1; return [] })
        })
        try await waitUntil("A failed refresh retains the cached map and exposes retry feedback") {
            model.refreshError != nil && self.button(named: "Cached Place", in: window) != nil
        }

        try await activateAccessibilityButton(named: "Retry", in: window)

        try await waitUntil("The real retry replaces the cached marker and clears refresh feedback") {
            model.refreshError == nil && model.markers.map(\.id) == ["fresh"]
                && self.button(named: "Fresh Place", in: window) != nil
        }
        XCTAssertEqual(markerQueries, 2)
        XCTAssertEqual(metadataQueries, 0, "Map refresh must not eagerly load the entire photo metadata index")
    }

    func testAnEmptyGridRetainsTheControlThatReturnsToTheMap() async throws {
        let model = try model()
        let photo = photo(UUID().uuidString)
        let window = try await host(NavigationStack {
            PhotoMapView(initialBounds: bounds, model: model,
                markerLoader: { [self.marker(photo.id)] }, assetLoader: { [photo] })
        })
        try await chooseMode("Grid", in: window)
        try await waitUntil("The grid initially contains the public photo") { self.photoCount(in: window) == 1 }

        deletedIDs.append(photo.id)
        DeletedServerAssetRegistry.shared.record([photo.id], permanently: true)

        try await waitUntil("The private or removed photo leaves the active map collection") {
            model.admittedMarkers.isEmpty && self.photoCount(in: window) == 0
        }
        try await chooseMode("Map", in: window)
        try await waitUntil("The empty collection still allows a return to the actual map") {
            self.gridController(in: window.rootViewController) == nil && self.mapView(in: window) != nil
        }
    }

    private var bounds: PhotoMapBounds {
        PhotoMapBounds(centerLatitude: 0, centerLongitude: 0, latitudeDelta: 1, longitudeDelta: 1)
    }

    private func model() throws -> PhotoMapViewModel {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("photo-map-presentation-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        self.directory = directory
        let manager = SwiftDataManager(storeURL: directory.appendingPathComponent("test.store"),
            backupJournalURL: directory.appendingPathComponent("backup.json"))
        let model = PhotoMapViewModel(dataManager: manager, localPhotos: { [] })
        fixtureManager = manager
        fixtureModel = model
        fixtureContainer = manager.modelContainer
        return model
    }

    private func marker(_ id: String, longitude: Double = 0, city: String = "Synthetic Place") -> MapMarkerDTO {
        MapMarkerDTO(id: id, lat: 0, lon: longitude, city: city, state: nil, country: nil)
    }

    private func photo(_ id: String) -> AssetLite {
        AssetLite(id: id, isVideo: false, ratio: 1, thumbhash: nil,
            createdAt: Date(timeIntervalSince1970: 1_793_188_800))
    }

    private func chooseMode(_ title: String, in window: UIWindow) async throws {
        try await waitUntil("The actual map/grid segmented control is visible") { self.modeControl(in: window) != nil }
        let control = try XCTUnwrap(modeControl(in: window))
        let index = try XCTUnwrap((0..<control.numberOfSegments).first { control.titleForSegment(at: $0) == title })
        XCTAssertTrue(control.isEnabled && control.isEnabledForSegment(at: index))
        control.selectedSegmentIndex = index
        control.sendActions(for: .valueChanged)
        try await waitUntil("The actual segmented control selects \(title)") {
            self.modeControl(in: window)?.selectedSegmentIndex == index
        }
    }

    private func modeControl(in view: UIView) -> UISegmentedControl? {
        if let control = view as? UISegmentedControl, control.numberOfSegments == 2,
           control.titleForSegment(at: 0) == "Map", control.titleForSegment(at: 1) == "Grid" { return control }
        return view.subviews.lazy.compactMap { self.modeControl(in: $0) }.first
    }

    private func photoCount(in window: UIWindow) -> Int {
        guard let grid = gridController(in: window.rootViewController),
              let collection = grid.view.subviews.first(where: { $0 is UICollectionView }) as? UICollectionView else { return 0 }
        return (0..<collection.numberOfSections).reduce(0) { $0 + collection.numberOfItems(inSection: $1) }
    }

    private func gridController(in controller: UIViewController?) -> PhotoGridController? {
        guard let controller else { return nil }
        if let grid = controller as? PhotoGridController { return grid }
        return controller.children.lazy.compactMap { self.gridController(in: $0) }.first
    }

    private func mapView(in view: UIView?) -> MKMapView? {
        guard let view, !view.isHidden, view.alpha > 0 else { return nil }
        if let map = view as? MKMapView { return map }
        return view.subviews.lazy.compactMap { self.mapView(in: $0) }.first
    }

    private func presentedController(from controller: UIViewController?) -> UIViewController? {
        guard let presented = controller?.presentedViewController else { return nil }
        return presentedController(from: presented) ?? presented
    }

    private func button(named title: String, value: String? = nil, in root: NSObject) -> NSObject? {
        var visited = Set<ObjectIdentifier>()
        func find(_ object: NSObject, depth: Int) -> NSObject? {
            guard depth < 45, visited.insert(ObjectIdentifier(object)).inserted else { return nil }
            if let view = object as? UIView, view.isHidden || view.alpha <= 0 { return nil }
            if object.accessibilityLabel == title, object.accessibilityTraits.contains(.button),
               value == nil || object.accessibilityValue == value { return object }
            if let view = object as? UIView {
                for child in view.subviews { if let found = find(child, depth: depth + 1) { return found } }
            }
            if let elements = object.accessibilityElements {
                for case let child as NSObject in elements { if let found = find(child, depth: depth + 1) { return found } }
            }
            let count = object.accessibilityElementCount()
            if (1...500).contains(count) {
                for index in 0..<count {
                    if let child = object.accessibilityElement(at: index) as? NSObject,
                       let found = find(child, depth: depth + 1) { return found }
                }
            }
            return nil
        }
        return find(root, depth: 0)
    }

    private func activate(_ button: NSObject) throws {
        if let control = button as? UIControl { control.performPrimaryAction() }
        else {
            let activated = button.accessibilityActivate()
            XCTAssertTrue(activated, "The counted map thumbnail must expose its real activation action")
            guard activated else { throw URLError(.unsupportedURL) }
        }
    }
}
