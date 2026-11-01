import Observation
import SwiftUI

@MainActor
@Observable
final class PhotoSlideshowState {
    private let source: [AssetLite]
    private let sourceIndex: [String: Int]
    @ObservationIgnored private let displayAsset: (AssetLite) -> AssetLite
    private let generation = LocalSnapshot.generation
    let policy: AssetVisibilityPolicy
    private(set) var currentAssetID: String?
    private(set) var isPlaying = true
    private(set) var hasEnded = false
    private(set) var revision = UUID()
    private(set) var mediaRevision = UUID()
    private(set) var mediaState = PhotoStoryMediaState.loading
    var isSceneActive = true
    @ObservationIgnored private var elapsed: TimeInterval = 0
    @ObservationIgnored private var acceptsMediaUpdates = true

    init(assets: [AssetLite], initialAssetID: String? = nil,
         visibilityPolicy: AssetVisibilityPolicy? = nil, dataManager: SwiftDataManager? = nil, removed: RemovedAssets? = nil,
         displayAsset: @escaping (AssetLite) -> AssetLite = { $0 }) {
        var seen = Set<String>()
        source = assets.filter { seen.insert($0.id).inserted }
        self.displayAsset = displayAsset
        sourceIndex = Dictionary(uniqueKeysWithValues: source.enumerated().map { ($0.element.id, $0.offset) })
        policy = visibilityPolicy ?? AssetVisibilityPolicy(scope: .timeline, dataManager: dataManager, removed: removed)
        currentAssetID = initialAssetID ?? source.first?.id
        reconcile()
    }

    var isCurrent: Bool { generation == LocalSnapshot.generation }
    var assets: [AssetLite] { isCurrent ? policy.filter(source) : [] }
    var currentAsset: AssetLite? {
        guard isCurrent, let id = currentAssetID, let index = sourceIndex[id], policy.allows(id: id) else { return nil }
        return displayAsset(source[index])
    }
    var currentIndex: Int { assets.firstIndex { $0.id == currentAssetID } ?? 0 }
    var canMovePrevious: Bool { currentAsset != nil && currentIndex > 0 }
    var canMoveNext: Bool { currentAsset != nil && !hasEnded }
    var duration: TimeInterval {
        guard let asset = currentAsset, asset.isVideo,
              let duration = asset.duration, duration.isFinite, duration > 0 else { return 5 }
        return duration
    }

    func reconcile() {
        let available = assets
        guard !available.isEmpty else {
            currentAssetID = nil
            isPlaying = false
            hasEnded = false
            restartInterval()
            return
        }
        let availableIDs = Set(available.map(\.id))
        guard currentAssetID.map(availableIDs.contains) != true else { return }
        let previousIndex = currentAssetID.flatMap { sourceIndex[$0] } ?? 0
        let next = source.dropFirst(previousIndex).first { availableIDs.contains($0.id) }
        currentAssetID = next?.id ?? available.last?.id
        hasEnded = false
        restartInterval()
    }

    func select(_ id: String) {
        guard assets.contains(where: { $0.id == id }) else { return }
        currentAssetID = id
        hasEnded = false
        restartInterval()
    }

    func previous() {
        guard canMovePrevious else { return }
        select(assets[currentIndex - 1].id)
    }

    func next() {
        let available = assets
        guard canMoveNext else { return }
        if currentIndex + 1 < available.count {
            select(available[currentIndex + 1].id)
        } else {
            hasEnded = true
            isPlaying = false
            revision = UUID()
        }
    }

    func togglePlayback() {
        guard currentAsset != nil else { return }
        if hasEnded { replay() }
        else { isPlaying.toggle(); revision = UUID() }
    }

    func replay() {
        guard let first = assets.first else { return }
        select(first.id)
        isPlaying = true
    }

    func elapse(_ seconds: TimeInterval, suspended: Bool = false) {
        guard isPlaying, isSceneActive, !suspended, !hasEnded, mediaState != .loading, currentAsset != nil,
              seconds.isFinite, seconds > 0 else { return }
        if mediaState == .failed { next(); return }
        elapsed += seconds
        if elapsed >= duration { next() }
    }

    func updateMediaState(_ value: PhotoStoryMediaState, assetID: String, revision: UUID) {
        guard acceptsMediaUpdates, !hasEnded, currentAsset?.id == assetID, mediaRevision == revision else { return }
        mediaState = value
    }

    func stop() { acceptsMediaUpdates = false; isPlaying = false; revision = UUID() }
    func allowsSharing(_ id: String) -> Bool { isCurrent && currentAsset?.id == id && policy.allows(id: id) }

    private func restartInterval() { elapsed = 0; mediaState = .loading; revision = UUID(); mediaRevision = UUID() }
}

struct PhotoSlideshowView: View {
    private let prepareShare: (AssetLite) async -> URL?
    private let previewLoader: PhotoPreviewLoader?
    @State private var state: PhotoSlideshowState
    @State private var sharePreparation = SharePreparation()
    @State private var shareItem: SharedLinkPresentation?
    @State private var sharedAssetID: String?
    @State private var sharedSourceIDs: [String] = []
    @State private var sharedRequestContext: SessionRequestContext?
    @State private var shareError: ErrorEvent?
    @State private var sessionContext: SessionRequestContext?
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @Environment(SessionManager.self) private var session

    init(assets: [AssetLite], session: SessionManager, initialAssetID: String? = nil,
         visibilityPolicy: AssetVisibilityPolicy? = nil, prepareShare: @escaping (AssetLite) async -> URL?, state: PhotoSlideshowState? = nil,
         previewLoader: PhotoPreviewLoader? = nil) {
        self.prepareShare = prepareShare
        self.previewLoader = previewLoader
        _state = State(initialValue: state ?? PhotoSlideshowState(assets: assets, initialAssetID: initialAssetID,
            visibilityPolicy: visibilityPolicy, displayAsset: { MediaEditingPipeline.shared.displayAsset($0, session: session) }))
    }

    private var suspended: Bool { !state.isSceneActive || sharePreparation.isPreparing || shareItem != nil }

    var body: some View {
        // Account clearing must also invalidate a paused slideshow with no saved detail snapshot.
        _ = LocalSnapshot.invalidationRevision(for: LocalSnapshot.Key.assetDetail(state.currentAssetID ?? ""))
        return ZStack {
            Color.black.ignoresSafeArea()
            if let asset = state.currentAsset {
                let revision = state.mediaRevision
                GeometryReader { geometry in
                    MemoryStorySlide(asset: asset, isActive: !state.hasEnded && state.isCurrent,
                        isPaused: !state.isPlaying || suspended, previewLoader: previewLoader, visibilityPolicy: state.policy,
                        onMediaStateChanged: { [weak state] value in
                            state?.updateMediaState(value, assetID: asset.id, revision: revision)
                        })
                        .id(state.mediaRevision)
                        .frame(width: geometry.size.width, height: geometry.size.height)
                        .clipped()
                }
                .ignoresSafeArea()
            }
            VStack(spacing: 16) {
                header
                Spacer()
                if state.hasEnded {
                    Button("Replay", systemImage: "arrow.counterclockwise", action: state.replay)
                        .buttonStyle(.glass).buttonBorderShape(.capsule)
                        .accessibilityIdentifier("photoSlideshow.replay")
                    Spacer()
                }
                controls
                thumbnails
            }
            .padding(.horizontal, 20).padding(.vertical, 12)
            .foregroundStyle(.white)
        }
        .preferredColorScheme(.dark)
        .sheet(item: $shareItem, onDismiss: { sharedAssetID = nil; sharedSourceIDs = []; sharedRequestContext = nil }) { item in
            PhotoShareSheet(urls: [item.url], assetIDs: sharedAssetID.map { [$0] } ?? [],
                sourceIDs: sharedSourceIDs, requestContext: sharedRequestContext,
                isAllowed: { [weak state] in state?.allowsSharing($0) == true })
        }
        .errorToast($shareError)
        .task(id: PlaybackKey(assetID: state.currentAssetID, revision: state.revision,
            paused: !state.isPlaying || suspended || state.mediaState == .loading, ended: state.hasEnded)) { await run() }
        .onAppear {
            if sessionContext == nil { sessionContext = session.snapshot }
            state.isSceneActive = scenePhase == .active
            reconcile()
        }
        .onChange(of: session.snapshot) { _, context in
            guard let sessionContext, context != sessionContext else { return }
            cleanup()
            dismiss()
        }
        .onChange(of: scenePhase) { _, phase in state.isSceneActive = phase == .active }
        .onChange(of: state.assets.map(\.id)) { _, _ in reconcile() }
        .onChange(of: state.currentAssetID) { _, _ in sharePreparation.cancel() }
        .onDisappear { cleanup() }
    }

    private var header: some View {
        HStack {
            Button("Close", systemImage: "xmark") { cleanup(); dismiss() }
                .accessibilityIdentifier("photoSlideshow.close")
            Spacer()
            Text("Slideshow").font(.headline)
                .padding(.horizontal, 12).padding(.vertical, 6)
                .background(.black.opacity(0.65), in: .capsule)
            Spacer()
            Button("Share", systemImage: "square.and.arrow.up", action: share)
                .disabled(state.currentAsset == nil || sharePreparation.isPreparing || shareItem != nil)
                .accessibilityIdentifier("photoSlideshow.share")
        }
        .labelStyle(.iconOnly).buttonStyle(.glass).buttonBorderShape(.circle)
    }

    private var controls: some View {
        VStack(spacing: 12) {
            if let asset = state.currentAsset {
                Text(asset.createdAt, format: .dateTime.month(.wide).day().year())
                    .font(.subheadline)
                    .padding(.horizontal, 12).padding(.vertical, 6)
                    .background(.black.opacity(0.65), in: .capsule)
            }
            HStack(spacing: 28) {
                Button("Previous", systemImage: "backward.end.fill", action: state.previous)
                    .disabled(!state.canMovePrevious).accessibilityIdentifier("photoSlideshow.previous")
                Button(state.isPlaying ? String(localized: "Pause") : String(localized: "Play"),
                    systemImage: state.isPlaying ? "pause.fill" : "play.fill", action: state.togglePlayback)
                    .disabled(state.currentAsset == nil).accessibilityIdentifier("photoSlideshow.playPause")
                Button("Next", systemImage: "forward.end.fill", action: state.next)
                    .disabled(!state.canMoveNext).accessibilityIdentifier("photoSlideshow.next")
            }
            .labelStyle(.iconOnly).buttonStyle(.glass).buttonBorderShape(.circle)
            Text("\(state.currentAsset == nil ? 0 : state.currentIndex + 1) of \(state.assets.count)")
                .font(.caption).monospacedDigit()
                .padding(.horizontal, 12).padding(.vertical, 6)
                .background(.black.opacity(0.65), in: .capsule)
        }
    }

    @ViewBuilder private var thumbnails: some View {
        if let id = state.currentAssetID {
            PhotoFilmstripView(assets: state.assets, currentAssetID: id,
                onSelect: { state.select($0.id) }, visibilityPolicy: state.policy,
                session: session)
                .frame(height: 64)
        }
    }

    private func reconcile() {
        state.reconcile()
        if let sharedAssetID, !state.allowsSharing(sharedAssetID) {
            shareItem = nil
            self.sharedAssetID = nil
            sharedSourceIDs = []
            sharedRequestContext = nil
        }
        if state.assets.isEmpty { cleanup(); dismiss() }
    }

    private func share() {
        guard sessionContext == session.snapshot, let asset = state.currentAsset,
              !sharePreparation.isPreparing, shareItem == nil else { return }
        shareError = nil
        let prepare = prepareShare, error = $shareError, item = $shareItem, sharedID = $sharedAssetID
        let sourceIDs = $sharedSourceIDs, requestContext = $sharedRequestContext, preparation = sharePreparation
        sharePreparation.start(ids: [asset.id], session: session, prepare: { _ in
            if let url = await prepare(asset) { return [url] }
            return []
        }, isAllowed: { [weak state] in state?.allowsSharing($0) == true },
            onError: { error.wrappedValue = ErrorEvent($0) }) { urls in
            sharedID.wrappedValue = asset.id
            sourceIDs.wrappedValue = preparation.preparedSourceIDs
            requestContext.wrappedValue = preparation.preparedContext
            item.wrappedValue = urls.first.map { SharedLinkPresentation(url: $0) }
        }
    }

    private func run() async {
        let revision = state.revision
        let clock = ContinuousClock()
        var previous = clock.now
        while !Task.isCancelled, state.revision == revision, state.isPlaying, !state.hasEnded,
              state.mediaState != .loading, !suspended {
            do { try await clock.sleep(for: .milliseconds(100)) } catch { return }
            guard !Task.isCancelled, state.revision == revision, state.mediaState != .loading, !suspended else { return }
            let now = clock.now
            let interval = previous.duration(to: now).components
            previous = now
            state.elapse(Double(interval.seconds) + Double(interval.attoseconds) / 1e18, suspended: suspended)
        }
    }

    private func cleanup() {
        sharePreparation.cancel()
        state.stop()
        if let url = shareItem?.url { TemporaryMediaStore.remove(url) }
        shareItem = nil
        sharedAssetID = nil
        sharedSourceIDs = []
        sharedRequestContext = nil
    }

    private struct PlaybackKey: Equatable {
        let assetID: String?
        let revision: UUID
        let paused: Bool
        let ended: Bool
    }
}
