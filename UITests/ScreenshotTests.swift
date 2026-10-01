import XCTest

/// Walks through every screen with canned data (`-ui-testing`: no network, no
/// location prompt) and saves a screenshot of each as a test attachment. CI
/// exports them from the result bundle and uploads them as a build artifact.
final class ScreenshotTests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    @MainActor
    func testScreenshots() {
        let app = XCUIApplication()
        app.launchArguments = ["-ui-testing"]
        app.launch()

        // Map with pins (FR-1, FR-2).
        let pin = app.buttons["pin-1"]
        XCTAssertTrue(pin.waitForExistence(timeout: 15))
        sleep(2) // let map tiles load
        saveScreenshot(named: "01-Map", app: app)

        // Bar sheet (FR-3).
        pin.tap()
        let inLine = app.buttons["in-line-button"]
        XCTAssertTrue(inLine.waitForExistence(timeout: 5))
        saveScreenshot(named: "02-BarSheet", app: app)

        // I'm in line: one tap, straight to the wait card (FR-4, FR-6).
        inLine.tap()
        let imIn = app.buttons["wait-im-in"]
        XCTAssertTrue(imIn.waitForExistence(timeout: 5))
        sleep(1)
        saveScreenshot(named: "03-WaitCard", app: app)

        // Line size from the card (FR-6).
        app.buttons["wait-update-line"].tap()
        XCTAssertTrue(app.staticTexts["How long is the line?"].waitForExistence(timeout: 5))
        saveScreenshot(named: "04-LineSize", app: app)
        app.buttons["option-2"].tap()

        // Adjust time from the card (FR-7).
        let adjust = app.buttons["wait-adjust-time"]
        XCTAssertTrue(adjust.waitForExistence(timeout: 5))
        adjust.tap()
        XCTAssertTrue(app.staticTexts["Adjust time"].waitForExistence(timeout: 5))
        saveScreenshot(named: "05-AdjustTime", app: app)
        app.buttons["option-2"].tap()

        // The timer now includes the ~10 minutes.
        XCTAssertTrue(imIn.waitForExistence(timeout: 5))
        sleep(1)
        saveScreenshot(named: "06-WaitCardAdjusted", app: app)

        // I'm in → busyness (FR-8, FR-11).
        XCTAssertTrue(imIn.waitForExistence(timeout: 5))
        imIn.tap()
        XCTAssertTrue(app.staticTexts["How busy is it inside?"].waitForExistence(timeout: 5))
        saveScreenshot(named: "07-Busyness", app: app)
        app.buttons["option-2"].tap()

        // I'm inside at another bar → busyness → how long it took (FR-11).
        let otherPin = app.buttons["pin-3"]
        XCTAssertTrue(otherPin.waitForExistence(timeout: 5))
        otherPin.tap()
        let inside = app.buttons["inside-button"]
        XCTAssertTrue(inside.waitForExistence(timeout: 5))
        saveScreenshot(named: "08-BarSheetNoData", app: app)
        inside.tap()
        XCTAssertTrue(app.staticTexts["How busy is it inside?"].waitForExistence(timeout: 5))
        app.buttons["option-1"].tap()
        XCTAssertTrue(app.staticTexts["How long did it take to get in?"].waitForExistence(timeout: 5))
        saveScreenshot(named: "09-RecalledWait", app: app)
        app.buttons["option-skip"].tap()

        // A line started by mistake: the ✕ discards it (FR-39).
        let thirdPin = app.buttons["pin-2"]
        XCTAssertTrue(thirdPin.waitForExistence(timeout: 5))
        thirdPin.tap()
        XCTAssertTrue(app.buttons["in-line-button"].waitForExistence(timeout: 5))
        app.buttons["in-line-button"].tap()
        let cancel = app.buttons["wait-cancel"]
        XCTAssertTrue(cancel.waitForExistence(timeout: 5))
        cancel.tap()
        let discard = app.buttons["Discard line"]
        XCTAssertTrue(discard.waitForExistence(timeout: 5))
        saveScreenshot(named: "10-CancelLine", app: app)
        discard.tap()
        XCTAssertTrue(app.buttons["settings-button"].waitForExistence(timeout: 5))
        sleep(1)
        XCTAssertFalse(app.buttons["wait-im-in"].exists, "a cancelled line leaves no wait card")

        // Settings (FR-5).
        let settings = app.buttons["settings-button"]
        settings.tap()
        XCTAssertTrue(app.buttons["delete-data-button"].waitForExistence(timeout: 5))
        saveScreenshot(named: "11-Settings", app: app)
        app.buttons["settings-done"].tap()
    }

    @MainActor
    private func saveScreenshot(named name: String, app: XCUIApplication) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
