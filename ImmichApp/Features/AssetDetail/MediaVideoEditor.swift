import AVFoundation
import Observation
import SwiftUI

struct MediaVideoEditValues: Equatable {
    var video: VideoEditRecipe
    var live: LivePhotoEditRecipe
    var photo: PhotoEditRecipe
}

@MainActor @Observable
final class MediaVideoEditHistory {
    let initial: MediaVideoEditValues
    private(set) var values: MediaVideoEditValues
    private var past: [MediaVideoEditValues] = []
    private var future: [MediaVideoEditValues] = []
    private var editingStart: MediaVideoEditValues?

    init(_ values: MediaVideoEditValues) { initial = values; self.values = values }
    var isDirty: Bool { values != initial }
    var canUndo: Bool { !past.isEmpty }
    var canRedo: Bool { !future.isEmpty }
    func update(_ value: MediaVideoEditValues) {
        guard value != values else { return }
        if editingStart == nil { past.append(values); future.removeAll() }
        values = value
    }
    func editingChanged(_ editing: Bool) {
        if editing { if editingStart == nil { editingStart = values } }
        else if let start = editingStart {
            if start != values { past.append(start); future.removeAll() }
            editingStart = nil
        }
    }
    func undo() {
        editingChanged(false)
        guard let value = past.popLast() else { return }
        future.append(values); values = value
    }
    func redo() {
        editingChanged(false)
        guard let value = future.popLast() else { return }
        past.append(values); values = value
    }
}

@MainActor @Observable
private final class MediaVideoEditorPreview {
    struct Frame: Identifiable { let id: Int; let image: UIImage }
    @ObservationIgnored let player = AVPlayer()
    var duration: Double = 0
    var frameRate: Double = 30
    var sourceTime: Double = 0
    var isPlaying = false
    var poster: UIImage?
    var frames: [Frame] = []
    var originalPhotoTime: Double = 0
    @ObservationIgnored private var recipe = VideoEditRecipe()
    @ObservationIgnored private var mode = LivePhotoEditRecipe.Mode.live
    @ObservationIgnored private var timeObserver: Any?
    @ObservationIgnored private var endObserver: NSObjectProtocol?

    func load(_ url: URL, stillURL: URL?, initial: MediaVideoEditValues, isLive: Bool) async throws {
        let asset = AVURLAsset(url: url)
        duration = try await asset.load(.duration).seconds
        _ = try initial.video.selection(duration: duration)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else { throw MediaVideoEditError.unavailableVideo }
        let fps = try await track.load(.nominalFrameRate)
        frameRate = fps.isFinite && fps > 0 ? Double(fps) : 30
        originalPhotoTime = isLive ? try await MediaLiveRenderer.shared.photoTime(motionURL: url) : initial.video.trimStart
        let end = initial.video.trimEnd ?? duration
        sourceTime = min(max(initial.live.keyPhotoTime ?? originalPhotoTime, initial.video.trimStart), max(initial.video.trimStart, end - 1 / 60_000))
        if let stillURL, initial.live.keyPhotoTime == nil, originalPhotoTime >= initial.video.trimStart, originalPhotoTime < end {
            poster = UIImage(contentsOfFile: stillURL.path)
        }
        if poster == nil { poster = try await Self.frame(asset, at: sourceTime, size: 1400) }
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        generator.maximumSize = CGSize(width: 180, height: 120)
        var result: [Frame] = []
        for index in 0..<10 {
            try Task.checkCancellation()
            let time = max(0, min(duration - 1 / frameRate, duration * Double(index) / 9))
            let frame = try await generator.image(at: CMTime(seconds: time, preferredTimescale: 60_000))
            result.append(Frame(id: index, image: UIImage(cgImage: frame.image)))
        }
        try Task.checkCancellation()
        frames = result
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.1, preferredTimescale: 600), queue: .main) { [weak self] time in
            MainActor.assumeIsolated {
                guard let self, self.isPlaying else { return }
                let length = (self.recipe.trimEnd ?? self.duration) - self.recipe.trimStart
                var offset = max(0, time.seconds * self.recipe.rate)
                if self.mode == .loop { offset = offset.truncatingRemainder(dividingBy: max(length, 0.001)) }
                else if self.mode == .bounce {
                    offset = offset.truncatingRemainder(dividingBy: max(length * 2, 0.001))
                    if offset > length { offset = length * 2 - offset }
                }
                self.sourceTime = min(self.recipe.trimStart + offset, self.recipe.trimEnd ?? self.duration)
            }
        }
        endObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: nil, queue: .main) { [weak self] notification in
            MainActor.assumeIsolated {
                guard let self, let item = notification.object as? AVPlayerItem, self.player.currentItem === item else { return }
                self.pause()
            }
        }
    }

    func install(_ item: AVPlayerItem, values: MediaVideoEditValues) {
        let resume = isPlaying
        player.pause()
        recipe = values.video; mode = values.live.mode
        player.replaceCurrentItem(with: item)
        seek(sourceTime)
        if resume { player.play() }
    }
    func toggle() {
        guard player.currentItem != nil else { return }
        if isPlaying { pause() }
        else {
            let end = player.currentItem?.duration.seconds ?? .nan
            if end.isFinite, player.currentTime().seconds >= end - 0.05 { player.seek(to: .zero) }
            isPlaying = true; player.play()
        }
    }
    func pause() { isPlaying = false; player.pause() }
    func seek(_ time: Double) {
        guard time.isFinite else { return }
        sourceTime = min(max(time, recipe.trimStart), recipe.trimEnd ?? max(duration, 0))
        player.seek(to: CMTime(seconds: max(0, sourceTime - recipe.trimStart) / recipe.rate, preferredTimescale: 60_000),
            toleranceBefore: .zero, toleranceAfter: .zero)
    }
    func updatePoster(_ source: URL, stillURL: URL? = nil, at time: Double, isAllowed: @MainActor () -> Bool) async throws {
        let image: UIImage
        if let stillURL, let still = UIImage(contentsOfFile: stillURL.path) { image = still }
        else { image = try await Self.frame(AVURLAsset(url: source), at: time, size: 1400) }
        try Task.checkCancellation()
        guard isAllowed() else { throw CancellationError() }
        poster = image
    }
    private static func frame(_ asset: AVAsset, at time: Double, size: CGFloat) async throws -> UIImage {
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        generator.maximumSize = CGSize(width: size, height: size)
        let frame = try await generator.image(at: CMTime(seconds: max(time, 0), preferredTimescale: 60_000))
        return UIImage(cgImage: frame.image)
    }
    func teardown() {
        pause()
        poster = nil
        frames = []
        if let timeObserver { player.removeTimeObserver(timeObserver) }
        timeObserver = nil
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        endObserver = nil
        VideoPlaybackLifecycle.stop(player)
    }
}

struct MediaVideoEditor: View {
    let sourceURL: URL
    let stillURL: URL?
    let isLivePhoto: Bool
    private let isAllowed: @MainActor () -> Bool
    private let onSave: @MainActor (VideoEditRecipe, LivePhotoEditRecipe, PhotoEditRecipe) async -> Bool
    private let onRevert: @MainActor () async -> Bool
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.locale) private var locale
    @State private var history: MediaVideoEditHistory
    @State private var preview = MediaVideoEditorPreview()
    @State private var tool: PhotoEditorTool?
    @State private var isSaving = false
    @State private var loadFailed = false
    @State private var ready = false
    @State private var error: ErrorEvent?
    @State private var discardConfirmation = false
    @State private var revertConfirmation = false
    @State private var previewFiles: [URL] = []
    @State private var effectPoster: UIImage?
    @State private var dragStart: Double?
    @State private var saveTask: Task<Void, Never>?

    init(sourceURL: URL, stillURL: URL? = nil, isLivePhoto: Bool,
         video: VideoEditRecipe = .init(), live: LivePhotoEditRecipe = .init(), photo: PhotoEditRecipe = .init(),
         isAllowed: @escaping @MainActor () -> Bool,
         onSave: @escaping @MainActor (VideoEditRecipe, LivePhotoEditRecipe, PhotoEditRecipe) async -> Bool,
         onRevert: @escaping @MainActor () async -> Bool) {
        self.sourceURL = sourceURL; self.stillURL = stillURL; self.isLivePhoto = isLivePhoto
        self.isAllowed = isAllowed; self.onSave = onSave; self.onRevert = onRevert
        _history = State(initialValue: MediaVideoEditHistory(.init(video: video, live: live, photo: photo)))
    }

    private var photo: Binding<PhotoEditRecipe> {
        Binding(get: { history.values.photo }, set: { value in
            guard !isSaving else { return }
            var next = history.values; next.photo = value; history.update(next)
        })
    }
    private var end: Double { history.values.video.trimEnd ?? preview.duration }
    private var stillMode: Bool { isLivePhoto && [.off, .longExposure].contains(history.values.live.mode) }

    var body: some View {
        NavigationStack {
            VStack(spacing: 12) {
                if !isAllowed() {
                    Color.clear.frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if loadFailed {
                    ContentUnavailableView("Video Unavailable", systemImage: "video.slash", description: Text("This video could not be loaded."))
                } else if ready {
                    canvas.frame(maxWidth: .infinity, maxHeight: .infinity)
                    if let tool, let image = preview.poster {
                        PhotoEditToolControls(image: image, recipe: photo, tool: tool, onEditingChanged: history.editingChanged)
                    } else {
                        primaryControls
                        frameStrip.frame(height: 64).padding(.horizontal, 22)
                    }
                    toolPicker
                } else { ProgressView("Loading video…").frame(maxWidth: .infinity, maxHeight: .infinity) }
            }
            .disabled(isSaving)
            .allowsHitTesting(!isSaving)
            .background(Color(uiColor: .systemBackground))
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(Color(uiColor: .systemBackground), for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel", systemImage: "xmark") {
                        history.editingChanged(false)
                        if history.isDirty { discardConfirmation = true } else { dismiss() }
                    }
                    .labelStyle(.iconOnly).buttonStyle(.glass).buttonBorderShape(.circle)
                    .accessibilityLabel("Cancel")
                    .disabled(isSaving)
                }
                .sharedBackgroundVisibility(.hidden)
                ToolbarItem(placement: .topBarLeading) {
                    HStack(spacing: 8) {
                        Button("Undo", systemImage: "arrow.uturn.backward", action: history.undo)
                            .frame(width: 44, height: 44).disabled(!history.canUndo || isSaving)
                        Button("Redo", systemImage: "arrow.uturn.forward", action: history.redo)
                            .frame(width: 44, height: 44).disabled(!history.canRedo || isSaving)
                    }
                    .labelStyle(.iconOnly).buttonStyle(.plain)
                    .glassEffect(.regular, in: .capsule)
                }
                .sharedBackgroundVisibility(.hidden)
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button("Revert to Original", role: .destructive) { revertConfirmation = true }
                    } label: { Image(systemName: "ellipsis") }
                    .labelStyle(.iconOnly).buttonStyle(.glass).buttonBorderShape(.circle)
                    .accessibilityLabel("More")
                    .disabled(isSaving)
                }
                .sharedBackgroundVisibility(.hidden)
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done", systemImage: "checkmark") { save(reverting: false) }
                        .labelStyle(.iconOnly).buttonStyle(.glass).buttonBorderShape(.circle)
                        .fontWeight(.semibold).tint(.yellow)
                        .accessibilityLabel("Done")
                        .disabled(!ready || isSaving || !isAllowed())
                }
                .sharedBackgroundVisibility(.hidden)
            }
            .overlay { if isSaving { ProgressView("Applying edits…").padding(24).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16)) } }
            .confirmationDialog("Discard Changes?", isPresented: $discardConfirmation, titleVisibility: .visible) {
                Button("Discard Changes", role: .destructive) { dismiss() }
                Button("Keep Editing", role: .cancel) {}
            }
            .confirmationDialog("Revert to Original?", isPresented: $revertConfirmation, titleVisibility: .visible) {
                Button("Revert to Original", role: .destructive) { save(reverting: true) }
                Button("Cancel", role: .cancel) {}
            } message: { Text("This will remove the edits made on this device.") }
            .errorToast($error)
            .task {
                guard isAllowed() else { dismiss(); return }
                do {
                    try await preview.load(sourceURL, stillURL: stillURL, initial: history.values, isLive: isLivePhoto)
                    guard !Task.isCancelled, isAllowed() else { return }
                    ready = true
                } catch { if !Task.isCancelled { loadFailed = true } }
            }
            .task(id: PreviewKey(values: history.values, primary: tool == nil, ready: ready)) { await updatePreview() }
            .task(id: PosterKey(keyTime: history.values.live.keyPhotoTime, video: history.values.video, tool: tool, ready: ready)) {
                guard ready, isAllowed() else { return }
                let originalKey = preview.originalPhotoTime
                let time = min(max(tool == nil ? (history.values.live.keyPhotoTime ?? originalKey) : preview.sourceTime,
                    history.values.video.trimStart), max(history.values.video.trimStart, end - 1 / 60_000))
                let originalStill = isLivePhoto && tool == nil && history.values.live.keyPhotoTime == nil
                    && originalKey >= history.values.video.trimStart && originalKey < end ? stillURL : nil
                try? await preview.updatePoster(sourceURL, stillURL: originalStill, at: time, isAllowed: isAllowed)
            }
            .onChange(of: tool) { _, _ in
                preview.pause()
            }
            .onChange(of: stillMode) { _, still in if still { preview.pause() } }
            .onChange(of: scenePhase) { _, phase in if phase != .active { preview.pause() } }
            .onChange(of: isAllowed()) { _, allowed in if !allowed { saveTask?.cancel(); effectPoster = nil; preview.teardown(); dismiss() } }
            .onDisappear { saveTask?.cancel(); preview.teardown(); TemporaryMediaStore.remove(previewFiles) }
        }
        .interactiveDismissDisabled(history.isDirty || isSaving)
    }

    @ViewBuilder private var canvas: some View {
        if let tool, let image = preview.poster { PhotoEditCanvas(image: image, recipe: photo, tool: tool, comparing: false, onEditingChanged: history.editingChanged) }
        else if stillMode, let image = effectPoster ?? preview.poster {
            if history.values.live.mode == .longExposure { Image(uiImage: image).resizable().scaledToFit() }
            else { PhotoEditCanvas(image: image, recipe: photo, tool: .adjust, comparing: false) }
        } else {
            ZStack {
                Color.black
                if let image = preview.poster { Image(uiImage: image).resizable().scaledToFit() }
                MediaVideoEditorSurface(player: preview.player)
            }
        }
    }

    private var primaryControls: some View {
        HStack(spacing: 20) {
            if !stillMode {
                Button(preview.isPlaying ? "Pause" : "Play", systemImage: preview.isPlaying ? "pause.fill" : "play.fill", action: preview.toggle)
                    .labelStyle(.iconOnly).accessibilityIdentifier("videoEditor.playPause")
            }
            Button(history.values.video.isMuted ? "Unmute" : "Mute", systemImage: history.values.video.isMuted ? "speaker.slash" : "speaker.wave.2") {
                var value = history.values; value.video.isMuted.toggle(); history.update(value)
            }.labelStyle(.iconOnly)
            Spacer()
            if isLivePhoto {
                Menu(history.values.live.mode.title) {
                    ForEach(LivePhotoEditRecipe.Mode.allCases) { mode in
                        Button(mode.title) { var value = history.values; value.live.mode = mode; history.update(value) }
                    }
                }.accessibilityLabel("Live Photo Effect")
                Button("Make Key Photo") {
                    var value = history.values
                    guard let selection = try? value.video.selection(duration: preview.duration) else { return }
                    value.live.selectKeyPhoto(at: preview.sourceTime, originalPhotoTime: preview.originalPhotoTime,
                        selection: selection)
                    history.update(value)
                }.font(.caption)
            } else {
                Menu("Playback Speed", systemImage: "speedometer") {
                    ForEach([0.25, 0.5, 1, 2], id: \.self) { rate in
                        Button(String(format: "%g×", rate)) { var value = history.values; value.video.rate = rate; history.update(value) }
                    }
                }.labelStyle(.iconOnly)
            }
            Text(timeText(preview.sourceTime)).font(.caption.monospacedDigit())
        }
        .padding(.horizontal, 22).disabled(isSaving)
    }

    private var frameStrip: some View {
        GeometryReader { geometry in
            let width = geometry.size.width, start = history.values.video.trimStart / max(preview.duration, 0.001) * width
            let finish = end / max(preview.duration, 0.001) * width
            ZStack(alignment: .leading) {
                HStack(spacing: 0) {
                    ForEach(preview.frames) { frame in
                        Image(uiImage: frame.image).resizable().scaledToFill()
                            .frame(width: width / CGFloat(max(preview.frames.count, 1)), height: 52).clipped()
                    }
                }.clipShape(RoundedRectangle(cornerRadius: 6))
                Color.black.opacity(0.65).frame(width: max(0, start), height: 52)
                Color.black.opacity(0.65).frame(width: max(0, width - finish), height: 52).offset(x: finish)
                RoundedRectangle(cornerRadius: 6).stroke(.yellow, lineWidth: 3).frame(width: max(1, finish - start), height: 56).offset(x: start)
                Rectangle().fill(.white).frame(width: 2, height: 50)
                    .offset(x: preview.sourceTime / max(preview.duration, 0.001) * width)
                trimHandle(start: true, width: width).offset(x: start - 9)
                trimHandle(start: false, width: width).offset(x: finish - 9)
            }
            .frame(height: 64)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                preview.pause()
                preview.seek(min(max(value.location.x / width * preview.duration, history.values.video.trimStart), end))
            })
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("videoEditor.frames")
        }
    }

    private func trimHandle(start: Bool, width: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: 5).fill(.yellow).frame(width: 18, height: 60)
            .overlay(Image(systemName: start ? "chevron.compact.left" : "chevron.compact.right").foregroundStyle(.black))
            .contentShape(Rectangle())
            .highPriorityGesture(DragGesture(minimumDistance: 0).onChanged { value in
                if dragStart == nil { dragStart = start ? history.values.video.trimStart : end; history.editingChanged(true); preview.pause() }
                changeTrim(start: start, time: (dragStart ?? 0) + value.translation.width / width * preview.duration)
            }.onEnded { _ in dragStart = nil; history.editingChanged(false) })
            .accessibilityLabel(start ? "Start Time" : "End Time")
            .accessibilityValue(Measurement(value: start ? history.values.video.trimStart : end, unit: UnitDuration.seconds)
                .formatted(.measurement(width: .abbreviated, usage: .asProvided,
                    numberFormatStyle: .number.precision(.fractionLength(2))).locale(locale)))
            .accessibilityAdjustableAction { direction in
                let delta = direction == .increment ? 1 / preview.frameRate : -1 / preview.frameRate
                changeTrim(start: start, time: (start ? history.values.video.trimStart : end) + delta)
            }
            .accessibilityIdentifier(start ? "videoEditor.trimStart" : "videoEditor.trimEnd")
    }

    private func changeTrim(start: Bool, time: Double) {
        guard !isSaving else { return }
        var value = history.values
        value.video.setTrimBoundary(start ? .start : .end, to: time, duration: preview.duration, frameRate: preview.frameRate)
        if let key = value.live.keyPhotoTime { value.live.keyPhotoTime = min(max(key, value.video.trimStart), value.video.trimEnd ?? preview.duration) }
        history.update(value)
    }

    private var toolPicker: some View {
        PhotoEditorToolPicker(selected: Binding(get: { tool }, set: { selected in
            guard !isSaving else { return }
            history.editingChanged(false)
            tool = selected
        }), primaryTitle: isLivePhoto ? String(localized: "Live") : String(localized: "Video"),
            primarySymbol: isLivePhoto ? "livephoto" : "video", isEnabled: !isSaving)
    }

    private func updatePreview() async {
        guard ready, tool == nil, isAllowed() else { return }
        let values = history.values
        if stillMode { preview.pause() }
        do {
            let item: AVPlayerItem?
            var owned: [URL] = [], poster: UIImage?
            if isLivePhoto, [.loop, .bounce, .longExposure].contains(values.live.mode) {
                let output = try await MediaLiveRenderer.shared.render(motionURL: sourceURL, stillURL: stillURL,
                    video: values.video, live: values.live, photo: values.photo)
                owned = output.ownedURLs
                if output.isVideo { item = AVPlayerItem(url: output.primaryURL) }
                else { item = nil; poster = UIImage(contentsOfFile: output.primaryURL.path) }
            } else { item = try await MediaVideoRenderer.shared.previewItem(sourceURL: sourceURL, video: values.video, photo: values.photo) }
            guard !Task.isCancelled, isAllowed(), history.values == values else { TemporaryMediaStore.remove(owned); return }
            TemporaryMediaStore.remove(previewFiles); previewFiles = owned; effectPoster = poster
            if let item { preview.install(item, values: values) }
            else { preview.pause(); preview.player.replaceCurrentItem(with: nil) }
        } catch { if !Task.isCancelled, isAllowed() { self.error = ErrorEvent(error.localizedDescription) } }
    }

    private func save(reverting: Bool) {
        history.editingChanged(false)
        guard ready, !isSaving, isAllowed() else { return }
        preview.pause()
        let values = history.values
        isSaving = true
        saveTask = Task {
            defer { isSaving = false; saveTask = nil }
            guard !Task.isCancelled, isAllowed() else { return }
            let succeeded = reverting ? await onRevert() : await onSave(values.video, values.live, values.photo)
            guard !Task.isCancelled, isAllowed() else { return }
            if succeeded { dismiss() }
            else { error = ErrorEvent(String(localized: "The edits could not be saved. Try again.")) }
        }
    }

    private func timeText(_ time: Double) -> String {
        let value = time.isFinite ? Int(max(0, time)) : 0
        return String(format: "%d:%02d", value / 60, value % 60)
    }
    private struct PreviewKey: Equatable { let values: MediaVideoEditValues; let primary: Bool; let ready: Bool }
    private struct PosterKey: Equatable { let keyTime: Double?; let video: VideoEditRecipe; let tool: PhotoEditorTool?; let ready: Bool }
}

private struct MediaVideoEditorSurface: UIViewRepresentable {
    let player: AVPlayer
    func makeUIView(context: Context) -> VideoEditorSurfaceView { let view = VideoEditorSurfaceView(); view.playerLayer.player = player; return view }
    func updateUIView(_ view: VideoEditorSurfaceView, context: Context) { view.playerLayer.player = player }
    static func dismantleUIView(_ view: VideoEditorSurfaceView, coordinator: ()) { view.playerLayer.player = nil }
}

private final class VideoEditorSurfaceView: UIView {
    override class var layerClass: AnyClass { AVPlayerLayer.self }
    var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
}
