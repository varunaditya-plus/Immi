import UIKit
import XCTest
@testable import ImmichApp

@MainActor
final class PhotoCellAccessibilityTests: XCTestCase {
    func testGridDescribesMediaAndSelectionAndClearsReusedMetadata() {
        let loader = AccessibilityThumbnailLoader()
        let cell = PhotoGridCell(frame: .zero)
        var video = asset()
        video = AssetLite(id: video.id, isVideo: true, ratio: 1, thumbhash: nil,
                          createdAt: video.createdAt, isFavorite: true, duration: 95)
        cell.configure(with: video, loader: loader)

        XCTAssertTrue(cell.isAccessibilityElement)
        XCTAssertTrue(cell.contentView.accessibilityElementsHidden)
        XCTAssertEqual(cell.accessibilityLabel, label(String(localized: "Video"), video))
        let duration = "1:35"
        XCTAssertEqual(cell.accessibilityValue,
                       "\(String(localized: "Favorite")), \(String(localized: "Duration: \(duration)"))")
        XCTAssertTrue(cell.accessibilityTraits.contains(.image))
        XCTAssertTrue(cell.accessibilityTraits.contains(.button))
        XCTAssertFalse(cell.accessibilityTraits.contains(.selected))
        XCTAssertEqual(cell.accessibilityHint, String(localized: "Opens the viewer."))

        cell.setSelectionState(showsSelection: true, isPicked: true)
        XCTAssertTrue(cell.accessibilityTraits.contains(.selected))
        XCTAssertEqual(cell.accessibilityHint, String(localized: "Deselects this item."))
        cell.setSelectionState(showsSelection: true, isPicked: false)
        XCTAssertFalse(cell.accessibilityTraits.contains(.selected))
        XCTAssertEqual(cell.accessibilityHint, String(localized: "Selects this item."))

        let livePhoto = asset(livePhoto: true)
        cell.configure(with: livePhoto, loader: loader)
        XCTAssertEqual(cell.accessibilityLabel, label(String(localized: "Live Photo"), livePhoto))
        XCTAssertNil(cell.accessibilityValue, "A new photo must not inherit favorite or video duration")
        var activations = 0
        cell.onAccessibilityActivate = { activations += 1; return true }
        cell.prepareForReuse()

        assertCleared(cell)
        XCTAssertNil(cell.onAccessibilityActivate)
        XCTAssertFalse(cell.accessibilityActivate())
        XCTAssertEqual(activations, 0)
    }

    func testFilmstripRefreshesSamePhotoMetadataAndClearsCurrentStateOnReuse() {
        let loader = AccessibilityThumbnailLoader()
        let cell = PhotoFilmstripCell(frame: .zero)
        var photo = asset()
        cell.configure(with: photo, loader: loader)
        cell.setCurrent(true)

        XCTAssertTrue(cell.isAccessibilityElement)
        XCTAssertTrue(cell.contentView.accessibilityElementsHidden)
        XCTAssertEqual(cell.accessibilityLabel, label(String(localized: "Photo"), photo))
        XCTAssertNil(cell.accessibilityValue)
        XCTAssertTrue(cell.accessibilityTraits.contains(.selected))
        photo.isFavorite = true
        photo.livePhotoVideoID = "live-video"
        cell.configure(with: photo, loader: loader)
        cell.setCurrent(true)

        XCTAssertEqual(cell.accessibilityLabel, label(String(localized: "Live Photo"), photo))
        XCTAssertEqual(cell.accessibilityValue, String(localized: "Favorite"))
        XCTAssertTrue(cell.accessibilityTraits.contains(.button))
        XCTAssertTrue(cell.accessibilityTraits.contains(.image))
        XCTAssertTrue(cell.accessibilityTraits.contains(.selected))
        cell.setCurrent(false)
        XCTAssertFalse(cell.accessibilityTraits.contains(.selected))
        cell.setCurrent(true)
        var activations = 0
        cell.onAccessibilityActivate = { activations += 1; return true }
        cell.prepareForReuse()

        assertCleared(cell)
        XCTAssertNil(cell.onAccessibilityActivate)
        XCTAssertFalse(cell.accessibilityActivate())
        XCTAssertEqual(activations, 0)
    }

    func testPrivacyRejectedConfigurationClearsBothCellDescriptionsAndActions() {
        let loader = AccessibilityThumbnailLoader()
        let removed = RemovedAssets()
        loader.visibilityPolicy = AssetVisibilityPolicy(removed: removed)
        let photo = asset(livePhoto: true)
        let grid = PhotoGridCell(frame: .zero)
        let filmstrip = PhotoFilmstripCell(frame: .zero)
        grid.configure(with: photo, loader: loader)
        filmstrip.configure(with: photo, loader: loader)
        grid.setSelectionState(showsSelection: true, isPicked: true)
        filmstrip.setCurrent(true)
        var activations = 0
        grid.onAccessibilityActivate = { activations += 1; return true }
        filmstrip.onAccessibilityActivate = { activations += 1; return true }

        removed.remove([photo.id])
        grid.configure(with: photo, loader: loader)
        filmstrip.configure(with: photo, loader: loader)

        assertCleared(grid)
        assertCleared(filmstrip)
        XCTAssertNil(grid.onAccessibilityActivate)
        XCTAssertNil(filmstrip.onAccessibilityActivate)
        XCTAssertFalse(grid.accessibilityActivate())
        XCTAssertFalse(filmstrip.accessibilityActivate())
        XCTAssertEqual(activations, 0)
    }

    func testGridVoiceOverActivationOpensOrTogglesTheActualSelection() async throws {
        let photo = asset()
        let controller = makeGrid([photo])
        let collection = try collectionView(in: controller)
        try await waitUntil { collection.visibleCells.contains { $0 is PhotoGridCell } }
        let cell = try XCTUnwrap(collection.visibleCells.first as? PhotoGridCell)
        var opened: [String] = []
        var selections: [Set<String>] = []
        controller.onOpen = { opened.append($0) }
        controller.onSelectionChanged = { selections.append($0) }

        XCTAssertTrue(cell.accessibilityActivate())
        XCTAssertEqual(opened, [photo.id])
        XCTAssertTrue(collection.indexPathsForSelectedItems?.isEmpty ?? true)
        controller.setSelecting(true)
        XCTAssertTrue(cell.accessibilityActivate())
        XCTAssertEqual(selections, [[photo.id]])
        XCTAssertTrue(cell.isSelected)
        XCTAssertTrue(cell.accessibilityTraits.contains(.selected))
        XCTAssertTrue(cell.accessibilityActivate())
        XCTAssertEqual(selections, [[photo.id], []])
        XCTAssertFalse(cell.isSelected)
        XCTAssertFalse(cell.accessibilityTraits.contains(.selected))
        XCTAssertEqual(opened, [photo.id], "Selecting and deselecting must not open the viewer")

        controller.setSelection([photo.id])
        XCTAssertTrue(cell.accessibilityTraits.contains(.selected), "Programmatic selection also updates VoiceOver")
        controller.setSelecting(false)
        XCTAssertFalse(cell.accessibilityTraits.contains(.selected))
        XCTAssertEqual(cell.accessibilityHint, String(localized: "Opens the viewer."))
    }

    func testGridMetadataRefreshKeepsTheSelectedStateAndActivation() async throws {
        var photo = asset()
        let controller = makeGrid([photo])
        let collection = try collectionView(in: controller)
        try await waitUntil { collection.visibleCells.contains { $0 is PhotoGridCell } }
        controller.setSelecting(true)
        controller.setSelection([photo.id])
        photo.isFavorite = true
        photo.livePhotoVideoID = "live-video"

        controller.apply(sections: [section([photo])], configuration: PhotoGridConfiguration(), hero: nil)
        try await waitUntil {
            collection.visibleCells.first?.accessibilityValue == String(localized: "Favorite")
        }
        let cell = try XCTUnwrap(collection.visibleCells.first as? PhotoGridCell)
        XCTAssertEqual(cell.accessibilityLabel, label(String(localized: "Live Photo"), photo))
        XCTAssertTrue(cell.accessibilityTraits.contains(.selected))
        var selected: Set<String>?
        controller.onSelectionChanged = { selected = $0 }
        XCTAssertTrue(cell.accessibilityActivate())
        XCTAssertEqual(selected, [])
        XCTAssertFalse(cell.accessibilityTraits.contains(.selected))
    }

    func testGridTwoFingerSelectionRefreshesAllVisibleAccessibilityHints() async throws {
        let first = asset(), second = asset()
        let controller = makeGrid([first, second])
        let collection = try collectionView(in: controller)
        let firstPath = IndexPath(item: 0, section: 0)
        let secondPath = IndexPath(item: 1, section: 0)
        try await waitUntil {
            collection.cellForItem(at: firstPath) is PhotoGridCell
                && collection.cellForItem(at: secondPath) is PhotoGridCell
        }
        let firstCell = try XCTUnwrap(collection.cellForItem(at: firstPath) as? PhotoGridCell)
        let secondCell = try XCTUnwrap(collection.cellForItem(at: secondPath) as? PhotoGridCell)
        var selecting: [Bool] = []
        var selected: Set<String>?
        controller.onSelectingChanged = { selecting.append($0) }
        controller.onSelectionChanged = { selected = $0 }
        XCTAssertEqual(firstCell.accessibilityHint, String(localized: "Opens the viewer."))
        XCTAssertEqual(secondCell.accessibilityHint, String(localized: "Opens the viewer."))

        XCTAssertTrue(controller.collectionView(collection, shouldBeginMultipleSelectionInteractionAt: firstPath))
        controller.collectionView(collection, didBeginMultipleSelectionInteractionAt: firstPath)

        XCTAssertTrue(collection.isEditing)
        XCTAssertEqual(selecting, [true])
        XCTAssertEqual(firstCell.accessibilityHint, String(localized: "Selects this item."))
        XCTAssertEqual(secondCell.accessibilityHint, String(localized: "Selects this item."))
        controller.setSelecting(true)
        collection.selectItem(at: firstPath, animated: false, scrollPosition: [])
        controller.collectionView(collection, didSelectItemAt: firstPath)

        XCTAssertEqual(selected, [first.id])
        XCTAssertTrue(firstCell.isSelected)
        XCTAssertTrue(firstCell.accessibilityTraits.contains(.selected))
        XCTAssertEqual(firstCell.accessibilityHint, String(localized: "Deselects this item."))
        XCTAssertFalse(secondCell.isSelected)
        XCTAssertFalse(secondCell.accessibilityTraits.contains(.selected))
        XCTAssertEqual(secondCell.accessibilityHint, String(localized: "Selects this item."))

        controller.setSelecting(false)

        XCTAssertFalse(collection.isEditing)
        XCTAssertTrue(collection.indexPathsForSelectedItems?.isEmpty ?? true)
        for cell in [firstCell, secondCell] {
            XCTAssertFalse(cell.isSelected)
            XCTAssertFalse(cell.accessibilityTraits.contains(.selected))
            XCTAssertEqual(cell.accessibilityHint, String(localized: "Opens the viewer."))
        }
    }

    func testFilmstripVoiceOverUsesCurrentMetadataAndTracksThePagerSelection() throws {
        let first = asset()
        var second = asset()
        let controller = PhotoFilmstripController(loader: AccessibilityThumbnailLoader())
        size(controller, height: 76)
        controller.apply(assets: [first, second], currentAssetID: first.id)
        controller.view.layoutIfNeeded()
        let collection = try collectionView(in: controller)
        let firstCell = try XCTUnwrap(collection.cellForItem(at: IndexPath(item: 0, section: 0)) as? PhotoFilmstripCell)
        let secondCell = try XCTUnwrap(collection.cellForItem(at: IndexPath(item: 1, section: 0)) as? PhotoFilmstripCell)
        XCTAssertTrue(firstCell.accessibilityTraits.contains(.selected))
        XCTAssertFalse(secondCell.accessibilityTraits.contains(.selected))

        controller.track(page: 1)
        XCTAssertFalse(firstCell.accessibilityTraits.contains(.selected))
        XCTAssertTrue(secondCell.accessibilityTraits.contains(.selected))
        second.isFavorite = true
        second.livePhotoVideoID = "live-video"
        controller.apply(assets: [first, second], currentAssetID: second.id)
        controller.view.layoutIfNeeded()
        let refreshed = try XCTUnwrap(collection.cellForItem(at: IndexPath(item: 1, section: 0)) as? PhotoFilmstripCell)
        XCTAssertEqual(refreshed.accessibilityLabel, label(String(localized: "Live Photo"), second))
        XCTAssertTrue(refreshed.accessibilityTraits.contains(.selected))
        var selected: [AssetLite] = []
        controller.onSelect = { selected.append($0) }

        let neighbor = try XCTUnwrap(collection.cellForItem(at: IndexPath(item: 0, section: 0)) as? PhotoFilmstripCell)
        XCTAssertFalse(neighbor.accessibilityTraits.contains(.selected))
        XCTAssertTrue(neighbor.accessibilityActivate())
        XCTAssertEqual(selected.map(\.id), [first.id], "Activating a neighbor must select its photo, not the current photo")
        XCTAssertTrue(refreshed.accessibilityActivate())
        XCTAssertEqual(selected.map(\.id), [first.id, second.id])
        XCTAssertEqual(selected.last?.isFavorite, true)
        XCTAssertEqual(selected.last?.livePhotoVideoID, second.livePhotoVideoID)
    }

    private func asset(livePhoto: Bool = false) -> AssetLite {
        AssetLite(id: UUID().uuidString, isVideo: false, ratio: 1, thumbhash: nil,
                  createdAt: Date(timeIntervalSince1970: 1_730_200_200),
                  livePhotoVideoID: livePhoto ? "live-video" : nil)
    }

    private func label(_ kind: String, _ asset: AssetLite) -> String {
        "\(kind), \(asset.createdAt.formatted(date: .long, time: .shortened))"
    }

    private func assertCleared(_ cell: UICollectionViewCell, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertFalse(cell.isAccessibilityElement, file: file, line: line)
        XCTAssertNil(cell.accessibilityLabel, file: file, line: line)
        XCTAssertNil(cell.accessibilityValue, file: file, line: line)
        XCTAssertNil(cell.accessibilityHint, file: file, line: line)
        XCTAssertFalse(cell.accessibilityTraits.contains(.selected), file: file, line: line)
    }

    private func makeGrid(_ assets: [AssetLite]) -> PhotoGridController {
        let controller = PhotoGridController(loader: AccessibilityThumbnailLoader(), session: MockSessionManager())
        size(controller, height: 600)
        controller.apply(sections: [section(assets)], configuration: PhotoGridConfiguration(), hero: nil)
        controller.view.layoutIfNeeded()
        return controller
    }

    private func section(_ assets: [AssetLite]) -> TimelineSection {
        TimelineSection(id: "2024-10", title: "October 2024", assets: assets, count: assets.count, startIndex: 0)
    }

    private func size(_ controller: UIViewController, height: CGFloat) {
        controller.loadViewIfNeeded()
        controller.view.frame = CGRect(x: 0, y: 0, width: 390, height: height)
        controller.view.layoutIfNeeded()
    }

    private func collectionView(in controller: UIViewController) throws -> UICollectionView {
        try XCTUnwrap(controller.view.subviews.first { $0 is UICollectionView } as? UICollectionView)
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<100 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Collection view did not publish the expected cell state")
        throw CancellationError()
    }
}

@MainActor
private final class AccessibilityThumbnailLoader: PhotoThumbnailLoader {
    private let thumbnail = UIGraphicsImageRenderer(size: CGSize(width: 10, height: 10)).image { _ in }

    init() { super.init(session: MockSessionManager()) }

    override func cachedImage(for assetId: String) -> UIImage? { thumbnail }
}
