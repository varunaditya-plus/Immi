import Observation
import SwiftUI
import UIKit
import Vision
import XCTest
@testable import ImmichApp

@MainActor
final class BackupSetupPresentationTests: SimulatorHostedTestCase {
    private var previousLaunchReadiness = false

    override func setUp() async throws {
        try await super.setUp()
        previousLaunchReadiness = AppLaunchState.shared.isReady
        AppLaunchState.shared.markReady()
    }

    override func tearDown() async throws {
        try await super.tearDown()
        if !previousLaunchReadiness { AppLaunchState.shared.reset() }
    }

    func testProfileTipPresentsFromTheActualRightHandAvatarInLTR() async throws {
        try await assertTipPresents(direction: .leftToRight)
    }

    func testProfileTipPresentsFromTheActualLeftHandAvatarInRTL() async throws {
        try await assertTipPresents(direction: .rightToLeft)
    }

    private func assertTipPresents(direction: LayoutDirection) async throws {
        let journey = BackupSetupJourney(hasSelectedAlbums: { false })
        journey.refreshForAlbumSelection()
        let layout = ProfileAnchorLayout()
        let window = try await host(ProfileAnchorHost(journey: journey, direction: direction, layout: layout))
        window.semanticContentAttribute = direction == .rightToLeft ? .forceRightToLeft : .forceLeftToRight
        window.rootViewController?.view.semanticContentAttribute = window.semanticContentAttribute
        window.setNeedsLayout()
        window.layoutIfNeeded()
        try await waitUntil("The native avatar reaches its actual trailing edge") {
            let frame = layout.frame
            guard frame.width > 0, frame.height > 0, frame.minX >= 0,
                  frame.maxX <= window.bounds.width + 1 else { return false }
            return direction == .rightToLeft
                ? frame.midX < window.bounds.midX : frame.midX > window.bounds.midX
        }
        if direction == .rightToLeft {
            XCTAssertLessThan(layout.frame.midX, window.bounds.midX, "RTL must place the actual avatar at the left")
        } else {
            XCTAssertGreaterThan(layout.frame.midX, window.bounds.midX, "LTR must place the actual avatar at the right")
        }
        try await waitUntil("The profile tip presents from its stable \(direction) avatar") {
            journey.isCoachmarkVisible
        }
        XCTAssertEqual(journey.step, .profile)
        let deadline = Date().addingTimeInterval(4)
        var text = ""
        repeat {
            let image = try await screenshot(window)
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.recognitionLanguages = ["en-US"]
            try VNImageRequestHandler(cgImage: XCTUnwrap(image.cgImage)).perform([request])
            text = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: " ")
            let words = String(text.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }).lowercased()
            if words.contains("keepyourphotossafe") { return }
        } while Date() < deadline
        XCTFail("The actual TipKit callout must render: \(text)")
    }
}

@MainActor @Observable
private final class ProfileAnchorLayout {
    var frame = CGRect.zero
}

private struct ProfileAnchorHost: View {
    let journey: BackupSetupJourney
    let direction: LayoutDirection
    let layout: ProfileAnchorLayout

    var body: some View {
        NavigationStack {
            Color(.systemBackground)
                .navigationTitle("Photos")
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        JourneyProfileButton(journey: journey) {
                            XCTFail("Presentation validation must not open Settings")
                        }
                        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { layout.frame = $0 }
                    }
                }
        }
        .environment(\.layoutDirection, direction)
    }
}
