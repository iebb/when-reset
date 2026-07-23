import Security
import XCTest
@testable import WhenReset

final class ParsingTests: XCTestCase {
    func testPublicGitHubLinksTargetWhenResetRepository() {
        XCTAssertEqual(AppLinks.sourceCode.scheme, "https")
        XCTAssertEqual(AppLinks.sourceCode.host, "github.com")
        XCTAssertEqual(AppLinks.sourceCode.path, "/iebb/when-reset")
        XCTAssertEqual(AppLinks.issues.path, "/iebb/when-reset/issues")
    }

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

    func testLiveActivityTargetsPutAllPinsFirstAndSortEachGroupByExpiry() {
        let now = Date(timeIntervalSince1970: 1_000)
        let targets = [
            UsageActivityTarget(id: "unpinned-nearest", kind: .quota, accountName: "A",
                                accountSymbolName: nil, providerID: .chatGPT, title: "5h",
                                expiresAt: now.addingTimeInterval(3_600)),
            UsageActivityTarget(id: "pinned-middle", kind: .quota, accountName: "B",
                                accountSymbolName: nil, providerID: .claude, title: "Weekly",
                                isPinned: true, expiresAt: now.addingTimeInterval(8 * 3_600)),
            UsageActivityTarget(id: "unpinned-second", kind: .bankedReset, accountName: "C",
                                accountSymbolName: nil, providerID: .chatGPT, title: "Banked resets",
                                expiresAt: now.addingTimeInterval(2 * 3_600)),
            UsageActivityTarget(id: "pinned-nearest", kind: .quota, accountName: "D",
                                accountSymbolName: nil, providerID: .kimi, title: "Session",
                                isPinned: true, expiresAt: now.addingTimeInterval(3 * 3_600)),
            UsageActivityTarget(id: "pinned-farthest", kind: .quota, accountName: "E",
                                accountSymbolName: nil, providerID: .githubCopilot, title: "Monthly",
                                isPinned: true, expiresAt: now.addingTimeInterval(12 * 3_600))
        ]

        XCTAssertEqual(UsageActivityTarget.ordered(targets, limit: 5).map(\.id), [
            "pinned-nearest", "pinned-middle", "pinned-farthest",
            "unpinned-nearest", "unpinned-second"
        ])
        XCTAssertEqual(UsageActivityTarget.ordered(targets).map(\.id), [
            "pinned-nearest", "pinned-middle", "pinned-farthest", "unpinned-nearest"
        ])
    }

    func testLiveActivityContentStateUsesPinnedTargetFirst() {
        let now = Date(timeIntervalSince1970: 1_000)
        let nearest = UsageActivityTarget(
            id: "nearest", kind: .quota, accountName: "Nearest", accountSymbolName: nil,
            providerID: .chatGPT, title: "5h", expiresAt: now.addingTimeInterval(3_600)
        )
        let pinned = UsageActivityTarget(
            id: "pinned", kind: .quota, accountName: "Pinned", accountSymbolName: nil,
            providerID: .claude, title: "Weekly", isPinned: true,
            expiresAt: now.addingTimeInterval(8 * 3_600)
        )

        let state = UsageActivityAttributes.ContentState(targets: [nearest, pinned], updatedAt: now)

        XCTAssertEqual(state.targets.first?.id, "pinned")
        XCTAssertEqual(state.targets.first?.isPinned, true)
        XCTAssertEqual(state.targets.dropFirst().first?.id, "nearest")
    }

    func testLegacyLiveActivityTargetWithoutPinDecodesAsUnpinned() throws {
        struct LegacyTarget: Encodable {
            var id: String
            var kind: UsageActivityTarget.Kind
            var accountName: String
            var providerID: ProviderID
            var title: String
            var expiresAt: Date
        }

        let data = try JSONEncoder().encode(LegacyTarget(
            id: "legacy", kind: .quota, accountName: "Legacy", providerID: .chatGPT,
            title: "Weekly", expiresAt: Date(timeIntervalSince1970: 10_000)
        ))
        let target = try JSONDecoder().decode(UsageActivityTarget.self, from: data)

        XCTAssertFalse(target.isPinned)
        let reencoded = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: JSONEncoder().encode(target)) as? [String: Any]
        )
        XCTAssertEqual(reencoded["isPinned"] as? Bool, false)
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
        XCTAssertTrue(settings.notifyAboutResets)
        XCTAssertTrue(settings.notifyAtScheduledReset)
        XCTAssertTrue(settings.showBankedResets)
        XCTAssertTrue(settings.showBankedResetsInLiveActivity)
        XCTAssertTrue(settings.hiddenMetricIDs.isEmpty)
        XCTAssertTrue(settings.hiddenLiveActivityMetricIDs.isEmpty)
        XCTAssertTrue(settings.pinnedLiveActivityMetricIDs.isEmpty)
        XCTAssertEqual(settings.defaultLiveActivityRule.trigger, .remainingHours)
        XCTAssertEqual(settings.defaultLiveActivityRule.remainingHours, 4)
        XCTAssertTrue(settings.liveActivityQuotaRules.isEmpty)
        XCTAssertTrue(settings.missingQuotaHistoryBehaviors.isEmpty)
    }

    func testAccountResetNotificationSettingRoundTripsDisabled() throws {
        let original = AccountMonitorSettings(notifyAboutResets: false)
        let decoded = try JSONDecoder().decode(
            AccountMonitorSettings.self,
            from: JSONEncoder().encode(original)
        )
        XCTAssertFalse(decoded.notifyAboutResets)
        XCTAssertTrue(decoded.notifyAtScheduledReset)
    }

    func testMissingQuotaHistoryBehaviorRoundTripsPerMetric() throws {
        let original = AccountMonitorSettings(
            missingQuotaHistoryBehaviors: [
                "five_hour": .recordAsFull,
                "monthly": .omit
            ]
        )
        let decoded = try JSONDecoder().decode(
            AccountMonitorSettings.self,
            from: JSONEncoder().encode(original)
        )

        XCTAssertEqual(decoded.missingQuotaHistoryBehavior(for: "five_hour"), .recordAsFull)
        XCTAssertEqual(decoded.missingQuotaHistoryBehavior(for: "monthly"), .omit)
        XCTAssertEqual(decoded.missingQuotaHistoryBehavior(for: "unconfigured"), .omit)
    }

    func testGlobalNotificationSettingsDefaultToUnexpectedResetAlertsEnabled() throws {
        let decoded = try JSONDecoder().decode(
            GlobalNotificationSettings.self,
            from: Data("{}".utf8)
        )

        XCTAssertTrue(decoded.notifyAboutUnexpectedResets)
        XCTAssertFalse(decoded.notifyAtScheduledReset)
        XCTAssertTrue(decoded.allows(.probableEarlyReset))
        XCTAssertTrue(decoded.allows(.probableEarlyWeeklyReset))
    }

    func testGlobalNotificationSettingsOnlyGateUnexpectedResetAlerts() throws {
        let settings = GlobalNotificationSettings(notifyAboutUnexpectedResets: false)
        let decoded = try JSONDecoder().decode(
            GlobalNotificationSettings.self,
            from: JSONEncoder().encode(settings)
        )

        XCTAssertFalse(decoded.allows(.probableEarlyReset))
        XCTAssertFalse(decoded.allows(.probableEarlyWeeklyReset))
        XCTAssertTrue(decoded.allows(.quotaReset))
        XCTAssertTrue(decoded.allows(.newBankedReset))
    }

    func testGlobalScheduledResetNotificationSettingRoundTripsEnabled() throws {
        let settings = GlobalNotificationSettings(notifyAtScheduledReset: true)
        let decoded = try JSONDecoder().decode(
            GlobalNotificationSettings.self,
            from: JSONEncoder().encode(settings)
        )

        XCTAssertTrue(decoded.notifyAtScheduledReset)
    }

    func testScheduledResetNotificationPlannerRequiresGlobalAndAccountOptIn() {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let account = MonitoredAccount(
            id: UUID(), providerID: .claude, displayName: "Claude Work",
            workspaceID: "workspace", plan: "Max", addedAt: now
        )
        let weekly = UsageWindow(
            title: "Weekly", usedPercent: 30,
            resetsAt: now.addingTimeInterval(3_600), windowMinutes: 10_080,
            kind: .weekly
        )
        let snapshot = UsageSnapshot(
            accountID: account.id, providerName: "Claude", accountName: account.displayName,
            plan: account.plan, primary: weekly, secondary: nil,
            availableResetCount: 0, resetCredits: [], fetchedAt: now
        )
        let snapshots = [account.id: snapshot]

        XCTAssertTrue(ScheduledResetNotificationPlanner.targets(
            accounts: [account], snapshots: snapshots, monitorSettings: [:],
            globalSettings: .init(), now: now
        ).isEmpty)
        XCTAssertTrue(ScheduledResetNotificationPlanner.targets(
            accounts: [account], snapshots: snapshots,
            monitorSettings: [account.id: .init(notifyAtScheduledReset: false)],
            globalSettings: .init(notifyAtScheduledReset: true), now: now
        ).isEmpty)

        let targets = ScheduledResetNotificationPlanner.targets(
            accounts: [account], snapshots: snapshots, monitorSettings: [:],
            globalSettings: .init(notifyAtScheduledReset: true), now: now
        )
        XCTAssertEqual(targets.count, 1)
        XCTAssertEqual(targets[0].accountID, account.id)
        XCTAssertEqual(targets[0].metricID, weekly.metricID)
        XCTAssertEqual(targets[0].metricTitle, "Weekly limit")
        XCTAssertEqual(targets[0].fireDate, weekly.resetsAt)
        XCTAssertTrue(targets[0].identifier.hasPrefix(ScheduledResetNotificationTarget.identifierPrefix))
    }

    func testScheduledResetNotificationPlannerSortsNearestAndDropsPastTargets() {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let account = MonitoredAccount(
            id: UUID(), providerID: .chatGPT, displayName: "ChatGPT Personal",
            workspaceID: "workspace", plan: "Plus", addedAt: now
        )
        let later = UsageWindow(
            title: "Weekly", usedPercent: 10,
            resetsAt: now.addingTimeInterval(7_200), windowMinutes: 10_080,
            kind: .weekly
        )
        let sooner = UsageWindow(
            title: "5-hour", usedPercent: 20,
            resetsAt: now.addingTimeInterval(1_800), windowMinutes: 300,
            kind: .fiveHour
        )
        let past = UsageWindow(
            title: "Past", usedPercent: 100,
            resetsAt: now.addingTimeInterval(-60), windowMinutes: 60,
            kind: .additional, identifier: "past"
        )
        let snapshot = UsageSnapshot(
            accountID: account.id, providerName: "ChatGPT", accountName: account.displayName,
            plan: account.plan, primary: later, secondary: sooner,
            availableResetCount: 0, resetCredits: [], fetchedAt: now,
            extraWindows: [past]
        )

        let targets = ScheduledResetNotificationPlanner.targets(
            accounts: [account], snapshots: [account.id: snapshot], monitorSettings: [:],
            globalSettings: .init(notifyAtScheduledReset: true), now: now
        )
        XCTAssertEqual(targets.map(\.metricID), [sooner.metricID, later.metricID])
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

    func testRefreshSettingsRoundTripAndLegacyDefaults() throws {
        let settings = GlobalRefreshSettings(
            inAppInterval: .fiveMinutes,
            backgroundInterval: .twoHours
        )
        let decoded = try JSONDecoder().decode(
            GlobalRefreshSettings.self,
            from: JSONEncoder().encode(settings)
        )
        let defaults = try JSONDecoder().decode(
            GlobalRefreshSettings.self,
            from: Data("{}".utf8)
        )

        XCTAssertEqual(decoded, settings)
        XCTAssertEqual(defaults.inAppInterval, .off)
        XCTAssertEqual(defaults.backgroundInterval, .fifteenMinutes)
        XCTAssertNil(RefreshInterval.off.timeInterval)
        XCTAssertEqual(RefreshInterval.twoHours.timeInterval, 7_200)
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

    func testClaudeProfileUsesReportedIdentityPlanAndSeparateTrialExpiry() throws {
        let profile = Data(#"""
        {
          "account": {
            "uuid": "account-pro",
            "email": "pro@example.com",
            "display_name": "Pro User"
          },
          "organization": {
            "uuid": "org-pro",
            "organization_type": "claude_pro",
            "rate_limit_tier": "default_claude_pro",
            "cc_onboarding_flags": {"e10": true},
            "claude_code_trial_ends_at": "2030-07-25T12:34:56.000Z",
            "claude_code_trial_duration_days": 14,
            "subscription_created_at": "2026-01-10T00:00:00.000Z"
          }
        }
        """#.utf8)

        let details = try ClaudeProvider.parseAccountDetails(profileData: profile)

        XCTAssertEqual(details.profileName, "Pro User")
        XCTAssertEqual(details.displayName, "Pro User")
        XCTAssertEqual(details.email, "pro@example.com")
        XCTAssertEqual(details.plan, "Claude Pro")
        XCTAssertNil(details.planExpiresAt)
        XCTAssertEqual(details.trialExpiresAt,
                       ISO8601DateFormatter().date(from: "2030-07-25T12:34:56Z"))
        XCTAssertTrue(details.replacesMissingFields)
    }

    func testClaudeMax20xProfileDoesNotInventPlanExpiry() throws {
        let profile = Data(#"""
        {
          "account": {"uuid":"account-max","email":"max@example.com"},
          "organization": {
            "uuid":"org-max",
            "organization_type":"claude_max",
            "rate_limit_tier":"default_claude_max_20x"
          }
        }
        """#.utf8)

        let details = try ClaudeProvider.parseAccountDetails(profileData: profile)

        XCTAssertEqual(details.displayName, "max@example.com")
        XCTAssertNil(details.profileName)
        XCTAssertEqual(details.plan, "Claude Max 20x")
        XCTAssertNil(details.planExpiresAt)
        XCTAssertNil(details.trialExpiresAt)
    }

    func testChatGPTWorkspaceIsReadFromNamespacedAuthClaim() throws {
        let payload: [String: Any] = [
            "exp": 2_000_000_000,
            "email": "person@example.com",
            "https://api.openai.com/profile": [
                "name": "Profile Person",
                "email": "profile@example.com"
            ],
            "https://api.openai.com/auth": [
                "chatgpt_account_id": "account-123",
                "chatgpt_plan_type": "pro_20x",
                "chatgpt_subscription_active_until": "2030-01-01T00:00:00Z"
            ]
        ]
        let data = try JSONSerialization.data(withJSONObject: payload)
        let encoded = data.base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        let identity = try ChatGPTProvider().linkedIdentity(accessToken: "access", refreshToken: "refresh", idToken: "header.\(encoded).signature")
        XCTAssertEqual(identity.workspaceID, "account-123")
        XCTAssertEqual(identity.plan, "pro_20x")
        XCTAssertEqual(identity.displayName, "Profile Person")
        XCTAssertEqual(identity.profileName, "Profile Person")
        XCTAssertEqual(identity.email, "person@example.com")
        XCTAssertEqual(identity.planExpiresAt, ISO8601DateFormatter().date(from: "2030-01-01T00:00:00Z"))
        XCTAssertEqual(identity.credentials.expiresAt, Date(timeIntervalSince1970: 2_000_000_000))
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
        XCTAssertEqual(keychainStatus(service: KeychainStore.credentialsService, id: id,
                                      synchronizable: true), errSecSuccess)
        XCTAssertEqual(keychainStatus(service: KeychainStore.credentialsService, id: id,
                                      synchronizable: false), errSecItemNotFound)
    }

    func testLegacyDeviceOnlyCredentialsMigrateToICloudKeychain() throws {
        let id = UUID()
        let credentials = AccountCredentials(accessToken: "legacy-access", refreshToken: "legacy-refresh",
                                             idToken: "legacy-id")
        let data = try JSONEncoder().encode(credentials)
        KeychainStore.delete(for: id)
        defer { KeychainStore.delete(for: id) }

        let legacyItem: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: KeychainStore.credentialsService,
            kSecAttrAccount as String: id.uuidString,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]
        XCTAssertEqual(SecItemAdd(legacyItem as CFDictionary, nil), errSecSuccess)

        XCTAssertEqual(try KeychainStore.load(for: id), credentials)
        XCTAssertEqual(keychainStatus(service: KeychainStore.credentialsService, id: id,
                                      synchronizable: true), errSecSuccess)
        XCTAssertEqual(keychainStatus(service: KeychainStore.credentialsService, id: id,
                                      synchronizable: false), errSecItemNotFound)
    }

    func testAccountMetadataRoundTripsThroughICloudKeychain() throws {
        let account = MonitoredAccount(
            id: UUID(), providerID: .claude, displayName: "Synced account",
            workspaceID: "workspace-synced", plan: "Max", addedAt: Date(timeIntervalSince1970: 2_000),
            customDisplayName: "My Claude", email: "sync@example.com"
        )
        defer { KeychainStore.deleteAccount(for: account.id) }

        try KeychainStore.saveAccount(account)
        XCTAssertEqual(try KeychainStore.loadAccounts().first(where: { $0.id == account.id }), account)
        XCTAssertEqual(keychainStatus(service: KeychainStore.accountsService, id: account.id,
                                      synchronizable: true), errSecSuccess)

        KeychainStore.deleteAccount(for: account.id)
        XCTAssertNil(try KeychainStore.loadAccounts().first(where: { $0.id == account.id }))
    }

    private func keychainStatus(service: String, id: UUID, synchronizable: Bool) -> OSStatus {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: id.uuidString,
            kSecAttrSynchronizable as String: synchronizable,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: CFTypeRef?
        return SecItemCopyMatching(query as CFDictionary, &result)
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

final class UsageHistoryTests: XCTestCase {
    func testHistoryRecordsEveryMetricAndWeeklyRemainingTime() async throws {
        let store = try makeStore()
        let observedAt = Date(timeIntervalSince1970: 2_000_000_000)
        let account = makeAccount(provider: .claude)
        let snapshot = UsageSnapshot(
            accountID: account.id,
            providerName: "Claude",
            accountName: "Work",
            accountProviderID: .claude,
            plan: "Max",
            primary: UsageWindow(title: "Session", usedPercent: 30,
                                 resetsAt: observedAt.addingTimeInterval(3_600), windowMinutes: 300,
                                 kind: .fiveHour, identifier: "five_hour"),
            secondary: UsageWindow(title: "Weekly", usedPercent: 20,
                                   resetsAt: observedAt.addingTimeInterval(6 * 86_400 + 1_234),
                                   windowMinutes: 10_080, kind: .weekly, identifier: "weekly"),
            availableResetCount: 0,
            resetCredits: [],
            fetchedAt: observedAt,
            extraWindows: [
                UsageWindow(title: "Extra", usedPercent: 55,
                            resetsAt: observedAt.addingTimeInterval(10_000), windowMinutes: 60,
                            kind: .additional, identifier: "extra")
            ]
        )

        let first = try await store.record(snapshot: snapshot, account: account,
                                           source: .background, now: observedAt)
        XCTAssertEqual(first.points.count, 3)
        XCTAssertTrue(first.points.allSatisfy { $0.source == .background })
        XCTAssertTrue(first.points.allSatisfy { $0.plan == "Max" })
        let weekly = try XCTUnwrap(first.points.first(where: { $0.metricID == "weekly" }))
        XCTAssertEqual(weekly.remainingPercent, 80)
        XCTAssertEqual(weekly.secondsUntilReset, 6 * 86_400 + 1_234, accuracy: 0.001)

        let duplicate = try await store.record(snapshot: snapshot, account: account,
                                               source: .manual, now: observedAt)
        XCTAssertEqual(duplicate.points.count, 3)
    }

    func testHistoryRetainsThirtyDaysAndPrunesBeyondThirtyFive() async throws {
        let store = try makeStore()
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let account = makeAccount(provider: .kimi)

        for ageInDays in [36.0, 30.0, 0.0] {
            let observedAt = now.addingTimeInterval(-ageInDays * 86_400)
            let snapshot = makeSnapshot(account: account, at: observedAt,
                                        weeklyRemaining: 70 - ageInDays / 2,
                                        weeklyResetAt: observedAt.addingTimeInterval(4 * 86_400))
            _ = try await store.record(snapshot: snapshot, account: account,
                                       source: .background, now: now)
        }

        let loaded = try await store.load(now: now)
        XCTAssertEqual(loaded.points.map(\.recordedAt), [
            now.addingTimeInterval(-30 * 86_400), now
        ])
        XCTAssertTrue(loaded.points.allSatisfy {
            $0.recordedAt >= now.addingTimeInterval(-UsageHistoryStore.retentionInterval)
        })
    }

    func testHistoryFallsBackToAccountPlanWhenSnapshotOmitsPlan() async throws {
        let store = try makeStore()
        let observedAt = Date(timeIntervalSince1970: 2_000_000_000)
        let account = makeAccount(provider: .miniMax)
        var snapshot = makeSnapshot(account: account, at: observedAt, weeklyRemaining: 50,
                                    weeklyResetAt: observedAt.addingTimeInterval(5 * 86_400))
        snapshot.plan = nil

        let result = try await store.record(snapshot: snapshot, account: account,
                                            source: .background, now: observedAt)
        XCTAssertEqual(result.points.map(\.plan), ["Pro"])
    }

    func testConfiguredMissingQuotaRecordsOneHundredPercentWithoutResetAlert() async throws {
        let store = try makeStore()
        let start = Date(timeIntervalSince1970: 2_000_000_000)
        let account = makeAccount(provider: .claude)
        let weeklyReset = start.addingTimeInterval(5 * 86_400)
        let baseline = UsageSnapshot(
            accountID: account.id, providerName: "Claude", accountName: "Work",
            accountProviderID: .claude, plan: "Max",
            primary: UsageWindow(
                title: "Session", usedPercent: 60,
                resetsAt: start.addingTimeInterval(4 * 3_600), windowMinutes: 300,
                kind: .fiveHour, identifier: "five_hour"
            ),
            secondary: UsageWindow(
                title: "Weekly", usedPercent: 20,
                resetsAt: weeklyReset, windowMinutes: 10_080,
                kind: .weekly, identifier: "weekly"
            ),
            availableResetCount: 0, resetCredits: [], fetchedAt: start,
            extraWindows: [
                UsageWindow(
                    title: "Extra", usedPercent: 50,
                    resetsAt: start.addingTimeInterval(8 * 3_600), windowMinutes: 480,
                    kind: .additional, identifier: "extra"
                )
            ]
        )
        _ = try await store.record(snapshot: baseline, account: account,
                                   source: .background, now: start)

        let observedAt = start.addingTimeInterval(30 * 60)
        let weeklyOnly = makeSnapshot(
            account: account, at: observedAt, weeklyRemaining: 80,
            weeklyResetAt: weeklyReset
        )
        let accountSettings = AccountMonitorSettings(
            missingQuotaHistoryBehaviors: ["five_hour": .recordAsFull]
        )
        let result = try await store.record(
            snapshot: weeklyOnly, account: account, source: .background,
            accountSettings: accountSettings, now: observedAt
        )

        let pointsAtRefresh = result.points.filter { $0.recordedAt == observedAt }
        XCTAssertEqual(Set(pointsAtRefresh.map(\.metricID)), ["five_hour", "weekly"])
        let inferredFiveHour = try XCTUnwrap(pointsAtRefresh.first { $0.metricID == "five_hour" })
        XCTAssertEqual(inferredFiveHour.remainingPercent, 100)
        XCTAssertTrue(inferredFiveHour.representsSyntheticMissingQuota)
        XCTAssertEqual(inferredFiveHour.plan, "Pro")
        XCTAssertFalse(pointsAtRefresh.contains { $0.metricID == "extra" })
        XCTAssertTrue(result.pendingNotifications.isEmpty)
    }

    func testMissingQuotaIsOmittedByDefaultAndNeverInventedBeforeFirstObservation() async throws {
        let store = try makeStore()
        let start = Date(timeIntervalSince1970: 2_000_000_000)
        let account = makeAccount(provider: .claude)
        let weeklyReset = start.addingTimeInterval(5 * 86_400)
        let baseline = UsageSnapshot(
            accountID: account.id, providerName: "Claude", accountName: "Work",
            accountProviderID: .claude, plan: "Max",
            primary: UsageWindow(
                title: "Session", usedPercent: 60,
                resetsAt: start.addingTimeInterval(4 * 3_600), windowMinutes: 300,
                kind: .fiveHour, identifier: "five_hour"
            ),
            secondary: UsageWindow(
                title: "Weekly", usedPercent: 20,
                resetsAt: weeklyReset, windowMinutes: 10_080,
                kind: .weekly, identifier: "weekly"
            ),
            availableResetCount: 0, resetCredits: [], fetchedAt: start
        )
        _ = try await store.record(snapshot: baseline, account: account,
                                   source: .background, now: start)

        let observedAt = start.addingTimeInterval(30 * 60)
        let weeklyOnly = makeSnapshot(
            account: account, at: observedAt, weeklyRemaining: 80,
            weeklyResetAt: weeklyReset
        )
        let omitted = try await store.record(
            snapshot: weeklyOnly, account: account, source: .background,
            now: observedAt
        )
        XCTAssertEqual(omitted.points.filter { $0.recordedAt == observedAt }.map(\.metricID), ["weekly"])

        let neverObservedAccount = makeAccount(provider: .kimi)
        let neverObservedSnapshot = makeSnapshot(
            account: neverObservedAccount, at: observedAt, weeklyRemaining: 100,
            weeklyResetAt: weeklyReset
        )
        let configured = AccountMonitorSettings(
            missingQuotaHistoryBehaviors: ["five_hour": .recordAsFull]
        )
        let neverInvented = try await store.record(
            snapshot: neverObservedSnapshot, account: neverObservedAccount,
            source: .background, accountSettings: configured, now: observedAt
        )
        XCTAssertFalse(neverInvented.points.contains {
            $0.accountID == neverObservedAccount.id && $0.metricID == "five_hour"
        })
    }

    func testReappearingMissingQuotaStartsFreshResetBaseline() async throws {
        let store = try makeStore()
        let start = Date(timeIntervalSince1970: 2_000_000_000)
        let account = makeAccount(provider: .claude)
        let weeklyReset = start.addingTimeInterval(5 * 86_400)
        let fiveHourReset = start.addingTimeInterval(4 * 3_600)
        let baseline = UsageSnapshot(
            accountID: account.id, providerName: "Claude", accountName: "Work",
            accountProviderID: .claude, plan: "Max",
            primary: UsageWindow(
                title: "Session", usedPercent: 80,
                resetsAt: fiveHourReset, windowMinutes: 300,
                kind: .fiveHour, identifier: "five_hour"
            ),
            secondary: UsageWindow(
                title: "Weekly", usedPercent: 20,
                resetsAt: weeklyReset, windowMinutes: 10_080,
                kind: .weekly, identifier: "weekly"
            ),
            availableResetCount: 0, resetCredits: [], fetchedAt: start
        )
        _ = try await store.record(snapshot: baseline, account: account,
                                   source: .background, now: start)

        let missingAt = start.addingTimeInterval(30 * 60)
        let settings = AccountMonitorSettings(
            missingQuotaHistoryBehaviors: ["five_hour": .recordAsFull]
        )
        _ = try await store.record(
            snapshot: makeSnapshot(
                account: account, at: missingAt, weeklyRemaining: 80,
                weeklyResetAt: weeklyReset
            ),
            account: account, source: .background,
            accountSettings: settings, now: missingAt
        )

        let returnedAt = start.addingTimeInterval(60 * 60)
        let returned = UsageSnapshot(
            accountID: account.id, providerName: "Claude", accountName: "Work",
            accountProviderID: .claude, plan: "Max",
            primary: UsageWindow(
                title: "Session", usedPercent: 0,
                resetsAt: returnedAt.addingTimeInterval(5 * 3_600), windowMinutes: 300,
                kind: .fiveHour, identifier: "five_hour"
            ),
            secondary: UsageWindow(
                title: "Weekly", usedPercent: 20,
                resetsAt: weeklyReset, windowMinutes: 10_080,
                kind: .weekly, identifier: "weekly"
            ),
            availableResetCount: 0, resetCredits: [], fetchedAt: returnedAt
        )
        let result = try await store.record(
            snapshot: returned, account: account, source: .background,
            accountSettings: settings, now: returnedAt
        )

        XCTAssertFalse(result.pendingNotifications.contains { $0.kind == .probableEarlyReset })
        let returnedPoint = try XCTUnwrap(result.points.last {
            $0.metricID == "five_hour" && $0.recordedAt == returnedAt
        })
        XCTAssertEqual(returnedPoint.remainingPercent, 100)
        XCTAssertFalse(returnedPoint.representsSyntheticMissingQuota)
    }

    func testConfiguredMissingWeeklyQuotaCanRecordOneHundredPercent() async throws {
        let store = try makeStore()
        let start = Date(timeIntervalSince1970: 2_000_000_000)
        let account = makeAccount(provider: .claude)
        let weeklyReset = start.addingTimeInterval(5 * 86_400)
        let baseline = makeSnapshot(
            account: account, at: start, weeklyRemaining: 30,
            weeklyResetAt: weeklyReset
        )
        _ = try await store.record(snapshot: baseline, account: account,
                                   source: .background, now: start)

        let missingAt = start.addingTimeInterval(30 * 60)
        var missing = baseline
        missing.secondary = nil
        missing.fetchedAt = missingAt
        let result = try await store.record(
            snapshot: missing, account: account, source: .background,
            accountSettings: .init(
                missingQuotaHistoryBehaviors: ["weekly": .recordAsFull]
            ),
            now: missingAt
        )

        let synthetic = try XCTUnwrap(result.points.last {
            $0.metricID == "weekly" && $0.recordedAt == missingAt
        })
        XCTAssertEqual(synthetic.remainingPercent, 100)
        XCTAssertTrue(synthetic.representsSyntheticMissingQuota)
        XCTAssertTrue(result.pendingNotifications.isEmpty)
    }

    func testDuplicateProviderMetricIDsAreDeduplicated() async throws {
        let store = try makeStore()
        let observedAt = Date(timeIntervalSince1970: 2_000_000_000)
        let account = makeAccount(provider: .claude)
        let duplicateID = "same-metric"
        let snapshot = UsageSnapshot(
            accountID: account.id, providerName: "Claude", accountName: "Work",
            accountProviderID: .claude, plan: "Pro",
            primary: UsageWindow(title: "First", usedPercent: 60,
                                 resetsAt: observedAt.addingTimeInterval(3_600),
                                 windowMinutes: 300, identifier: duplicateID),
            secondary: nil, availableResetCount: 0, resetCredits: [], fetchedAt: observedAt,
            extraWindows: [
                UsageWindow(title: "Replacement", usedPercent: 40,
                            resetsAt: observedAt.addingTimeInterval(7_200),
                            windowMinutes: 300, identifier: duplicateID)
            ]
        )

        let result = try await store.record(snapshot: snapshot, account: account,
                                            source: .background, now: observedAt)
        XCTAssertEqual(result.points.count, 1)
        XCTAssertEqual(result.points.first?.remainingPercent, 60)
        XCTAssertEqual(result.points.first?.secondsUntilReset, 7_200)
    }

    func testDuplicateBankedCreditIDsDoNotCrashOrDoubleCount() async throws {
        let store = try makeStore()
        let observedAt = Date(timeIntervalSince1970: 2_000_000_000)
        let account = makeAccount(provider: .chatGPT)
        let duplicateCredits = [
            ResetCredit(id: "same-credit", expiresAt: observedAt.addingTimeInterval(5 * 86_400),
                        status: "available"),
            ResetCredit(id: "same-credit", expiresAt: observedAt.addingTimeInterval(10 * 86_400),
                        status: "available")
        ]
        let snapshot = makeSnapshot(account: account, at: observedAt, weeklyRemaining: 50,
                                    weeklyResetAt: observedAt.addingTimeInterval(5 * 86_400),
                                    credits: duplicateCredits)

        let result = try await store.record(snapshot: snapshot, account: account,
                                            source: .background, now: observedAt)
        XCTAssertTrue(result.pendingNotifications.isEmpty)
    }

    func testSchemaOneArchiveIsPersistentlyUpgraded() async throws {
        let fileURL = try makeStoreFileURL()
        let observedAt = Date(timeIntervalSince1970: 2_000_000_000)
        let account = makeAccount(provider: .claude)
        let snapshot = makeSnapshot(account: account, at: observedAt, weeklyRemaining: 50,
                                    weeklyResetAt: observedAt.addingTimeInterval(5 * 86_400))
        _ = try await UsageHistoryStore(fileURL: fileURL).record(
            snapshot: snapshot, account: account, source: .background, now: observedAt
        )

        var legacy = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(contentsOf: fileURL)) as? [String: Any]
        )
        legacy["schemaVersion"] = 1
        try JSONSerialization.data(withJSONObject: legacy).write(to: fileURL, options: .atomic)

        _ = try await UsageHistoryStore(fileURL: fileURL).load(now: observedAt)
        let upgraded = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(contentsOf: fileURL)) as? [String: Any]
        )
        XCTAssertEqual((upgraded["schemaVersion"] as? NSNumber)?.intValue, 2)
    }

    func testStaleDetectorObservationBecomesANewBaseline() async throws {
        let store = try makeStore()
        let start = Date(timeIntervalSince1970: 2_000_000_000)
        let account = makeAccount(provider: .claude)
        let baseline = makeSnapshot(account: account, at: start, weeklyRemaining: 10,
                                    weeklyResetAt: start.addingTimeInterval(2 * 86_400))
        _ = try await store.record(snapshot: baseline, account: account,
                                   source: .background, now: start)

        let observedAt = start.addingTimeInterval(40 * 86_400)
        let current = makeSnapshot(account: account, at: observedAt, weeklyRemaining: 100,
                                   weeklyResetAt: observedAt.addingTimeInterval(7 * 86_400))
        let result = try await store.record(snapshot: current, account: account,
                                            source: .background, now: observedAt)
        XCTAssertTrue(result.pendingNotifications.isEmpty)
    }

    func testEarlyWeeklyRecoveryWithConsumedCreditNotifiesOnce() async throws {
        let store = try makeStore()
        let start = Date(timeIntervalSince1970: 2_000_000_000)
        let account = makeAccount(provider: .chatGPT)
        let oldCredit = ResetCredit(id: "credit-old", expiresAt: start.addingTimeInterval(10 * 86_400),
                                    status: "available", grantedAt: start.addingTimeInterval(-86_400))
        let baseline = makeSnapshot(account: account, at: start, weeklyRemaining: 20,
                                    weeklyResetAt: start.addingTimeInterval(4 * 86_400),
                                    credits: [oldCredit])
        let baselineResult = try await store.record(snapshot: baseline, account: account,
                                                    source: .background, now: start)
        XCTAssertTrue(baselineResult.pendingNotifications.isEmpty)

        let recoveredAt = start.addingTimeInterval(3_600)
        let recovered = makeSnapshot(account: account, at: recoveredAt, weeklyRemaining: 100,
                                     weeklyResetAt: recoveredAt.addingTimeInterval(7 * 86_400))
        let result = try await store.record(snapshot: recovered, account: account,
                                            source: .background, now: recoveredAt)
        let event = try XCTUnwrap(result.pendingNotifications.first)
        XCTAssertEqual(event.kind, .probableEarlyWeeklyReset)
        XCTAssertTrue(event.body.contains("20% to 100%"))

        try await store.markNotificationsDelivered([event.id], now: recoveredAt)
        let later = makeSnapshot(account: account, at: recoveredAt.addingTimeInterval(600),
                                 weeklyRemaining: 99,
                                 weeklyResetAt: recoveredAt.addingTimeInterval(7 * 86_400))
        let repeated = try await store.record(snapshot: later, account: account,
                                              source: .background,
                                              now: recoveredAt.addingTimeInterval(600))
        XCTAssertTrue(repeated.pendingNotifications.isEmpty)
    }

    func testChatGPTEarlyWeeklyRecoveryWithoutCreditDetailsStillNotifies() async throws {
        let store = try makeStore()
        let start = Date(timeIntervalSince1970: 2_000_000_000)
        let account = makeAccount(provider: .chatGPT)
        let baseline = makeSnapshot(account: account, at: start, weeklyRemaining: 20,
                                    weeklyResetAt: start.addingTimeInterval(4 * 86_400))
        _ = try await store.record(snapshot: baseline, account: account,
                                   source: .background, now: start)

        let observedAt = start.addingTimeInterval(60 * 60)
        let recovered = makeSnapshot(account: account, at: observedAt, weeklyRemaining: 80,
                                     weeklyResetAt: observedAt.addingTimeInterval(7 * 86_400))
        let result = try await store.record(snapshot: recovered, account: account,
                                            source: .background, now: observedAt)
        XCTAssertEqual(result.pendingNotifications.filter {
            $0.kind == .probableEarlyWeeklyReset
        }.count, 1)
        XCTAssertFalse(result.pendingNotifications.contains { $0.kind == .probableEarlyReset })
    }

    func testScheduledWeeklyRolloverDoesNotNotify() async throws {
        let store = try makeStore()
        let start = Date(timeIntervalSince1970: 2_000_000_000)
        let account = makeAccount(provider: .chatGPT)
        let credit = ResetCredit(id: "credit", expiresAt: start.addingTimeInterval(5 * 86_400),
                                 status: "available")
        let baseline = makeSnapshot(account: account, at: start, weeklyRemaining: 10,
                                    weeklyResetAt: start.addingTimeInterval(30 * 60), credits: [credit])
        _ = try await store.record(snapshot: baseline, account: account,
                                   source: .background, now: start)

        let afterReset = start.addingTimeInterval(60 * 60)
        let rolledOver = makeSnapshot(account: account, at: afterReset, weeklyRemaining: 100,
                                      weeklyResetAt: afterReset.addingTimeInterval(7 * 86_400))
        let result = try await store.record(snapshot: rolledOver, account: account,
                                            source: .background, now: afterReset)
        XCTAssertFalse(result.pendingNotifications.contains { $0.kind == .probableEarlyWeeklyReset })
    }

    func testClaudeScheduledResetNotifies() async throws {
        let store = try makeStore()
        let start = Date(timeIntervalSince1970: 2_000_000_000)
        let account = makeAccount(provider: .claude)
        let baseline = makeSnapshot(account: account, at: start, weeklyRemaining: 10,
                                    weeklyResetAt: start.addingTimeInterval(30 * 60))
        _ = try await store.record(snapshot: baseline, account: account,
                                   source: .background, now: start)

        let observedAt = start.addingTimeInterval(60 * 60)
        let reset = makeSnapshot(account: account, at: observedAt, weeklyRemaining: 100,
                                 weeklyResetAt: observedAt.addingTimeInterval(7 * 86_400))
        let result = try await store.record(snapshot: reset, account: account,
                                            source: .background, now: observedAt)

        let events = result.pendingNotifications.filter { $0.kind == .quotaReset }
        XCTAssertEqual(events.count, 1)
        XCTAssertTrue(try XCTUnwrap(events.first).title.contains("Weekly"))
    }

    func testUnusedQuotaCycleAdvanceStillNotifies() async throws {
        let store = try makeStore()
        let start = Date(timeIntervalSince1970: 2_000_000_000)
        let account = makeAccount(provider: .claude)
        let baseline = makeSnapshot(account: account, at: start, weeklyRemaining: 100,
                                    weeklyResetAt: start.addingTimeInterval(30 * 60))
        _ = try await store.record(snapshot: baseline, account: account,
                                   source: .background, now: start)

        let observedAt = start.addingTimeInterval(60 * 60)
        let reset = makeSnapshot(account: account, at: observedAt, weeklyRemaining: 100,
                                 weeklyResetAt: observedAt.addingTimeInterval(7 * 86_400))
        let result = try await store.record(snapshot: reset, account: account,
                                            source: .background, now: observedAt)
        XCTAssertEqual(result.pendingNotifications.filter { $0.kind == .quotaReset }.count, 1)
    }

    func testClaudeProbableEarlyResetNotifies() async throws {
        let store = try makeStore()
        let start = Date(timeIntervalSince1970: 2_000_000_000)
        let account = makeAccount(provider: .claude)
        let baseline = makeSnapshot(account: account, at: start, weeklyRemaining: 20,
                                    weeklyResetAt: start.addingTimeInterval(4 * 86_400))
        _ = try await store.record(snapshot: baseline, account: account,
                                   source: .background, now: start)

        let observedAt = start.addingTimeInterval(60 * 60)
        let reset = makeSnapshot(account: account, at: observedAt, weeklyRemaining: 80,
                                 weeklyResetAt: observedAt.addingTimeInterval(7 * 86_400))
        let result = try await store.record(snapshot: reset, account: account,
                                            source: .background, now: observedAt)

        let event = try XCTUnwrap(result.pendingNotifications.first {
            $0.kind == .probableEarlyReset
        })
        XCTAssertTrue(event.body.contains("20%→80%"))
    }

    func testProviderMetricsResettingTogetherProduceOneNotification() async throws {
        let store = try makeStore()
        let start = Date(timeIntervalSince1970: 2_000_000_000)
        let account = makeAccount(provider: .githubCopilot)
        let initialReset = start.addingTimeInterval(30 * 60)
        let baseline = UsageSnapshot(
            accountID: account.id, providerName: "GitHub Copilot", accountName: "Work",
            accountProviderID: .githubCopilot, plan: "Pro",
            primary: UsageWindow(title: "Chat", usedPercent: 90, resetsAt: initialReset,
                                 windowMinutes: 1_440, identifier: "chat"),
            secondary: UsageWindow(title: "Premium requests", usedPercent: 80,
                                   resetsAt: initialReset, windowMinutes: 1_440,
                                   identifier: "premium"),
            availableResetCount: 0, resetCredits: [], fetchedAt: start
        )
        _ = try await store.record(snapshot: baseline, account: account,
                                   source: .background, now: start)

        let observedAt = start.addingTimeInterval(60 * 60)
        let nextReset = observedAt.addingTimeInterval(30 * 86_400)
        var reset = baseline
        reset.primary!.usedPercent = 0
        reset.primary!.resetsAt = nextReset
        reset.secondary!.usedPercent = 0
        reset.secondary!.resetsAt = nextReset
        reset.fetchedAt = observedAt
        let result = try await store.record(snapshot: reset, account: account,
                                            source: .background, now: observedAt)

        let events = result.pendingNotifications.filter { $0.kind == .quotaReset }
        XCTAssertEqual(events.count, 1)
        XCTAssertTrue(try XCTUnwrap(events.first).body.contains("Chat 100%"))
        XCTAssertTrue(try XCTUnwrap(events.first).body.contains("Premium requests 100%"))
    }

    func testShortTTLResetTargetJitterDoesNotNotify() async throws {
        let store = try makeStore()
        let start = Date(timeIntervalSince1970: 2_000_000_000)
        let account = makeAccount(provider: .kimi)
        let baseline = makeSnapshot(account: account, at: start, weeklyRemaining: 50,
                                    weeklyResetAt: start.addingTimeInterval(7 * 86_400))
        _ = try await store.record(snapshot: baseline, account: account,
                                   source: .background, now: start)

        let observedAt = start.addingTimeInterval(10 * 60)
        let jittered = makeSnapshot(account: account, at: observedAt, weeklyRemaining: 50,
                                    weeklyResetAt: baseline.secondary!.resetsAt.addingTimeInterval(10 * 60))
        let result = try await store.record(snapshot: jittered, account: account,
                                            source: .background, now: observedAt)
        XCTAssertTrue(result.pendingNotifications.isEmpty)
    }

    func testResetNotificationsCanBeDisabledWithoutReplayingChanges() async throws {
        let store = try makeStore()
        let start = Date(timeIntervalSince1970: 2_000_000_000)
        let account = makeAccount(provider: .claude)
        let baseline = makeSnapshot(account: account, at: start, weeklyRemaining: 10,
                                    weeklyResetAt: start.addingTimeInterval(30 * 60))
        _ = try await store.record(snapshot: baseline, account: account,
                                   source: .background, notificationsEnabled: false, now: start)

        let firstResetAt = start.addingTimeInterval(60 * 60)
        let firstReset = makeSnapshot(account: account, at: firstResetAt, weeklyRemaining: 100,
                                      weeklyResetAt: firstResetAt.addingTimeInterval(7 * 86_400))
        let disabled = try await store.record(snapshot: firstReset, account: account,
                                              source: .background, notificationsEnabled: false,
                                              now: firstResetAt)
        XCTAssertTrue(disabled.pendingNotifications.isEmpty)

        var unchanged = firstReset
        unchanged.fetchedAt = firstResetAt.addingTimeInterval(10 * 60)
        let enabled = try await store.record(snapshot: unchanged, account: account,
                                             source: .background, notificationsEnabled: true,
                                             now: unchanged.fetchedAt)
        XCTAssertTrue(enabled.pendingNotifications.isEmpty)

        let secondResetAt = firstReset.secondary!.resetsAt.addingTimeInterval(60 * 60)
        let secondReset = makeSnapshot(account: account, at: secondResetAt, weeklyRemaining: 100,
                                       weeklyResetAt: secondResetAt.addingTimeInterval(7 * 86_400))
        let later = try await store.record(snapshot: secondReset, account: account,
                                           source: .background, notificationsEnabled: true,
                                           now: secondResetAt)
        XCTAssertEqual(later.pendingNotifications.filter { $0.kind == .quotaReset }.count, 1)
    }

    func testChatGPTCountOnlyBankedResetIncreaseNotifies() async throws {
        let store = try makeStore()
        let start = Date(timeIntervalSince1970: 2_000_000_000)
        let account = makeAccount(provider: .chatGPT)
        var baseline = makeSnapshot(account: account, at: start, weeklyRemaining: 50,
                                    weeklyResetAt: start.addingTimeInterval(5 * 86_400))
        baseline.availableResetCount = 2
        _ = try await store.record(snapshot: baseline, account: account,
                                   source: .background, now: start)

        var increased = baseline
        increased.fetchedAt = start.addingTimeInterval(10 * 60)
        increased.availableResetCount = 3
        let result = try await store.record(snapshot: increased, account: account,
                                            source: .background, now: increased.fetchedAt)
        XCTAssertEqual(result.pendingNotifications.filter { $0.kind == .newBankedReset }.count, 1)
        try await store.discardPendingNotifications(accountID: account.id, now: increased.fetchedAt)
        let afterDiscard = try await store.load(now: increased.fetchedAt)
        XCTAssertTrue(afterDiscard.pendingNotifications.isEmpty)
    }

    func testPlanChangeRebaselinesResetDetector() async throws {
        let store = try makeStore()
        let start = Date(timeIntervalSince1970: 2_000_000_000)
        let account = makeAccount(provider: .claude)
        let baseline = makeSnapshot(account: account, at: start, weeklyRemaining: 20,
                                    weeklyResetAt: start.addingTimeInterval(4 * 86_400))
        _ = try await store.record(snapshot: baseline, account: account,
                                   source: .background, now: start)

        let observedAt = start.addingTimeInterval(60 * 60)
        var changedPlan = makeSnapshot(account: account, at: observedAt, weeklyRemaining: 100,
                                       weeklyResetAt: observedAt.addingTimeInterval(7 * 86_400))
        changedPlan.plan = "Team"
        let result = try await store.record(snapshot: changedPlan, account: account,
                                            source: .background, now: observedAt)
        XCTAssertTrue(result.pendingNotifications.isEmpty)
        XCTAssertEqual(result.points.last?.plan, "Team")
    }

    func testPlanCasingChangeDoesNotRebaselineResetDetector() async throws {
        let store = try makeStore()
        let start = Date(timeIntervalSince1970: 2_000_000_000)
        let account = makeAccount(provider: .claude)
        let baseline = makeSnapshot(account: account, at: start, weeklyRemaining: 10,
                                    weeklyResetAt: start.addingTimeInterval(30 * 60))
        _ = try await store.record(snapshot: baseline, account: account,
                                   source: .background, now: start)

        let observedAt = start.addingTimeInterval(60 * 60)
        var reset = makeSnapshot(account: account, at: observedAt, weeklyRemaining: 100,
                                 weeklyResetAt: observedAt.addingTimeInterval(7 * 86_400))
        reset.plan = "pro"
        let result = try await store.record(snapshot: reset, account: account,
                                            source: .background, now: observedAt)
        XCTAssertEqual(result.pendingNotifications.filter { $0.kind == .quotaReset }.count, 1)
    }

    func testNewBankedCreditWithUnchangedCountNotifiesAndDoesNotRepeat() async throws {
        let store = try makeStore()
        let start = Date(timeIntervalSince1970: 2_000_000_000)
        let account = makeAccount(provider: .chatGPT)
        let old = ResetCredit(id: "old", expiresAt: start.addingTimeInterval(10 * 86_400),
                              status: "available")
        let new = ResetCredit(id: "new", expiresAt: start.addingTimeInterval(20 * 86_400),
                              status: "available")
        let baseline = makeSnapshot(account: account, at: start, weeklyRemaining: 60,
                                    weeklyResetAt: start.addingTimeInterval(5 * 86_400), credits: [old])
        _ = try await store.record(snapshot: baseline, account: account,
                                   source: .background, now: start)

        let nextDate = start.addingTimeInterval(3_600)
        let replacement = makeSnapshot(account: account, at: nextDate, weeklyRemaining: 59,
                                       weeklyResetAt: start.addingTimeInterval(5 * 86_400), credits: [new])
        let result = try await store.record(snapshot: replacement, account: account,
                                            source: .background, now: nextDate)
        let event = try XCTUnwrap(result.pendingNotifications.first(where: { $0.kind == .newBankedReset }))
        XCTAssertTrue(event.body.contains("new banked reset"))
        try await store.markNotificationsDelivered([event.id], now: nextDate)

        let againDate = nextDate.addingTimeInterval(600)
        let again = makeSnapshot(account: account, at: againDate, weeklyRemaining: 58,
                                 weeklyResetAt: start.addingTimeInterval(5 * 86_400), credits: [new])
        let repeated = try await store.record(snapshot: again, account: account,
                                              source: .background, now: againDate)
        XCTAssertTrue(repeated.pendingNotifications.isEmpty)
    }

    func testChatGPTCreditWithoutServerIDUsesDeterministicIdentity() throws {
        let account = makeAccount(provider: .chatGPT)
        let usage = try JSONSerialization.data(withJSONObject: [
            "rate_limit": [
                "secondary_window": [
                    "used_percent": 25,
                    "limit_window_seconds": 604_800,
                    "reset_at": 2_100_000_000
                ]
            ]
        ])
        let credits = try JSONSerialization.data(withJSONObject: [
            "available_count": 1,
            "credits": [[
                "status": "available",
                "granted_at": "2030-01-01T00:00:00Z",
                "expires_at": "2030-01-31T00:00:00Z"
            ]]
        ])

        let first = try ChatGPTProvider().parse(account: account, usage: usage, credits: credits)
        let second = try ChatGPTProvider().parse(account: account, usage: usage, credits: credits)
        XCTAssertEqual(first.resetCredits.map(\.id), second.resetCredits.map(\.id))
        XCTAssertTrue(try XCTUnwrap(first.resetCredits.first?.id).hasPrefix("generated:"))
    }

    func testBankedResetAlertStateSurvivesStoreRestart() async throws {
        let fileURL = try makeStoreFileURL()
        let start = Date(timeIntervalSince1970: 2_000_000_000)
        let account = makeAccount(provider: .chatGPT)
        let old = ResetCredit(id: "old", expiresAt: start.addingTimeInterval(10 * 86_400),
                              status: "available")
        let baseline = makeSnapshot(account: account, at: start, weeklyRemaining: 50,
                                    weeklyResetAt: start.addingTimeInterval(5 * 86_400), credits: [old])
        _ = try await UsageHistoryStore(fileURL: fileURL).record(
            snapshot: baseline, account: account, source: .background, now: start
        )

        let nextDate = start.addingTimeInterval(3_600)
        let new = ResetCredit(id: "new", expiresAt: start.addingTimeInterval(20 * 86_400),
                              status: "available")
        let updated = makeSnapshot(account: account, at: nextDate, weeklyRemaining: 49,
                                   weeklyResetAt: start.addingTimeInterval(5 * 86_400), credits: [old, new])
        let restartedStore = UsageHistoryStore(fileURL: fileURL)
        let result = try await restartedStore.record(
            snapshot: updated, account: account, source: .background, now: nextDate
        )
        let event = try XCTUnwrap(result.pendingNotifications.first(where: { $0.kind == .newBankedReset }))
        try await restartedStore.markNotificationsDelivered([event.id], now: nextDate)

        let thirdDate = nextDate.addingTimeInterval(600)
        var repeatedSnapshot = updated
        repeatedSnapshot.fetchedAt = thirdDate
        let afterSecondRestart = try await UsageHistoryStore(fileURL: fileURL).record(
            snapshot: repeatedSnapshot, account: account, source: .background, now: thirdDate
        )
        XCTAssertTrue(afterSecondRestart.pendingNotifications.isEmpty)
    }

    func testCreditDetailsAppearingAfterCountOnlyBaselineDoNotLookNew() async throws {
        let store = try makeStore()
        let start = Date(timeIntervalSince1970: 2_000_000_000)
        let account = makeAccount(provider: .chatGPT)
        var countOnly = makeSnapshot(account: account, at: start, weeklyRemaining: 50,
                                     weeklyResetAt: start.addingTimeInterval(5 * 86_400))
        countOnly.availableResetCount = 2
        _ = try await store.record(snapshot: countOnly, account: account,
                                   source: .background, now: start)

        let nextDate = start.addingTimeInterval(600)
        let credits = [
            ResetCredit(id: "existing-1", expiresAt: start.addingTimeInterval(10 * 86_400),
                        status: "available"),
            ResetCredit(id: "existing-2", expiresAt: start.addingTimeInterval(20 * 86_400),
                        status: "available")
        ]
        let detailed = makeSnapshot(account: account, at: nextDate, weeklyRemaining: 49,
                                    weeklyResetAt: start.addingTimeInterval(5 * 86_400), credits: credits)
        let result = try await store.record(snapshot: detailed, account: account,
                                            source: .background, now: nextDate)
        XCTAssertFalse(result.pendingNotifications.contains { $0.kind == .newBankedReset })
    }

    private func makeStore() throws -> UsageHistoryStore {
        UsageHistoryStore(fileURL: try makeStoreFileURL())
    }

    private func makeStoreFileURL() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("when-reset-history-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory.appendingPathComponent("history.json")
    }

    private func makeAccount(provider: ProviderID) -> MonitoredAccount {
        MonitoredAccount(
            id: UUID(), providerID: provider, displayName: "Work account",
            workspaceID: "workspace", plan: "Pro", addedAt: .now
        )
    }

    private func makeSnapshot(account: MonitoredAccount, at date: Date,
                              weeklyRemaining: Double, weeklyResetAt: Date,
                              credits: [ResetCredit] = []) -> UsageSnapshot {
        UsageSnapshot(
            accountID: account.id,
            providerName: account.providerID.displayName,
            accountName: account.displayName,
            accountProviderID: account.providerID,
            plan: account.plan,
            primary: nil,
            secondary: UsageWindow(
                title: "Weekly limit",
                usedPercent: 100 - weeklyRemaining,
                resetsAt: weeklyResetAt,
                windowMinutes: 10_080,
                kind: .weekly,
                identifier: "weekly"
            ),
            availableResetCount: credits.count,
            resetCredits: credits,
            fetchedAt: date
        )
    }
}
