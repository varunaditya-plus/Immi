import SwiftUI
import UIKit
import XCTest
@testable import ImmichApp

@MainActor
final class AssetInfoDateActionLayoutTests: ViewerAdaptiveLayoutTestCase {
    func testDateAndFileNameKeepTheirLargeTextWhileAdjustRemainsReadableAndOpensTheRealEditor() async throws {
        let date = try XCTUnwrap(Calendar(identifier: .gregorian).date(from:
            DateComponents(year: 2026, month: 11, day: 1, hour: 19, minute: 45)))
        let detail = AssetResponseDTO(id: UUID().uuidString, type: "IMAGE", originalFileName: "photo.jpg",
            fileCreatedAt: date, isFavorite: false, isArchived: false, isTrashed: false,
            duration: nil, thumbhash: nil, localDateTime: date, exifInfo: nil, people: nil)
        let dateText = date.formatted(.dateTime.weekday(.wide).day().month(.abbreviated).year()
            .hour().minute().locale(Locale(identifier: "en_US")))
        for width: CGFloat in [320, 390] {
            for style in [UIUserInterfaceStyle.light, .dark] {
                let window = try await host(InfoDateActionProbe(detail: detail).dynamicTypeSize(.accessibility5), style: style)
                resize(window, to: CGSize(width: width, height: 844))
                try await waitUntil("The real metadata date action appears") {
                    self.accessibilityObject("Adjust", in: window) != nil
                }
                let dateElement = try XCTUnwrap(accessibilityObject(dateText, in: window))
                try scrollVertically(to: dateElement, in: window)
                let snapshot = try await screenshot(window)
                let strings = try renderedStrings(snapshot).map { $0.replacingOccurrences(of: " ", with: "") }
                for part in ["Sunday", "Nov", "2026", "7:45PM"] {
                    XCTAssertTrue(strings.contains { $0.contains(part) },
                        "The metadata date must preserve the complete \(part) value at \(width)pt: \(strings)")
                }
                XCTAssertGreaterThan(dateElement.accessibilityFrame.height, 40,
                    "The date must retain the user's accessibility text size")
                let fileName = try XCTUnwrap(accessibilityObject("photo.jpg", in: window))
                XCTAssertGreaterThan(fileName.accessibilityFrame.height, 30,
                    "The metadata action's cap must not reduce the file name")
                let adjust = try XCTUnwrap(accessibilityObject("Adjust", in: window))
                XCTAssertLessThan(adjust.accessibilityFrame.width, 100,
                    "The ordinary-size action must leave room for the preferred-size date")
                try scrollVertically(to: adjust, in: window)

                try await activateAccessibilityButton(named: "Adjust", in: window)

                try await waitUntil("The actual Adjust action opens the existing Date Editor picker") {
                    self.descendants(window).contains { $0 is UIDatePicker }
                }
                XCTAssertTrue(searchContainsText("Adjust Date & Time", in: window))
                try await activateAccessibilityButton(named: "Cancel", in: window)
                try await waitUntil("Cancelling returns from the actual Date Editor") {
                    !self.descendants(window).contains { $0 is UIDatePicker }
                }
            }
        }
    }
}

private struct InfoDateActionProbe: View {
    let detail: AssetResponseDTO
    @State private var description = ""
    @FocusState private var descriptionFocused: Bool
    @State private var showsDateEditor = false

    var body: some View {
        AssetInfoPanel(detail: detail, descriptionDraft: $description,
            descriptionFocus: $descriptionFocused, onAdjustDate: { showsDateEditor = true })
            .sheet(isPresented: $showsDateEditor) {
                AssetDateEditor(initialDate: detail.fileCreatedAt) { _ in
                    XCTFail("Opening or cancelling Adjust cannot save the date")
                }
            }
    }
}
