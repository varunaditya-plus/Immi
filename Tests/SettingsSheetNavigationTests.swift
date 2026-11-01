import SwiftUI
import UIKit
import XCTest
@testable import ImmichApp

@MainActor
final class SettingsSheetNavigationTests: SimulatorHostedTestCase {
    func testCloseSettingsDismissesFromNestedBackupOptionsInBothAppearances() async throws {
        let initialSelection = LocalPhotoLibrary.shared.selectedAlbumIDs
        for style in [UIUserInterfaceStyle.light, .dark] {
            let session = MockSessionManager()
            let state = SettingsPresentationState()
            let window = try await host(SettingsNavigationHost(session: session, state: state), style: style)
            try await activateAccessibilityButton(named: "Open Settings", in: window)
            try await waitUntil("The actual settings sheet is presented") {
                window.rootViewController?.presentedViewController != nil
            }
            try await activateAccessibilityButton(named: "Back Up Photos", in: window)
            try await activateAccessibilityButton(named: "Backup Options", in: window)
            _ = try await screenshot(window)
            XCTAssertTrue(state.presented)
            try await activateAccessibilityButton(named: "Close Settings", in: window)
            try await waitUntil("Close dismisses the whole settings sheet from the nested page") {
                !state.presented && window.rootViewController?.presentedViewController == nil
            }
            XCTAssertEqual(LocalPhotoLibrary.shared.selectedAlbumIDs, initialSelection)
        }
    }
}

@MainActor @Observable
private final class SettingsPresentationState {
    var presented = false
}

private struct SettingsNavigationHost: View {
    let session: SessionManager
    @Bindable var state: SettingsPresentationState
    var body: some View {
        Button("Open Settings") { state.presented = true }
            .sheet(isPresented: $state.presented) { SettingsSheetView(session: session) }
            .environment(session)
    }
}
