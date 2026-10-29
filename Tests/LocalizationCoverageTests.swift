import Foundation
import XCTest
@testable import ImmichApp

@MainActor
final class LocalizationCoverageTests: XCTestCase {
    private let argumentExpression = try! NSRegularExpression(pattern: #"%%|%(?:(\d+)\$)?(lld|llu|ld|lu|@|d|u|f|s)"#)

    func testMemoryAgesUseRussianFewAndManyForms() throws {
        let russian = try localizedBundle(Bundle.main, language: "ru")
        XCTAssertEqual(String(localized: "\(2) years ago", bundle: russian,
            locale: Locale(identifier: "ru")), "2 года назад")
        XCTAssertEqual(String(localized: "\(5) years ago", bundle: russian,
            locale: Locale(identifier: "ru")), "5 лет назад")
    }

    func testGenericCountsUseNativeGrammarWithoutRawInflectionMarkup() throws {
        let english = try localizedBundle(Bundle.main, language: "en")
        XCTAssertEqual(String(localized: "\(1) items", bundle: english, locale: Locale(identifier: "en")), "1 item")
        XCTAssertEqual(String(localized: "\(1) People", bundle: english, locale: Locale(identifier: "en")), "1 Person")
        let selected = String(localized: "^[\(1) Photo](inflect: true) Selected", bundle: english,
            locale: Locale(identifier: "en"))
        XCTAssertEqual(selected, "1 Photo Selected")
        let russian = try localizedBundle(Bundle.main, language: "ru")
        XCTAssertEqual(String(localized: "\(2) People", bundle: russian, locale: Locale(identifier: "ru")).lowercased(), "2 человека")
        XCTAssertEqual(String(localized: "\(5) People", bundle: russian, locale: Locale(identifier: "ru")).lowercased(), "5 человек")
        XCTAssertEqual(String(localized: "\(2) Results", bundle: russian, locale: Locale(identifier: "ru")).lowercased(), "2 результата")
        XCTAssertEqual(String(localized: "\(5) Results", bundle: russian, locale: Locale(identifier: "ru")).lowercased(), "5 результатов")
        let polish = try localizedBundle(Bundle.main, language: "pl")
        XCTAssertEqual(String(localized: "\(2) items", bundle: polish, locale: Locale(identifier: "pl")).lowercased(), "2 elementy")
        XCTAssertEqual(String(localized: "\(5) items", bundle: polish, locale: Locale(identifier: "pl")).lowercased(), "5 elementów")
    }

    func testArgumentValidationAllowsReorderingButRejectsLostOrWrongSlots() {
        let source = arguments(in: "%@ of %@ used")
        XCTAssertEqual(source, arguments(in: "%2$@ 中 %1$@ を使用"))
        XCTAssertNotEqual(source, arguments(in: "%1$@ 中 %1$@ を使用"))
        XCTAssertNotEqual(source, arguments(in: "%3$@ 中 %1$@ を使用"))
        XCTAssertNotEqual(source, arguments(in: "%1$lld 中 %2$@ を使用"))
        XCTAssertNotEqual(source, arguments(in: "%2$@ 中 %@ を使用"))
        XCTAssertEqual(arguments(in: "100%% finished: %lld"), ["1:lld"])
        XCTAssertTrue(validArguments(source: "%lld photos", translation: "صورتان", category: "two", language: "ar"))
        XCTAssertFalse(validArguments(source: "%lld photos", translation: "صور", category: "other", language: "ar"))
        XCTAssertFalse(validArguments(source: "%lld photos", translation: "photos", category: "one", language: "en"))
        XCTAssertFalse(validArguments(source: "%lld %@", translation: "صورتان", category: "two", language: "ar"))
    }

    private func localizedBundle(_ bundle: Bundle, language: String) throws -> Bundle {
        let url = try XCTUnwrap(bundle.url(forResource: language, withExtension: "lproj"), "Missing \(language) resources")
        return try XCTUnwrap(Bundle(url: url))
    }

    private func validArguments(source: String, translation: String, category: String?, language: String) -> Bool {
        let expected = arguments(in: source)
        let actual = arguments(in: translation)
        if actual == expected { return true }
        // Arabic/Hebrew can spell a fixed count in the singular or dual noun.
        return actual.isEmpty && expected == ["1:lld"] && ["ar", "he"].contains(language)
            && ["zero", "one", "two"].contains(category ?? "")
    }

    private func arguments(in value: String) -> [String] {
        let range = NSRange(value.startIndex..., in: value)
        var nextArgument = 1
        var explicitArguments = false
        var implicitArguments = false
        var result = argumentExpression.matches(in: value, range: range).compactMap { match -> String? in
            guard let type = Range(match.range(at: 2), in: value) else { return nil }
            let explicit = Range(match.range(at: 1), in: value).flatMap { Int(value[$0]) }
            let position = explicit ?? nextArgument
            if explicit == nil { nextArgument += 1; implicitArguments = true }
            else { explicitArguments = true }
            return "\(position):\(value[type])"
        }
        if explicitArguments && implicitArguments { result.append("INVALID-MIXED-ARGUMENTS") }
        return result.sorted()
    }
}
