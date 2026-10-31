import SwiftUI
import UIKit

struct PhotoEditCanvas: View {
    let image: UIImage
    @Binding var recipe: PhotoEditRecipe
    let tool: PhotoEditorTool
    let comparing: Bool
    var onEditingChanged: (Bool) -> Void = { _ in }
    @State private var rendered: UIImage?
    @State private var internalCompare = false
    @State private var renderFailed = false
    @State private var revision = UUID()

    private var shownRecipe: PhotoEditRecipe {
        if comparing || internalCompare { return PhotoEditRecipe() }
        var result = recipe
        result.cropAspectRatio = 0
        if tool == .crop { result.framing = CGRect(x: 0, y: 0, width: 1, height: 1) }
        return result
    }
    private var framing: Binding<CGRect> {
        Binding(get: { recipe.framing }, set: { recipe.framing = $0 })
    }

    var body: some View {
        GeometryReader { geometry in
            if let rendered {
                let aspect = rendered.size.width / max(1, rendered.size.height)
                let size = PhotoEditLayout.fittedSize(aspect: aspect, in: geometry.size)
                ZStack {
                    Image(uiImage: rendered).resizable().scaledToFit()
                    if tool == .crop, !comparing, !internalCompare {
                        CropOverlay(crop: framing,
                            fixedPhysicalRatio: recipe.cropAspectRatio.map { $0 == 0 ? aspect : CGFloat($0) },
                            displayAspect: aspect, onEditingChanged: onEditingChanged)
                    }
                    if comparing || internalCompare {
                        Text("Original").font(.caption.weight(.semibold)).foregroundStyle(.white).padding(8)
                            .background(.black.opacity(0.65), in: Capsule())
                            .frame(maxHeight: .infinity, alignment: .top).padding(12)
                    }
                }
                .frame(width: size.width, height: size.height)
                .position(x: geometry.size.width / 2, y: geometry.size.height / 2)
                .contentShape(Rectangle())
                .simultaneousGesture(TapGesture().onEnded { if tool != .crop { internalCompare.toggle() } })
                .accessibilityLabel(comparing || internalCompare ? "Original Photo" : "Edited Photo")
                .accessibilityAddTraits(.isImage)
                .accessibilityAction { internalCompare.toggle() }
                .accessibilityHint("Double-tap to compare with the original.")
            } else if renderFailed {
                ContentUnavailableView {
                    Label("Preview Unavailable", systemImage: "photo.badge.exclamationmark")
                } actions: { Button("Retry") { revision = UUID() } }
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .frame(maxHeight: .infinity)
        .task(id: PreviewKey(image: ObjectIdentifier(image), recipe: shownRecipe, revision: revision)) {
            let value = shownRecipe
            do {
                let next = try await PhotoEditRenderer.shared.renderPreview(image, recipe: value)
                guard !Task.isCancelled else { return }
                rendered = next
                renderFailed = false
            } catch {
                guard !Task.isCancelled else { return }
                renderFailed = true
                rendered = nil
            }
        }
        .onChange(of: recipe) { _, _ in internalCompare = false }
        .onChange(of: tool) { _, _ in internalCompare = false }
    }

    private struct PreviewKey: Equatable {
        let image: ObjectIdentifier
        let recipe: PhotoEditRecipe
        let revision: UUID
    }
}

struct PhotoEditToolControls: View {
    let image: UIImage
    @Binding var recipe: PhotoEditRecipe
    let tool: PhotoEditorTool
    var onEditingChanged: (Bool) -> Void
    @State private var adjustment = PhotoAdjustment.auto
    @State private var geometry = PhotoGeometryTool.straighten
    @State private var aspectDrawer = false
    @State private var viewportSize = CGSize.zero

    var body: some View {
        VStack(spacing: 12) {
            switch tool {
            case .adjust: adjustmentControls
            case .filters: filterControls
            case .crop: cropControls
            }
        }
        .padding(.vertical, 10)
        .foregroundStyle(.primary)
        .background(PhotoEditViewportProbe(size: $viewportSize))
    }

    private var adjustmentControls: some View {
        VStack(spacing: 12) {
            valueLabel(adjustment.title, value: recipe[adjustment])
            ScrollViewReader { proxy in
                GeometryReader { geometry in
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 18) {
                            ForEach(PhotoAdjustment.allCases) { option in
                                Button {
                                    onEditingChanged(false)
                                    adjustment = option
                                    if option == .auto { recipe[.auto] = recipe[.auto] == 0 ? 1 : 0 }
                                } label: {
                                    Image(systemName: option.symbol).font(.title2)
                                        .frame(width: 46, height: 46)
                                        .background(adjustment == option ? Color.yellow : Color.clear, in: Circle())
                                        .overlay(Circle().stroke(recipe[option] != 0 ? .yellow : .gray, lineWidth: 2))
                                        .foregroundStyle(adjustment == option ? Color.black : Color.primary)
                                }
                                .id(option)
                                .accessibilityLabel(option.title)
                                .accessibilityValue("\(Int((recipe[option] * 100).rounded()))")
                                .accessibilityAddTraits(adjustment == option ? .isSelected : [])
                            }
                        }
                        .padding(.horizontal, max(0, (geometry.size.width - 46) / 2))
                        .padding(.vertical, 3)
                    }
                    .onAppear { proxy.scrollTo(adjustment, anchor: .center) }
                    .onChange(of: adjustment) { _, value in
                        withAnimation(.snappy(duration: 0.22)) { proxy.scrollTo(value, anchor: .center) }
                    }
                }
                .frame(height: 54)
            }
            PhotoEditRulerSlider(value: Binding(get: { recipe[adjustment] }, set: { recipe[adjustment] = $0 }),
                in: adjustment.range, label: adjustment.title,
                valueText: "\(Int((recipe[adjustment] * 100).rounded()))", onEditingChanged: onEditingChanged)
                .overlay(alignment: .leading) {
                    Button("Reset", systemImage: "arrow.counterclockwise") { recipe[adjustment] = 0 }
                        .frame(width: 44, height: 44).contentShape(.rect)
                        .labelStyle(.iconOnly).disabled(recipe[adjustment] == 0)
                }
                .padding(.horizontal, 24)
        }
        .tint(.yellow)
    }

    private var filterControls: some View {
        VStack(spacing: 12) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    ForEach(PhotoEditFilter.allCases) { option in
                        Button { onEditingChanged(false); recipe.filter = option } label: {
                            VStack(spacing: 6) {
                                PhotoFilterThumbnail(image: image, recipe: recipe, filter: option)
                                    .frame(width: 62, height: 76).clipped()
                                    .overlay(Rectangle().stroke(recipe.filter == option ? .yellow : .clear, lineWidth: 3))
                                Text(option.title).font(.caption2)
                                    .foregroundStyle(recipe.filter == option ? Color.yellow : Color.primary)
                            }
                        }
                        .accessibilityLabel(option.title)
                        .accessibilityAddTraits(recipe.filter == option ? .isSelected : [])
                    }
                }.padding(.horizontal, 16)
            }
            HStack {
                Text("Intensity").font(.caption)
                PhotoEditRulerSlider(value: $recipe.filterIntensity, in: 0...1,
                    label: String(localized: "Filter Intensity"), valueText: "\(Int((recipe.filterIntensity * 100).rounded()))",
                    onEditingChanged: onEditingChanged)
                    .disabled(recipe.filter == .original)
                Text("\(Int((recipe.filterIntensity * 100).rounded()))").font(.caption.monospacedDigit())
                    .frame(width: 28)
            }.padding(.horizontal, 24)
        }
        .tint(.yellow)
    }

    private var cropControls: some View {
        VStack(spacing: 12) {
            HStack(spacing: 30) {
                Button("Flip", systemImage: "arrow.left.and.right.righttriangle.left.righttriangle.right") {
                    onEditingChanged(true)
                    defer { onEditingChanged(false) }
                    if recipe.quarterTurns.isMultiple(of: 2) { recipe.flipHorizontal.toggle() }
                    else { recipe.flipVertical.toggle() }
                    recipe.framing.origin.x = 1 - recipe.framing.maxX
                }
                Button("Rotate Left", systemImage: "rotate.left") {
                    onEditingChanged(true)
                    defer { onEditingChanged(false) }
                    let frame = recipe.framing
                    recipe.quarterTurns = (recipe.quarterTurns + 3) % 4
                    recipe.framing = CGRect(x: frame.minY, y: 1 - frame.maxX, width: frame.height, height: frame.width)
                    if let ratio = recipe.cropAspectRatio, ratio > 0 { recipe.cropAspectRatio = 1 / ratio }
                }
                Button("Aspect Ratio", systemImage: "aspectratio") { aspectDrawer.toggle() }
                Button(recipe.cropAspectRatio == nil ? "Lock Aspect Ratio" : "Unlock Aspect Ratio",
                    systemImage: recipe.cropAspectRatio == nil ? "lock.open" : "lock") {
                    onEditingChanged(false)
                    recipe.cropAspectRatio = recipe.cropAspectRatio == nil
                        ? Double(recipe.framing.width * baseAspect / max(0.000_001, recipe.framing.height)) : nil
                }
                Button("Reset", systemImage: "arrow.counterclockwise") { recipe.resetGeometry() }
            }
            .labelStyle(.iconOnly).font(.title3)
            if aspectDrawer { ratioControls }
            HStack(spacing: 28) {
                ForEach(PhotoGeometryTool.allCases) { option in
                    Button { onEditingChanged(false); geometry = option } label: {
                        VStack(spacing: 5) {
                            Image(systemName: option.symbol).font(.title2)
                            Text(option.title).font(.caption2)
                        }.foregroundStyle(geometry == option ? Color.yellow : Color.primary)
                    }
                    .accessibilityAddTraits(geometry == option ? .isSelected : [])
                }
            }
            HStack {
                Text(geometry.title).font(.caption)
                PhotoEditRulerSlider(value: geometryValue, in: geometry == .straighten ? -45...45 : -1...1,
                    label: geometry.title, valueText: geometry == .straighten ? String(format: "%.1f°", recipe.straighten)
                        : "\(Int((geometryValue.wrappedValue * 100).rounded()))", onEditingChanged: onEditingChanged)
                Text(geometry == .straighten ? String(format: "%.1f°", recipe.straighten)
                    : "\(Int((geometryValue.wrappedValue * 100).rounded()))")
                    .font(.caption.monospacedDigit()).frame(width: 48)
            }.padding(.horizontal, 24)
        }.tint(.yellow)
    }

    private var geometryValue: Binding<Double> {
        switch geometry {
        case .straighten: $recipe.straighten
        case .vertical: $recipe.perspectiveVertical
        case .horizontal: $recipe.perspectiveHorizontal
        }
    }

    private var ratioControls: some View {
        VStack(spacing: 10) {
            HStack(spacing: 28) {
                Button("Portrait", systemImage: "rectangle.portrait") { orientCrop(wide: false) }
                Button("Wide", systemImage: "rectangle") { orientCrop(wide: true) }
            }.labelStyle(.iconOnly)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 22) {
                    ForEach(PhotoCropPreset.allCases) { preset in
                        Button(preset.title.uppercased()) { selectRatio(preset) }
                            .font(.caption.weight(.medium)).frame(minHeight: 44)
                    }
                }.padding(.horizontal, 20)
            }
        }
    }

    private func valueLabel(_ title: String, value: Double) -> some View {
        HStack {
            Text(title.uppercased()).font(.caption.weight(.medium))
            Text("\(Int((value * 100).rounded()))").font(.caption.monospacedDigit())
        }
    }

    private var baseAspect: CGFloat {
        let rotated = [UIImage.Orientation.left, .leftMirrored, .right, .rightMirrored].contains(image.imageOrientation)
        let width = rotated ? image.size.height : image.size.width
        let height = rotated ? image.size.width : image.size.height
        let aspect = width * recipe.crop.width / max(1, height * recipe.crop.height)
        return recipe.quarterTurns.isMultiple(of: 2) ? aspect : 1 / max(0.000_001, aspect)
    }

    private func selectRatio(_ preset: PhotoCropPreset) {
        onEditingChanged(true)
        defer { onEditingChanged(false) }
        if preset == .freeform { recipe.cropAspectRatio = nil; return }
        let ratio: CGFloat
        if preset == .original { ratio = baseAspect; recipe.cropAspectRatio = 0 }
        else {
            let portrait = preset.ratio(viewport: viewportSize)
            let wide = recipe.framing.width * baseAspect > recipe.framing.height
            ratio = wide ? max(portrait, 1 / portrait) : min(portrait, 1 / portrait)
            recipe.cropAspectRatio = Double(ratio)
        }
        recipe.framing = PhotoEditLayout.frame(aspect: ratio, in: baseAspect)
    }

    private func orientCrop(wide: Bool) {
        onEditingChanged(true)
        defer { onEditingChanged(false) }
        let current = recipe.cropAspectRatio.flatMap { $0 == 0 ? Double(baseAspect) : $0 } ?? Double(baseAspect)
        let portrait = min(current, 1 / current)
        let ratio = wide ? 1 / portrait : portrait
        recipe.cropAspectRatio = ratio
        recipe.framing = PhotoEditLayout.frame(aspect: CGFloat(ratio), in: baseAspect)
    }
}

private enum PhotoGeometryTool: CaseIterable, Identifiable {
    case straighten, vertical, horizontal
    var id: Self { self }
    var title: String {
        switch self {
        case .straighten: String(localized: "Straighten")
        case .vertical: String(localized: "Vertical")
        case .horizontal: String(localized: "Horizontal")
        }
    }
    var symbol: String {
        switch self {
        case .straighten: "circle.lefthalf.filled"
        case .vertical: "trapezoid.and.line.vertical"
        case .horizontal: "trapezoid.and.line.horizontal"
        }
    }
}

@MainActor
private enum PhotoCropPreset: String, CaseIterable, Identifiable {
    case original, freeform, square, wallpaper, nineSixteen, fourFive, fiveSeven, threeFour, threeFive, twoThree
    var id: Self { self }
    var title: String {
        switch self {
        case .original: String(localized: "Original")
        case .freeform: String(localized: "Freeform")
        case .square: String(localized: "Square")
        case .wallpaper: String(localized: "Wallpaper")
        case .nineSixteen: "9:16"
        case .fourFive: "4:5"
        case .fiveSeven: "5:7"
        case .threeFour: "3:4"
        case .threeFive: "3:5"
        case .twoThree: "2:3"
        }
    }
    func ratio(viewport: CGSize) -> CGFloat {
        switch self {
        case .original, .freeform, .square: 1
        case .wallpaper: viewport.width / max(1, viewport.height)
        case .nineSixteen: 9 / 16
        case .fourFive: 4 / 5
        case .fiveSeven: 5 / 7
        case .threeFour: 3 / 4
        case .threeFive: 3 / 5
        case .twoThree: 2 / 3
        }
    }
}

private struct PhotoEditViewportProbe: UIViewRepresentable {
    @Binding var size: CGSize

    func makeUIView(context: Context) -> ViewportView { ViewportView() }
    func updateUIView(_ view: ViewportView, context: Context) {
        view.onSize = { size = $0 }
        view.setNeedsLayout()
    }
    static func dismantleUIView(_ view: ViewportView, coordinator: ()) { view.onSize = nil }

    final class ViewportView: UIView {
        var onSize: ((CGSize) -> Void)?
        private var reportedSize = CGSize.zero
        override func didMoveToWindow() { super.didMoveToWindow(); setNeedsLayout() }
        override func layoutSubviews() {
            super.layoutSubviews()
            guard let window, window.bounds.size != reportedSize else { return }
            reportedSize = window.bounds.size
            let value = reportedSize
            DispatchQueue.main.async { [weak self] in self?.onSize?(value) }
        }
    }
}

private struct PhotoFilterThumbnail: View {
    let image: UIImage
    var recipe: PhotoEditRecipe
    let filter: PhotoEditFilter
    @State private var rendered: UIImage?
    private var value: PhotoEditRecipe {
        var copy = recipe
        copy.cropAspectRatio = 0
        copy.filter = filter
        copy.filterIntensity = 1
        return copy
    }
    var body: some View {
        Group {
            if let rendered { Image(uiImage: rendered).resizable().scaledToFill() }
            else { Color.gray.opacity(0.25) }
        }
        .task(id: ThumbnailKey(image: ObjectIdentifier(image), recipe: value)) {
            let result = try? await PhotoEditRenderer.shared.renderPreview(image, recipe: value, maxPixelSize: 160)
            guard !Task.isCancelled else { return }
            rendered = result
        }
    }
    private struct ThumbnailKey: Equatable { let image: ObjectIdentifier; let recipe: PhotoEditRecipe }
}

private enum PhotoEditLayout {
    static func fittedSize(aspect: CGFloat, in available: CGSize) -> CGSize {
        guard aspect > 0, available.width > 0, available.height > 0 else { return .zero }
        return aspect > available.width / available.height
            ? CGSize(width: available.width, height: available.width / aspect)
            : CGSize(width: available.height * aspect, height: available.height)
    }
    static func frame(aspect: CGFloat, in imageAspect: CGFloat) -> CGRect {
        let normalized = aspect / max(0.000_001, imageAspect)
        if normalized >= 1 {
            let height = min(1, 1 / normalized)
            return CGRect(x: 0, y: (1 - height) / 2, width: 1, height: height)
        }
        return CGRect(x: (1 - normalized) / 2, y: 0, width: normalized, height: 1)
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
    var onEditingChanged: (Bool) -> Void = { _ in }

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
                if dragStart == nil { onEditingChanged(true); dragStart = start }
                let dx = value.translation.width / max(1, size.width)
                let dy = value.translation.height / max(1, size.height)
                var moved = start
                moved.origin.x = min(max(0, start.origin.x + dx), 1 - start.width)
                moved.origin.y = min(max(0, start.origin.y + dy), 1 - start.height)
                updateCropDuringGesture(moved)
            }
            .onEnded { _ in dragStart = nil; onEditingChanged(false) }
    }

    private func resizeGesture(_ handle: CropHandle, size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .named("cropCanvas"))
            .onChanged { value in
                let start = dragStart ?? crop
                if dragStart == nil { onEditingChanged(true); dragStart = start }
                let dx = value.translation.width / max(1, size.width)
                let dy = value.translation.height / max(1, size.height)
                updateCropDuringGesture(resized(start, handle: handle, dx: dx, dy: dy))
            }
            .onEnded { _ in dragStart = nil; onEditingChanged(false) }
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

struct PhotoEditorToolPicker: View {
    @Binding private var selected: PhotoEditorTool?
    private let primary: (title: String, symbol: String)?
    var isEnabled: Bool

    init(selected: Binding<PhotoEditorTool>, isEnabled: Bool = true) {
        _selected = Binding<PhotoEditorTool?>(get: { selected.wrappedValue }, set: { if let value = $0 { selected.wrappedValue = value } })
        primary = nil
        self.isEnabled = isEnabled
    }

    init(selected: Binding<PhotoEditorTool?>, primaryTitle: String, primarySymbol: String, isEnabled: Bool = true) {
        _selected = selected
        primary = (primaryTitle, primarySymbol)
        self.isEnabled = isEnabled
    }

    var body: some View {
        HStack(spacing: 0) {
            if let primary { item(nil, title: primary.title, symbol: primary.symbol) }
            ForEach(PhotoEditorTool.allCases) { tool in item(tool, title: tool.title, symbol: tool.symbol) }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 2)
        .glassEffect(.regular, in: .capsule)
        .disabled(!isEnabled)
    }

    private func item(_ tool: PhotoEditorTool?, title: String, symbol: String) -> some View {
        Button { guard isEnabled else { return }; selected = tool } label: {
            VStack(spacing: 3) {
                Image(systemName: symbol).font(.system(size: 20))
                Text(title).font(.system(size: 11, weight: .medium))
            }
            .frame(minWidth: 48, minHeight: 52)
            .foregroundStyle(selected == tool ? Color.yellow : Color.primary)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityAddTraits(selected == tool ? .isSelected : [])
    }
}

struct PhotoEditRulerSlider: View {
    @Binding var value: Double
    let range: ClosedRange<Double>
    let label: String
    let valueText: String
    let onEditingChanged: (Bool) -> Void
    @Environment(\.isEnabled) private var isEnabled

    init(value: Binding<Double>, in range: ClosedRange<Double>, label: String, valueText: String,
         onEditingChanged: @escaping (Bool) -> Void) {
        _value = value
        self.range = range
        self.label = label
        self.valueText = valueText
        self.onEditingChanged = onEditingChanged
    }

    private var fraction: Double {
        guard value.isFinite, range.upperBound > range.lowerBound else { return 0 }
        return min(1, max(0, (value - range.lowerBound) / (range.upperBound - range.lowerBound)))
    }

    var body: some View {
        ZStack {
            Canvas { context, size in
                let span = max(1, size.width * 1.7)
                for index in 0...100 {
                    let x = size.width / 2 + (CGFloat(index) / 100 - CGFloat(fraction)) * span
                    guard x >= 0, x <= size.width else { continue }
                    let height: CGFloat = index.isMultiple(of: 10) ? 20 : index.isMultiple(of: 5) ? 14 : 8
                    var tick = Path()
                    tick.move(to: CGPoint(x: x, y: (size.height - height) / 2))
                    tick.addLine(to: CGPoint(x: x, y: (size.height + height) / 2))
                    context.stroke(tick, with: .color(.primary.opacity(index.isMultiple(of: 10) ? 0.6 : 0.3)), lineWidth: 1)
                }
                var marker = Path()
                marker.move(to: CGPoint(x: size.width / 2, y: 7))
                marker.addLine(to: CGPoint(x: size.width / 2, y: size.height - 7))
                context.stroke(marker, with: .color(.yellow), lineWidth: 2)
            }
            .accessibilityHidden(true)
            .opacity(isEnabled ? 1 : 0.4)
            PhotoEditSliderControl(value: $value, range: range, label: label, valueText: valueText,
                isEnabled: isEnabled, onEditingChanged: onEditingChanged)
        }
        .frame(height: 44)
    }
}

private struct PhotoEditSliderControl: UIViewRepresentable {
    @Binding var value: Double
    let range: ClosedRange<Double>
    let label: String
    let valueText: String
    let isEnabled: Bool
    let onEditingChanged: (Bool) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeUIView(context: Context) -> PhotoEditNativeSlider {
        let slider = PhotoEditNativeSlider()
        slider.minimumValue = 0
        slider.maximumValue = 1
        slider.minimumTrackTintColor = .clear
        slider.maximumTrackTintColor = .clear
        let clear = UIGraphicsImageRenderer(size: CGSize(width: 28, height: 28)).image { _ in }
        for state: UIControl.State in [.normal, .highlighted, .disabled] { slider.setThumbImage(clear, for: state) }
        slider.addTarget(context.coordinator, action: #selector(Coordinator.began), for: .touchDown)
        slider.addTarget(context.coordinator, action: #selector(Coordinator.changed), for: .valueChanged)
        slider.addTarget(context.coordinator, action: #selector(Coordinator.ended), for: [.touchUpInside, .touchUpOutside, .touchCancel])
        return slider
    }
    func updateUIView(_ slider: PhotoEditNativeSlider, context: Context) {
        context.coordinator.parent = self
        slider.isEnabled = isEnabled
        slider.accessibilityLabel = label
        slider.accessibilityValue = valueText
        let span = range.upperBound - range.lowerBound
        let fraction = value.isFinite && span > 0 ? (value - range.lowerBound) / span : 0
        slider.value = Float(min(1, max(0, fraction)))
        if !isEnabled { context.coordinator.finishEditing() }
    }
    func sizeThatFits(_ proposal: ProposedViewSize, uiView: PhotoEditNativeSlider, context: Context) -> CGSize? {
        guard let width = proposal.width, width.isFinite else { return nil }
        let height = proposal.height.flatMap { $0.isFinite ? $0 : nil } ?? 44
        return CGSize(width: width, height: height)
    }
    static func dismantleUIView(_ slider: PhotoEditNativeSlider, coordinator: Coordinator) {
        slider.cancelRulerInteraction()
        slider.removeTarget(coordinator, action: nil, for: .allEvents)
        coordinator.finishEditing()
    }

    @MainActor final class Coordinator: NSObject {
        var parent: PhotoEditSliderControl
        private var isEditing = false
        init(_ parent: PhotoEditSliderControl) { self.parent = parent }
        @objc func began(_ slider: UISlider) {
            guard slider.isEnabled, parent.isEnabled, !isEditing else { return }
            isEditing = true
            parent.onEditingChanged(true)
        }
        @objc func changed(_ slider: UISlider) {
            guard slider.isEnabled, parent.isEnabled else { return }
            let fraction = min(1, max(0, Double(slider.value)))
            parent.value = parent.range.lowerBound + fraction * (parent.range.upperBound - parent.range.lowerBound)
        }
        @objc func ended(_ slider: UISlider) { finishEditing() }
        func finishEditing() {
            guard isEditing else { return }
            isEditing = false
            parent.onEditingChanged(false)
        }
    }
}

private final class PhotoEditNativeSlider: UISlider {
    private var rulerPan: UIPanGestureRecognizer?
    private var panStartValue: Float?
    private var prioritizedRecognizers = Set<ObjectIdentifier>()

    override init(frame: CGRect) {
        super.init(frame: frame)
        let pan = UIPanGestureRecognizer(target: self, action: #selector(panned))
        pan.maximumNumberOfTouches = 1
        pan.delaysTouchesBegan = true
        pan.cancelsTouchesInView = true
        rulerPan = pan
        addGestureRecognizer(pan)
        prioritizeRulerPan()
    }
    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    override var isEnabled: Bool {
        didSet {
            if !isEnabled { finishPan(cancelled: true) }
            rulerPan?.isEnabled = isEnabled
        }
    }
    override func layoutSubviews() {
        super.layoutSubviews()
        prioritizeRulerPan()
    }
    private func prioritizeRulerPan() {
        guard let rulerPan else { return }
        for recognizer in gestureRecognizers ?? [] where recognizer !== rulerPan {
            if prioritizedRecognizers.insert(ObjectIdentifier(recognizer)).inserted {
                recognizer.require(toFail: rulerPan)
            }
        }
    }
    @objc private func panned(_ pan: UIPanGestureRecognizer) {
        guard isEnabled else { finishPan(cancelled: true); return }
        switch pan.state {
        case .began:
            panStartValue = value
            sendActions(for: .touchDown)
            updatePan(pan)
        case .changed: updatePan(pan)
        case .ended:
            updatePan(pan)
            finishPan(cancelled: false)
        case .cancelled, .failed: finishPan(cancelled: true)
        default: break
        }
    }
    private func updatePan(_ pan: UIPanGestureRecognizer) {
        guard isEnabled, let panStartValue else { return }
        // Moving the ruler left selects the higher values to the right of its fixed marker.
        let delta = Float(pan.translation(in: self).x / max(1, bounds.width * 1.7))
        let next = min(maximumValue, max(minimumValue, panStartValue - delta))
        guard next != value else { return }
        value = next
        sendActions(for: .valueChanged)
    }
    private func finishPan(cancelled: Bool) {
        guard panStartValue != nil else { return }
        panStartValue = nil
        sendActions(for: cancelled ? .touchCancel : .touchUpInside)
    }
    func cancelRulerInteraction() {
        finishPan(cancelled: true)
        rulerPan?.isEnabled = false
    }
    override func accessibilityIncrement() { adjustAccessibility(by: 0.01) }
    override func accessibilityDecrement() { adjustAccessibility(by: -0.01) }
    private func adjustAccessibility(by delta: Float) {
        guard isEnabled else { return }
        sendActions(for: .touchDown)
        value = min(maximumValue, max(minimumValue, value + delta))
        sendActions(for: .valueChanged)
        sendActions(for: .touchUpInside)
    }
}
