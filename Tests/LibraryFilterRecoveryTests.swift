import SwiftUI
import XCTest
@testable import ImmichApp

@MainActor
final class LibraryFilterRecoveryTests: SimulatorHostedTestCase {
    func testEmptyFilteredLibraryCanRemoveItsFilterFromAllMonthsAndYears() async throws {
        for mode in TimelineMode.allCases {
            let model = TimelineViewModel()
            let asset = AssetLite(id: UUID().uuidString, isVideo: false, ratio: 1, thumbhash: nil,
                createdAt: Date(timeIntervalSince1970: 1_750_000_000))
            model.sections = [TimelineSection(id: MonthKey.of(asset.createdAt), title: "Month", assets: [asset])]
            await model.updateLibraryOptions(.init(filters: [.favorites]))
            XCTAssertTrue(model.librarySections.isEmpty)
            let navigation = TimelineNavigationState()
            navigation.mode = mode
            let window = try await host(TimelineBrowserView(
                viewModel: model, navigation: navigation, gridController: nil,
                onRemoveFilters: {
                    Task {
                        var options = model.libraryOptions
                        options.filters.removeAll()
                        await model.updateLibraryOptions(options)
                    }
                }, grid: { Color.clear }))

            // Wait beyond the 420ms transition so an old All-pane button cannot
            // satisfy a Months/Years recovery check before the mode changes.
            try await Task.sleep(for: .milliseconds(750))
            try await activateAccessibilityButton(named: "Remove Filter", in: window)

            try await waitUntil("Filter removal restores the real grid and both overview data sets") {
                model.libraryOptions.filters.isEmpty && model.libraryAssets.map(\.id) == [asset.id]
                    && !model.libraryMonthNavigationItems.isEmpty && !model.libraryYearNavigationItems.isEmpty
            }
            XCTAssertEqual(navigation.mode, mode,
                "Recovery must work in the current overview without requiring a switch back to All")
        }
    }
}
