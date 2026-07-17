import XCTest
@testable import WhenReset

final class ParsingTests: XCTestCase {
    func testRemainingPercentIsClamped() {
        XCTAssertEqual(UsageWindow(title: "Test", usedPercent: 30, resetsAt: .now, windowMinutes: nil).remainingPercent, 70)
        XCTAssertEqual(UsageWindow(title: "Test", usedPercent: 120, resetsAt: .now, windowMinutes: nil).remainingPercent, 0)
    }

    func testBankedResetExpiryUsesNextAvailableCredit() {
        let now = Date(timeIntervalSince1970: 1_000)
        var snapshot = UsageSnapshot.preview
        snapshot.resetCredits = [
            ResetCredit(id: "spent", expiresAt: now.addingTimeInterval(10), status: "used"),
            ResetCredit(id: "later", expiresAt: now.addingTimeInterval(300), status: "available"),
            ResetCredit(id: "past", expiresAt: now.addingTimeInterval(-10), status: "available"),
            ResetCredit(id: "next", expiresAt: now.addingTimeInterval(60), status: "AVAILABLE"),
            ResetCredit(id: "forever", expiresAt: nil, status: "available")
        ]

        XCTAssertEqual(snapshot.availableResetCredits.map(\.id), ["past", "next", "later", "forever"])
        XCTAssertEqual(snapshot.nextBankedResetExpiry(after: now), now.addingTimeInterval(60))
    }

    func testChatGPTResetCreditMicrosecondExpiriesParse() {
        let expiries = [
            "2026-07-18T00:30:13.485435Z",
            "2026-07-27T00:01:57.783638Z",
            "2026-07-31T20:14:55.520109Z",
            "2026-08-12T17:55:01.777363Z"
        ]

        let parsed = expiries.compactMap(ChatGPTProvider.date)
        XCTAssertEqual(parsed.count, expiries.count)
        XCTAssertEqual(parsed, parsed.sorted())
    }

    func testWeeklyWindowIsClassifiedByDurationInsteadOfPrimaryPosition() throws {
        let window = try XCTUnwrap(ChatGPTProvider.window([
            "used_percent": 14,
            "limit_window_seconds": 604_800,
            "reset_after_seconds": 596_678
        ]))

        XCTAssertEqual(window.windowMinutes, 10_080)
        XCTAssertEqual(window.displayTitle, "Weekly limit")
        XCTAssertEqual(window.remainingPercent, 86)
    }

    func testUsageWindowsSortFiveHourBeforeWeekly() {
        var snapshot = UsageSnapshot.preview
        snapshot.primary = UsageWindow(title: "Primary", usedPercent: 14, resetsAt: .now, windowMinutes: 10_080)
        snapshot.secondary = UsageWindow(title: "Secondary", usedPercent: 2, resetsAt: .now, windowMinutes: 300)

        XCTAssertEqual(snapshot.usageWindows.map(\.displayTitle), ["5h limit", "Weekly limit"])
    }

    func testBankedCountdownUsesDaysAndSubdayClock() {
        let now = Date(timeIntervalSince1970: 1_000)
        let expiry = now.addingTimeInterval(2 * 86_400 + 3 * 3_600 + 4 * 60 + 5)
        XCTAssertEqual(CountdownDisplay.string(until: expiry, from: now), "2 days, 03:04:05")
    }

    func testCompactCountdownSwitchesFromMinutesToHoursAtOneHundredMinutes() {
        let now = Date(timeIntervalSince1970: 1_000)
        XCTAssertEqual(CountdownDisplay.compactString(until: now.addingTimeInterval(99 * 60 + 59), from: now), "99m")
        XCTAssertEqual(CountdownDisplay.compactString(until: now.addingTimeInterval(100 * 60), from: now), "1h")
        XCTAssertEqual(CountdownDisplay.compactString(until: now.addingTimeInterval(48 * 3_600), from: now), "48h")
        XCTAssertEqual(CountdownDisplay.compactString(until: now.addingTimeInterval(49 * 3_600), from: now), "2d")
        XCTAssertEqual(CountdownDisplay.usageString(until: now.addingTimeInterval(6 * 86_400 + 21 * 3_600), from: now), "6 days")
    }

    func testLiveActivityBankedExpiryUsesNearestAcrossAccounts() {
        let now = Date(timeIntervalSince1970: 1_000)
        var first = UsageSnapshot.preview
        var second = UsageSnapshot.preview
        first.resetCredits = [ResetCredit(id: "later", expiresAt: now.addingTimeInterval(500), status: "available")]
        second.resetCredits = [
            ResetCredit(id: "expired", expiresAt: now.addingTimeInterval(-1), status: "available"),
            ResetCredit(id: "nearest", expiresAt: now.addingTimeInterval(100), status: "available")
        ]

        XCTAssertEqual(UsageSnapshot.nearestBankedResetExpiry(in: [first, second], after: now),
                       now.addingTimeInterval(100))
    }

    func testChatGPTAdditionalSparkLimitIsParsedAsItsOwnMetric() throws {
        let account = MonitoredAccount(id: UUID(), providerID: .chatGPT, displayName: "Test",
                                       workspaceID: "workspace", plan: "pro", addedAt: .now)
        let usageObject: [String: Any] = [
            "rate_limit": [
                "primary_window": [
                    "used_percent": 14,
                    "limit_window_seconds": 604_800,
                    "reset_at": 1_800_000_000
                ]
            ],
            "additional_rate_limits": [[
                "limit_name": "GPT-5.3-Codex-Spark",
                "metered_feature": "codex_bengalfox",
                "rate_limit": [
                    "primary_window": [
                        "used_percent": 3,
                        "limit_window_seconds": 604_800,
                        "reset_at": 1_800_000_100
                    ]
                ]
            ]]
        ]
        let usage = try JSONSerialization.data(withJSONObject: usageObject)
        let credits = try JSONSerialization.data(withJSONObject: ["credits": [], "available_count": 0])
        let snapshot = try ChatGPTProvider().parse(account: account, usage: usage, credits: credits)

        XCTAssertEqual(snapshot.usageWindows.map(\.displayTitle), ["Weekly limit", "GPT-5.3-Codex-Spark"])
        XCTAssertEqual(snapshot.usageWindows.last?.metricID, "additional:codex_bengalfox:primary")
    }

    func testAccountDisplayAndLiveActivitySelectionsAreIndependent() {
        let snapshot = UsageSnapshot.preview
        let weeklyID = try! XCTUnwrap(snapshot.secondary?.metricID)
        let fiveHourID = try! XCTUnwrap(snapshot.primary?.metricID)
        var settings = AccountMonitorSettings()
        settings.hiddenMetricIDs.insert(weeklyID)
        settings.hiddenLiveActivityMetricIDs.insert(fiveHourID)
        settings.showBankedResetsInLiveActivity = false

        XCTAssertEqual(snapshot.filtered(using: settings).usageWindows.map(\.metricID), [fiveHourID])
        let liveSnapshot = snapshot.filteredForLiveActivity(using: settings)
        XCTAssertEqual(liveSnapshot.usageWindows.map(\.metricID), [weeklyID])
        XCTAssertEqual(liveSnapshot.availableResetCount, 0)
    }

    func testLegacyAccountSettingsDecodeWithNewVisibilityDefaults() throws {
        let data = Data(#"{"liveActivityMode":"nearReset","nearResetMinutes":60}"#.utf8)
        let settings = try JSONDecoder().decode(AccountMonitorSettings.self, from: data)
        XCTAssertTrue(settings.showBankedResets)
        XCTAssertTrue(settings.showBankedResetsInLiveActivity)
        XCTAssertTrue(settings.hiddenMetricIDs.isEmpty)
        XCTAssertTrue(settings.hiddenLiveActivityMetricIDs.isEmpty)
    }

    func testClaudeOAuthAuthorizationUsesPKCEPublicClientFlow() throws {
        let link = try ClaudeProvider().beginLink()
        let components = try XCTUnwrap(URLComponents(url: link.authorizationURL, resolvingAgainstBaseURL: false))
        let query = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).compactMap { item in
            item.value.map { (item.name, $0) }
        })

        XCTAssertEqual(components.host, "claude.com")
        XCTAssertEqual(query["client_id"], ClaudeProvider.clientID)
        XCTAssertEqual(query["redirect_uri"], ClaudeProvider.redirectURI)
        XCTAssertEqual(query["code_challenge_method"], "S256")
        XCTAssertEqual(query["state"], link.state)
        XCTAssertFalse(query["code_challenge", default: ""].isEmpty)
    }

    func testChatGPTWorkspaceIsReadFromNamespacedAuthClaim() throws {
        let payload: [String: Any] = [
            "email": "person@example.com",
            "https://api.openai.com/profile": ["email": "profile@example.com"],
            "https://api.openai.com/auth": [
                "chatgpt_account_id": "account-123",
                "chatgpt_plan_type": "plus"
            ]
        ]
        let data = try JSONSerialization.data(withJSONObject: payload)
        let encoded = data.base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        let identity = try ChatGPTProvider().linkedIdentity(accessToken: "access", refreshToken: "refresh", idToken: "header.\(encoded).signature")
        XCTAssertEqual(identity.workspaceID, "account-123")
        XCTAssertEqual(identity.plan, "plus")
        XCTAssertEqual(identity.displayName, "profile@example.com")
    }

    func testCredentialsRoundTripThroughKeychain() throws {
        let id = UUID()
        let expiry = Date(timeIntervalSince1970: 2_000)
        let credentials = AccountCredentials(accessToken: "access", refreshToken: "refresh", idToken: "id", expiresAt: expiry)
        defer { KeychainStore.delete(for: id) }
        try KeychainStore.save(credentials, for: id)
        let restored = try KeychainStore.load(for: id)
        XCTAssertEqual(restored.accessToken, "access")
        XCTAssertEqual(restored.refreshToken, "refresh")
        XCTAssertEqual(restored.idToken, "id")
        XCTAssertEqual(restored.expiresAt, expiry)
    }
}
