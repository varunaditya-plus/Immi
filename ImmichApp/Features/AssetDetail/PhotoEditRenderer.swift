import CoreImage
import ImageIO
import UIKit
import UniformTypeIdentifiers

enum PhotoEditRenderError: LocalizedError {
    case unavailable, failed
    var errorDescription: String? {
        switch self {
        case .unavailable: String(localized: "This photo could not be opened for editing.")
        case .failed: String(localized: "The edited photo could not be rendered.")
        }
    }
}

actor PhotoEditRenderer {
    static let shared = PhotoEditRenderer()
    private let context = CIContext(options: [.cacheIntermediates: false])

    nonisolated static func render(_ source: CIImage, recipe: PhotoEditRecipe) throws -> CIImage {
        let recipe = recipe.normalized()
        guard source.extent.width.isFinite, source.extent.height.isFinite,
              source.extent.width > 0, source.extent.height > 0 else { throw PhotoEditRenderError.unavailable }
        var image = originNormalized(source)
        let original = image.extent
        let crop = recipe.crop
        image = image.cropped(to: CGRect(x: crop.minX * original.width,
            y: (1 - crop.maxY) * original.height, width: crop.width * original.width,
            height: crop.height * original.height).integral.intersection(original))
        image = originNormalized(image)
        image = adjustments(image, recipe: recipe)
        image = filter(image, kind: recipe.filter, intensity: recipe.filterIntensity)
        if recipe.flipHorizontal { image = originNormalized(image.transformed(by: CGAffineTransform(scaleX: -1, y: 1))) }
        if recipe.flipVertical { image = originNormalized(image.transformed(by: CGAffineTransform(scaleX: 1, y: -1))) }
        if recipe.quarterTurns != 0 {
            let orientation: Int32 = recipe.quarterTurns == 1 ? 6 : recipe.quarterTurns == 2 ? 3 : 8
            image = originNormalized(image.oriented(forExifOrientation: orientation))
        }
        if recipe.straighten != 0 {
            let extent = image.extent
            let angle = -CGFloat(recipe.straighten) * .pi / 180
            let transform = CGAffineTransform(translationX: -extent.midX, y: -extent.midY)
                .concatenating(CGAffineTransform(rotationAngle: angle))
                .concatenating(CGAffineTransform(translationX: extent.midX, y: extent.midY))
            let points = corners(extent).map { $0.applying(transform) }
            image = originNormalized(image.transformed(by: transform).cropped(to: interiorRect(in: points, size: extent.size)))
        }
        if recipe.perspectiveHorizontal != 0 || recipe.perspectiveVertical != 0 {
            let extent = image.extent
            let x = CGFloat(recipe.perspectiveVertical) * extent.width * 0.2
            let y = CGFloat(recipe.perspectiveHorizontal) * extent.height * 0.2
            let points = [CGPoint(x: x, y: extent.height - y), CGPoint(x: extent.width - x, y: extent.height + y),
                CGPoint(x: extent.width + x, y: -y), CGPoint(x: -x, y: y)]
            image = image.applyingFilter("CIPerspectiveTransform", parameters: [
                "inputTopLeft": CIVector(cgPoint: points[0]), "inputTopRight": CIVector(cgPoint: points[1]),
                "inputBottomRight": CIVector(cgPoint: points[2]), "inputBottomLeft": CIVector(cgPoint: points[3]),
            ])
            image = originNormalized(image.cropped(to: interiorRect(in: points, size: extent.size)))
        }
        let extent = image.extent, framing = recipe.framing
        image = image.cropped(to: CGRect(x: framing.minX * extent.width,
            y: (1 - framing.maxY) * extent.height, width: framing.width * extent.width,
            height: framing.height * extent.height).integral.intersection(extent))
        guard image.extent.width >= 1, image.extent.height >= 1 else { throw PhotoEditRenderError.failed }
        return originNormalized(image)
    }

    func renderPreview(_ image: UIImage, recipe: PhotoEditRecipe, maxPixelSize: Int = 2048) async throws -> UIImage {
        try Task.checkCancellation()
        guard let source = Self.input(image) else { throw PhotoEditRenderError.unavailable }
        let scale = min(1, CGFloat(max(1, maxPixelSize)) / max(source.extent.width, source.extent.height))
        let resized = source.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let rendered = try Self.render(resized, recipe: recipe)
        guard let result = context.createCGImage(rendered, from: rendered.extent.integral) else { throw PhotoEditRenderError.failed }
        try Task.checkCancellation()
        return UIImage(cgImage: result)
    }

    func renderFile(_ source: URL, recipe: PhotoEditRecipe) async throws -> URL {
        try Task.checkCancellation()
        guard source.isFileURL, let input = CGImageSourceCreateWithURL(source as CFURL, nil),
              CGImageSourceGetCount(input) == 1, CGImageSourceGetStatus(input) == .statusComplete,
              let decoded = CGImageSourceCreateImageAtIndex(input, 0, nil) else { throw PhotoEditRenderError.unavailable }
        var properties = CGImageSourceCopyPropertiesAtIndex(input, 0, nil) as? [String: Any] ?? [:]
        let orientation = (properties[kCGImagePropertyOrientation as String] as? NSNumber)?.int32Value ?? 1
        let image = try Self.render(CIImage(cgImage: decoded).oriented(forExifOrientation: orientation), recipe: recipe)
        let colorSpace = decoded.colorSpace?.model == .rgb ? decoded.colorSpace! : CGColorSpaceCreateDeviceRGB()
        guard let rendered = context.createCGImage(image, from: image.extent.integral,
            format: .RGBA8, colorSpace: colorSpace) else { throw PhotoEditRenderError.failed }
        let originalType = (CGImageSourceGetType(input) as String?).flatMap { UTType($0) }
        let alpha = [.first, .last, .premultipliedFirst, .premultipliedLast, .alphaOnly].contains(decoded.alphaInfo)
        let writableTypes = CGImageDestinationCopyTypeIdentifiers() as? [String] ?? []
        let type = originalType.flatMap { writableTypes.contains($0.identifier) ? $0 : nil } ?? (alpha ? .png : .jpeg)
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: temporary) }
        guard let destination = CGImageDestinationCreateWithURL(temporary as CFURL, type.identifier as CFString, 1, nil) else {
            throw PhotoEditRenderError.failed
        }
        properties[kCGImagePropertyOrientation as String] = 1
        properties[kCGImagePropertyPixelWidth as String] = rendered.width
        properties[kCGImagePropertyPixelHeight as String] = rendered.height
        properties[kCGImageDestinationLossyCompressionQuality as String] = 0.95
        if var exif = properties[kCGImagePropertyExifDictionary as String] as? [String: Any] {
            exif[kCGImagePropertyExifPixelXDimension as String] = rendered.width
            exif[kCGImagePropertyExifPixelYDimension as String] = rendered.height
            properties[kCGImagePropertyExifDictionary as String] = exif
        }
        if var tiff = properties[kCGImagePropertyTIFFDictionary as String] as? [String: Any] {
            tiff[kCGImagePropertyTIFFOrientation as String] = 1
            properties[kCGImagePropertyTIFFDictionary as String] = tiff
        }
        CGImageDestinationAddImage(destination, rendered, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw PhotoEditRenderError.failed }
        try Task.checkCancellation()
        return try TemporaryMediaStore.adoptShareFile(at: temporary,
            suggestedFilename: source.deletingPathExtension().lastPathComponent + "." + (type.preferredFilenameExtension ?? "jpg"))
    }

    private nonisolated static func adjustments(_ input: CIImage, recipe: PhotoEditRecipe) -> CIImage {
        var image = input
        if recipe[.auto] > 0 {
            var automatic = image
            for effect in input.autoAdjustmentFilters(options: [.enhance: true, .redEye: false, .crop: false, .level: false]) {
                effect.setValue(automatic, forKey: kCIInputImageKey)
                automatic = effect.outputImage ?? automatic
            }
            image = blend(image, automatic, amount: recipe[.auto])
        }
        if recipe[.exposure] != 0 { image = image.applyingFilter("CIExposureAdjust", parameters: [kCIInputEVKey: recipe[.exposure] * 2]) }
        let brilliance = recipe[.brilliance]
        if brilliance != 0 || recipe[.shadows] != 0 {
            image = image.applyingFilter("CIHighlightShadowAdjust", parameters: [
                "inputHighlightAmount": 1 - brilliance * 0.25,
                "inputShadowAmount": recipe[.shadows] * 0.8 + brilliance * 0.4,
            ])
        }
        if recipe[.highlights] != 0 {
            let value = recipe[.highlights]
            image = image.applyingFilter("CIToneCurve", parameters: [
                "inputPoint0": CIVector(x: 0, y: 0), "inputPoint1": CIVector(x: 0.25, y: 0.25),
                "inputPoint2": CIVector(x: 0.5, y: 0.5 + value * 0.02),
                "inputPoint3": CIVector(x: 0.75, y: 0.75 + value * 0.12), "inputPoint4": CIVector(x: 1, y: 1),
            ])
        }
        if recipe[.brightness] != 0 || recipe[.contrast] != 0 || recipe[.saturation] != 0 || brilliance != 0 {
            image = image.applyingFilter("CIColorControls", parameters: [
                kCIInputBrightnessKey: recipe[.brightness] * 0.25 + brilliance * 0.035,
                kCIInputContrastKey: 1 + recipe[.contrast] * 0.75 + brilliance * 0.12,
                kCIInputSaturationKey: 1 + recipe[.saturation],
            ])
        }
        if recipe[.blackPoint] != 0 {
            let value = recipe[.blackPoint] * 0.12
            let coefficients = CIVector(x: -value, y: 1 + value, z: 0, w: 0)
            image = image.applyingFilter("CIColorPolynomial", parameters: [
                "inputRedCoefficients": coefficients, "inputGreenCoefficients": coefficients, "inputBlueCoefficients": coefficients,
            ])
        }
        if recipe[.vibrance] != 0 { image = image.applyingFilter("CIVibrance", parameters: [kCIInputAmountKey: recipe[.vibrance]]) }
        if recipe[.warmth] != 0 || recipe[.tint] != 0 {
            image = image.applyingFilter("CITemperatureAndTint", parameters: [
                "inputNeutral": CIVector(x: 6500 + recipe[.warmth] * 2500, y: recipe[.tint] * 100),
                "inputTargetNeutral": CIVector(x: 6500, y: 0),
            ])
        }
        if recipe[.sharpness] != 0 { image = image.applyingFilter("CISharpenLuminance", parameters: [kCIInputSharpnessKey: recipe[.sharpness] * 2]) }
        if recipe[.definition] != 0 {
            image = image.applyingFilter("CIUnsharpMask", parameters: [kCIInputRadiusKey: max(1, min(image.extent.width, image.extent.height) / 500),
                kCIInputIntensityKey: recipe[.definition] * 1.2]).cropped(to: image.extent)
        }
        if recipe[.noiseReduction] != 0 {
            image = image.applyingFilter("CINoiseReduction", parameters: ["inputNoiseLevel": recipe[.noiseReduction] * 0.1,
                kCIInputSharpnessKey: 0])
        }
        if recipe[.vignette] != 0 {
            image = image.applyingFilter("CIVignette", parameters: [kCIInputIntensityKey: recipe[.vignette] * 1.5,
                kCIInputRadiusKey: min(image.extent.width, image.extent.height) * 0.6])
        }
        return image.cropped(to: input.extent)
    }

    private nonisolated static func filter(_ image: CIImage, kind: PhotoEditFilter, intensity: Double) -> CIImage {
        guard kind != .original, intensity > 0 else { return image }
        var output: CIImage
        switch kind {
        case .original: return image
        case .mono: output = image.applyingFilter("CIPhotoEffectMono")
        case .silvertone: output = image.applyingFilter("CIPhotoEffectTonal")
        case .noir: output = image.applyingFilter("CIPhotoEffectNoir")
        case .vivid, .vividWarm, .vividCool:
            output = image.applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: 1.3, kCIInputContrastKey: 1.12])
        case .dramatic, .dramaticWarm, .dramaticCool:
            output = image.applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: 0.85,
                kCIInputContrastKey: 1.35, kCIInputBrightnessKey: -0.04])
        }
        if [.vividWarm, .dramaticWarm, .vividCool, .dramaticCool].contains(kind) {
            let warm = kind == .vividWarm || kind == .dramaticWarm
            output = output.applyingFilter("CITemperatureAndTint", parameters: [
                "inputNeutral": CIVector(x: warm ? 8500 : 4500, y: 0), "inputTargetNeutral": CIVector(x: 6500, y: 0),
            ])
        }
        return blend(image, output, amount: intensity)
    }

    private nonisolated static func blend(_ original: CIImage, _ changed: CIImage, amount: Double) -> CIImage {
        guard amount < 1 else { return changed.cropped(to: original.extent) }
        return original.applyingFilter("CIDissolveTransition", parameters: [kCIInputTargetImageKey: changed,
            kCIInputTimeKey: amount]).cropped(to: original.extent)
    }

    private nonisolated static func input(_ image: UIImage) -> CIImage? {
        guard let raw = image.cgImage.map(CIImage.init(cgImage:)) ?? image.ciImage else { return nil }
        let orientation: Int32
        switch image.imageOrientation {
        case .up: orientation = 1
        case .upMirrored: orientation = 2
        case .down: orientation = 3
        case .downMirrored: orientation = 4
        case .leftMirrored: orientation = 5
        case .right: orientation = 6
        case .rightMirrored: orientation = 7
        case .left: orientation = 8
        @unknown default: orientation = 1
        }
        return originNormalized(raw.oriented(forExifOrientation: orientation))
    }

    private nonisolated static func originNormalized(_ image: CIImage) -> CIImage {
        image.transformed(by: CGAffineTransform(translationX: -image.extent.minX, y: -image.extent.minY))
    }

    private nonisolated static func corners(_ rect: CGRect) -> [CGPoint] {
        [CGPoint(x: rect.minX, y: rect.maxY), CGPoint(x: rect.maxX, y: rect.maxY),
            CGPoint(x: rect.maxX, y: rect.minY), CGPoint(x: rect.minX, y: rect.minY)]
    }

    private nonisolated static func interiorRect(in quad: [CGPoint], size: CGSize) -> CGRect {
        let center = CGPoint(x: quad.map(\.x).reduce(0, +) / 4, y: quad.map(\.y).reduce(0, +) / 4)
        func rectangle(_ scale: CGFloat) -> CGRect {
            CGRect(x: center.x - size.width * scale / 2, y: center.y - size.height * scale / 2,
                width: size.width * scale, height: size.height * scale)
        }
        func contains(_ point: CGPoint) -> Bool {
            let products = quad.indices.map { index -> CGFloat in
                let a = quad[index], b = quad[(index + 1) % quad.count]
                return (b.x - a.x) * (point.y - a.y) - (b.y - a.y) * (point.x - a.x)
            }
            return products.allSatisfy { $0 >= -0.000_001 } || products.allSatisfy { $0 <= 0.000_001 }
        }
        // Find the largest centered, same-aspect viewport inside the transformed image, avoiding empty corners.
        var lower: CGFloat = 0, upper: CGFloat = 1
        for _ in 0..<24 {
            let middle = (lower + upper) / 2
            if corners(rectangle(middle)).allSatisfy(contains) { lower = middle } else { upper = middle }
        }
        let rect = rectangle(lower)
        return CGRect(x: ceil(rect.minX), y: ceil(rect.minY), width: floor(rect.maxX) - ceil(rect.minX),
            height: floor(rect.maxY) - ceil(rect.minY))
    }
}
