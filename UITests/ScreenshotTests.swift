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
        let pin = app.descendants(matching: .any)["pin-1"].firstMatch
        XCTAssertTrue(pin.waitForExistence(timeout: 15))
        sleep(2) // let map tiles load
        saveScreenshot(named: "01-Map", app: app)

        // Bar sheet (FR-3).
        pin.tap()
        let inLine = app.buttons["in-line-button"]
        XCTAssertTrue(inLine.waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["directions-button"].exists, "the bar sheet has Directions (FR-40)")
        saveScreenshot(named: "02-BarSheet", app: app)

        // Start line timer: one tap, straight to the wait card (FR-4, FR-6).
        inLine.tap()
        XCTAssertTrue(app.buttons["wait-im-in"].waitForExistence(timeout: 5))
        sleep(1)
        XCTAssertTrue(app.buttons["wait-directions"].exists, "the wait card has Directions (FR-40)")
        saveScreenshot(named: "03-WaitCard", app: app)

        // Line size from the card (FR-6).
        app.buttons["wait-update-line"].tap()
        XCTAssertTrue(app.staticTexts["How many people are in line?"].waitForExistence(timeout: 5))
        saveScreenshot(named: "04-LineSize", app: app)
        app.buttons["option-2"].tap()

        // Adjust time from the card (FR-7): ~5, ~10, or More… for the wheel.
        let adjust = app.buttons["wait-adjust-time"]
        XCTAssertTrue(adjust.waitForExistence(timeout: 5))
        adjust.tap()
        XCTAssertTrue(app.staticTexts["Adjust time"].waitForExistence(timeout: 5))
        saveScreenshot(named: "05-AdjustTime", app: app)
        app.buttons["option-more"].tap()
        let set = app.buttons["adjust-set"]
        XCTAssertTrue(set.waitForExistence(timeout: 5))
        saveScreenshot(named: "06-AdjustTimeWheel", app: app)
        set.tap()

        // The timer now includes the 15 minutes from the wheel.
        let imIn = app.buttons["wait-im-in"]
        XCTAssertTrue(imIn.waitForExistence(timeout: 5))
        sleep(1)
        saveScreenshot(named: "07-WaitCardAdjusted", app: app)

        // I'm in ends the timer and asks nothing, then says thanks (FR-8, FR-42).
        imIn.tap()
        let thanks = app.descendants(matching: .any)["thanks-message"]
        XCTAssertTrue(thanks.waitForExistence(timeout: 10))
        saveScreenshot(named: "08-Thanks", app: app)
        XCTAssertTrue(app.buttons["settings-button"].waitForExistence(timeout: 5))
        sleep(1)
        XCTAssertFalse(app.buttons["wait-im-in"].exists, "I'm in closes the wait card")
        XCTAssertFalse(app.otherElements["question-lineSize"].exists, "I'm in asks no question")

        // Report conditions at another bar: line size and crowd on one screen (FR-11).
        let otherPin = app.descendants(matching: .any)["pin-3"].firstMatch
        XCTAssertTrue(otherPin.waitForExistence(timeout: 5))
        otherPin.tap()
        let conditions = app.buttons["conditions-button"]
        XCTAssertTrue(conditions.waitForExistence(timeout: 5))
        saveScreenshot(named: "09-BarSheetNoData", app: app)
        conditions.tap()
        let send = app.buttons["conditions-send"]
        XCTAssertTrue(send.waitForExistence(timeout: 5))
        XCTAssertFalse(send.isEnabled, "Send waits for at least one answer")
        saveScreenshot(named: "10-ConditionsEmpty", app: app)
        app.buttons["line-2"].tap()
        app.buttons["crowd-2"].tap()
        XCTAssertTrue(send.isEnabled)
        saveScreenshot(named: "11-ConditionsAnswered", app: app)
        send.tap()

        // The ✕ stops a line: gave up, or started by mistake (FR-9, FR-39).
        let thirdPin = app.descendants(matching: .any)["pin-2"].firstMatch
        XCTAssertTrue(thirdPin.waitForExistence(timeout: 5))
        thirdPin.tap()
        XCTAssertTrue(app.buttons["in-line-button"].waitForExistence(timeout: 5))
        app.buttons["in-line-button"].tap()
        let cancel = app.buttons["wait-cancel"]
        XCTAssertTrue(cancel.waitForExistence(timeout: 5))
        cancel.tap()
        let discard = app.buttons["Started it by mistake"]
        XCTAssertTrue(discard.waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["I gave up on the line"].exists)
        saveScreenshot(named: "12-StopTimer", app: app)
        discard.tap()
        XCTAssertTrue(app.buttons["settings-button"].waitForExistence(timeout: 5))
        sleep(1)
        XCTAssertFalse(app.buttons["wait-im-in"].exists, "a cancelled line leaves no wait card")

        // Settings (FR-5).
        let settings = app.buttons["settings-button"]
        settings.tap()
        XCTAssertTrue(app.buttons["delete-data-button"].waitForExistence(timeout: 5))
        saveScreenshot(named: "13-Settings", app: app)

        // Made a wrong report?: delete one of the last 24 hours' reports (FR-41).
        app.buttons["recent-reports-link"].tap()
        let deleteButtons = app.buttons.matching(identifier: "delete-report-button")
        XCTAssertTrue(deleteButtons.firstMatch.waitForExistence(timeout: 5))
        XCTAssertEqual(deleteButtons.count, 2)
        saveScreenshot(named: "14-RecentReports", app: app)
        deleteButtons.firstMatch.tap()
        let confirm = app.buttons["Delete"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        saveScreenshot(named: "15-DeleteReport", app: app)
        confirm.tap()
        let oneLeft = NSPredicate(format: "count == 1")
        expectation(for: oneLeft, evaluatedWith: deleteButtons)
        waitForExpectations(timeout: 5)
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(app.buttons["settings-done"].waitForExistence(timeout: 5))
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
