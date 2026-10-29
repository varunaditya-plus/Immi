import Foundation
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
