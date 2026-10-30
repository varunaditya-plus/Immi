import XCTest
@testable import ImmichApp

final class PhotoCollectionCoverTests: XCTestCase {
    func testChosenAlbumCoverIsUsedEvenOutsideThePreviewPrefix() {
        let assets = (0..<12).map(asset)
        let cover = PhotoCollectionCover.assets(in: assets, preferredID: "11")
        XCTAssertEqual(cover.map(\.id), ["11"])
    }

    func testDeletedOrInaccessibleCoverFallsBackOnlyToVisibleMembers() {
        let assets = (0..<12).map(asset)
        let cover = PhotoCollectionCover.assets(in: assets, preferredID: "removed")
        XCTAssertEqual(cover.map(\.id), (0..<8).map(String.init))
        XCTAssertFalse(cover.contains { $0.id == "removed" })
    }

    func testNoCoverCanBeResolvedForAnEmptyCollection() {
        XCTAssertTrue(PhotoCollectionCover.assets(in: [], preferredID: "old-cover").isEmpty)
    }

    private func asset(_ value: Int) -> AssetLite {
        AssetLite(id: String(value), isVideo: false, ratio: 1,
                  thumbhash: nil, createdAt: Date(timeIntervalSince1970: Double(value)))
    }
}
