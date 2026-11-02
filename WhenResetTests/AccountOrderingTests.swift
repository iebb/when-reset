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
}
