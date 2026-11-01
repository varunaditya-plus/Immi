import UIKit
import Vision
import XCTest

@MainActor
class ViewerAdaptiveLayoutTestCase: SimulatorHostedTestCase {
    func resize(_ window: UIWindow, to size: CGSize) {
        window.frame.size = size
        window.rootViewController?.view.frame = window.bounds
        window.layoutIfNeeded()
    }

    func descendants(_ view: UIView) -> [UIView] {
        guard !view.isHidden, view.alpha > 0 else { return [] }
        return [view] + view.subviews.flatMap(descendants)
    }

    func accessibilityObject(_ label: String, in root: NSObject) -> NSObject? {
        var visited = Set<ObjectIdentifier>()
        func find(_ object: NSObject, depth: Int) -> NSObject? {
            guard depth < 45, visited.insert(ObjectIdentifier(object)).inserted else { return nil }
            if let view = object as? UIView, view.isHidden || view.alpha <= 0 { return nil }
            if object.accessibilityLabel == label { return object }
            if let view = object as? UIView {
                for child in view.subviews { if let found = find(child, depth: depth + 1) { return found } }
            }
            for case let child as NSObject in object.accessibilityElements ?? [] {
                if let found = find(child, depth: depth + 1) { return found }
            }
            let count = object.accessibilityElementCount()
            if (1...500).contains(count) {
                for index in 0..<count {
                    if let child = object.accessibilityElement(at: index) as? NSObject,
                       let found = find(child, depth: depth + 1) { return found }
                }
            }
            return nil
        }
        return find(root, depth: 0)
    }

    func scrollVertically(to object: NSObject, in window: UIWindow) throws {
        let frame = window.convert(object.accessibilityFrame, from: nil)
        guard !window.bounds.contains(frame) else { return }
        let scroll = try XCTUnwrap(descendants(window).compactMap { $0 as? UIScrollView }.first {
            $0.bounds.width > window.bounds.width * 0.7 && $0.contentSize.height > $0.bounds.height + 1
        }, "Overflowing editor or metadata content must have a vertical scrolling viewport")
        scroll.scrollRectToVisible(scroll.convert(frame, from: window).insetBy(dx: 0, dy: -8), animated: false)
        window.layoutIfNeeded()
    }

    func renderedStrings(_ image: UIImage) throws -> [String] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["en-US"]
        request.usesLanguageCorrection = false
        try VNImageRequestHandler(cgImage: XCTUnwrap(image.cgImage)).perform([request])
        return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
    }

    func centerLuminance(_ image: UIImage) throws -> Double {
        let source = try XCTUnwrap(image.cgImage)
        var bytes = [UInt8](repeating: 0, count: 4)
        try bytes.withUnsafeMutableBytes { storage in
            let context = try XCTUnwrap(CGContext(data: storage.baseAddress, width: 1, height: 1,
                bitsPerComponent: 8, bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.draw(source, in: CGRect(x: -source.width / 2, y: -source.height / 2,
                width: source.width, height: source.height))
        }
        return (Double(bytes[0]) + Double(bytes[1]) + Double(bytes[2])) / (255 * 3)
    }
}

