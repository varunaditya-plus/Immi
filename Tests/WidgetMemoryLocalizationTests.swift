import XCTest
@testable import ImmichApp

final class WidgetMemoryLocalizationTests: XCTestCase {
    func testWidgetBundleUsesTheRequestedLocaleInsteadOfItsProcessLanguage() throws {
        let plugins = try XCTUnwrap(Bundle.main.builtInPlugInsURL)
        let widget = try XCTUnwrap(Bundle(url: plugins.appendingPathComponent("ImmichWidgets.appex")))
        let memory = WidgetMemory(id: "memory", title: "English", subtitle: "English", imageName: nil, yearsAgo: 2)

        XCTAssertEqual(memory.localizedTitle(bundle: widget, locale: Locale(identifier: "fr_FR")), "il y a 2 ans")
    }

    func testCachedEnglishMemoryUsesTheWidgetsFrenchAgeAndDate() throws {
        let memory = try decode("""
        {"id":"memory","title":"2 years ago","subtitle":"January 1, 2020",
         "imageName":"photo.image","memoryAt":"2020-01-01T00:00:00Z","yearsAgo":2}
        """)
        let french = try widgetBundle("fr")

        XCTAssertEqual(memory.localizedTitle(bundle: french, locale: Locale(identifier: "fr_FR")), "il y a 2 ans")
        XCTAssertEqual(memory.localizedSubtitle(locale: Locale(identifier: "fr_FR")), "1 janvier 2020")
        XCTAssertEqual(memory.imageName, "photo.image")
    }

    func testSameSnapshotCanChooseRussianPluralFormsWithoutAnotherExport() throws {
        let russian = try widgetBundle("ru")
        for (years, expected) in [(2, "2 года назад"), (5, "5 лет назад")] {
            let memory = WidgetMemory(id: "memory", title: "English", subtitle: "English", imageName: nil,
                yearsAgo: years)

            XCTAssertEqual(memory.localizedTitle(bundle: russian, locale: Locale(identifier: "ru")), expected)
        }
    }

    func testLegacySnapshotKeepsItsPhotoWithoutLeakingOldLanguageCaptions() throws {
        let memory = try decode("""
        {"id":"legacy","title":"5 years ago","subtitle":"August 9, 2021","imageName":"legacy.image"}
        """)

        XCTAssertEqual(memory.localizedTitle(bundle: try widgetBundle("fr"),
            locale: Locale(identifier: "fr_FR")), "Souvenirs")
        XCTAssertNil(memory.localizedSubtitle(locale: Locale(identifier: "fr_FR")))
        XCTAssertEqual(memory.imageName, "legacy.image")
    }

    func testThisYearAndCivilDateDoNotShiftToThePreviousDay() throws {
        let memory = WidgetMemory(id: "memory", title: "This year", subtitle: "English", imageName: nil,
            memoryAt: try XCTUnwrap(ISO8601DateFormatter().date(from: "2020-01-01T00:00:00Z")), yearsAgo: 0)
        let locale = Locale(identifier: "fr_US")

        XCTAssertEqual(memory.localizedTitle(bundle: try widgetBundle("fr"), locale: locale), "Cette année")
        XCTAssertEqual(memory.localizedSubtitle(locale: locale), "1 janvier 2020")
    }

    private func decode(_ json: String) throws -> WidgetMemory {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(WidgetMemory.self, from: Data(json.utf8))
    }

    private func widgetBundle(_ language: String) throws -> Bundle {
        let plugins = try XCTUnwrap(Bundle.main.builtInPlugInsURL)
        let widget = try XCTUnwrap(Bundle(url: plugins.appendingPathComponent("ImmichWidgets.appex")))
        let url = try XCTUnwrap(widget.url(forResource: language, withExtension: "lproj"))
        return try XCTUnwrap(Bundle(url: url))
    }
}
