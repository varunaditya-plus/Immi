import SwiftUI
import UIKit
import Vision
import XCTest
@testable import ImmichApp

@MainActor
final class AssetViewerDatePresentationTests: ViewerAdaptiveLayoutTestCase {
    private var assetIDs: [String] = []

    override func tearDown() async throws {
        try await super.tearDown()
        for id in assetIDs { LocalSnapshot.remove(LocalSnapshot.Key.assetDetail(id)) }
        assetIDs.removeAll()
    }

    func testSavedCaptureDateUpdatesTheMountedNavigationTitleWithoutReopening() async throws {
        let original = Date(timeIntervalSince1970: 1_600_000_000)
        let saved = Date(timeIntervalSince1970: 1_700_000_000)
        let (window, model, repository) = try await showViewer(date: original)
        let id = repository.value.id
        try await waitUntil("The original date appears") { self.titles(window).contains(self.title(original)) }

        let accepted = await model.updateDate(id, to: saved)

        XCTAssertTrue(accepted)
        XCTAssertEqual(repository.savedDates, [saved])
        XCTAssertEqual(model.detail?.fileCreatedAt, saved)
        try await waitUntil("The saved date appears in the existing viewer header") {
            self.titles(window).contains(self.title(saved))
        }
        XCTAssertFalse(titles(window).contains(title(original)))
        _ = try await screenshot(window)
    }

    func testActualDateEditorSaveUpdatesTheExistingViewerAndReportsItsTarget() async throws {
        let original = Date(timeIntervalSince1970: 1_599_999_960)
        let saved = original.addingTimeInterval(86_400)
        var updatedIDs: [String] = []
        let (window, model, repository) = try await showViewer(date: original,
            onAssetUpdated: { updatedIDs.append($0) })
        try await waitUntil("The original date appears before editing") {
            self.titles(window).contains(self.title(original))
        }
        try await activateInfo(in: window)
        try await activateAccessibilityButton(named: "Adjust", in: window)
        try await waitUntil("The viewer's own Date Editor presents its native picker") {
            self.visibleViews(in: window).contains { $0 is UIDatePicker }
        }
        let picker = try XCTUnwrap(visibleViews(in: window).compactMap { $0 as? UIDatePicker }.first)
        picker.setDate(saved, animated: false)
        picker.sendActions(for: .valueChanged)
        let root = try XCTUnwrap(window.rootViewController)
        try await waitUntil("Changing the actual picker enables Save") {
            self.barItems(root).contains { ($0.title == "Save" || $0.accessibilityLabel == "Save") && $0.isEnabled }
        }
        XCTAssertTrue(repository.savedDates.isEmpty, "Changing the picker must not save by itself")
        XCTAssertTrue(updatedIDs.isEmpty)
        let save = try XCTUnwrap(barItems(root).first {
            ($0.title == "Save" || $0.accessibilityLabel == "Save") && $0.isEnabled
        })
        let action = try XCTUnwrap(save.action)
        XCTAssertTrue(UIApplication.shared.sendAction(action, to: save.target, from: save, for: nil))
        try await waitUntil("The actual Save action writes the selected date and reports its photo") {
            repository.savedDates == [saved] && updatedIDs == [repository.value.id]
        }
        XCTAssertEqual(model.detail?.fileCreatedAt, saved)
        try await waitUntil("The actual Date Editor dismisses after saving") {
            !self.visibleViews(in: window).contains { $0 is UIDatePicker }
        }
        try await activateInfo(in: window)
        try await waitUntil("The existing viewer header displays the date saved through the actual editor") {
            self.titles(window).contains(self.title(saved))
        }
        XCTAssertFalse(titles(window).contains(title(original)))
        _ = try await screenshot(window)
    }

    func testFailedDateSaveKeepsTheMountedTitleAndShowsTheMutationError() async throws {
        let original = Date(timeIntervalSince1970: 1_600_000_000)
        let (window, model, repository) = try await showViewer(date: original)
        try await waitUntil("Metadata is loaded") { model.detail?.id == repository.value.id }
        repository.rejectSave = true

        let accepted = await model.updateDate(repository.value.id, to: Date(timeIntervalSince1970: 1_700_000_000))

        XCTAssertFalse(accepted)
        XCTAssertEqual(model.detail?.fileCreatedAt, original)
        XCTAssertNotNil(model.actionError)
        XCTAssertTrue(titles(window).contains(title(original)))
    }

    func testConfirmedDateRemainsVisibleWhenTheFollowUpReadFails() async throws {
        let original = Date(timeIntervalSince1970: 1_600_000_000)
        let saved = Date(timeIntervalSince1970: 1_700_000_000)
        let other = AssetLite(id: UUID().uuidString, isVideo: false, ratio: 1, thumbhash: nil,
            createdAt: Date(timeIntervalSince1970: 1_500_000_000))
        let (window, model, repository) = try await showViewer(date: original, additional: [other])
        let originalPage = AssetLite(id: repository.value.id, isVideo: false, ratio: 1,
            thumbhash: nil, createdAt: original)
        try await waitUntil("Metadata is loaded") { model.detail?.id == repository.value.id }
        repository.failReadAfterSaving = true

        let accepted = await model.updateDate(repository.value.id, to: saved)

        XCTAssertTrue(accepted, "The server accepted the write even if its follow-up read fails")
        XCTAssertEqual(model.detail?.fileCreatedAt, saved)
        try await waitUntil("The confirmed date remains in the mounted header") {
            self.titles(window).contains(self.title(saved))
        }
        XCTAssertNil(LocalSnapshot.load(AssetResponseDTO.self,
            for: LocalSnapshot.Key.assetDetail(repository.value.id)))
        let pager = try XCTUnwrap(findPager(in: try XCTUnwrap(window.rootViewController)))
        pager.onPageChanged?(other)
        try await waitUntil("The other page displays its own date offline") {
            self.titles(window).contains(self.title(other.createdAt))
        }
        pager.onPageChanged?(originalPage)
        try await waitUntil("The saved date survives paging back with no detail cache or network") {
            self.titles(window).contains(self.title(saved))
        }
    }

    func testAnotherPhotosMetadataCannotSupplyTheCurrentHeaderDate() async throws {
        let original = Date(timeIntervalSince1970: 1_600_000_000)
        let otherDate = Date(timeIntervalSince1970: 1_700_000_000)
        let (window, model, repository) = try await showViewer(date: original)
        try await waitUntil("Metadata is loaded") { model.detail?.id == repository.value.id }
        let otherID = UUID().uuidString
        assetIDs.append(otherID)
        repository.value = ViewerDateRepository.asset(id: otherID, date: otherDate)

        await model.load(otherID)

        try await waitUntil("Unrelated metadata leaves the current title intact") {
            self.titles(window).contains(self.title(original))
        }
        XCTAssertFalse(titles(window).contains(title(otherDate)))
    }

    func testTheTwoLineCaptureTitleFollowsSavedMetadataAndPagingInBothAppearances() async throws {
        let original = Date(timeIntervalSince1970: 1_600_000_000)
        let saved = original.addingTimeInterval(3_660)
        let other = AssetLite(id: UUID().uuidString, isVideo: false, ratio: 1, thumbhash: nil,
            createdAt: original.addingTimeInterval(-172_800))
        for width: CGFloat in [320, 390] {
            for style in [UIUserInterfaceStyle.light, .dark] {
                let (window, model, repository) = try await showViewer(date: original,
                    additional: [other], style: style)
                resize(window, to: CGSize(width: width, height: 844))
                try await assertCaptureTitle(original, in: window)

                let accepted = await model.updateDate(repository.value.id, to: saved)
                XCTAssertTrue(accepted)

                try await assertCaptureTitle(saved, in: window)
                XCTAssertTrue(titles(window).contains(title(saved)), "The navigation stack must retain its text title")
                let pager = try XCTUnwrap(findPager(in: try XCTUnwrap(window.rootViewController)))
                pager.onPageChanged?(other)
                try await assertCaptureTitle(other.createdAt, in: window)
                pager.onPageChanged?(AssetLite(id: repository.value.id, isVideo: false, ratio: 1,
                    thumbhash: nil, createdAt: original))
                try await assertCaptureTitle(saved, in: window)

                try await activateInfo(in: window)
                try await waitUntil("The real caption field is mounted") {
                    self.visibleViews(in: window).contains { $0 is UITextView }
                }
                let caption = try XCTUnwrap(visibleViews(in: window).compactMap { $0 as? UITextView }.first)
                XCTAssertTrue(caption.becomeFirstResponder())
                try await waitUntil("Caption editing exposes its actual Cancel and Save controls") {
                    self.accessibilityButton(named: "Cancel", in: window) != nil
                        && self.accessibilityButton(named: "Save", in: window) != nil
                }
                XCTAssertNil(accessibilityObject(saved.formatted(date: .long, time: .shortened), in: window),
                    "The capture title must not displace the existing caption-editing toolbar")
                try await activateAccessibilityButton(named: "Cancel", in: window)
                try await waitUntil("Closing caption editing restores the visible Info control") {
                    self.accessibilityButton(named: "Info", in: window) != nil
                }
                try await activateInfo(in: window)
                try await assertCaptureTitle(saved, in: window)
            }
        }
    }

    private func assertCaptureTitle(_ date: Date, in window: UIWindow) async throws {
        let label = date.formatted(date: .long, time: .shortened)
        try await waitUntil("The visible capture title contains the current date and time") {
            self.accessibilityObject(label, in: window) != nil
        }
        let element = try XCTUnwrap(accessibilityObject(label, in: window))
        XCTAssertFalse(element.accessibilityTraits.contains(.button), "The title must not introduce an unused action")
        let frame = window.convert(element.accessibilityFrame, from: nil)
        XCTAssertGreaterThan(frame.height, 28, "Date and time need two distinct text lines")
        XCTAssertTrue(window.bounds.contains(frame), "The title must fit between the navigation actions")
        let snapshot = try await screenshot(window)
        let image = try XCTUnwrap(snapshot.cgImage)
        let scale = CGFloat(image.width) / window.bounds.width
        let crop = try XCTUnwrap(image.cropping(to: frame.insetBy(dx: -4, dy: -4)
            .applying(CGAffineTransform(scaleX: scale, y: scale))))
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["en-US"]
        try VNImageRequestHandler(cgImage: crop).perform([request])
        let observations = request.results ?? []
        func normalize(_ value: String) -> String { value.filter { !$0.isWhitespace }.lowercased() }
        let dateLine = try XCTUnwrap(observations.first {
            normalize($0.topCandidates(1).first?.string ?? "") == normalize(date.formatted(date: .long, time: .omitted))
        }, "The complete date must be visibly rendered in the capture capsule")
        let timeLine = try XCTUnwrap(observations.first {
            normalize($0.topCandidates(1).first?.string ?? "") == normalize(date.formatted(date: .omitted, time: .shortened))
        }, "The complete capture time must be visibly rendered beneath the date")
        XCTAssertGreaterThan(dateLine.boundingBox.midY, timeLine.boundingBox.midY,
            "The capture time belongs below the date, as in Photos")
    }

    private func showViewer(date: Date, additional: [AssetLite] = [],
                            onAssetUpdated: ((String) -> Void)? = nil,
                            style: UIUserInterfaceStyle = .light) async throws
        -> (UIWindow, AssetDetailViewModel, ViewerDateRepository) {
        let id = UUID().uuidString
        assetIDs.append(id)
        assetIDs.append(contentsOf: additional.map(\.id))
        let repository = ViewerDateRepository(id: id, date: date)
        let model = AssetDetailViewModel(repo: repository)
        let asset = AssetLite(id: id, isVideo: false, ratio: 1, thumbhash: nil, createdAt: date)
        let viewer = AssetDetailView(currentAsset: asset, assets: [asset] + additional,
            isModal: true, onAssetUpdated: onAssetUpdated, viewModel: model)
        return (try await host(NavigationStack { viewer }, style: style), model, repository)
    }

    private func title(_ date: Date) -> String {
        date.formatted(date: .abbreviated, time: .omitted)
    }

    private func visibleViews(in view: UIView) -> [UIView] {
        guard !view.isHidden, view.alpha > 0 else { return [] }
        return [view] + view.subviews.flatMap { visibleViews(in: $0) }
    }

    private func titles(_ window: UIWindow) -> [String] {
        visibleViews(in: window).compactMap { ($0 as? UINavigationBar)?.topItem?.title }
    }

    private func barItems(_ controller: UIViewController) -> [UIBarButtonItem] {
        let groups = controller.navigationItem.leadingItemGroups + controller.navigationItem.centerItemGroups
            + controller.navigationItem.trailingItemGroups
        let own = (controller.navigationItem.leftBarButtonItems ?? []) + (controller.navigationItem.rightBarButtonItems ?? [])
            + (controller.toolbarItems ?? []) + groups.flatMap(\.barButtonItems)
        let presented = controller.presentedViewController.map { barItems($0) } ?? []
        return own + presented + controller.children.flatMap { barItems($0) }
    }

    private func activateInfo(in window: UIWindow) async throws {
        let root = try XCTUnwrap(window.rootViewController)
        try await waitUntil("The real Info action is enabled") {
            self.barItems(root).contains { ($0.title == "Info" || $0.accessibilityLabel == "Info") && $0.isEnabled }
        }
        let item = try XCTUnwrap(barItems(root).first {
            ($0.title == "Info" || $0.accessibilityLabel == "Info") && $0.isEnabled
        })
        let action = try XCTUnwrap(item.action)
        XCTAssertTrue(UIApplication.shared.sendAction(action, to: item.target, from: item, for: nil))
    }

    private func findPager(in controller: UIViewController) -> PhotoPagerController? {
        if let pager = controller as? PhotoPagerController { return pager }
        return controller.children.lazy.compactMap { self.findPager(in: $0) }.first
    }
}

@MainActor
private final class ViewerDateRepository: AssetDetailRepository {
    var value: AssetResponseDTO
    var savedDates: [Date] = []
    var rejectSave = false
    var failReadAfterSaving = false

    init(id: String, date: Date) {
        value = Self.asset(id: id, date: date)
        super.init(api: makeStubAPIClient())
    }

    override func fetchAsset(_ id: String) async throws -> AssetResponseDTO {
        guard id == value.id else { throw APIError.notConnected }
        if failReadAfterSaving, !savedDates.isEmpty { throw APIError.notConnected }
        return value
    }

    override func updateDate(_ id: String, to date: Date) async throws {
        XCTAssertEqual(id, value.id)
        if rejectSave { throw APIError.server(status: 503, message: "Date rejected") }
        savedDates.append(date)
        value = Self.asset(id: id, date: date)
    }

    static func asset(id: String, date: Date) -> AssetResponseDTO {
        AssetResponseDTO(id: id, type: "IMAGE", originalFileName: "date-test.png", fileCreatedAt: date,
            isFavorite: false, isArchived: false, isTrashed: false, duration: nil, thumbhash: nil,
            localDateTime: date, exifInfo: nil, people: nil)
    }
}
