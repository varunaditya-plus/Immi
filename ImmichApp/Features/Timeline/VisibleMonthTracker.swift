import Observation
import SwiftUI

/// Tingkat ringkasan linimasa yang dipilih dari aksesori tab bar Photos.
///
/// Urutannya sengaja sama dengan kontrol milik Apple Photos: ringkasan terbesar
/// di kiri, seluruh foto di kanan.
enum TimelineMode: String, CaseIterable, Identifiable {
    case years
    case months
    case all

    var id: Self { self }

    var title: LocalizedStringKey {
        switch self {
        case .years: "Years"
        case .months: "Months"
        case .all: "All"
        }
    }
}

/// State yang menjembatani isi tab Photos dengan bottom bar ringkasnya.
@MainActor
@Observable
final class TimelineNavigationState {
    var mode: TimelineMode = .all
    private(set) var isTabBarMinimized = false
    /// Dipakai AppRouter untuk menyembunyikan picker compact yang hidup di luar
    /// TimelineView selama toolbar seleksi menggantikan tab bar.
    private(set) var isSelecting = false
    /// Naik saat mode yang sedang aktif diketuk lagi. Counter dipakai supaya dua
    /// permintaan beruntun tidak hilang seperti yang dapat terjadi pada Bool.
    private(set) var returnToNewestRequest = 0

    /// Picker sistem tidak mengirim `selection` ketika segmen aktif diketuk
    /// lagi. Semua ketukan masuk lewat sini agar reselect bekerja seperti tab
    /// Photos: pilih sekali, lalu ketuk segmen aktif sekali lagi untuk kembali.
    func tap(_ tappedMode: TimelineMode) {
        let wasAlreadySelected = mode == tappedMode
        mode = tappedMode

        if wasAlreadySelected {
            returnToNewestRequest += 1
        }
    }

    func setTabBarMinimized(_ isMinimized: Bool) {
        guard isTabBarMinimized != isMinimized else { return }
        isTabBarMinimized = isMinimized
    }

    func setSelecting(_ isSelecting: Bool) {
        guard self.isSelecting != isSelecting else { return }
        self.isSelecting = isSelecting
    }
}

/// Segmented control yang dipakai bottom bar ringkas milik Photos.
struct TimelineModePicker: View {
    let navigation: TimelineNavigationState
    var allTitle: LocalizedStringKey = "All"

    var body: some View {
        // Picker tetap menjadi satu-satunya penentu ukuran dan visual. Pembaca
        // tap dipasang sebagai overlay agar tidak pernah memperbesar capsule.
        ZStack {
            Picker("", selection: modeBinding) {
                ForEach(TimelineMode.allCases) { mode in
                    Text(mode == .all ? allTitle : mode.title).tag(mode)
                }
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .allowsHitTesting(false)
        }
        .overlay {
            GeometryReader { geometry in
                Color.clear
                    .contentShape(Rectangle())
                    .gesture(
                        SpatialTapGesture()
                            .onEnded { tap in
                                handleTap(
                                    x: tap.location.x,
                                    width: geometry.size.width)
                            })
                    // VoiceOver tetap mendapatkan nama dan nilai dari Picker
                    // native yang berada tepat di bawah bidang gesture ini.
                    .accessibilityHidden(true)
            }
        }
        .accessibilityElement(children: .contain)
    }

    private func handleTap(x: CGFloat, width: CGFloat) {
        guard width > 0 else { return }
        let modes = TimelineMode.allCases
        let segmentWidth = width / CGFloat(modes.count)
        let index = min(max(Int(x / segmentWidth), 0), modes.count - 1)
        navigation.tap(modes[index])
    }

    private var modeBinding: Binding<TimelineMode> {
        Binding(
            get: { navigation.mode },
            set: { newMode in
                // Jalur ini dipertahankan untuk aktivasi aksesibilitas dan
                // input non-sentuh yang tetap dikirim langsung oleh Picker.
                if navigation.mode != newMode {
                    navigation.tap(newMode)
                }
            }
        )
    }
}

/// Bulan yang sedang berada di tepi atas layar.
///
/// Dipisah dari `TimelineView` dengan sengaja. Nilainya berubah puluhan kali
/// selama satu gulir, dan sebagai `@State` milik layar itu setiap perubahannya
/// menggambar ulang seluruh body — termasuk grid berisi puluhan ribu sel —
/// hanya untuk memperbarui sebaris teks di toolbar.
///
/// Dengan `@Observable` di objek terpisah, hanya `VisibleMonthLabel` yang
/// berlangganan, jadi yang digambar ulang cuma label itu.
@MainActor
@Observable
final class VisibleMonthTracker {
    private(set) var title = ""
    /// Bulan yang sedang berada di tepi atas layar.
    ///
    /// Sekarang cukup satu arah: collection view sendiri yang memberi tahu
    /// section mana yang paling atas, jadi tidak perlu lagi menyimpulkannya dari
    /// arah gerak probe geometri.
    func show(_ section: TimelineSection) {
        setTitle(section.title)
    }

    /// Hanya ditulis kalau benar-benar berbeda: probe memanggil ini berkali-kali
    /// per detik dengan bulan yang sama.
    private func setTitle(_ new: String) {
        guard title != new else { return }
        title = new
    }
}

struct VisibleMonthLabel: View {
    let tracker: VisibleMonthTracker

    var body: some View {
        Text(tracker.title)
            .font(.headline.bold())
    }
}
