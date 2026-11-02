import Foundation
import XCTest
@testable import ImmichApp

@MainActor
final class AppBrandingTests: XCTestCase {
    private let credit = "Based on SelfPhotos by rendiwijiatmoko"

    func testCompiledProductsUseImmiWhilePreservingInstalledBundleAndModelIdentities() throws {
        XCTAssertEqual(Bundle.main.bundleURL.lastPathComponent, "Immi.app")
        XCTAssertTrue(String(reflecting: CachedAsset.self).hasPrefix("ImmichApp."),
            "Branding must preserve the existing persistent-model module")
        for target in try bundles() {
            XCTAssertEqual(target.bundle.bundleIdentifier, target.identifier)
            XCTAssertEqual(target.bundle.infoDictionary?["CFBundleDisplayName"] as? String, target.name)
            let name = try XCTUnwrap(target.bundle.infoDictionary?["CFBundleName"] as? String)
            XCTAssertFalse(containsOldBrand(name), name)
        }
        let icons = try XCTUnwrap(Bundle.main.infoDictionary?["CFBundleIcons"] as? [String: Any])
        let primary = try XCTUnwrap(icons["CFBundlePrimaryIcon"] as? [String: Any])
        XCTAssertEqual(primary["CFBundleIconName"] as? String, "immi")
    }

    func testCompiledDisplayNamesAndPrivacyDescriptionsUseImmiInEverySupportedLanguage() throws {
        let languages = try supportedLanguages()
        for target in try bundles() {
            for language in languages {
                let bundle = try localizedBundle(target.bundle, language: language)
                let fallback = target.name == "Upload to Immi" ? target.name : "MISSING-NAME"
                let name = bundle.localizedString(forKey: "CFBundleDisplayName", value: fallback, table: "InfoPlist")
                XCTAssertNotEqual(name, "MISSING-NAME", "\(target.name): \(language)")
                XCTAssertTrue(name.contains("Immi"), "\(target.name): \(language): \(name)")
                XCTAssertFalse(containsOldBrand(name), name)
                if target.name == "Immi" || target.name == "Upload to Immi" {
                    XCTAssertEqual(name, target.name, language)
                }
            }
        }
        for language in languages {
            let bundle = try localizedBundle(.main, language: language)
            for key in ["NSPhotoLibraryUsageDescription", "NSLocalNetworkUsageDescription", "NSLocationWhenInUseUsageDescription"] {
                let message = bundle.localizedString(forKey: key, value: "MISSING-PURPOSE", table: "InfoPlist")
                XCTAssertNotEqual(message, "MISSING-PURPOSE", "\(language): \(key)")
                XCTAssertTrue(message.contains("Immi"), "\(language): \(key): \(message)")
                XCTAssertFalse(containsOldBrand(message), message)
            }
        }
    }

    func testCatalogsContainTheOldNameOnlyInTheIntentionalUpstreamCredit() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let paths = ["ImmichApp/Resources/Localizable.xcstrings", "ImmichApp/Resources/InfoPlist.xcstrings",
            "ImmichWidgets/Localizable.xcstrings", "ImmichWidgets/InfoPlist.xcstrings",
            "ImmiShareExtension/Localizable.xcstrings", "ImmiShareExtension/InfoPlist.xcstrings"]
        var foundCredit = false
        for path in paths {
            let data = try Data(contentsOf: root.appendingPathComponent(path))
            let catalog = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            let entries = try XCTUnwrap(catalog["strings"] as? [String: Any])
            XCTAssertFalse(entries.isEmpty, path)
            for (key, entry) in entries {
                if path == paths[0], key == credit {
                    foundCredit = true
                    continue
                }
                XCTAssertFalse(containsOldBrand(key), "\(path): \(key)")
                for value in stringValues(in: entry) {
                    XCTAssertFalse(containsOldBrand(value), "\(path): \(key): \(value)")
                }
            }
        }
        XCTAssertTrue(foundCredit, "Rebranding must retain the explicit upstream credit")
    }

    func testUpstreamCreditIsCompiledInEverySupportedLanguage() throws {
        for language in try supportedLanguages() {
            let bundle = try localizedBundle(.main, language: language)
            let message = bundle.localizedString(forKey: credit, value: "MISSING-CREDIT", table: nil)
            XCTAssertNotEqual(message, "MISSING-CREDIT", language)
            XCTAssertTrue(message.contains("SelfPhotos"), "\(language): \(message)")
            XCTAssertTrue(message.contains("rendiwijiatmoko"), "\(language): \(message)")
        }
    }

    func testNewAndLegacyNavigationSchemesOpenTheSameDestinations() throws {
        let navigation = AppNavigation.shared
        let previous = navigation.pendingDestination
        defer { restore(previous, in: navigation) }
        let destinations: [(String, AppNavigation.Destination)] = [
            ("favorites", .favorites), ("search", .search), ("memories", .memories), ("album/album-id", .album("album-id"))
        ]
        let urlTypes = try XCTUnwrap(Bundle.main.infoDictionary?["CFBundleURLTypes"] as? [[String: Any]])
        let registered = Set(urlTypes.flatMap { $0["CFBundleURLSchemes"] as? [String] ?? [] })
        for scheme in ["immi", "selfphotos", "immiches"] {
            XCTAssertTrue(registered.contains(scheme), "Existing links must remain registered with iOS: \(scheme)")
            for (path, expected) in destinations {
                restore(nil, in: navigation)
                navigation.handle(try XCTUnwrap(URL(string: "\(scheme)://\(path)")))
                XCTAssertEqual(navigation.pendingDestination, expected, "\(scheme)://\(path)")
                navigation.consume(expected)
                XCTAssertNil(navigation.pendingDestination)
            }
        }
        navigation.handle(try XCTUnwrap(URL(string: "IMMI://FAVORITES")))
        XCTAssertEqual(navigation.pendingDestination, .favorites)
    }

    func testUnrelatedSchemesAndIncompleteLinksCannotReplaceAPendingDestination() throws {
        let navigation = AppNavigation.shared
        let previous = navigation.pendingDestination
        defer { restore(previous, in: navigation) }
        for link in ["https://favorites", "immi://album", "immi://unknown", "unrelated://search"] {
            navigation.open(.memories)
            navigation.handle(try XCTUnwrap(URL(string: link)))
            XCTAssertEqual(navigation.pendingDestination, .memories, link)
        }
    }

    private func bundles() throws -> [(bundle: Bundle, name: String, identifier: String)] {
        let plugins = try XCTUnwrap(Bundle.main.builtInPlugInsURL)
        let products = [("ImmiShareExtension", "Immi", "xyz.0xmwehehe.ImmichApp.ShareExtension"),
            ("ImmiUploadAction", "Upload to Immi", "xyz.0xmwehehe.ImmichApp.UploadAction"),
            ("ImmichWidgets", "Immi Widgets", "xyz.0xmwehehe.ImmichApp.ImmichWidgets")]
        return [(Bundle.main, "Immi", "xyz.0xmwehehe.ImmichApp")] + (try products.map { product in
            (try XCTUnwrap(Bundle(url: plugins.appendingPathComponent("\(product.0).appex"))), product.1, product.2)
        })
    }

    private func supportedLanguages() throws -> [String] {
        let languages = try XCTUnwrap(Bundle.main.infoDictionary?["CFBundleLocalizations"] as? [String])
        XCTAssertGreaterThan(languages.count, 1)
        return languages
    }

    private func localizedBundle(_ bundle: Bundle, language: String) throws -> Bundle {
        let path = bundle.bundleURL.appendingPathComponent("\(language).lproj", isDirectory: true)
        return try XCTUnwrap(Bundle(url: path), "Missing \(language) resources in \(bundle.bundleURL.lastPathComponent)")
    }

    private func containsOldBrand(_ text: String) -> Bool {
        text.range(of: "selfphotos", options: .caseInsensitive) != nil
            || text.range(of: "self photos", options: .caseInsensitive) != nil
    }

    private func stringValues(in value: Any) -> [String] {
        if let dictionary = value as? [String: Any] {
            return dictionary.flatMap { key, value in
                key == "value" ? (value as? String).map { [$0] } ?? [] : stringValues(in: value)
            }
        }
        return (value as? [Any])?.flatMap { stringValues(in: $0) } ?? []
    }

    private func restore(_ destination: AppNavigation.Destination?, in navigation: AppNavigation) {
        if let current = navigation.pendingDestination { navigation.consume(current) }
        if let destination { navigation.open(destination) }
    }
}
