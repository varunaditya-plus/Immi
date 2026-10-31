import Observation
import UIKit
import VisionKit

@MainActor
protocol PhotoImageAnalyzing: AnyObject {
    var isSupported: Bool { get }
    func analyze(_ image: UIImage) async throws -> ImageAnalysis?
}

@MainActor
private final class SystemPhotoImageAnalyzer: PhotoImageAnalyzing {
    private lazy var analyzer = ImageAnalyzer()
    var isSupported: Bool { ImageAnalyzer.isSupported }

    func analyze(_ image: UIImage) async throws -> ImageAnalysis? {
        try await analyzer.analyze(image,
            configuration: ImageAnalyzer.Configuration([.text, .machineReadableCode, .visualLookUp]))
    }
}

@MainActor
final class PhotoImageAnalysisRequest<Result> {
    private var revision = UUID()
    private var task: Task<Void, Never>?

    @discardableResult
    func start(operation: @escaping @MainActor () async throws -> Result,
               isAllowed: @escaping @MainActor () -> Bool,
               onReady: @escaping @MainActor (Result) -> Void) -> Task<Void, Never>? {
        cancel()
        guard !Task.isCancelled, isAllowed() else { return nil }
        let request = revision
        let task = Task { [weak self] in
            defer { if self?.revision == request { self?.task = nil } }
            do {
                let result = try await operation()
                guard !Task.isCancelled, self?.revision == request, isAllowed() else { return }
                onReady(result)
            } catch {}
        }
        self.task = task
        return task
    }

    func cancel() {
        revision = UUID()
        task?.cancel()
        task = nil
    }

    deinit { task?.cancel() }
}

@MainActor
final class PhotoImageAnalysis: NSObject, ImageAnalysisInteractionDelegate {
    private struct Context: Equatable {
        let assetID: String
        let generation: UUID
        let imageID: ObjectIdentifier
    }

    private weak var imageView: UIImageView?
    private let analyzer: any PhotoImageAnalyzing
    private let request = PhotoImageAnalysisRequest<ImageAnalysis?>()
    private let interaction = ImageAnalysisInteraction()
    private let originallyInteractive: Bool
    private let onForeground: () -> Void
    private let notificationCenter: NotificationCenter
    private var context: Context?
    private var authorization: (() -> Bool)?
    private var observation = UUID()
    private var foregroundActive = UIApplication.shared.applicationState == .active
    private var notifications: [NSObjectProtocol] = []

    init(imageView: UIImageView, analyzer: (any PhotoImageAnalyzing)? = nil,
         notificationCenter: NotificationCenter = .default,
         onForeground: @escaping () -> Void = {}) {
        self.imageView = imageView
        self.analyzer = analyzer ?? SystemPhotoImageAnalyzer()
        originallyInteractive = imageView.isUserInteractionEnabled
        self.onForeground = onForeground
        self.notificationCenter = notificationCenter
        super.init()
        interaction.delegate = self
        notifications.append(notificationCenter.addObserver(
            forName: UIApplication.willResignActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.foregroundActive = false
                self?.clear()
            }
        })
        notifications.append(notificationCenter.addObserver(
            forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.foregroundActive = true
                self?.onForeground()
            }
        })
    }

    func update(image: UIImage?, assetID: String?, generation: UUID,
                isAllowed: @escaping () -> Bool) {
        guard analyzer.isSupported, foregroundActive, let imageView, imageView.window != nil,
              let image, image.images == nil, let assetID,
              generation == LocalSnapshot.generation, isAllowed() else {
            clear()
            return
        }
        let next = Context(assetID: assetID, generation: generation, imageID: ObjectIdentifier(image))
        authorization = isAllowed
        guard context != next else { return }
        clear()
        context = next
        authorization = isAllowed
        imageView.isUserInteractionEnabled = true
        interaction.preferredInteractionTypes = [.textSelection, .dataDetectors, .imageSubject, .visualLookUp]
        interaction.isSupplementaryInterfaceHidden = false
        imageView.addInteraction(interaction)
        observeAuthorization()
        let analyzer = analyzer
        request.start(operation: { try await analyzer.analyze(image) },
            isAllowed: { [weak self] in self?.isCurrent == true },
            onReady: { [weak self] analysis in self?.interaction.analysis = analysis })
    }

    func clear() {
        observation = UUID()
        request.cancel()
        context = nil
        authorization = nil
        interaction.resetTextSelection()
        interaction.analysis = nil
        interaction.preferredInteractionTypes = []
        interaction.isSupplementaryInterfaceHidden = true
        imageView?.removeInteraction(interaction)
        imageView?.isUserInteractionEnabled = originallyInteractive
    }

    func layoutDidChange() {
        if interaction.view != nil { interaction.setContentsRectNeedsUpdate() }
    }

    func handlesTouch(at point: CGPoint) -> Bool {
        guard isCurrent, interaction.analysis != nil else { return false }
        return interaction.hasActiveTextSelection || interaction.hasInteractiveItem(at: point)
    }

    func interaction(_ interaction: ImageAnalysisInteraction, shouldBeginAt point: CGPoint,
                     for interactionType: ImageAnalysisInteraction.InteractionTypes) -> Bool {
        isCurrent && interaction.analysis != nil
    }

    private var isCurrent: Bool {
        guard foregroundActive, let context, context.generation == LocalSnapshot.generation,
              let imageView, imageView.window != nil, let image = imageView.image,
              ObjectIdentifier(image) == context.imageID else { return false }
        return authorization?() == true
    }

    private func observeAuthorization() {
        guard let context else { return }
        let token = UUID()
        observation = token
        withObservationTracking {
            _ = authorization?()
            // Account clearing invalidates this observable revision even when this asset has no snapshot.
            _ = LocalSnapshot.invalidationRevision(for: LocalSnapshot.Key.assetDetail(context.assetID))
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, self.observation == token else { return }
                if self.isCurrent { self.observeAuthorization() }
                else { self.clear() }
            }
        }
    }

    deinit {
        notifications.forEach { notificationCenter.removeObserver($0) }
    }
}
