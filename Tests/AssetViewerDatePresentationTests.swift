import SwiftUI
import UIKit
import XCTest
@testable import ImmichApp

@MainActor
final class AssetViewerDatePresentationTests: SimulatorHostedTestCase {
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

    private func showViewer(date: Date, additional: [AssetLite] = [],
                            onAssetUpdated: ((String) -> Void)? = nil) async throws
        -> (UIWindow, AssetDetailViewModel, ViewerDateRepository) {
        let id = UUID().uuidString
        assetIDs.append(id)
        assetIDs.append(contentsOf: additional.map(\.id))
        let repository = ViewerDateRepository(id: id, date: date)
        let model = AssetDetailViewModel(repo: repository)
        let asset = AssetLite(id: id, isVideo: false, ratio: 1, thumbhash: nil, createdAt: date)
        let viewer = AssetDetailView(currentAsset: asset, assets: [asset] + additional,
            isModal: true, onAssetUpdated: onAssetUpdated, viewModel: model)
        return (try await host(NavigationStack { viewer }), model, repository)
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
