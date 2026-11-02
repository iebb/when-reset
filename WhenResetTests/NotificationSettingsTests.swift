import UserNotifications
import XCTest
@testable import WhenReset

final class NotificationSettingsTests: XCTestCase {
    func testPermissionPresentationMatchesSystemStatus() {
        XCTAssertEqual(NotificationPermissionPresentation(.notDetermined), .needsRequest)
        XCTAssertEqual(NotificationPermissionPresentation(.provisional), .provisional)
        XCTAssertEqual(NotificationPermissionPresentation(.authorized), .allowed)
        XCTAssertEqual(NotificationPermissionPresentation(.denied), .denied)
        XCTAssertEqual(NotificationPermissionPresentation(.ephemeral), .ephemeral)
    }

    func testEnglishNotificationCopyKeepsDetectorPhrases() {
        let earlyWeekly = UsageNotificationCopy.format(
            "%@’s weekly allowance increased from %lld%% to %lld%% before its scheduled reset. A banked reset was probably applied.",
            "Work",
            Int64(20),
            Int64(100)
        )
        XCTAssertTrue(earlyWeekly.contains("20% to 100%"))

        let earlyQuota = UsageNotificationCopy.format(
            "%1$@ %2$lld%%→%3$lld%%",
            "Weekly limit",
            Int64(20),
            Int64(80)
        )
        XCTAssertTrue(earlyQuota.contains("20%→80%"))

        let banked = UsageNotificationCopy.format(
            "A new banked reset was added to %@.",
            "Work"
        )
        XCTAssertTrue(banked.contains("new banked reset"))
        XCTAssertEqual(
            UsageNotificationCopy.format("%@ reset", "Weekly limit"),
            String(format: String.localized("%@ reset"), locale: AppLanguage.current.locale, "Weekly limit")
        )
    }
}
