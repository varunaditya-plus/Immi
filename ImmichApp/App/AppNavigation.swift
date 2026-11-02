import Foundation
import Observation
import UIKit

/// Satu pintu masuk untuk navigasi dari luar hierarchy SwiftUI.
///
/// Widget, quick action Home Screen, dan URL scheme semuanya berakhir di sini.
/// Tujuannya disimpan sampai view yang tepat benar-benar siap mengonsumsinya,
/// sehingga cold start tidak kehilangan tap saat sesi masih dipulihkan.
@MainActor
@Observable
final class AppNavigation {
    static let shared = AppNavigation()

    enum Destination: Equatable {
        case favorites
        case search
        case memories
        case album(String)
    }

    private(set) var pendingDestination: Destination?

    private init() {}

    func open(_ destination: Destination) {
        pendingDestination = destination
    }

    func handle(_ url: URL) {
        // Keep legacy schemes valid for existing widgets and saved links.
        let acceptedSchemes = ["immi", "selfphotos", "immiches"]
        guard let scheme = url.scheme?.lowercased(),
              acceptedSchemes.contains(scheme)
        else { return }

        switch url.host?.lowercased() {
        case "favorites":
            open(.favorites)
        case "search":
            open(.search)
        case "memories":
            open(.memories)
        case "album":
            let id = url.pathComponents.dropFirst().first
            if let id, !id.isEmpty { open(.album(id)) }
        default:
            break
        }
    }

    func handle(_ shortcutItem: UIApplicationShortcutItem) {
        switch shortcutItem.type {
        case "xyz.0xmwehehe.ImmichApp.favorites":
            open(.favorites)
        case "xyz.0xmwehehe.ImmichApp.search":
            open(.search)
        default:
            break
        }
    }

    func consume(_ destination: Destination) {
        guard pendingDestination == destination else { return }
        pendingDestination = nil
    }
}
