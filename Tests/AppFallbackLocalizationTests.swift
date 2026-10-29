import Foundation
import XCTest
@testable import ImmichApp

@MainActor
final class AppFallbackLocalizationTests: XCTestCase {
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

    private func expected(_ english: String, _ french: String) -> String {
        Bundle.main.preferredLocalizations.first?.hasPrefix("fr") == true ? french : english
    }
}
