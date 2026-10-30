import SwiftUI
import UIKit
import Vision
import XCTest
@testable import ImmichApp

@MainActor
class SimulatorHostedTestCase: XCTestCase {
    var windows: [UIWindow] = []
    private weak var previousKeyWindow: UIWindow?

    override func tearDown() async throws {
        for window in windows.reversed() {
            if let root = window.rootViewController, root.presentedViewController != nil {
                await withCheckedContinuation { continuation in
                    root.dismiss(animated: false) { continuation.resume() }
                }
            }
            window.isHidden = true
            window.rootViewController = nil
        }
        windows.removeAll()
        previousKeyWindow?.makeKey()
        previousKeyWindow = nil
        try await super.tearDown()
    }

    @discardableResult
    func host<Content: View>(_ content: Content, style: UIUserInterfaceStyle = .light) async throws -> UIWindow {
        try await waitUntil("The app has an active scene for rendered testing") {
            UIApplication.shared.connectedScenes.contains { $0.activationState == .foregroundActive }
        }
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first(where: { $0.activationState == .foregroundActive }))
        if windows.isEmpty { previousKeyWindow = scene.windows.first(where: \.isKeyWindow) }
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        window.overrideUserInterfaceStyle = style
        let controller = UIHostingController(rootView: content
            .environment(MockSessionManager() as SessionManager)
            .environment(\.locale, Locale(identifier: "en_US")))
        window.rootViewController = controller
        window.makeKeyAndVisible()
        controller.view.frame = window.bounds
        controller.view.layoutIfNeeded()
        windows.append(window)
        return window
    }

    func waitUntil(_ message: String, _ predicate: () -> Bool,
                   file: StaticString = #filePath, line: UInt = #line) async throws {
        let deadline = Date().addingTimeInterval(4)
        while !predicate(), Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertTrue(predicate(), message, file: file, line: line)
    }

    func screenshot(_ window: UIWindow) async throws -> UIImage {
        try await Task.sleep(for: .milliseconds(150))
        window.layoutIfNeeded()
        let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        let attachment = XCTAttachment(image: image)
        attachment.lifetime = .keepAlways
        add(attachment)
        return image
    }

    func assertTextContrast(_ text: String, image: UIImage,
                                    file: StaticString = #filePath, line: UInt = #line) throws {
        let cgImage = try XCTUnwrap(image.cgImage, file: file, line: line)
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["en-US"]
        try VNImageRequestHandler(cgImage: cgImage).perform([request])
        let result = try XCTUnwrap(request.results?.first {
            $0.topCandidates(1).first?.string.localizedCaseInsensitiveContains(text) == true
        }, "Missing rendered text: \(text)", file: file, line: line)
        let width = cgImage.width, height = cgImage.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        try pixels.withUnsafeMutableBytes { buffer in
            let context = try XCTUnwrap(CGContext(data: buffer.baseAddress, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        let bounds = result.boundingBox
        let left = max(0, Int(bounds.minX * CGFloat(width)))
        let right = min(width, Int(bounds.maxX * CGFloat(width)))
        let top = max(0, Int((1 - bounds.maxY) * CGFloat(height)))
        let bottom = min(height, Int((1 - bounds.minY) * CGFloat(height)))
        var luminance: [Double] = []
        func linear(_ byte: UInt8) -> Double {
            let value = Double(byte) / 255
            return value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }
        for y in top..<bottom {
            for x in left..<right {
                let index = (y * width + x) * 4
                luminance.append(0.2126 * linear(pixels[index])
                    + 0.7152 * linear(pixels[index + 1]) + 0.0722 * linear(pixels[index + 2]))
            }
        }
        luminance.sort()
        XCTAssertFalse(luminance.isEmpty, file: file, line: line)
        guard !luminance.isEmpty else { return }
        let background = luminance[Int(Double(luminance.count - 1) * 0.1)]
        let foreground = luminance[Int(Double(luminance.count - 1) * 0.9)]
        XCTAssertGreaterThanOrEqual((foreground + 0.05) / (background + 0.05), 4.5,
            "\(text) needs readable text-to-background contrast", file: file, line: line)
    }
}
