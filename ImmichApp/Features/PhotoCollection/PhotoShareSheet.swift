import AVFoundation
import LinkPresentation
import SwiftUI
import Observation
import UIKit
import UniformTypeIdentifiers

struct PhotoShareSheet: UIViewControllerRepresentable {
    let urls: [URL]
    var assetIDs: [String] = []
    var sourceIDs: [String]? = nil
    var requestContext: SessionRequestContext? = nil
    var api: APIClient? = nil
    var isAllowed: @MainActor (String) -> Bool = { AssetVisibilityPolicy().allows(id: $0) }
    @Environment(SessionManager.self) private var session
    @Environment(\.dismiss) private var dismiss

    func makeUIViewController(context: Context) -> PhotoShareViewController {
        PhotoShareViewController(urls: urls, assetIDs: assetIDs, sourceIDs: sourceIDs, requestContext: requestContext,
            session: session, api: api,
            isAllowed: isAllowed, onFinish: { dismiss() })
    }

    func updateUIViewController(_ controller: PhotoShareViewController, context: Context) {}

    static func dismantleUIViewController(_ controller: PhotoShareViewController, coordinator: ()) {
        controller.cancelAndCleanup()
    }
}

@MainActor
final class PhotoShareViewController: UIViewController, UICollectionViewDataSource,
    UICollectionViewDelegate, UIDocumentPickerDelegate, UIAdaptivePresentationControllerDelegate {
    private let urls: [URL]
    private let assetIDs: [String]
    private let exportIDs: [String]
    private let api: APIClient
    private let context: SessionRequestContext
    private let generation = LocalSnapshot.generation
    private let isAllowed: (String) -> Bool
    private let onFinish: () -> Void
    private var selected: Set<Int>
    private(set) var options = PhotoExportOptions()
    private var task: Task<Void, Never>?
    private var generatedURLs: [URL] = []
    private var isClosed = false
    private var isBusy = false
    private var observation = UUID()
    private let countLabel = UILabel()
    private let locationLabel = UILabel()
    private let thumbnail = UIImageView()
    private let optionsButton = UIButton(type: .system)
    private let shareButton = UIButton(type: .system)
    private let copyButton = UIButton(type: .system)
    private let originalButton = UIButton(type: .system)
    private let activity = UIActivityIndicatorView(style: .medium)
    private let previews: UICollectionView
    private let thumbnails = NSCache<NSURL, UIImage>()
    private var previewTasks: [URL: Task<Void, Never>] = [:]
    private var failedPreviews = Set<URL>()

    init(urls: [URL], assetIDs: [String], sourceIDs: [String]? = nil, requestContext: SessionRequestContext? = nil,
         session: SessionManager, api: APIClient? = nil,
         isAllowed: @escaping (String) -> Bool, onFinish: @escaping () -> Void) {
        self.urls = urls
        self.assetIDs = assetIDs
        exportIDs = sourceIDs ?? AssetServerIdentity.exportIDs(for: assetIDs)
        self.api = api ?? APIClient(session: session)
        context = requestContext ?? session.snapshot
        self.isAllowed = isAllowed
        self.onFinish = onFinish
        selected = Set(urls.indices)
        let layout = UICollectionViewFlowLayout()
        layout.scrollDirection = .horizontal
        layout.itemSize = CGSize(width: 230, height: 260)
        layout.minimumLineSpacing = 10
        previews = UICollectionView(frame: .zero, collectionViewLayout: layout)
        super.init(nibName: nil, bundle: nil)
        thumbnails.countLimit = 12
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemGroupedBackground
        guard isCurrent else { return }
        let scroll = UIScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(scroll)
        let stack = UIStackView()
        stack.axis = .vertical
        stack.spacing = 20
        stack.translatesAutoresizingMaskIntoConstraints = false
        scroll.addSubview(stack)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            scroll.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor),
            stack.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor, constant: 20),
            stack.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor, constant: -20),
            stack.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor, constant: -16),
            stack.widthAnchor.constraint(equalTo: scroll.frameLayoutGuide.widthAnchor, constant: -40)
        ])
        stack.addArrangedSubview(header())
        previews.backgroundColor = .clear
        previews.showsHorizontalScrollIndicator = false
        previews.allowsMultipleSelection = true
        previews.dataSource = self
        previews.delegate = self
        previews.register(PhotoSharePreviewCell.self, forCellWithReuseIdentifier: "preview")
        previews.heightAnchor.constraint(equalToConstant: 260).isActive = true
        previews.accessibilityIdentifier = "photoShare.previews"
        stack.addArrangedSubview(previews)
        let quickActions = UIStackView()
        quickActions.distribution = .fillEqually
        quickActions.spacing = 16
        configure(copyButton, title: String(localized: "Copy"), symbol: "document.on.document", id: "photoShare.copy") {
            [weak self] in self?.prepare(.copy)
        }
        configure(shareButton, title: String(localized: "Share"), symbol: "square.and.arrow.up", id: "photoShare.continue") {
            [weak self] in self?.prepare(.share)
        }
        quickActions.addArrangedSubview(copyButton)
        quickActions.addArrangedSubview(shareButton)
        stack.addArrangedSubview(quickActions)
        configure(originalButton, title: String(localized: "Export Unmodified Original"), symbol: "folder",
            id: "photoShare.original") { [weak self] in self?.prepare(.original) }
        originalButton.isHidden = assetIDs.count != urls.count || assetIDs.isEmpty
        stack.addArrangedSubview(originalButton)
        if !originalButton.isHidden {
            let note = UILabel()
            note.text = String(localized: "Unmodified originals include their original metadata. Turn on Location to export them.")
            note.font = .preferredFont(forTextStyle: .footnote)
            note.textColor = .secondaryLabel
            note.numberOfLines = 0
            note.adjustsFontForContentSizeCategory = true
            stack.addArrangedSubview(note)
        }
        if assetIDs.count > urls.count {
            let warning = UILabel()
            warning.text = String(localized: "Some items could not be prepared. Only the available items are selected.")
            warning.font = .preferredFont(forTextStyle: .footnote)
            warning.textColor = .secondaryLabel
            warning.numberOfLines = 0
            warning.adjustsFontForContentSizeCategory = true
            stack.addArrangedSubview(warning)
        }
        activity.hidesWhenStopped = true
        stack.addArrangedSubview(activity)
        refreshSelection()
        observeAuthorization()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        if !isClosed, !isCurrent { finish() }
    }

    private func header() -> UIView {
        thumbnail.contentMode = .scaleAspectFill
        thumbnail.clipsToBounds = true
        thumbnail.layer.cornerRadius = 12
        thumbnail.widthAnchor.constraint(equalToConstant: 58).isActive = true
        thumbnail.heightAnchor.constraint(equalToConstant: 58).isActive = true
        countLabel.font = .preferredFont(forTextStyle: .headline)
        countLabel.adjustsFontForContentSizeCategory = true
        countLabel.numberOfLines = 0
        locationLabel.font = .preferredFont(forTextStyle: .subheadline)
        locationLabel.adjustsFontForContentSizeCategory = true
        locationLabel.textColor = .secondaryLabel
        locationLabel.numberOfLines = 0
        configure(optionsButton, title: String(localized: "Options"), symbol: "chevron.right",
            id: "photoShare.options") { [weak self] in self?.showOptions() }
        let labels = UIStackView(arrangedSubviews: [countLabel, locationLabel, optionsButton])
        labels.axis = .vertical
        labels.alignment = .leading
        labels.spacing = 5
        let close = UIButton(type: .system)
        close.setImage(UIImage(systemName: "xmark"), for: .normal)
        close.accessibilityLabel = String(localized: "Close")
        close.accessibilityIdentifier = "photoShare.close"
        close.configuration = .glass()
        close.addAction(UIAction { [weak self] _ in self?.finish() }, for: .touchUpInside)
        close.widthAnchor.constraint(equalToConstant: 42).isActive = true
        close.heightAnchor.constraint(equalToConstant: 42).isActive = true
        let row = UIStackView(arrangedSubviews: [thumbnail, labels, close])
        row.alignment = .top
        row.spacing = 14
        return row
    }

    private func configure(_ button: UIButton, title: String, symbol: String, id: String,
                           action: @escaping () -> Void) {
        var configuration = UIButton.Configuration.glass()
        configuration.title = title
        configuration.image = UIImage(systemName: symbol)
        configuration.imagePadding = 8
        configuration.contentInsets = NSDirectionalEdgeInsets(top: 14, leading: 14, bottom: 14, trailing: 14)
        button.configuration = configuration
        button.accessibilityIdentifier = id
        button.addAction(UIAction { _ in action() }, for: .touchUpInside)
    }

    private var selectedIndices: [Int] { selected.sorted() }
    private var selectedURLs: [URL] { selectedIndices.map { urls[$0] } }
    private var selectedIDs: [String] {
        guard assetIDs.count == urls.count, exportIDs.count == assetIDs.count else { return [] }
        return selectedIndices.map { exportIDs[$0] }
    }
    private var isCurrent: Bool {
        !isClosed && exportIDs.count == assetIDs.count
            && generation == LocalSnapshot.generation && (try? api.checkCurrent(context)) != nil
            && AssetServerIdentity.exportIDs(for: assetIDs) == exportIDs
            && assetIDs.allSatisfy(isAllowed)
    }

    private func observeAuthorization() {
        let revision = observation
        withObservationTracking {
            _ = api.session.snapshot
            _ = SwiftDataManager.shared.backupMappingRevision
            for id in assetIDs { _ = LocalSnapshot.invalidationRevision(for: LocalSnapshot.Key.assetDetail(id)) }
            _ = isCurrent
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, !self.isClosed, self.observation == revision else { return }
                if self.isCurrent { self.observeAuthorization() } else { self.finish() }
            }
        }
    }

    private func refreshSelection() {
        let files = selectedURLs
        let videoCount = files.filter { PhotoExportService.contentType(of: $0).conforms(to: .movie) }.count
        if videoCount == 0 {
            countLabel.text = files.count == 1 ? String(localized: "1 Photo Selected")
                : String(localized: "\(files.count) Photos Selected")
        } else if videoCount == files.count {
            countLabel.text = files.count == 1 ? String(localized: "1 Video Selected")
                : String(localized: "\(files.count) Videos Selected")
        }
        else { countLabel.text = String(localized: "\(files.count) Items Selected") }
        var copy = copyButton.configuration
        copy?.title = videoCount == 0 ? String(localized: "Copy Photos") : String(localized: "Copy Items")
        if files.count == 1 { copy?.title = videoCount == 0 ? String(localized: "Copy Photo") : String(localized: "Copy Video") }
        copyButton.configuration = copy
        var original = originalButton.configuration
        original?.title = files.count == 1 ? String(localized: "Export Unmodified Original")
            : String(localized: "Export Unmodified Originals")
        originalButton.configuration = original
        locationLabel.text = options.includeLocation
            ? String(localized: "Location Is Included") : String(localized: "Location Is Not Included")
        thumbnail.image = files.first.flatMap(preview)
        for button in [copyButton, shareButton, originalButton] { button.isEnabled = !isBusy && !files.isEmpty }
        originalButton.isEnabled = originalButton.isEnabled && options.includeLocation
        optionsButton.isEnabled = !isBusy
        previews.isUserInteractionEnabled = !isBusy
    }

    private func preview(_ url: URL) -> UIImage? {
        if let cached = thumbnails.object(forKey: url as NSURL) { return cached }
        if PhotoExportService.contentType(of: url).conforms(to: .movie) {
            prepareVideoPreview(url)
            return nil
        }
        if let image = SharePreviewThumbnail.image(at: url) {
            thumbnails.setObject(image, forKey: url as NSURL)
            return image
        }
        return nil
    }

    private func prepareVideoPreview(_ url: URL) {
        guard previewTasks[url] == nil, !failedPreviews.contains(url), isCurrent else { return }
        previewTasks[url] = Task { [weak self] in
            let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: 600, height: 600)
            defer { self?.previewTasks[url] = nil }
            do {
                let (image, _) = try await generator.image(at: .zero)
                guard let self, self.isCurrent, !Task.isCancelled else { return }
                let thumbnail = UIImage(cgImage: image)
                self.thumbnails.setObject(thumbnail, forKey: url as NSURL)
                let paths = self.previews.indexPathsForVisibleItems.filter { self.urls[$0.item] == url }
                self.previews.reloadItems(at: paths)
                if self.selectedURLs.first == url { self.thumbnail.image = thumbnail }
            } catch {
                if let self, !Task.isCancelled { self.failedPreviews.insert(url) }
            }
        }
    }

    private func showOptions() {
        guard !isBusy else { return }
        let controller = UIHostingController(rootView: PhotoShareOptionsView(options: options) { [weak self] options in
            guard let self else { return }
            self.options = options
            self.refreshSelection()
            self.dismiss(animated: true)
        })
        present(controller, animated: true)
    }

    private enum Action { case share, copy, original }

    private func prepare(_ action: Action) {
        guard !isBusy, isCurrent, !selected.isEmpty else { return }
        guard action != .original || (options.includeLocation && !selectedIDs.isEmpty) else { return }
        isBusy = true
        refreshSelection()
        activity.startAnimating()
        let sources = selectedURLs, ids = selectedIDs, options = options
        task = Task { [weak self] in
            guard let self else { return }
            var owned: [URL] = []
            defer { TemporaryMediaStore.remove(owned); self.task = nil }
            do {
                let exports: [PhotoExportRepresentations]
                if action == .original {
                    let originals = try await self.originalFiles(ids)
                    owned += originals
                    guard originals.count == sources.count else { throw PhotoShareError.incomplete }
                    exports = originals.map { .init(fileURL: $0, compatibleURL: nil, ownedURLs: []) }
                } else {
                    var prepared: [PhotoExportRepresentations] = []
                    for source in sources {
                        try Task.checkCancellation()
                        let file = try await PhotoExportService.prepare(source, options: options)
                        owned += file.ownedURLs
                        prepared.append(file)
                    }
                    exports = prepared
                }
                try Task.checkCancellation()
                guard self.isCurrent else { throw CancellationError() }
                if action == .copy {
                    var items: [[MediaCopy.Item]] = []
                    for file in exports {
                        let urls = [file.fileURL, file.compatibleURL].compactMap { $0 }
                        items.append(try await MediaCopy.prepare(urls.map {
                            .init(url: $0, isVideo: PhotoExportService.contentType(of: $0).conforms(to: .movie))
                        }))
                    }
                    try Task.checkCancellation()
                    guard self.isCurrent else { throw CancellationError() }
                    MediaCopy.writeRepresentations(items)
                    self.finish()
                } else {
                    self.generatedURLs = owned
                    owned.removeAll()
                    if action == .original { self.presentOriginals(exports.map(\.fileURL)) }
                    else { self.presentActivity(exports) }
                }
            } catch {
                self.setIdle()
                if self.isCurrent, !Task.isCancelled, !(error is CancellationError) { self.showError(error) }
            }
        }
    }

    func activityConfiguration(for files: [PhotoExportRepresentations]) -> UIActivityItemsConfiguration {
        let providers = files.map { file in
            Self.itemProvider(for: file, isAllowed: { [weak self] in self?.isCurrent == true })
        }
        let configuration = UIActivityItemsConfiguration(itemProviders: providers)
        configuration.metadataProvider = { [weak self] key in
            guard let self, self.isCurrent, key == .title, let first = files.first else { return nil }
            return files.count == 1 ? first.fileURL.deletingPathExtension().lastPathComponent : self.countLabel.text
        }
        configuration.perItemMetadataProvider = { [weak self] index, key in
            guard let self, self.isCurrent, key == .linkPresentationMetadata,
                  files.indices.contains(index) else { return nil }
            let file = files[index].fileURL
            let metadata = LPLinkMetadata()
            metadata.title = file.deletingPathExtension().lastPathComponent
            if let image = self.preview(file) { metadata.imageProvider = NSItemProvider(object: image) }
            return metadata
        }
        return configuration
    }

    private func presentActivity(_ files: [PhotoExportRepresentations]) {
        let configuration = activityConfiguration(for: files)
        let controller = UIActivityViewController(activityItemsConfiguration: configuration)
        controller.popoverPresentationController?.sourceView = shareButton
        controller.popoverPresentationController?.sourceRect = shareButton.bounds
        controller.completionWithItemsHandler = { [weak self] _, completed, _, _ in
            self?.cleanupGenerated()
            self?.setIdle()
            if completed { self?.finish() }
        }
        present(controller, animated: true)
        controller.presentationController?.delegate = self
    }

    private func originalFiles(_ ids: [String]) async throws -> [URL] {
        var files: [URL] = []
        do {
            for id in ids {
                try Task.checkCancellation()
                guard isCurrent else { throw CancellationError() }
                if LocalPhotoLibrary.isLocal(id) {
                    guard let file = await LocalPhotoLibrary.shared.exportFile(for: id, unmodified: true) else {
                        throw PhotoShareError.incomplete
                    }
                    defer { try? FileManager.default.removeItem(at: file.url) }
                    files.append(try TemporaryMediaStore.adoptShareFile(at: file.url, suggestedFilename: file.filename))
                } else {
                    let downloaded = await AssetDetailRepository(api: api).shareOriginalFiles([id])
                    files += downloaded
                    guard downloaded.count == 1 else { throw PhotoShareError.incomplete }
                }
            }
            try Task.checkCancellation()
            guard isCurrent else { throw CancellationError() }
            return files
        } catch {
            TemporaryMediaStore.remove(files)
            throw error
        }
    }

    static func itemProvider(for file: PhotoExportRepresentations,
                             isAllowed: @escaping @MainActor () -> Bool) -> NSItemProvider {
        let provider = NSItemProvider()
        provider.suggestedName = file.fileURL.deletingPathExtension().lastPathComponent
        var seen = Set<String>()
        for url in [file.fileURL, file.compatibleURL].compactMap({ $0 }) {
            let type = PhotoExportService.contentType(of: url).identifier
            guard seen.insert(type).inserted else { continue }
            provider.registerFileRepresentation(forTypeIdentifier: type, fileOptions: [], visibility: .all) { completion in
                let progress = Progress(totalUnitCount: 1)
                let task = Task { @MainActor in
                    guard isAllowed(), !Task.isCancelled, FileManager.default.fileExists(atPath: url.path) else {
                        completion(nil, false, CancellationError()); return
                    }
                    completion(url, false, nil)
                    progress.completedUnitCount = 1
                }
                progress.cancellationHandler = { task.cancel() }
                return progress
            }
        }
        return provider
    }

    private func presentOriginals(_ files: [URL]) {
        let controller = UIDocumentPickerViewController(forExporting: files, asCopy: true)
        controller.delegate = self
        present(controller, animated: true)
        controller.presentationController?.delegate = self
    }

    func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
        cleanupGenerated()
        setIdle()
    }

    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        cleanupGenerated()
        finish()
    }

    func presentationControllerDidDismiss(_ presentationController: UIPresentationController) {
        cleanupGenerated()
        setIdle()
    }

    private func showError(_ error: Error) {
        let alert = UIAlertController(title: String(localized: "Action Failed"),
            message: error.localizedDescription, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: String(localized: "OK"), style: .default))
        present(alert, animated: true)
    }

    private func setIdle() {
        isBusy = false
        activity.stopAnimating()
        refreshSelection()
    }

    private func cleanupGenerated() {
        TemporaryMediaStore.remove(generatedURLs)
        generatedURLs.removeAll()
    }

    private func finish() {
        cancelAndCleanup()
        onFinish()
    }

    func cancelAndCleanup() {
        isClosed = true
        thumbnail.image = nil
        viewIfLoaded?.isHidden = true
        var presented = presentedViewController
        while let controller = presented {
            controller.viewIfLoaded?.isHidden = true
            presented = controller.presentedViewController
        }
        observation = UUID()
        task?.cancel()
        task = nil
        cleanupGenerated()
        TemporaryMediaStore.remove(urls)
        thumbnails.removeAllObjects()
        previewTasks.values.forEach { $0.cancel() }
        previewTasks.removeAll()
        failedPreviews.removeAll()
    }

    func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int { urls.count }

    func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
        let cell = collectionView.dequeueReusableCell(withReuseIdentifier: "preview", for: indexPath) as! PhotoSharePreviewCell
        cell.configure(image: preview(urls[indexPath.item]), selected: selected.contains(indexPath.item))
        if selected.contains(indexPath.item) {
            collectionView.selectItem(at: indexPath, animated: false, scrollPosition: [])
        } else {
            collectionView.deselectItem(at: indexPath, animated: false)
        }
        cell.onActivate = { [weak self] in
            guard let self else { return false }
            self.setSelected(indexPath.item, to: !self.selected.contains(indexPath.item))
            return true
        }
        cell.accessibilityLabel = String(localized: "Item \(indexPath.item + 1)")
        cell.accessibilityTraits = selected.contains(indexPath.item) ? [.button, .selected] : .button
        return cell
    }

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        setSelected(indexPath.item, to: true)
    }

    func collectionView(_ collectionView: UICollectionView, didDeselectItemAt indexPath: IndexPath) {
        setSelected(indexPath.item, to: false)
    }

    private func setSelected(_ index: Int, to value: Bool) {
        if value { selected.insert(index) } else { selected.remove(index) }
        previews.reloadItems(at: [IndexPath(item: index, section: 0)])
        refreshSelection()
    }
}

private final class PhotoSharePreviewCell: UICollectionViewCell {
    var onActivate: (() -> Bool)?
    private let image = UIImageView()
    private let check = UIImageView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        contentView.backgroundColor = .secondarySystemGroupedBackground
        contentView.layer.cornerRadius = 16
        contentView.clipsToBounds = true
        image.contentMode = .scaleAspectFit
        image.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(image)
        check.translatesAutoresizingMaskIntoConstraints = false
        check.tintColor = .systemBlue
        check.backgroundColor = .systemBackground
        check.layer.cornerRadius = 14
        contentView.addSubview(check)
        NSLayoutConstraint.activate([
            image.topAnchor.constraint(equalTo: contentView.topAnchor),
            image.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            image.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            image.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            check.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -12),
            check.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -12),
            check.widthAnchor.constraint(equalToConstant: 28), check.heightAnchor.constraint(equalToConstant: 28)
        ])
        isAccessibilityElement = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(image: UIImage?, selected: Bool) {
        self.image.image = image ?? UIImage(systemName: "photo.on.rectangle")
        check.image = UIImage(systemName: selected ? "checkmark.circle.fill" : "circle")
    }

    override func accessibilityActivate() -> Bool { onActivate?() ?? false }
}

private enum PhotoShareError: LocalizedError {
    case incomplete
    var errorDescription: String? { String(localized: "Some items could not be prepared. Please try again.") }
}
