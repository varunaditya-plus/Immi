import SwiftUI
import XCTest
@testable import ImmichApp

@MainActor
final class DerivedCollectionActionTests: XCTestCase {
    func testUnuploadedLocalItemsKeepShareAndDeleteWithoutServerOnlyCommands() {
        let fixture = screen()
        let localTitles = Set(fixture.menuActions(for: "local:only").map(\.title))
        for title in ["Favorite", "Archive", "Add to Album", "Move to Locked Folder", "Share Link"] {
            XCTAssertFalse(localTitles.contains(String(localized: String.LocalizationValue(title))))
        }
        XCTAssertTrue(localTitles.contains(String(localized: "Share")))
        XCTAssertTrue(localTitles.contains(String(localized: "Delete")))
        let remoteTitles = Set(fixture.menuActions(for: "remote").map(\.title))
        for title in ["Favorite", "Archive", "Add to Album", "Move to Locked Folder", "Share Link"] {
            XCTAssertTrue(remoteTitles.contains(String(localized: String.LocalizationValue(title))))
        }
    }

    func testMixedSelectionKeepsSafeActionsAndOmitsUnsupportedBulkMutations() {
        let fixture = screen()
        let mixed = fixture.selectionActions(for: ["local:only", "remote"])
        XCTAssertNotNil(mixed.share)
        XCTAssertNotNil(mixed.trashConfirmation)
        XCTAssertNil(mixed.favorite)
        XCTAssertNil(mixed.archive)
        XCTAssertTrue(mixed.menu.isEmpty)

        let remote = fixture.selectionActions(for: ["remote"])
        XCTAssertNotNil(remote.favorite)
        XCTAssertNotNil(remote.archive)
        XCTAssertEqual(remote.menu.count, 1, "Server-backed items retain the Locked Folder action")
    }

    private func screen() -> PhotoCollectionScreen<EmptyView> {
        let assets = [
            AssetLite(id: "local:only", isVideo: false, ratio: 1, thumbhash: nil, createdAt: .distantPast, origin: .device),
            AssetLite(id: "remote", isVideo: false, ratio: 1, thumbhash: nil, createdAt: .distantPast)
        ]
        return PhotoCollectionScreen(title: "Recent Days", assets: assets, phase: .loaded(()),
            onRetry: {}, onToggleFavorite: { _ in }, onDelete: { _ in }, shareURLs: { _ in [] },
            onAddToAlbum: { _ in }, onFavoriteSelection: { _ in }, onArchiveSelection: { _ in },
            onMoveToLocked: { _ in }, onShareLink: { _ in },
            canPerformServerActions: { !$0.needsUpload })
    }
}
