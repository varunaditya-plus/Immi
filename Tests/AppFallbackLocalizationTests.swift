import Foundation
import SwiftUI
import XCTest
@testable import ImmichApp

@MainActor
final class AppFallbackLocalizationTests: XCTestCase {
    private var directories: [URL] = []

    override func tearDown() async throws {
        for directory in directories { try? FileManager.default.removeItem(at: directory) }
        directories.removeAll()
        try await super.tearDown()
    }

    func testOAuthFallbackIsLocalizedButServerLabelRemainsVerbatim() async {
        let session = MockSessionManager()
        session.shouldSucceedPing = true
        session.mockFeatures = ServerFeaturesDTO(smartSearch: true, facialRecognition: true,
            oauth: true, passwordLogin: true, search: true)
        let model = OnboardingViewModel(session: session)
        let fallback = expected("Sign In with OAuth", "Se connecter avec OAuth")
        XCTAssertEqual(model.oauthButtonText, fallback)
        model.serverText = "https://fallback-localization.example"
        for label in [String?.none, " \n "] {
            session.mockOAuthButtonText = label
            let connected = await model.connectToServer()
            XCTAssertTrue(connected)
            XCTAssertEqual(model.oauthButtonText, fallback)
        }
        for label in ["Continue at Example SSO", "Sign In with OAuth"] {
            session.mockOAuthButtonText = "  \(label)  "
            let connected = await model.connectToServer()
            XCTAssertTrue(connected)
            XCTAssertEqual(model.oauthButtonText, label,
                "A server's custom label stays verbatim, including labels that match a catalog key")
        }
        model.prepareToEditServer()
        XCTAssertEqual(model.oauthButtonText, fallback)
        XCTAssertFalse(model.canSignInWithOIDC)
    }

    func testPhotoMaintenanceAndDeletionErrorsUseTheProcessLanguage() {
        let cases: [(any LocalizedError, String, String)] = [
            (DeviceAssetSyncError.offline, "Connect to the server before running this job.",
             "Connectez-vous au serveur avant d'exécuter cette tâche."),
            (DeviceAssetSyncError.meteredNetwork, "Connect to Wi-Fi before reading and hashing your photo library.",
             "Connectez-vous au Wi-Fi avant de lire les fichiers de votre photothèque et de calculer leurs empreintes."),
            (LocalPhotoLibraryError.accessRequired, "Allow Photos access to read the library on this device.",
             "Autorisez l'accès à Photos pour lire la photothèque sur cet appareil."),
            (LocalPhotoLibraryError.libraryChanged, "Your photo library changed. Try again.",
             "Votre photothèque a changé. Réessayez."),
            (DeviceCopySafetyError.signInRequired, "Sign in to verify the copies on your server before removing device copies.",
             "Connectez-vous pour vérifier les copies sur votre serveur avant de supprimer les copies de l'appareil."),
            (DeviceCopySafetyError.copiesChanged, "A device or server copy changed or could not be verified. Refresh the photos and try again.",
             "Une copie sur l'appareil ou le serveur a changé ou n'a pas pu être vérifiée. Actualisez les photos et réessayez."),
            (DeviceCopySafetyError.invalidDeletionResult, "Photos could not confirm which device copies were removed.",
             "Photos n'a pas pu confirmer quelles copies de l'appareil ont été supprimées."),
            (LocalSpaceLibraryError.accessRequired, "Allow Photos access to verify the copies on this device.",
             "Autorisez l'accès à Photos pour vérifier les copies sur cet appareil."),
            (LocalSpaceLibraryError.libraryChanged, "Your photo library changed. Scan again before removing device copies.",
             "Votre photothèque a changé. Lancez une nouvelle analyse avant de supprimer les copies de l'appareil.")
        ]
        for (error, english, french) in cases {
            XCTAssertEqual(error.localizedDescription, expected(english, french))
        }
    }

    func testDatabaseExportFailureUsesTheProcessLanguage() throws {
        let directory = try directory()
        do {
            try SwiftDataManager.createDatabaseSnapshot(from: directory.appendingPathComponent("missing.sqlite"),
                to: directory.appendingPathComponent("export.sqlite"))
            XCTFail("A missing store must fail export")
        } catch let error as LocalDatabaseMaintenanceError {
            XCTAssertEqual(error.localizedDescription, expected(
                "The local sync database could not be exported.",
                "La base de données de synchronisation locale n'a pas pu être exportée."))
            XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("export.sqlite").path))
        }
        XCTAssertEqual(LocalDatabaseMaintenanceError.persistentStoreUnavailable.localizedDescription, expected(
            "The local sync database is temporarily unavailable.",
            "La base de données de synchronisation locale est temporairement indisponible."))
    }

    func testCorruptDatabaseRecoveryWarningUsesTheProcessLanguage() throws {
        let directory = try directory()
        let store = directory.appendingPathComponent("corrupt.sqlite")
        try Data("not a SQLite database".utf8).write(to: store)
        let manager = SwiftDataManager(storeURL: store, backupJournalURL: directory.appendingPathComponent("journal.json"))

        guard case .recovered(let quarantinedStore, _, let warning) = manager.startupState else {
            return XCTFail("The corrupt store must take the recovery path")
        }
        XCTAssertNotNil(quarantinedStore)
        let message = try XCTUnwrap(warning)
        let prefix = expected("The previous local cache could not be opened: ",
            "Le cache local précédent n'a pas pu être ouvert : ")
        XCTAssertTrue(message.hasPrefix(prefix), message)
        XCTAssertGreaterThan(message.count, prefix.count, "The underlying storage error must remain visible")
    }

    func testUnreadableMappingJournalWarningUsesTheProcessLanguage() throws {
        let directory = try directory()
        let journal = directory.appendingPathComponent("journal.json", isDirectory: true)
        try FileManager.default.createDirectory(at: journal, withIntermediateDirectories: true)
        let manager = SwiftDataManager(storeURL: directory.appendingPathComponent("store.sqlite"), backupJournalURL: journal)

        guard case .protectionUnavailable(let message) = manager.startupState else {
            return XCTFail("An unreadable journal must retain its protection warning")
        }
        let prefix = expected("Backup mapping protection is unavailable: ",
            "La protection des correspondances de sauvegarde est indisponible : ")
        XCTAssertTrue(message.hasPrefix(prefix), message)
        XCTAssertGreaterThan(message.count, prefix.count, "The underlying journal error must remain visible")
    }

    func testMissingAlbumTitleIsLocalizedAndPhotoLibraryTitlesRemainVerbatim() {
        XCTAssertEqual(LocalPhotoLibrary.displayAlbumTitle(nil), expected("Untitled", "Sans titre"))
        for title in ["Untitled", "Family photos", "", "休暇"] {
            XCTAssertEqual(LocalPhotoLibrary.displayAlbumTitle(title), title,
                "A nonnil title belongs to the photo library, even if it matches the fallback")
        }
    }

    func testAssistiveAlbumFallbackUsesTheSelectionIDAndPreservesAlbumNames() {
        let defaults = UserDefaults.standard
        let keys = [AssistiveAccessPreferences.albumIDKey, AssistiveAccessPreferences.albumNameKey]
        let previous = keys.map { ($0, defaults.object(forKey: $0)) }
        defer {
            for (key, value) in previous {
                if let value { defaults.set(value, forKey: key) }
                else { defaults.removeObject(forKey: key) }
            }
        }
        for (id, name, label) in [
            ("", "", expected("None", "Aucun")),
            ("", "A stale album name", expected("None", "Aucun")),
            ("selected-album", "", expected("None", "Aucun")),
            ("selected-album", "None", "None"),
            ("selected-album", "Family photos", "Family photos")
        ] {
            defaults.set(id, forKey: AssistiveAccessPreferences.albumIDKey)
            defaults.set(name, forKey: AssistiveAccessPreferences.albumNameKey)
            let view = AssistiveAccessSettingsView(session: MockSessionManager())
            XCTAssertEqual(view.selectedAlbumLabel, label)
            XCTAssertEqual(defaults.string(forKey: AssistiveAccessPreferences.albumIDKey), id)
            XCTAssertEqual(defaults.string(forKey: AssistiveAccessPreferences.albumNameKey), name,
                "Drawing a fallback must not rewrite a stored selection or album name")
        }
    }

    func testMissingPlaceNameIsLocalizedAndServerMetadataRemainsVerbatim() throws {
        let fallback = expected("Unknown Location", "Lieu inconnu")
        let cases: [(String?, String?, String?, String)] = [
            (nil, nil, nil, fallback),
            ("", "", "", fallback),
            (" \n ", "\t", " \n ", fallback),
            (nil, nil, "Unknown Location", "Unknown Location"),
            (nil, nil, "France", "France"),
            ("Paris", "Île-de-France", "France", "Paris - Île-de-France"),
            (" \n ", "Catalonia", "Spain", "Catalonia")
        ]
        let blank = try render(Color.clear)
        for (city, state, country, label) in cases {
            let detail = makeTestAsset(id: "place-name", exifInfo: ExifDTO(make: nil, model: nil,
                exifImageWidth: nil, exifImageHeight: nil, orientation: nil, fileSizeInByte: nil,
                dateTimeOriginal: nil, latitude: 0, longitude: 0, city: city, state: state,
                country: country, lensModel: nil, fNumber: nil, focalLength: nil, iso: nil,
                exposureTime: nil, description: nil))
            let expectedImage = try render(Text(verbatim: label))
            XCTAssertNotEqual(expectedImage, blank, "The comparison must render nonempty text")
            XCTAssertEqual(try render(FallbackPlaceNameFixture(detail: detail)), expectedImage,
                "The map label must use localized fallback text while preserving geographic metadata")
        }
    }

    private func render<Content: View>(_ content: Content) throws -> Data {
        let renderer = ImageRenderer(content: content.font(.body).foregroundStyle(.black)
            .frame(width: 500, height: 60).background(Color.white))
        renderer.scale = 1
        return try XCTUnwrap(renderer.uiImage?.pngData())
    }

    private func expected(_ english: String, _ french: String) -> String {
        Bundle.main.preferredLocalizations.first?.hasPrefix("fr") == true ? french : english
    }

    private func directory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("fallback-localization-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        directories.append(directory)
        return directory
    }
}

private struct FallbackPlaceNameFixture: View {
    let detail: AssetResponseDTO
    @State private var description = ""
    @FocusState private var focused: Bool

    var body: some View {
        Text(verbatim: AssetInfoPanel(detail: detail, descriptionDraft: $description,
            descriptionFocus: $focused).placeName)
    }
}
