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

        // I'm in line → line size (FR-6).
        inLine.tap()
        XCTAssertTrue(app.buttons["option-2"].waitForExistence(timeout: 5))
        saveScreenshot(named: "03-LineSize", app: app)

        // → Been here a while? (FR-7)
        app.buttons["option-2"].tap()
        XCTAssertTrue(app.staticTexts["Been here a while?"].waitForExistence(timeout: 5))
        saveScreenshot(named: "04-BeenHereAWhile", app: app)

        // → Wait card on the map (FR-4).
        app.buttons["option-1"].tap()
        let imIn = app.buttons["wait-im-in"]
        XCTAssertTrue(imIn.waitForExistence(timeout: 5))
        sleep(1)
        saveScreenshot(named: "05-WaitCard", app: app)

        // Line-size update from the card.
        app.buttons["wait-update-line"].tap()
        XCTAssertTrue(app.staticTexts["How long is the line now?"].waitForExistence(timeout: 5))
        saveScreenshot(named: "06-LineSizeUpdate", app: app)
        app.buttons["option-skip"].tap()

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

        // A line started by mistake: Cancel line discards it (FR-39).
        let thirdPin = app.buttons["pin-2"]
        XCTAssertTrue(thirdPin.waitForExistence(timeout: 5))
        thirdPin.tap()
        XCTAssertTrue(app.buttons["in-line-button"].waitForExistence(timeout: 5))
        app.buttons["in-line-button"].tap()
        let cancelLine = app.buttons["cancel-line"]
        XCTAssertTrue(cancelLine.waitForExistence(timeout: 5))
        cancelLine.tap()
        XCTAssertTrue(app.buttons["settings-button"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["wait-im-in"].exists, "a cancelled line leaves no wait card")

        // Settings (FR-5).
        let settings = app.buttons["settings-button"]
        settings.tap()
        XCTAssertTrue(app.buttons["delete-data-button"].waitForExistence(timeout: 5))
        saveScreenshot(named: "10-Settings", app: app)
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
