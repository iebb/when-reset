import XCTest
@testable import WhenReset

final class AccountOrderingTests: XCTestCase {
    func testFreshOrderGroupsByProvider() {
        let chatgpt = account(.chatGPT, name: "Later", at: 20)
        let kimi = account(.kimi, name: "Kimi", at: 5)
        let second = account(.chatGPT, name: "Earlier", at: 10)
        let ordered = AccountOrdering.grouped([chatgpt, kimi, second])
        XCTAssertEqual(ordered.map(\.displayName), ["Earlier", "Later", "Kimi"])
    }

    func testNewAccountInsertsAfterTheProvidersLastRow() {
        let first = account(.chatGPT, name: "One", at: 1)
        let kimi = account(.kimi, name: "Kimi", at: 2)
        let second = account(.chatGPT, name: "Two", at: 3)
        let ordered = AccountOrdering.inserting(second, into: [first, kimi])
        XCTAssertEqual(ordered.map(\.displayName), ["One", "Two", "Kimi"])
    }

    func testCustomOrderKeepsInterleavingAndStillGroupsANewSibling() {
        let first = account(.chatGPT, name: "One", at: 1)
        let kimi = account(.kimi, name: "Kimi", at: 2)
        let other = account(.grok, name: "Grok", at: 3)
        let second = account(.chatGPT, name: "Two", at: 4)
        let custom = AccountOrdering.apply(customIDs: [first.id, kimi.id, other.id], to: [first, kimi, other, second])
        XCTAssertEqual(custom.map(\.displayName), ["One", "Two", "Kimi", "Grok"])
    }

    func testCustomSortKeepsStoredOrderWhenOneAccountResetsSooner() {
        let later = account(.chatGPT, name: "Later", at: 1)
        let sooner = account(.kimi, name: "Sooner", at: 2)
        let now = Date(timeIntervalSince1970: 1_000)
        let snapshots = [
            later.id: snapshot(later, remaining: 90, resetsIn: 60, now: now),
            sooner.id: snapshot(sooner, remaining: 10, resetsIn: 10, now: now),
        ]
        let displayed = AccountOrdering.displayed(
            [later, sooner], sort: .custom, snapshots: snapshots, now: now
        )
        XCTAssertEqual(displayed.map(\.id), [later.id, sooner.id])
    }

    func testRemainingSortPutsTheLowestPercentFirstAndKeepsTies() {
        let low = account(.chatGPT, name: "Low", at: 1)
        let tiedFirst = account(.kimi, name: "Tied first", at: 2)
        let tiedSecond = account(.grok, name: "Tied second", at: 3)
        let missing = account(.zai, name: "Missing", at: 4)
        let now = Date(timeIntervalSince1970: 1_000)
        let snapshots = [
            low.id: snapshot(low, remaining: 12, resetsIn: 500, now: now),
            tiedFirst.id: snapshot(tiedFirst, remaining: 40, resetsIn: 500, now: now),
            tiedSecond.id: snapshot(tiedSecond, remaining: 40, resetsIn: 20, now: now),
        ]
        let displayed = AccountOrdering.displayed(
            [tiedSecond, missing, tiedFirst, low],
            sort: .remaining,
            snapshots: snapshots,
            now: now
        )
        XCTAssertEqual(displayed.map(\.displayName), ["Low", "Tied second", "Tied first", "Missing"])
    }

    func testSoonestResetSortPutsTheNextCountdownFirst() {
        let later = account(.chatGPT, name: "Later", at: 1)
        let sooner = account(.kimi, name: "Sooner", at: 2)
        let quiet = account(.grok, name: "Quiet", at: 3)
        let past = account(.zai, name: "Past", at: 4)
        let now = Date(timeIntervalSince1970: 1_000)
        let snapshots = [
            later.id: snapshot(later, remaining: 5, resetsIn: 400, now: now),
            sooner.id: snapshot(sooner, remaining: 90, resetsIn: 30, now: now),
            quiet.id: snapshot(quiet, remaining: 50, resetsIn: nil, now: now),
            past.id: snapshot(past, remaining: 50, resetsIn: -10, now: now),
        ]
        let displayed = AccountOrdering.displayed(
            [later, quiet, past, sooner],
            sort: .soonestReset,
            snapshots: snapshots,
            now: now
        )
        XCTAssertEqual(displayed.map(\.displayName), ["Sooner", "Later", "Quiet", "Past"])
    }

    func testMainlandAccountMigratesToZhipu() {
        var account = account(.zai, name: "智谱 GLM", at: 1)
        let migrated = ZhipuAccountMigration.migrate(
            account,
            region: "mainland",
            host: "https://open.bigmodel.cn/api/monitor/usage/quota/limit"
        )
        XCTAssertEqual(migrated.providerID, .zhipu)
        XCTAssertEqual(migrated.displayName, "智谱")
        account.displayName = "Work"
        let kept = ZhipuAccountMigration.migrate(account, region: "mainland", host: "https://open.bigmodel.cn")
        XCTAssertEqual(kept.displayName, "Work")
        let global = ZhipuAccountMigration.migrate(
            self.account(.zai, name: "智谱 GLM", at: 2),
            region: "global",
            host: nil
        )
        XCTAssertEqual(global.providerID, .zai)
        XCTAssertEqual(global.displayName, "z.ai")
    }

    private func account(_ provider: ProviderID, name: String, at time: TimeInterval) -> MonitoredAccount {
        MonitoredAccount(id: UUID(), providerID: provider, displayName: name, workspaceID: name,
                         plan: nil, addedAt: Date(timeIntervalSince1970: time))
    }

    private func snapshot(
        _ account: MonitoredAccount,
        remaining: Double,
        resetsIn: TimeInterval?,
        now: Date
    ) -> UsageSnapshot {
        UsageSnapshot(
            accountID: account.id,
            providerName: account.providerID.displayName,
            accountName: account.displayName,
            accountProviderID: account.providerID,
            plan: nil,
            primary: UsageWindow(
                title: "Weekly limit",
                usedPercent: 100 - remaining,
                resetsAt: now.addingTimeInterval(resetsIn ?? 3_600),
                windowMinutes: 10_080,
                kind: .weekly,
                identifier: "weekly",
                reportsReset: resetsIn != nil
            ),
            secondary: nil,
            availableResetCount: 0,
            resetCredits: [],
            fetchedAt: now
        )
    }
}
