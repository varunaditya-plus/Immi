import Observation
import SwiftUI
import UIKit
import XCTest
@testable import ImmichApp

@MainActor
final class PhotoEditPresentationTests: SimulatorHostedTestCase {
    private var fixtures: [PhotoEditorTestFixture] = []
    private weak var retainedFixture: PhotoEditorTestFixture?

    override func tearDown() async throws {
        fixtures.forEach { $0.allowed = false; $0.isPresented = false; $0.gate?.complete(.success(false)) }
        try await waitUntil("The editor's held saves finish before fixture cleanup") {
            self.fixtures.allSatisfy { $0.saveReturns == $0.saves.count }
        }
        try await super.tearDown()
        fixtures.removeAll()
        try await waitUntil("Closing the editor releases its callbacks and fixture") { self.retainedFixture == nil }
    }

    func testActualExposureSliderUndoRedoFilterAndDoneSaveTheVisibleRecipe() async throws {
        let (fixture, window) = try await show()
        try await activateAccessibilityButton(named: "Exposure", in: window)
        let initial = try slider(in: window).value
        let edited = try await changeSlider(in: window)
        try await activateAccessibilityButton(named: "Undo", in: window)
        try await waitUntil("Undo restores the actual slider's neutral value") { abs(((try? self.slider(in: window).value) ?? -10) - initial) < 0.01 }
        XCTAssertEqual(try slider(in: window).value, initial, accuracy: 0.01)
        try await activateAccessibilityButton(named: "Redo", in: window)
        try await waitUntil("Redo restores the actual slider's edited value") { abs(((try? self.slider(in: window).value) ?? -10) - edited) < 0.01 }
        try await activateAccessibilityButton(named: "Exposure", in: window)
        try await waitUntil("Tapping the selected applied adjustment resets it") { abs(((try? self.slider(in: window).value) ?? -10) - initial) < 0.01 }
        try await activateAccessibilityButton(named: "Undo", in: window)
        try await waitUntil("Undo restores the adjustment cleared by its selected icon") { abs(((try? self.slider(in: window).value) ?? -10) - edited) < 0.01 }
        try await activateAccessibilityButton(named: "Filters", in: window)
        try await activateAccessibilityButton(named: "Vivid", in: window)

        try await activateAccessibilityButton(named: "Done", in: window)

        try await waitUntil("Done saves once and dismisses the actual editor") { fixture.saves.count == 1 && !fixture.isPresented }
        let saved = try XCTUnwrap(fixture.saves.first)
        XCTAssertEqual(saved[.exposure], 0.6, accuracy: 0.01)
        XCTAssertEqual(saved.filter, .vivid)
        XCTAssertEqual(fixture.reverts, 0)
    }

    func testRecoveredChangedSourceSavesItsNewIdentityRecipeWhenDoneIsTappedWithoutFurtherAdjustments() async throws {
        let (fixture, window) = try await show(requiresSave: true)

        try await activateAccessibilityButton(named: "Done", in: window)

        try await waitUntil("Recovery Done replaces the stale saved edit with the new source's identity recipe") {
            fixture.saves.count == 1 && !fixture.isPresented
        }
        XCTAssertTrue(try XCTUnwrap(fixture.saves.first).isIdentity)
        XCTAssertEqual(fixture.reverts, 0)
    }

    func testCancellingWithoutChangesPreservesTheOpenedEditsWithoutSavingOrReverting() async throws {
        var recipe = PhotoEditRecipe()
        recipe.filter = .mono
        let (fixture, window) = try await show(recipe: recipe)

        try await activateAccessibilityButton(named: "Cancel", in: window)

        try await waitUntil("A clean Cancel closes directly") { !fixture.isPresented }
        XCTAssertTrue(fixture.saves.isEmpty)
        XCTAssertEqual(fixture.reverts, 0)
    }

    func testDirtyCancelPresentsEnabledDiscardAndKeepEditingActionsWithoutSavingOrChangingTheDraft() async throws {
        let (fixture, window) = try await show()
        try await activateAccessibilityButton(named: "Exposure", in: window)
        let edited = try await changeSlider(in: window)

        try await activateAccessibilityButton(named: "Cancel", in: window)

        let confirmation = try await alert(in: window)
        XCTAssertEqual(confirmation.title, "Discard Changes?")
        let discard = try XCTUnwrap(confirmation.actions.first { $0.title == "Discard Changes" })
        let keep = try XCTUnwrap(confirmation.actions.first { $0.title == "Keep Editing" })
        XCTAssertEqual(discard.style, .destructive)
        XCTAssertEqual(keep.style, .cancel)
        XCTAssertTrue(discard.isEnabled)
        XCTAssertTrue(keep.isEnabled)
        XCTAssertTrue(fixture.isPresented)
        XCTAssertEqual(try slider(in: window).value, edited, accuracy: 0.01)
        XCTAssertTrue(fixture.saves.isEmpty)
        XCTAssertEqual(fixture.reverts, 0)
        _ = try await screenshot(window)
    }

    func testRevertMenuPresentsItsEnabledConfirmationWithoutSavingOrRevertingBeforeApproval() async throws {
        var recipe = PhotoEditRecipe()
        recipe[.exposure] = 0.4
        let (fixture, window) = try await show(recipe: recipe)

        try await activateSearchMenuAction(named: "Revert to Original", in: window)

        let confirmation = try await alert(in: window)
        XCTAssertEqual(confirmation.title, "Revert to Original?")
        XCTAssertEqual(confirmation.message, "This will remove the edits made to this photo.")
        let revert = try XCTUnwrap(confirmation.actions.first { $0.title == "Revert to Original" })
        let cancel = try XCTUnwrap(confirmation.actions.first { $0.title == "Cancel" })
        XCTAssertEqual(revert.style, .destructive)
        XCTAssertEqual(cancel.style, .cancel)
        XCTAssertTrue(revert.isEnabled)
        XCTAssertTrue(cancel.isEnabled)
        XCTAssertTrue(fixture.isPresented)
        XCTAssertTrue(fixture.saves.isEmpty)
        XCTAssertEqual(fixture.reverts, 0)
        _ = try await screenshot(window)
    }

    func testARejectedSaveStaysOpenAndTheActualDoneButtonCanRetry() async throws {
        let (fixture, window) = try await show()
        fixture.acceptSave = false
        try await activateAccessibilityButton(named: "Exposure", in: window)
        _ = try await changeSlider(in: window)
        try await activateAccessibilityButton(named: "Done", in: window)
        try await waitUntil("A rejected save finishes and keeps the editor open") { fixture.saveReturns == 1 }
        XCTAssertTrue(fixture.isPresented)
        try await waitUntil("The failed save explains that the edits were not saved") {
            self.searchContainsText("The edits could not be saved. Please try again.", in: window)
        }
        fixture.acceptSave = true

        try await activateAccessibilityButton(named: "Done", in: window)

        try await waitUntil("Retry saves the same edited recipe and closes") { fixture.saveReturns == 2 && !fixture.isPresented }
        XCTAssertEqual(fixture.saves.count, 2)
        XCTAssertEqual(fixture.saves[0], fixture.saves[1])
    }

    func testRevokingTheEditorDuringAHeldActualSaveCancelsItsTaskAndReleasesItsCallbacks() async throws {
        let (fixture, window) = try await show()
        let gate = PeopleStateGate<Bool>()
        fixture.gate = gate
        try await activateAccessibilityButton(named: "Exposure", in: window)
        _ = try await changeSlider(in: window)
        XCTAssertTrue(try slider(in: window).isEnabled)
        try await activateAccessibilityButton(named: "Done", in: window)
        await fulfillment(of: [gate.started], timeout: 2)
        XCTAssertEqual(fixture.saves.count, 1)
        try await waitUntil("The actual Exposure slider becomes disabled while the captured save is held") {
            let controls = self.views(window).compactMap { $0 as? UISlider }.filter { $0.accessibilityLabel == "Exposure" }
            return !controls.isEmpty && controls.allSatisfy { !$0.isEnabled }
        }
        let controls = views(window).compactMap { $0 as? UISlider }.filter { $0.accessibilityLabel == "Exposure" }
        XCTAssertFalse(controls.isEmpty)
        XCTAssertTrue(controls.allSatisfy { !$0.isEnabled })

        fixture.allowed = false

        try await waitUntil("Losing the captured authorization closes the actual editor") { !fixture.isPresented }
        gate.complete(.success(true))
        try await waitUntil("The late save returns through cancellation cleanup") { fixture.saveReturns == 1 }
        XCTAssertTrue(fixture.cancelledSave)
        XCTAssertEqual(fixture.reverts, 0)
    }

    func testTheImageCompareAccessibilityActionShowsTheRealOriginalPixelsWithoutChangingTheSavedRecipe() async throws {
        let (fixture, window) = try await show()
        try await activateAccessibilityButton(named: "Exposure", in: window)
        var edited: NSObject?
        try await waitUntil("The rendered image exposes its real comparison action") {
            edited = self.accessibilityObject("Edited Photo", in: window)
            return edited != nil
        }
        let image = try XCTUnwrap(edited)
        let frame = window.convert(image.accessibilityFrame, from: nil)
        let baseline = try centerLuminance(await screenshot(window), frame: frame, window: window)
        _ = try await changeSlider(in: window)
        var editedScreenshot: UIImage?
        try await waitUntil("The actual Exposure preview becomes brighter before comparison") {
            let snapshot = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
                window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
            }
            guard let luminance = try? self.centerLuminance(snapshot, frame: frame, window: window),
                  luminance > baseline + 2 else { return false }
            editedScreenshot = snapshot
            return true
        }
        let editedPixels = try XCTUnwrap(editedScreenshot)
        var currentImage: NSObject?
        try await waitUntil("The updated preview exposes its real comparison action") {
            currentImage = self.accessibilityObject("Edited Photo", in: window)
            return currentImage != nil
        }
        XCTAssertTrue(try XCTUnwrap(currentImage).accessibilityActivate())
        try await waitUntil("The actual comparison action switches the image to Original") {
            self.accessibilityObject("Original Photo", in: window) != nil
        }
        let originalScreenshot = try await screenshot(window)

        XCTAssertLessThan(try centerLuminance(originalScreenshot, frame: frame, window: window),
            try centerLuminance(editedPixels, frame: frame, window: window))
        XCTAssertEqual(try centerLuminance(originalScreenshot, frame: frame, window: window), baseline, accuracy: 2)
        try await activateAccessibilityButton(named: "Crop", in: window)
        try await waitUntil("Entering Crop exits comparison and restores its editable image") {
            self.accessibilityObject("Edited Photo", in: window) != nil
                && self.accessibilityObject("Original Photo", in: window) == nil
        }
        try await activateAccessibilityButton(named: "Done", in: window)
        try await waitUntil("Comparing does not discard the edited recipe saved by Done") { fixture.saves.count == 1 }
        XCTAssertGreaterThan(try XCTUnwrap(fixture.saves.first)[.exposure], 0)
    }

    func testRevokingTheEditorRemovesItsGeneratedPhotoPixelsBeforeItFinishesDismissing() async throws {
        let green = UIGraphicsImageRenderer(size: CGSize(width: 180, height: 120)).image { context in
            UIColor.green.setFill(); context.fill(CGRect(x: 0, y: 0, width: 180, height: 120))
        }
        let (fixture, window) = try await show(image: green)
        var image: NSObject?
        try await waitUntil("The distinctive generated photo is actually rendered") {
            image = self.accessibilityObject("Edited Photo", in: window)
            return image != nil
        }
        let frame = window.convert(try XCTUnwrap(image).accessibilityFrame, from: nil)
        let shown = try await screenshot(window)
        XCTAssertGreaterThan(try greenPixels(in: frame, image: shown, window: window), 500)

        fixture.allowed = false

        try await waitUntil("The revoked editor removes its image-bearing accessibility subtree") {
            self.accessibilityObject("Edited Photo", in: window) == nil
        }
        window.layoutIfNeeded()
        let captured = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        XCTAssertEqual(try greenPixels(in: frame, image: captured, window: window), 0)
        XCTAssertTrue(fixture.saves.isEmpty)
        XCTAssertEqual(fixture.reverts, 0)
    }

    func testLockingAFreeformCropCapturesItsCurrentPhysicalAspectWithoutChangingTheFraming() async throws {
        var recipe = PhotoEditRecipe()
        recipe.framing = CGRect(x: 0.1, y: 0.1, width: 0.6, height: 0.4)
        recipe.cropAspectRatio = nil
        let (fixture, window) = try await show(recipe: recipe)
        try await activateAccessibilityButton(named: "Crop", in: window)

        try await activateAccessibilityButton(named: "Lock Aspect Ratio", in: window)
        try await activateAccessibilityButton(named: "Done", in: window)

        try await waitUntil("The actual Lock control saves its constraint with the existing freeform framing") {
            fixture.saves.count == 1
        }
        let saved = try XCTUnwrap(fixture.saves.first)
        XCTAssertEqual(try XCTUnwrap(saved.cropAspectRatio), 0.6 * 1.5 / 0.4, accuracy: 0.000_001)
        XCTAssertEqual(saved.framing, recipe.framing)
    }

    private func show(recipe: PhotoEditRecipe = PhotoEditRecipe(), image supplied: UIImage? = nil, requiresSave: Bool = false) async throws -> (PhotoEditorTestFixture, UIWindow) {
        let image = supplied ?? UIGraphicsImageRenderer(size: CGSize(width: 180, height: 120)).image { context in
            UIColor(white: 0.35, alpha: 1).setFill()
            context.fill(CGRect(x: 0, y: 0, width: 180, height: 120))
        }
        let fixture = PhotoEditorTestFixture(image: image, recipe: recipe, requiresSave: requiresSave)
        fixtures.append(fixture)
        retainedFixture = fixture
        let window = try await host(PhotoEditorTestPresenter(fixture: fixture))
        if let scene = window.windowScene {
            window.frame = scene.effectiveGeometry.coordinateSpace.bounds
            window.rootViewController?.view.frame = window.bounds
            window.layoutIfNeeded()
        }
        try await waitUntil("The loaded editor's real tools are mounted") { self.searchContainsText("Adjust", in: window) }
        return (fixture, window)
    }

    private func slider(in window: UIWindow) throws -> UISlider {
        try XCTUnwrap(views(window).compactMap { $0 as? UISlider }.first { $0.isEnabled && !$0.isHidden })
    }

    @discardableResult
    private func changeSlider(in window: UIWindow) async throws -> Float {
        try await waitUntil("The enabled slider is bound to the selected Exposure adjustment") {
            self.views(window).compactMap { $0 as? UISlider }.contains {
                $0.isEnabled && !$0.isHidden && $0.accessibilityLabel == "Exposure"
            }
        }
        let slider = try XCTUnwrap(views(window).compactMap { $0 as? UISlider }.first {
            $0.isEnabled && !$0.isHidden && $0.accessibilityLabel == "Exposure"
        })
        slider.sendActions(for: .touchDown)
        slider.value = slider.minimumValue + (slider.maximumValue - slider.minimumValue) * 0.8
        let value = slider.value
        slider.sendActions(for: .valueChanged)
        slider.sendActions(for: .touchUpInside)
        let fraction = Double((value - slider.minimumValue) / (slider.maximumValue - slider.minimumValue))
        let range = PhotoAdjustment.exposure.range
        let recipeValue = range.lowerBound + fraction * (range.upperBound - range.lowerBound)
        let text = String(Int((recipeValue * 100).rounded()))
        try await waitUntil("The actual numeric value reflects the edited recipe before the next action") {
            self.searchContainsText(text, in: window)
        }
        return value
    }

    private func alert(in window: UIWindow) async throws -> UIAlertController {
        try await waitUntil("The real editor confirmation is presented") {
            self.searchPresentedControllers(in: window.rootViewController).contains { $0 is UIAlertController }
        }
        return try XCTUnwrap(searchPresentedControllers(in: window.rootViewController).compactMap { $0 as? UIAlertController }.first)
    }

    private func views(_ view: UIView) -> [UIView] { [view] + view.subviews.flatMap(views) }

    private func accessibilityObject(_ label: String, in root: NSObject) -> NSObject? {
        var visited = Set<ObjectIdentifier>()
        func find(_ object: NSObject, depth: Int) -> NSObject? {
            guard depth < 40, visited.insert(ObjectIdentifier(object)).inserted else { return nil }
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

    private func centerLuminance(_ image: UIImage, frame: CGRect, window: UIWindow) throws -> Double {
        let cg = try XCTUnwrap(image.cgImage)
        let x = frame.midX * CGFloat(cg.width) / window.bounds.width
        let y = frame.midY * CGFloat(cg.height) / window.bounds.height
        let pixel = try XCTUnwrap(cg.cropping(to: CGRect(x: x, y: y, width: 1, height: 1)))
        var rgba = [UInt8](repeating: 0, count: 4)
        try rgba.withUnsafeMutableBytes { bytes in
            let context = try XCTUnwrap(CGContext(data: bytes.baseAddress, width: 1, height: 1,
                bitsPerComponent: 8, bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.draw(pixel, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        }
        return (Double(rgba[0]) + Double(rgba[1]) + Double(rgba[2])) / 3
    }

    private func greenPixels(in frame: CGRect, image: UIImage, window: UIWindow) throws -> Int {
        let cg = try XCTUnwrap(image.cgImage)
        let scale = CGFloat(cg.width) / window.bounds.width
        let area = frame.insetBy(dx: 8, dy: 8).applying(CGAffineTransform(scaleX: scale, y: scale))
            .intersection(CGRect(x: 0, y: 0, width: cg.width, height: cg.height))
        let cropped = try XCTUnwrap(cg.cropping(to: area))
        var bytes = [UInt8](repeating: 0, count: cropped.width * cropped.height * 4)
        try bytes.withUnsafeMutableBytes { storage in
            let context = try XCTUnwrap(CGContext(data: storage.baseAddress, width: cropped.width, height: cropped.height,
                bitsPerComponent: 8, bytesPerRow: cropped.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.draw(cropped, in: CGRect(x: 0, y: 0, width: cropped.width, height: cropped.height))
        }
        var count = 0
        for offset in stride(from: 0, to: bytes.count, by: 4) {
            let red = Int(bytes[offset]), green = Int(bytes[offset + 1]), blue = Int(bytes[offset + 2])
            if green > red + 60, green > blue + 60, green > 100 { count += 1 }
        }
        return count
    }
}

@MainActor
@Observable
private final class PhotoEditorTestFixture {
    let image: UIImage
    let recipe: PhotoEditRecipe
    let requiresSave: Bool
    var isPresented = true
    var allowed = true
    var acceptSave = true
    var saves: [PhotoEditRecipe] = []
    var saveReturns = 0
    var reverts = 0
    var cancelledSave = false
    var gate: PeopleStateGate<Bool>?
    init(image: UIImage, recipe: PhotoEditRecipe, requiresSave: Bool) { self.image = image; self.recipe = recipe; self.requiresSave = requiresSave }
    func save(_ value: PhotoEditRecipe) async -> Bool {
        saves.append(value)
        let accepted = if let gate { (try? await gate.value()) == true } else { acceptSave }
        cancelledSave = Task.isCancelled
        saveReturns += 1
        return accepted
    }
}

private struct PhotoEditorTestPresenter: View {
    @Bindable var fixture: PhotoEditorTestFixture
    var body: some View {
        Color.clear.fullScreenCover(isPresented: $fixture.isPresented) {
            PhotoCropEditor(initialRecipe: fixture.recipe, requiresSave: fixture.requiresSave, loadImage: { fixture.image }, isAllowed: { fixture.allowed },
                onSave: { await fixture.save($0) }, onRevert: { fixture.reverts += 1; return true })
        }
    }
}
