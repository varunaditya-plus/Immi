import Observation
import SwiftUI
import TipKit

/// Journey singkat yang membantu pengguna memilih sumber backup.
///
/// Eligibility-nya tidak bergantung pada first login maupun server. Album lokal
/// adalah sumber kebenaran: selama belum ada satu pun album dipilih, journey
/// ditawarkan lagi pada sesi aplikasi berikutnya.
@MainActor
@Observable
final class BackupSetupJourney {
    enum Step: Equatable {
        case idle
        case profile
        case backupRow
    }

    static let shared = BackupSetupJourney()

    private(set) var step: Step = .idle
    private(set) var isCoachmarkVisible = false
    /// Naik setiap kali sebuah anchor perlu mempresentasikan TipKit baru.
    /// View memakai angka ini sebagai task identity supaya eligibility di-reset
    /// dahulu sebelum binding presentation dinyalakan.
    private(set) var presentationRequest = 0

    @ObservationIgnored private let hasSelectedAlbums: () -> Bool
    private var lastHadSelectedAlbums: Bool?
    private var suppressedForCurrentEmptySelection = false

    init(hasSelectedAlbums: (() -> Bool)? = nil) {
        self.hasSelectedAlbums = hasSelectedAlbums ?? {
            !LocalPhotoLibrary.shared.selectedAlbumIDs.isEmpty
        }
    }

    /// Dipanggil saat area utama muncul dan setiap kali pilihan album berubah.
    /// Pemanggilan berulang dengan keadaan yang sama tidak membuka kembali tip
    /// yang baru saja ditutup pada sesi yang sama.
    func refreshForAlbumSelection() {
        let hasAlbums = hasSelectedAlbums()
        defer { lastHadSelectedAlbums = hasAlbums }

        if hasAlbums {
            suppressedForCurrentEmptySelection = false
            deactivate()
            return
        }

        // Transisi dari "ada album" ke "kosong" adalah kebutuhan setup baru,
        // jadi penyelesaian sebelumnya tidak boleh menahannya.
        if lastHadSelectedAlbums == true {
            suppressedForCurrentEmptySelection = false
        }

        guard step == .idle, !suppressedForCurrentEmptySelection else { return }
        activate(at: .profile)
    }

    func advanceToBackupRow() {
        guard step == .profile, !hasSelectedAlbums() else { return }
        activate(at: .backupRow)
    }

    func dismissCoachmark() {
        isCoachmarkVisible = false
    }

    /// Jika Settings ditutup sebelum Backup dibuka, arahkan lagi dari avatar.
    func returnToProfileIfNeeded() {
        guard step == .backupRow, !hasSelectedAlbums() else { return }
        activate(at: .profile)
    }

    /// Dipanggil anchor setelah `Tip.resetEligibility()` selesai. Request lama
    /// tidak boleh membuka tip kalau pengguna sudah berpindah langkah.
    func markTipReady(for expectedStep: Step, request: Int) {
        guard step == expectedStep, presentationRequest == request else { return }
        isCoachmarkVisible = true
    }

    func finish() {
        suppressedForCurrentEmptySelection = !hasSelectedAlbums()
        deactivate()
    }

    private func activate(at step: Step) {
        self.step = step
        isCoachmarkVisible = false
        presentationRequest += 1
    }

    private func deactivate() {
        step = .idle
        isCoachmarkVisible = false
    }
}

struct BackupSetupProfileTip: Tip {
    var options: [any TipOption] {
        Tips.IgnoresDisplayFrequency(true)
    }

    var title: Text {
        Text("Keep Your Photos Safe")
    }

    var message: Text? {
        Text("Choose which albums to back up automatically from your profile.")
    }

    var image: Image? {
        Image(systemName: "icloud.and.arrow.up")
    }

    var actions: [Tips.Action] {
        Tips.Action(id: "setup", title: "Set Up Backup")
    }
}

/// TipKit memang dirancang untuk coach mark yang menempel pada kontrol sistem,
/// termasuk toolbar. Tombolnya tetap tombol profil biasa; TipKit hanya memberi
/// callout dengan ukuran, panah, dan spacing native milik iOS.
struct JourneyProfileButton: View {
    var isActive = true
    let openSettings: () -> Void

    @State private var journey = BackupSetupJourney.shared
    @State private var launch = AppLaunchState.shared
    @State private var anchorFrame = CGRect.zero
    @State private var isAnchorReady = false
    @State private var isOpeningSettings = false
    private let tip = BackupSetupProfileTip()

    var body: some View {
        Button(action: proceedToSettings) {
            ProfileAvatar(
                style: .toolbar,
                showsBackupState: true,
                isJourneyHighlighted: showsHighlight)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Profile and Settings")
        .onGeometryChange(for: CGRect.self) { proxy in
            proxy.frame(in: .global)
        } action: { newFrame in
            guard newFrame != anchorFrame else { return }
            anchorFrame = newFrame
            if !journey.isCoachmarkVisible {
                isAnchorReady = false
            }
        }
        .popoverTip(
            isAnchorReady ? tip : nil,
            isPresented: tipPresented,
            attachmentAnchor: .rect(.bounds),
            arrowEdge: .top,
            action: handleTipAction)
        .task(id: presentationTaskID) {
            // Pada login pertama toolbar dibangun bersamaan dengan transisi
            // onboarding dan splash. Menunggu launch siap mencegah TipKit
            // membaca frame awal tombol yang masih berada di sisi kiri.
            guard launch.isReady,
                  isActive,
                  journey.step == .profile,
                  hasUsableAnchorFrame
            else { return }

            let request = journey.presentationRequest
            let stableFrame = anchorFrame

            // Jangan berikan TipKit sebuah source view saat toolbar masih
            // berpindah posisi. Modifier dipasang ulang sesudah frame global
            // avatar tidak berubah sepanjang jeda stabilisasi ini.
            isAnchorReady = false
            try? await Task.sleep(for: .milliseconds(320))
            guard !Task.isCancelled,
                  stableFrame == anchorFrame,
                  launch.isReady,
                  isActive
            else { return }

            isAnchorReady = true
            await Task.yield()
            await tip.resetEligibility()
            guard !Task.isCancelled else { return }
            await Task.yield()
            journey.markTipReady(for: .profile, request: request)
        }
    }

    private var showsHighlight: Bool {
        isActive && journey.step == .profile
    }

    private var presentationTaskID: String {
        let x = Int(anchorFrame.minX.rounded())
        let y = Int(anchorFrame.minY.rounded())
        let width = Int(anchorFrame.width.rounded())
        let height = Int(anchorFrame.height.rounded())
        return "\(journey.presentationRequest)-\(isActive)-\(launch.isReady)-\(x)-\(y)-\(width)-\(height)"
    }

    /// Frame sementara toolbar pada login pertama biasanya nol atau berada di
    /// tepi kiri. Avatar profile valid selalu punya ukuran dan berada lebih
    /// jauh dari leading edge daripada lebarnya sendiri.
    private var hasUsableAnchorFrame: Bool {
        anchorFrame.width > 0
            && anchorFrame.height > 0
            && anchorFrame.minX > anchorFrame.width
            && anchorFrame.minY > 0
    }

    private var tipPresented: Binding<Bool> {
        Binding(
            get: {
                showsHighlight && journey.isCoachmarkVisible
            },
            set: { presented in
                if !presented, journey.step == .profile {
                    journey.dismissCoachmark()
                }
            })
    }

    private func handleTipAction(_ action: Tips.Action) {
        if action.id == "setup" { proceedToSettings() }
    }

    private func proceedToSettings() {
        guard !isOpeningSettings else { return }
        isOpeningSettings = true

        // Tip profile harus mati SEBELUM sheet mulai dipresentasikan. Kalau
        // urutannya terbalik, popover lama ikut terbawa ke atas sheet dan dapat
        // meninggalkan presentation layer yang menangkap tap setelah ditutup.
        if journey.step == .profile {
            tip.invalidate(reason: .actionPerformed)
            journey.advanceToBackupRow()
            Task { @MainActor in
                // `isPresented = false` memulai animasi dismissal, bukan
                // menyelesaikannya. Sheet baru aman masuk setelah popover lama
                // benar-benar keluar dari presentation hierarchy.
                try? await Task.sleep(for: .milliseconds(350))
                openSettings()
                await Task.yield()
                isOpeningSettings = false
            }
        } else {
            openSettings()
            isOpeningSettings = false
        }
    }
}

struct BackupSetupRowTip: Tip {
    var options: [any TipOption] {
        Tips.IgnoresDisplayFrequency(true)
    }

    var title: Text {
        Text("One More Step")
    }

    var message: Text? {
        Text("Open Back Up Photos to select your albums and turn on automatic backup.")
    }

    var image: Image? {
        Image(systemName: "arrow.up.circle.fill")
    }

    var actions: [Tips.Action] {
        Tips.Action(id: "open", title: "Open Backup")
    }
}
