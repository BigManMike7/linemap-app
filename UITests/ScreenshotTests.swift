import XCTest

/// Launches the app and saves a screenshot of each screen as a test attachment.
/// CI exports them from the result bundle and uploads them as a build artifact.
final class ScreenshotTests: XCTestCase {
    @MainActor
    func testScreenshots() {
        let app = XCUIApplication()
        app.launch()

        XCTAssertTrue(app.staticTexts["LineMap"].waitForExistence(timeout: 10))
        saveScreenshot(named: "01-Home", app: app)
    }

    @MainActor
    private func saveScreenshot(named name: String, app: XCUIApplication) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
