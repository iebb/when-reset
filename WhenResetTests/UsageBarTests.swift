import SwiftUI
import XCTest
@testable import WhenReset

final class UsageBarTests: XCTestCase {
    func testSegmentedTicksNeverLookUntouchedOrFullUntilTheyAre() {
        let width: CGFloat = 100
        let empty = UsageBar.ticks(width: width, fraction: 0)
        XCTAssertGreaterThan(empty.count, 1)
        XCTAssertEqual(empty.lit, 0)

        let touched = UsageBar.ticks(width: width, fraction: 0.001)
        XCTAssertEqual(touched.count, empty.count)
        XCTAssertEqual(touched.lit, 1)

        let almost = UsageBar.ticks(width: width, fraction: 0.999)
        XCTAssertEqual(almost.lit, almost.count - 1)

        let full = UsageBar.ticks(width: width, fraction: 1)
        XCTAssertEqual(full.lit, full.count)
    }

    func testBarStyleDefaultsToContinuous() {
        let standard = UserDefaults.standard
        let shared = UserDefaults(suiteName: AppIdentity.appGroupIdentifier)
        let key = UsageBarStyle.storageKey
        let previousStandard = standard.string(forKey: key)
        let previousShared = shared?.string(forKey: key)
        standard.removeObject(forKey: key)
        shared?.removeObject(forKey: key)
        defer {
            if let previousStandard {
                standard.set(previousStandard, forKey: key)
            }
            if let shared {
                if let previousShared {
                    shared.set(previousShared, forKey: key)
                } else {
                    shared.removeObject(forKey: key)
                }
            }
        }
        XCTAssertEqual(UsageBarStyle.current, .continuous)
    }

    func testRemainingColorUsesThreeTiers() {
        let light = ColorScheme.light
        let comfortable = UsageMeterTint.color(remainingFraction: 0.85, colorScheme: light)
        let warning = UsageMeterTint.color(remainingFraction: 0.20, colorScheme: light)
        let danger = UsageMeterTint.color(remainingFraction: 0, colorScheme: light)
        XCTAssertNotEqual(comfortable, warning)
        XCTAssertNotEqual(warning, danger)
        XCTAssertEqual(
            UsageMeterTint.color(remainingFraction: 0.25, colorScheme: light),
            warning
        )
        XCTAssertEqual(
            UsageMeterTint.color(remainingFraction: 0.26, colorScheme: light),
            comfortable
        )
    }

    func testInterfaceStylesUseDifferentContinuousMeters() {
        let classic = InterfaceStyle.classic.continuousMeter(prominent: true)
        let screenTime = InterfaceStyle.screenTime.continuousMeter(prominent: true)
        let glass = InterfaceStyle.liquidGlass.continuousMeter(prominent: true)
        XCTAssertEqual(classic.cap, .round)
        XCTAssertEqual(screenTime.cap, .square)
        XCTAssertEqual(glass.cap, .round)
        XCTAssertGreaterThan(screenTime.height, classic.height)
        XCTAssertGreaterThan(screenTime.height, glass.height)
        let screenTimeCard = InterfaceStyle.screenTime.continuousMeter(prominent: false)
        XCTAssertEqual(screenTimeCard.cap, .square)
        XCTAssertGreaterThan(
            screenTimeCard.height,
            InterfaceStyle.classic.continuousMeter(prominent: false).height
        )
        XCTAssertLessThan(screenTimeCard.height, screenTime.height)
        XCTAssertGreaterThan(glass.trackOpacity, classic.trackOpacity)
        XCTAssertNotEqual(classic, screenTime)
        XCTAssertNotEqual(screenTime, glass)
    }

    func testInterfaceStyleDefaultsToLiquidGlassAndIgnoresAppearance() {
        let standard = UserDefaults.standard
        let shared = UserDefaults(suiteName: AppIdentity.appGroupIdentifier)
        let styleKey = InterfaceStyle.storageKey
        let appearanceKey = AppAppearance.storageKey
        let previousStyle = standard.string(forKey: styleKey)
        let previousSharedStyle = shared?.string(forKey: styleKey)
        let previousAppearance = standard.string(forKey: appearanceKey)
        let previousSharedAppearance = shared?.string(forKey: appearanceKey)
        defer {
            restore(previousStyle, key: styleKey, defaults: standard)
            restore(previousAppearance, key: appearanceKey, defaults: standard)
            if let shared {
                restore(previousSharedStyle, key: styleKey, defaults: shared)
                restore(previousSharedAppearance, key: appearanceKey, defaults: shared)
            }
        }

        standard.removeObject(forKey: styleKey)
        shared?.removeObject(forKey: styleKey)
        XCTAssertNotEqual(styleKey, appearanceKey)
        XCTAssertEqual(InterfaceStyle.current, .liquidGlass)

        AppAppearance.choose(.dark)
        XCTAssertEqual(AppAppearance.current, .dark)
        XCTAssertEqual(InterfaceStyle.current, .liquidGlass)

        InterfaceStyle.choose(.classic)
        XCTAssertEqual(InterfaceStyle.current, .classic)
        XCTAssertEqual(shared?.string(forKey: styleKey), InterfaceStyle.classic.rawValue)
        XCTAssertEqual(AppAppearance.current, .dark)
    }

    private func restore(_ value: String?, key: String, defaults: UserDefaults) {
        if let value {
            defaults.set(value, forKey: key)
        } else {
            defaults.removeObject(forKey: key)
        }
    }
}
