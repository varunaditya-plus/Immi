import SwiftUI
import UIKit
import MapKit

/// SATU pan recognizer untuk seluruh interaksi panel info — area foto maupun
/// badan panel.
///
/// Sebelumnya panel dan foto punya gesture sendiri-sendiri (`DragGesture`
/// SwiftUI di panel, pan UIKit di foto). Dua masalah muncul dari situ:
///
/// 1. Gesture SwiftUI yang dipasang lewat `if/else` ViewBuilder mengganti
///    identitas subtree-nya setiap kali syaratnya berubah, jadi ScrollView di
///    dalam panel dibangun ulang di tengah drag — inilah getaran yang hanya
///    terasa saat menyeret di panel, bukan di foto.
/// 2. Dua recognizer dengan titik awal berbeda bisa sama-sama menggerakkan
///    tinggi panel.
///
/// Dengan satu recognizer, keduanya hilang. Keputusan boleh/tidaknya diambil di
/// `touchesBegan`/`touchesMoved` lalu dikunci — recognizer yang `.failed`
/// benar-benar keluar dari kompetisi, sehingga dismiss bawaan zoom transition
/// dan scroll milik panel tetap berfungsi normal.
struct PanelPanGesture: UIGestureRecognizerRepresentable {
    /// Tinggi panel sekarang; 0 = tertutup.
    var panelHeight: CGFloat
    /// true kalau daftar di dalam panel sedang bisa di-scroll (panel di detent
    /// tertinggi). Saat false, seluruh panel inert dan drag di mana pun
    /// mengubah tingginya.
    var panelScrollEnabled: Bool
    /// true kalau daftar itu sedang mentok di paling atas.
    var panelScrollAtTop: Bool
    var viewportSize: CGSize
    var onChanged: (CGFloat) -> Void
    /// (translation.y, velocity.y)
    var onEnded: (CGFloat, CGFloat) -> Void

    func makeUIGestureRecognizer(context: Context) -> PanelPanRecognizer {
        let recognizer = PanelPanRecognizer()
        recognizer.delegate = context.coordinator
        apply(to: recognizer)
        return recognizer
    }

    func updateUIGestureRecognizer(_ recognizer: PanelPanRecognizer, context: Context) {
        apply(to: recognizer)
    }

    private func apply(to recognizer: PanelPanRecognizer) {
        recognizer.panelHeight = panelHeight
        recognizer.panelScrollEnabled = panelScrollEnabled
        recognizer.panelScrollAtTop = panelScrollAtTop
        recognizer.resetForViewportChange(to: viewportSize)
    }

    func handleUIGestureRecognizerAction(_ recognizer: PanelPanRecognizer, context: Context) {
        let translation = recognizer.translation(in: recognizer.view).y
        switch recognizer.state {
        case .changed:
            onChanged(translation)
        case .ended, .cancelled, .failed:
            onEnded(translation, recognizer.velocity(in: recognizer.view).y)
        default:
            break
        }
    }

    func makeCoordinator(converter: CoordinateSpaceConverter) -> Coordinator {
        Coordinator()
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        /// Simultanitas ditolak HANYA untuk recognizer tombol, dan HANYA saat
        /// sentuhannya dimulai di dalam panel.
        ///
        /// Menolaknya secara menyeluruh membuat pan dismiss bawaan zoom
        /// transition di area foto ikut terganggu, sehingga swipe-ke-bawah
        /// untuk menutup jadi kadang jalan kadang tidak. Di sisi lain, kalau
        /// semuanya diizinkan, menyeret panel dari atas tombol "Add Location"
        /// menutup panel sekaligus menjalankan aksi tombolnya.
        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer
        ) -> Bool {
            // Paging, pinch zoom, dan scroll panel wajib tetap berbagi.
            if other.view is UIScrollView { return true }
            guard let pan = gestureRecognizer as? PanelPanRecognizer else { return true }
            return !pan.startedInPanel
        }
    }
}

final class PanelPanRecognizer: UIPanGestureRecognizer {
    var panelHeight: CGFloat = 0
    var panelScrollEnabled = false
    var panelScrollAtTop = true

    /// Sentuhan dimulai di dalam area panel, bukan di area foto.
    /// Dibaca juga oleh delegate untuk menentukan aturan simultanitas.
    private(set) var startedInPanel = false
    /// Arah dinilai sekali saja; setelah itu jari boleh bergerak ke mana pun.
    private var hasDecided = false
    private var viewportSize: CGSize = .zero

    func resetForViewportChange(to size: CGSize) {
        guard size != viewportSize else { return }
        viewportSize = size
        isEnabled = false
        isEnabled = true
    }

    override func reset() {
        super.reset()
        startedInPanel = false
        hasDecided = false
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesBegan(touches, with: event)
        guard let view, let touch = touches.first else { return }

        // Panel dipatok ke tepi bawah LAYAR (mengabaikan safe area), jadi
        // batasnya tidak boleh dihitung dari safe area — kalau tidak, area
        // deteksi meleset setinggi home indicator dan bottom toolbar.
        let panelTop = view.bounds.height - panelHeight
        startedInPanel = panelHeight > 0 && touch.location(in: view).y >= panelTop

        if shouldYieldToMap(at: view.hitTest(touch.location(in: view), with: event)) {
            state = .failed
            return
        }

        // Daftar sedang bisa di-scroll dan tidak di paling atas → serahkan
        // sepenuhnya ke scroll view.
        if startedInPanel && panelScrollEnabled && !panelScrollAtTop {
            state = .failed
        }
    }

    func shouldYieldToMap(at hitView: UIView?) -> Bool {
        guard panelScrollEnabled else { return false }
        var ancestor = hitView
        while let view = ancestor {
            if view is MKMapView { return true }
            ancestor = view.superview
        }
        return false
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesMoved(touches, with: event)
        guard !hasDecided else { return }

        let translation = translation(in: view)
        // Tunggu sampai ada gerakan yang cukup untuk menilai arah.
        guard max(abs(translation.x), abs(translation.y)) > 8 else { return }
        hasDecided = true

        if abs(translation.x) > abs(translation.y) {
            // Dominan horizontal: itu paging antar foto.
            state = .failed
            return
        }

        let isDownward = translation.y > 0

        // Panel tertutup: hanya arah ke atas yang boleh diklaim. Tarikan ke
        // bawah adalah gesture dismiss bawaan zoom transition.
        if panelHeight <= 0 && isDownward {
            state = .failed
            return
        }

        // Di dalam panel dengan daftar aktif dan mentok atas: tarikan ke atas
        // artinya user ingin men-scroll isinya, bukan membesarkan panel.
        if startedInPanel && panelScrollEnabled && !isDownward {
            state = .failed
        }
    }
}
