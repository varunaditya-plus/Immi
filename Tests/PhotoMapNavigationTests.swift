import XCTest
@testable import ImmichApp

@MainActor
final class PhotoMapNavigationTests: XCTestCase {
    func testUnfilteredLibraryMapDoesNotRestrictTheServerToPartiallyCachedPhotos() {
        let cached = [photo()]
        XCTAssertNil(PhotoMapNavigation.libraryIDs(for: cached, options: .init()))
        XCTAssertNil(PhotoMapNavigation.libraryIDs(for: cached, options: .init(sort: .recentlyAdded)),
            "Changing the sort must not hide uncached locations")
    }

    func testFilteredLibraryMapKeepsTheActualAdmittedPhotoScope() {
        let favorite = photo()
        XCTAssertEqual(PhotoMapNavigation.libraryIDs(for: [favorite], options: .init(filters: [.favorites])), [favorite.id])
        XCTAssertEqual(PhotoMapNavigation.libraryIDs(for: [], options: .init(filters: [.favorites])), [],
            "An empty filtered collection must not become the whole library")
        XCTAssertEqual(PhotoMapNavigation.libraryIDs(for: [favorite], options: .init(showsScreenshots: false)), [favorite.id])
    }

    private func photo() -> AssetLite {
        AssetLite(id: UUID().uuidString, isVideo: false, ratio: 1, thumbhash: nil, createdAt: .distantPast)
    }
}
