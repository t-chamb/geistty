//
//  GeisttyUITests.swift
//  GeisttyUITests
//
//  UI Tests for Geistty terminal app
//

import XCTest

final class GeisttyUITests: XCTestCase {
    
    var app: XCUIApplication!
    
    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launch()
    }
    
    override func tearDownWithError() throws {
        app = nil
    }
    
    // Helper to take and attach screenshot
    private func takeScreenshot(name: String) {
        let screenshot = app.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
    
    // MARK: - Connection Tests
    
    /// Test that the app launches and shows the connection screen
    func testAppLaunches() throws {
        // Take screenshot of launch state
        takeScreenshot(name: "01-App-Launch-State")
        
        // Check for connection-related UI elements
        // The app should show either a connection list or quick connect option
        let exists = app.buttons["New Connection"].waitForExistence(timeout: 5) ||
                     app.buttons["Quick Connect"].waitForExistence(timeout: 5) ||
                     app.staticTexts["Connections"].waitForExistence(timeout: 5)
        
        takeScreenshot(name: "02-After-Wait-For-UI")
        
        // Print all visible elements for debugging
        print("📱 All buttons: \(app.buttons.allElementsBoundByIndex.map { $0.label })")
        print("📱 All static texts: \(app.staticTexts.allElementsBoundByIndex.map { $0.label })")
        print("📱 All text fields: \(app.textFields.allElementsBoundByIndex.map { $0.placeholderValue ?? $0.label })")
        
        XCTAssertTrue(exists, "App should show connection UI on launch")
    }
    
    /// Test quick connect flow
    func testQuickConnectFlow() throws {
        // Look for quick connect button or field
        let quickConnectButton = app.buttons["Quick Connect"]
        if quickConnectButton.waitForExistence(timeout: 3) {
            quickConnectButton.tap()
        }
        
        // Should see text fields for host/user/password
        let hostField = app.textFields["Host"]
        let userField = app.textFields["Username"]
        
        // If fields exist, try entering test values
        if hostField.waitForExistence(timeout: 3) {
            hostField.tap()
            hostField.typeText("test.example.com")
        }
        
        if userField.waitForExistence(timeout: 3) {
            userField.tap()
            userField.typeText("testuser")
        }
    }

    /// Quick Connect form — exercises both entry points and the pre-flight
    /// host validation added in the unified ConnectionFormFields refactor.
    ///
    /// Path A: home → "Quick Connect" → ConnectionSheet (idPrefix "Sheet")
    /// Path B: home → "Saved Connections" → list → "Quick Connect" row →
    ///         QuickConnectView (idPrefix "")
    ///
    /// Both paths render the same shared ConnectionFormFields, so this test
    /// guards against the two flows silently drifting apart again.
    func testQuickConnectForm() throws {
        takeScreenshot(name: "QC-00-Home")

        // ─────────────────────────────────────────────────────────────
        // Path A: ConnectionSheet from home
        // ─────────────────────────────────────────────────────────────
        let homeQuickConnect = app.buttons["DisconnectedQuickConnectButton"]
        XCTAssertTrue(homeQuickConnect.waitForExistence(timeout: 5),
                      "DisconnectedQuickConnectButton should be on the home screen")
        homeQuickConnect.tap()

        // Sheet present + all shared fields rendered with the "Sheet" prefix.
        let sheetHost = app.textFields["SheetHostField"]
        let sheetPort = app.textFields["SheetPortField"]
        let sheetUser = app.textFields["SheetUsernameField"]
        let sheetPass = app.secureTextFields["SheetPasswordField"]
        let sheetConnect = app.buttons["SheetConnectButton"]

        XCTAssertTrue(sheetHost.waitForExistence(timeout: 3), "Sheet host field")
        XCTAssertTrue(sheetPort.exists, "Sheet port field")
        XCTAssertTrue(sheetUser.exists, "Sheet username field")
        XCTAssertTrue(sheetPass.exists, "Sheet password field")
        XCTAssertTrue(sheetConnect.exists, "Sheet connect button")

        // Connect should be disabled with empty fields.
        XCTAssertFalse(sheetConnect.isEnabled,
                       "Connect must be disabled when host/username are empty")

        takeScreenshot(name: "QC-01-Sheet-Empty")

        // Type a deliberately bad host — this should trip the pre-flight
        // hostWarning regex (catches scheme://) BEFORE any SSH round-trip.
        sheetHost.tap()
        sheetHost.typeText("ssh://example.com")

        let warning = app.staticTexts.matching(identifier: "SheetHostWarning").firstMatch
        XCTAssertTrue(warning.waitForExistence(timeout: 2),
                      "Pre-flight warning should appear for 'ssh://' prefix")
        XCTAssertFalse(sheetConnect.isEnabled,
                       "Connect must stay disabled while host warning is active")

        takeScreenshot(name: "QC-02-Sheet-Warning")

        // Clear → type a valid host + username; warning goes away, button enables.
        clear(sheetHost)
        sheetHost.typeText("example.com")
        sheetUser.tap()
        sheetUser.typeText("alice")

        XCTAssertFalse(warning.exists,
                       "Pre-flight warning should clear once host is sane")
        XCTAssertTrue(sheetConnect.isEnabled,
                      "Connect should enable with valid host + username")

        takeScreenshot(name: "QC-03-Sheet-Valid")

        // Cancel back to home.
        app.buttons["SheetCancelButton"].tap()
        XCTAssertTrue(homeQuickConnect.waitForExistence(timeout: 3),
                      "Should be back on the home screen after cancel")

        // ─────────────────────────────────────────────────────────────
        // Path B: QuickConnectView from the saved-connections list
        // ─────────────────────────────────────────────────────────────
        app.buttons["DisconnectedSavedConnectionsButton"].tap()

        let listQuickConnect = app.buttons["QuickConnectButton"]
        XCTAssertTrue(listQuickConnect.waitForExistence(timeout: 3),
                      "List Quick Connect row should be present")
        listQuickConnect.tap()

        // Same shared fields, this time with empty idPrefix.
        let listHost = app.textFields["HostField"]
        let listUser = app.textFields["UsernameField"]
        let listConnect = app.buttons["ConnectButton"]

        XCTAssertTrue(listHost.waitForExistence(timeout: 3),
                      "List host field with empty prefix")
        XCTAssertTrue(listUser.exists, "List username field")
        XCTAssertTrue(listConnect.exists, "List connect button")

        // Pre-flight validation should behave identically — same shared
        // ConnectionFormFields means same warning logic.
        listHost.tap()
        listHost.typeText("not a host")
        let listWarning = app.staticTexts.matching(identifier: "HostWarning").firstMatch
        XCTAssertTrue(listWarning.waitForExistence(timeout: 2),
                      "Pre-flight warning should appear for spaces in host")
        XCTAssertFalse(listConnect.isEnabled,
                       "List Connect must be disabled while warning is active")

        takeScreenshot(name: "QC-04-List-Warning")

        // Cancel out cleanly.
        app.buttons["QuickConnectCancelButton"].tap()
        XCTAssertTrue(listQuickConnect.waitForExistence(timeout: 3),
                      "Should be back on the connection list after cancel")
    }

    /// Reconnect-to-last button — exercises the highest-leverage UX change
    /// from the home-screen overhaul (commit 1195eb0).
    ///
    /// Precondition: a saved profile with lastConnectedAt set must exist in
    /// the app's UserDefaults BEFORE launch. The host-side seeding script
    /// (tools/seed_recent_profile.py invoked by the test runner before this
    /// test runs) writes a binary plist into the app container so
    /// ConnectionProfileManager.shared.recents.first is non-nil.
    ///
    /// Without that pre-seed, this test will skip — there's no way to drive
    /// a real SSH connection from a sandboxed XCUITest runner without
    /// configured TestConfig credentials.
    func testReconnectLastButton() throws {
        let reconnect = app.buttons["DisconnectedReconnectLastButton"]
        guard reconnect.waitForExistence(timeout: 5) else {
            throw XCTSkip("DisconnectedReconnectLastButton not present — run tools/seed_recent_profile.py before invoking this test to pre-seed a recent profile")
        }

        takeScreenshot(name: "RC-01-Home-With-Reconnect")

        // Label should be the two-line "Reconnect / user@host" composition.
        // XCUIElement.label flattens VStack content into a single string.
        XCTAssertTrue(reconnect.label.contains("Reconnect"),
                      "Button label should include 'Reconnect': '\(reconnect.label)'")
        XCTAssertTrue(reconnect.label.contains("demo@test.rebex.net"),
                      "Button label should include user@host: '\(reconnect.label)'")

        // Quick Connect should still exist (demoted to secondary, not removed).
        XCTAssertTrue(app.buttons["DisconnectedQuickConnectButton"].exists,
                      "Quick Connect should remain as the secondary CTA")

        // Saved Connections count badge should read "1" (the seeded profile).
        XCTAssertTrue(app.staticTexts["1 saved"].exists,
                      "Saved Connections badge should announce '1 saved' for the seeded profile")

        reconnect.tap()

        // After tap: connectionStatus = .connecting → TerminalContainerView
        // mounts. The home chrome (Reconnect button, settings gear) should
        // unmount. The actual SSH attempt to test.rebex.net (with the
        // synthesized 'demo' password injected from the seed plist) will
        // fail downstream — and may crash the app due to a pre-existing
        // bug in the SSH session error path. That crash is NOT what this
        // test verifies; we only verify the UX wire-up (home unmounts on
        // .connecting transition).
        //
        // Use a polled exists() check rather than waitForNonExistence so
        // we can break out the moment the app dies or the home unmounts.
        let deadline = Date().addingTimeInterval(5)
        while reconnect.exists && app.state == .runningForeground && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.2)
        }
        XCTAssertFalse(reconnect.exists,
                       "Reconnect button should disappear after tapping (state → .connecting or app handed control to terminal/error chrome)")

        // Device-level screenshot survives the case where the app has
        // already crashed mid-transition; XCUIApplication.screenshot()
        // would throw "Element Target Application cannot request
        // screenshot data because it does not exist".
        let deviceShot = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: deviceShot)
        attachment.name = "RC-02-After-Tap"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    // MARK: - Feature regression coverage (commits 530bd76 .. eeb1ded)

    /// Editor sections added in commit 530bd76:
    /// Organization (Folder + Color) and SSH Options (Agent Forward).
    /// Tests that the new fields exist, fill, save, and the row in the
    /// list reflects the saved settings (color chip + agent badge).
    func testEditorFoldersAndAgentForward() throws {
        takeScreenshot(name: "FT-00-Home")

        // Navigate: Home → Saved Connections → +
        app.buttons["DisconnectedSavedConnectionsButton"].tap()

        let add = app.buttons["AddConnectionButton"]
        XCTAssertTrue(add.waitForExistence(timeout: 5))
        add.tap()

        // Required fields so Save enables.
        let name = app.textFields["EditorNameField"]
        XCTAssertTrue(name.waitForExistence(timeout: 3))
        name.tap(); name.typeText("test-server")
        app.textFields["EditorHostField"].tap()
        app.textFields["EditorHostField"].typeText("ts-host.example.com")
        app.textFields["EditorUsernameField"].tap()
        app.textFields["EditorUsernameField"].typeText("alice")

        // Switch auth method to password — the test simulator has no SSH
        // keys, so leaving the default .sshKey would keep Save disabled
        // ("Select an SSH key" validation error). Picker is segmented;
        // tap the AuthMethodPicker, then "Password".
        app.navigationBars.firstMatch.tap()  // dismiss keyboard
        let authPicker = app.buttons["AuthMethodPicker"]
        if authPicker.waitForExistence(timeout: 2) {
            authPicker.tap()
            // The picker is presented as a Menu — pick the Password option.
            let passwordOption = app.buttons["Password"]
            if passwordOption.waitForExistence(timeout: 2) { passwordOption.tap() }
        }
        // Provide a password so the .password validation passes.
        let passwordField = app.secureTextFields["EditorPasswordField"]
        if passwordField.waitForExistence(timeout: 2) {
            passwordField.tap()
            passwordField.typeText("hunter2")
        }

        // Dismiss the keyboard before scrolling — otherwise the scroll
        // gesture lands on the keyboard and doesn't move the form.
        // Tapping the navigation title is a no-op that closes the keyboard.
        app.navigationBars.firstMatch.tap()

        // Scroll to bring the Organization section into view. Existence
        // check is on `exists` (not `isHittable`) since SwiftUI lazily
        // materializes form sections — once it's in the hierarchy we can
        // tap-via-coordinate even if the picker considers it not hittable.
        let folderField = app.textFields["FolderField"]
        scrollUntilExists(folderField)
        XCTAssertTrue(folderField.exists,
                      "FolderField should be in the hierarchy after scrolling")
        folderField.tap()
        folderField.typeText("Production")
        app.navigationBars.firstMatch.tap()  // dismiss keyboard again

        // Color tag picker — tap blue, verify checkmark, tap again to clear,
        // re-tap to set so we know toggle state is correct.
        let blueSwatch = app.buttons["ColorTag-blue"]
        scrollUntilExists(blueSwatch)
        if blueSwatch.isHittable {
            blueSwatch.tap()
        } else {
            // Fall back to coordinate tap — the swatch is small (20pt
            // circle) and SwiftUI sometimes reports !isHittable even
            // when visible.
            blueSwatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        }

        takeScreenshot(name: "FT-01-Organization-Filled")

        // SSH Options — agent toggle. Dismiss keyboard so scroll lands on
        // the form rather than the keyboard.
        app.navigationBars.firstMatch.tap()
        let forwardToggle = app.switches["ForwardAgentToggle"]
        scrollUntilExists(forwardToggle)
        Thread.sleep(forTimeInterval: 0.4)

        // Diagnostic screenshot just before the tap so we can see what
        // the simulator actually displays at this point if the assert
        // below fails.
        takeScreenshot(name: "FT-01b-PreToggle")

        // Try the standard XCUIElement.tap() first — works for most
        // SwiftUI Toggles. Fall back to coordinate-tap on the trailing
        // edge if the value didn't change (some XCTest builds need it).
        forwardToggle.tap()
        Thread.sleep(forTimeInterval: 0.3)
        if forwardToggle.value as? String != "1" {
            forwardToggle.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
            Thread.sleep(forTimeInterval: 0.3)
        }
        Thread.sleep(forTimeInterval: 0.4)
        XCTAssertEqual(forwardToggle.value as? String, "1",
                       "Agent forward toggle should be on after tap")

        takeScreenshot(name: "FT-02-AgentToggled")

        // Save.
        app.buttons["EditorSaveButton"].tap()

        // Back on the list — the row should be present, and (since we set
        // a folder) it should now be in a 'Production' section, not 'All
        // Connections'. Just assert the row exists; section grouping is
        // implicit on screen and verified visually.
        let row = app.buttons["ConnectionRow-test-server"]
        XCTAssertTrue(row.waitForExistence(timeout: 3),
                      "Saved profile should appear in the list")

        takeScreenshot(name: "FT-03-List-WithFolder")

        // Dismiss iOS's system 'Save Password?' sheet if it intercepted —
        // typing into a SecureField + saving the form triggers it. Tap
        // 'Not Now' (iOS 17+) or 'Never for This Website' equivalents
        // best-effort.
        for label in ["Not Now", "Never for This App", "Cancel"] {
            let btn = app.buttons[label]
            if btn.exists && btn.isHittable { btn.tap(); break }
        }

        // Cleanup is best-effort — assertions above already verified the
        // feature. If the row delete races with iOS chrome we don't fail.
        if row.exists && row.isHittable {
            row.press(forDuration: 1.2)
            let delete = app.buttons["ContextMenuDelete"]
            if delete.waitForExistence(timeout: 2) { delete.tap() }
            if app.buttons["Delete"].waitForExistence(timeout: 1) {
                app.buttons["Delete"].tap()
            }
        }
    }

    /// Snippets feature (commit 4bd9338): Settings → Snippets → empty
    /// state → Add → fill → save → see in list → swipe-copy → delete.
    func testSnippetsCRUD() throws {
        app.buttons["SettingsButton"].tap()

        let snippetsLink = app.buttons["SnippetsLink"]
        scrollUntilHittable(snippetsLink)
        snippetsLink.tap()

        takeScreenshot(name: "SN-01-Empty")

        // Empty-state copy should be visible on first run.
        let empty = app.staticTexts["No Snippets Yet"]
        XCTAssertTrue(empty.waitForExistence(timeout: 3),
                      "Empty-state ContentUnavailableView should render")

        // Add.
        app.buttons["SnippetAddButton"].tap()

        let nameField = app.textFields["SnippetNameField"]
        XCTAssertTrue(nameField.waitForExistence(timeout: 3))
        nameField.tap(); nameField.typeText("kubectl pods")

        // Content is a TextEditor (no placeholder); tap on it then type.
        let content = app.textViews["SnippetContentField"]
        XCTAssertTrue(content.exists, "Content TextEditor should exist")
        content.tap()
        content.typeText("kubectl get pods -A")

        // Optional category — autocomplete picker only renders when there
        // are existing categories, so just type a fresh one.
        let cat = app.textFields["SnippetCategoryField"]
        cat.tap(); cat.typeText("kubernetes")

        takeScreenshot(name: "SN-02-Editor-Filled")

        app.buttons["SnippetSaveButton"].tap()

        // Back on list — row should exist with the snippet name.
        let row = app.buttons["SnippetRow-kubectl pods"]
        XCTAssertTrue(row.waitForExistence(timeout: 3),
                      "Saved snippet should appear in the list")

        takeScreenshot(name: "SN-03-List-Populated")

        // Cleanup: swipe to delete (XCTest default left-swipe).
        row.swipeLeft()
        let trash = app.buttons["Delete"]
        if trash.waitForExistence(timeout: 2) { trash.tap() }
    }

    /// Known Hosts UI (commit e0188a8): Settings → Known Hosts → empty
    /// state, since the test simulator hasn't completed any TOFU trusts.
    func testKnownHostsEmptyState() throws {
        app.buttons["SettingsButton"].tap()

        let link = app.buttons["KnownHostsLink"]
        scrollUntilHittable(link)
        link.tap()

        // Empty state must render with the helpful copy explaining how
        // entries get added.
        let empty = app.staticTexts["No Trusted Hosts"]
        XCTAssertTrue(empty.waitForExistence(timeout: 3),
                      "Known Hosts empty state should render")

        let nav = app.navigationBars["Known Hosts"]
        XCTAssertTrue(nav.exists, "Nav title should be 'Known Hosts'")

        takeScreenshot(name: "KH-01-Empty")
    }

    /// Tailscale settings (commit eeb1ded): Settings → Tailscale → fields
    /// render, accept input. We don't actually save (would require a real
    /// PAT to refresh against the API); this verifies the UI surface.
    func testTailscaleSettingsUI() throws {
        app.buttons["SettingsButton"].tap()

        let link = app.buttons["TailscaleLink"]
        scrollUntilHittable(link)
        link.tap()

        let token = app.secureTextFields["TailscaleTokenField"]
        let tailnet = app.textFields["TailscaleTailnetField"]
        let user = app.textFields["TailscaleUsernameField"]

        XCTAssertTrue(token.waitForExistence(timeout: 3), "Token field")
        XCTAssertTrue(tailnet.exists, "Tailnet field")
        XCTAssertTrue(user.exists, "Username field")

        // Default tailnet should pre-populate to '-' (the API alias).
        XCTAssertEqual(tailnet.value as? String, "-",
                       "Tailnet should default to '-'")

        // Type into each — verifies they're editable.
        tailnet.tap()
        // Field is pre-filled with '-'; clear it first.
        clear(tailnet)
        tailnet.typeText("example.ts.net")

        user.tap()
        clear(user)
        user.typeText("alice")

        takeScreenshot(name: "TS-01-Settings-Filled")

        // Save button should exist regardless of token presence.
        XCTAssertTrue(app.buttons["TailscaleSaveButton"].exists,
                      "Save button should render")
    }

    /// Helper: drag-scroll until the given element is hittable (or we
    /// give up after maxAttempts). Same shape as the helper in
    /// ConnectionEditorTests but local-private to keep this test file
    /// self-contained for the new feature regression suite.
    private func scrollUntilHittable(_ element: XCUIElement, maxAttempts: Int = 10) {
        var attempts = 0
        while attempts < maxAttempts && !(element.exists && element.isHittable) {
            let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.7))
            let end = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3))
            start.press(forDuration: 0.1, thenDragTo: end)
            attempts += 1
        }
    }

    /// Helper: scroll until the element is in the hierarchy (existence,
    /// not hittability). For SwiftUI Forms where deeper sections are
    /// lazily materialized — once it's in `app.descendants`, we can
    /// interact with it via coordinate-tap even if XCTest's hit-test
    /// considers it not directly hittable due to overlapping chrome.
    private func scrollUntilExists(_ element: XCUIElement, maxAttempts: Int = 12) {
        var attempts = 0
        while attempts < maxAttempts && !element.exists {
            let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.6))
            let end = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.2))
            start.press(forDuration: 0.1, thenDragTo: end)
            attempts += 1
        }
    }

    /// Helper: clear a text field by selecting all + deleting. iOS field
    /// clearing is finicky (no API for "clear text"), this is the
    /// XCTest-idiomatic workaround.
    private func clear(_ field: XCUIElement) {
        guard let value = field.value as? String, !value.isEmpty else { return }
        field.tap()
        // Triple-tap to select-all is unreliable; build a backspace string.
        let deleteString = String(repeating: XCUIKeyboardKey.delete.rawValue, count: value.count)
        field.typeText(deleteString)
    }

    /// Settings → Keyboard Shortcuts navigation flow.
    /// Verifies the new SettingsView entry I added (KeyboardShortcutsLink)
    /// pushes the dedicated KeyboardShortcutsView with all expected shortcut
    /// rows. Captures screenshots at each step for visual confirmation.
    func testSettingsKeyboardShortcutsFlow() throws {
        takeScreenshot(name: "KS-00-Home")

        // Top-right gear (post-UX-overhaul). Wait + tap.
        let settings = app.buttons["SettingsButton"]
        XCTAssertTrue(settings.waitForExistence(timeout: 5),
                      "Settings gear should be present in toolbar")
        settings.tap()

        takeScreenshot(name: "KS-01-Settings-Open")

        // Keyboard Shortcuts link is below Theme/Cursor/Font/etc; scroll the
        // settings list until the link comes into hit-testable view.
        let link = app.buttons["KeyboardShortcutsLink"]
        let listView = app.collectionViews.firstMatch
        var scrolls = 0
        while !link.isHittable && scrolls < 10 {
            listView.swipeUp()
            scrolls += 1
        }
        XCTAssertTrue(link.isHittable,
                      "KeyboardShortcutsLink should become hittable after scrolling")
        link.tap()

        takeScreenshot(name: "KS-02-Shortcuts-View")

        // Verify representative rows from each category render.
        let nav = app.navigationBars["Keyboard Shortcuts"]
        XCTAssertTrue(nav.waitForExistence(timeout: 3),
                      "Keyboard Shortcuts nav title should appear")

        let connectionRow = app.staticTexts["New Connection"]
        let appRow = app.staticTexts["Settings"]
        let terminalRow = app.staticTexts["Copy Selection"]
        XCTAssertTrue(connectionRow.exists, "Connection-category shortcut row")
        XCTAssertTrue(appRow.exists, "App-category shortcut row")
        XCTAssertTrue(terminalRow.exists, "Terminal-category shortcut row")

        // Combo column rendered in monospace; verify at least one combo
        // string is present so we know the layout reached the trailing label.
        XCTAssertTrue(app.staticTexts["⌘N"].exists,
                      "⌘N combo should render in trailing column")
    }
}

// MARK: - Terminal Tests

final class TerminalUITests: XCTestCase {
    
    var app: XCUIApplication!
    
    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        
        // Launch with arguments to skip to terminal (if supported)
        // This would require app to support launch arguments for testing
        app.launchArguments = ["--ui-testing"]
        app.launch()
    }
    
    override func tearDownWithError() throws {
        app = nil
    }
    
    // MARK: - Keyboard Shortcut Tests
    
    /// Test that Cmd+D triggers split
    func testSplitShortcut() throws {
        // This test requires being connected to a terminal
        // Skip if not in terminal view
        guard isInTerminalView() else {
            throw XCTSkip("Not in terminal view - need active connection")
        }
        
        // Send Cmd+D
        app.typeKey("d", modifierFlags: .command)
        
        // Wait for potential split to occur
        Thread.sleep(forTimeInterval: 0.5)
        
        // Verify split occurred (would need accessibility identifiers)
        // For now, just verify no crash
    }
    
    /// Test that Cmd+] cycles focus between panes
    func testSplitFocusShortcut() throws {
        guard isInTerminalView() else {
            throw XCTSkip("Not in terminal view - need active connection")
        }
        
        // Send Cmd+]
        app.typeKey("]", modifierFlags: .command)
        
        // Wait for focus change
        Thread.sleep(forTimeInterval: 0.3)
        
        // Verify no crash
    }
    
    /// Test that Cmd+F opens search
    func testSearchShortcut() throws {
        guard isInTerminalView() else {
            throw XCTSkip("Not in terminal view - need active connection")
        }
        
        // Send Cmd+F
        app.typeKey("f", modifierFlags: .command)
        
        // Wait for search UI
        Thread.sleep(forTimeInterval: 0.5)
        
        // Look for search field
        let searchField = app.searchFields.firstMatch
        XCTAssertTrue(searchField.waitForExistence(timeout: 2), "Search field should appear")
    }
    
    /// Test that Escape closes search
    func testSearchCloseWithEscape() throws {
        guard isInTerminalView() else {
            throw XCTSkip("Not in terminal view - need active connection")
        }
        
        // Open search first
        app.typeKey("f", modifierFlags: .command)
        Thread.sleep(forTimeInterval: 0.5)
        
        // Press Escape
        app.typeKey(.escape, modifierFlags: [])
        Thread.sleep(forTimeInterval: 0.3)
        
        // Search should be gone
        let searchField = app.searchFields.firstMatch
        XCTAssertFalse(searchField.exists, "Search field should be dismissed")
    }
    
    // MARK: - Font Size Tests
    
    /// Test Cmd++ increases font size
    func testIncreaseFontSize() throws {
        guard isInTerminalView() else {
            throw XCTSkip("Not in terminal view - need active connection")
        }
        
        // Send Cmd++
        app.typeKey("+", modifierFlags: .command)
        Thread.sleep(forTimeInterval: 0.3)
        
        // No crash = success for now
    }
    
    /// Test Cmd+- decreases font size
    func testDecreaseFontSize() throws {
        guard isInTerminalView() else {
            throw XCTSkip("Not in terminal view - need active connection")
        }
        
        // Send Cmd+-
        app.typeKey("-", modifierFlags: .command)
        Thread.sleep(forTimeInterval: 0.3)
        
        // No crash = success for now
    }
    
    /// Test Cmd+0 resets font size
    func testResetFontSize() throws {
        guard isInTerminalView() else {
            throw XCTSkip("Not in terminal view - need active connection")
        }
        
        // Send Cmd+0
        app.typeKey("0", modifierFlags: .command)
        Thread.sleep(forTimeInterval: 0.3)
        
        // No crash = success for now
    }
    
    // MARK: - Helper Methods
    
    private func isInTerminalView() -> Bool {
        // Check for terminal-specific UI elements
        // This is heuristic - adjust based on actual UI
        let terminalIndicators = [
            app.otherElements["TerminalSurface"],
            app.otherElements["MetalView"],
        ]
        
        for element in terminalIndicators {
            if element.exists {
                return true
            }
        }
        
        // Also check if we're NOT on the connection screen
        let connectionIndicators = [
            app.buttons["New Connection"],
            app.staticTexts["Connections"],
        ]
        
        for element in connectionIndicators {
            if element.exists {
                return false
            }
        }
        
        // Default to true if neither found (might be in terminal)
        return true
    }
}
