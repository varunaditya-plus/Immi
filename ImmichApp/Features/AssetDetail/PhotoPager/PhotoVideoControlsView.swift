import SwiftUI
import UIKit

/// Keadaan pemutaran yang perlu diketahui bar kontrol.
struct PhotoPlaybackState: Equatable {
    var isVideo = false
    var isPlaying = false
    var isMuted = false
    /// Detik yang sudah berjalan.
    var time: Double = 0
    var duration: Double = 0
    /// Bagian file yang sudah tersedia untuk diputar, 0…1.
    var bufferedFraction: Float = 0
    var rate: Float = 1
    var isLooping = false
    var availableRates: [Float] = [1]
    var hasAudio: Bool? = nil

    var fraction: Float {
        guard duration.isFinite, duration > 0, time.isFinite else { return 0 }
        return Float(min(max(time / duration, 0), 1))
    }
}

/// Yang dikabari pager setiap keadaan pemutaran berubah.
@MainActor
protocol PhotoPlaybackObserver: AnyObject {
    func playbackDidUpdate(_ state: PhotoPlaybackState)
}

/// Bar kontrol video: putar/jeda, geser posisi, dan bisu.
///
/// Kontrolnya bawaan semua — `UISlider` dan SF Symbols — bukan gambar sendiri,
/// jadi perilakunya (area sentuh, umpan balik tekan, dukungan aksesibilitas)
/// sama persis dengan yang diharapkan di iOS.
struct PhotoVideoControlsView: UIViewRepresentable {
    /// Pager yang memegang pemutarnya.
    ///
    /// Disambungkan LANGSUNG, tanpa melewati `@State`: posisi pemutaran berubah
    /// beberapa kali per detik, dan menyalurkannya lewat SwiftUI berarti
    /// membangun ulang seluruh body layar detail sesering itu juga.
    let pager: PhotoPagerController

    func makeUIView(context: Context) -> PhotoVideoControlsBar {
        let bar = PhotoVideoControlsBar()
        bar.attach(to: pager)
        return bar
    }

    func updateUIView(_ bar: PhotoVideoControlsBar, context: Context) {
        bar.attach(to: pager)
    }

    static func dismantleUIView(_ bar: PhotoVideoControlsBar, coordinator: ()) { bar.detach() }
}

final class PhotoVideoControlsBar: UIView {
    private let background = UIVisualEffectView(effect: UIGlassEffect(style: .regular))
    private let playButton = UIButton(type: .system)
    private let muteButton = UIButton(type: .system)
    private let slider = UISlider()
    private let bufferProgress = UIProgressView(progressViewStyle: .default)
    private let elapsedLabel = UILabel()
    private let remainingLabel = UILabel()
    private let times = UIStackView()

    private weak var pager: PhotoPagerController?
    private var state = PhotoPlaybackState()
    /// true selagi jari memegang slider — selama itu posisi dari pemutar
    /// diabaikan, kalau tidak nilainya tarik-menarik dengan jari.
    private var isScrubbing = false

    override init(frame: CGRect) {
        super.init(frame: frame)

        tintColor = .label
        background.clipsToBounds = true
        background.translatesAutoresizingMaskIntoConstraints = false
        addSubview(background)

        playButton.setImage(UIImage(systemName: "play.fill"), for: .normal)
        playButton.addTarget(self, action: #selector(togglePlay), for: .touchUpInside)
        playButton.accessibilityIdentifier = "video.playPause"

        muteButton.setImage(UIImage(systemName: "speaker.wave.2.fill"), for: .normal)
        muteButton.addTarget(self, action: #selector(toggleMute), for: .touchUpInside)
        muteButton.accessibilityIdentifier = "video.mute"

        slider.minimumValue = 0
        slider.maximumValue = 1
        slider.accessibilityLabel = String(localized: "Playback Position")
        slider.accessibilityIdentifier = "video.position"
        // Track kosong transparan supaya progres unduhan di belakang slider
        // tetap terlihat. Bagian yang sudah ditonton digambar oleh minimumTrack.
        slider.maximumTrackTintColor = .clear
        slider.addTarget(self, action: #selector(scrubbingBegan), for: .touchDown)
        slider.addTarget(self, action: #selector(scrubbed), for: .valueChanged)
        slider.addTarget(
            self, action: #selector(scrubbingEnded),
            for: [.touchUpInside, .touchUpOutside, .touchCancel])

        bufferProgress.trackTintColor = UIColor.secondaryLabel.withAlphaComponent(0.22)
        bufferProgress.translatesAutoresizingMaskIntoConstraints = false

        let timeline = UIView()
        timeline.addSubview(bufferProgress)
        slider.translatesAutoresizingMaskIntoConstraints = false
        timeline.addSubview(slider)
        NSLayoutConstraint.activate([
            bufferProgress.leadingAnchor.constraint(equalTo: timeline.leadingAnchor),
            bufferProgress.trailingAnchor.constraint(equalTo: timeline.trailingAnchor),
            bufferProgress.centerYAnchor.constraint(equalTo: timeline.centerYAnchor),
            slider.leadingAnchor.constraint(equalTo: timeline.leadingAnchor),
            slider.trailingAnchor.constraint(equalTo: timeline.trailingAnchor),
            slider.topAnchor.constraint(equalTo: timeline.topAnchor),
            slider.bottomAnchor.constraint(equalTo: timeline.bottomAnchor),
        ])
        for label in [elapsedLabel, remainingLabel] {
            label.font = UIFontMetrics(forTextStyle: .caption2)
                .scaledFont(for: .monospacedDigitSystemFont(ofSize: 11, weight: .regular))
            label.adjustsFontForContentSizeCategory = true
            label.textColor = .secondaryLabel
            label.isAccessibilityElement = false
        }
        for view in [elapsedLabel, UIView(), remainingLabel] { times.addArrangedSubview(view) }
        times.isHidden = true
        let transport = UIStackView(arrangedSubviews: [timeline, times])
        transport.axis = .vertical
        let stack = UIStackView(arrangedSubviews: [playButton, transport, muteButton])
        stack.axis = .horizontal
        stack.alignment = .center
        stack.spacing = 4
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        // Tombolnya tidak boleh ikut melar; yang mengisi sisa lebar adalah
        // slider-nya.
        for button in [playButton, muteButton] {
            button.setContentHuggingPriority(.required, for: .horizontal)
            button.setPreferredSymbolConfiguration(
                UIImage.SymbolConfiguration(pointSize: 18, weight: .medium), forImageIn: .normal)
            NSLayoutConstraint.activate([
                button.widthAnchor.constraint(equalToConstant: 44),
                button.heightAnchor.constraint(equalToConstant: 44),
            ])
        }

        NSLayoutConstraint.activate([
            background.leadingAnchor.constraint(equalTo: leadingAnchor),
            background.trailingAnchor.constraint(equalTo: trailingAnchor),
            background.topAnchor.constraint(equalTo: topAnchor),
            background.bottomAnchor.constraint(equalTo: bottomAnchor),

            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) tidak dipakai") }

    override func layoutSubviews() {
        super.layoutSubviews()
        background.layer.cornerRadius = bounds.height / 2
        bufferProgress.progressTintColor = tintColor
    }

    func attach(to pager: PhotoPagerController) {
        guard self.pager !== pager else { return }
        detach()
        self.pager = pager
        pager.playbackObserver = self
        pager.reportPlaybackState()
    }

    func detach() {
        if pager?.playbackObserver === self { pager?.playbackObserver = nil }
        if isScrubbing { pager?.endScrubbing() }
        pager = nil
        isScrubbing = false
        times.isHidden = true
    }

    // MARK: - Aksi

    @objc private func togglePlay() {
        pager?.togglePlayback()
    }

    @objc private func toggleMute() {
        pager?.toggleMute()
    }

    @objc private func scrubbingBegan() {
        isScrubbing = true
        times.isHidden = false
        pager?.beginScrubbing()
    }

    @objc private func scrubbed() {
        guard state.duration > 0 else { return }
        pager?.seek(toFraction: Double(slider.value))
    }

    @objc private func scrubbingEnded() {
        isScrubbing = false
        times.isHidden = true
        pager?.endScrubbing()
    }

    private func timeText(_ value: Double) -> String {
        let seconds = value.isFinite ? Int(min(max(value, 0), 35_999_999)) : 0
        if seconds >= 3600 { return String(format: "%d:%02d:%02d", seconds / 3600, (seconds / 60) % 60, seconds % 60) }
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}

// MARK: - Keadaan

extension PhotoVideoControlsBar: PhotoPlaybackObserver {
    func playbackDidUpdate(_ state: PhotoPlaybackState) {
        self.state = state

        let playSymbol = state.isPlaying ? "pause.fill" : "play.fill"
        playButton.setImage(UIImage(systemName: playSymbol), for: .normal)
        playButton.accessibilityLabel = state.isPlaying ? String(localized: "Pause") : String(localized: "Play")

        let hasNoAudio = state.hasAudio == false
        let muteSymbol = state.isMuted || hasNoAudio ? "speaker.slash.fill" : "speaker.wave.2.fill"
        muteButton.setImage(UIImage(systemName: muteSymbol), for: .normal)
        muteButton.isEnabled = !hasNoAudio
        muteButton.accessibilityLabel = hasNoAudio ? String(localized: "No Audio")
            : state.isMuted ? String(localized: "Unmute") : String(localized: "Mute")
        elapsedLabel.text = timeText(state.time)
        remainingLabel.text = "−" + timeText(state.duration - state.time)
        slider.accessibilityValue = String(localized: "\(timeText(state.time)) of \(timeText(state.duration))")

        slider.isEnabled = state.duration > 0
        bufferProgress.setProgress(state.bufferedFraction, animated: false)
        guard !isScrubbing else { return }
        slider.setValue(state.fraction, animated: false)
    }
}
