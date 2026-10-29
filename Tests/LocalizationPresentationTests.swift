import SwiftUI
import UIKit
import Vision
import XCTest
@testable import ImmichApp

@MainActor
final class LocalizationPresentationTests: XCTestCase {
    private var window: UIWindow?
    private weak var previousKeyWindow: UIWindow?

    override func tearDown() async throws {
        window?.isHidden = true
        window?.rootViewController = nil
        window = nil
        previousKeyWindow?.makeKey()
        previousKeyWindow = nil
        try await super.tearDown()
    }

    func testFreeUpSpaceStepHeaderUsesTheFrenchLocale() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first(where: { $0.activationState == .foregroundActive }))
        previousKeyWindow = scene.windows.first(where: \.isKeyWindow)
        let header = FreeUpSpaceView().stepHeader(1, title: "Select Cutoff Date", active: true)
        let host = UIHostingController(rootView: header
            .padding()
            .environment(\.locale, Locale(identifier: "fr_FR"))
            .environment(\.colorScheme, .light))
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 300)
        window.rootViewController = host
        window.makeKeyAndVisible()
        host.view.frame = window.bounds
        self.window = window

        let deadline = ContinuousClock.now + .seconds(3)
        var text = ""
        var screenshot: UIImage?
        repeat {
            try await Task.sleep(for: .milliseconds(150))
            window.layoutIfNeeded()
            let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
                window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
            }
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.recognitionLanguages = ["fr-FR", "en-US"]
            try VNImageRequestHandler(cgImage: try XCTUnwrap(image.cgImage)).perform([request])
            text = normalized((request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
                .joined(separator: " "))
            screenshot = image
            if text.contains("choisir la date limite") { break }
        } while ContinuousClock.now < deadline

        if let screenshot {
            let attachment = XCTAttachment(image: screenshot)
            attachment.lifetime = .keepAlways
            add(attachment)
        }
        XCTAssertTrue(text.contains("choisir la date limite"), "The actual heading must be in French. Visible text: \(text)")
        XCTAssertFalse(text.contains("select cutoff date"), "A translated catalog alone must not leave the heading in English")
    }

    private func normalized(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "fr_FR"))
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
    }
}
