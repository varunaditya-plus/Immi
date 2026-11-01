import XCTest

@MainActor
final class NativeConfirmationUITests: XCTestCase {
    private var app: XCUIApplication!
    private var server: LoopbackImmichServer!
    private var serverURL: URL!

    override func setUp() async throws {
        try await super.setUp()
        continueAfterFailure = false
        server = try LoopbackImmichServer()
        serverURL = try await server.start()
        app = XCUIApplication(bundleIdentifier: "xyz.0xmwehehe.ImmichApp")
        app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        try signOutIfNeeded()
        try login()
    }

    override func tearDown() async throws {
        continueAfterFailure = true
        defer {
            app?.terminate()
            server?.stop()
            app = nil
            server = nil
        }
        if let app, let server {
            let attachment = XCTAttachment(screenshot: app.screenshot())
            attachment.name = name
            attachment.lifetime = .keepAlways
            add(attachment)
            app.terminate()
            app.launch()
            try signOutIfNeeded()
            app.terminate()
            let state = server.snapshot()
            XCTAssertEqual(state.uploadRequests, 0, "No test may request a device-media upload")
            XCTAssertTrue(state.unexpectedRequests.isEmpty, "Unimplemented contracts cannot be mistaken for success: \(state.unexpectedRequests)")
        }
        try await super.tearDown()
    }

    func testNativeFolderCreationFromSharedRemainsReachableAndKeepsSharedAlbumsAfterMovingThem() throws {
        try openAlbums()
        try tap(app.segmentedControls.buttons["Shared"])
        try tap(app.buttons["Create"])
        try tap(menuItem("New Folder"))
        let alert = app.alerts["New Folder"]
        XCTAssertTrue(alert.waitForExistence(timeout: 5))
        let folderName = "Created folder"
        try enter(folderName, in: alert.textFields.firstMatch)
        try tap(alert.buttons["Create"])
        try wait("The native folder confirmation dismisses") { !alert.exists }
        try wait("Creation reveals Personal, rather than leaving an invisible folder in Shared") {
            self.app.segmentedControls.buttons["Personal"].isSelected
                && self.card(folderName).isHittable
        }

        app.terminate()
        app.launch()
        try openAlbums()
        try wait("The created local folder survives a real app relaunch") { self.card(folderName).isHittable }
        try tap(app.segmentedControls.buttons["Shared"])
        let shared = card(LoopbackImmichServer.sharedAlbumName)
        try reveal(shared)
        shared.press(forDuration: 0.8)
        try tap(menuItem("Move to Folder"))
        try tap(app.buttons.matching(NSPredicate(format: "label CONTAINS %@", folderName)).firstMatch)
        try wait("A shared album stays visible after moving into a personal folder") { shared.isHittable }
        try tap(app.segmentedControls.buttons["Personal"])
        try tap(card(folderName))
        try wait("The folder contains the moved shared album") { shared.isHittable }
        XCTAssertTrue(server.snapshot().creations.isEmpty, "Local folder organization must not create a server album")
        XCTAssertEqual(Set(server.snapshot().albumNames), Set(["Personal Trip", LoopbackImmichServer.sharedAlbumName]))
    }

    func testNativeDuplicateConfirmationsUseCurrentSurvivingAndFallbackKeepers() throws {
        try openCollections()
        try reveal(app.buttons["Duplicates"])
        try tap(app.buttons["Duplicates"])
        let keepAll = app.buttons["Keep All"].firstMatch
        try tap(keepAll)
        try confirm("Cancel")
        XCTAssertTrue(server.snapshot().dismissedGroups.isEmpty)
        XCTAssertTrue(server.snapshot().resolutions.isEmpty)
        XCTAssertTrue(server.snapshot().trashedIDs.isEmpty)
        try tap(keepAll)
        try confirm("Keep All")
        try wait("Keep All dismisses only its own duplicate group") {
            self.server.snapshot().dismissedGroups == [LoopbackImmichServer.keepGroupID]
        }
        XCTAssertTrue(server.snapshot().trashedIDs.isEmpty)
        XCTAssertTrue(server.snapshot().resolutions.isEmpty)

        let third = app.buttons["Third.jpg"]
        try revealPhoto(third, inStripContaining: "First.jpg")
        try tap(third)
        try wait("The user's additional Third keeper is selected") { third.exists && third.value as? String == "Keep" }
        server.replaceMembers(in: LoopbackImmichServer.changingGroupID,
            with: ["Second.jpg", "Third.jpg"], suggesting: ["Second.jpg"])
        try refreshDuplicates()
        try revealPhoto(third, inStripContaining: "Second.jpg")
        try wait("Refreshing the same group preserves the user's surviving keeper") { third.exists && third.value as? String == "Keep" }
        XCTAssertEqual(app.buttons["Second.jpg"].value as? String, "Move to Trash")
        try tap(app.buttons["Trash 1"].firstMatch)
        try confirm("Cancel")
        XCTAssertTrue(server.snapshot().resolutions.isEmpty)
        try tap(app.buttons["Trash 1"].firstMatch)
        try confirm("Move to Trash")
        let retained = LoopbackImmichServer.Resolution(groupID: LoopbackImmichServer.changingGroupID,
            keepIDs: [LoopbackImmichServer.assetID("Third.jpg")], trashIDs: [LoopbackImmichServer.assetID("Second.jpg")])
        try wait("The native action sends exactly the latest group partition") { self.server.snapshot().resolutions == [retained] }
        XCTAssertEqual(server.snapshot().trashedIDs, retained.trashIDs)

        let originalFallback = app.buttons["Fallback First.jpg"]
        try revealPhoto(originalFallback, inStripContaining: "Fallback First.jpg")
        try wait("The fallback group initially has only First selected") { originalFallback.exists && originalFallback.value as? String == "Keep" }
        XCTAssertEqual(app.buttons["Fallback Second.jpg"].value as? String, "Move to Trash")
        server.replaceMembers(in: LoopbackImmichServer.fallbackGroupID,
            with: ["Fallback Second.jpg", "Fallback Third.jpg"], suggesting: ["Fallback Second.jpg"])
        try refreshDuplicates()
        let fallback = app.buttons["Fallback Second.jpg"]
        try revealPhoto(fallback, inStripContaining: "Fallback Second.jpg")
        try wait("Removing the only former keeper chooses an admitted fallback") { fallback.exists && fallback.value as? String == "Keep" }
        try tap(fallback)
        XCTAssertEqual(fallback.value as? String, "Keep", "A user cannot deselect the final current keeper")
        try tap(app.buttons["Trash 1"].firstMatch)
        try confirm("Move to Trash")
        let replacement = LoopbackImmichServer.Resolution(groupID: LoopbackImmichServer.fallbackGroupID,
            keepIDs: [LoopbackImmichServer.assetID("Fallback Second.jpg")], trashIDs: [LoopbackImmichServer.assetID("Fallback Third.jpg")])
        try wait("The fallback action preserves exactly the new selected keeper") { self.server.snapshot().resolutions == [retained, replacement] }
        XCTAssertEqual(server.snapshot().trashedIDs, retained.trashIDs.union(replacement.trashIDs))
        XCTAssertTrue(app.staticTexts["No Duplicates"].waitForExistence(timeout: 5))
    }

    func testNativeAlbumFailureAcknowledgementPreservesInputAndAllowsOneSuccessfulRetry() throws {
        try openAlbums()
        try tap(app.buttons["Create"])
        try tap(menuItem("New Album"))
        let name = app.textFields["Album Name"]
        XCTAssertTrue(name.waitForExistence(timeout: 5))
        try enter("   ", in: name)
        let create = app.buttons["Create"].firstMatch
        XCTAssertFalse(create.isEnabled)
        let draft = "  Recovery Trip  "
        try enter(draft, in: name)
        let description = app.textViews["Add Description"].exists ? app.textViews["Add Description"] : app.textFields["Add Description"]
        try enter("  Server description  ", in: description)
        server.holdAndFailNextAlbumCreation()
        try tap(create)
        try wait("The real Create remains busy while its request is held") { self.server.snapshot().creationIsHeld }
        XCTAssertFalse(create.isEnabled, "A held request must block duplicate submissions")
        XCTAssertEqual(server.snapshot().creations.count, 1)
        server.releaseFailedAlbumCreation()
        let alert = app.alerts["Failed to Create Album"]
        XCTAssertTrue(alert.waitForExistence(timeout: 5))
        XCTAssertTrue(alert.staticTexts["Synthetic album creation failure"].exists)
        XCTAssertFalse(server.snapshot().albumNames.contains("Recovery Trip"))
        try tap(alert.buttons["OK"])
        try wait("The native OK returns to the unchanged editable form") { !alert.exists && name.isHittable && create.isEnabled }
        XCTAssertEqual(name.value as? String, draft)
        try tap(create)
        try wait("Retry persists one accepted album and closes the actual creation sheet") {
            self.server.snapshot().albumNames.contains("Recovery Trip") && !name.exists
        }
        let expected = LoopbackImmichServer.Creation(name: "Recovery Trip", description: "Server description", assetIDs: [])
        XCTAssertEqual(server.snapshot().creations, [expected, expected])
        XCTAssertEqual(server.snapshot().albumNames.filter { $0 == "Recovery Trip" }.count, 1)
        XCTAssertTrue(card("Recovery Trip").waitForExistence(timeout: 5))
    }

    private var serverField: XCUIElement { app.textFields["http://your-server-ip:port"] }

    private var collectionsControl: XCUIElement {
        let compact = app.tabBars.buttons["Collections"]
        return compact.exists ? compact : app.buttons["Collections"].firstMatch
    }

    private func card(_ title: String) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", title)).firstMatch
    }

    private func login() throws {
        try enter(serverURL.absoluteString, in: serverField)
        try tap(app.buttons["Continue"])
        try enter(LoopbackImmichServer.email, in: app.textFields["you@example.com"])
        try enter(LoopbackImmichServer.password, in: app.secureTextFields["Required"])
        try tap(app.buttons["Sign In"])
        try wait("The complete app finishes its authenticated launch", timeout: 30) {
            self.collectionsControl.exists
        }
        try openCollections()
        XCTAssertTrue(app.buttons["Profile and Settings"].waitForExistence(timeout: 10))
    }

    private func signOutIfNeeded() throws {
        if serverField.waitForExistence(timeout: 2) { return }
        try openCollections()
        try tap(app.buttons["Profile and Settings"])
        let signOut = app.buttons["Sign Out"]
        try reveal(signOut)
        let loopback = app.staticTexts.matching(NSPredicate(format: "label CONTAINS '127.0.0.1'")).firstMatch.exists
        let syntheticEmail = app.staticTexts.matching(NSPredicate(format: "label ENDSWITH '.test'")).firstMatch
        guard syntheticEmail.exists, loopback else {
            XCTFail("UI tests can sign out only a synthetic localhost account")
            throw URLError(.userAuthenticationRequired)
        }
        try tap(signOut)
        try confirm("Sign Out")
        XCTAssertTrue(serverField.waitForExistence(timeout: 15))
    }

    private func openCollections() throws {
        try tap(collectionsControl)
        if app.staticTexts["Keep Your Photos Safe"].exists {
            let close = app.buttons["Close"].firstMatch
            if close.exists && close.isHittable { close.tap() }
        }
    }

    private func openAlbums() throws {
        try openCollections()
        let heading = app.buttons["Albums"].firstMatch
        try reveal(heading)
        try tap(heading)
        XCTAssertTrue(app.segmentedControls.buttons["Shared"].waitForExistence(timeout: 10))
    }

    private func menuItem(_ title: String) -> XCUIElement {
        app.menuItems[title].exists ? app.menuItems[title] : app.buttons[title].firstMatch
    }

    private func confirm(_ title: String) throws {
        try wait("A real native confirmation is visible") { self.app.alerts.firstMatch.exists || self.app.sheets.firstMatch.exists }
        let native = app.alerts.firstMatch.exists ? app.alerts.firstMatch : app.sheets.firstMatch
        if title == "Cancel", !native.buttons[title].exists {
            try tap(app.otherElements["PopoverDismissRegion"])
        } else {
            try tap(native.buttons[title])
        }
        try wait("The native confirmation finishes dismissing") { !native.exists }
    }

    private func enter(_ value: String, in field: XCUIElement) throws {
        try tap(field)
        if let previous = field.value as? String, previous != field.placeholderValue, !previous.isEmpty {
            field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: previous.count))
        }
        field.typeText(value)
    }

    private func tap(_ element: XCUIElement) throws {
        let processes: [XCUIApplication] = [app, XCUIApplication(bundleIdentifier: "com.apple.springboard")]
        try wait("The requested native control is enabled and hittable", timeout: 15) {
            if element.exists && element.isHittable && element.isEnabled { return true }
            for process in processes {
                for prompt in [process.alerts["Save Password?"], process.sheets["Save Password?"]] {
                    if prompt.exists {
                        let decline = prompt.buttons["Not Now"]
                        if decline.isHittable && decline.isEnabled { decline.tap() }
                        return false
                    }
                }
            }
            return false
        }
        element.tap()
    }

    private func reveal(_ element: XCUIElement) throws {
        for _ in 0..<10 {
            if element.exists && element.isHittable { return }
            app.swipeUp()
        }
        try wait("The requested control can be reached by normal scrolling") { element.exists && element.isHittable }
    }

    private func revealPhoto(_ photo: XCUIElement, inStripContaining name: String) throws {
        try reveal(app.buttons[name])
        for _ in 0..<4 {
            if photo.exists && photo.isHittable { return }
            let strips = app.scrollViews.containing(.button, identifier: name).allElementsBoundByIndex
            guard let strip = strips.last else { break }
            strip.swipeLeft()
        }
        try wait("The actual photo choice can be reached in its horizontal strip") { photo.exists && photo.isHittable }
    }

    private func refreshDuplicates() throws {
        let before = server.snapshot().duplicateReads
        let outer = try XCTUnwrap(app.scrollViews.allElementsBoundByIndex.first {
            $0.frame.height > app.frame.height * 0.5 && $0.frame.width > app.frame.width * 0.8
        }, "The duplicate groups must have an outer vertical scroll view")
        for _ in 0..<4 where server.snapshot().duplicateReads == before {
            let start = outer.coordinate(withNormalizedOffset: CGVector(dx: 0.02, dy: 0.25))
            let end = outer.coordinate(withNormalizedOffset: CGVector(dx: 0.02, dy: 0.85))
            start.press(forDuration: 0.1, thenDragTo: end)
        }
        try wait("Normal pull-to-refresh reads the current server group") { self.server.snapshot().duplicateReads > before }
        try wait("The updated two-member group is rendered") {
            self.app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH '2 items'")).firstMatch.exists
        }
    }

    private func wait(_ message: String, timeout: TimeInterval = 10, _ condition: @escaping () -> Bool) throws {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in condition() }, object: nil)
        guard XCTWaiter.wait(for: [expectation], timeout: timeout) == .completed else {
            let hierarchy = XCTAttachment(string: app.debugDescription)
            hierarchy.name = message
            hierarchy.lifetime = .keepAlways
            add(hierarchy)
            XCTFail(message)
            throw URLError(.timedOut)
        }
    }
}
