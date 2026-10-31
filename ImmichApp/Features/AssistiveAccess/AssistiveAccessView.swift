import SwiftUI
import UIKit
import AVKit

/// Root yang hanya dipakai oleh `AssistiveAccess` scene di `ImmichApp`.
struct AssistiveAccessRouter: View {
    @Environment(SessionManager.self) private var session
    @AppStorage(AssistiveAccessPreferences.showsHomeKey)
    private var showsHome = AssistiveAccessPreferences.defaultShowsHome
    @AppStorage(AssistiveAccessPreferences.showsFavoritesKey)
    private var showsFavorites = AssistiveAccessPreferences.defaultShowsFavorites
    @AppStorage(AssistiveAccessPreferences.albumIDKey)
    private var albumID = ""
    @AppStorage(AssistiveAccessPreferences.albumNameKey)
    private var albumName = ""

    @State private var viewModel: AssistiveAccessViewModel?

    var body: some View {
        Group {
            if session.isLoggedIn {
                if let viewModel {
                    AssistiveAccessContentView(
                        viewModel: viewModel,
                        showsHome: showsHome,
                        showsFavorites: showsFavorites,
                        albumID: albumID,
                        albumName: albumName)
                } else {
                    ProgressView("Loading Photos")
                }
            } else {
                ContentUnavailableView(
                    "Sign In Required",
                    systemImage: "person.crop.circle.badge.exclamationmark",
                    description: Text("Exit Assistive Access and sign in to Immich first."))
            }
        }
        .task(id: loadID) {
            guard session.isLoggedIn else { return }
            let model = viewModel ?? AssistiveAccessViewModel(session: session)
            viewModel = model
            await model.load(
                showsFavorites: showsFavorites,
                albumID: albumID)
        }
    }

    private var loadID: String {
        "\(session.isLoggedIn)-\(showsFavorites)-\(albumID)"
    }
}

private struct AssistiveAccessContentView: View {
    let viewModel: AssistiveAccessViewModel
    let showsHome: Bool
    let showsFavorites: Bool
    let albumID: String
    let albumName: String

    var body: some View {
        NavigationStack {
            if showsHome {
                home
            } else {
                photoGrid(
                    title: String(localized: "Photos"),
                    systemImage: "photo.on.rectangle.angled",
                    assets: viewModel.photos)
            }
        }
    }

    /// `List` sengaja dipakai apa adanya. Di dalam Assistive Access scene, iOS
    /// sendiri yang mengubah daftar ini menjadi Row atau Grid sesuai pilihan
    /// supporter di Settings.
    private var home: some View {
        List {
            NavigationLink {
                photoGrid(
                    title: String(localized: "Photos"),
                    systemImage: "photo.on.rectangle.angled",
                    assets: viewModel.photos)
            } label: {
                Label("Photos", systemImage: "photo.on.rectangle.angled")
            }

            if showsFavorites {
                NavigationLink {
                    photoGrid(
                        title: String(localized: "Favorites"),
                        systemImage: "heart.fill",
                        assets: viewModel.favorites)
                } label: {
                    Label("Favorites", systemImage: "heart.fill")
                }
            }

            if !albumID.isEmpty {
                NavigationLink {
                    photoGrid(
                        title: displayedAlbumName,
                        systemImage: "rectangle.stack.fill",
                        assets: viewModel.album)
                } label: {
                    Label(displayedAlbumName, systemImage: "rectangle.stack.fill")
                }
            }
        }
        .navigationTitle("SelfPhotos")
        .assistiveAccessNavigationIcon(systemImage: "photo.stack.fill")
    }

    private var displayedAlbumName: String {
        albumName.isEmpty ? String(localized: "Album") : albumName
    }

    private func photoGrid(
        title: String,
        systemImage: String,
        assets: [AssetLite]
    ) -> some View {
        AssistiveAccessPhotoGrid(
            title: title,
            systemImage: systemImage,
            assets: assets,
            isLoading: viewModel.isLoading,
            thumbnailLoader: viewModel.thumbnails,
            previewLoader: viewModel.previews)
    }
}

private struct AssistiveAccessPhotoGrid: View {
    let title: String
    let systemImage: String
    let assets: [AssetLite]
    let isLoading: Bool
    let thumbnailLoader: PhotoThumbnailLoader
    let previewLoader: PhotoPreviewLoader

    private let columns = [
        GridItem(.flexible(minimum: 0), spacing: 4),
        GridItem(.flexible(minimum: 0), spacing: 4),
    ]

    var body: some View {
        Group {
            if assets.isEmpty, isLoading {
                ProgressView("Loading Photos")
            } else if assets.isEmpty {
                ContentUnavailableView(
                    "No Photos",
                    systemImage: systemImage)
            } else {
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 4) {
                        ForEach(assets) { asset in
                            NavigationLink {
                                AssistiveAccessPhotoDetail(
                                    asset: asset,
                                    loader: previewLoader)
                            } label: {
                                AssistiveAccessPhotoCell(
                                    asset: asset,
                                    loader: thumbnailLoader)
                            }
                            // Menjaga foto tetap menjadi petak, tidak diberi
                            // padding/background tombol Assistive Access.
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(4)
                }
                // Ujung bawah berisi foto terbaru dan menjadi posisi pembuka,
                // sedangkan foto lama tetap dapat dicapai dengan scroll naik.
                .defaultScrollAnchor(.bottom)
            }
        }
        .navigationTitle(title)
        .assistiveAccessNavigationIcon(systemImage: systemImage)
    }
}

private struct AssistiveAccessPhotoCell: View {
    let asset: AssetLite
    let loader: PhotoThumbnailLoader
    @State private var image: UIImage?

    var body: some View {
        // Bidang transparan ini menentukan ukuran 1:1 lebih dulu. Gambar hanya
        // menjadi overlay dan tidak boleh lagi menyumbang intrinsic ratio-nya
        // ke perhitungan LazyVGrid.
        Color.clear
            .aspectRatio(1, contentMode: .fit)
            .overlay {
                GeometryReader { proxy in
                    thumbnail
                        .frame(
                            width: proxy.size.width,
                            height: proxy.size.height)
                        .clipped()
                }
            }
            .background(Color(.secondarySystemFill))
            .clipShape(.rect(cornerRadius: 8))
            .contentShape(.rect)
            .accessibilityElement()
            .accessibilityLabel(accessibilityLabel)
            .task(id: asset.id) {
                if let cached = loader.cachedImage(for: asset.id) {
                    image = cached
                } else {
                    image = await loader.image(for: asset.id)
                }
            }

    }

    @ViewBuilder
    private var thumbnail: some View {
        ZStack(alignment: .bottomTrailing) {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else if let placeholder = ThumbHash.placeholder(for: asset.thumbhash) {
                Image(uiImage: placeholder)
                    .resizable()
                    .scaledToFill()
            } else {
                Color(.secondarySystemFill)
            }

            if asset.isVideo {
                Image(systemName: "play.fill")
                    .font(.caption.bold())
                    .foregroundStyle(.white)
                    .padding(7)
                    .background(.black.opacity(0.55), in: .circle)
                    .padding(6)
                    .accessibilityHidden(true)
            }
        }
    }

    private var accessibilityLabel: Text {
        let kind = asset.isVideo
            ? String(localized: "Video")
            : String(localized: "Photo")
        return Text("\(kind), \(asset.createdAt.formatted(date: .long, time: .omitted))")
    }
}

/// Detail read-only yang ringan untuk Assistive Access. Preview memakai jalur
/// gambar detail yang sama dengan app utama, tetapi seluruh aksi destruktif dan
/// panel kompleks sengaja tidak dibawa masuk.
private struct AssistiveAccessPhotoDetail: View {
    let asset: AssetLite
    let loader: PhotoPreviewLoader

    @State private var image: UIImage?
    @State private var isLoading = true
    @State private var player: AVPlayer?

    var body: some View {
        VStack(spacing: 16) {
            GeometryReader { _ in
                preview
            }

            Label {
                Text(asset.createdAt.formatted(date: .long, time: .shortened))
            } icon: {
                Image(systemName: "calendar")
            }
            .font(.headline)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding()
        .navigationTitle(asset.isVideo ? "Video" : "Photo")
        .assistiveAccessNavigationIcon(
            systemImage: asset.isVideo ? "video.fill" : "photo.fill")
        .task(id: asset.id) {
            VideoPlaybackLifecycle.stop(player)
            player = nil
            isLoading = true
            if let cached = loader.cachedImage(for: asset.id) {
                image = cached
            }

            // Video memakai player sistem dan langsung dimulai begitu sumber
            // lokal/server siap. Thumbnail di atas tetap menjadi poster selama
            // sumber itu disiapkan.
            if asset.isVideo,
               let playbackItem = await loader.playbackItem(for: asset.id) {
                guard !Task.isCancelled else {
                    playbackItem.asset.cancelLoading()
                    return
                }
                let autoplayPlayer = AVPlayer(
                    playerItem: playbackItem)
                player = autoplayPlayer
                isLoading = false
                // Beri VideoPlayer satu giliran untuk masuk hierarchy sebelum
                // playback dimulai, supaya frame pertama tidak terlewat.
                await Task.yield()
                guard !Task.isCancelled else {
                    VideoPlaybackLifecycle.stop(autoplayPlayer)
                    return
                }
                autoplayPlayer.play()
                return
            }

            if !loader.hasPreview(for: asset.id) {
                image = await loader.image(for: asset.id) ?? image
            }
            isLoading = false
        }
        .onDisappear {
            VideoPlaybackLifecycle.stop(player)
            player = nil
        }
    }

    @ViewBuilder
    private var preview: some View {
        ZStack {
            Color(.secondarySystemBackground)

            if asset.isVideo, let player {
                VideoPlayer(player: player)
                    .onAppear { player.play() }
            } else if let image {
                AssistiveAccessZoomableImage(image: image)
            } else if isLoading {
                ProgressView(asset.isVideo ? "Loading Video" : "Loading Photo")
            } else {
                ContentUnavailableView(
                    asset.isVideo ? "Video Unavailable" : "Photo Unavailable",
                    systemImage: asset.isVideo
                        ? "video.badge.exclamationmark"
                        : "photo.badge.exclamationmark")
            }

            if asset.isVideo, player == nil {
                Label("Video", systemImage: "play.fill")
                    .font(.headline)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(.black.opacity(0.6), in: .capsule)
                    .accessibilityHidden(true)
                    .allowsHitTesting(false)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipShape(.rect(cornerRadius: 16))
        // Control VideoPlayer harus tetap menjadi elemen accessibility native.
        // Foto tidak punya control anak, jadi cukup diumumkan sebagai satu item.
        .accessibilityElement(children: asset.isVideo ? .contain : .ignore)
        .accessibilityLabel(detailAccessibilityLabel, isEnabled: !asset.isVideo)
        .accessibilityHint(
            "Pinch or double tap to zoom",
            isEnabled: !asset.isVideo)
    }

    private var detailAccessibilityLabel: Text {
        let kind = asset.isVideo
            ? String(localized: "Video")
            : String(localized: "Photo")
        return Text("\(kind), \(asset.createdAt.formatted(date: .long, time: .shortened))")
    }
}

/// Zoom UIKit native memberikan pinch, pan, bounce, dan perhitungan viewport
/// yang sudah teruji sistem. Double tap menjadi jalur yang lebih sederhana
/// bagi pengguna yang kesulitan melakukan gesture dua jari.
private struct AssistiveAccessZoomableImage: UIViewRepresentable {
    let image: UIImage

    func makeUIView(context: Context) -> AssistiveAccessZoomScrollView {
        AssistiveAccessZoomScrollView()
    }

    func updateUIView(
        _ scrollView: AssistiveAccessZoomScrollView,
        context: Context
    ) {
        scrollView.setImage(image)
    }
}

@MainActor
private final class AssistiveAccessZoomScrollView: UIScrollView, UIScrollViewDelegate {
    private let zoomImageView = UIImageView()
    private var displayedImage: UIImage?
    private var laidOutSize = CGSize.zero

    override init(frame: CGRect) {
        super.init(frame: frame)

        delegate = self
        minimumZoomScale = 1
        maximumZoomScale = 5
        bouncesZoom = true
        decelerationRate = .fast
        showsHorizontalScrollIndicator = false
        showsVerticalScrollIndicator = false
        contentInsetAdjustmentBehavior = .never

        zoomImageView.contentMode = .scaleAspectFit
        zoomImageView.clipsToBounds = true
        addSubview(zoomImageView)

        let doubleTap = UITapGestureRecognizer(
            target: self,
            action: #selector(handleDoubleTap(_:)))
        doubleTap.numberOfTapsRequired = 2
        addGestureRecognizer(doubleTap)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) tidak dipakai")
    }

    func setImage(_ image: UIImage) {
        guard displayedImage !== image else { return }
        let isReplacingLoadedImage = displayedImage != nil
        displayedImage = image
        zoomImageView.image = image
        // Thumbnail dapat diganti preview tajam saat pengguna sedang zoom.
        // Pergantian kualitas itu tidak boleh melempar zoom kembali ke 1×.
        if !isReplacingLoadedImage { resetZoom() }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard bounds.size.width > 0, bounds.size.height > 0 else { return }

        if laidOutSize != bounds.size {
            laidOutSize = bounds.size
            resetZoom()
        }
        centerZoomedImage()
    }

    func viewForZooming(in scrollView: UIScrollView) -> UIView? {
        zoomImageView
    }

    func scrollViewDidZoom(_ scrollView: UIScrollView) {
        centerZoomedImage()
    }

    private func resetZoom() {
        setZoomScale(minimumZoomScale, animated: false)
        zoomImageView.frame = bounds
        contentSize = bounds.size
        contentInset = .zero
        contentOffset = .zero
    }

    private func centerZoomedImage() {
        let horizontal = max(0, (bounds.width - contentSize.width) / 2)
        let vertical = max(0, (bounds.height - contentSize.height) / 2)
        contentInset = UIEdgeInsets(
            top: vertical,
            left: horizontal,
            bottom: vertical,
            right: horizontal)
    }

    @objc
    private func handleDoubleTap(_ recognizer: UITapGestureRecognizer) {
        if zoomScale > minimumZoomScale + 0.01 {
            setZoomScale(minimumZoomScale, animated: true)
            return
        }

        let targetScale = min(2.5, maximumZoomScale)
        let point = recognizer.location(in: zoomImageView)
        let width = bounds.width / targetScale
        let height = bounds.height / targetScale
        zoom(
            to: CGRect(
                x: point.x - width / 2,
                y: point.y - height / 2,
                width: width,
                height: height),
            animated: true)
    }
}
