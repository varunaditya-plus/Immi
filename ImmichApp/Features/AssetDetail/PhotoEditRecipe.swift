import CoreGraphics
import Foundation
import Observation

enum PhotoEditorTool: String, CaseIterable, Identifiable, Sendable {
    case adjust, filters, crop
    var id: Self { self }
    var title: String {
        switch self {
        case .adjust: String(localized: "Adjust")
        case .filters: String(localized: "Filters")
        case .crop: String(localized: "Crop")
        }
    }
    var symbol: String {
        switch self {
        case .adjust: "dial.low.fill"
        case .filters: "camera.filters"
        case .crop: "crop.rotate"
        }
    }
}

enum PhotoAdjustment: String, Codable, CaseIterable, Identifiable, Sendable {
    case auto, exposure, brilliance, highlights, shadows, contrast, brightness, blackPoint
    case saturation, vibrance, warmth, tint, sharpness, definition, noiseReduction, vignette
    var id: Self { self }
    var range: ClosedRange<Double> {
        switch self {
        case .auto, .sharpness, .definition, .noiseReduction, .vignette: 0...1
        default: -1...1
        }
    }
    var title: String {
        switch self {
        case .auto: String(localized: "Auto")
        case .exposure: String(localized: "Exposure")
        case .brilliance: String(localized: "Brilliance")
        case .highlights: String(localized: "Highlights")
        case .shadows: String(localized: "Shadows")
        case .contrast: String(localized: "Contrast")
        case .brightness: String(localized: "Brightness")
        case .blackPoint: String(localized: "Black Point")
        case .saturation: String(localized: "Saturation")
        case .vibrance: String(localized: "Vibrance")
        case .warmth: String(localized: "Warmth")
        case .tint: String(localized: "Tint")
        case .sharpness: String(localized: "Sharpness")
        case .definition: String(localized: "Definition")
        case .noiseReduction: String(localized: "Noise Reduction")
        case .vignette: String(localized: "Vignette")
        }
    }
    var symbol: String {
        switch self {
        case .auto: "wand.and.stars.inverse"
        case .exposure: "plusminus.circle"
        case .brilliance: "swirl.circle.righthalf.filled"
        case .highlights: "circle.lefthalf.striped.horizontal.inverse"
        case .shadows: "circle.lefthalf.filled.righthalf.striped.horizontal.inverse"
        case .contrast: "circle.righthalf.filled"
        case .brightness: "sun.min.fill"
        case .blackPoint: "circle.fill"
        case .saturation: "circle.fill"
        case .vibrance: "lightspectrum.horizontal"
        case .warmth: "thermometer.medium"
        case .tint: "drop.halffull"
        case .sharpness: "righttriangle.fill"
        case .definition: "righttriangle.split.diagonal"
        case .noiseReduction: "circle.bottomrighthalf.pattern.checkered"
        case .vignette: "circle.dotted.circle"
        }
    }
}

enum PhotoEditFilter: String, Codable, CaseIterable, Identifiable, Sendable {
    case original, vivid, vividWarm, vividCool, dramatic, dramaticWarm, dramaticCool, mono, silvertone, noir
    var id: Self { self }
    var title: String {
        switch self {
        case .original: String(localized: "Original")
        case .vivid: String(localized: "Vivid")
        case .vividWarm: String(localized: "Vivid Warm")
        case .vividCool: String(localized: "Vivid Cool")
        case .dramatic: String(localized: "Dramatic")
        case .dramaticWarm: String(localized: "Dramatic Warm")
        case .dramaticCool: String(localized: "Dramatic Cool")
        case .mono: String(localized: "Mono")
        case .silvertone: String(localized: "Silvertone")
        case .noir: String(localized: "Noir")
        }
    }
}

struct PhotoEditRecipe: Codable, Equatable, Sendable {
    var crop = CGRect(x: 0, y: 0, width: 1, height: 1)
    var framing = CGRect(x: 0, y: 0, width: 1, height: 1)
    var cropAspectRatio: Double? = 0
    var quarterTurns = 0
    var flipHorizontal = false
    var flipVertical = false
    var straighten: Double = 0
    var perspectiveVertical: Double = 0
    var perspectiveHorizontal: Double = 0
    var adjustments: [PhotoAdjustment: Double] = [:]
    var filter = PhotoEditFilter.original
    var filterIntensity: Double = 1

    init() {}

    subscript(_ adjustment: PhotoAdjustment) -> Double {
        get { adjustments[adjustment] ?? 0 }
        set {
            let value = Self.bounded(newValue, to: adjustment.range)
            adjustments[adjustment] = value == 0 ? nil : value
        }
    }

    var isIdentity: Bool {
        var value = normalized()
        value.cropAspectRatio = 0
        if value.filterIntensity == 0 { value.filter = .original; value.filterIntensity = 1 }
        return value == PhotoEditRecipe()
    }

    func normalized() -> Self {
        var result = self
        result.crop = Self.unitRect(crop)
        result.framing = Self.unitRect(framing)
        if let cropAspectRatio { result.cropAspectRatio = cropAspectRatio.isFinite && cropAspectRatio >= 0 ? cropAspectRatio : 0 }
        result.quarterTurns = ((quarterTurns % 4) + 4) % 4
        result.straighten = Self.bounded(straighten, to: -45...45)
        result.perspectiveVertical = Self.bounded(perspectiveVertical, to: -1...1)
        result.perspectiveHorizontal = Self.bounded(perspectiveHorizontal, to: -1...1)
        result.filterIntensity = Self.bounded(filterIntensity, to: 0...1)
        result.adjustments = [:]
        for (key, value) in adjustments { result[key] = value }
        if filter == .original { result.filterIntensity = 1 }
        return result
    }

    mutating func resetGeometry() {
        crop = CGRect(x: 0, y: 0, width: 1, height: 1)
        framing = crop
        cropAspectRatio = 0
        quarterTurns = 0
        flipHorizontal = false
        flipVertical = false
        straighten = 0
        perspectiveVertical = 0
        perspectiveHorizontal = 0
    }

    init(serverEdits: [AssetEditRecord], originalPixelSize: CGSize) {
        self.init()
        var matrix = PhotoEditMatrix.identity
        for edit in serverEdits {
            switch edit.action {
            case "crop":
                if let x = edit.parameters.x, let y = edit.parameters.y,
                   let width = edit.parameters.width, let height = edit.parameters.height,
                   originalPixelSize.width.isFinite, originalPixelSize.height.isFinite,
                   originalPixelSize.width > 0, originalPixelSize.height > 0 {
                    crop = Self.unitRect(CGRect(x: CGFloat(x) / originalPixelSize.width,
                        y: CGFloat(y) / originalPixelSize.height, width: CGFloat(width) / originalPixelSize.width,
                        height: CGFloat(height) / originalPixelSize.height))
                }
            case "rotate":
                if let angle = edit.parameters.angle, angle.isFinite, [0, 90, 180, 270].contains(angle) {
                    matrix = matrix * PhotoEditMatrix.rotation(Int(angle / 90))
                }
            case "mirror":
                // Immich names the axis of reflection: horizontal reflects Y, vertical reflects X.
                if edit.parameters.axis == "horizontal" { matrix = matrix * .verticalFlip }
                else if edit.parameters.axis == "vertical" { matrix = matrix * .horizontalFlip }
            default: break
            }
        }
        let candidates = (0..<4).flatMap { turns in
            [(turns, false, false), (turns, true, false), (turns, false, true), (turns, true, true)]
        }.sorted { ($0.1 ? 1 : 0) + ($0.2 ? 1 : 0) < ($1.1 ? 1 : 0) + ($1.2 ? 1 : 0) }
        if let match = candidates.first(where: {
            PhotoEditMatrix.rotation($0.0) * ($0.2 ? .verticalFlip : .identity)
                * ($0.1 ? .horizontalFlip : .identity) == matrix
        }) {
            quarterTurns = match.0
            flipHorizontal = match.1
            flipVertical = match.2
        }
    }

    private static func unitRect(_ value: CGRect) -> CGRect {
        guard [value.minX, value.minY, value.width, value.height].allSatisfy(\.isFinite),
              value.width > 0, value.height > 0 else { return CGRect(x: 0, y: 0, width: 1, height: 1) }
        let x = min(max(0, value.minX), 1 - 0.000_001)
        let y = min(max(0, value.minY), 1 - 0.000_001)
        return CGRect(x: x, y: y, width: min(max(0.000_001, value.width), 1 - x),
            height: min(max(0.000_001, value.height), 1 - y))
    }

    private static func bounded(_ value: Double, to range: ClosedRange<Double>) -> Double {
        value.isFinite ? min(max(value, range.lowerBound), range.upperBound) : 0
    }
}

private struct PhotoEditMatrix: Equatable {
    let a: Int, b: Int, c: Int, d: Int
    static let identity = Self(a: 1, b: 0, c: 0, d: 1)
    static let horizontalFlip = Self(a: -1, b: 0, c: 0, d: 1)
    static let verticalFlip = Self(a: 1, b: 0, c: 0, d: -1)
    static func rotation(_ turns: Int) -> Self {
        switch ((turns % 4) + 4) % 4 {
        case 1: Self(a: 0, b: 1, c: -1, d: 0)
        case 2: Self(a: -1, b: 0, c: 0, d: -1)
        case 3: Self(a: 0, b: -1, c: 1, d: 0)
        default: .identity
        }
    }
    static func * (lhs: Self, rhs: Self) -> Self {
        Self(a: lhs.a * rhs.a + lhs.b * rhs.c, b: lhs.a * rhs.b + lhs.b * rhs.d,
            c: lhs.c * rhs.a + lhs.d * rhs.c, d: lhs.c * rhs.b + lhs.d * rhs.d)
    }
}

@MainActor
@Observable
final class PhotoEditHistory {
    private(set) var recipe: PhotoEditRecipe
    let initialRecipe: PhotoEditRecipe
    private var states: [PhotoEditRecipe]
    private var cursor = 0
    private(set) var isEditing = false
    var canUndo: Bool { cursor > 0 }
    var canRedo: Bool { cursor + 1 < states.count }
    var isDirty: Bool { recipe != initialRecipe }

    init(recipe: PhotoEditRecipe) {
        initialRecipe = recipe.normalized()
        self.recipe = initialRecipe
        states = [initialRecipe]
    }

    func update(_ value: PhotoEditRecipe) {
        recipe = value.normalized()
        if !isEditing { commit() }
    }
    func editingChanged(_ editing: Bool) {
        isEditing = editing
        if !editing { commit() }
    }
    func undo() {
        editingChanged(false)
        guard canUndo else { return }
        cursor -= 1
        recipe = states[cursor]
    }
    func redo() {
        editingChanged(false)
        guard canRedo else { return }
        cursor += 1
        recipe = states[cursor]
    }
    private func commit() {
        guard states[cursor] != recipe else { return }
        states.removeSubrange((cursor + 1)..<states.count)
        states.append(recipe)
        cursor = states.count - 1
    }
}
