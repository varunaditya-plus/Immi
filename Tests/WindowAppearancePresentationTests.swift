import Observation
import SwiftUI
import UIKit
import XCTest
@testable import ImmichApp

@MainActor
final class WindowAppearancePresentationTests: SimulatorHostedTestCase {
    private var previousTheme: Any?

    override func setUp() async throws {
        try await super.setUp()
        previousTheme = UserDefaults.standard.object(forKey: SettingsViewModel.themeKey)
    }

    override func tearDown() async throws {
        try await super.tearDown()
        if let previousTheme { UserDefaults.standard.set(previousTheme, forKey: SettingsViewModel.themeKey) }
        else { UserDefaults.standard.removeObject(forKey: SettingsViewModel.themeKey) }
    }

    func testSystemAppearanceUpdatesAlreadyPresentedContentAndLeavesOtherWindowsAlone() async throws {
        let state = AppearancePresentation()
        let window = try await host(AppearancePresentationHost(state: state), style: .unspecified)
        let nativeStyle = try XCTUnwrap(window.windowScene).traitCollection.userInterfaceStyle
        let forced = nativeStyle == .dark ? UIUserInterfaceStyle.light : .dark
        let key = SettingsViewModel.themeKey
        UserDefaults.standard.set(forced == .dark ? "dark" : "light", forKey: key)
        try await waitUntil("The app applies its explicit appearance") {
            window.rootViewController?.traitCollection.userInterfaceStyle == forced
        }
        let other = try await host(Text("Other window"), style: nativeStyle)
        window.makeKey()
        state.showSheet = true
        try await waitUntil("A sheet is presented in the app's appearance") {
            window.rootViewController?.presentedViewController?.traitCollection.userInterfaceStyle == forced
        }
        let presented = try XCTUnwrap(window.rootViewController?.presentedViewController)
        UserDefaults.standard.set("system", forKey: key)
        try await waitUntil("An already-open sheet follows System without relaunching") {
            presented.traitCollection.userInterfaceStyle == nativeStyle
                && window.rootViewController?.traitCollection.userInterfaceStyle == nativeStyle
        }
        XCTAssertEqual(window.overrideUserInterfaceStyle, .unspecified)
        XCTAssertEqual(other.overrideUserInterfaceStyle, nativeStyle)
        XCTAssertEqual(other.rootViewController?.traitCollection.userInterfaceStyle, nativeStyle)

        UserDefaults.standard.set(forced == .dark ? "dark" : "light", forKey: key)
        try await waitUntil("The open sheet can switch back to an explicit appearance") {
            presented.traitCollection.userInterfaceStyle == forced
        }
    }
}

@MainActor @Observable
private final class AppearancePresentation {
    var showSheet = false
}

private struct AppearancePresentationHost: View {
    @Bindable var state: AppearancePresentation

    var body: some View {
        AppRouter()
            .sheet(isPresented: $state.showSheet) { Text("Presented content") }
    }
}
