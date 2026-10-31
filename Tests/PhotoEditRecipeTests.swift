import XCTest
@testable import ImmichApp

final class PhotoEditRecipeTests: XCTestCase {
    func testRecipeRoundTripRetainsIndependentSourceCropFramingGeometryAndEffects() throws {
        var recipe = PhotoEditRecipe()
        recipe.crop = CGRect(x: 0.1, y: 0.2, width: 0.8, height: 0.6)
        recipe.framing = CGRect(x: 0.25, y: 0, width: 0.5, height: 1)
        recipe.quarterTurns = 3
        recipe.flipHorizontal = true
        recipe.straighten = 14.5
        recipe.perspectiveVertical = 0.35
        recipe.perspectiveHorizontal = -0.2
        recipe[.exposure] = 0.4
        recipe[.sharpness] = 0.75
        recipe.filter = .dramaticCool
        recipe.filterIntensity = 0.65

        let restored = try JSONDecoder().decode(PhotoEditRecipe.self, from: JSONEncoder().encode(recipe))

        XCTAssertEqual(restored, recipe)
        XCTAssertFalse(restored.isIdentity)
        XCTAssertEqual(restored.crop, recipe.crop)
        XCTAssertEqual(restored.framing, recipe.framing)
    }

    func testInvalidNumbersAndOutOfBoundsRectanglesCannotCreateAnInvalidRender() {
        var recipe = PhotoEditRecipe()
        recipe.crop = CGRect(x: 0.9, y: -0.4, width: 8, height: 2)
        recipe.framing = CGRect(x: CGFloat.nan, y: 0, width: 1, height: 1)
        recipe.quarterTurns = -5
        recipe.straighten = .infinity
        recipe.perspectiveVertical = -20
        recipe.adjustments = [.exposure: .nan, .sharpness: -0.2, .contrast: 4]
        let normalized = recipe.normalized()

        XCTAssertEqual(normalized.crop.minX, 0.9, accuracy: 0.000_001)
        XCTAssertEqual(normalized.crop.width, 0.1, accuracy: 0.000_001)
        XCTAssertEqual(normalized.crop.minY, 0)
        XCTAssertEqual(normalized.crop.height, 1)
        XCTAssertEqual(normalized.framing, CGRect(x: 0, y: 0, width: 1, height: 1))
        XCTAssertEqual(normalized.quarterTurns, 3)
        XCTAssertEqual(normalized.straighten, 0)
        XCTAssertEqual(normalized.perspectiveVertical, -1)
        XCTAssertEqual(normalized[.exposure], 0)
        XCTAssertEqual(normalized[.sharpness], 0)
        XCTAssertEqual(normalized[.contrast], 1)
    }

    func testCropResetPreservesColorAndFilterAndAnAspectLockAloneDoesNotAlterPixels() {
        var recipe = PhotoEditRecipe()
        recipe.cropAspectRatio = nil
        XCTAssertTrue(recipe.isIdentity)
        recipe.crop = CGRect(x: 0.2, y: 0, width: 0.5, height: 1)
        recipe.framing = CGRect(x: 0, y: 0.2, width: 1, height: 0.5)
        recipe.flipVertical = true
        recipe.quarterTurns = 1
        recipe.straighten = 12
        recipe.perspectiveHorizontal = 0.4
        recipe[.warmth] = 0.6
        recipe.filter = .mono

        recipe.resetGeometry()

        XCTAssertEqual(recipe.crop, PhotoEditRecipe().crop)
        XCTAssertEqual(recipe.framing, PhotoEditRecipe().framing)
        XCTAssertEqual(recipe.quarterTurns, 0)
        XCTAssertFalse(recipe.flipVertical)
        XCTAssertEqual(recipe.straighten, 0)
        XCTAssertEqual(recipe.perspectiveHorizontal, 0)
        XCTAssertEqual(recipe[.warmth], 0.6)
        XCTAssertEqual(recipe.filter, .mono)
    }

    func testImportedServerCropAndReflectionAxesUseTheDocumentedOriginalCoordinates() throws {
        let edits = try records(#"[{"action":"crop","parameters":{"x":20,"y":30,"width":100,"height":50}},{"action":"mirror","parameters":{"axis":"horizontal"}}]"#)
        let recipe = PhotoEditRecipe(serverEdits: edits, originalPixelSize: CGSize(width: 200, height: 100))

        XCTAssertEqual(recipe.crop, CGRect(x: 0.1, y: 0.3, width: 0.5, height: 0.5))
        XCTAssertEqual(recipe.framing, PhotoEditRecipe().framing)
        XCTAssertFalse(recipe.flipHorizontal)
        XCTAssertTrue(recipe.flipVertical, "An Immich horizontal reflection flips Y, not X")
        XCTAssertEqual(recipe.quarterTurns, 0)
    }

    func testMalformedServerGeometryCannotTrapOrInventAMirror() throws {
        let edits = try records(#"[{"action":"rotate","parameters":{"angle":1e300}},{"action":"rotate","parameters":{"angle":45}},{"action":"mirror","parameters":{"axis":"unknown"}},{"action":"mirror","parameters":{}}]"#)
        let recipe = PhotoEditRecipe(serverEdits: edits, originalPixelSize: CGSize(width: 200, height: 100))

        XCTAssertTrue(recipe.isIdentity)
    }

    private func records(_ json: String) throws -> [AssetEditRecord] {
        try JSONDecoder().decode([AssetEditRecord].self, from: Data(json.utf8))
    }
}

@MainActor
final class PhotoEditHistoryTests: XCTestCase {
    func testOneSliderGestureHasOneUndoEntryAndANewEditDiscardsOnlyTheRedoBranch() {
        let history = PhotoEditHistory(recipe: PhotoEditRecipe())
        history.editingChanged(true)
        for step in 1...10 {
            var value = history.recipe
            value[.exposure] = Double(step) / 10
            history.update(value)
        }
        history.editingChanged(false)
        XCTAssertTrue(history.canUndo)
        XCTAssertFalse(history.canRedo)
        XCTAssertTrue(history.isDirty)

        history.undo()

        XCTAssertTrue(history.recipe.isIdentity)
        XCTAssertFalse(history.canUndo, "Ten continuous updates must coalesce into one undo step")
        XCTAssertTrue(history.canRedo)
        history.redo()
        XCTAssertEqual(history.recipe[.exposure], 1)
        history.undo()
        var replacement = history.recipe
        replacement.filter = .noir
        history.update(replacement)
        XCTAssertEqual(history.recipe.filter, .noir)
        XCTAssertFalse(history.canRedo)
        history.undo()
        XCTAssertTrue(history.recipe.isIdentity)
        XCTAssertFalse(history.isDirty)
    }

    func testUndoRestoresTheOpenedRecipeInsteadOfDiscardingItsPreviouslySavedEdits() {
        var initial = PhotoEditRecipe()
        initial[.saturation] = 0.3
        initial.quarterTurns = 1
        let history = PhotoEditHistory(recipe: initial)
        var change = initial
        change[.exposure] = -0.4
        history.update(change)

        history.undo()

        XCTAssertEqual(history.recipe, initial)
        XCTAssertFalse(history.isDirty)
        XCTAssertFalse(history.recipe.isIdentity)
        XCTAssertTrue(history.canRedo)
    }
}
