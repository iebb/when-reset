import XCTest

final class ScreenshotUITests: XCTestCase {
    func testEnglishScreens() {
        capture(language: "en", prefix: "en")
    }

    func testChineseScreens() {
        capture(language: "zh-Hans", prefix: "zh-Hans")
    }

    private func capture(language: String, prefix: String) {
        for appearance in ["light", "dark"] {
            let name = "\(prefix)-\(appearance)"
            shot(language: language, appearance: appearance, screen: "usage", name: "\(name)-01-usage-list")
            shot(language: language, appearance: appearance, screen: "reorder", name: "\(name)-02-usage-reorder")
            shot(language: language, appearance: appearance, screen: "addAccount", name: "\(name)-03-add-account")
            shot(language: language, appearance: appearance, screen: "deviceCode", name: "\(name)-04-device-code")
            shot(language: language, appearance: appearance, screen: "settings", name: "\(name)-05-settings")
        }
    }

    private func shot(language: String, appearance: String, screen: String, name: String) {
        let app = XCUIApplication()
        app.launchArguments = [
            "-BlinkyScreenshotFixture",
            "-BlinkyScreenshotLanguage", language,
            "-BlinkyScreenshotAppearance", appearance,
            "-BlinkyScreenshotScreen", screen,
        ]
        app.launch()

        switch screen {
        case "addAccount":
            let connect = app.staticTexts["Connect an account"].exists
                || app.staticTexts["连接账号"].waitForExistence(timeout: 8)
                || app.staticTexts["Connect an account"].waitForExistence(timeout: 8)
            XCTAssertTrue(connect)
            let zhipu = app.descendants(matching: .any)["provider-zhipu"]
            var swipes = 0
            while !zhipu.isHittable && swipes < 14 {
                app.swipeUp()
                swipes += 1
            }
            XCTAssertTrue(zhipu.waitForExistence(timeout: 5))
            app.swipeUp(velocity: .slow)
        case "deviceCode":
            XCTAssertTrue(app.staticTexts["K3M9-PQ2R"].waitForExistence(timeout: 15))
        case "settings":
            let label = app.staticTexts["Interface appearance"]
            let chinese = app.staticTexts["界面外观"]
            XCTAssertTrue(label.waitForExistence(timeout: 12) || chinese.waitForExistence(timeout: 4))
        case "reorder":
            let done = app.buttons["Done"]
            let chineseDone = app.buttons["完成"]
            XCTAssertTrue(done.waitForExistence(timeout: 12) || chineseDone.waitForExistence(timeout: 4))
        default:
            XCTAssertTrue(app.navigationBars.firstMatch.waitForExistence(timeout: 15))
        }

        RunLoop.current.run(until: Date().addingTimeInterval(0.8))
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        app.terminate()
    }
}
