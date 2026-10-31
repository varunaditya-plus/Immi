import Foundation
import XCTest
@testable import ImmichApp

@MainActor
final class LocalizationCoverageTests: XCTestCase {
    private let argumentExpression = try! NSRegularExpression(pattern: #"%%|%(?:(\d+)\$)?(lld|llu|ld|lu|@|d|u|f|s)"#)
    private let languages = ["ar", "bg", "bn", "ca", "cs", "da", "de", "el", "es", "fa", "fi", "fr",
        "he", "hi", "hr", "hu", "id", "it", "ja", "kk", "ko", "lt", "ms", "nb", "nl", "pl",
        "pt", "ro", "ru", "sk", "sl", "sv", "th", "tr", "uk", "vi", "zh-Hans", "zh-Hant"]

    func testEveryCatalogEntryHasAllSupportedTranslationsAndValidFormatArguments() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        for path in ["ImmichApp/Resources/Localizable.xcstrings", "ImmichApp/Resources/InfoPlist.xcstrings", "ImmichWidgets/Localizable.xcstrings",
                     "SelfPhotosShareExtension/Localizable.xcstrings"] {
            let data = try Data(contentsOf: root.appendingPathComponent(path))
            let catalog = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            let entries = try XCTUnwrap(catalog["strings"] as? [String: [String: Any]])
            XCTAssertFalse(entries.isEmpty)
            for (key, entry) in entries {
                guard !key.isEmpty else { continue }
                if entry["shouldTranslate"] as? Bool == false {
                    XCTAssertFalse(key.hasSuffix("UsageDescription"), "Permission explanations must remain localized: \(key)")
                    continue
                }
                let translations = try XCTUnwrap(entry["localizations"] as? [String: [String: Any]], "Missing translations: \(key)")
                for language in languages {
                    let translation = try XCTUnwrap(translations[language], "\(path): \(language): \(key)")
                    let values = stringValues(in: translation)
                    XCTAssertFalse(values.isEmpty, "\(language): \(key)")
                    for form in values {
                        let value = form.value
                        XCTAssertFalse(value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                            "\(language): \(key)")
                        XCTAssertTrue(validArguments(source: key, translation: value,
                            category: form.category, language: language), "\(language): \(key): \(value)")
                    }
                    if let variations = translation["variations"] as? [String: Any],
                       let plural = variations["plural"] as? [String: Any] {
                        XCTAssertNotNil(plural["other"], "A plural resource requires its fallback form")
                    }
                }
            }
        }
    }

    func testPhotosBrowsingAndAlbumControlsAreInEveryCompiledLocalization() throws {
        let keys = ["Collections", "All Items", "Recently Added", "Date Captured", "View Options",
            "Aspect Ratio Grid", "Edited", "Not in an Album", "Pinned", "New Folder", "Custom Order",
            "Choose Key Photo", "Activity", "Send Comment", "View Personal Albums", "Collapse %@", "Expand %@",
            "Recently Added is unavailable for device photos.", "Screenshots filtering is unavailable for server photos."]
        for language in languages {
            let bundle = try localizedBundle(Bundle.main, language: language)
            for key in keys { assertCompiled(key, in: bundle) }
        }
        let french = try localizedBundle(Bundle.main, language: "fr")
        XCTAssertEqual(french.localizedString(forKey: "New Folder", value: nil, table: nil), "Nouveau dossier")
        let arabic = try localizedBundle(Bundle.main, language: "ar")
        XCTAssertNotEqual(arabic.localizedString(forKey: "Send Comment", value: nil, table: nil), "Send Comment")
    }

    func testPeopleGroupsAndMapControlsAreInEveryCompiledLocalization() throws {
        let keys = ["Groups", "Group Options", "Group Name", "Create New Group", "Edit Name and People",
            "Edit Name and Photos", "Name This Person", "Edit Key Photo", "Make Key Photo", "Faces",
            "Merge", "Merge Photos", "Merge People", "Merge These People?", "Hidden People", "No Hidden People", "This is Not %@",
            "Sort by Custom Order", "Sort by Name", "Other People", "Group Unavailable", "No Group Photos",
            "Groups are saved on this device.", "The server did not provide people information for group photos.",
            "Choose Map", "Explore", "Satellite", "Show Map", "Show Nearby Photos", "Hide Nearby Photos",
            "No Photos with Location", "Photos and videos with location information appear here."]
        for language in languages {
            let bundle = try localizedBundle(Bundle.main, language: language)
            for key in keys { assertCompiled(key, in: bundle) }
        }
        let french = try localizedBundle(Bundle.main, language: "fr")
        XCTAssertEqual(french.localizedString(forKey: "Faces", value: nil, table: nil), "Visages")
        XCTAssertEqual(french.localizedString(forKey: "Choose Map", value: nil, table: nil), "Choisir un plan")
        let arabic = try localizedBundle(Bundle.main, language: "ar")
        XCTAssertEqual(arabic.localizedString(forKey: "Faces", value: nil, table: nil), "الوجوه",
            "The face view refers to people’s faces, not interface surfaces")
        let persian = try localizedBundle(Bundle.main, language: "fa")
        XCTAssertEqual(persian.localizedString(forKey: "Groups", value: nil, table: nil), "گروه‌ها")
        let name = "Ada"
        for language in ["fr", "ar", "fa"] {
            let bundle = try localizedBundle(Bundle.main, language: language)
            let correction = String(localized: "This is Not \(name)", bundle: bundle, locale: Locale(identifier: language))
            XCTAssertTrue(correction.contains(name), correction)
            XCTAssertFalse(correction.contains("%@"), correction)
            XCTAssertNotEqual(correction, "This is Not Ada", correction)
        }
    }

    func testOptionalPhotoMapLocationPermissionIsLocalizedInEveryCompiledBundle() throws {
        let key = "NSLocationWhenInUseUsageDescription"
        for language in languages {
            let bundle = try localizedBundle(Bundle.main, language: language)
            let message = bundle.localizedString(forKey: key, value: "MISSING-PERMISSION", table: "InfoPlist")
            XCTAssertNotEqual(message, "MISSING-PERMISSION", "Missing \(language) location permission")
            XCTAssertFalse(message.isEmpty)
            XCTAssertTrue(message.contains("SelfPhotos"), message)
        }
        let french = try localizedBundle(Bundle.main, language: "fr")
        let message = french.localizedString(forKey: key, value: nil, table: "InfoPlist")
        XCTAssertTrue(message.contains("uniquement"), "Permission must describe the user-triggered location action")
        XCTAssertFalse(message.contains("uses your location"))
    }

    func testRecentUserFacingErrorsAndPaginationAreInCompiledAppResources() throws {
        let keys = ["The server took too long to respond. Try again.",
            "The connection to the server was lost. Try again.",
            "Network access is restricted. Check your connection settings.", "Incorrect PIN. Try again.", "Load More", "Loading More…", "Failed to load more photos",
            "Search returned an incomplete page. Please try again.", "Selects this item.",
            "Deselects this item.", "Opens the viewer.", "Shows this item in the viewer.",
            "Unable to play video. Try again.", "Unable to play Live Photo. Touch and hold to try again.",
            "Automatic Backup Off", "Accessible Photos Backed Up", "Shared Uploads", "Upload Details",
            "Sign In with OAuth", "The local sync database could not be exported.",
            "The local sync database is temporarily unavailable.",
            "The previous local cache could not be opened: %@", "Backup mapping protection is unavailable: %@",
            "Connect to the server before running this job.",
            "Connect to Wi-Fi before reading and hashing your photo library.",
            "Allow Photos access to read the library on this device.", "Your photo library changed. Try again.",
            "Sign in to verify the copies on your server before removing device copies.",
            "A device or server copy changed or could not be verified. Refresh the photos and try again.",
            "Photos could not confirm which device copies were removed.",
            "Allow Photos access to verify the copies on this device.",
            "Your photo library changed. Scan again before removing device copies.", "Unknown Location", "Untitled"]
        for language in languages {
            let bundle = try localizedBundle(Bundle.main, language: language)
            for key in keys { assertCompiled(key, in: bundle) }
        }
        let french = try localizedBundle(Bundle.main, language: "fr")
        XCTAssertEqual(french.localizedString(forKey: "Load More", value: nil, table: nil), "Charger plus")
    }

    func testSharingOptionsAndSlideshowAreInEveryCompiledLocalization() throws {
        let keys = [
            "%lld Photos Selected", "%lld Videos Selected", "%lld of %lld",
            "1 Photo Selected", "1 Video Selected", "Automatic",
            "Automatic lets the destination choose a format. Current keeps the file format. Most Compatible uses JPEG, PNG, or H.264.", "Copy", "Copy Items",
            "Copy Photo", "Copy Photos", "Copy Video",
            "Could not convert this photo or video for sharing.", "Could not copy these items.", "Could not remove location information from this file.",
            "Current", "Export Unmodified Original", "Export Unmodified Originals",
            "Format", "Include", "Item %lld",
            "Location Is Included", "Location Is Not Included", "Most Compatible",
            "Next", "Options", "Pause",
            "Play", "Previous", "Replay",
            "Slideshow", "Some items could not be prepared. Only the available items are selected.", "Some items could not be prepared. Please try again.",
            "This photo or video format cannot be shared.", "Unmodified originals include their original metadata. Turn on Location to export them."
        ]
        for language in ["en"] + languages {
            let bundle = try localizedBundle(Bundle.main, language: language)
            for key in keys { assertCompiled(key, in: bundle) }
        }
        let french = try localizedBundle(Bundle.main, language: "fr")
        XCTAssertEqual(french.localizedString(forKey: "Export Unmodified Original", value: nil, table: nil),
            "Exporter l’original non modifié")
        XCTAssertEqual(String(localized: "\(2) of \(7)", bundle: french, locale: Locale(identifier: "fr")), "2 sur 7")
        let arabic = try localizedBundle(Bundle.main, language: "ar")
        XCTAssertEqual(String(localized: "\(2) Photos Selected", bundle: arabic, locale: Locale(identifier: "ar")),
            "تم تحديد صورتين")
        let polish = try localizedBundle(Bundle.main, language: "pl")
        for (count, expected) in [(2, "zdjęcia"), (5, "zdjęć")] {
            let value = String(localized: "\(count) Photos Selected", bundle: polish, locale: Locale(identifier: "pl"))
            XCTAssertTrue(value.contains(expected), value)
            XCTAssertTrue(value.contains(String(count)), value)
        }
        let bengali = try localizedBundle(Bundle.main, language: "bn")
        let progress = String(localized: "\(2) of \(7)", bundle: bengali, locale: Locale(identifier: "en"))
        XCTAssertEqual(progress, "7টির মধ্যে 2টি", "A translated progress label must retain ordinal and total meaning")
    }

    func testSettingsCountsChooseEnglishAndRussianPluralForms() throws {
        let english = try localizedBundle(Bundle.main, language: "en")
        XCTAssertEqual(SettingsView.assetCounts(images: 1, videos: 2, bundle: english,
            locale: Locale(identifier: "en")), "1 Photo, 2 Videos")
        let russian = try localizedBundle(Bundle.main, language: "ru")
        for (amount, expected) in [(1, "1 Фото"), (2, "2 Фото"), (5, "5 Фото")] {
            let value = SettingsView.assetCounts(images: amount, videos: 1, bundle: russian,
                locale: Locale(identifier: "ru"))
            XCTAssertTrue(value.localizedCaseInsensitiveContains(expected), value)
            XCTAssertTrue(value.localizedCaseInsensitiveContains("1 Видео"), value)
            XCTAssertFalse(value.contains("Photos") || value.contains("Videos"), value)
        }
    }

    func testSettingsCountsUsePolishSingularFewAndManyForms() throws {
        let polish = try localizedBundle(Bundle.main, language: "pl")
        for (amount, word) in [(1, "zdjęcie"), (2, "zdjęcia"), (5, "zdjęć")] {
            let value = SettingsView.assetCounts(images: amount, videos: 1, bundle: polish,
                locale: Locale(identifier: "pl"))
            XCTAssertTrue(value.localizedCaseInsensitiveContains(word), value)
            XCTAssertTrue(value.contains(String(amount)), value)
        }
    }

    func testSettingsCountsUseArabicDualForms() throws {
        let arabic = try localizedBundle(Bundle.main, language: "ar")
        let value = SettingsView.assetCounts(images: 2, videos: 2, bundle: arabic,
            locale: Locale(identifier: "ar"))
        XCTAssertTrue(value.contains("صورتان"), value)
        XCTAssertTrue(value.contains("مقطعا فيديو"), value)
    }

    func testStorageCaptionsPreserveUsedAndTotalWhenArgumentsChangeOrder() throws {
        for (language, expected) in [
            ("hi", "100 GB में से 42 GB का उपयोग हुआ"),
            ("ja", "100 GB 中 42 GB を使用"),
            ("ko", "100 GB 중 42 GB 사용됨"),
            ("zh-Hans", "已使用 42 GB，共 100 GB"),
            ("zh-Hant", "已使用 42 GB，共 100 GB")
        ] {
            let bundle = try localizedBundle(Bundle.main, language: language)
            XCTAssertEqual(SettingsView.storageCaption(used: "42 GB", total: "100 GB", bundle: bundle,
                locale: Locale(identifier: language)), expected)
        }
    }

    func testSyncTermsDescribeMediaAndServers() throws {
        let french = try localizedBundle(Bundle.main, language: "fr")
        XCTAssertEqual(french.localizedString(forKey: "Assets", value: nil, table: nil), "Éléments")
        XCTAssertEqual(french.localizedString(forKey: "Hash Assets", value: nil, table: nil), "Calculer les empreintes")
        let german = try localizedBundle(Bundle.main, language: "de")
        XCTAssertEqual(german.localizedString(forKey: "Remote", value: nil, table: nil), "Server")
        XCTAssertEqual(german.localizedString(forKey: "Sync Remote", value: nil, table: nil), "Mit dem Server synchronisieren")
    }

    func testRemovalCountsUseSingularEnglishForms() throws {
        let english = try localizedBundle(Bundle.main, language: "en")
        XCTAssertEqual(String(localized: "Move \(1) Items to Recently Deleted", bundle: english,
            locale: Locale(identifier: "en")), "Move 1 Item to Recently Deleted")
        XCTAssertEqual(String(localized: "\(1) items moved to Recently Deleted", bundle: english,
            locale: Locale(identifier: "en")), "1 item moved to Recently Deleted")
    }

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

    func testBackedUpCountsUseRussianFewAndManyForms() throws {
        let russian = try localizedBundle(Bundle.main, language: "ru")
        XCTAssertEqual(String(localized: "\(2) items backed up", bundle: russian, locale: Locale(identifier: "ru")),
            "2 элемента сохранены в резервной копии")
        XCTAssertEqual(String(localized: "\(5) items backed up", bundle: russian, locale: Locale(identifier: "ru")),
            "5 элементов сохранено в резервной копии")
    }

    func testCutoffPresetsUseCompleteLocalizedDurations() {
        XCTAssertEqual(FreeUpSpaceView.cutoffLabel(amount: 1, days: false, locale: Locale(identifier: "en")), "1 year")
        XCTAssertEqual(FreeUpSpaceView.cutoffLabel(amount: 2, days: false, locale: Locale(identifier: "en")), "2 years")
        XCTAssertEqual(FreeUpSpaceView.cutoffLabel(amount: 5, days: false, locale: Locale(identifier: "en")), "5 years")
        XCTAssertEqual(FreeUpSpaceView.cutoffLabel(amount: 30, days: true, locale: Locale(identifier: "ru")), "30 дней")
        XCTAssertEqual(FreeUpSpaceView.cutoffLabel(amount: 1, days: false, locale: Locale(identifier: "ru")), "1 год")
        XCTAssertEqual(FreeUpSpaceView.cutoffLabel(amount: 2, days: false, locale: Locale(identifier: "ru")), "2 года")
        XCTAssertEqual(FreeUpSpaceView.cutoffLabel(amount: 5, days: false, locale: Locale(identifier: "ru")), "5 лет")
        for language in languages {
            let locale = Locale(identifier: language)
            for (amount, days) in [(30, true), (60, true), (90, true), (1, false), (2, false), (3, false)] {
                let value = FreeUpSpaceView.cutoffLabel(amount: amount, days: days, locale: locale)
                XCTAssertFalse(value.isEmpty, "\(language): \(amount)")
                if ["ar", "ru", "zh-Hans", "zh-Hant"].contains(language) {
                    XCTAssertFalse(value.contains("year") || value.contains("day"), "\(language): \(value)")
                }
            }
        }
    }

    func testBothShareExtensionsContainTheirOwnCompiledTranslations() throws {
        let plugins = try XCTUnwrap(Bundle.main.builtInPlugInsURL)
        for name in ["SelfPhotosShareExtension.appex", "SelfPhotosUploadAction.appex"] {
            let shared = try XCTUnwrap(Bundle(url: plugins.appendingPathComponent(name)))
            for language in languages {
                let shareBundle = try localizedBundle(shared, language: language)
                assertCompiled("No supported photos or videos were shared.", in: shareBundle)
                assertCompiled("Open SelfPhotos to retry or remove failed uploads in Backup > View Details.", in: shareBundle)
            }
            let french = try localizedBundle(shared, language: "fr")
            let error = french.localizedString(forKey: "No supported photos or videos were shared.", value: nil, table: nil)
            XCTAssertTrue(error.contains("photo") && error.contains("vidéo"), error)
        }
    }

    func testWidgetContainsItsOwnCompiledTranslations() throws {
        let plugins = try XCTUnwrap(Bundle.main.builtInPlugInsURL)
        let widget = try XCTUnwrap(Bundle(url: plugins.appendingPathComponent("ImmichWidgets.appex")))
        for language in languages {
            let bundle = try localizedBundle(widget, language: language)
            assertCompiled("Favorites", in: bundle)
            assertCompiled("%lld years ago", in: bundle)
        }
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

    private func assertCompiled(_ key: String, in bundle: Bundle, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertNotEqual(bundle.localizedString(forKey: key, value: "MISSING-TRANSLATION", table: nil),
            "MISSING-TRANSLATION", "Missing compiled key: \(key)", file: file, line: line)
    }

    private struct CatalogForm {
        let category: String?
        let value: String
    }

    private func stringValues(in object: [String: Any]) -> [CatalogForm] {
        if let unit = object["stringUnit"] as? [String: Any], let value = unit["value"] as? String {
            return [CatalogForm(category: nil, value: value)]
        }
        if let variations = object["variations"] as? [String: Any],
           let plural = variations["plural"] as? [String: [String: Any]] {
            return plural.flatMap { category, value in
                stringValues(in: value).map { CatalogForm(category: category, value: $0.value) }
            }
        }
        return object.values.compactMap { $0 as? [String: Any] }.flatMap { stringValues(in: $0) }
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
