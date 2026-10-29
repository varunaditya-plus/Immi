import MapKit
import Observation
import SwiftUI
import UIKit
import XCTest
@testable import ImmichApp

@MainActor
final class AssetInfoLocationMapTests: XCTestCase {
    private var window: UIWindow?
    private weak var previousKeyWindow: UIWindow?
    private var snapshotIDs: [String] = []
    private let barcelona = CLLocationCoordinate2D(latitude: 41.3874, longitude: 2.1686)
    private let jakarta = CLLocationCoordinate2D(latitude: -6.2, longitude: 106.8167)

    override func tearDown() async throws {
        window?.isHidden = true
        window?.rootViewController = nil
        window = nil
        previousKeyWindow?.makeKey()
        previousKeyWindow = nil
        for id in snapshotIDs { LocalSnapshot.remove(LocalSnapshot.Key.assetDetail(id)) }
        snapshotIDs.removeAll()
        try await super.tearDown()
    }

    func testSavedLocationRefreshMovesCameraAndAnnotationInTheMountedPanel() async throws {
        let id = UUID().uuidString
        snapshotIDs.append(id)
        let repository = LocationMapRepository()
        var serverDetail = photo(id, at: barcelona)
        repository.fetch = { _ in serverDetail }
        repository.save = { [self] savedID, latitude, longitude in
            XCTAssertEqual(savedID, id)
            serverDetail = photo(id, at: .init(latitude: latitude, longitude: longitude))
        }
        let model = AssetDetailViewModel(repo: repository)
        await model.load(id)
        try mount(detail: { model.detail })
        let map = try await mountedMap(at: barcelona)

        let saved = await model.updateLocation(id, latitude: jakarta.latitude, longitude: jakarta.longitude)

        XCTAssertTrue(saved)
        try await waitUntil("The saved location reaches the displayed camera and annotation") {
            self.isCentered(map, at: self.jakarta) && self.hasAnnotation(map, at: self.jakarta)
        }
        XCTAssertTrue(findMap(in: try XCTUnwrap(window)) === map, "The existing map must accept the fresh metadata")
    }

    func testZeroLatitudeAndLongitudeDisplayTheirMapAndAnnotation() async throws {
        let origin = CLLocationCoordinate2D(latitude: 0, longitude: 0)
        let input = LocationPanelInput(detail: photo("origin", at: origin))
        try mount(detail: { input.detail })

        let map = try await mountedMap(at: origin)

        XCTAssertTrue(hasAnnotation(map, at: origin))
    }

    func testLocationEditorStartsAtSavedZeroLatitudeAndLongitude() async throws {
        let origin = CLLocationCoordinate2D(latitude: 0, longitude: 0)
        let detail = photo("origin", at: origin)
        let coordinate = try XCTUnwrap(AssetDetailView.coordinate(for: detail),
            "A saved location at 0/0 must remain available to the editor")
        XCTAssertEqual(coordinate.latitude, 0)
        XCTAssertEqual(coordinate.longitude, 0)
        try mount(AssetLocationEditor(initialCoordinate: coordinate) { _ in })

        try await waitUntil("The editor's map starts at the saved 0/0 location") {
            guard let map = self.findMap(in: self.window) else { return false }
            return self.isCentered(map, at: origin)
        }
    }

    func testUnrelatedMetadataPreservesPanAndAnotherPhotoRecentersEvenAtTheSameLocation() async throws {
        let input = LocationPanelInput(detail: photo("first", at: barcelona))
        try mount(detail: { input.detail })
        let map = try await mountedMap(at: barcelona)
        map.setRegion(MKCoordinateRegion(center: jakarta,
            span: MKCoordinateSpan(latitudeDelta: 0.05, longitudeDelta: 0.05)), animated: false)
        try await waitUntil("The map has moved away from the photo") { self.isCentered(map, at: self.jakarta) }

        input.detail.setDescription("Updated caption")

        try await waitUntil("The actual caption field receives the metadata update") {
            self.textInputs(in: self.window).contains("Updated caption")
        }
        XCTAssertTrue(isCentered(map, at: jakarta), "A caption update must preserve the location being explored")
        XCTAssertTrue(findMap(in: try XCTUnwrap(window)) === map, "A caption update keeps the same photo's map")

        input.detail = photo("second", at: barcelona)

        _ = try await mountedMap(at: barcelona)
    }

    func testLocationAddedRemovedAndReaddedShowsTheCurrentCoordinate() async throws {
        let input = LocationPanelInput(detail: makeTestAsset(id: "photo"))
        try mount(detail: { input.detail })
        XCTAssertNil(findMap(in: try XCTUnwrap(window)))

        input.detail = photo("photo", at: barcelona)
        _ = try await mountedMap(at: barcelona)
        input.detail = makeTestAsset(id: "photo")
        try await waitUntil("Removing location removes its map") { self.findMap(in: self.window) == nil }
        input.detail = photo("photo", at: jakarta)

        let map = try await mountedMap(at: jakarta)
        XCTAssertTrue(hasAnnotation(map, at: jakarta))
    }

    func testExpandedPanelAllowsMapPanAndZoomAndCollapsedPanelYieldsItsTouches() async throws {
        let input = LocationPanelInput(detail: photo("photo", at: barcelona))
        try mount(detail: { input.detail }, expanded: { input.expanded })
        let map = try await mountedMap(at: barcelona)
        try await waitUntil("The expanded map can receive touches") { self.mapReceivesTouches(map) }
        XCTAssertTrue(map.isScrollEnabled)
        XCTAssertTrue(map.isZoomEnabled)

        input.expanded = false

        try await waitUntil("The preview yields gestures to the collapsed panel") {
            !map.isScrollEnabled && !map.isZoomEnabled && !self.mapReceivesTouches(map)
        }
        input.expanded = true
        try await waitUntil("Expanding restores native map interaction") {
            map.isScrollEnabled && map.isZoomEnabled && self.mapReceivesTouches(map)
        }
    }

    private func mount(detail: @escaping () -> AssetResponseDTO?, expanded: @escaping () -> Bool = { true }) throws {
        try mount(LocationPanelFixture(detail: detail, expanded: expanded))
    }

    private func mount<Content: View>(_ content: Content) throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        previousKeyWindow = scene.windows.first { $0.isKeyWindow }
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        window.rootViewController = UIHostingController(rootView: content
            .environment(MockSessionManager() as SessionManager))
        window.makeKeyAndVisible()
        window.layoutIfNeeded()
        self.window = window
    }

    private func mountedMap(at coordinate: CLLocationCoordinate2D) async throws -> MKMapView {
        try await waitUntil("The real MapKit map displays the photo location") {
            guard let map = self.findMap(in: self.window) else { return false }
            return self.isCentered(map, at: coordinate) && self.hasAnnotation(map, at: coordinate)
        }
        return try XCTUnwrap(findMap(in: window))
    }

    private func findMap(in view: UIView?) -> MKMapView? {
        guard let view else { return nil }
        return (view as? MKMapView) ?? view.subviews.compactMap { findMap(in: $0) }.first
    }

    private func isCentered(_ map: MKMapView, at coordinate: CLLocationCoordinate2D) -> Bool {
        abs(map.centerCoordinate.latitude - coordinate.latitude) < 0.002
            && abs(map.centerCoordinate.longitude - coordinate.longitude) < 0.002
    }

    private func hasAnnotation(_ map: MKMapView, at coordinate: CLLocationCoordinate2D) -> Bool {
        map.annotations.contains {
            !($0 is MKUserLocation) && abs($0.coordinate.latitude - coordinate.latitude) < 0.00001
                && abs($0.coordinate.longitude - coordinate.longitude) < 0.00001
        }
    }

    private func mapReceivesTouches(_ map: MKMapView) -> Bool {
        guard let window else { return false }
        let point = map.convert(CGPoint(x: map.bounds.midX, y: map.bounds.midY), to: window)
        guard let hit = window.hitTest(point, with: nil) else { return false }
        return hit === map || hit.isDescendant(of: map)
    }

    private func textInputs(in view: UIView?) -> [String] {
        guard let view else { return [] }
        if let field = view as? UITextField { return [field.text ?? ""] }
        if let field = view as? UITextView { return [field.text ?? ""] }
        return view.subviews.flatMap { textInputs(in: $0) }
    }

    private func waitUntil(_ message: String, _ condition: () -> Bool,
                           file: StaticString = #filePath, line: UInt = #line) async throws {
        let deadline = Date.now.addingTimeInterval(3)
        while !condition(), Date.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(condition(), message, file: file, line: line)
    }

    private func photo(_ id: String, at coordinate: CLLocationCoordinate2D,
                       city: String? = nil, state: String? = nil, country: String? = nil) -> AssetResponseDTO {
        makeTestAsset(id: id, exifInfo: ExifDTO(make: nil, model: nil, exifImageWidth: nil,
            exifImageHeight: nil, orientation: nil, fileSizeInByte: nil, dateTimeOriginal: nil,
            latitude: coordinate.latitude, longitude: coordinate.longitude, city: city, state: state,
            country: country, lensModel: nil, fNumber: nil, focalLength: nil, iso: nil, exposureTime: nil,
            description: nil))
    }
}

@MainActor @Observable private final class LocationPanelInput {
    var detail: AssetResponseDTO
    var expanded = true
    init(detail: AssetResponseDTO) { self.detail = detail }
}

private struct LocationPanelFixture: View {
    let detail: () -> AssetResponseDTO?
    let expanded: () -> Bool
    @State private var description = ""
    @FocusState private var focused: Bool

    var body: some View {
        if let detail = detail() {
            AssetInfoPanel(detail: detail, isScrollEnabled: expanded(), descriptionDraft: $description,
                descriptionFocus: $focused)
        }
    }
}

private final class LocationMapRepository: AssetDetailRepository {
    @MainActor var fetch: (String) async throws -> AssetResponseDTO = { _ in throw APIError.unknown }
    @MainActor var save: (String, Double, Double) async throws -> Void = { _, _, _ in }
    @MainActor init() { super.init(api: makeStubAPIClient()) }
    override func fetchAsset(_ id: String) async throws -> AssetResponseDTO { try await fetch(id) }
    override func updateLocation(_ id: String, latitude: Double, longitude: Double) async throws {
        try await save(id, latitude, longitude)
    }
}
