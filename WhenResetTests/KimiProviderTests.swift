import XCTest
@testable import WhenReset

final class KimiProviderTests: XCTestCase {
    func testDeviceAuthorizationUsesCompleteURLAndServerLifetime() throws {
        let now = Date(timeIntervalSince1970: 1_000)
        let data = Data(#"""
        {
            "device_code":"device-secret",
            "user_code":"ABCD-EFGH",
            "verification_uri":"https://www.kimi.com/code/authorize_device",
            "verification_uri_complete":"https://www.kimi.com/code/authorize_device?user_code=ABCD-EFGH",
            "expires_in":1800,
            "interval":"7"
        }
        """#.utf8)

        let link = try KimiProvider.deviceLink(from: data, now: now)

        XCTAssertEqual(link.verificationURL.absoluteString,
                       "https://www.kimi.com/code/authorize_device?user_code=ABCD-EFGH")
        XCTAssertEqual(link.userCode, "ABCD-EFGH")
        XCTAssertEqual(link.deviceCode, "device-secret")
        XCTAssertEqual(link.interval, .seconds(7))
        XCTAssertEqual(link.expiresAt, now.addingTimeInterval(1_800))
    }

    func testTokenResponsePersistsRotatedRefreshTokenAndExpiration() throws {
        let now = Date(timeIntervalSince1970: 2_000)
        let data = Data(#"""
        {
            "access_token":"new-access",
            "refresh_token":"rotated-refresh",
            "id_token":"identity",
            "expires_in":"3600",
            "token_type":"Bearer"
        }
        """#.utf8)

        let credentials = try KimiProvider.credentials(from: data, previousIDToken: "old-id", now: now)

        XCTAssertEqual(credentials.accessToken, "new-access")
        XCTAssertEqual(credentials.refreshToken, "rotated-refresh")
        XCTAssertEqual(credentials.idToken, "identity")
        XCTAssertEqual(credentials.expiresAt, now.addingTimeInterval(3_600))
    }

    func testUsageParserBuildsFiveHourWeeklyAndAdditionalWindows() throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let data = Data(#"""
        {
            "usage": {
                "limit": "2048",
                "remaining": "1536",
                "resetTime": "2026-01-09T15:23:13.373329235Z"
            },
            "limits": [
                {
                    "window": {"duration": 300, "timeUnit": "TIME_UNIT_MINUTE"},
                    "detail": {
                        "limit": 200,
                        "used": 50,
                        "reset_at": "2026-01-06T15:05:24.374187075Z"
                    }
                },
                {
                    "name": "Daily cap",
                    "window": {"duration": 24, "timeUnit": "TIME_UNIT_HOUR"},
                    "detail": {
                        "limit": "100",
                        "remaining": "80",
                        "resetIn": 3600
                    }
                }
            ]
        }
        """#.utf8)
        let account = MonitoredAccount(id: UUID(), providerID: .kimi, displayName: "Kimi account",
                                       workspaceID: "kimi-user", plan: nil, addedAt: now)

        let snapshot = try KimiProvider().parse(account: account, data: data, now: now)

        XCTAssertEqual(snapshot.providerName, "Kimi Code")
        XCTAssertEqual(snapshot.primary?.metricID, "five_hour")
        XCTAssertEqual(snapshot.primary?.usedPercent, 25)
        XCTAssertEqual(snapshot.primary?.windowMinutes, 300)
        XCTAssertEqual(snapshot.secondary?.metricID, "weekly")
        XCTAssertEqual(snapshot.secondary?.usedPercent, 25)
        XCTAssertEqual(snapshot.secondary?.windowMinutes, 10_080)
        XCTAssertEqual(snapshot.extraWindows?.first?.displayTitle, "Daily cap")
        XCTAssertEqual(snapshot.extraWindows?.first?.usedPercent, 20)
        XCTAssertEqual(snapshot.extraWindows?.first?.resetsAt, now.addingTimeInterval(3_600))

        let expectedWeeklyReset = try XCTUnwrap(
            ISO8601DateFormatter().date(from: "2026-01-09T15:23:13Z")
        )
        XCTAssertEqual(try XCTUnwrap(snapshot.secondary?.resetsAt).timeIntervalSince1970,
                       expectedWeeklyReset.timeIntervalSince1970 + 0.373329235,
                       accuracy: 0.001)
    }

    func testUsageParserRejectsQuotaWithoutResetTime() throws {
        let data = Data(#"{"usage":{"limit":"100","used":"25"},"limits":[]}"#.utf8)
        let account = MonitoredAccount(id: UUID(), providerID: .kimi, displayName: "Kimi account",
                                       workspaceID: "kimi-user", plan: nil, addedAt: .now)

        XCTAssertThrowsError(try KimiProvider().parse(account: account, data: data)) { error in
            guard case KimiProviderError.missingUsageWindows = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
    }
}
