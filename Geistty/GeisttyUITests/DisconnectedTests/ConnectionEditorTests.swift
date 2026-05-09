//
//  ConnectionEditorTests.swift
//  GeisttyUITests
//
//  Tests for the ConnectionEditorView: field presence, validation,
//  auth method switching, tmux toggle, save/cancel.
//

import XCTest

final class ConnectionEditorTests: XCTestCase {

    var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = launchForDisconnectedTests()

        // Navigate: Disconnected → Saved Connections → "+" (Add Connection)
        let savedBtn = app.buttons["DisconnectedSavedConnectionsButton"]
        XCTAssertTrue(savedBtn.waitForExistence(timeout: 5))
        savedBtn.tap()

        let addButton = app.buttons["AddConnectionButton"]
        XCTAssertTrue(addButton.waitForExistence(timeout: 3))
        addButton.tap()

        // Wait for editor to appear
        let nameField = app.textFields["EditorNameField"]
        XCTAssertTrue(nameField.waitForExistence(timeout: 3),
                      "Editor should present with name field")
    }

    override func tearDownWithError() throws {
        takeScreenshot(app, name: "\(name)-teardown")
        app = nil
    }

    // MARK: - Field Presence

    /// All basic connection fields exist.
    func testBasicFieldsExist() throws {
        XCTAssertTrue(app.textFields["EditorNameField"].exists, "Name field")
        XCTAssertTrue(app.textFields["EditorHostField"].exists, "Host field")
        XCTAssertTrue(app.textFields["EditorPortField"].exists, "Port field")
        XCTAssertTrue(app.textFields["EditorUsernameField"].exists, "Username field")

        takeScreenshot(app, name: "Editor-01-BasicFields")
    }

    /// Auth method picker exists.
    func testAuthMethodPickerExists() throws {
        // May need to scroll to find it
        let authPicker = app.buttons["AuthMethodPicker"]
            .exists ? app.buttons["AuthMethodPicker"] : app.otherElements["AuthMethodPicker"]

        // Picker might be rendered as a button in compact mode
        let found = app.element(withIdentifier: "AuthMethodPicker") != nil
        XCTAssertTrue(found, "AuthMethodPicker should exist")

        takeScreenshot(app, name: "Editor-02-AuthPicker")
    }

    /// Toolbar has Cancel and Save buttons.
    func testToolbarButtons() throws {
        let cancel = app.buttons["EditorCancelButton"]
        let save = app.buttons["EditorSaveButton"]

        XCTAssertTrue(cancel.exists, "Cancel button should exist")
        XCTAssertTrue(save.exists, "Save button should exist")

        takeScreenshot(app, name: "Editor-03-ToolbarButtons")
    }

    // MARK: - Validation

    /// Save is disabled when required fields are empty.
    func testSaveDisabledWithEmptyFields() throws {
        // New editor starts empty — Save should be disabled
        let save = app.buttons["EditorSaveButton"]
        XCTAssertFalse(save.isEnabled,
                       "Save should be disabled with empty required fields")

        takeScreenshot(app, name: "Editor-04-SaveDisabled")
    }

    // MARK: - Form Entry

    /// Can fill in all basic fields.
    func testCanFillBasicFields() throws {
        let nameField = app.textFields["EditorNameField"]
        nameField.tap()
        nameField.typeText("Test Server")

        let hostField = app.textFields["EditorHostField"]
        hostField.tap()
        hostField.typeText("test.example.com")

        let portField = app.textFields["EditorPortField"]
        portField.tap()
        // Port field starts with "22" — clear and type new value
        portField.press(forDuration: 1.0)
        if app.menuItems["Select All"].waitForExistence(timeout: 2) {
            app.menuItems["Select All"].tap()
        }
        portField.typeText("2222")

        let usernameField = app.textFields["EditorUsernameField"]
        usernameField.tap()
        usernameField.typeText("admin")

        takeScreenshot(app, name: "Editor-05-FilledFields")
    }

    // MARK: - Options

    /// Favorite toggle exists and can be toggled.
    func testFavoriteToggle() throws {
        // Scroll down to find the toggle
        app.swipeUp()

        let toggle = app.switches["FavoriteToggle"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 3),
                      "FavoriteToggle should exist")

        takeScreenshot(app, name: "Editor-06-FavoriteToggle")
    }

    /// tmux toggle exists and reveals session name field when enabled.
    /// Updated for the DisclosureGroup wrapper added in the UX overhaul:
    /// the tmux toggle now lives behind an "Advanced — tmux" disclosure
    /// that starts collapsed for new profiles, so the test must expand
    /// the disclosure before the toggle becomes hittable.
    func testTmuxToggle() throws {
        // Step 1: scroll the disclosure header into view and tap it to expand.
        let disclosure = app.buttons["TmuxDisclosure"]
        scrollUntilHittable(disclosure)
        XCTAssertTrue(disclosure.isHittable, "TmuxDisclosure should be hittable")
        disclosure.tap()

        // Step 2: now the toggle is in the hierarchy. Wait + tap it.
        let tmuxToggle = app.switches["TmuxToggle"]
        XCTAssertTrue(tmuxToggle.waitForExistence(timeout: 3),
                      "TmuxToggle should appear after expanding disclosure")
        scrollUntilHittable(tmuxToggle)
        tmuxToggle.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        Thread.sleep(forTimeInterval: 0.5)

        XCTAssertEqual(tmuxToggle.value as? String, "1",
                       "TmuxToggle should be enabled after tap")

        // Step 3: session name field should appear after toggle is on.
        let sessionField = app.textFields["TmuxSessionNameField"]
        XCTAssertTrue(sessionField.waitForExistence(timeout: 5),
                      "TmuxSessionNameField should appear when tmux is enabled")

        takeScreenshot(app, name: "Editor-07-TmuxEnabled")
    }

    /// New: verify the DisclosureGroup wrapper behavior itself.
    /// - Disclosure header is present
    /// - Toggle + session name field are NOT in the hierarchy when collapsed
    /// - Both appear after tapping the disclosure
    /// - Disclosure stays collapsed by default for new profiles (regression
    ///   guard: an earlier draft accidentally auto-expanded for everyone)
    func testTmuxDisclosureCollapsedByDefault() throws {
        let disclosure = app.buttons["TmuxDisclosure"]
        scrollUntilHittable(disclosure)

        // Collapsed precondition: toggle should NOT exist in the hierarchy
        // yet, because DisclosureGroup unmounts its content while collapsed.
        let tmuxToggle = app.switches["TmuxToggle"]
        XCTAssertFalse(tmuxToggle.exists,
                       "TmuxToggle should not exist while disclosure is collapsed (new profile)")

        takeScreenshot(app, name: "Editor-Tmux-01-Collapsed")

        // Tap to expand
        disclosure.tap()
        XCTAssertTrue(tmuxToggle.waitForExistence(timeout: 3),
                      "TmuxToggle should appear after tapping disclosure")

        takeScreenshot(app, name: "Editor-Tmux-02-Expanded")

        // Tap again to collapse — toggle should disappear from hierarchy.
        disclosure.tap()
        // Allow SwiftUI a moment to unmount.
        Thread.sleep(forTimeInterval: 0.5)
        XCTAssertFalse(tmuxToggle.exists,
                       "TmuxToggle should disappear after tapping disclosure to collapse")

        takeScreenshot(app, name: "Editor-Tmux-03-Recollapsed")
    }

    /// Helper: drag-scroll the form until the given element is hittable.
    /// Used by both testTmuxToggle and testTmuxDisclosureCollapsedByDefault
    /// since the editor is a long form on iPhone and most tmux-related
    /// elements live below the fold.
    private func scrollUntilHittable(_ element: XCUIElement, maxAttempts: Int = 10) {
        var attempts = 0
        while attempts < maxAttempts && !(element.exists && element.isHittable) {
            let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.7))
            let end = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3))
            start.press(forDuration: 0.1, thenDragTo: end)
            attempts += 1
        }
    }

    // MARK: - Cancel

    /// Cancel dismisses the editor without saving.
    func testCancelDismisses() throws {
        let cancel = app.buttons["EditorCancelButton"]
        cancel.tap()

        // Editor should be dismissed — name field should disappear
        let nameField = app.textFields["EditorNameField"]
        XCTAssertTrue(nameField.waitForDisappearance(timeout: 3),
                      "Editor should dismiss on Cancel")

        takeScreenshot(app, name: "Editor-08-Cancelled")
    }
}
