import XCTest

/// Walks through every screen with canned data (`-ui-testing`: no network, no
/// location prompt) and saves a screenshot of each as a test attachment. CI
/// exports them from the result bundle and uploads them as a build artifact.
final class ScreenshotTests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    override func tearDown() {
        // On a failure, save the screen as it was then, so the CI artifact
        // shows what went wrong.
        if let run = testRun, run.failureCount + run.unexpectedExceptionCount > 0 {
            // Only the PNG bytes leave the main actor, so `self` never crosses.
            let png = MainActor.assumeIsolated { XCUIScreen.main.screenshot().pngRepresentation }
            let attachment = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
            attachment.name = "FAILED"
            attachment.lifetime = .keepAlways
            add(attachment)
        }
        super.tearDown()
    }

    @MainActor
    func testScreenshots() {
        let app = XCUIApplication()
        app.launchArguments = ["-ui-testing"]
        app.launch()

        // Map with pins, under a tab bar of Map, Bars, and Settings (FR-1, FR-2, FR-44).
        let pin = app.descendants(matching: .any)["pin-1"].firstMatch
        XCTAssertTrue(pin.waitForExistence(timeout: 15))
        for tab in ["Map", "Bars", "Settings"] {
            XCTAssertTrue(app.tabBars.buttons[tab].exists, "the \(tab) tab")
        }
        sleep(2) // let map tiles load
        saveScreenshot(named: "01-Map", app: app)

        // Bar sheet (FR-3).
        pin.tap()
        let inLine = app.buttons["in-line-button"]
        XCTAssertTrue(inLine.waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["directions-button"].exists, "the bar sheet has Directions (FR-40)")
        saveScreenshot(named: "02-BarSheet", app: app)

        XCTAssertFalse(app.buttons["details-button-1"].exists, "History is on the Bars tab only (FR-43)")

        // Does this look wrong? asks before sending (FR-35).
        app.buttons["looks-wrong-button"].tap()
        let yesWrong = app.buttons["Yes, it looks wrong"]
        XCTAssertTrue(yesWrong.waitForExistence(timeout: 5), "Does this look wrong? asks first")
        saveScreenshot(named: "03-LooksWrongConfirm", app: app)
        tapDialogButton(yesWrong, "Yes, it looks wrong")
        let thanksOK = app.alerts.buttons["OK"]
        XCTAssertTrue(thanksOK.waitForExistence(timeout: 5))
        thanksOK.tap()

        // Start line timer: one tap, straight to the wait card (FR-4, FR-6).
        XCTAssertTrue(inLine.waitForExistence(timeout: 5))
        inLine.tap()
        let imIn = app.buttons["wait-im-in"]
        XCTAssertTrue(imIn.waitForExistence(timeout: 5))
        sleep(1)
        XCTAssertFalse(app.buttons["wait-directions"].exists, "the wait card has no Directions (FR-40)")
        saveScreenshot(named: "04-WaitCard", app: app)

        // Line size from the card (FR-6): one wheel and Save, no Skip.
        app.buttons["wait-update-line"].tap()
        XCTAssertTrue(app.staticTexts["How many people are in line?"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["Skip"].exists, "Line size has no Skip; swiping away skips it")
        let lineWheel = app.pickerWheels.firstMatch
        XCTAssertTrue(lineWheel.waitForExistence(timeout: 5))
        lineWheel.adjust(toPickerWheelValue: "10–25")
        saveScreenshot(named: "05-LineSize", app: app)
        app.buttons["line-save"].tap()

        // Save confirms the answer was sent, naming the size (FR-42).
        XCTAssertTrue(message(containing: "10–25 in line is now visible to everyone", in: app)
            .waitForExistence(timeout: 20))

        // Saving the same size again sends nothing and says so, like Adjust time (FR-6, FR-42).
        app.buttons["wait-update-line"].tap()
        XCTAssertTrue(app.buttons["line-save"].waitForExistence(timeout: 5))
        app.buttons["line-save"].tap()
        XCTAssertTrue(message(containing: "No change", in: app).waitForExistence(timeout: 5),
                      "an unchanged line size says No change")
        saveScreenshot(named: "05b-NoChange", app: app)

        // Adjust time from the card (FR-7): one wheel, 0 to 90, and Save.
        let adjust = app.buttons["wait-adjust-time"]
        XCTAssertTrue(adjust.waitForExistence(timeout: 5))
        adjust.tap()
        XCTAssertTrue(app.staticTexts["Adjust time"].waitForExistence(timeout: 5))
        let wheel = app.pickerWheels.firstMatch
        XCTAssertTrue(wheel.waitForExistence(timeout: 5))
        wheel.adjust(toPickerWheelValue: "15 min")
        saveScreenshot(named: "06-AdjustTimeWheel", app: app)
        app.buttons["adjust-save"].tap()
        // Save confirms with a haptic only, no message (FR-42).
        XCTAssertTrue(app.descendants(matching: .any)["question-adjustTime"].waitForNonExistence(timeout: 5),
                      "Save closes Adjust time")
        // (Line size's thank-you can still be showing, so look for Adjust time's old one.)
        XCTAssertFalse(message(containing: "Saved", in: app).exists, "Save on Adjust time shows no message")

        // Saving the same time again says nothing changed (FR-42).
        adjust.tap()
        XCTAssertTrue(app.buttons["adjust-save"].waitForExistence(timeout: 5))
        app.buttons["adjust-save"].tap()
        XCTAssertTrue(message(containing: "No change", in: app).waitForExistence(timeout: 5),
                      "an unchanged time says No change")

        // I'm in ends the timer and asks nothing, then says thanks with Undo (FR-8, FR-42, FR-47).
        XCTAssertTrue(imIn.waitForExistence(timeout: 5))
        imIn.tap()
        let undo = app.buttons["thanks-undo"]
        XCTAssertTrue(undo.waitForExistence(timeout: 20))
        XCTAssertTrue(message(containing: "now visible to everyone", in: app).exists)
        XCTAssertFalse(imIn.exists, "I'm in closes the wait card")
        XCTAssertFalse(app.otherElements["question-lineSize"].exists, "I'm in asks no question")
        saveScreenshot(named: "07-ThanksWithUndo", app: app)

        // Undo brings the same timer back; then get in for real.
        undo.tap()
        XCTAssertTrue(imIn.waitForExistence(timeout: 5), "Undo brings the wait card back")
        imIn.tap()
        XCTAssertTrue(app.buttons["thanks-undo"].waitForExistence(timeout: 20))

        // Bars list (FR-45): fresh wait first, then grayed out, then no data.
        app.tabBars.buttons["Bars"].tap()
        let doggies = app.buttons["bar-card-1"]
        let champs = app.buttons["bar-card-2"]
        let cafe = app.buttons["bar-card-3"]
        XCTAssertTrue(doggies.waitForExistence(timeout: 5))
        XCTAssertTrue(doggies.frame.minY < champs.frame.minY, "a fresh wait comes before older reports")
        XCTAssertTrue(champs.frame.minY < cafe.frame.minY, "bars without data come last")
        saveScreenshot(named: "08-Bars", app: app)

        // History from a card (FR-43): a calendar, then tonight's quarter
        // hours, starting with the afternoon's reports. No Right now.
        app.buttons["details-button-1"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["history-row"].firstMatch.waitForExistence(timeout: 10))
        XCTAssertFalse(app.staticTexts["Right now"].exists)
        XCTAssertTrue(app.descendants(matching: .any)["history-busiest"].firstMatch.exists)
        XCTAssertTrue(app.descendants(matching: .any)["history-gap"].firstMatch.exists)
        saveScreenshot(named: "09-History", app: app)
        app.swipeUp()
        sleep(1)
        saveScreenshot(named: "10-HistoryRows", app: app)
        app.swipeUp()
        sleep(1)
        saveScreenshot(named: "10b-HistoryRowsLater", app: app)
        app.buttons["details-close"].tap()

        // A card shows the bar on the map with its sheet.
        XCTAssertTrue(cafe.waitForExistence(timeout: 5))
        scrollUntilHittable(cafe, in: app)
        cafe.tap()
        let conditions = app.buttons["conditions-button"]
        XCTAssertTrue(conditions.waitForExistence(timeout: 5))
        sleep(1)
        saveScreenshot(named: "11-BarSheetFromList", app: app)

        // Report line size: one question, six sizes, sent once (FR-11).
        conditions.tap()
        let send = app.buttons["conditions-send"]
        XCTAssertTrue(send.waitForExistence(timeout: 5))
        XCTAssertFalse(send.isEnabled, "Send waits for at least one answer")
        saveScreenshot(named: "12-ConditionsEmpty", app: app)
        app.buttons["line-2"].tap()
        XCTAssertTrue(send.isEnabled)
        saveScreenshot(named: "13-ConditionsAnswered", app: app)
        send.tap()

        // A timer shows on Map and Bars, but not on Settings (FR-4).
        app.tabBars.buttons["Bars"].tap()
        XCTAssertTrue(champs.waitForExistence(timeout: 5))
        scrollUntilHittable(champs, in: app)
        champs.tap()
        XCTAssertTrue(app.buttons["in-line-button"].waitForExistence(timeout: 5))
        app.buttons["in-line-button"].tap()
        XCTAssertTrue(imIn.waitForExistence(timeout: 5))
        app.tabBars.buttons["Bars"].tap()
        XCTAssertTrue(imIn.waitForExistence(timeout: 5), "the wait card shows on Bars")
        saveScreenshot(named: "14-BarsWithTimer", app: app)
        app.tabBars.buttons["Settings"].tap()
        XCTAssertTrue(app.buttons["recent-reports-link"].waitForExistence(timeout: 5))
        XCTAssertFalse(imIn.exists, "the wait card is hidden on Settings")
        app.tabBars.buttons["Map"].tap()

        // The ✕ stops a line: gave up, with Undo (FR-9, FR-47)...
        let cancel = app.buttons["wait-cancel"]
        XCTAssertTrue(cancel.waitForExistence(timeout: 5))
        cancel.tap()
        let gaveUp = app.buttons["I gave up on the line"]
        XCTAssertTrue(gaveUp.waitForExistence(timeout: 5), "the ✕ asks how the timer ended")
        XCTAssertTrue(app.buttons["Started it by mistake"].exists, "the ✕ offers Started it by mistake")
        saveScreenshot(named: "15-StopTimer", app: app)
        tapDialogButton(gaveUp, "I gave up on the line")
        XCTAssertTrue(imIn.waitForNonExistence(timeout: 5), "Gave up closes the wait card")
        XCTAssertTrue(message(containing: "Timer stopped", in: app).waitForExistence(timeout: 10),
                      "Gave up says Timer stopped")
        saveScreenshot(named: "16-TimerStopped", app: app)
        app.buttons["thanks-undo"].tap()

        // ...or started by mistake, which leaves nothing (FR-39).
        XCTAssertTrue(cancel.waitForExistence(timeout: 5), "Undo brings the timer back")
        cancel.tap()
        let discard = app.buttons["Started it by mistake"]
        XCTAssertTrue(discard.waitForExistence(timeout: 5), "the ✕ asks again after Undo")
        tapDialogButton(discard, "Started it by mistake")
        sleep(1)
        XCTAssertFalse(imIn.exists, "a cancelled line leaves no wait card")

        // Settings tab (FR-5), with Time in lines (FR-48) and no Delete my data (FR-32).
        app.tabBars.buttons["Settings"].tap()
        let stats = app.descendants(matching: .any)["wait-stats"]
        XCTAssertTrue(stats.waitForExistence(timeout: 5))
        let total = NSPredicate(format: "label CONTAINS '3 hr 25 min' AND label CONTAINS '7 lines'")
        expectation(for: total, evaluatedWith: stats)
        waitForExpectations(timeout: 5)
        XCTAssertFalse(app.buttons["Delete my data"].exists, "Delete my data is gone (support does it)")
        saveScreenshot(named: "17-Settings", app: app)

        // Made a wrong report?: delete one of the last 24 hours' reports (FR-41).
        app.buttons["recent-reports-link"].tap()
        let deleteButtons = app.buttons.matching(identifier: "delete-report-button")
        XCTAssertTrue(deleteButtons.firstMatch.waitForExistence(timeout: 5))
        XCTAssertEqual(deleteButtons.count, 2)
        saveScreenshot(named: "18-RecentReports", app: app)
        deleteButtons.firstMatch.tap()
        let confirm = app.buttons["Delete"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 5), "Delete asks first")
        saveScreenshot(named: "19-DeleteReport", app: app)
        tapDialogButton(confirm, "Delete")
        let oneLeft = NSPredicate(format: "count == 1")
        expectation(for: oneLeft, evaluatedWith: deleteButtons)
        waitForExpectations(timeout: 5)
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(app.buttons["recent-reports-link"].waitForExistence(timeout: 5))
    }

    /// The main screens again in light mode at a large accessibility text size,
    /// to review dark mode against light and Dynamic Type (NFR-3, NFR-4).
    @MainActor
    func testLightModeLargeText() {
        let app = XCUIApplication()
        app.launchArguments = [
            "-ui-testing", "-ui-light",
            "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityL",
        ]
        app.launch()

        // MapKit sometimes exposes pins as its own map features on a second
        // launch, so this walkthrough opens bars from the Bars tab instead.
        XCTAssertTrue(app.tabBars.buttons["Bars"].waitForExistence(timeout: 15))
        sleep(3) // let pins and map tiles load
        saveScreenshot(named: "L01-Map", app: app)

        app.tabBars.buttons["Bars"].tap()
        XCTAssertTrue(app.buttons["bar-card-1"].waitForExistence(timeout: 10))
        saveScreenshot(named: "L02-Bars", app: app)

        // History before any timer, so the timer card covers nothing.
        app.buttons["details-button-1"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["history-row"].firstMatch.waitForExistence(timeout: 10))
        saveScreenshot(named: "L03-History", app: app)
        app.swipeUp()
        app.swipeUp()
        sleep(1)
        saveScreenshot(named: "L04-HistoryRows", app: app)
        app.buttons["details-close"].tap()

        // The top card, so large text never needs a scroll to reach it.
        let first = app.buttons["bar-card-1"]
        XCTAssertTrue(first.waitForExistence(timeout: 5))
        scrollUntilHittable(first, in: app, up: false)
        first.tap()
        let conditions = app.buttons["conditions-button"]
        XCTAssertTrue(conditions.waitForExistence(timeout: 5))
        conditions.tap()
        XCTAssertTrue(app.buttons["conditions-send"].waitForExistence(timeout: 5))
        saveScreenshot(named: "L05-Conditions", app: app)
        let cancel = app.buttons["conditions-cancel"]
        scrollUntilHittable(cancel, in: app)
        cancel.tap()

        app.tabBars.buttons["Bars"].tap()
        let doggies = app.buttons["bar-card-1"]
        XCTAssertTrue(doggies.waitForExistence(timeout: 5))
        scrollUntilHittable(doggies, in: app, up: false)
        doggies.tap()
        XCTAssertTrue(app.buttons["in-line-button"].waitForExistence(timeout: 5))
        saveScreenshot(named: "L06-BarSheet", app: app)
        app.buttons["in-line-button"].tap()
        XCTAssertTrue(app.buttons["wait-im-in"].waitForExistence(timeout: 5))
        sleep(1)
        saveScreenshot(named: "L07-WaitCard", app: app)

        app.tabBars.buttons["Settings"].tap()
        XCTAssertTrue(app.buttons["recent-reports-link"].waitForExistence(timeout: 5))
        saveScreenshot(named: "L08-Settings", app: app)
    }

    /// The thank-you message showing this text (FR-42).
    @MainActor
    private func message(containing text: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier == 'thanks-message' AND label CONTAINS %@", text))
            .firstMatch
    }

    /// Taps a button in a confirmation dialog. On iOS 26 these animate in as
    /// popovers, and a tap that lands mid-animation can be dropped, so this
    /// waits until the button can be tapped and taps again if the dialog stays.
    @MainActor
    private func tapDialogButton(_ button: XCUIElement, _ step: String) {
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate(format: "isHittable == true"), object: button)
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 5), .completed, "\(step): the button can be tapped")
        button.tap()
        if !button.waitForNonExistence(timeout: 2), button.isHittable {
            button.tap() // the first tap was dropped
        }
        XCTAssertTrue(button.waitForNonExistence(timeout: 5), "\(step): the dialog closes")
    }

    @MainActor
    /// Swipes until the element can be tapped. Large text makes cards tall
    /// enough that one swipe isn't always enough.
    private func scrollUntilHittable(_ element: XCUIElement, in app: XCUIApplication, up: Bool = true) {
        for _ in 0..<5 where !element.isHittable {
            if up { app.swipeUp() } else { app.swipeDown() }
        }
    }

    private func saveScreenshot(named name: String, app: XCUIApplication) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
