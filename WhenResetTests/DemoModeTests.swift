import XCTest
@testable import WhenReset

final class DemoModeTests: XCTestCase {
    func testDemoSnapshotContainsAllChatGPTReviewContent() throws {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let account = MonitoredAccount(
            id: UUID(),
            providerID: .chatGPT,
            displayName: "Demo account",
            workspaceID: MonitoredAccount.demoWorkspaceID,
            plan: "Pro · Demo",
            addedAt: now
        )
        var generator = SeededGenerator(seed: 42)

        let snapshot = DemoUsageFactory.snapshot(for: account, at: now, using: &generator)

        XCTAssertTrue(account.isDemo)
        XCTAssertEqual(snapshot.accountID, account.id)
        XCTAssertEqual(snapshot.providerName, "ChatGPT")
        XCTAssertEqual(snapshot.usageWindows.map(\.displayTitle), ["5h limit", "Weekly limit", "GPT-5.3-Codex-Spark"])
        XCTAssertTrue(snapshot.usageWindows.allSatisfy { (0...100).contains($0.usedPercent) })
        XCTAssertTrue((2...4).contains(snapshot.availableResetCount))
        XCTAssertEqual(snapshot.availableResetCredits.count, snapshot.availableResetCount)
        XCTAssertTrue(snapshot.availableResetCredits.allSatisfy { ($0.expiresAt ?? .distantPast) > now })
        XCTAssertLessThanOrEqual(try XCTUnwrap(snapshot.primary?.resetsAt).timeIntervalSince(now), 4 * 3_600)
    }

    func testDefaultLiveActivityStartsAutomaticallyWithinFourHours() {
        let settings = GlobalLiveActivitySettings()
        XCTAssertEqual(settings.mode, .nearReset)
        XCTAssertEqual(settings.nearResetMinutes, 240)
    }

    func testProviderSectionTitleIncludesAvailablePlan() {
        XCTAssertEqual(ProviderID.chatGPT.sectionTitle(plan: "pro"), "ChatGPT Pro 5x")
        XCTAssertEqual(ProviderID.chatGPT.sectionTitle(plan: nil), "ChatGPT")
        XCTAssertEqual(ProviderID.claude.sectionTitle(plan: "max"), "Claude Max")
        XCTAssertEqual(ProviderID.githubCopilot.sectionTitle(plan: "Individual Pro"), "GitHub Copilot Individual Pro")
    }
}

private struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func next() -> UInt64 {
        state = state &* 6_364_136_223_846_793_005 &+ 1
        return state
    }
}
