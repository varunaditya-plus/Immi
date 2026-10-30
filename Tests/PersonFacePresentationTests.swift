import SwiftUI
import UIKit
import XCTest
@testable import ImmichApp

@MainActor
final class PersonFacePresentationTests: SimulatorHostedTestCase {


    func testFacesToggleReconfiguresTheActualVisibleCellWithoutChangingItsAssetIdentity() async throws {
        let loader = FacePresentationLoader()
        let controller = PhotoGridController(loader: loader, session: MockSessionManager())
        let asset = AssetLite(id: UUID().uuidString, isVideo: false, ratio: 2, thumbhash: nil, createdAt: .distantPast)
        let sections = [TimelineSection(id: "month", title: "Month", assets: [asset])]
        var configuration = PhotoGridConfiguration(facePersonID: "person", showsSectionHeaders: false)
        controller.apply(sections: sections, configuration: configuration, hero: nil)
        let window = try await host(FacePresentationHost(controller: controller))
        let collectionView = try XCTUnwrap(controller.view.subviews.compactMap { $0 as? UICollectionView }.first)
        var cell: PhotoGridCell?
        try await waitUntil("The real grid renders the face-specific image") {
            guard let path = controller.revealCell(for: asset.id) else { return false }
            cell = collectionView.cellForItem(at: path) as? PhotoGridCell
            return cell?.displayedImage === loader.face
        }
        var opened: [String] = []
        controller.onOpen = { opened.append($0) }
        XCTAssertTrue(try XCTUnwrap(cell).accessibilityActivate())
        XCTAssertEqual(opened, [asset.id], "Faces mode must still open the original photo identity")

        configuration.facePersonID = nil
        controller.apply(sections: sections, configuration: configuration, hero: nil)

        try await waitUntil("Switching back reconfigures the same visible cell to the original image") {
            guard let path = controller.revealCell(for: asset.id),
                  let currentCell = collectionView.cellForItem(at: path) as? PhotoGridCell else { return false }
            return currentCell === cell && currentCell.displayedImage === loader.original
        }
        _ = try await screenshot(window)
    }

    func testFaceCropsClampToTheImageAndRejectStaleAspectSpace() throws {
        let face = try decodeFace(x1: -20, y1: 10, x2: 50, y2: 70)
        let crop = try XCTUnwrap(face.normalizedCrop)
        XCTAssertGreaterThanOrEqual(crop.minX, 0)
        XCTAssertGreaterThanOrEqual(crop.minY, 0)
        XCTAssertLessThanOrEqual(crop.maxX, 1)
        XCTAssertLessThanOrEqual(crop.maxY, 1)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let data = UIGraphicsImageRenderer(size: CGSize(width: 200, height: 100), format: format).pngData { context in
            UIColor.red.setFill(); context.fill(CGRect(x: 0, y: 0, width: 100, height: 100))
            UIColor.blue.setFill(); context.fill(CGRect(x: 100, y: 0, width: 100, height: 100))
        }
        let cropped = try XCTUnwrap(PersonFaceImage.croppedData(data, face: face))
        let image = try XCTUnwrap(UIImage(data: cropped))
        XCTAssertEqual(image.size.width, image.size.height, accuracy: 2)
        XCTAssertLessThan(image.size.width, 110)
        let square = UIGraphicsImageRenderer(size: CGSize(width: 100, height: 100), format: format).pngData { _ in }
        XCTAssertNil(PersonFaceImage.croppedData(square, face: face), "A square or stale-edited preview cannot use wide-image face coordinates")
        XCTAssertNil(try decodeFace(x1: 50, y1: 10, x2: 20, y2: 70).normalizedCrop)
        XCTAssertNil(try decodeFace(x1: 300, y1: 100, x2: 400, y2: 200).normalizedCrop)
        let extremes = try XCTUnwrap(decodeFace(x1: Int.min, y1: Int.min, x2: Int.max, y2: Int.max).normalizedCrop)
        XCTAssertTrue(extremes.minX.isFinite && extremes.maxX.isFinite && extremes.minY.isFinite && extremes.maxY.isFinite)
    }

    func testFaceNamespacesDoNotOverwriteOrdinaryThumbnailsAndTrackGeometryInvalidation() async throws {
        let loader = PhotoThumbnailLoader(session: MockSessionManager())
        let id = UUID().uuidString
        let normal = loader.cacheKey(for: id)
        let before = loader.faceCacheKey(for: id, personID: "first")
        XCTAssertNotEqual(before, normal)
        XCTAssertNotEqual(before, loader.faceCacheKey(for: id, personID: "second"))
        LocalSnapshot.remove(LocalSnapshot.Key.person("first"))
        XCTAssertNotEqual(before, loader.faceCacheKey(for: id, personID: "first"))
        XCTAssertEqual(loader.cacheKey(for: id), normal)
    }

    private func decodeFace(x1: Int, y1: Int, x2: Int, y2: Int) throws -> PersonFaceDTO {
        let data = try JSONSerialization.data(withJSONObject: ["id": "face", "imageWidth": 200, "imageHeight": 100,
            "boundingBoxX1": x1, "boundingBoxY1": y1, "boundingBoxX2": x2, "boundingBoxY2": y2, "person": NSNull()])
        return try JSONDecoder.immich.decode(PersonFaceDTO.self, from: data)
    }
}

private struct FacePresentationHost: UIViewControllerRepresentable {
    let controller: PhotoGridController
    func makeUIViewController(context: Context) -> PhotoGridController { controller }
    func updateUIViewController(_ uiViewController: PhotoGridController, context: Context) {}
}

@MainActor
private final class FacePresentationLoader: PhotoThumbnailLoader {
    let original = UIGraphicsImageRenderer(size: CGSize(width: 2, height: 2)).image { context in
        UIColor.blue.setFill(); context.fill(CGRect(x: 0, y: 0, width: 2, height: 2))
    }
    let face = UIGraphicsImageRenderer(size: CGSize(width: 2, height: 2)).image { context in
        UIColor.red.setFill(); context.fill(CGRect(x: 0, y: 0, width: 2, height: 2))
    }
    init() { super.init(session: MockSessionManager()) }
    override func cachedImage(for assetId: String) -> UIImage? { original }
    override func cachedFaceImage(for assetID: String, personID: String) -> UIImage? { face }
}
