import XCTest
import UIKit
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
        XCTAssertEqual(settings.mode, .automatic)
        XCTAssertTrue(settings.showRemainingPercentage)
        XCTAssertTrue(settings.showBankedResets)
        XCTAssertEqual(AccountMonitorSettings().defaultLiveActivityRule.remainingHours, 4)
    }

    func testProviderSectionTitleIncludesAvailablePlan() {
        XCTAssertEqual(ProviderID.chatGPT.sectionTitle(plan: "pro"), "ChatGPT Pro")
        XCTAssertEqual(ProviderID.chatGPT.sectionTitle(plan: "pro_20x"), "ChatGPT Pro 20x")
        XCTAssertEqual(ProviderID.chatGPT.sectionTitle(plan: nil), "ChatGPT")
        XCTAssertEqual(ProviderID.claude.sectionTitle(plan: "max"), "Claude Max")
        XCTAssertEqual(ProviderID.githubCopilot.sectionTitle(plan: "Individual Pro"), "GitHub Copilot Individual Pro")
    }

    func testCustomAccountPresentationFallsBackToProviderIdentity() throws {
        var account = MonitoredAccount(id: UUID(), providerID: .chatGPT, displayName: "person@example.com",
                                       workspaceID: "workspace", plan: "pro_20x", addedAt: .now)
        XCTAssertEqual(account.resolvedDisplayName, "person@example.com")

        account.customDisplayName = "Work account"
        account.customSymbolName = "briefcase.fill"
        XCTAssertEqual(account.resolvedDisplayName, "Work account")

        let decoded = try JSONDecoder().decode(MonitoredAccount.self,
                                               from: JSONEncoder().encode(account))
        XCTAssertEqual(decoded.customDisplayName, "Work account")
        XCTAssertEqual(decoded.customSymbolName, "briefcase.fill")
    }

    func testFullSFSymbolCatalogIsBundled() throws {
        let data = try XCTUnwrap(NSDataAsset(name: "SFSymbolNames")?.data)
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let symbols = try XCTUnwrap(root["symbols"] as? [[String: Any]])
        let names = Set(symbols.compactMap { $0["name"] as? String })

        XCTAssertGreaterThan(symbols.count, 9_000)
        XCTAssertEqual(names.count, symbols.count)
        XCTAssertTrue(names.isSuperset(of: ["clock", "person.crop.circle", "sparkles"]))
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
