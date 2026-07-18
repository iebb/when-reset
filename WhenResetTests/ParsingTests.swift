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
        XCTAssertEqual(CountdownDisplay.usageString(
            until: now.addingTimeInterval(6 * 86_400 + 21 * 3_600 + 4 * 60 + 5), from: now
        ), "6 days, 21:04:05")
    }

    func testLiveActivityCountdownUsesRequestedDayHourAndNativeTimerTiers() {
        let now = Date(timeIntervalSince1970: 1_000)
        XCTAssertEqual(CountdownDisplay.liveActivityValue(until: now.addingTimeInterval(-1), from: now), .expired)
        XCTAssertEqual(CountdownDisplay.liveActivityValue(until: now, from: now), .expired)
        XCTAssertEqual(CountdownDisplay.liveActivityValue(until: now.addingTimeInterval(1), from: now), .timer)
        XCTAssertEqual(CountdownDisplay.liveActivityValue(until: now.addingTimeInterval(7_199), from: now), .timer)
        XCTAssertEqual(CountdownDisplay.liveActivityValue(until: now.addingTimeInterval(7_200), from: now),
                       .hours(hours: 2, minutes: 0))
        XCTAssertEqual(CountdownDisplay.liveActivityValue(until: now.addingTimeInterval(7_500), from: now),
                       .hours(hours: 2, minutes: 5))
        XCTAssertEqual(CountdownDisplay.liveActivityValue(until: now.addingTimeInterval(86_399), from: now),
                       .hours(hours: 23, minutes: 59))
        XCTAssertEqual(CountdownDisplay.liveActivityValue(until: now.addingTimeInterval(86_400), from: now),
                       .days(days: 1, hours: 0))
        XCTAssertEqual(CountdownDisplay.liveActivityValue(until: now.addingTimeInterval(90_000), from: now),
                       .days(days: 1, hours: 1))
        XCTAssertEqual(CountdownDisplay.liveActivityValue(until: now.addingTimeInterval(172_799), from: now),
                       .days(days: 1, hours: 23))
        XCTAssertEqual(CountdownDisplay.liveActivityValue(until: now.addingTimeInterval(172_800), from: now),
                       .days(days: 2, hours: 0))
    }

    func testLockScreenCountdownPadsHoursAfterDays() {
        let now = Date(timeIntervalSince1970: 1_000)
        XCTAssertEqual(CountdownDisplay.widgetString(
            until: now.addingTimeInterval(8 * 86_400 + 3 * 3_600 + 59 * 60), from: now
        ), "8d 03h")
    }

    func testLiveActivityTargetsSortClosestFirstAndKeepOnlyFour() {
        let now = Date(timeIntervalSince1970: 1_000)
        let targets = [
            UsageActivityTarget(id: "account-a-weekly", kind: .quota, accountName: "A",
                                accountSymbolName: nil, providerID: .chatGPT, title: "Weekly",
                                remainingPercent: 80, expiresAt: now.addingTimeInterval(8 * 3_600)),
            UsageActivityTarget(id: "account-a-five-hour", kind: .quota, accountName: "A",
                                accountSymbolName: nil, providerID: .chatGPT, title: "5h",
                                remainingPercent: 20, expiresAt: now.addingTimeInterval(2 * 3_600)),
            UsageActivityTarget(id: "account-b-weekly", kind: .quota, accountName: "B",
                                accountSymbolName: nil, providerID: .claude, title: "Weekly",
                                remainingPercent: 30, progressFraction: 0.3,
                                expiresAt: now.addingTimeInterval(3_600)),
            UsageActivityTarget(id: "account-a-banked", kind: .bankedReset, accountName: "A",
                                accountSymbolName: nil, providerID: .chatGPT, title: "Banked resets",
                                resetCount: 3, expiresAt: now.addingTimeInterval(3 * 3_600)),
            UsageActivityTarget(id: "account-c-weekly", kind: .quota, accountName: "C",
                                accountSymbolName: nil, providerID: .kimi, title: "Weekly",
                                remainingPercent: 50, expiresAt: now.addingTimeInterval(12 * 3_600))
        ]

        let state = UsageActivityAttributes.ContentState(targets: targets, updatedAt: now)
        XCTAssertEqual(state.targets.map(\.id), [
            "account-b-weekly", "account-a-five-hour", "account-a-banked", "account-a-weekly"
        ])
        XCTAssertEqual(state.targets.first?.accountName, "B")
        XCTAssertEqual(state.targets.first?.progressFraction, 0.3)
        XCTAssertEqual(state.targets[1].accountName, "A")
    }

    func testLiveActivityLegacyStateDecodesAndSortsAllTargets() throws {
        struct LegacyState: Encodable {
            var primaryTitle = "Weekly"
            var primaryAccountName = "ChatGPT"
            var primaryProviderID = ProviderID.chatGPT
            var primaryUsedPercent = 70.0
            var primaryResetsAt: Date
            var secondaryTitle = "Session"
            var secondaryAccountName = "Claude"
            var secondaryProviderID = ProviderID.claude
            var secondaryUsedPercent = 20.0
            var secondaryResetsAt: Date
            var availableResets = 2
            var nextBankedResetExpiresAt: Date
            var updatedAt: Date
        }

        let now = Date(timeIntervalSince1970: 1_000)
        let data = try JSONEncoder().encode(LegacyState(
            primaryResetsAt: now.addingTimeInterval(8_000),
            secondaryResetsAt: now.addingTimeInterval(2_000),
            nextBankedResetExpiresAt: now.addingTimeInterval(5_000), updatedAt: now
        ))
        let state = try JSONDecoder().decode(UsageActivityAttributes.ContentState.self, from: data)

        XCTAssertEqual(state.targets.map(\.id), ["legacy-secondary", "legacy-banked", "legacy-primary"])
        XCTAssertEqual(state.targets[0].remainingPercent, 80)
        XCTAssertEqual(state.targets[1].resetCount, 2)
    }

    func testLiveActivityFourTargetPayloadStaysBelowActivityKitLimit() throws {
        let now = Date(timeIntervalSince1970: 1_000)
        let longText = String(repeating: "x", count: 1_000)
        let targets = (0..<4).map { index in
            UsageActivityTarget(id: "\(index)-\(longText)", kind: .quota,
                                accountName: longText, accountSymbolName: longText,
                                providerID: .chatGPT, title: longText,
                                remainingPercent: Double(index * 10),
                                expiresAt: now.addingTimeInterval(Double(index + 1) * 3_600))
        }
        let state = UsageActivityAttributes.ContentState(targets: targets, updatedAt: now)
        let data = try JSONEncoder().encode(state)

        XCTAssertEqual(state.targets.count, 4)
        XCTAssertLessThan(data.count, 4_096)
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
        XCTAssertEqual(settings.defaultLiveActivityRule.trigger, .remainingHours)
        XCTAssertEqual(settings.defaultLiveActivityRule.remainingHours, 4)
        XCTAssertTrue(settings.liveActivityQuotaRules.isEmpty)
    }

    func testLegacyGlobalLiveActivityModesDecodeToAutomaticAndDisabled() throws {
        let automatic = try JSONDecoder().decode(GlobalLiveActivitySettings.self,
            from: Data(#"{"mode":"nearReset","nearResetMinutes":60}"#.utf8))
        let disabled = try JSONDecoder().decode(GlobalLiveActivitySettings.self,
            from: Data(#"{"mode":"manual"}"#.utf8))
        XCTAssertEqual(automatic.mode, .automatic)
        XCTAssertEqual(disabled.mode, .disabled)
        XCTAssertTrue(automatic.showBankedResets)
    }

    func testPerQuotaLiveActivityRulesMatchExactBoundaries() throws {
        let now = Date(timeIntervalSince1970: 1_000)
        let window = UsageWindow(title: "Weekly", usedPercent: 80,
                                 resetsAt: now.addingTimeInterval(4 * 3_600), windowMinutes: 10_080)
        XCTAssertTrue(LiveActivityQuotaRule(trigger: .remainingPercent, remainingPercent: 20).matches(window, at: now))
        XCTAssertFalse(LiveActivityQuotaRule(trigger: .remainingPercent, remainingPercent: 19).matches(window, at: now))
        XCTAssertTrue(LiveActivityQuotaRule(trigger: .remainingHours, remainingHours: 4).matches(window, at: now))
        XCTAssertFalse(LiveActivityQuotaRule(trigger: .remainingHours, remainingHours: 3).matches(window, at: now))
        XCTAssertFalse(LiveActivityQuotaRule(trigger: .exhausted).matches(window, at: now))
        XCTAssertFalse(LiveActivityQuotaRule(trigger: .never).matches(window, at: now))

        var nearlyExhausted = window
        nearlyExhausted.usedPercent = 99.999
        XCTAssertFalse(LiveActivityQuotaRule(trigger: .exhausted).matches(nearlyExhausted, at: now))

        var exhausted = window
        exhausted.usedPercent = 100
        XCTAssertTrue(LiveActivityQuotaRule(trigger: .exhausted).matches(exhausted, at: now))
        exhausted.usedPercent = 120
        XCTAssertTrue(LiveActivityQuotaRule(trigger: .exhausted).matches(exhausted, at: now))
        XCTAssertFalse(LiveActivityQuotaRule(trigger: .exhausted).matches(expiry: window.resetsAt, at: now))

        let encoded = try JSONEncoder().encode(LiveActivityQuotaRule(trigger: .exhausted))
        XCTAssertEqual(try JSONDecoder().decode(LiveActivityQuotaRule.self, from: encoded).trigger, .exhausted)

        var expired = window
        expired.resetsAt = now
        XCTAssertFalse(LiveActivityQuotaRule(trigger: .remainingPercent, remainingPercent: 100).matches(expired, at: now))
    }

    func testChatGPTSpecificLinkedPlanSurvivesGenericUsagePlan() throws {
        let account = MonitoredAccount(id: UUID(), providerID: .chatGPT, displayName: "Test",
                                       workspaceID: "workspace", plan: "pro_20x", addedAt: .now)
        let usage = try JSONSerialization.data(withJSONObject: ["plan_type": "pro"])
        let credits = try JSONSerialization.data(withJSONObject: ["credits": [], "available_count": 0])

        let snapshot = try ChatGPTProvider().parse(account: account, usage: usage, credits: credits)
        XCTAssertEqual(snapshot.plan, "pro_20x")
        XCTAssertEqual(ProviderID.chatGPT.sectionTitle(plan: snapshot.plan), "ChatGPT Pro 20x")
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
            "https://api.openai.com/profile": [
                "name": "Profile Person",
                "email": "profile@example.com"
            ],
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
        XCTAssertEqual(identity.displayName, "Profile Person")
        XCTAssertEqual(identity.email, "profile@example.com")
        XCTAssertNil(identity.planExpiresAt)
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

    func testRefreshFailureClassifiesExpiredProviderCredentialsAsAuthentication() {
        XCTAssertTrue(AccountRefreshFailure.requiresReauthentication(
            for: ProviderError.server(401, "unauthorized")
        ))
        XCTAssertTrue(AccountRefreshFailure.requiresReauthentication(
            for: ProviderError.server(400, #"{"error":"invalid_grant"}"#)
        ))
        XCTAssertTrue(AccountRefreshFailure.requiresReauthentication(
            for: KimiProviderError.reauthenticationRequired
        ))
        XCTAssertTrue(AccountRefreshFailure.requiresReauthentication(
            for: CopilotProviderError.relinkRequired
        ))
        XCTAssertTrue(AccountRefreshFailure.requiresReauthentication(
            for: ZAIProviderError.authorizationFailed
        ))
    }

    func testRefreshFailureKeepsTransientErrorsSeparateFromAuthentication() {
        XCTAssertFalse(AccountRefreshFailure.requiresReauthentication(
            for: URLError(.notConnectedToInternet)
        ))

        let failedAt = Date(timeIntervalSince1970: 2_000)
        let failure = AccountRefreshFailure(error: URLError(.timedOut), failedAt: failedAt)
        XCTAssertEqual(failure.kind, .update)
        XCTAssertFalse(failure.requiresRelink)
        XCTAssertEqual(failure.failedAt, failedAt)
    }

    func testAuthenticationFailureUsesSafeRelinkMessage() {
        let failure = AccountRefreshFailure(
            error: ProviderError.server(403, "provider response that should not be shown")
        )

        XCTAssertEqual(failure.kind, .authentication)
        XCTAssertTrue(failure.requiresRelink)
        XCTAssertEqual(failure.title, "Sign-in failed")
        XCTAssertFalse(failure.message.contains("provider response"))
    }
}
