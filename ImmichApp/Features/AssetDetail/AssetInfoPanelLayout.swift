import CoreGraphics

struct AssetInfoPanelLayout {
    let viewportHeight: CGFloat
    let contentHeight: CGFloat

    var mediumHeight: CGFloat { max(0, viewportHeight) * 0.55 }

    var maximumHeight: CGFloat {
        let ceiling = max(0, viewportHeight) * 0.75
        guard contentHeight > 0 else { return ceiling }
        return min(ceiling, max(mediumHeight, contentHeight))
    }

    var detents: [CGFloat] {
        var heights: [CGFloat] = [0, mediumHeight]
        if maximumHeight > mediumHeight + 24 { heights.append(maximumHeight) }
        return heights
    }

    func resizedHeight(_ height: CGFloat, from previous: Self) -> CGFloat {
        guard height > 0 else { return 0 }
        if abs(height - previous.mediumHeight) <= 1 { return mediumHeight }
        if abs(height - previous.maximumHeight) <= 1 { return maximumHeight }
        return min(height, maximumHeight)
    }
}
