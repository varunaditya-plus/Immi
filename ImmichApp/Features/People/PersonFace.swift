import Foundation
import ImageIO
import UIKit

struct PersonFaceDTO: Decodable, Identifiable, Hashable, Sendable {
    let id: String
    let imageWidth: Int
    let imageHeight: Int
    let boundingBoxX1: Int
    let boundingBoxY1: Int
    let boundingBoxX2: Int
    let boundingBoxY2: Int
    let person: PersonDTO?

    var normalizedCrop: CGRect? {
        guard imageWidth > 0, imageHeight > 0,
              boundingBoxX2 > boundingBoxX1, boundingBoxY2 > boundingBoxY1 else { return nil }
        let width = CGFloat(imageWidth), height = CGFloat(imageHeight)
        let face = CGRect(x: CGFloat(boundingBoxX1), y: CGFloat(boundingBoxY1),
            width: CGFloat(boundingBoxX2) - CGFloat(boundingBoxX1),
            height: CGFloat(boundingBoxY2) - CGFloat(boundingBoxY1))
            .intersection(CGRect(x: 0, y: 0, width: width, height: height))
        guard !face.isNull, !face.isEmpty else { return nil }
        let side = min(max(face.width, face.height) * 1.45, min(width, height))
        let x = min(max(0, face.midX - side / 2), width - side)
        let y = min(max(0, face.midY - side / 2), height - side)
        return CGRect(x: x / width, y: y / height, width: side / width, height: side / height)
    }
}

enum PersonFaceImage {
    nonisolated static func croppedData(_ data: Data, face: PersonFaceDTO) -> Data? {
        guard let crop = face.normalizedCrop,
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 1_200,
              ] as CFDictionary) else { return nil }
        let actualRatio = Double(image.width) / Double(image.height)
        let expectedRatio = Double(face.imageWidth) / Double(face.imageHeight)
        guard abs(actualRatio / expectedRatio - 1) < 0.03 else { return nil }
        let pixels = CGRect(x: crop.minX * CGFloat(image.width), y: crop.minY * CGFloat(image.height),
            width: crop.width * CGFloat(image.width), height: crop.height * CGFloat(image.height)).integral
            .intersection(CGRect(x: 0, y: 0, width: CGFloat(image.width), height: CGFloat(image.height)))
        guard let cropped = image.cropping(to: pixels), cropped.width > 0, cropped.height > 0 else { return nil }
        return UIImage(cgImage: cropped, scale: 1, orientation: .up).pngData()
    }
}
