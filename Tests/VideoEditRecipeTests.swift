import AVFoundation
import XCTest
@testable import ImmichApp

@MainActor
final class VideoEditRecipeTests: XCTestCase {
    func testInvalidRangesRatesAndKeyPhotosAreRejectedInsteadOfSilentlyEditingAnotherFrame() {
        for recipe in [VideoEditRecipe(trimStart: -1), VideoEditRecipe(trimEnd: 4), VideoEditRecipe(trimStart: 2, trimEnd: 1),
            VideoEditRecipe(rate: .nan), VideoEditRecipe(rate: 0), VideoEditRecipe(trimStart: .infinity),
            VideoEditRecipe(trimStart: 3.0005, trimEnd: 3.0008), VideoEditRecipe(trimStart: 1, trimEnd: 1.000001)] {
            XCTAssertThrowsError(try recipe.selection(duration: 3))
        }
        XCTAssertThrowsError(try LivePhotoEditRecipe(keyPhotoTime: 0.5).validatedPhotoTime(video: VideoEditRecipe(trimStart: 1), duration: 3))
        XCTAssertThrowsError(try LivePhotoEditRecipe(keyPhotoTime: .nan).validatedPhotoTime(video: VideoEditRecipe(), duration: 3))
    }

    func testTrimHandlesCannotInvertAClipShorterThanItsNominalFrameDuration() throws {
        var recipe = VideoEditRecipe()
        recipe.setTrimBoundary(.start, to: 1, duration: 0.01, frameRate: 30)
        recipe.setTrimBoundary(.end, to: -1, duration: 0.01, frameRate: 30)
        XCTAssertEqual(recipe.trimStart, 0)
        XCTAssertEqual(recipe.trimEnd, 0.01)
        XCTAssertEqual(try recipe.selection(duration: 0.01).duration.seconds, 0.01, accuracy: 0.0001)
        let previous = recipe
        recipe.setTrimBoundary(.start, to: .nan, duration: 0.01, frameRate: 30)
        XCTAssertEqual(recipe, previous)
        recipe = VideoEditRecipe(trimStart: 2.999)
        recipe.setTrimBoundary(.end, to: 0, duration: 3, frameRate: 30)
        XCTAssertEqual(recipe.trimEnd, 3)
        XCTAssertNoThrow(try recipe.selection(duration: 3))
    }
}
