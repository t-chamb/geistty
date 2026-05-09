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
