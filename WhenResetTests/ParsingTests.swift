import Security
import XCTest
@testable import WhenReset

private actor TestAsyncLatch {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        isOpen = true
        let pending = waiters
        waiters.removeAll()
        pending.forEach { $0.resume() }
    }
}

private actor TestEventRecorder {
    private var events: [String] = []

    func append(_ event: String) { events.append(event) }
    func snapshot() -> [String] { events }
}

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

    func testLiveActivityCountdownEmphasizesOnlyPositiveTimesBelowThirtyMinutes() {
        let now = Date(timeIntervalSince1970: 1_000)

        XCTAssertFalse(CountdownDisplay.shouldEmphasizeLiveActivityCountdown(
            until: now.addingTimeInterval(30 * 60 + 1), from: now
        ))
        XCTAssertFalse(CountdownDisplay.shouldEmphasizeLiveActivityCountdown(
            until: now.addingTimeInterval(30 * 60), from: now
        ))
        XCTAssertTrue(CountdownDisplay.shouldEmphasizeLiveActivityCountdown(
            until: now.addingTimeInterval(30 * 60 - 1), from: now
        ))
        XCTAssertTrue(CountdownDisplay.shouldEmphasizeLiveActivityCountdown(
            until: now.addingTimeInterval(1), from: now
        ))
        XCTAssertFalse(CountdownDisplay.shouldEmphasizeLiveActivityCountdown(until: now, from: now))
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
        XCTAssertNil(settings.remoteWorkerAccountID)
        XCTAssertNil(settings.workerAccountReference)
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

    func testRemoteWorkerSourceReferenceRoundTripsInDeviceSettings() throws {
        let remoteReference = String(repeating: "A", count: 43)
        let accountReference = String(repeating: "B", count: 43)
        let original = AccountMonitorSettings(
            monitorOnSelfHostedServer: true,
            selfHostedServerConsentURL: "https://worker.example",
            selfHostedServerConsentRevision: 1,
            remoteWorkerAccountID: remoteReference,
            workerAccountReference: accountReference
        )

        let decoded = try JSONDecoder().decode(
            AccountMonitorSettings.self,
            from: JSONEncoder().encode(original)
        )

        XCTAssertEqual(decoded.remoteWorkerAccountID, remoteReference)
        XCTAssertEqual(decoded.workerAccountReference, accountReference)
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
        XCTAssertEqual(RefreshInterval.serverMonitoringOptions.first, .fiveMinutes)
        XCTAssertFalse(RefreshInterval.backgroundOptions.contains(.fiveMinutes))
    }

    func testPushServerSettingsDecodeDisabledByDefault() throws {
        let settings = try JSONDecoder().decode(
            PushServerSettings.self,
            from: Data("{}".utf8)
        )

        XCTAssertEqual(settings.mode, .disabled)
        XCTAssertEqual(settings.customServerURL, "")
        XCTAssertEqual(settings.serverMonitoringInterval, .tenMinutes)
        XCTAssertEqual(settings.historyRetention, .thirtyFiveDays)
        XCTAssertNil(try settings.resolvedServerURL())
    }

    func testMissingAPNSEntitlementRegistrationFailureIsRecognized() {
        let missingEntitlement = NSError(
            domain: NSCocoaErrorDomain,
            code: 3_000,
            userInfo: [
                NSLocalizedDescriptionKey:
                    "No valid aps-environment entitlement string found for application"
            ]
        )
        let unrelatedFailure = NSError(
            domain: NSURLErrorDomain,
            code: NSURLErrorNotConnectedToInternet
        )

        XCTAssertTrue(
            RemotePushRegistrationFailurePolicy.isMissingAPNSEntitlement(missingEntitlement)
        )
        XCTAssertFalse(
            RemotePushRegistrationFailurePolicy.isMissingAPNSEntitlement(unrelatedFailure)
        )
    }

    func testNotificationsNotAllowedRegistrationFailureIsRecognized() {
        let notificationsDenied = NSError(
            domain: NSCocoaErrorDomain,
            code: 3_010,
            userInfo: [
                NSLocalizedDescriptionKey:
                    "Notifications are not allowed for this application"
            ]
        )
        let unrelatedFailure = NSError(
            domain: NSURLErrorDomain,
            code: NSURLErrorNotConnectedToInternet
        )

        XCTAssertTrue(
            RemotePushRegistrationFailurePolicy.notificationsAreNotAllowed(notificationsDenied)
        )
        XCTAssertFalse(
            RemotePushRegistrationFailurePolicy.notificationsAreNotAllowed(unrelatedFailure)
        )
    }

    func testPushServerURLRequiresHTTPSAndNormalizesOrigin() throws {
        let url = try PushServerConfiguration.normalizedServerURL(
            "  https://PUSH.Example.com/base///?secret=no#fragment  "
        )

        XCTAssertEqual(url.absoluteString, "https://push.example.com/base")
        XCTAssertThrowsError(
            try PushServerConfiguration.normalizedServerURL("http://push.example.com")
        )
        XCTAssertThrowsError(
            try PushServerConfiguration.normalizedServerURL(
                "https://user:pass@push.example.com"
            )
        )
    }

    func testWorkerLinkParserAcceptsStrictVersionOnePayload() throws {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let session = UUID(uuidString: "019f724a-3414-4d52-ae37-0c7024a1ab97")!
        let link = try makeWorkerLink(
            server: "https://Push.Example.com/",
            session: session.uuidString.lowercased(),
            token: String(repeating: "a", count: 43),
            expires: Int64(now.timeIntervalSince1970) + 300
        )

        let payload = try WorkerLinkPayload.parse(link, now: now)

        XCTAssertEqual(payload.serverURL.absoluteString, "https://push.example.com")
        XCTAssertEqual(payload.sessionID, session)
        XCTAssertEqual(payload.token, String(repeating: "a", count: 43))
        XCTAssertEqual(payload.expiresAt, now.addingTimeInterval(300))
    }

    func testWorkerLinkParserRejectsExpiredFarFutureAndMalformedPayloads() throws {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let session = "019f724a-3414-4d52-ae37-0c7024a1ab97"
        let token = String(repeating: "a", count: 43)

        XCTAssertThrowsError(try WorkerLinkPayload.parse(
            makeWorkerLink(server: "https://push.example.com", session: session,
                           token: token, expires: Int64(now.timeIntervalSince1970)),
            now: now
        ))
        XCTAssertThrowsError(try WorkerLinkPayload.parse(
            makeWorkerLink(server: "https://push.example.com", session: session,
                           token: token, expires: Int64(now.timeIntervalSince1970) + 601),
            now: now
        ))
        XCTAssertThrowsError(try WorkerLinkPayload.parse(
            makeWorkerLink(server: "http://push.example.com", session: session,
                           token: token, expires: Int64(now.timeIntervalSince1970) + 300),
            now: now
        ))
        XCTAssertThrowsError(try WorkerLinkPayload.parse(
            makeWorkerLink(server: "https://push.example.com/path", session: session,
                           token: token, expires: Int64(now.timeIntervalSince1970) + 300),
            now: now
        ))
        XCTAssertThrowsError(try WorkerLinkPayload.parse(
            makeWorkerLink(server: "https://push.example.com", session: session.uppercased(),
                           token: token, expires: Int64(now.timeIntervalSince1970) + 300),
            now: now
        ))
        XCTAssertThrowsError(try WorkerLinkPayload.parse(
            makeWorkerLink(server: "https://push.example.com", session: session,
                           token: String(repeating: "a", count: 42),
                           expires: Int64(now.timeIntervalSince1970) + 300),
            now: now
        ))
        XCTAssertThrowsError(try WorkerLinkPayload.parse(
            makeWorkerLink(server: "https://push.example.com", session: session,
                           token: token, expires: Int64(now.timeIntervalSince1970) + 300,
                           version: "2"),
            now: now
        ))
    }

    func testWorkerLinkParserRejectsDuplicateAndExtraQueryItems() throws {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let valid = try makeWorkerLink(
            server: "https://push.example.com",
            session: "019f724a-3414-4d52-ae37-0c7024a1ab97",
            token: String(repeating: "a", count: 43),
            expires: Int64(now.timeIntervalSince1970) + 300
        )

        XCTAssertThrowsError(try WorkerLinkPayload.parse(valid + "&token="
            + String(repeating: "b", count: 43), now: now))
        XCTAssertThrowsError(try WorkerLinkPayload.parse(valid + "&unexpected=1", now: now))
        XCTAssertThrowsError(try WorkerLinkPayload.parse(
            String(repeating: "x", count: WorkerLinkPayload.maximumURLBytes + 1),
            now: now
        ))
    }

    func testCopilotCredentialsCannotBeSelectedForOffDeviceMonitoring() {
        XCTAssertFalse(ProviderID.githubCopilot.supportsOffDeviceMonitoring)
        XCTAssertTrue(ProviderID.chatGPT.supportsOffDeviceMonitoring)
        XCTAssertTrue(ProviderID.claude.supportsOffDeviceMonitoring)
        XCTAssertTrue(ProviderID.kimi.supportsOffDeviceMonitoring)
        XCTAssertTrue(ProviderID.zai.supportsOffDeviceMonitoring)
        XCTAssertTrue(ProviderID.miniMax.supportsOffDeviceMonitoring)
    }

    func testWorkerAccountResponseIgnoresReturnedCredentials() throws {
        let account = MonitoredAccount(
            id: UUID(), providerID: .chatGPT, displayName: "Work account",
            workspaceID: "workspace", plan: "Pro", addedAt: .now
        )
        let response = Data(#"""
        {
          "consent_revision": 7,
          "account_reference": "DDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDD",
          "session_status": "active",
          "session_checked_at": 1999999975,
          "credentials": {
            "access_token": 123,
            "refresh_token": ["must", "not", "decode"],
            "id_token": {"or": "reach Keychain"}
          },
          "metadata": {
            "name": "Provider Person",
            "email": "person@example.com",
            "plan": "Pro 20x",
            "plan_expires_at": 2000000000,
            "trial_expires_at": 1999000000
          },
          "history": []
        }
        """#.utf8)

        let result = try PushServerClient.decodeAccountResponse(response, account: account)

        XCTAssertEqual(result.consentRevision, 7)
        XCTAssertEqual(result.workerAccountReference,
                       "DDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDD")
        XCTAssertEqual(result.sessionStatus, .active)
        XCTAssertEqual(result.sessionCheckedAt,
                       Date(timeIntervalSince1970: 1_999_999_975))
        XCTAssertEqual(result.accountDetails?.profileName, "Provider Person")
        XCTAssertEqual(result.accountDetails?.email, "person@example.com")
        XCTAssertEqual(result.accountDetails?.plan, "Pro 20x")
        XCTAssertEqual(result.accountDetails?.planExpiresAt,
                       Date(timeIntervalSince1970: 2_000_000_000))
        XCTAssertEqual(result.accountDetails?.trialExpiresAt,
                       Date(timeIntervalSince1970: 1_999_000_000))
        XCTAssertEqual(result.accountDetails?.replacesMissingFields, true)
        XCTAssertNil(result.snapshot)
        XCTAssertTrue(result.history.isEmpty)
    }

    func testWorkerAccountResponsePreservesWalletBalanceSemantics() throws {
        let account = MonitoredAccount(
            id: UUID(), providerID: .poe, displayName: "Poe API account",
            workspaceID: "poe-key-test", plan: nil, addedAt: .now
        )
        let response = Data(#"""
        {
          "consent_revision": 3,
          "snapshot": {
            "provider_id": "poe",
            "fetched_at": 2000000000,
            "windows": [],
            "available_reset_count": 0,
            "reset_credits": [],
            "api_balance": {
              "title": "API point balance",
              "currency_code": "POINTS",
              "spent": 0,
              "remaining": 123456,
              "is_unlimited": false,
              "kind": "wallet",
              "unit_label": "points"
            }
          },
          "history": []
        }
        """#.utf8)

        let result = try PushServerClient.decodeAccountResponse(response, account: account)

        XCTAssertEqual(result.snapshot?.apiBalance?.kind, .wallet)
        XCTAssertEqual(result.snapshot?.apiBalance?.unitLabel, "points")
        XCTAssertEqual(result.snapshot?.apiBalance?.remaining, 123_456)
    }

    func testRemoteWorkerCandidateDecodesSanitizedAccountMetadata() throws {
        let response = Data(#"""
        {
          "remote_account_id": "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA",
          "synced_account_reference": "BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB",
          "account_reference": "CCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCC",
          "provider_id": "claude",
          "display_name": "Work",
          "plan": "Max",
          "metadata": {
            "name": "Provider Person",
            "email": "person@example.com",
            "plan": "Max",
            "plan_expires_at": 2000000000,
            "trial_expires_at": null
          },
          "last_success_at": 1999999900,
          "session_status": "expired",
          "session_checked_at": 1999999950
        }
        """#.utf8)

        let candidate = try JSONDecoder().decode(RemoteWorkerAccountCandidate.self, from: response)

        XCTAssertEqual(candidate.syncedAccountReference,
                       "BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB")
        XCTAssertEqual(candidate.workerAccountReference,
                       "CCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCC")
        XCTAssertEqual(candidate.metadata?.name, "Provider Person")
        XCTAssertEqual(candidate.metadata?.email, "person@example.com")
        XCTAssertEqual(candidate.metadata?.plan, "Max")
        XCTAssertEqual(candidate.metadata?.accountDetails.planExpiresAt,
                       Date(timeIntervalSince1970: 2_000_000_000))
        XCTAssertNil(candidate.metadata?.accountDetails.trialExpiresAt)
        XCTAssertEqual(candidate.sessionStatus, .expired)
        XCTAssertEqual(candidate.sessionCheckedAt,
                       Date(timeIntervalSince1970: 1_999_999_950))
    }

    func testRemoteWorkerCandidateMatchesItsSyncedLocalAccountWithoutExposingUUID() throws {
        let accountID = UUID(uuidString: "019F724A-3414-4D52-AE37-0C7024A1ABA0")!
        let account = MonitoredAccount(
            id: accountID,
            providerID: .claude,
            displayName: "Work",
            workspaceID: "workspace",
            plan: "Max",
            addedAt: .now
        )
        let candidate = RemoteWorkerAccountCandidate(
            remoteAccountID: String(repeating: "A", count: 43),
            syncedAccountReference: RemoteWorkerAccountMatcher.reference(for: accountID),
            workerAccountReference: String(repeating: "B", count: 43),
            providerID: .claude,
            displayName: "Work",
            plan: "Max",
            metadata: nil,
            lastSuccessTimestamp: nil
        )

        let matchingSettings = AccountMonitorSettings(
            workerAccountReference: String(repeating: "B", count: 43)
        )
        XCTAssertTrue(RemoteWorkerAccountMatcher.matches(
            candidate,
            account: account,
            settings: matchingSettings
        ))
        XCTAssertFalse(RemoteWorkerAccountMatcher.reference(for: accountID)
            .contains(accountID.uuidString.lowercased()))

        let legacyCandidate = RemoteWorkerAccountCandidate(
            remoteAccountID: String(repeating: "C", count: 43),
            syncedAccountReference: RemoteWorkerAccountMatcher.reference(for: accountID),
            providerID: .claude,
            displayName: "Work",
            plan: "Max",
            metadata: nil,
            lastSuccessTimestamp: nil
        )
        XCTAssertTrue(RemoteWorkerAccountMatcher.matches(
            legacyCandidate,
            account: account,
            settings: .init()
        ))

        var wrongProvider = account
        wrongProvider.providerID = .chatGPT
        XCTAssertFalse(RemoteWorkerAccountMatcher.matches(
            candidate,
            account: wrongProvider,
            settings: matchingSettings
        ))
    }

    func testMatchingDirectWorkerAccountRemainsEligibleUntilRemoteIDIsAttached() throws {
        let serverURL = "https://worker.example.com"
        let account = MonitoredAccount(
            id: UUID(uuidString: "019F724A-3414-4D52-AE37-0C7024A1ABA0")!,
            providerID: .claude,
            displayName: "Work",
            workspaceID: "workspace",
            plan: "Max",
            addedAt: .now
        )
        let remoteAccountID = String(repeating: "A", count: 43)
        let workerReference = String(repeating: "B", count: 43)
        let candidate = RemoteWorkerAccountCandidate(
            remoteAccountID: remoteAccountID,
            workerAccountReference: workerReference,
            providerID: .claude,
            displayName: "Work",
            plan: "Max",
            metadata: nil,
            lastSuccessTimestamp: nil
        )
        let awaitingAttachment = AccountMonitorSettings(
            monitorOnSelfHostedServer: true,
            selfHostedServerConsentURL: serverURL,
            selfHostedServerConsentRevision: 1,
            workerAccountReference: workerReference
        )

        XCTAssertTrue(RemoteWorkerAccountMatcher.matches(
            candidate,
            account: account,
            settings: awaitingAttachment
        ))
        XCTAssertFalse(RemoteWorkerAccountMatcher.isAlreadyAttached(
            candidate,
            accounts: [account],
            serverURL: serverURL,
            settingsForAccount: { _ in awaitingAttachment }
        ))

        var attached = awaitingAttachment
        attached.remoteWorkerAccountID = remoteAccountID
        XCTAssertTrue(RemoteWorkerAccountMatcher.isAlreadyAttached(
            candidate,
            accounts: [account],
            serverURL: serverURL,
            settingsForAccount: { _ in attached }
        ))
    }

    func testRemoteWorkerImportResponsePropagatesConsentRevision() throws {
        let remoteAccountID = String(repeating: "A", count: 43)
        let localAccountID = UUID(uuidString: "019F724A-3414-4D52-AE37-0C7024A1ABA0")!
        let candidate = RemoteWorkerAccountCandidate(
            remoteAccountID: remoteAccountID,
            providerID: .claude,
            displayName: "Work",
            plan: "Max",
            metadata: nil,
            lastSuccessTimestamp: nil
        )
        let response = Data(#"""
        {
          "account": {
            "remote_account_id": "\#(remoteAccountID)",
            "local_account_id": "\#(localAccountID.uuidString.lowercased())",
            "provider_id": "claude",
            "display_name": "Work",
            "consent_revision": 23
          }
        }
        """#.utf8)

        let result = try PushServerClient.decodeRemoteAccountImportResponse(
            response,
            candidate: candidate,
            localAccountID: localAccountID
        )

        XCTAssertEqual(result.account.remoteAccountID, remoteAccountID)
        XCTAssertEqual(result.consentRevision, 23)
    }

    func testRemoteWorkerImportResponseDefaultsLegacyConsentRevisionToOne() throws {
        let remoteAccountID = String(repeating: "A", count: 43)
        let localAccountID = UUID(uuidString: "019F724A-3414-4D52-AE37-0C7024A1ABA0")!
        let candidate = RemoteWorkerAccountCandidate(
            remoteAccountID: remoteAccountID,
            providerID: .claude,
            displayName: "Work",
            plan: "Max",
            metadata: nil,
            lastSuccessTimestamp: nil
        )
        let response = Data(#"""
        {
          "account": {
            "remote_account_id": "\#(remoteAccountID)",
            "local_account_id": "\#(localAccountID.uuidString.lowercased())",
            "provider_id": "claude",
            "display_name": "Work"
          }
        }
        """#.utf8)

        let result = try PushServerClient.decodeRemoteAccountImportResponse(
            response,
            candidate: candidate,
            localAccountID: localAccountID
        )

        XCTAssertEqual(result.consentRevision, 1)
    }

    func testRemoteWorkerImportResponseRejectsInvalidConsentRevision() throws {
        let remoteAccountID = String(repeating: "A", count: 43)
        let localAccountID = UUID(uuidString: "019F724A-3414-4D52-AE37-0C7024A1ABA0")!
        let candidate = RemoteWorkerAccountCandidate(
            remoteAccountID: remoteAccountID,
            providerID: .claude,
            displayName: "Work",
            plan: "Max",
            metadata: nil,
            lastSuccessTimestamp: nil
        )

        for revision in [Int64(0), ServerConsentRevisionPolicy.maximum + 1] {
            let response = Data(#"""
            {
              "account": {
                "remote_account_id": "\#(remoteAccountID)",
                "local_account_id": "\#(localAccountID.uuidString.lowercased())",
                "provider_id": "claude",
                "display_name": "Work",
                "consent_revision": \#(revision)
              }
            }
            """#.utf8)

            XCTAssertThrowsError(try PushServerClient.decodeRemoteAccountImportResponse(
                response,
                candidate: candidate,
                localAccountID: localAccountID
            )) { error in
                guard let pushServerError = error as? PushServerError,
                      case .invalidResponse = pushServerError else {
                    return XCTFail("Expected invalidResponse, got \(error)")
                }
            }
        }
    }

    func testStoredWorkerRegistrationControlsRemoteDiscoveryReadiness() throws {
        let serverURL = try XCTUnwrap(URL(
            string: "https://worker-\(UUID().uuidString.lowercased()).example.com"
        ))
        let settings = PushServerSettings(
            mode: .custom,
            customServerURL: serverURL.absoluteString
        )
        defer { KeychainStore.deletePushRegistration(for: serverURL) }
        KeychainStore.deletePushRegistration(for: serverURL)

        XCTAssertFalse(PushServerClient.hasStoredRegistration(settings: settings))

        do {
            try KeychainStore.savePushRegistration(.init(
                deviceID: UUID(),
                deviceSecret: "test-only-device-secret",
                serverURL: serverURL
            ))
        } catch {
            let nsError = error as NSError
            if nsError.domain == NSOSStatusErrorDomain,
               nsError.code == Int(errSecMissingEntitlement) {
                throw XCTSkip("The simulator test host cannot access Keychain.")
            }
            throw error
        }
        XCTAssertTrue(PushServerClient.hasStoredRegistration(settings: settings))
    }

    func testRemoteHistoryImportFailureExplainsPartialSuccess() {
        let error = RemoteWorkerImportError.retainedHistoryDownloadFailed(
            importedCount: 2,
            reason: "The Worker could not be reached."
        )

        XCTAssertEqual(
            error.localizedDescription,
            "2 accounts were added, but retained history could not be downloaded. The Worker could not be reached. Retry from the account’s Usage History section."
        )
    }

    func testRemoteWorkerImportFailureExplainsDurablePartialSuccess() {
        let error = RemoteWorkerImportError.accountImportPartiallySucceeded(
            importedCount: 2,
            reason: "The Worker returned HTTP 409.",
            retainedHistoryReason: nil
        )

        XCTAssertEqual(
            error.localizedDescription,
            "2 accounts were added, but the remaining Worker accounts could not be added. The Worker returned HTTP 409. Try again to continue."
        )
    }

    func testRemoteWorkerImportFailureCanAlsoReportHistoryFailure() {
        let error = RemoteWorkerImportError.accountImportPartiallySucceeded(
            importedCount: 1,
            reason: "The Worker returned HTTP 409.",
            retainedHistoryReason: "The history request timed out."
        )

        XCTAssertEqual(
            error.localizedDescription,
            "1 account was added, but the remaining Worker accounts could not be added. The Worker returned HTTP 409. Retained history for the added accounts also could not be downloaded. The history request timed out. Try again to continue."
        )
    }

    func testRecoveredWorkerConsentRevisionPreservesDirectSourceButNotSubscription() {
        XCTAssertEqual(ServerConsentRevisionPolicy.recoveredRevision(
            isRemoteOnly: false,
            proposedRevision: 1,
            previousRevision: 1,
            highWaterRevision: 29
        ), 1)
        XCTAssertEqual(ServerConsentRevisionPolicy.recoveredRevision(
            isRemoteOnly: false,
            proposedRevision: 23,
            previousRevision: 23,
            highWaterRevision: 29
        ), 23)
        XCTAssertEqual(ServerConsentRevisionPolicy.recoveredRevision(
            isRemoteOnly: true,
            proposedRevision: 29,
            previousRevision: 29,
            highWaterRevision: 29
        ), 1)
    }

    func testAuthenticatedWorkerSyncRecoversNewerDirectConsentRevision() throws {
        XCTAssertEqual(try ServerConsentRevisionPolicy.synchronizedRevision(
            currentRevision: 2,
            serverRevision: 59,
            highWaterRevision: 2,
            pendingDeletionRevision: nil
        ), 59)
    }

    func testAuthenticatedWorkerSyncRebasesRemoteSubscriptionToRevisionOne() throws {
        XCTAssertEqual(try ServerConsentRevisionPolicy.synchronizedRevision(
            currentRevision: 29,
            serverRevision: 1,
            highWaterRevision: 29,
            pendingDeletionRevision: nil
        ), 1)
    }

    func testAuthenticatedWorkerSyncCannotRevivePendingDeletion() {
        XCTAssertThrowsError(try ServerConsentRevisionPolicy.synchronizedRevision(
            currentRevision: 60,
            serverRevision: 59,
            highWaterRevision: 60,
            pendingDeletionRevision: 60
        )) { error in
            guard let pushError = error as? PushServerError,
                  case .consentRevisionConflict = pushError else {
                return XCTFail("Expected consentRevisionConflict, got \(error)")
            }
        }
    }

    func testSameAccountReconnectCanReplaceRemoteCredentialButNormalUploadCannot() {
        XCTAssertTrue(ServerAccountUploadPolicy.permitsUpload(
            isDemo: false,
            isRemoteOnly: false,
            hasRemoteWorkerAccountID: true,
            replacingRemoteCredential: true
        ))
        XCTAssertFalse(ServerAccountUploadPolicy.permitsUpload(
            isDemo: false,
            isRemoteOnly: false,
            hasRemoteWorkerAccountID: true,
            replacingRemoteCredential: false
        ))
        XCTAssertFalse(ServerAccountUploadPolicy.permitsUpload(
            isDemo: false,
            isRemoteOnly: true,
            hasRemoteWorkerAccountID: true,
            replacingRemoteCredential: true
        ))
    }

    func testLiveActivityRotatesBeforeSystemEightHourLimit() {
        let startedAt = Date(timeIntervalSince1970: 2_000_000_000)

        XCTAssertFalse(LiveActivityLifecyclePolicy.shouldRotate(startedAt: nil, at: startedAt))
        XCTAssertFalse(LiveActivityLifecyclePolicy.shouldRotate(
            startedAt: startedAt,
            at: startedAt.addingTimeInterval(7 * 60 * 60 - 1)
        ))
        XCTAssertTrue(LiveActivityLifecyclePolicy.shouldRotate(
            startedAt: startedAt,
            at: startedAt.addingTimeInterval(7 * 60 * 60)
        ))
        XCTAssertTrue(LiveActivityLifecyclePolicy.isRunning(.active))
        XCTAssertTrue(LiveActivityLifecyclePolicy.isRunning(.stale))
        XCTAssertFalse(LiveActivityLifecyclePolicy.isRunning(.ended))
        XCTAssertFalse(LiveActivityLifecyclePolicy.isRunning(.dismissed))
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

    func testDirectChatGPTDuplicatePlanOnlyOriginatesOnWorkerAuthoritativeDevice() throws {
        let earlier = Date(timeIntervalSince1970: 1_000)
        let later = Date(timeIntervalSince1970: 2_000)
        let unmonitored = MonitoredAccount(
            id: UUID(uuidString: "00000000-0000-4000-8000-000000000001")!,
            providerID: .chatGPT,
            displayName: "Different provider label",
            workspaceID: "shared-chatgpt-workspace",
            plan: "Pro",
            addedAt: later
        )
        let workerProtected = MonitoredAccount(
            id: UUID(uuidString: "00000000-0000-4000-8000-000000000002")!,
            providerID: .chatGPT,
            displayName: "Another provider label",
            workspaceID: "shared-chatgpt-workspace",
            plan: "Pro",
            addedAt: earlier
        )
        let sameNameDifferentWorkspace = MonitoredAccount(
            id: UUID(uuidString: "00000000-0000-4000-8000-000000000003")!,
            providerID: .chatGPT,
            displayName: unmonitored.displayName,
            workspaceID: "different-chatgpt-workspace",
            plan: "Pro",
            addedAt: earlier
        )

        let plan = try XCTUnwrap(DirectChatGPTDuplicateMergePolicy.plans(
            accounts: [unmonitored, workerProtected, sameNameDifferentWorkspace],
            workerProtectedAccountIDs: [workerProtected.id]
        ).first)

        XCTAssertEqual(plan.canonicalAccountID, workerProtected.id)
        XCTAssertEqual(plan.duplicateAccountIDs, [unmonitored.id])
        let zeroProtectedPlan = try XCTUnwrap(
            DirectChatGPTDuplicateMergePolicy.plans(
                accounts: [unmonitored, workerProtected, sameNameDifferentWorkspace],
                workerProtectedAccountIDs: []
            ).first
        )
        XCTAssertEqual(zeroProtectedPlan.canonicalAccountID, workerProtected.id)
        XCTAssertEqual(zeroProtectedPlan.duplicateAccountIDs, [unmonitored.id])
    }

    func testDirectChatGPTDuplicatePlanNeverMergesTwoWorkerSourcesOrOtherProviders() {
        let date = Date(timeIntervalSince1970: 2_000)
        let first = MonitoredAccount(
            id: UUID(uuidString: "00000000-0000-4000-8000-000000000001")!,
            providerID: .chatGPT, displayName: "One",
            workspaceID: "workspace", plan: "Pro", addedAt: date
        )
        let second = MonitoredAccount(
            id: UUID(uuidString: "00000000-0000-4000-8000-000000000002")!,
            providerID: .chatGPT, displayName: "Two",
            workspaceID: "workspace", plan: "Pro",
            addedAt: date.addingTimeInterval(1)
        )
        let claude = MonitoredAccount(
            id: UUID(), providerID: .claude, displayName: "One",
            workspaceID: "workspace", plan: "Pro", addedAt: date
        )

        XCTAssertTrue(DirectChatGPTDuplicateMergePolicy.plans(
            accounts: [first, second, claude],
            workerProtectedAccountIDs: [first.id, second.id]
        ).isEmpty)
        XCTAssertTrue(DirectChatGPTDuplicateMergePolicy.plans(
            accounts: [first, second],
            workerProtectedAccountIDs: [second.id]
        ).isEmpty)
        let zeroProtectedForward = DirectChatGPTDuplicateMergePolicy.plans(
            accounts: [first, second],
            workerProtectedAccountIDs: []
        )
        let zeroProtectedReverse = DirectChatGPTDuplicateMergePolicy.plans(
            accounts: [second, first],
            workerProtectedAccountIDs: []
        )
        XCTAssertEqual(zeroProtectedForward, zeroProtectedReverse)
        XCTAssertEqual(zeroProtectedForward.first?.canonicalAccountID, first.id)
        XCTAssertEqual(zeroProtectedForward.first?.duplicateAccountIDs, [second.id])
        XCTAssertEqual(DirectChatGPTDuplicateMergePolicy.plans(
            accounts: [second, first],
            workerProtectedAccountIDs: [first.id]
        ).first?.canonicalAccountID, first.id)
        XCTAssertTrue(DirectChatGPTDuplicateMergePolicy.plans(
            accounts: [first, claude],
            workerProtectedAccountIDs: []
        ).isEmpty)
    }

    func testColdLaunchMissingAccountSynthesizesBothWorkerDeletionFloors() {
        let workerURL = "https://worker.example"
        let settings = AccountMonitorSettings(
            monitorOnSelfHostedServer: true,
            selfHostedServerConsentURL: workerURL,
            selfHostedServerConsentRevision: 7,
            uploadsDeviceUsageToWorker: true,
            deviceUsageWorkerURL: workerURL,
            deviceUsageConsentRevision: 11
        )

        let needs = ColdLaunchAccountCleanupPolicy.workerDeletionNeeds(
            settings: settings,
            workerURL: workerURL,
            pendingCredentialRevision: 9,
            pendingDeviceUsageRevision: 13
        )

        XCTAssertEqual(needs.credentialRevisionFloor, 9)
        XCTAssertEqual(needs.deviceUsageRevisionFloor, 13)
        XCTAssertFalse(needs.isEmpty)
        // A relaunched device retains the already-journaled floors even after account settings
        // have been cleared locally by the prior offline removal attempt.
        XCTAssertEqual(
            ColdLaunchAccountCleanupPolicy.workerDeletionNeeds(
                settings: nil,
                workerURL: workerURL,
                pendingCredentialRevision: 10,
                pendingDeviceUsageRevision: 14
            ),
            .init(credentialRevisionFloor: 10, deviceUsageRevisionFloor: 14)
        )

        let credentialDeleted = ColdLaunchAccountCleanupPolicy.clearingCredentialSource(
            in: settings,
            deletionRevision: 10
        )
        XCTAssertFalse(credentialDeleted.monitorOnSelfHostedServer)
        XCTAssertNil(credentialDeleted.selfHostedServerConsentURL)
        XCTAssertEqual(credentialDeleted.selfHostedServerConsentRevision, 10)
        XCTAssertTrue(credentialDeleted.uploadsDeviceUsageToWorker)

        let fullyDeleted = ColdLaunchAccountCleanupPolicy.clearingDeviceUsageSource(
            in: credentialDeleted,
            deletionRevision: 14
        )
        XCTAssertFalse(fullyDeleted.uploadsDeviceUsageToWorker)
        XCTAssertNil(fullyDeleted.deviceUsageWorkerURL)
        XCTAssertEqual(fullyDeleted.deviceUsageConsentRevision, 14)
        XCTAssertFalse(DirectChatGPTDuplicateMergePolicy.protectsDeviceUsageSource(fullyDeleted))
    }

    func testColdLaunchAliasSourceIsRetainedWhetherAliasArrivesBeforeOrAfterDeletion() {
        let canonical = MonitoredAccount(
            id: UUID(uuidString: "00000000-0000-4000-8000-000000000001")!,
            providerID: .chatGPT,
            displayName: "Canonical",
            workspaceID: "exact-workspace",
            plan: "Pro",
            addedAt: Date(timeIntervalSince1970: 1_000)
        )
        let deletedSource = MonitoredAccount(
            id: UUID(uuidString: "00000000-0000-4000-8000-000000000002")!,
            providerID: .chatGPT,
            displayName: "Old label",
            workspaceID: "exact-workspace",
            plan: "Pro",
            addedAt: Date(timeIntervalSince1970: 2_000)
        )

        XCTAssertEqual(
            ColdLaunchAccountCleanupPolicy.missingCachedAccounts(
                cachedAccounts: [canonical, deletedSource],
                syncedAccounts: [canonical]
            ),
            [deletedSource]
        )
        XCTAssertTrue(ColdLaunchAccountCleanupPolicy.isPotentialChatGPTMergeSource(
            deletedSource,
            syncedAccounts: [canonical]
        ))
        XCTAssertFalse(ColdLaunchAccountCleanupPolicy.isPotentialChatGPTMergeSource(
            MonitoredAccount(
                id: UUID(), providerID: .chatGPT, displayName: "Other",
                workspaceID: "other-workspace", plan: nil, addedAt: .now
            ),
            syncedAccounts: [canonical]
        ))
    }

    func testDuplicateMergeAbortsWhenProtectionAppearsAfterPlan() throws {
        let date = Date(timeIntervalSince1970: 2_000)
        let canonical = MonitoredAccount(
            id: UUID(uuidString: "00000000-0000-4000-8000-000000000001")!,
            providerID: .chatGPT, displayName: "One",
            workspaceID: "workspace", plan: "Pro", addedAt: date
        )
        let duplicate = MonitoredAccount(
            id: UUID(uuidString: "00000000-0000-4000-8000-000000000002")!,
            providerID: .chatGPT, displayName: "Two",
            workspaceID: "workspace", plan: "Pro", addedAt: date
        )
        let plan = try XCTUnwrap(DirectChatGPTDuplicateMergePolicy.plans(
            accounts: [duplicate, canonical],
            workerProtectedAccountIDs: []
        ).first)

        XCTAssertTrue(DirectChatGPTDuplicateMergePolicy.protectionRemainsValid(
            plan,
            protectedAccountIDs: []
        ))
        XCTAssertFalse(DirectChatGPTDuplicateMergePolicy.protectionRemainsValid(
            plan,
            protectedAccountIDs: [duplicate.id]
        ))
        XCTAssertFalse(DirectChatGPTDuplicateMergePolicy.protectionRemainsValid(
            plan,
            protectedAccountIDs: [canonical.id]
        ))

        var canonicalProtectedPlan = plan
        canonicalProtectedPlan.allowedProtectedAccountIDs = [canonical.id]
        XCTAssertTrue(DirectChatGPTDuplicateMergePolicy.protectionRemainsValid(
            canonicalProtectedPlan,
            protectedAccountIDs: [canonical.id]
        ))
        XCTAssertFalse(DirectChatGPTDuplicateMergePolicy.protectionRemainsValid(
            canonicalProtectedPlan,
            protectedAccountIDs: [canonical.id, duplicate.id]
        ))
    }

    func testDirectChatGPTDuplicateMergePreservesWorkerTupleAndRestrictiveSettings() {
        let canonical = AccountMonitorSettings(
            notifyAboutResets: true,
            notifyAtScheduledReset: true,
            showBankedResets: true,
            hiddenMetricIDs: ["canonical-hidden"],
            showBankedResetsInLiveActivity: true,
            hiddenLiveActivityMetricIDs: ["canonical-live-hidden"],
            pinnedLiveActivityMetricIDs: ["canonical-pinned"],
            monitorOnSelfHostedServer: true,
            selfHostedServerConsentURL: "https://worker.example",
            selfHostedServerConsentRevision: 9,
            remoteWorkerAccountID: String(repeating: "A", count: 43),
            workerAccountReference: String(repeating: "B", count: 43)
        )
        let duplicate = AccountMonitorSettings(
            notifyAboutResets: false,
            notifyAtScheduledReset: false,
            showBankedResets: false,
            hiddenMetricIDs: ["duplicate-hidden"],
            showBankedResetsInLiveActivity: false,
            hiddenLiveActivityMetricIDs: ["duplicate-live-hidden"],
            pinnedLiveActivityMetricIDs: ["duplicate-pinned"],
            monitorOnSelfHostedServer: false,
            selfHostedServerConsentURL: "https://must-not-replace.example",
            selfHostedServerConsentRevision: 99,
            remoteWorkerAccountID: String(repeating: "C", count: 43),
            workerAccountReference: String(repeating: "D", count: 43)
        )

        let merged = DirectChatGPTDuplicateMergePolicy.mergedSettings(
            canonical: canonical,
            duplicate: duplicate
        )

        XCTAssertFalse(merged.notifyAboutResets)
        XCTAssertFalse(merged.notifyAtScheduledReset)
        XCTAssertFalse(merged.showBankedResets)
        XCTAssertFalse(merged.showBankedResetsInLiveActivity)
        XCTAssertEqual(merged.hiddenMetricIDs, ["canonical-hidden", "duplicate-hidden"])
        XCTAssertEqual(
            merged.hiddenLiveActivityMetricIDs,
            ["canonical-live-hidden", "duplicate-live-hidden"]
        )
        XCTAssertEqual(
            merged.pinnedLiveActivityMetricIDs,
            ["canonical-pinned", "duplicate-pinned"]
        )
        XCTAssertEqual(merged.monitorOnSelfHostedServer, canonical.monitorOnSelfHostedServer)
        XCTAssertEqual(merged.selfHostedServerConsentURL, canonical.selfHostedServerConsentURL)
        XCTAssertEqual(
            merged.selfHostedServerConsentRevision,
            canonical.selfHostedServerConsentRevision
        )
        XCTAssertEqual(merged.remoteWorkerAccountID, canonical.remoteWorkerAccountID)
        XCTAssertEqual(merged.workerAccountReference, canonical.workerAccountReference)
    }

    func testChatGPTDuplicateCredentialPolicyUsesFreshestValidCredential() throws {
        let canonicalID = UUID(uuidString: "00000000-0000-4000-8000-000000000001")!
        let olderFallbackID = UUID(uuidString: "00000000-0000-4000-8000-000000000002")!
        let newerFallbackID = UUID(uuidString: "00000000-0000-4000-8000-000000000003")!
        let canonical = ChatGPTDuplicateCredentialCandidate(
            accountID: canonicalID,
            credentials: chatGPTCredential(workspaceID: "workspace", expiresAt: 4_000)
        )
        let olderFallback = ChatGPTDuplicateCredentialCandidate(
            accountID: olderFallbackID,
            credentials: chatGPTCredential(workspaceID: "workspace", expiresAt: 2_000)
        )
        let newerFallback = ChatGPTDuplicateCredentialCandidate(
            accountID: newerFallbackID,
            credentials: chatGPTCredential(workspaceID: "workspace", expiresAt: 3_000)
        )
        let wrongWorkspace = ChatGPTDuplicateCredentialCandidate(
            accountID: UUID(),
            credentials: chatGPTCredential(workspaceID: "other", expiresAt: 5_000)
        )

        XCTAssertEqual(ChatGPTDuplicateCredentialPolicy.preferred(
            from: [newerFallback, wrongWorkspace, canonical, olderFallback],
            canonicalAccountID: canonicalID,
            workspaceID: "workspace"
        )?.accountID, canonicalID)
        XCTAssertEqual(ChatGPTDuplicateCredentialPolicy.preferred(
            from: [olderFallback, wrongWorkspace, newerFallback],
            canonicalAccountID: canonicalID,
            workspaceID: "workspace"
        )?.accountID, newerFallbackID)
    }

    func testChatGPTDuplicateKeychainMergeDeletesLosingSynchronizedRecords() throws {
        let canonical = MonitoredAccount(
            id: UUID(), providerID: .chatGPT, displayName: "Canonical",
            workspaceID: "workspace", plan: "Pro",
            addedAt: Date(timeIntervalSince1970: 1_000)
        )
        let duplicate = MonitoredAccount(
            id: UUID(), providerID: .chatGPT, displayName: "Duplicate",
            workspaceID: canonical.workspaceID, plan: "Pro",
            addedAt: Date(timeIntervalSince1970: 2_000)
        )
        defer {
            KeychainStore.delete(for: canonical.id)
            KeychainStore.delete(for: duplicate.id)
            KeychainStore.deleteAccount(for: canonical.id)
            KeychainStore.deleteAccount(for: duplicate.id)
            KeychainStore.deleteAccountMergeAlias(for: duplicate.id)
        }
        try KeychainStore.save(
            chatGPTCredential(workspaceID: canonical.workspaceID, expiresAt: 2_000),
            for: canonical.id
        )
        try KeychainStore.save(
            chatGPTCredential(workspaceID: canonical.workspaceID, expiresAt: 3_000),
            for: duplicate.id
        )
        try KeychainStore.saveAccount(canonical)
        try KeychainStore.saveAccount(duplicate)

        XCTAssertTrue(try KeychainStore.prepareChatGPTDuplicateCredential(
            canonical: canonical,
            duplicateIDs: [duplicate.id]
        ))
        let alias = DirectChatGPTAccountMergeAlias(
            sourceAccountID: duplicate.id,
            canonicalAccountID: canonical.id,
            workspaceID: canonical.workspaceID,
            createdAt: .now
        )
        try KeychainStore.saveAccountMergeAlias(alias)
        try KeychainStore.deleteDuplicateAccountAndCredential(for: duplicate.id)

        XCTAssertEqual(
            try KeychainStore.load(for: canonical.id).expiresAt,
            Date(timeIntervalSince1970: 3_000)
        )
        XCTAssertThrowsError(try KeychainStore.load(for: duplicate.id))
        XCTAssertNotNil(try KeychainStore.loadAccounts().first { $0.id == canonical.id })
        XCTAssertNil(try KeychainStore.loadAccounts().first { $0.id == duplicate.id })
        XCTAssertEqual(
            try KeychainStore.loadAccountMergeAliases().first {
                $0.sourceAccountID == duplicate.id
            },
            alias
        )
    }

    private func makeWorkerLink(
        server: String,
        session: String,
        token: String,
        expires: Int64,
        version: String = "1"
    ) throws -> String {
        var components = URLComponents()
        components.scheme = WorkerLinkPayload.scheme
        components.host = WorkerLinkPayload.host
        components.queryItems = [
            URLQueryItem(name: "v", value: version),
            URLQueryItem(name: "server", value: server),
            URLQueryItem(name: "session", value: session),
            URLQueryItem(name: "token", value: token),
            URLQueryItem(name: "expires", value: String(expires))
        ]
        return try XCTUnwrap(components.url?.absoluteString)
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

    func testWorkerErrorEnvelopePreservesOnlyAllowlistedCodes() throws {
        let decoded = PushServerClient.rejectedResponseError(
            statusCode: 403,
            body: Data(#"{"error":"provider_request_forbidden"}"#.utf8)
        )
        XCTAssertEqual(decoded.httpStatus, 403)
        XCTAssertEqual(decoded.workerErrorCode, .providerRequestForbidden)

        for body in [
            Data(#"{"error":"upstream-secret-canary"}"#.utf8),
            Data(#"{"error":401}"#.utf8),
            Data("not-json-upstream-secret-canary".utf8),
            Data(repeating: 65, count: 4_097)
        ] {
            let rejected = PushServerClient.rejectedResponseError(
                statusCode: 403,
                body: body
            )
            XCTAssertEqual(rejected.httpStatus, 403)
            XCTAssertNil(rejected.workerErrorCode)
            XCTAssertFalse(rejected.localizedDescription.contains("upstream-secret-canary"))
        }
    }

    func testWorkerFailureClassificationUsesStructuredCodeNotHTTPStatus() {
        let expired = AccountRefreshFailure(
            error: PushServerError.serverRejected(401, .providerSessionExpired)
        )
        XCTAssertEqual(expired.kind, .authentication)
        XCTAssertTrue(expired.requiresRelink)

        let forbidden = AccountRefreshFailure(
            error: PushServerError.serverRejected(403, .providerRequestForbidden)
        )
        XCTAssertEqual(forbidden.kind, .update)
        XCTAssertFalse(forbidden.requiresRelink)
        XCTAssertEqual(forbidden.title, "ChatGPT blocked the Worker check")
        XCTAssertTrue(forbidden.message.contains("was not activated on the Worker"))

        let unauthorized = AccountRefreshFailure(
            error: PushServerError.serverRejected(401, .unauthorized)
        )
        XCTAssertEqual(unauthorized.kind, .update)
        XCTAssertFalse(unauthorized.requiresRelink)
        XCTAssertEqual(unauthorized.title, "Worker pairing expired")

        for status in [401, 403] {
            let unclassified = AccountRefreshFailure(
                error: PushServerError.serverRejected(status)
            )
            XCTAssertEqual(unclassified.kind, .update)
            XCTAssertFalse(unclassified.requiresRelink)
        }
    }

    func testWorkerRelinkKeepsExpiredFailureUntilWorkerConfirmsSuccess() {
        XCTAssertFalse(AccountRelinkFailurePolicy.clearsFailureAfterLocalCredentialSave(
            serverMonitoringEnabled: true
        ))
        XCTAssertTrue(AccountRelinkFailurePolicy.clearsFailureAfterLocalCredentialSave(
            serverMonitoringEnabled: false
        ))
        XCTAssertTrue(WorkerCredentialReplacementPolicy.isConfirmed(
            sessionStatus: .active
        ))
        XCTAssertFalse(WorkerCredentialReplacementPolicy.isConfirmed(
            sessionStatus: .expired
        ))
        XCTAssertFalse(WorkerCredentialReplacementPolicy.isConfirmed(
            sessionStatus: nil
        ))
    }

    func testWorkerRelinkProgressDoesNotReturnToProviderStartAfterAuthorization() {
        let accountID = UUID()
        let verifying = AccountLinkProgress.verifyingWorker(
            accountID: accountID,
            canRetryWithoutAuthorization: true
        )
        let failed = AccountLinkProgress.workerVerificationFailed(
            accountID: accountID,
            canRetryWithoutAuthorization: true
        )

        XCTAssertTrue(verifying.applies(to: accountID))
        XCTAssertTrue(verifying.isVerifyingWorker)
        XCTAssertTrue(verifying.canRetryWithoutAuthorization)
        XCTAssertTrue(failed.applies(to: accountID))
        XCTAssertFalse(failed.isVerifyingWorker)
        XCTAssertTrue(failed.canRetryWithoutAuthorization)
        XCTAssertFalse(AccountLinkProgress.idle.applies(to: accountID))
    }

    func testRemoteOnlyWorkerRelinkFailureRequiresExplicitNewAuthorization() {
        let failed = AccountLinkProgress.workerVerificationFailed(
            accountID: UUID(),
            canRetryWithoutAuthorization: false
        )

        XCTAssertFalse(failed.canRetryWithoutAuthorization)
    }

    func testServerAccountOperationGateSerializesOneAccount() async {
        let gate = ServerAccountOperationGate()
        let accountID = UUID()
        let firstHasLock = expectation(description: "first operation acquired account lock")
        let releaseFirst = TestAsyncLatch()
        let recorder = TestEventRecorder()

        let first = Task {
            await gate.acquire(accountID: accountID)
            await recorder.append("first-start")
            firstHasLock.fulfill()
            await releaseFirst.wait()
            await recorder.append("first-end")
            await gate.release(accountID: accountID)
        }
        await fulfillment(of: [firstHasLock], timeout: 1)

        let second = Task {
            await gate.acquire(accountID: accountID)
            await recorder.append("second-start")
            await gate.release(accountID: accountID)
        }
        await Task.yield()
        let eventsWhileFirstIsHeld = await recorder.snapshot()
        XCTAssertEqual(eventsWhileFirstIsHeld, ["first-start"])

        await releaseFirst.open()
        await first.value
        await second.value
        let completedEvents = await recorder.snapshot()
        XCTAssertEqual(completedEvents, ["first-start", "first-end", "second-start"])
    }

    func testPendingServerDeletionFailsClosedUnlessConsentIsNewer() {
        let serverURL = "https://push.example.com"
        let pending = AccountMonitorSettings(
            monitorOnSelfHostedServer: true,
            selfHostedServerConsentURL: serverURL,
            selfHostedServerConsentRevision: 4
        )
        let reconciled = ServerMonitoringRecovery.reconcilingPendingDeletion(
            in: pending,
            serverURL: serverURL,
            pendingRevision: 5
        )
        XCTAssertFalse(reconciled.monitorOnSelfHostedServer)
        XCTAssertNil(reconciled.selfHostedServerConsentURL)
        XCTAssertEqual(reconciled.selfHostedServerConsentRevision, 5)

        var newerConsent = pending
        newerConsent.selfHostedServerConsentRevision = 6
        XCTAssertEqual(
            ServerMonitoringRecovery.reconcilingPendingDeletion(
                in: newerConsent,
                serverURL: serverURL,
                pendingRevision: 5
            ),
            newerConsent
        )
    }

    func testMissingRemoteSourceCanBeRecreatedOnlyFromConsentedLocalCredentials() {
        let attached = AccountMonitorSettings(
            monitorOnSelfHostedServer: true,
            selfHostedServerConsentURL: "https://push.example.com",
            selfHostedServerConsentRevision: 4,
            remoteWorkerAccountID: String(repeating: "a", count: 43),
            workerAccountReference: String(repeating: "b", count: 43)
        )

        let recovered = ServerMonitoringRecovery.detachingMissingRemoteSource(
            in: attached,
            hasLocalCredentials: true
        )
        XCTAssertEqual(recovered?.monitorOnSelfHostedServer, true)
        XCTAssertEqual(recovered?.selfHostedServerConsentRevision, 4)
        XCTAssertNil(recovered?.remoteWorkerAccountID)
        XCTAssertNil(recovered?.workerAccountReference)

        XCTAssertNil(ServerMonitoringRecovery.detachingMissingRemoteSource(
            in: attached,
            hasLocalCredentials: false
        ))
        var disabled = attached
        disabled.monitorOnSelfHostedServer = false
        XCTAssertNil(ServerMonitoringRecovery.detachingMissingRemoteSource(
            in: disabled,
            hasLocalCredentials: true
        ))
    }

    func testCleanupRecoveryMatchesWorkerOriginDespiteIntervalChange() {
        let cleanup = PushServerSettings(
            mode: .custom,
            customServerURL: "https://push.example.com",
            serverMonitoringInterval: .fifteenMinutes
        )
        let sameWorker = PushServerSettings(
            mode: .custom,
            customServerURL: "https://push.example.com/",
            serverMonitoringInterval: .oneHour
        )
        let otherWorker = PushServerSettings(
            mode: .custom,
            customServerURL: "https://other.example.com",
            serverMonitoringInterval: .fifteenMinutes
        )

        XCTAssertTrue(ServerMonitoringRecovery.cleanupMatchesCurrentWorker(
            cleanup: cleanup,
            current: sameWorker
        ))
        XCTAssertFalse(ServerMonitoringRecovery.cleanupMatchesCurrentWorker(
            cleanup: cleanup,
            current: otherWorker
        ))
    }

    private func chatGPTCredential(
        workspaceID: String,
        expiresAt: TimeInterval
    ) -> AccountCredentials {
        let claims: [String: Any] = [
            "exp": expiresAt,
            "https://api.openai.com/auth": ["chatgpt_account_id": workspaceID]
        ]
        let data = try! JSONSerialization.data(withJSONObject: claims)
        let payload = data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        return AccountCredentials(
            accessToken: "test-access",
            refreshToken: "test-refresh",
            idToken: "header.\(payload).signature",
            expiresAt: Date(timeIntervalSince1970: expiresAt)
        )
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

    func testHistoryMergeMovesRemoteAccountDataWithoutDuplicatePoints() async throws {
        let store = try makeStore()
        let observedAt = Date(timeIntervalSince1970: 2_000_000_000)
        let target = MonitoredAccount(
            id: UUID(uuidString: "019F724A-3414-4D52-AE37-0C7024A1ABA0")!,
            providerID: .chatGPT,
            displayName: "ieb",
            workspaceID: "workspace",
            plan: "Pro",
            addedAt: observedAt
        )
        let remote = MonitoredAccount(
            id: UUID(uuidString: "019F724A-3414-4D52-AE37-0C7024A1ABA1")!,
            providerID: .chatGPT,
            displayName: "Natu Leppanen",
            workspaceID: MonitoredAccount.remoteWorkspacePrefix + "remote",
            plan: "Pro",
            addedAt: observedAt
        )
        let localSnapshot = makeSnapshot(
            account: target,
            at: observedAt,
            weeklyRemaining: 40,
            weeklyResetAt: observedAt.addingTimeInterval(86_400)
        )
        let remoteSnapshot = makeSnapshot(
            account: remote,
            at: observedAt,
            weeklyRemaining: 70,
            weeklyResetAt: observedAt.addingTimeInterval(86_400)
        )
        _ = try await store.record(
            snapshot: localSnapshot,
            account: target,
            source: .background,
            now: observedAt
        )
        _ = try await store.record(
            snapshot: remoteSnapshot,
            account: remote,
            source: .server,
            now: observedAt
        )

        let merged = try await store.mergeAccount(
            sourceID: remote.id,
            into: target.id,
            now: observedAt
        )

        XCTAssertEqual(merged.count, 1)
        XCTAssertEqual(merged.first?.accountID, target.id)
        XCTAssertEqual(merged.first?.remainingPercent, 70)
        XCTAssertEqual(merged.first?.source, .server)
    }

    func testHistoryMergePreservesNewestDetectorStateForSameChatGPTIdentity() async throws {
        let store = try makeStore()
        let firstDate = Date(timeIntervalSince1970: 2_000_000_000)
        let duplicateDate = firstDate.addingTimeInterval(300)
        let nextDate = duplicateDate.addingTimeInterval(300)
        let canonical = MonitoredAccount(
            id: UUID(), providerID: .chatGPT, displayName: "Canonical",
            workspaceID: "same-workspace", plan: "Pro", addedAt: firstDate
        )
        let duplicate = MonitoredAccount(
            id: UUID(), providerID: .chatGPT, displayName: "Duplicate",
            workspaceID: canonical.workspaceID, plan: "Pro", addedAt: duplicateDate
        )
        let resetAt = firstDate.addingTimeInterval(6 * 24 * 60 * 60)
        _ = try await store.record(
            snapshot: makeSnapshot(
                account: canonical,
                at: firstDate,
                weeklyRemaining: 40,
                weeklyResetAt: resetAt
            ),
            account: canonical,
            source: .background,
            now: firstDate
        )
        _ = try await store.record(
            snapshot: makeSnapshot(
                account: duplicate,
                at: duplicateDate,
                weeklyRemaining: 70,
                weeklyResetAt: resetAt
            ),
            account: duplicate,
            source: .background,
            now: duplicateDate
        )

        _ = try await store.mergeAccount(
            sourceID: duplicate.id,
            into: canonical.id,
            now: duplicateDate
        )
        let result = try await store.record(
            snapshot: makeSnapshot(
                account: canonical,
                at: nextDate,
                weeklyRemaining: 71,
                weeklyResetAt: resetAt
            ),
            account: canonical,
            source: .background,
            now: nextDate
        )

        XCTAssertTrue(result.pendingNotifications.isEmpty)
        XCTAssertEqual(result.points.filter { $0.accountID == canonical.id }.count, 3)
        XCTAssertFalse(result.points.contains { $0.accountID == duplicate.id })

        let repeated = try await store.mergeAccount(
            sourceID: duplicate.id,
            into: canonical.id,
            now: nextDate
        )
        XCTAssertEqual(repeated, result.points)
    }

    func testHistoryIdentityMergeDoesNotApplyDefaultThirtyFiveDayPruning() async throws {
        let store = try makeStore()
        let mergeDate = Date(timeIntervalSince1970: 2_000_000_000)
        let oldDate = mergeDate.addingTimeInterval(-60 * 24 * 60 * 60)
        let canonical = MonitoredAccount(
            id: UUID(), providerID: .chatGPT, displayName: "Canonical",
            workspaceID: "same-workspace", plan: "Pro", addedAt: oldDate
        )
        let duplicate = MonitoredAccount(
            id: UUID(), providerID: .chatGPT, displayName: "Duplicate",
            workspaceID: canonical.workspaceID, plan: "Pro", addedAt: oldDate
        )
        _ = try await store.record(
            snapshot: makeSnapshot(
                account: duplicate,
                at: oldDate,
                weeklyRemaining: 60,
                weeklyResetAt: oldDate.addingTimeInterval(7 * 24 * 60 * 60)
            ),
            account: duplicate,
            source: .background,
            now: oldDate
        )

        let merged = try await store.mergeAccount(
            sourceID: duplicate.id,
            into: canonical.id,
            now: mergeDate
        )

        XCTAssertEqual(merged.count, 1)
        XCTAssertEqual(merged.first?.accountID, canonical.id)
        XCTAssertEqual(merged.first?.recordedAt, oldDate)
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
        XCTAssertEqual((upgraded["schemaVersion"] as? NSNumber)?.intValue, 3)
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

    func testLegacyMonitorSettingsDoNotUploadCredentialsByDefault() throws {
        let decoded = try JSONDecoder().decode(AccountMonitorSettings.self, from: Data("{}".utf8))

        XCTAssertFalse(decoded.monitorOnSelfHostedServer)
        XCTAssertNil(decoded.selfHostedServerConsentURL)
        XCTAssertEqual(decoded.selfHostedServerConsentRevision, 0)
        XCTAssertFalse(decoded.uploadsDeviceUsageToWorker)
        XCTAssertNil(decoded.deviceUsageWorkerURL)
        XCTAssertEqual(decoded.deviceUsageConsentRevision, 0)
        XCTAssertEqual(decoded.deviceUsageNextSequence, 1)
    }

    func testDeviceUsageSnapshotEncodingIsCredentialFreeAndExact() throws {
        let account = MonitoredAccount(
            id: UUID(),
            providerID: .chatGPT,
            displayName: "Private account name",
            workspaceID: "private-workspace",
            plan: "Pro",
            addedAt: .now,
            profileName: "Private profile",
            email: "private@example.com"
        )
        let snapshot = UsageSnapshot(
            accountID: account.id,
            providerName: "ChatGPT",
            accountName: account.displayName,
            accountProviderID: .chatGPT,
            plan: account.plan,
            primary: UsageWindow(
                title: "Limit",
                usedPercent: 20,
                resetsAt: Date(timeIntervalSince1970: 2_000_000_600),
                windowMinutes: nil,
                kind: nil,
                identifier: "limit"
            ),
            secondary: nil,
            availableResetCount: 1,
            resetCredits: [ResetCredit(
                id: "private-provider-reset-id",
                expiresAt: nil,
                status: nil,
                grantedAt: nil
            )],
            fetchedAt: Date(timeIntervalSince1970: 2_000_000_000)
        )

        let data = try PushServerClient.deviceUsageSnapshotBody(
            account: account,
            snapshot: snapshot,
            consentRevision: 7,
            sequence: 11
        )
        let text = try XCTUnwrap(String(data: data, encoding: .utf8))
        for privateValue in [
            account.id.uuidString,
            account.displayName,
            account.workspaceID,
            account.profileName!,
            account.email!,
            "private-provider-reset-id",
            "credentials",
            "access_token",
            "refresh_token",
            "id_token",
        ] {
            XCTAssertFalse(text.contains(privateValue))
        }

        let keys = try PushServerClient.deviceUsageSnapshotKeys(
            account: account,
            snapshot: snapshot,
            consentRevision: 7,
            sequence: 11
        )
        XCTAssertEqual(keys.root, ["consent_revision", "sequence", "observed_at", "snapshot"])
        XCTAssertEqual(keys.snapshot, [
            "provider_id", "plan", "windows", "available_reset_count",
            "reset_credits", "reset_credits_authoritative",
        ])
        XCTAssertEqual(keys.resetCredit, ["expires_at", "status", "granted_at"])
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let projection = try XCTUnwrap(json["snapshot"] as? [String: Any])
        let window = try XCTUnwrap((projection["windows"] as? [[String: Any]])?.first)
        XCTAssertTrue(window["kind"] is NSNull)
        XCTAssertTrue(window["window_minutes"] is NSNull)
        let credit = try XCTUnwrap((projection["reset_credits"] as? [[String: Any]])?.first)
        XCTAssertTrue(credit["expires_at"] is NSNull)
        XCTAssertTrue(credit["status"] is NSNull)
        XCTAssertTrue(credit["granted_at"] is NSNull)
    }

    func testServerConsentRevisionSurvivesSettingsPersistence() throws {
        let settings = AccountMonitorSettings(
            monitorOnSelfHostedServer: true,
            selfHostedServerConsentURL: "https://push.example",
            selfHostedServerConsentRevision: 42
        )

        let decoded = try JSONDecoder().decode(
            AccountMonitorSettings.self,
            from: JSONEncoder().encode(settings)
        )
        XCTAssertEqual(decoded.selfHostedServerConsentRevision, 42)
        XCTAssertEqual(decoded.selfHostedServerConsentURL, "https://push.example")
        XCTAssertTrue(decoded.monitorOnSelfHostedServer)
    }

    func testDeviceUsageConsentRoundTripsWithoutEnablingCredentialMonitoring() throws {
        let uploadedAt = Date(timeIntervalSince1970: 2_000_000_000)
        let settings = AccountMonitorSettings(
            monitorOnSelfHostedServer: false,
            uploadsDeviceUsageToWorker: true,
            deviceUsageWorkerURL: "https://worker.example",
            deviceUsageConsentRevision: 4,
            deviceUsageNextSequence: 9,
            deviceUsageLastUploadedAt: uploadedAt,
            deviceUsageLastError: "Retry pending"
        )

        let decoded = try JSONDecoder().decode(
            AccountMonitorSettings.self,
            from: JSONEncoder().encode(settings)
        )
        XCTAssertFalse(decoded.monitorOnSelfHostedServer)
        XCTAssertTrue(decoded.uploadsDeviceUsageToWorker)
        XCTAssertEqual(decoded.deviceUsageWorkerURL, "https://worker.example")
        XCTAssertEqual(decoded.deviceUsageConsentRevision, 4)
        XCTAssertEqual(decoded.deviceUsageNextSequence, 9)
        XCTAssertEqual(decoded.deviceUsageLastUploadedAt, uploadedAt)
        XCTAssertEqual(decoded.deviceUsageLastError, "Retry pending")
    }

    func testDeviceUsageSequencePolicyRejectsUnsafeBoundaries() {
        XCTAssertFalse(DeviceUsageSequencePolicy.isValid(0))
        XCTAssertTrue(DeviceUsageSequencePolicy.isValid(1))
        XCTAssertEqual(DeviceUsageSequencePolicy.next(after: 1), 2)
        XCTAssertEqual(
            DeviceUsageSequencePolicy.next(after: ServerConsentRevisionPolicy.maximum - 2),
            ServerConsentRevisionPolicy.maximum - 1
        )
        XCTAssertNil(DeviceUsageSequencePolicy.next(
            after: ServerConsentRevisionPolicy.maximum - 1
        ))
        XCTAssertFalse(DeviceUsageSequencePolicy.isValid(
            ServerConsentRevisionPolicy.maximum
        ))
        XCTAssertNil(DeviceUsageSequencePolicy.next(after: Int64.max))
    }

    @MainActor
    func testEnableRaceRecordsDurableDeletionBeforeAttemptAndKeepsItOnFailure() async {
        enum ExpectedFailure: Error { case offline }
        var events: [String] = []

        let succeeded = await DeviceUsageEnableCompensation.run(
            recordDeletionIntent: { events.append("record") },
            deleteSource: {
                events.append("delete")
                throw ExpectedFailure.offline
            },
            clearDeletionIntent: { events.append("clear") }
        )

        XCTAssertFalse(succeeded)
        XCTAssertEqual(events, ["record", "delete"])
    }

    @MainActor
    func testEnableRaceClearsDurableDeletionOnlyAfterConfirmedDelete() async {
        var events: [String] = []

        let succeeded = await DeviceUsageEnableCompensation.run(
            recordDeletionIntent: { events.append("record") },
            deleteSource: { events.append("delete") },
            clearDeletionIntent: { events.append("clear") }
        )

        XCTAssertTrue(succeeded)
        XCTAssertEqual(events, ["record", "delete", "clear"])
    }

    func testDuplicateMergePreservesOnlyCanonicalDeviceUsageConsent() {
        let canonical = AccountMonitorSettings(
            uploadsDeviceUsageToWorker: false,
            deviceUsageConsentRevision: 2
        )
        let duplicate = AccountMonitorSettings(
            uploadsDeviceUsageToWorker: true,
            deviceUsageWorkerURL: "https://must-not-enable.example",
            deviceUsageConsentRevision: 8,
            deviceUsageNextSequence: 12
        )
        let merged = DirectChatGPTDuplicateMergePolicy.mergedSettings(
            canonical: canonical,
            duplicate: duplicate
        )

        XCTAssertFalse(merged.uploadsDeviceUsageToWorker)
        XCTAssertNil(merged.deviceUsageWorkerURL)
        XCTAssertEqual(merged.deviceUsageConsentRevision, 2)
        XCTAssertEqual(merged.deviceUsageNextSequence, 1)
    }

    func testDuplicateMergeProtectsActiveOrPendingDeviceUsageSources() {
        XCTAssertFalse(DirectChatGPTDuplicateMergePolicy.protectsDeviceUsageSource(nil))
        XCTAssertFalse(DirectChatGPTDuplicateMergePolicy.protectsDeviceUsageSource(.init()))
        XCTAssertTrue(DirectChatGPTDuplicateMergePolicy.protectsDeviceUsageSource(
            .init(uploadsDeviceUsageToWorker: true)
        ))
        XCTAssertTrue(DirectChatGPTDuplicateMergePolicy.protectsDeviceUsageSource(
            .init(deviceUsageWorkerURL: "https://worker.example")
        ))
        XCTAssertFalse(DirectChatGPTDuplicateMergePolicy.protectsDeviceUsageSource(
            .init(deviceUsageConsentRevision: 1)
        ))
        XCTAssertTrue(DirectChatGPTDuplicateMergePolicy.protectsDeviceUsageSource(
            nil,
            hasPendingDeletion: true
        ))
    }

    func testServerHistoryMergeKeepsOnlyMatchingAccountAndProvider() async throws {
        let store = try makeStore()
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let account = makeAccount(provider: .claude)
        let older = UsageHistoryPoint(
            accountID: account.id,
            providerID: .claude,
            metricID: "weekly",
            metricTitle: "Weekly limit",
            kind: .weekly,
            windowMinutes: 10_080,
            remainingPercent: 105,
            recordedAt: now.addingTimeInterval(-600),
            resetsAt: now.addingTimeInterval(5 * 86_400),
            secondsUntilReset: 5 * 86_400 + 600,
            source: .server,
            plan: "Max"
        )
        var latest = older
        latest.remainingPercent = 84
        latest.recordedAt = older.recordedAt.addingTimeInterval(5 * 60)
        latest.secondsUntilReset -= 5 * 60
        var rejected = older
        rejected.accountID = UUID()

        let points = try await store.mergeServerHistory(
            [older, latest, rejected],
            account: account,
            now: now
        )

        XCTAssertEqual(points.count, 2)
        let first = try XCTUnwrap(points.first)
        let last = try XCTUnwrap(points.last)
        XCTAssertEqual(first.remainingPercent, 100)
        XCTAssertEqual(last.remainingPercent, 84)
        XCTAssertEqual(
            last.recordedAt.timeIntervalSince(first.recordedAt),
            5 * 60,
            accuracy: 0.001
        )
        XCTAssertTrue(points.allSatisfy { $0.source == .server && $0.plan == "Max" })
    }

    func testHistoryTagsAreStableAndExtendedCloudRetentionAcceptsOlderRows() async throws {
        let store = try makeStore()
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let account = MonitoredAccount(
            id: UUID(uuidString: "00000000-0000-4000-8000-000000000001")!,
            providerID: .chatGPT,
            displayName: "Work",
            workspaceID: "workspace",
            plan: "Plus",
            addedAt: now
        )
        let recordedAt = now.addingTimeInterval(-60 * 24 * 60 * 60)
        let expectedTag = "h1.00000000-0000-4000-8000-000000000001.d2Vla2x5.1994816000"
        var point = UsageHistoryPoint(
            accountID: account.id,
            providerID: .chatGPT,
            metricID: "weekly",
            metricTitle: "Weekly limit",
            kind: .weekly,
            windowMinutes: 10_080,
            remainingPercent: 50,
            recordedAt: recordedAt,
            resetsAt: recordedAt.addingTimeInterval(7 * 24 * 60 * 60),
            secondsUntilReset: 7 * 24 * 60 * 60,
            source: .server,
            plan: "Plus"
        )
        XCTAssertEqual(point.resolvedRowTag, expectedTag)

        try await store.setRetentionInterval(90 * 24 * 60 * 60, now: now)
        let firstMerge = try await store.mergeServerHistory([point], account: account, now: now)
        XCTAssertEqual(firstMerge.map(\.resolvedRowTag), [expectedTag])

        point.remainingPercent = 42
        let repeatedMerge = try await store.mergeServerHistory([point], account: account, now: now)
        XCTAssertEqual(repeatedMerge.count, 1)
        XCTAssertEqual(repeatedMerge.first?.remainingPercent, 42)
    }

    func testMacStatusTargetsDeduplicateMetricsAndResolveBankedCreditCount() throws {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let account = MonitoredAccount(
            id: UUID(uuidString: "00000000-0000-4000-8000-000000000001")!,
            providerID: .chatGPT,
            displayName: "Work account",
            workspaceID: "workspace",
            plan: "Plus",
            addedAt: now
        )
        let snapshot = UsageSnapshot(
            accountID: account.id,
            providerName: account.providerID.displayName,
            accountName: account.displayName,
            accountProviderID: account.providerID,
            plan: account.plan,
            primary: UsageWindow(
                title: "Primary",
                usedPercent: 25,
                resetsAt: now.addingTimeInterval(600),
                windowMinutes: 300,
                identifier: "same-metric"
            ),
            secondary: UsageWindow(
                title: "Duplicate",
                usedPercent: 90,
                resetsAt: now.addingTimeInterval(1_200),
                windowMinutes: 10_080,
                identifier: "same-metric"
            ),
            availableResetCount: 0,
            resetCredits: [
                ResetCredit(
                    id: "credit",
                    expiresAt: now.addingTimeInterval(300),
                    status: "available"
                )
            ],
            fetchedAt: now,
            extraWindows: [
                UsageWindow(
                    title: "Expired",
                    usedPercent: 100,
                    resetsAt: now.addingTimeInterval(-1),
                    windowMinutes: nil,
                    identifier: "expired"
                )
            ]
        )

        let targets = MacStatusTarget.targets(
            accounts: [account],
            snapshots: [account.id: snapshot],
            settings: [:],
            now: now
        )

        XCTAssertEqual(targets.count, 2)
        XCTAssertEqual(targets.map(\.title), ["Banked resets", "5h limit"])
        XCTAssertEqual(targets.first?.valueLabel, "1 available")
        XCTAssertEqual(targets.last?.valueLabel, "75% left")
        XCTAssertEqual(
            MacUsagePresentation.availableResetCount(in: snapshot, after: now),
            1
        )

        var expiredSnapshot = snapshot
        expiredSnapshot.availableResetCount = 0
        expiredSnapshot.resetCredits[0].expiresAt = now.addingTimeInterval(-1)
        XCTAssertEqual(
            MacUsagePresentation.availableResetCount(in: expiredSnapshot, after: now),
            0
        )
    }

    func testMacStatusTargetsRespectVisibilityAndUseDeterministicTieBreaks() {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let resetDate = now.addingTimeInterval(600)
        let first = MonitoredAccount(
            id: UUID(uuidString: "00000000-0000-4000-8000-000000000001")!,
            providerID: .claude,
            displayName: "Same name",
            workspaceID: "first",
            plan: nil,
            addedAt: now
        )
        let second = MonitoredAccount(
            id: UUID(uuidString: "00000000-0000-4000-8000-000000000002")!,
            providerID: .claude,
            displayName: "Same name",
            workspaceID: "second",
            plan: nil,
            addedAt: now
        )
        func snapshot(for account: MonitoredAccount) -> UsageSnapshot {
            UsageSnapshot(
                accountID: account.id,
                providerName: account.providerID.displayName,
                accountName: account.displayName,
                accountProviderID: account.providerID,
                plan: nil,
                primary: UsageWindow(
                    title: "Quota",
                    usedPercent: 50,
                    resetsAt: resetDate,
                    windowMinutes: nil,
                    identifier: "quota"
                ),
                secondary: nil,
                availableResetCount: 0,
                resetCredits: [],
                fetchedAt: now
            )
        }

        let ordered = MacStatusTarget.targets(
            accounts: [second, first],
            snapshots: [first.id: snapshot(for: first), second.id: snapshot(for: second)],
            settings: [:],
            now: now
        )
        XCTAssertEqual(ordered.map(\.id), [
            "\(first.id.uuidString):quota",
            "\(second.id.uuidString):quota"
        ])

        let hidden = MacStatusTarget.targets(
            accounts: [first],
            snapshots: [first.id: snapshot(for: first)],
            settings: [first.id: AccountMonitorSettings(hiddenMetricIDs: ["quota"])],
            now: now
        )
        XCTAssertTrue(hidden.isEmpty)
    }

    func testPeriodicRefreshPolicyTracksIntervalsSettingsAndClockChanges() {
        let start = Date(timeIntervalSince1970: 2_000_000_000)
        var policy = PeriodicRefreshPolicy(startingAt: start)

        XCTAssertFalse(policy.shouldRefresh(
            at: start.addingTimeInterval(299),
            interval: .fiveMinutes
        ))
        XCTAssertTrue(policy.shouldRefresh(
            at: start.addingTimeInterval(300),
            interval: .fiveMinutes
        ))

        policy.recordRefresh(at: start.addingTimeInterval(450))
        XCTAssertFalse(policy.shouldRefresh(
            at: start.addingTimeInterval(749),
            interval: .fiveMinutes
        ))
        XCTAssertTrue(policy.shouldRefresh(
            at: start.addingTimeInterval(750),
            interval: .fiveMinutes
        ))

        XCTAssertFalse(policy.shouldRefresh(
            at: start.addingTimeInterval(900),
            interval: .off
        ))
        XCTAssertFalse(policy.shouldRefresh(
            at: start.addingTimeInterval(899),
            interval: .fiveMinutes
        ))
        XCTAssertEqual(policy.lastAttempt, start.addingTimeInterval(899))
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

final class MacUsageHistoryPresentationTests: XCTestCase {
    func testWorkerHistoryFetchScopesChooseIncrementalOrFullRetentionStart() {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let latest = now.addingTimeInterval(-3_600)
        let retainedStart = now.addingTimeInterval(-UsageHistoryStore.retentionInterval)

        XCTAssertEqual(
            WorkerHistoryFetchScope.incremental.startDate(
                now: now,
                latestServerPoint: latest,
                retentionInterval: UsageHistoryStore.retentionInterval
            ),
            latest.addingTimeInterval(-60)
        )
        XCTAssertEqual(
            WorkerHistoryFetchScope.retainedHistory.startDate(
                now: now,
                latestServerPoint: latest,
                retentionInterval: UsageHistoryStore.retentionInterval
            ),
            retainedStart
        )
        XCTAssertEqual(
            WorkerHistoryFetchScope.incremental.startDate(
                now: now,
                latestServerPoint: nil,
                retentionInterval: UsageHistoryStore.retentionInterval
            ),
            retainedStart
        )
    }

    func testSeriesCombinesLocalAndWorkerSamplesWithoutLosingTheirSource() throws {
        let accountID = UUID()
        let start = Date(timeIntervalSince1970: 2_000_000_000)
        let points = [
            point(accountID: accountID, recordedAt: start, remaining: 90, source: .manual),
            point(accountID: accountID, recordedAt: start.addingTimeInterval(300),
                  remaining: 82, source: .server),
            point(accountID: accountID, recordedAt: start.addingTimeInterval(600),
                  remaining: 75, source: .background),
        ]

        let series = try XCTUnwrap(MacUsageHistoryPresentation.series(
            points: points,
            accountID: accountID,
            in: start...start.addingTimeInterval(600)
        ).first)

        XCTAssertEqual(series.points.count, 3)
        XCTAssertEqual(series.deviceSampleCount, 2)
        XCTAssertEqual(series.workerSampleCount, 1)
        XCTAssertTrue(series.includesDeviceSamples)
        XCTAssertTrue(series.includesWorkerSamples)
        XCTAssertEqual(Set(series.chartPoints.map(\.sampleSource)), [.device, .worker])
        XCTAssertEqual(Set(series.chartPoints.map(\.segmentID)).count, 1)
        XCTAssertFalse(series.chartPoints.contains(where: \.isGapConnector))
    }

    func testOnlyGapsLongerThanOneHourUseDashedConnectors() throws {
        let accountID = UUID()
        let start = Date(timeIntervalSince1970: 2_000_000_000)
        let oneHour = start.addingTimeInterval(60 * 60)
        let afterLongGap = oneHour.addingTimeInterval(60 * 60 + 1)
        let points = [
            point(accountID: accountID, recordedAt: start, remaining: 90, source: .manual),
            point(accountID: accountID, recordedAt: oneHour, remaining: 80, source: .server),
            point(accountID: accountID, recordedAt: afterLongGap,
                  remaining: 70, source: .background),
        ]

        let series = try XCTUnwrap(MacUsageHistoryPresentation.series(
            points: points,
            accountID: accountID,
            in: start...afterLongGap
        ).first)
        let dashed = series.chartPoints.filter(\.isGapConnector)
        let solid = series.chartPoints.filter { !$0.isGapConnector }

        XCTAssertEqual(dashed.map(\.point.recordedAt), [oneHour, afterLongGap])
        XCTAssertEqual(Set(dashed.map(\.segmentID)).count, 1)
        XCTAssertEqual(solid.map(\.point.recordedAt), [start, oneHour, afterLongGap])
        XCTAssertEqual(solid[0].segmentID, solid[1].segmentID)
        XCTAssertNotEqual(solid[1].segmentID, solid[2].segmentID)
    }

    func testDownsamplingDoesNotTurnContinuousHistoryIntoDashedGaps() {
        let accountID = UUID()
        let start = Date(timeIntervalSince1970: 2_000_000_000)
        var points: [UsageHistoryPoint] = []
        for index in 0...(7 * 24 * 12) {
            points.append(point(
                accountID: accountID,
                recordedAt: start.addingTimeInterval(TimeInterval(index * 5 * 60)),
                remaining: 100 - Double(index % 100),
                source: .manual
            ))
        }

        let chartPoints = UsageHistoryLineSegmentation.downsampledChartPoints(
            from: points,
            seriesID: "weekly",
            maximumSolidPoints: 80
        )

        XCTAssertLessThanOrEqual(chartPoints.count, 82)
        XCTAssertFalse(chartPoints.contains { $0.isGapConnector })
        XCTAssertEqual(chartPoints.first?.point.recordedAt, points.first?.recordedAt)
        XCTAssertEqual(chartPoints.last?.point.recordedAt, points.last?.recordedAt)
    }

    func testDownsamplingRetainsRealGapConnector() {
        let accountID = UUID()
        let start = Date(timeIntervalSince1970: 2_000_000_000)
        var points = (0..<100).map { index in
            point(accountID: accountID,
                  recordedAt: start.addingTimeInterval(TimeInterval(index * 5 * 60)),
                  remaining: 90,
                  source: .manual)
        }
        let secondStart = points.last!.recordedAt.addingTimeInterval(60 * 60 + 1)
        points.append(contentsOf: (0..<100).map { index in
            point(accountID: accountID,
                  recordedAt: secondStart.addingTimeInterval(TimeInterval(index * 5 * 60)),
                  remaining: 70,
                  source: .server)
        })

        let chartPoints = UsageHistoryLineSegmentation.downsampledChartPoints(
            from: points,
            seriesID: "weekly",
            maximumSolidPoints: 40
        )
        let gap = chartPoints.filter(\.isGapConnector)

        XCTAssertEqual(gap.count, 2)
        XCTAssertEqual(gap.first?.point.recordedAt, points[99].recordedAt)
        XCTAssertEqual(gap.last?.point.recordedAt, points[100].recordedAt)
    }

    func testArbitraryDateRangeIsPreservedAndClampedToAvailableHistory() throws {
        let accountID = UUID()
        let end = Date(timeIntervalSince1970: 2_000_000_000)
        let beginning = end.addingTimeInterval(-20 * 24 * 60 * 60)
        let points = [
            point(accountID: accountID, recordedAt: beginning, remaining: 95, source: .manual),
            point(accountID: accountID, recordedAt: end, remaining: 55, source: .server),
        ]
        let available = try XCTUnwrap(MacUsageHistoryPresentation.availableRange(
            points: points,
            accountID: accountID
        ))

        let arbitraryStart = end.addingTimeInterval(-12 * 24 * 60 * 60 - 1_337)
        let arbitraryEnd = end.addingTimeInterval(-2 * 24 * 60 * 60 - 913)
        let arbitrary = MacUsageHistoryPresentation.normalizedRange(
            start: arbitraryStart,
            end: arbitraryEnd,
            within: available
        )
        XCTAssertEqual(arbitrary.lowerBound, arbitraryStart)
        XCTAssertEqual(arbitrary.upperBound, arbitraryEnd)

        let clamped = MacUsageHistoryPresentation.normalizedRange(
            start: beginning.addingTimeInterval(-86_400),
            end: end.addingTimeInterval(86_400),
            within: available
        )
        XCTAssertEqual(clamped, available)
    }

    func testDefaultRangeEndsAtLatestSampleAndSeriesHonorsSelection() throws {
        let accountID = UUID()
        let latest = Date(timeIntervalSince1970: 2_000_000_000)
        let old = latest.addingTimeInterval(-10 * 24 * 60 * 60)
        let recent = latest.addingTimeInterval(-2 * 24 * 60 * 60)
        let points = [
            point(accountID: accountID, recordedAt: old, remaining: 96, source: .manual),
            point(accountID: accountID, recordedAt: recent, remaining: 68, source: .server),
            point(accountID: accountID, recordedAt: latest, remaining: 51, source: .server),
        ]
        let available = try XCTUnwrap(MacUsageHistoryPresentation.availableRange(
            points: points,
            accountID: accountID
        ))
        let selected = MacUsageHistoryPresentation.defaultRange(within: available)
        let series = try XCTUnwrap(MacUsageHistoryPresentation.series(
            points: points,
            accountID: accountID,
            in: selected
        ).first)

        XCTAssertEqual(selected.upperBound, latest)
        XCTAssertEqual(selected.lowerBound, latest.addingTimeInterval(-7 * 24 * 60 * 60))
        XCTAssertEqual(series.points.map(\.recordedAt), [recent, latest])
    }

    func testCodexCLICredentialParserReadsChatGPTAuthSchema() throws {
        let data = try JSONSerialization.data(withJSONObject: [
            "auth_mode": "chatgpt",
            "last_refresh": "2030-01-02T03:04:05.678Z",
            "tokens": [
                "access_token": "codex-access-placeholder",
                "account_id": "account-123",
                "id_token": "codex-id-placeholder",
                "refresh_token": "codex-refresh-placeholder"
            ]
        ])

        let parsed = try CodexCLICredentialParser.parse(data)

        XCTAssertEqual(parsed.accountID, "account-123")
        XCTAssertEqual(
            parsed.lastRefresh.timeIntervalSince1970,
            ISO8601DateFormatter().date(from: "2030-01-02T03:04:05Z")!
                .addingTimeInterval(0.678).timeIntervalSince1970,
            accuracy: 0.001
        )
        XCTAssertEqual(parsed.credentials.accessToken, "codex-access-placeholder")
        XCTAssertEqual(parsed.credentials.idToken, "codex-id-placeholder")
        XCTAssertEqual(parsed.credentials.refreshToken, "codex-refresh-placeholder")
    }

    func testCodexCLICredentialParserRejectsOtherAuthModesWithoutLeakingValues() throws {
        let sensitivePlaceholder = "credential-value-must-not-appear"
        let data = try JSONSerialization.data(withJSONObject: [
            "auth_mode": "apikey",
            "last_refresh": "2030-01-02T03:04:05Z",
            "tokens": [
                "access_token": sensitivePlaceholder,
                "account_id": "account-123",
                "id_token": sensitivePlaceholder,
                "refresh_token": sensitivePlaceholder
            ]
        ])

        XCTAssertThrowsError(try CodexCLICredentialParser.parse(data)) { error in
            XCTAssertEqual(
                error as? LocalCLICredentialImportError,
                .invalidCredential(.codex)
            )
            XCTAssertFalse(error.localizedDescription.contains(sensitivePlaceholder))
        }
    }

    func testClaudeCodeCredentialParserReadsKeychainSchemaAndMilliseconds() throws {
        let data = try JSONSerialization.data(withJSONObject: [
            "claudeAiOauth": [
                "accessToken": "claude-access-placeholder",
                "refreshToken": "claude-refresh-placeholder",
                "expiresAt": 2_000_000_000_000,
                "subscriptionType": "max",
                "rateLimitTier": "default_claude_max_20x",
                "scopes": ["user:profile", "user:inference"]
            ]
        ])

        let parsed = try ClaudeCodeCredentialParser.parse(data)

        XCTAssertEqual(
            LocalCLICredentialRuntime.claudeCodeKeychainService,
            "Claude Code-credentials"
        )
        XCTAssertEqual(parsed.credentials.accessToken, "claude-access-placeholder")
        XCTAssertEqual(parsed.credentials.refreshToken, "claude-refresh-placeholder")
        XCTAssertEqual(parsed.credentials.expiresAt, Date(timeIntervalSince1970: 2_000_000_000))
        XCTAssertEqual(parsed.subscriptionType, "max")
        XCTAssertEqual(parsed.rateLimitTier, "default_claude_max_20x")
        XCTAssertEqual(parsed.scopes, ["user:profile", "user:inference"])
        XCTAssertEqual(parsed.planHint, "Claude Max 20x")
    }

    func testLocalCLICredentialCapabilityReportsRuntimeRestrictions() {
        let sandboxed = LocalCLICredentialCapabilityPolicy.capability(
            source: .codex,
            isMacOS: true,
            isSandboxed: true,
            resourceAccess: .available
        )
        XCTAssertFalse(sandboxed.isAvailable)
        XCTAssertEqual(sandboxed.unavailableReason, .sandboxed)

        let inaccessible = LocalCLICredentialCapabilityPolicy.capability(
            source: .claudeCode,
            isMacOS: true,
            isSandboxed: false,
            resourceAccess: .inaccessible
        )
        XCTAssertFalse(inaccessible.isAvailable)
        XCTAssertEqual(inaccessible.unavailableReason, .inaccessible)

        let unsupported = LocalCLICredentialCapabilityPolicy.capability(
            source: .codex,
            isMacOS: false,
            isSandboxed: false,
            resourceAccess: .available
        )
        XCTAssertFalse(unsupported.isAvailable)
        XCTAssertEqual(unsupported.unavailableReason, .unsupportedPlatform)

        let available = LocalCLICredentialCapabilityPolicy.capability(
            source: .codex,
            isMacOS: true,
            isSandboxed: false,
            resourceAccess: .available
        )
        XCTAssertTrue(available.isAvailable)
        XCTAssertNil(available.unavailableReason)
    }

    func testLocalCLIImportOnlyReplacesWorkerCredentialForMatchedMonitoredAccount() {
        XCTAssertTrue(LocalCLICredentialImportPolicy.requiresWorkerCredentialReplacement(
            deduplicatedExistingAccount: true,
            existingAccountUsesWorkerMonitoring: true
        ))
        XCTAssertFalse(LocalCLICredentialImportPolicy.requiresWorkerCredentialReplacement(
            deduplicatedExistingAccount: false,
            existingAccountUsesWorkerMonitoring: true
        ))
        XCTAssertFalse(LocalCLICredentialImportPolicy.requiresWorkerCredentialReplacement(
            deduplicatedExistingAccount: true,
            existingAccountUsesWorkerMonitoring: false
        ))
    }

    private func point(
        accountID: UUID,
        recordedAt: Date,
        remaining: Double,
        source: UsageRefreshSource
    ) -> UsageHistoryPoint {
        UsageHistoryPoint(
            accountID: accountID,
            providerID: .chatGPT,
            metricID: "weekly",
            metricTitle: "Weekly limit",
            kind: .weekly,
            windowMinutes: 10_080,
            remainingPercent: remaining,
            recordedAt: recordedAt,
            resetsAt: recordedAt.addingTimeInterval(7 * 24 * 60 * 60),
            secondsUntilReset: 7 * 24 * 60 * 60,
            source: source,
            plan: "Pro"
        )
    }
}
