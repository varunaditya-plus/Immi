import MapKit
import XCTest
@testable import ImmichApp

final class AssetInfoPanelLayoutTests: XCTestCase {
    func testDetentsRespectTheWindowEvenWhenContentOrAnotherScreenIsMuchTaller() {
        let small = AssetInfoPanelLayout(viewportHeight: 320, contentHeight: 1_400)
        XCTAssertEqual(small.mediumHeight, 176, accuracy: 0.01)
        XCTAssertEqual(small.maximumHeight, 240, accuracy: 0.01)
        assertDetents(small.detents, [0, 176, 240])
        let shortContent = AssetInfoPanelLayout(viewportHeight: 800, contentHeight: 200)
        assertDetents(shortContent.detents, [0, 440])
        let naturalContent = AssetInfoPanelLayout(viewportHeight: 800, contentHeight: 500)
        assertDetents(naturalContent.detents, [0, 440, 500])
    }

    func testResizingKeepsClosedMediumAndExpandedDetentsAndBoundsAnInterruptedDrag() {
        let portrait = AssetInfoPanelLayout(viewportHeight: 1_000, contentHeight: 1_400)
        let landscape = AssetInfoPanelLayout(viewportHeight: 400, contentHeight: 1_400)
        XCTAssertEqual(landscape.resizedHeight(0, from: portrait), 0)
        XCTAssertEqual(landscape.resizedHeight(550, from: portrait), 220, accuracy: 0.01)
        XCTAssertEqual(landscape.resizedHeight(750, from: portrait), 300, accuracy: 0.01)
        XCTAssertEqual(landscape.resizedHeight(620, from: portrait), 300, accuracy: 0.01)
        XCTAssertEqual(portrait.resizedHeight(220, from: landscape), 550, accuracy: 0.01)
        XCTAssertEqual(portrait.resizedHeight(300, from: landscape), 750, accuracy: 0.01)
    }

    func testCollapsedContentUsesTheMediumDetentWhenTheWindowGrows() {
        let small = AssetInfoPanelLayout(viewportHeight: 400, contentHeight: 100)
        let large = AssetInfoPanelLayout(viewportHeight: 1_000, contentHeight: 100)
        XCTAssertEqual(large.resizedHeight(220, from: small), 550, accuracy: 0.01)
        let unknown = AssetInfoPanelLayout(viewportHeight: 0, contentHeight: 0)
        XCTAssertEqual(unknown.maximumHeight, 0)
        XCTAssertEqual(unknown.resizedHeight(550, from: large), 0)
    }

    @MainActor
    func testOnlyAnExpandedMapKeepsItsOwnPanAndZoomGestures() {
        let panel = UIView()
        let map = MKMapView()
        let mapContent = UIView()
        let ordinaryScroll = UIScrollView()
        panel.addSubview(map)
        panel.addSubview(ordinaryScroll)
        map.addSubview(mapContent)
        let recognizer = PanelPanRecognizer()

        recognizer.panelScrollEnabled = false
        XCTAssertFalse(recognizer.shouldYieldToMap(at: mapContent), "The collapsed panel must keep its own drag")
        recognizer.panelScrollEnabled = true
        XCTAssertTrue(recognizer.shouldYieldToMap(at: map))
        XCTAssertTrue(recognizer.shouldYieldToMap(at: mapContent), "MapKit's descendant views must keep map interaction")
        XCTAssertFalse(recognizer.shouldYieldToMap(at: ordinaryScroll))
        XCTAssertFalse(recognizer.shouldYieldToMap(at: panel))
        XCTAssertFalse(recognizer.shouldYieldToMap(at: nil))
        mapContent.removeFromSuperview()
        XCTAssertFalse(recognizer.shouldYieldToMap(at: mapContent))
    }

    @MainActor
    func testViewportChangeCancelsAndReenablesTheRecognizerButOrdinaryUpdatesDoNot() {
        let recognizer = PanelPanRecognizer()
        let changes = PanEnabledChanges()
        let observation = recognizer.observe(\.isEnabled, options: .new) { _, change in
            MainActor.assumeIsolated {
                if let enabled = change.newValue { changes.values.append(enabled) }
            }
        }
        let portrait = CGSize(width: 390, height: 844)
        recognizer.resetForViewportChange(to: portrait)
        XCTAssertEqual(changes.values, [false, true])
        changes.values.removeAll()

        recognizer.resetForViewportChange(to: portrait)

        XCTAssertTrue(changes.values.isEmpty, "Normal pan updates must not cancel the active recognizer")
        recognizer.resetForViewportChange(to: CGSize(width: 844, height: 390))
        XCTAssertEqual(changes.values, [false, true], "Resizing must cancel the old gesture and accept a new one")
        XCTAssertTrue(recognizer.isEnabled)
        withExtendedLifetime(observation) {}
    }

    private func assertDetents(_ actual: [CGFloat], _ expected: [CGFloat], file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(actual.count, expected.count, file: file, line: line)
        for (height, expectedHeight) in zip(actual, expected) {
            XCTAssertEqual(height, expectedHeight, accuracy: 0.01, file: file, line: line)
        }
    }
}

@MainActor
private final class PanEnabledChanges {
    var values: [Bool] = []
}
