import SwiftUI
import UIKit

/// Preset crop yang diminta layar detail. Angka disimpan dalam orientasi
/// portrait; tombol orientation menukarnya untuk mode wide.
private enum PhotoCropPreset: String, CaseIterable, Identifiable {
    case original = "Original"
    case freeform = "Freeform"
    case square = "Square"
    case nineSixteen = "9:16"
    case fourFive = "4:5"
    case fiveSeven = "5:7"
    case threeFour = "3:4"
    case threeFive = "3:5"
    case twoThree = "2:3"

    var id: String { rawValue }

    var numbers: (first: Int, second: Int)? {
        switch self {
        case .nineSixteen: (9, 16)
        case .fourFive: (4, 5)
        case .fiveSeven: (5, 7)
        case .threeFour: (3, 4)
        case .threeFive: (3, 5)
        case .twoThree: (2, 3)
        case .original, .freeform, .square: nil
        }
    }

    var portraitRatio: CGFloat? {
        if self == .square { return 1 }
        guard let numbers else { return nil }
        return CGFloat(numbers.first) / CGFloat(numbers.second)
    }

    func label(isWide: Bool) -> String {
        guard let numbers else { return rawValue }
        return isWide
            ? "\(numbers.second):\(numbers.first)"
            : "\(numbers.first):\(numbers.second)"
    }
}

/// Editor non-destruktif: hasil akhirnya dikirim sebagai daftar operasi ke
/// server, bukan dirender ulang menjadi JPEG di perangkat.
struct PhotoCropEditor: View {
    let assetID: String
    let originalPixelSize: CGSize
    let existingEdits: [AssetEditRecord]
    let onSave: ([AssetEditCommand]) async -> Bool

    @Environment(SessionManager.self) private var session
    @Environment(\.dismiss) private var dismiss

    @State private var image: UIImage?
    @State private var crop = CGRect(x: 0, y: 0, width: 1, height: 1)
    @State private var preset: PhotoCropPreset = .original
    @State private var isWide = false
    @State private var quarterTurns = 0
    @State private var visualQuarterTurns = 0
    @State private var flipHorizontal = false
    @State private var flipVertical = false
    @State private var isSaving = false
    @State private var loadFailed = false
    @State private var didInitialize = false
    @Namespace private var orientationIndicator

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                editorCanvas
                transformControls
                ratioPicker
            }
            .background(.black)
            .navigationTitle("Edit")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.black, for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .disabled(isSaving || image == nil)
                }
            }
            .overlay {
                if isSaving {
                    ZStack {
                        Color.black.opacity(0.45).ignoresSafeArea()
                        ProgressView("Applying edits…")
                            .padding(20)
                            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
                    }
                }
            }
            .task {
                initializeExistingEditsIfNeeded()
                await loadImage()
            }
        }
        .environment(\.colorScheme, .dark)
    }

    @ViewBuilder
    private var editorCanvas: some View {
        GeometryReader { geometry in
            if let image {
                let available = geometry.size
                let originalAspect = image.size.width / max(1, image.size.height)
                let rotatedAspect = quarterTurns.isMultiple(of: 2)
                    ? originalAspect : 1 / originalAspect
                let display = fittedSize(aspect: rotatedAspect, in: available)
                let base = quarterTurns.isMultiple(of: 2)
                    ? display : CGSize(width: display.height, height: display.width)

                ZStack {
                    Image(uiImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: base.width, height: base.height)
                        .scaleEffect(x: flipHorizontal ? -1 : 1, y: flipVertical ? -1 : 1)
                        .rotationEffect(.degrees(Double(visualQuarterTurns * 90)))
                        .frame(width: display.width, height: display.height)
                        .clipped()

                    CropOverlay(
                        crop: $crop,
                        fixedPhysicalRatio: selectedRatio,
                        displayAspect: rotatedAspect)
                }
                .frame(width: display.width, height: display.height)
                .position(x: available.width / 2, y: available.height / 2)
                .animation(.smooth(duration: 0.3), value: visualQuarterTurns)
            } else if loadFailed {
                ContentUnavailableView(
                    "Photo Unavailable",
                    systemImage: "photo.badge.exclamationmark",
                    description: Text("The photo could not be loaded for editing."))
                    .foregroundStyle(.white)
            } else {
                ProgressView("Loading photo…")
                    .tint(.white)
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(maxHeight: .infinity)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var transformControls: some View {
        HStack(spacing: 30) {
            transformButton("rotate.left", label: "Rotate Left") { rotate(-1) }
            transformButton("rotate.right", label: "Rotate Right") { rotate(1) }
            transformButton("arrow.left.and.right.righttriangle.left.righttriangle.right", label: "Flip Horizontal") {
                flipHorizontal.toggle()
            }
            transformButton("arrow.up.and.down.righttriangle.up.righttriangle.down", label: "Flip Vertical") {
                flipVertical.toggle()
            }
            transformButton("arrow.counterclockwise", label: "Reset") { reset() }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .foregroundStyle(.white)
    }

    private func transformButton(
        _ symbol: String,
        label: LocalizedStringKey,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.title3)
                .frame(width: 32, height: 32)
        }
        .accessibilityLabel(label)
    }

    private var ratioPicker: some View {
        VStack(spacing: 14) {
            orientationSelector

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 18) {
                    ForEach(PhotoCropPreset.allCases) { option in
                        Button {
                            selectPreset(option)
                        } label: {
                            Text(option.label(isWide: isWide).uppercased())
                                .font(.callout.weight(.medium))
                                .padding(.horizontal, 14)
                                .padding(.vertical, 7)
                                .background(
                                    preset == option ? Color.white.opacity(0.22) : Color.clear,
                                    in: Capsule())
                                .foregroundStyle(preset == option ? .white : .secondary)
                                .contentTransition(.numericText())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 16)
            }
        }
        .padding(.bottom, 12)
    }

    private var orientationSelector: some View {
        HStack(spacing: 20) {
            orientationButton(isWide: false)
            orientationButton(isWide: true)
        }
        .frame(height: 46)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Crop Orientation")
    }

    private func orientationButton(isWide optionIsWide: Bool) -> some View {
        let selected = isWide == optionIsWide
        let size = optionIsWide
            ? CGSize(width: 42, height: 28)
            : CGSize(width: 28, height: 42)

        return Button {
            setOrientation(wide: optionIsWide)
        } label: {
            ZStack {
                if selected {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(Color.white.opacity(0.3))
                        .matchedGeometryEffect(id: "orientation", in: orientationIndicator)
                }
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .stroke(Color.white.opacity(0.72), lineWidth: 2.5)

                if selected {
                    Image(systemName: "checkmark")
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(.black)
                        .transition(.scale.combined(with: .opacity))
                }
            }
            .frame(width: size.width, height: size.height)
            .frame(width: 52, height: 46)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(optionIsWide ? "Wide" : "Portrait")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private var selectedRatio: CGFloat? {
        ratio(for: preset, wide: isWide)
    }

    private func loadImage() async {
        image = await PhotoPreviewLoader(session: session).originalImageForEditing(assetID)
        loadFailed = image == nil
    }

    private func initializeExistingEditsIfNeeded() {
        guard !didInitialize else { return }
        didInitialize = true

        var originalCrop = CGRect(x: 0, y: 0, width: 1, height: 1)

        for edit in existingEdits {
            switch edit.action {
            case "crop":
                guard let x = edit.parameters.x,
                      let y = edit.parameters.y,
                      let width = edit.parameters.width,
                      let height = edit.parameters.height,
                      originalPixelSize.width > 0,
                      originalPixelSize.height > 0 else { continue }
                originalCrop = CGRect(
                    x: CGFloat(x) / originalPixelSize.width,
                    y: CGFloat(y) / originalPixelSize.height,
                    width: CGFloat(width) / originalPixelSize.width,
                    height: CGFloat(height) / originalPixelSize.height)
                preset = .freeform
            case "rotate":
                let angle = Int((edit.parameters.angle ?? 0).rounded())
                quarterTurns = ((angle / 90) % 4 + 4) % 4
            case "mirror":
                if edit.parameters.axis == "horizontal" { flipHorizontal.toggle() }
                if edit.parameters.axis == "vertical" { flipVertical.toggle() }
            default:
                continue
            }
        }

        visualQuarterTurns = quarterTurns
        isWide = rotatedPixelSize.width > rotatedPixelSize.height
        crop = displayRect(fromOriginal: originalCrop, quarterTurns: quarterTurns)
    }

    private func rotate(_ direction: Int) {
        let originalCrop = originalRect(fromDisplay: crop, quarterTurns: quarterTurns)
        let nextTurns = ((quarterTurns + direction) % 4 + 4) % 4
        let nextCrop = displayRect(fromOriginal: originalCrop, quarterTurns: nextTurns)

        withAnimation(.smooth(duration: 0.32)) {
            quarterTurns = nextTurns
            visualQuarterTurns += direction
            isWide.toggle()
            crop = nextCrop
        }
    }

    private func reset() {
        withAnimation(.smooth(duration: 0.32)) {
            crop = CGRect(x: 0, y: 0, width: 1, height: 1)
            preset = .original
            isWide = originalPixelSize.width > originalPixelSize.height
            quarterTurns = 0
            visualQuarterTurns = 0
            flipHorizontal = false
            flipVertical = false
        }
    }

    private func selectPreset(_ option: PhotoCropPreset) {
        let nextCrop = targetCrop(for: option, wide: isWide)
        withAnimation(.smooth(duration: 0.32)) {
            preset = option
            if let nextCrop { crop = nextCrop }
        }
    }

    private func setOrientation(wide: Bool) {
        guard isWide != wide else { return }
        let nextCrop = targetCrop(for: preset, wide: wide)
        withAnimation(.smooth(duration: 0.32)) {
            isWide = wide
            if let nextCrop { crop = nextCrop }
        }
    }

    private func ratio(for option: PhotoCropPreset, wide: Bool) -> CGFloat? {
        if option == .original {
            let natural = originalPixelSize.width / max(1, originalPixelSize.height)
            guard natural > 0 else { return nil }
            let portrait = min(natural, 1 / natural)
            return wide ? 1 / portrait : portrait
        }
        guard let portrait = option.portraitRatio else { return nil }
        return wide ? 1 / portrait : portrait
    }

    private func targetCrop(for option: PhotoCropPreset, wide: Bool) -> CGRect? {
        guard let ratio = ratio(for: option, wide: wide) else { return nil }
        let imageAspect = rotatedPixelSize.width / max(1, rotatedPixelSize.height)
        let normalizedRatio = ratio / imageAspect

        if normalizedRatio >= 1 {
            let height = min(1, 1 / normalizedRatio)
            return CGRect(x: 0, y: (1 - height) / 2, width: 1, height: height)
        }
        let width = min(1, normalizedRatio)
        return CGRect(x: (1 - width) / 2, y: 0, width: width, height: 1)
    }

    private var rotatedPixelSize: CGSize {
        quarterTurns.isMultiple(of: 2)
            ? originalPixelSize
            : CGSize(width: originalPixelSize.height, height: originalPixelSize.width)
    }

    private func save() {
        isSaving = true
        let pixelSize = originalPixelSize
        let normalizedRotation = ((quarterTurns * 90) % 360 + 360) % 360
        let currentCrop = clampedUnitRect(
            originalRect(fromDisplay: crop, quarterTurns: quarterTurns))
        let horizontal = flipHorizontal
        let vertical = flipVertical

        Task {
            var edits: [AssetEditCommand] = []
            let assetWidth = max(1, Int(pixelSize.width.rounded()))
            let assetHeight = max(1, Int(pixelSize.height.rounded()))

            let x = min(assetWidth - 1, max(
                0, Int((currentCrop.minX * CGFloat(assetWidth)).rounded(.down))))
            let y = min(assetHeight - 1, max(
                0, Int((currentCrop.minY * CGFloat(assetHeight)).rounded(.down))))
            let maxX = min(assetWidth, max(
                x + 1, Int((currentCrop.maxX * CGFloat(assetWidth)).rounded(.up))))
            let maxY = min(assetHeight, max(
                y + 1, Int((currentCrop.maxY * CGFloat(assetHeight)).rounded(.up))))
            let width = maxX - x
            let height = maxY - y

            if x > 0 || y > 0 || width < assetWidth || height < assetHeight {
                edits.append(.init(payload: .crop(x: x, y: y, width: width, height: height)))
            }
            if horizontal { edits.append(.init(payload: .mirror(axis: "horizontal"))) }
            if vertical { edits.append(.init(payload: .mirror(axis: "vertical"))) }
            if normalizedRotation != 0 {
                edits.append(.init(payload: .rotate(angle: Double(normalizedRotation))))
            }

            // Daftar kosong berarti reset ke original; view model menerjemahkan
            // itu menjadi DELETE `/edits`, bukan PUT dengan array kosong.
            let succeeded = await onSave(edits)
            isSaving = false
            if succeeded { dismiss() }
        }
    }

    private func clampedUnitRect(_ rect: CGRect) -> CGRect {
        let standardized = rect.standardized
        let minX = min(1, max(0, standardized.minX))
        let minY = min(1, max(0, standardized.minY))
        let maxX = min(1, max(minX, standardized.maxX))
        let maxY = min(1, max(minY, standardized.maxY))
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    /// Mengubah area crop dari koordinat foto asli ke koordinat yang sedang
    /// dilihat user setelah mirror dan rotate diterapkan.
    private func displayRect(fromOriginal rect: CGRect, quarterTurns: Int) -> CGRect {
        var transformed = rect
        if flipHorizontal { transformed.origin.x = 1 - transformed.maxX }
        if flipVertical { transformed.origin.y = 1 - transformed.maxY }

        switch ((quarterTurns % 4) + 4) % 4 {
        case 1:
            return CGRect(
                x: 1 - transformed.maxY, y: transformed.minX,
                width: transformed.height, height: transformed.width)
        case 2:
            return CGRect(
                x: 1 - transformed.maxX, y: 1 - transformed.maxY,
                width: transformed.width, height: transformed.height)
        case 3:
            return CGRect(
                x: transformed.minY, y: 1 - transformed.maxX,
                width: transformed.height, height: transformed.width)
        default:
            return transformed
        }
    }

    /// Invers dari `displayRect`; server selalu menerima crop dalam koordinat
    /// foto asli sebelum operasi mirror dan rotate.
    private func originalRect(fromDisplay rect: CGRect, quarterTurns: Int) -> CGRect {
        let unrotated: CGRect
        switch ((quarterTurns % 4) + 4) % 4 {
        case 1:
            unrotated = CGRect(
                x: rect.minY, y: 1 - rect.maxX,
                width: rect.height, height: rect.width)
        case 2:
            unrotated = CGRect(
                x: 1 - rect.maxX, y: 1 - rect.maxY,
                width: rect.width, height: rect.height)
        case 3:
            unrotated = CGRect(
                x: 1 - rect.maxY, y: rect.minX,
                width: rect.height, height: rect.width)
        default:
            unrotated = rect
        }

        var original = unrotated
        if flipHorizontal { original.origin.x = 1 - original.maxX }
        if flipVertical { original.origin.y = 1 - original.maxY }
        return original
    }

    private func fittedSize(aspect: CGFloat, in available: CGSize) -> CGSize {
        guard aspect > 0, available.width > 0, available.height > 0 else { return .zero }
        let availableAspect = available.width / available.height
        if aspect > availableAspect {
            return CGSize(width: available.width, height: available.width / aspect)
        }
        return CGSize(width: available.height * aspect, height: available.height)
    }
}

private enum CropHandle: CaseIterable {
    case topLeft, top, topRight, right, bottomRight, bottom, bottomLeft, left
}

private typealias CropRectAnimationData = AnimatablePair<
    AnimatablePair<CGFloat, CGFloat>,
    AnimatablePair<CGFloat, CGFloat>
>

/// Mask dan grid harus mengekspos CGRect sebagai animatable data. Membuat
/// `Path` baru langsung di body menyebabkan SwiftUI menggantinya sekaligus,
/// sehingga frame terlihat jumping walaupun perubahan state memakai animasi.
private struct CropMaskShape: Shape {
    var cropFrame: CGRect

    var animatableData: CropRectAnimationData {
        get {
            .init(
                .init(cropFrame.minX, cropFrame.minY),
                .init(cropFrame.width, cropFrame.height))
        }
        set {
            cropFrame = CGRect(
                x: newValue.first.first,
                y: newValue.first.second,
                width: newValue.second.first,
                height: newValue.second.second)
        }
    }

    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.addRect(rect)
        path.addRect(cropFrame)
        return path
    }
}

private struct CropGridShape: Shape {
    var cropFrame: CGRect

    var animatableData: CropRectAnimationData {
        get {
            .init(
                .init(cropFrame.minX, cropFrame.minY),
                .init(cropFrame.width, cropFrame.height))
        }
        set {
            cropFrame = CGRect(
                x: newValue.first.first,
                y: newValue.first.second,
                width: newValue.second.first,
                height: newValue.second.second)
        }
    }

    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.addRect(cropFrame)
        for index in 1...2 {
            let x = cropFrame.minX + cropFrame.width * CGFloat(index) / 3
            let y = cropFrame.minY + cropFrame.height * CGFloat(index) / 3
            path.move(to: CGPoint(x: x, y: cropFrame.minY))
            path.addLine(to: CGPoint(x: x, y: cropFrame.maxY))
            path.move(to: CGPoint(x: cropFrame.minX, y: y))
            path.addLine(to: CGPoint(x: cropFrame.maxX, y: y))
        }
        return path
    }
}

/// Overlay crop dengan delapan handle: empat sudut dan empat sisi.
private struct CropOverlay: View {
    @Binding var crop: CGRect
    let fixedPhysicalRatio: CGFloat?
    let displayAspect: CGFloat

    @State private var dragStart: CGRect?
    private let minimum: CGFloat = 0.06

    var body: some View {
        GeometryReader { geometry in
            let bounds = CGRect(origin: .zero, size: geometry.size)
            let frame = denormalized(crop, in: bounds)

            CropMaskShape(cropFrame: frame)
            .fill(.black.opacity(0.55), style: FillStyle(eoFill: true))
            .allowsHitTesting(false)

            Rectangle()
                .fill(.clear)
                .contentShape(Rectangle())
                .frame(width: frame.width, height: frame.height)
                .position(x: frame.midX, y: frame.midY)
                .gesture(moveGesture(size: bounds.size))

            grid(in: frame)
            ForEach(Array(CropHandle.allCases.enumerated()), id: \.offset) { _, handle in
                handleView(handle, frame: frame, canvasSize: bounds.size)
            }
        }
        .coordinateSpace(name: "cropCanvas")
        .animation(.smooth(duration: 0.3), value: crop)
    }

    private func grid(in frame: CGRect) -> some View {
        CropGridShape(cropFrame: frame)
        .stroke(.white.opacity(0.85), lineWidth: 1)
        .allowsHitTesting(false)
    }

    private func handleView(
        _ handle: CropHandle, frame: CGRect, canvasSize: CGSize
    ) -> some View {
        ZStack {
            Circle()
                .fill(.white)
                .frame(width: 16, height: 16)
                .shadow(color: .black.opacity(0.5), radius: 2)
        }
            .frame(width: 44, height: 44)
            .contentShape(Rectangle())
            .position(position(of: handle, in: frame))
            .highPriorityGesture(resizeGesture(handle, size: canvasSize))
    }

    private func moveGesture(size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .named("cropCanvas"))
            .onChanged { value in
                let start = dragStart ?? crop
                if dragStart == nil { dragStart = start }
                let dx = value.translation.width / max(1, size.width)
                let dy = value.translation.height / max(1, size.height)
                var moved = start
                moved.origin.x = min(max(0, start.origin.x + dx), 1 - start.width)
                moved.origin.y = min(max(0, start.origin.y + dy), 1 - start.height)
                updateCropDuringGesture(moved)
            }
            .onEnded { _ in dragStart = nil }
    }

    private func resizeGesture(_ handle: CropHandle, size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .named("cropCanvas"))
            .onChanged { value in
                let start = dragStart ?? crop
                if dragStart == nil { dragStart = start }
                let dx = value.translation.width / max(1, size.width)
                let dy = value.translation.height / max(1, size.height)
                updateCropDuringGesture(resized(start, handle: handle, dx: dx, dy: dy))
            }
            .onEnded { _ in dragStart = nil }
    }

    /// Gesture harus mengikuti posisi jari 1:1. Animasi hanya digunakan untuk
    /// pergantian preset/orientation, bukan pada setiap update drag.
    private func updateCropDuringGesture(_ newCrop: CGRect) {
        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            crop = newCrop
        }
    }

    private func resized(
        _ start: CGRect, handle: CropHandle, dx: CGFloat, dy: CGFloat
    ) -> CGRect {
        guard let fixedPhysicalRatio, displayAspect > 0 else {
            return freeformResized(start, handle: handle, dx: dx, dy: dy)
        }

        let ratio = fixedPhysicalRatio / displayAspect
        guard ratio > 0 else { return start }

        switch handle {
        case .topLeft:
            return cornerResized(
                start, anchor: CGPoint(x: start.maxX, y: start.maxY),
                moving: CGPoint(x: start.minX + dx, y: start.minY + dy),
                xDirection: -1, yDirection: -1, ratio: ratio)
        case .topRight:
            return cornerResized(
                start, anchor: CGPoint(x: start.minX, y: start.maxY),
                moving: CGPoint(x: start.maxX + dx, y: start.minY + dy),
                xDirection: 1, yDirection: -1, ratio: ratio)
        case .bottomRight:
            return cornerResized(
                start, anchor: CGPoint(x: start.minX, y: start.minY),
                moving: CGPoint(x: start.maxX + dx, y: start.maxY + dy),
                xDirection: 1, yDirection: 1, ratio: ratio)
        case .bottomLeft:
            return cornerResized(
                start, anchor: CGPoint(x: start.maxX, y: start.minY),
                moving: CGPoint(x: start.minX + dx, y: start.maxY + dy),
                xDirection: -1, yDirection: 1, ratio: ratio)
        case .left:
            return horizontalResized(
                start, anchorX: start.maxX, movingX: start.minX + dx,
                direction: -1, ratio: ratio)
        case .right:
            return horizontalResized(
                start, anchorX: start.minX, movingX: start.maxX + dx,
                direction: 1, ratio: ratio)
        case .top:
            return verticalResized(
                start, anchorY: start.maxY, movingY: start.minY + dy,
                direction: -1, ratio: ratio)
        case .bottom:
            return verticalResized(
                start, anchorY: start.minY, movingY: start.maxY + dy,
                direction: 1, ratio: ratio)
        }
    }

    private func freeformResized(
        _ start: CGRect, handle: CropHandle, dx: CGFloat, dy: CGFloat
    ) -> CGRect {
        var left = start.minX
        var right = start.maxX
        var top = start.minY
        var bottom = start.maxY

        if [.topLeft, .left, .bottomLeft].contains(handle) { left += dx }
        if [.topRight, .right, .bottomRight].contains(handle) { right += dx }
        if [.topLeft, .top, .topRight].contains(handle) { top += dy }
        if [.bottomLeft, .bottom, .bottomRight].contains(handle) { bottom += dy }

        left = min(max(0, left), right - minimum)
        right = max(min(1, right), left + minimum)
        top = min(max(0, top), bottom - minimum)
        bottom = max(min(1, bottom), top + minimum)

        return CGRect(x: left, y: top, width: right - left, height: bottom - top)
    }

    private func cornerResized(
        _ start: CGRect,
        anchor: CGPoint,
        moving: CGPoint,
        xDirection: CGFloat,
        yDirection: CGFloat,
        ratio: CGFloat
    ) -> CGRect {
        let horizontalDistance = max(0, xDirection * (moving.x - anchor.x))
        let verticalDistance = max(0, yDirection * (moving.y - anchor.y))

        // Proyeksikan gerakan jari ke garis dengan aspect ratio tetap. Kedua
        // sumbu ikut berpengaruh sehingga handle sudut tidak melompat.
        let projectedHeight = (
            ratio * horizontalDistance + verticalDistance
        ) / (ratio * ratio + 1)
        let minimumHeight = max(minimum, minimum / ratio)
        let maximumWidth = xDirection > 0 ? 1 - anchor.x : anchor.x
        let maximumHeight = yDirection > 0 ? 1 - anchor.y : anchor.y
        let allowedHeight = max(0, min(maximumHeight, maximumWidth / ratio))
        let height = min(max(projectedHeight, minimumHeight), allowedHeight)
        let width = height * ratio

        return CGRect(
            x: xDirection > 0 ? anchor.x : anchor.x - width,
            y: yDirection > 0 ? anchor.y : anchor.y - height,
            width: width,
            height: height)
    }

    private func horizontalResized(
        _ start: CGRect,
        anchorX: CGFloat,
        movingX: CGFloat,
        direction: CGFloat,
        ratio: CGFloat
    ) -> CGRect {
        let requestedWidth = max(0, direction * (movingX - anchorX))
        let centerY = start.midY
        let maximumWidthAtEdge = direction > 0 ? 1 - anchorX : anchorX
        let maximumHeightAroundCenter = 2 * min(centerY, 1 - centerY)
        let allowedWidth = max(0, min(maximumWidthAtEdge, maximumHeightAroundCenter * ratio))
        let minimumWidth = max(minimum, minimum * ratio)
        let width = min(max(requestedWidth, minimumWidth), allowedWidth)
        let height = width / ratio

        return CGRect(
            x: direction > 0 ? anchorX : anchorX - width,
            y: centerY - height / 2,
            width: width,
            height: height)
    }

    private func verticalResized(
        _ start: CGRect,
        anchorY: CGFloat,
        movingY: CGFloat,
        direction: CGFloat,
        ratio: CGFloat
    ) -> CGRect {
        let requestedHeight = max(0, direction * (movingY - anchorY))
        let centerX = start.midX
        let maximumHeightAtEdge = direction > 0 ? 1 - anchorY : anchorY
        let maximumWidthAroundCenter = 2 * min(centerX, 1 - centerX)
        let allowedHeight = max(0, min(maximumHeightAtEdge, maximumWidthAroundCenter / ratio))
        let minimumHeight = max(minimum, minimum / ratio)
        let height = min(max(requestedHeight, minimumHeight), allowedHeight)
        let width = height * ratio

        return CGRect(
            x: centerX - width / 2,
            y: direction > 0 ? anchorY : anchorY - height,
            width: width,
            height: height)
    }

    private func denormalized(_ rect: CGRect, in bounds: CGRect) -> CGRect {
        CGRect(
            x: rect.minX * bounds.width,
            y: rect.minY * bounds.height,
            width: rect.width * bounds.width,
            height: rect.height * bounds.height)
    }

    private func position(of handle: CropHandle, in frame: CGRect) -> CGPoint {
        switch handle {
        case .topLeft: return CGPoint(x: frame.minX, y: frame.minY)
        case .top: return CGPoint(x: frame.midX, y: frame.minY)
        case .topRight: return CGPoint(x: frame.maxX, y: frame.minY)
        case .right: return CGPoint(x: frame.maxX, y: frame.midY)
        case .bottomRight: return CGPoint(x: frame.maxX, y: frame.maxY)
        case .bottom: return CGPoint(x: frame.midX, y: frame.maxY)
        case .bottomLeft: return CGPoint(x: frame.minX, y: frame.maxY)
        case .left: return CGPoint(x: frame.minX, y: frame.midY)
        }
    }
}
