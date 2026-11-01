import MapKit
import Observation
import SwiftUI
import UIKit
import XCTest
@testable import ImmichApp

@MainActor
final class CollectionsMapPreviewTests: SimulatorHostedTestCase {
    func testUpdatedCoordinatesForTheSamePhotoRepositionTheMountedPreview() async throws {
        for style in [UIUserInterfaceStyle.light, .dark] {
            let original = marker(latitude: 41.3874, longitude: 2.1686)
            let updated = marker(latitude: 35.6762, longitude: 139.6503)
            XCTAssertEqual(original.id, updated.id)
            let fixture = MapPreviewFixture(marker: original)
            let window = try await host(MapPreviewHost(fixture: fixture), style: style)
            try await waitUntil("The real map initially frames the photo's original coordinates") {
                self.isCentered(on: original, in: window)
            }

            fixture.marker = updated

            try await waitUntil("Changing coordinates without changing the photo updates the actual MapKit camera") {
                self.isCentered(on: updated, in: window)
            }
            XCTAssertFalse(isCentered(on: original, in: window))
            _ = try await screenshot(window)
        }
    }

    private func isCentered(on marker: MapMarkerDTO, in window: UIWindow) -> Bool {
        guard let map = mapView(in: window), map.window === window else { return false }
        return abs(map.centerCoordinate.latitude - marker.lat) < 0.01
            && abs(map.centerCoordinate.longitude - marker.lon) < 0.01
    }

    private func mapView(in view: UIView) -> MKMapView? {
        guard !view.isHidden, view.alpha > 0 else { return nil }
        if let map = view as? MKMapView { return map }
        return view.subviews.lazy.compactMap { self.mapView(in: $0) }.first
    }

    private func marker(latitude: Double, longitude: Double) -> MapMarkerDTO {
        MapMarkerDTO(id: "same-photo", lat: latitude, lon: longitude,
            city: nil, state: nil, country: nil)
    }
}

@MainActor
@Observable
private final class MapPreviewFixture {
    var marker: MapMarkerDTO

    init(marker: MapMarkerDTO) { self.marker = marker }
}

private struct MapPreviewHost: View {
    let fixture: MapPreviewFixture

    var body: some View {
        CollectionsMapPreview(marker: fixture.marker)
            .frame(height: 240)
    }
}
