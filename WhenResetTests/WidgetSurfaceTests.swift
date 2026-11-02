import XCTest
@testable import WhenReset

final class WidgetSurfaceTests: XCTestCase {
    func testHomeLockScreenAndLiveActivityCoverCodingPlanProviders() throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let snapshots = [
            codingSnapshot(.chatGPT, name: "Codex", primary: "chatgpt:five_hour",
                           secondary: "chatgpt:weekly", now: now),
            codingSnapshot(.kimi, name: "Kimi", primary: "kimi:five_hour",
                           secondary: "kimi:weekly", now: now),
            try zaiSnapshot(now: now, provider: .zai),
            try zaiSnapshot(now: now, provider: .zhipu),
            try grokSnapshot(now: now),
        ]

        XCTAssertEqual(snapshots.map(\.accountProviderID), WidgetSurface.codingPlanProviders)
        XCTAssertEqual(WidgetSurface.homeFamilies, ["systemSmall", "systemMedium", "systemLarge"])
        XCTAssertEqual(WidgetSurface.lockFamilies, [
            "accessoryCircular", "accessoryRectangular", "accessoryInline",
        ])

        for snapshot in snapshots {
            let provider = try XCTUnwrap(snapshot.accountProviderID)
            XCTAssertTrue(WidgetSurface.supportsHomeLockScreenAndLiveActivity(provider, snapshot: snapshot))
            let metrics = WidgetSurface.metrics(for: snapshot, after: now)
            XCTAssertFalse(metrics.isEmpty)
            XCTAssertTrue(metrics.allSatisfy { $0.expiresAt.map { $0 > now } ?? false })
            XCTAssertNotNil(provider.logoAssetName)
#if os(iOS)
            let activity = UsageActivityTarget(
                id: "\(provider.rawValue):\(metrics[0].metricID)",
                kind: .quota,
                accountName: snapshot.resolvedAccountName,
                accountSymbolName: provider.systemImageName,
                providerID: provider,
                title: metrics[0].title,
                remainingPercent: metrics[0].remainingPercent,
                expiresAt: try XCTUnwrap(metrics[0].expiresAt)
            )
            XCTAssertEqual(activity.providerID, provider)
            XCTAssertGreaterThan(activity.expiresAt, now)
#endif
        }
    }

    private func codingSnapshot(
        _ provider: ProviderID,
        name: String,
        primary: String,
        secondary: String,
        now: Date
    ) -> UsageSnapshot {
        UsageSnapshot(
            accountID: UUID(),
            providerName: provider.displayName,
            accountName: name,
            accountProviderID: provider,
            plan: "Coding",
            primary: UsageWindow(title: "5h limit", usedPercent: 20,
                                 resetsAt: now.addingTimeInterval(3_600), windowMinutes: 300,
                                 kind: .fiveHour, identifier: primary),
            secondary: UsageWindow(title: "Weekly limit", usedPercent: 40,
                                   resetsAt: now.addingTimeInterval(86_400), windowMinutes: 10_080,
                                   kind: .weekly, identifier: secondary),
            availableResetCount: provider == .chatGPT ? 1 : 0,
            resetCredits: provider == .chatGPT ? [
                ResetCredit(id: "banked", expiresAt: now.addingTimeInterval(7_200), status: "available")
            ] : [],
            fetchedAt: now
        )
    }

    private func zaiSnapshot(now: Date, provider: ProviderID) throws -> UsageSnapshot {
        let data = Data(#"""
        {
          "code": 200,
          "success": true,
          "data": {
            "planName": "GLM Coding Plan",
            "limits": [{
              "type": "TOKENS_LIMIT",
              "unit": 3,
              "number": 5,
              "usage": 100,
              "remaining": 300,
              "nextResetTime": 1800000000000
            }]
          }
        }
        """#.utf8)
        let account = MonitoredAccount(id: UUID(), providerID: provider, displayName: provider.displayName,
                                       workspaceID: "zai-widget", plan: nil, addedAt: now)
        return try ZAIProvider.parseUsage(account: account, data: data, now: now)
    }

    private func grokSnapshot(now: Date) throws -> UsageSnapshot {
        let data = Data(#"""
        {
          "config": {
            "creditUsagePercent": 12,
            "currentPeriod": {
              "start": "2030-01-01T00:00:00Z",
              "end": "2030-01-08T00:00:00Z"
            }
          }
        }
        """#.utf8)
        return try GrokProvider.parseUsage(
            account: MonitoredAccount(id: UUID(), providerID: .grok, displayName: "Grok",
                                      workspaceID: "grok-widget", plan: "SuperGrok", addedAt: now),
            data: data,
            now: now
        )
    }
}
