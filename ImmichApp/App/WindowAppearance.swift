import SwiftUI
import UIKit

struct WindowAppearance: UIViewRepresentable {
    let theme: String

    func makeUIView(context: Context) -> AppearanceView {
        AppearanceView()
    }

    func updateUIView(_ view: AppearanceView, context: Context) {
        switch theme {
        case "light": view.style = .light
        case "dark": view.style = .dark
        default: view.style = .unspecified
        }
    }

    final class AppearanceView: UIView {
        var style: UIUserInterfaceStyle = .unspecified {
            didSet { applyAppearance() }
        }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            applyAppearance()
        }

        private func applyAppearance() {
            guard let window, window.overrideUserInterfaceStyle != style else { return }
            // Reset the window override as well as its presented sheets when
            // switching back to System; a nil SwiftUI preference can linger.
            window.overrideUserInterfaceStyle = style
        }
    }
}
