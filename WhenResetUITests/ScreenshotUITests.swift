import XCTest

final class ScreenshotUITests: XCTestCase {
    func testEnglishScreens() {
        capture(language: "en", prefix: "en")
    }

    func testChineseScreens() {
        capture(language: "zh-Hans", prefix: "zh-Hans")
    }

    /// Collapsed and expanded usage in both languages, both appearances, and
    /// all three styles, plus a low-remaining card. Token activity stays on
    /// its own screen and is not part of this pass.
    private func capture(language: String, prefix: String) {
        for appearance in ["light", "dark"] {
            for style in ["liquidGlass", "classic", "screenTime"] {
                let name = "\(prefix)-\(appearance)-\(style)"
                shot(
                    language: language,
                    appearance: appearance,
                    interfaceStyle: style,
                    screen: "usage",
                    name: "\(name)-usage"
                )
                shot(
                    language: language,
                    appearance: appearance,
                    interfaceStyle: style,
                    screen: "usageExpanded",
                    name: "\(name)-usage-expanded"
                )
            }
        }
        for appearance in ["light", "dark"] {
            shot(
                language: language,
                appearance: appearance,
                interfaceStyle: "liquidGlass",
                screen: "usageDanger",
                name: "\(prefix)-\(appearance)-liquidGlass-usage-danger"
            )
        }
        if language == "zh-Hans" {
            for style in ["classic", "screenTime"] {
                shot(
                    language: language,
                    appearance: "light",
                    interfaceStyle: style,
                    screen: "usageDanger",
                    name: "\(prefix)-light-\(style)-usage-danger"
                )
            }
        }
        for appearance in ["light", "dark"] {
            shot(
                language: language,
                appearance: appearance,
                interfaceStyle: "liquidGlass",
                screen: "settingsRoot",
                name: "\(prefix)-\(appearance)-settings-root"
            )
            shot(
                language: language,
                appearance: appearance,
                interfaceStyle: "screenTime",
                screen: "settings",
                name: "\(prefix)-\(appearance)-style"
            )
            shot(
                language: language,
                appearance: appearance,
                interfaceStyle: "liquidGlass",
                screen: "liveActivity",
                name: "\(prefix)-\(appearance)-live-activity"
            )
        }
    }

    private func shot(
        language: String,
        appearance: String,
        interfaceStyle: String = "liquidGlass",
        screen: String,
        name: String
    ) {
        let app = XCUIApplication()
        app.launchArguments = [
            "-BlinkyScreenshotFixture",
            "-BlinkyScreenshotLanguage", language,
            "-BlinkyScreenshotAppearance", appearance,
            "-BlinkyScreenshotInterfaceStyle", interfaceStyle,
            "-BlinkyScreenshotScreen", screen,
        ]
        app.launch()
        dismissSystemAlerts(app)

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
            let appearanceRow = app.staticTexts["Appearance"]
            let chineseAppearanceRow = app.staticTexts["外观"]
            XCTAssertTrue(appearanceRow.waitForExistence(timeout: 12) || chineseAppearanceRow.waitForExistence(timeout: 4))
            if appearanceRow.exists {
                appearanceRow.tap()
            } else {
                chineseAppearanceRow.tap()
            }
            let label = app.staticTexts["Interface appearance"]
            let chinese = app.staticTexts["界面外观"]
            XCTAssertTrue(label.waitForExistence(timeout: 8) || chinese.waitForExistence(timeout: 4))
            let style = app.staticTexts["Interface style"]
            let chineseStyle = app.staticTexts["界面风格"]
            XCTAssertTrue(style.exists || chineseStyle.waitForExistence(timeout: 4))
            let selected = selectedInterfaceStyleTitle(language: language, interfaceStyle: interfaceStyle)
            XCTAssertTrue(app.staticTexts[selected].waitForExistence(timeout: 4))
            let bars = app.staticTexts["Progress bars"]
            let chineseBars = app.staticTexts["进度条"]
            XCTAssertTrue(bars.exists || chineseBars.exists)
        case "forecasts":
            let forecastsRow = app.staticTexts["Forecasts"]
            let chineseForecastsRow = app.staticTexts["预测"]
            XCTAssertTrue(forecastsRow.waitForExistence(timeout: 12) || chineseForecastsRow.waitForExistence(timeout: 4))
            if forecastsRow.exists {
                forecastsRow.tap()
            } else {
                chineseForecastsRow.tap()
            }
            let estimate = language == "zh-Hans" ? "显示预估" : "Show the estimate"
            let predicted = language == "zh-Hans" ? "显示预测重置" : "Show predicted reset"
            XCTAssertTrue(app.staticTexts[estimate].waitForExistence(timeout: 8))
            let predictedSwitch = app.switches["forecasts-show-predicted"]
            var swipes = 0
            while !predictedSwitch.exists && swipes < 4 {
                app.swipeUp()
                swipes += 1
            }
            XCTAssertTrue(predictedSwitch.waitForExistence(timeout: 4))
            XCTAssertTrue(app.staticTexts[predicted].exists)
            XCTAssertTrue(app.switches["forecasts-show-estimate"].exists)
        case "settingsRoot":
            let appearanceRow = app.staticTexts["Appearance"]
            let chineseAppearanceRow = app.staticTexts["外观"]
            XCTAssertTrue(appearanceRow.waitForExistence(timeout: 12) || chineseAppearanceRow.waitForExistence(timeout: 4))
            let about = app.staticTexts["About"]
            let chineseAbout = app.staticTexts["关于"]
            var swipes = 0
            while !about.exists && !chineseAbout.exists && swipes < 4 {
                app.swipeUp()
                swipes += 1
            }
            XCTAssertTrue(about.exists || chineseAbout.exists)
            XCTAssertFalse(app.staticTexts["Self-hosted Worker"].exists)
            XCTAssertFalse(app.staticTexts["自托管服务"].exists)
            swipes = 0
            while !appearanceRow.exists && !chineseAppearanceRow.exists && swipes < 4 {
                app.swipeDown()
                swipes += 1
            }
        case "liveActivity":
            openSettingsModule(app, english: "Live Activity", chinese: "实时活动")
            let percent = app.staticTexts["Show percentage remaining"]
            let chinesePercent = app.staticTexts["显示剩余百分比"]
            let cards = app.staticTexts["Show banked resets"]
            let chineseCards = app.staticTexts["显示重置卡"]
            XCTAssertTrue(percent.waitForExistence(timeout: 8) || chinesePercent.waitForExistence(timeout: 4))
            XCTAssertTrue(cards.exists || chineseCards.waitForExistence(timeout: 4))
            XCTAssertFalse(app.staticTexts["Kong Yi"].exists)
            XCTAssertFalse(app.staticTexts["sharkchili.cai@gmail.com"].exists)
            XCTAssertFalse(app.switches["Kong Yi"].exists)
        case "about":
            openIdentifier(app, "settings-module-about")
            XCTAssertTrue(app.descendants(matching: .any)["about-check-updates"].waitForExistence(timeout: 12))
        case "notifications":
            openSettingsModule(app, english: "Notifications", chinese: "通知")
            let allow = app.staticTexts["Allow Notifications"]
            let chineseAllow = app.staticTexts["允许通知"]
            let unexpected = app.staticTexts["Unexpected or early resets"]
            let chineseUnexpected = app.staticTexts["意外或提前的重置"]
            XCTAssertTrue(
                allow.waitForExistence(timeout: 8)
                    || chineseAllow.waitForExistence(timeout: 4)
                    || unexpected.exists
                    || chineseUnexpected.exists
            )
        case "tokenActivity":
            openTokenActivity(app)
            let legend = language == "zh-Hans" ? "少" : "Less"
            XCTAssertTrue(app.staticTexts[legend].waitForExistence(timeout: 15))
            XCTAssertTrue(app.staticTexts["gpt-5.4"].waitForExistence(timeout: 8))
        case "tokenActivityWeekly":
            openTokenActivity(app)
            XCTAssertTrue(app.descendants(matching: .any)["token-activity-weekly"].waitForExistence(timeout: 12))
        case "tokenActivityCumulative":
            openTokenActivity(app)
            XCTAssertTrue(app.descendants(matching: .any)["token-activity-cumulative"].waitForExistence(timeout: 12))
        case "tokenActivityEmpty":
            let token = app.staticTexts["Token activity"]
            let chineseToken = app.staticTexts["Token 活动"]
            XCTAssertTrue(app.staticTexts["Appearance"].waitForExistence(timeout: 12)
                || app.staticTexts["外观"].waitForExistence(timeout: 4))
            XCTAssertFalse(token.exists)
            XCTAssertFalse(chineseToken.exists)
        case "tokenActivityExpanded":
            openTokenActivity(app)
            let missingCache = app.staticTexts["—"]
            var swipes = 0
            while !missingCache.isHittable && swipes < 5 {
                app.swipeUp()
                swipes += 1
            }
            XCTAssertTrue(missingCache.waitForExistence(timeout: 8))
        case "usageExpanded":
            let disclosure = app.descendants(matching: .any)
                .matching(NSPredicate(format: "identifier == %@", "forecasts-disclosure"))
                .element(boundBy: 0)
            XCTAssertTrue(disclosure.waitForExistence(timeout: 12))
            disclosure.tap()
            let forecastHeader = language == "zh-Hans" ? "用尽预测" : "Exhaustion forecast"
            let resetHeader = language == "zh-Hans" ? "重置卡" : "Reset cards"
            let pace = language == "zh-Hans" ? "早于重置" : "Before reset"
            XCTAssertTrue(
                app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", forecastHeader))
                    .firstMatch
                    .waitForExistence(timeout: 6)
            )
            XCTAssertTrue(
                app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", resetHeader))
                    .firstMatch
                    .waitForExistence(timeout: 4)
            )
            XCTAssertTrue(app.descendants(matching: .any)["usage-footer-codex"].waitForExistence(timeout: 4))
            XCTAssertTrue(
                app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", pace))
                    .firstMatch
                    .waitForExistence(timeout: 4)
            )
            XCTAssertFalse(app.staticTexts["估算价值"].exists)
            XCTAssertFalse(app.staticTexts["Estimated value"].exists)
        case "usageDanger":
            let exhausted = language == "zh-Hans" ? "剩余 0%" : "0% left"
            var swipes = 0
            while !app.staticTexts[exhausted].isHittable && swipes < 4 {
                app.swipeUp()
                swipes += 1
            }
            XCTAssertTrue(app.staticTexts[exhausted].waitForExistence(timeout: 8))
        case "reorder":
            let done = app.buttons["Done"]
            let chineseDone = app.buttons["完成"]
            XCTAssertTrue(done.waitForExistence(timeout: 12) || chineseDone.waitForExistence(timeout: 4))
        default:
            XCTAssertTrue(app.navigationBars.firstMatch.waitForExistence(timeout: 15))
            XCTAssertTrue(
                app.descendants(matching: .any)["usage-style-\(interfaceStyle)"].waitForExistence(timeout: 8)
            )
        }

        RunLoop.current.run(until: Date().addingTimeInterval(0.8))
        dismissSystemAlerts(app)
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        app.terminate()
    }

    /// The simulator sometimes asks for an Apple Account. That sheet covers the card.
    private func dismissSystemAlerts(_ app: XCUIApplication) {
        let monitor = addUIInterruptionMonitor(withDescription: "System alert") { alert in
            for label in ["Not Now", "以后", "Cancel", "取消", "Don't Allow", "不允许"] {
                if alert.buttons[label].exists {
                    alert.buttons[label].tap()
                    return true
                }
            }
            return false
        }
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        var dismissed = false
        for label in ["Not Now", "以后", "Cancel", "取消"] {
            let systemButton = springboard.buttons[label]
            if systemButton.exists {
                systemButton.tap()
                dismissed = true
            }
            let appButton = app.buttons[label]
            if appButton.exists {
                appButton.tap()
                dismissed = true
            }
        }
        if !dismissed && (springboard.alerts.firstMatch.exists || app.alerts.firstMatch.exists) {
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.08)).tap()
        }
        removeUIInterruptionMonitor(monitor)
    }

    private func openIdentifier(_ app: XCUIApplication, _ identifier: String) {
        let row = app.descendants(matching: .any)[identifier]
        var swipes = 0
        while !row.isHittable && swipes < 8 {
            app.swipeUp()
            swipes += 1
        }
        XCTAssertTrue(row.waitForExistence(timeout: 8))
        row.tap()
    }

    private func openTokenActivity(_ app: XCUIApplication) {
        openSettingsModule(app, english: "Token activity", chinese: "Token 活动")
    }

    private func openSettingsModule(_ app: XCUIApplication, english: String, chinese: String) {
        let row = app.staticTexts[english]
        let chineseRow = app.staticTexts[chinese]
        var swipes = 0
        while !row.exists && !chineseRow.exists && swipes < 6 {
            app.swipeUp()
            swipes += 1
        }
        XCTAssertTrue(row.waitForExistence(timeout: 8) || chineseRow.waitForExistence(timeout: 4))
        if row.exists {
            row.tap()
        } else {
            chineseRow.tap()
        }
    }

    /// The appearance picker shows only the selected style until it is opened.
    private func selectedInterfaceStyleTitle(language: String, interfaceStyle: String) -> String {
        let chinese = language == "zh-Hans"
        switch interfaceStyle {
        case "classic":
            return chinese ? "经典" : "Classic"
        case "screenTime":
            return chinese ? "方块进度条" : "Block bars"
        default:
            return chinese ? "液态玻璃" : "Liquid Glass"
        }
    }
}
