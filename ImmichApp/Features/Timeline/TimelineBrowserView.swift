import SwiftUI

/// Scroll state belongs to each overview, independent of the zoom animation.
@MainActor
@Observable
final class TimelineOverviewPosition {
    var itemID: String?
    @ObservationIgnored var cardFrames: [String: CGRect] = [:]
    @ObservationIgnored var viewport = CGRect.zero

    var centeredAssetID: String? {
        cardFrames
            .filter { $0.value.intersects(viewport) }
            .min {
                abs($0.value.midY - viewport.midY)
                    < abs($1.value.midY - viewport.midY)
            }?.key
    }
}

/// Keeps the grid and both overviews alive. Only their presentation transforms
/// animate; changing the scroll target never inherits the zoom transaction.
struct TimelineBrowserView<Grid: View>: View {
    let viewModel: TimelineViewModel
    let navigation: TimelineNavigationState
    let gridController: PhotoGridController?
    var resetScrollRequest = 0
    var onRemoveFilters: () -> Void
    @ViewBuilder var grid: () -> Grid

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var monthsPosition = TimelineOverviewPosition()
    @State private var yearsPosition = TimelineOverviewPosition()
    @State private var mountedModes: Set<TimelineMode> = [.all]
    @State private var displayedMode: TimelineMode = .all
    @State private var outgoingMode: TimelineMode = .all
    @State private var progress: CGFloat = 1
    @State private var isTransitioning = false
    @State private var focusedAsset: AssetLite?
    @State private var pendingSelection: TimelineCardSelection?
    @State private var transitionTask: Task<Void, Never>?
    @State private var transitionID = UUID()
    @State private var matchingAssetID: String?
    @State private var transitionDestination: TimelineMode?
    @State private var photoMatchTransition: PhotoMatchZoomTransition?

    var body: some View {
        ZStack {
            ForEach(TimelineMode.allCases) { mode in
                if mountedModes.contains(mode) {
                    pane(for: mode)
                        .transaction { $0.animation = nil }
                        .scaleEffect(scale(for: mode))
                        .opacity(opacity(for: mode))
                        .zIndex(displayedMode == mode ? 1 : 0)
                        .allowsHitTesting(displayedMode == mode && !isTransitioning)
                        .accessibilityHidden(displayedMode != mode)
                }
            }
        }
        .overlay {
            if viewModel.librarySections.isEmpty, !viewModel.libraryOptions.filters.isEmpty {
                ContentUnavailableView {
                    Label("No Photos or Videos", systemImage: "line.3.horizontal.decrease.circle")
                } description: {
                    Text("Try removing filters to see more photos and videos.")
                } actions: {
                    Button("Remove Filter", action: onRemoveFilters)
                }
            }
        }
        .onChange(of: navigation.mode, initial: true) { _, mode in
            guard transitionDestination != mode else { return }
            changeMode(to: mode)
        }
        .onAppear {
            if navigation.mode != displayedMode, transitionDestination == nil {
                changeMode(to: navigation.mode)
            }
        }
        .onChange(of: resetScrollRequest) { _, _ in
            pendingSelection = nil
            focusedAsset = nil
            changeMode(to: .all, showNewest: true)
            navigation.mode = .all
        }
        .onChange(of: navigation.returnToNewestRequest) { _, _ in
            focusedAsset = nil
            if navigation.mode == .all {
                changeMode(to: .all, showNewest: true)
            } else if transitionDestination != nil {
                // A quick second tap belongs to the requested mode, even
                // while its hidden scroll view is still being positioned.
                let position = navigation.mode == .months ? monthsPosition : yearsPosition
                let items = navigation.mode == .months
                    ? viewModel.libraryMonthNavigationItems : viewModel.libraryYearNavigationItems
                position.itemID = items.last?.id
            }
        }
        .onDisappear {
            transitionTask?.cancel()
            photoMatchTransition?.cancel()
            photoMatchTransition = nil
            transitionID = UUID()
            transitionDestination = nil
            isTransitioning = false
            progress = 1
        }
    }

    @ViewBuilder
    private func pane(for mode: TimelineMode) -> some View {
        if mode == .all {
            grid()
        } else {
            TimelineNavigatorView(
                mode: mode,
                items: mode == .months
                    ? viewModel.libraryMonthNavigationItems : viewModel.libraryYearNavigationItems,
                position: mode == .months ? monthsPosition : yearsPosition,
                isActive: navigation.mode == mode,
                returnToNewestRequest: navigation.returnToNewestRequest,
                hiddenAssetID: matchingAssetID,
                onSelect: { selection in
                    pendingSelection = selection
                    navigation.mode = mode == .years ? .months : .all
                })
        }
    }

    private func opacity(for mode: TimelineMode) -> Double {
        if mode == displayedMode { return isTransitioning ? Double(progress) : 1 }
        if isTransitioning, mode == outgoingMode { return Double(1 - progress) }
        return 0
    }

    private func scale(for mode: TimelineMode) -> CGFloat {
        guard isTransitioning, !reduceMotion else { return 1 }
        let zoomsOut = displayedMode.zoomLevel < outgoingMode.zoomLevel
        if mode == displayedMode {
            let start: CGFloat = zoomsOut ? 1.16 : 0.84
            return start + (1 - start) * progress
        }
        if mode == outgoingMode {
            return 1 + (zoomsOut ? -0.16 : 0.16) * progress
        }
        return 1
    }

    private func currentFocus() -> AssetLite? {
        if displayedMode == .all {
            return gridController?.visibleAssetForTimelineNavigation() ?? focusedAsset
        }

        let position = displayedMode == .months ? monthsPosition : yearsPosition
        let items = displayedMode == .months
            ? viewModel.libraryMonthNavigationItems : viewModel.libraryYearNavigationItems
        let visibleAssetID = position.centeredAssetID
        let item = items.first { item in
            item.cover.id == visibleAssetID
                || item.highlights.contains { $0.cover.id == visibleAssetID }
        } ?? items.first { $0.id == position.itemID } ?? items.last
        guard let item else { return focusedAsset }

        // Passing through Years and back should retain the exact month/photo
        // until the user browses to a different period.
        if let focusedAsset {
            let month = MonthKey.of(focusedAsset.createdAt)
            if (displayedMode == .months && month == item.id)
                || (displayedMode == .years && String(month.prefix(4)) == item.id) {
                return focusedAsset
            }
        }
        return item.highlights.first { $0.cover.id == visibleAssetID }?.cover ?? item.cover
    }

    private func changeMode(to mode: TimelineMode, showNewest: Bool = false) {
        // A second request can arrive while the hidden destination is laying
        // out. Cancel that work even when returning to the still-visible mode.
        transitionTask?.cancel()
        photoMatchTransition?.cancel()
        photoMatchTransition = nil
        let id = UUID()
        transitionID = id
        transitionDestination = mode
        if mode == displayedMode {
            transitionDestination = nil
            isTransitioning = false
            progress = 1
            if showNewest { gridController?.scrollToNewest(animated: !reduceMotion) }
            return
        }
        let selection = pendingSelection
        pendingSelection = nil
        let focus = showNewest ? nil : selection?.asset ?? currentFocus()
        focusedAsset = focus

        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            progress = 1
            isTransitioning = false
            if let focus {
                let month = MonthKey.of(focus.createdAt)
                if mode == .months { monthsPosition.itemID = month }
                if mode == .years { yearsPosition.itemID = String(month.prefix(4)) }
            }
            mountedModes.insert(mode)
        }

        transitionTask = Task { @MainActor in
            // Mount and position the hidden destination before exposing it.
            // In particular, let the navigation bar settle before measuring
            // the grid cell for a card-to-photo match.
            await nextLayoutPass()
            guard !Task.isCancelled, transitionID == id else { return }
            if showNewest {
                gridController?.scrollToNewest(animated: false)
            } else if mode == .all, let focus,
               selection != nil || gridController?.visibleAssetForTimelineNavigation()?.id != focus.id {
                gridController?.scrollToAsset(id: focus.id, animated: false)
            }
            gridController?.view.window?.layoutIfNeeded()
            await nextLayoutPass()
            guard !Task.isCancelled, transitionID == id else { return }

            // A tapped day uses the very same image as its destination cell.
            // The common bitmap bridges SwiftUI cards and UICollectionView.
            if mode == .all, let selection,
               let controller = gridController,
               let destination = controller.zoomSource(for: selection.asset.id),
               let image = selection.image ?? destination.image,
               let window = controller.view.window,
               !reduceMotion {
                matchingAssetID = selection.asset.id
                controller.setZoomSourceHidden(true, for: selection.asset.id)
                photoMatchTransition = animatePhotoMatchZoom(
                    image: image,
                    fromScreenFrame: selection.frame,
                    toScreenFrame: destination.frame,
                    in: window,
                    sourceCornerRadius: 18
                ) {
                    controller.setZoomSourceHidden(false, for: selection.asset.id)
                    if transitionID == id {
                        matchingAssetID = nil
                        photoMatchTransition = nil
                    }
                }
            }

            withTransaction(transaction) {
                outgoingMode = displayedMode
                displayedMode = mode
                progress = 0
                isTransitioning = true
            }
            await nextLayoutPass()
            guard !Task.isCancelled, transitionID == id else { return }
            withAnimation(
                reduceMotion ? .easeOut(duration: 0.15) : .spring(duration: 0.42, bounce: 0.12)
            ) {
                progress = 1
            } completion: {
                guard transitionID == id else { return }
                isTransitioning = false
                transitionDestination = nil
            }
        }
    }

    private func nextLayoutPass() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async {
                continuation.resume()
            }
        }
    }
}

extension TimelineMode {
    var zoomLevel: Int {
        switch self {
        case .years: 0
        case .months: 1
        case .all: 2
        }
    }
}

struct TimelineCardSelection {
    let asset: AssetLite
    let frame: CGRect
    let image: UIImage?
}

private struct TimelineCardFramesKey: PreferenceKey {
    static var defaultValue: [String: CGRect] { [:] }
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}

struct TimelineNavigatorView: View {
    let mode: TimelineMode
    let items: [TimelineNavigationItem]
    @Bindable var position: TimelineOverviewPosition
    let isActive: Bool
    let returnToNewestRequest: Int
    var hiddenAssetID: String? = nil
    let onSelect: (TimelineCardSelection) -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 34) {
                    ForEach(items) { item in
                        if mode == .months {
                            TimelineMonthSection(
                                item: item, hiddenAssetID: hiddenAssetID, onSelect: onSelect)
                                .id(item.id)
                        } else {
                            TimelineNavigatorTile(
                                asset: item.cover,
                                title: item.title,
                                accessibilityTitle: item.title,
                                onSelect: onSelect)
                                .opacity(item.cover.id == hiddenAssetID ? 0 : 1)
                                .aspectRatio(1.45, contentMode: .fit)
                                .id(item.id)
                        }
                    }
                }
                .scrollTargetLayout()
                .padding(.horizontal, 20)
                .padding(.vertical, 24)
                .frame(maxWidth: 900)
                .frame(maxWidth: .infinity)
            }
            .scrollPosition(id: $position.itemID, anchor: .center)
            .defaultScrollAnchor(.bottom, for: .initialOffset)
            .background(Color(.systemBackground))
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: {
                position.viewport = $0
            }
            .onPreferenceChange(TimelineCardFramesKey.self) { position.cardFrames = $0 }
            .onChange(of: returnToNewestRequest) { _, _ in
                guard isActive, let newest = items.last else { return }
                withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.35)) {
                    proxy.scrollTo(newest.id, anchor: .bottom)
                }
            }
        }
    }
}

struct TimelineMonthSection: View {
    let item: TimelineNavigationItem
    var hiddenAssetID: String? = nil
    let onSelect: (TimelineCardSelection) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(item.title)
                .font(.title.bold())
                .foregroundStyle(.primary)
                .accessibilityAddTraits(.isHeader)
            GeometryReader { geometry in
                let highlights = Array(item.highlights.prefix(3))
                let gap: CGFloat = 6
                if let first = highlights.first {
                    HStack(spacing: gap) {
                        tile(first)
                            .frame(width: highlights.count == 3
                                ? (geometry.size.width - gap) * 2 / 3
                                : nil)
                        if highlights.count == 2 {
                            tile(highlights[1])
                        } else if highlights.count == 3 {
                            VStack(spacing: gap) {
                                tile(highlights[1])
                                tile(highlights[2])
                            }
                        }
                    }
                }
            }
            .aspectRatio(1.5, contentMode: .fit)
        }
    }

    private func tile(_ highlight: TimelineDayHighlight) -> some View {
        TimelineNavigatorTile(
            asset: highlight.cover,
            title: highlight.title,
            accessibilityTitle: highlight.date.formatted(date: .complete, time: .omitted),
            onSelect: onSelect)
            .opacity(highlight.cover.id == hiddenAssetID ? 0 : 1)
    }
}

private struct TimelineNavigatorTile: View {
    let asset: AssetLite
    let title: String
    let accessibilityTitle: String
    let onSelect: (TimelineCardSelection) -> Void
    @State private var frame = CGRect.zero

    var body: some View {
        Button {
            onSelect(TimelineCardSelection(
                asset: asset, frame: frame, image: TimelineNavigatorCover.cachedImage(for: asset)))
        } label: {
            Color.clear
                .overlay { TimelineNavigatorCover(asset: asset) }
                .clipShape(.rect(cornerRadius: 18))
                .overlay(alignment: .topLeading) {
                    Text(title)
                        .font(.title2.bold())
                        .foregroundStyle(.white)
                        .shadow(color: .black.opacity(0.65), radius: 3, y: 1)
                        .padding(12)
                }
                .contentShape(.rect(cornerRadius: 18))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityTitle)
        .accessibilityHint("Show photos from this period")
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frame = $0 }
        .background {
            GeometryReader { geometry in
                Color.clear.preference(
                    key: TimelineCardFramesKey.self,
                    value: [asset.id: geometry.frame(in: .global)])
            }
        }
    }
}

private struct TimelineNavigatorCover: View {
    let asset: AssetLite
    @Environment(SessionManager.self) private var session
    @State private var revision = 0

    var body: some View {
        let _ = revision
        ZStack(alignment: .bottomTrailing) {
            if let image = Self.cachedImage(for: asset) {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                Color(.tertiarySystemFill)
                    .overlay {
                        Image(systemName: "photo")
                            .font(.title)
                            .foregroundStyle(.secondary)
                    }
            }
            if asset.isVideo {
                Image(systemName: "play.fill")
                    .font(.caption.bold())
                    .foregroundStyle(.white)
                    .padding(8)
                    .background(.black.opacity(0.55), in: .circle)
                    .padding(10)
            }
        }
        .clipped()
        .task(id: asset.id) {
            let loader = PhotoThumbnailLoader(session: session)
            guard loader.cachedImage(for: asset.id) == nil else { return }
            _ = await loader.image(for: asset.id)
            revision &+= 1
        }
    }

    static func cachedImage(for asset: AssetLite) -> UIImage? {
        ImageMemoryCache.shared.image(
            for: ImageCache.memoryKey(
                "\(asset.id)-thumbnail", PhotoThumbnailLoader.maxPixelSize))
            ?? ThumbHash.placeholder(for: asset.thumbhash)
    }
}
