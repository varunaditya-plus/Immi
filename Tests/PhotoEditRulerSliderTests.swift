import Observation
import SwiftUI
import UIKit
import XCTest
@testable import ImmichApp

@MainActor
final class PhotoEditRulerSliderTests: SimulatorHostedTestCase {
    func testRealRulerMapsNormalizedInputAndVoiceOverBoundsThenRejectsDisabledEvents() async throws {
        let fixture = RulerSliderFixture()
        let window = try await host(RulerSliderHost(fixture: fixture))
        var slider: UISlider?
        try await waitUntil("The real normalized ruler slider is mounted") {
            slider = self.views(window).compactMap { $0 as? UISlider }.first { $0.accessibilityLabel == "Exposure" }
            return slider != nil
        }
        let control = try XCTUnwrap(slider)
        XCTAssertEqual(control.minimumValue, 0)
        XCTAssertEqual(control.maximumValue, 1)
        XCTAssertEqual(control.value, 0.5, accuracy: 0.001)
        control.sendActions(for: .touchDown)
        control.value = 0.8
        control.sendActions(for: .valueChanged)
        control.sendActions(for: .touchUpInside)
        try await waitUntil("The real control maps fraction .8 into signed Exposure .6") { abs(fixture.value - 0.6) < 0.001 }
        XCTAssertEqual(fixture.editing, [true, false])

        control.value = 0.995
        control.sendActions(for: .valueChanged)
        control.accessibilityIncrement()
        try await waitUntil("VoiceOver clamps at the real adjustment upper bound") { fixture.value == 1 }
        control.accessibilityIncrement()
        XCTAssertEqual(fixture.value, 1)
        control.accessibilityDecrement()
        try await waitUntil("VoiceOver decreases the actual bound value") { abs(fixture.value - 0.98) < 0.001 }

        fixture.enabled = false
        try await waitUntil("The actual ruler becomes disabled") { !control.isEnabled }
        let captured = fixture.value
        control.accessibilityIncrement()
        control.value = 0.2
        control.sendActions(for: .valueChanged)
        XCTAssertEqual(fixture.value, captured, "Disabled controls must reject queued UIControl and VoiceOver writes")
    }

    private func views(_ view: UIView) -> [UIView] { [view] + view.subviews.flatMap(views) }
}

@MainActor @Observable
private final class RulerSliderFixture {
    var value: Double = 0
    var enabled = true
    var editing: [Bool] = []
}

private struct RulerSliderHost: View {
    @Bindable var fixture: RulerSliderFixture
    var body: some View {
        PhotoEditRulerSlider(value: $fixture.value, in: -1...1, label: "Exposure", valueText: "\(Int(fixture.value * 100))",
            onEditingChanged: { fixture.editing.append($0) })
            .disabled(!fixture.enabled)
            .padding(24)
    }
}
