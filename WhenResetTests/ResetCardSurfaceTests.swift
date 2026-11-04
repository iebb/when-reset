import XCTest
@testable import WhenReset

final class ResetCardSurfaceTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    override func tearDown() {
        AppLanguage.choose(.system)
        super.tearDown()
    }

    func testSquareWidgetKeepsCustomOrderAndCapsAtFour() {
        let ordered = (0..<6).map { make(count: $0 == 0 || $0 == 3 ? 1 : 0, credits: [], name: "A\($0)") }
        XCTAssertEqual(SmallSquareAccounts.visible(ordered, limit: 4).map(\.accountName), ["A0", "A1", "A2", "A3"])
        XCTAssertEqual(SmallSquareAccounts.visible(ordered, limit: 2).map(\.accountName), ["A0", "A1"])
        XCTAssertEqual(SmallSquareAccounts.visible(ordered, limit: 1).map(\.accountName), ["A0"])
        XCTAssertEqual(SmallSquareAccounts.visible(Array(ordered.prefix(2)), limit: 4).map(\.accountName), ["A0", "A1"])
        XCTAssertEqual(SmallSquareAccounts.visible(ordered, limit: 99).count, 4)
    }

    func testPercentBasisDefaultsToRemainingAndInvertsTheNumberAndFill() {
        let previous = QuotaPercentBasis.current
        defer { QuotaPercentBasis.choose(previous) }
        QuotaPercentBasis.choose(.remaining)
        XCTAssertEqual(QuotaPercentBasis.current, .remaining)
        XCTAssertEqual(QuotaPercentBasis.remaining.displayed(remainingPercent: 75), 75)
        XCTAssertEqual(QuotaPercentBasis.remaining.figure(remainingPercent: 75), "75%")
        XCTAssertEqual(QuotaPercentBasis.remaining.fillFraction(remainingFraction: 0.75), 0.75)
        QuotaPercentBasis.choose(.used)
        XCTAssertEqual(QuotaPercentBasis.current, .used)
        XCTAssertEqual(QuotaPercentBasis.used.displayed(remainingPercent: 75.4), 25)
        XCTAssertEqual(QuotaPercentBasis.used.figure(remainingPercent: 75), "25%")
        XCTAssertEqual(QuotaPercentBasis.used.fillFraction(remainingFraction: 0.75), 0.25, accuracy: 0.001)
        XCTAssertEqual(UsageText.widgetFigure(80), "20%")
        AppLanguage.choose(.chineseSimplified)
        XCTAssertEqual(ResetCardSurface.compactBadge(count: 1), "卡×1")
        XCTAssertFalse(UsageText.widgetFigure(75).contains("剩余"))
        XCTAssertFalse(UsageText.widgetFigure(75).contains("已用"))
        XCTAssertEqual(QuotaPercentBasis.used.labeled(remainingPercent: 75), "已用 25%")
    }

    func testZeroCardsAreAbsent() {
        let snapshot = make(count: 0, credits: [])
        XCTAssertNil(ResetCardSurface.fact(snapshot: snapshot, now: now))
        XCTAssertNil(ResetCardSurface.fact(snapshot: snapshot, now: now, included: true))
    }

    func testHiddenSwitchOmitsCardsThatExist() {
        let snapshot = make(count: 2, credits: [credit("a", hours: 5)])
        XCTAssertNil(ResetCardSurface.fact(snapshot: snapshot, now: now, included: false))
        XCTAssertEqual(ResetCardSurface.fact(snapshot: snapshot, now: now)?.count, 2)
    }

    func testCountUsesTheLargerOfTheCounterAndTheCredits() {
        let snapshot = make(count: 1, credits: [credit("a", hours: 5), credit("b", hours: 20)])
        XCTAssertEqual(ResetCardSurface.fact(snapshot: snapshot, now: now)?.count, 2)
        let countOnly = make(count: 3, credits: [])
        XCTAssertEqual(ResetCardSurface.fact(snapshot: countOnly, now: now)?.count, 3)
        XCTAssertNil(ResetCardSurface.fact(snapshot: countOnly, now: now)?.expiresAt)
    }

    func testSoonestFutureExpiryIgnoresEarlierSpentCards() {
        let snapshot = make(count: 0, credits: [
            credit("later", hours: 20),
            credit("past", hours: -1),
            credit("soon", hours: 2),
            ResetCredit(id: "used", expiresAt: now.addingTimeInterval(60), status: "used"),
        ])
        let fact = ResetCardSurface.fact(snapshot: snapshot, now: now)
        XCTAssertEqual(fact?.count, 3)
        XCTAssertEqual(fact?.expiresAt, now.addingTimeInterval(2 * 3_600))
    }

    func testIndicatorsKeepTheGivenAccountOrder() {
        let ordered = [
            make(count: 0, credits: [], name: "First"),
            make(count: 2, credits: [credit("a", hours: 4)], name: "Second"),
            make(count: 1, credits: [credit("b", hours: 1)], name: "Third"),
        ]
        let facts = ResetCardSurface.facts(in: ordered, now: now)
        let counts: [Int?] = facts.map { $0?.count }
        XCTAssertEqual(ordered.map(\.accountName), ["First", "Second", "Third"])
        XCTAssertEqual(counts, [nil, 2, 1])
    }

    func testMediumDropsTheUsageTitleOnlyWhenACardNeedsTheRow() {
        let empty = [make(count: 0, credits: [])]
        let holding = [make(count: 1, credits: [credit("a", hours: 3)])]
        XCTAssertTrue(ResetCardSurface.showsUsageTitle(showsSecondLimit: false, snapshots: empty, now: now))
        XCTAssertFalse(ResetCardSurface.showsUsageTitle(showsSecondLimit: false, snapshots: holding, now: now))
        XCTAssertTrue(ResetCardSurface.showsUsageTitle(showsSecondLimit: true, snapshots: holding, now: now))
    }

    func testReloadWakesForTheEarliestCardBeforeTheQuota() {
        let soon = now.addingTimeInterval(120)
        let card = make(count: 1, credits: [
            ResetCredit(id: "a", expiresAt: soon, status: "available")
        ])
        let quota = now.addingTimeInterval(8 * 3_600)
        XCTAssertEqual(
            ResetCardSurface.reloadDate(targetExpiresAt: quota, snapshots: [card], now: now),
            soon.addingTimeInterval(1)
        )
        let quiet = make(count: 0, credits: [])
        XCTAssertEqual(
            ResetCardSurface.reloadDate(targetExpiresAt: quota, snapshots: [quiet], now: now),
            now.addingTimeInterval(15 * 60)
        )
        let urgentQuota = now.addingTimeInterval(30)
        XCTAssertEqual(
            ResetCardSurface.reloadDate(targetExpiresAt: urgentQuota, snapshots: [quiet], now: now),
            urgentQuota.addingTimeInterval(1)
        )
    }

    func testWordingMatchesTheUsageCardInBothLanguages() {
        let expiry = now.addingTimeInterval(4 * 3_600 + 59 * 60)
        AppLanguage.choose(.english)
        XCTAssertEqual(ResetCardSurface.name(count: 1), "1 reset card")
        XCTAssertEqual(ResetCardSurface.name(count: 2), "2 reset cards")
        XCTAssertEqual(ResetCardSurface.sectionLabel, "Reset cards")
        XCTAssertEqual(ResetCardSurface.countValue(count: 1), "1 available")
        XCTAssertEqual(
            ResetCardSurface.expiryPhrase(count: 1, expiresAt: expiry, now: now),
            "expires in 4h 59m"
        )
        XCTAssertEqual(
            ResetCardSurface.expiryPhrase(count: 2, expiresAt: expiry, now: now),
            "next expires in 4h 59m"
        )
        XCTAssertEqual(
            ResetCardSurface.roomyCopy(count: 1, expiresAt: expiry, now: now),
            ResetCardSurface.RoomyCopy(label: "1 reset card", value: "expires in 4h 59m")
        )
        XCTAssertFalse(ResetCardSurface.roomyCopy(count: 1, expiresAt: expiry, now: now).label.contains("$"))
        XCTAssertFalse(ResetCardSurface.name(count: 1).contains("已存储"))

        AppLanguage.choose(.chineseSimplified)
        XCTAssertEqual(ResetCardSurface.name(count: 1), "重置卡 1 张")
        XCTAssertEqual(ResetCardSurface.name(count: 2), "重置卡 2 张")
        XCTAssertEqual(ResetCardSurface.sectionLabel, "重置卡")
        XCTAssertEqual(ResetCardSurface.countValue(count: 1), "可用 1 张")
        XCTAssertEqual(
            ResetCardSurface.expiryPhrase(count: 1, expiresAt: expiry, now: now),
            "4 小时 59 分后过期"
        )
        XCTAssertEqual(
            ResetCardSurface.roomyCopy(count: 2, expiresAt: expiry, now: now),
            ResetCardSurface.RoomyCopy(label: "重置卡 2 张", value: "最近一个 4 小时 59 分后过期")
        )
        let chinese = ResetCardSurface.roomyCopy(count: 1, expiresAt: expiry, now: now)
        XCTAssertEqual(chinese.value, "4 小时 59 分后过期")
        XCTAssertFalse(chinese.label.contains("已存储"))
        XCTAssertFalse(chinese.label.contains("可用"))
        XCTAssertFalse(chinese.value?.contains("可用") ?? true)
        XCTAssertFalse(chinese.label.contains("$"))
        XCTAssertEqual(
            ResetCardSurface.name(count: 1),
            BankedResetCopy.collapsedLine(count: 1, expiresAt: nil, now: now)
        )
    }

    func testExpiredCardKeepsTheCountAndDropsThePhrase() {
        let snapshot = make(count: 1, credits: [credit("past", hours: -2)])
        let fact = ResetCardSurface.fact(snapshot: snapshot, now: now)
        XCTAssertEqual(fact?.count, 1)
        XCTAssertNil(fact?.expiresAt)
        AppLanguage.choose(.english)
        XCTAssertEqual(
            ResetCardSurface.roomyCopy(count: 1, expiresAt: nil, now: now),
            ResetCardSurface.RoomyCopy(label: "1 reset card", value: nil)
        )
    }

    func testRoomySurfacesUseTheFullNameAndCrowdedRowsStayShort() {
        let expiry = now.addingTimeInterval(5 * 3_600)
        AppLanguage.choose(.chineseSimplified)
        XCTAssertEqual(
            ResetCardSurface.roomyCopy(count: 1, expiresAt: expiry, now: now),
            ResetCardSurface.RoomyCopy(label: "重置卡 1 张", value: "5 小时后过期")
        )
        XCTAssertEqual(ResetCardSurface.roomyCopy(count: 4, expiresAt: expiry, now: now).label, "重置卡 4 张")
        XCTAssertEqual(ResetCardSurface.compactBadge(count: 1), "卡×1")
        XCTAssertEqual(ResetCardSurface.compactBadge(count: 4), "卡×4")
        XCTAssertNotEqual(ResetCardSurface.compactBadge(count: 1), ResetCardSurface.name(count: 1))

        AppLanguage.choose(.english)
        XCTAssertEqual(
            ResetCardSurface.roomyCopy(count: 2, expiresAt: expiry, now: now),
            ResetCardSurface.RoomyCopy(label: "2 reset cards", value: "next expires in 5h")
        )
        XCTAssertEqual(ResetCardSurface.compactBadge(count: 1), "×1")
    }

#if os(iOS)
    func testLegacyAccountRowDecodesWithoutResetCards() throws {
        struct LegacyRow: Encodable {
            var id = "account"
            var accountName = "Kong Yi"
            var providerID = ProviderID.chatGPT
            var headlineTitle = "5h limit"
            var headlineRemainingPercent = 40.0
            var isSoonestReset = true
        }
        let row = try JSONDecoder().decode(UsageActivityAccountRow.self, from: JSONEncoder().encode(LegacyRow()))
        XCTAssertEqual(row.resetCardCount, 0)
        XCTAssertNil(row.resetCardExpiresAt)
        XCTAssertTrue(row.isSoonestReset)
        XCTAssertEqual(row.accountName, "Kong Yi")
    }

    func testAccountRowRoundTripsResetCardsAndOmitsAZeroCount() throws {
        let expiry = now.addingTimeInterval(5 * 3_600)
        let row = UsageActivityAccountRow(
            id: "account",
            accountName: "Work",
            providerID: .chatGPT,
            symbolName: nil,
            headlineTitle: "5h limit",
            headlineRemainingPercent: 80,
            headlineResetsAt: expiry,
            resetCardCount: 2,
            resetCardExpiresAt: expiry
        )
        let data = try JSONEncoder().encode(row)
        let decoded = try JSONDecoder().decode(UsageActivityAccountRow.self, from: data)
        XCTAssertEqual(decoded.resetCardCount, 2)
        XCTAssertEqual(decoded.resetCardExpiresAt, expiry)

        var hidden = row
        hidden.resetCardCount = 0
        hidden.resetCardExpiresAt = expiry
        let hiddenData = try JSONEncoder().encode(hidden)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: hiddenData) as? [String: Any])
        XCTAssertNil(object["resetCardCount"])
        XCTAssertNil(object["resetCardExpiresAt"])
        let restored = try JSONDecoder().decode(UsageActivityAccountRow.self, from: hiddenData)
        XCTAssertEqual(restored.resetCardCount, 0)
        XCTAssertNil(restored.resetCardExpiresAt)
    }

    func testLiveActivityPayloadWithResetCardsStaysUnderTheActivityKitLimit() throws {
        let rows = (0..<4).map { index in
            UsageActivityAccountRow(
                id: "account-\(index)",
                accountName: "Account \(index)",
                providerID: .chatGPT,
                symbolName: nil,
                headlineTitle: "5h limit",
                headlineRemainingPercent: Double(20 * index),
                secondaryTitle: "Weekly limit",
                secondaryRemainingPercent: 40,
                headlineResetsAt: now.addingTimeInterval(Double(index + 1) * 3_600),
                resetCardCount: index == 3 ? 0 : 1,
                resetCardExpiresAt: index == 3 ? nil : now.addingTimeInterval(5 * 3_600)
            )
        }
        let targets = (0..<4).map { index in
            UsageActivityTarget(
                id: "target-\(index)",
                kind: .quota,
                accountName: "Account \(index)",
                accountSymbolName: nil,
                providerID: .chatGPT,
                title: "5h limit",
                remainingPercent: Double(20 * index),
                expiresAt: now.addingTimeInterval(Double(index + 1) * 3_600)
            )
        }
        let state = UsageActivityAttributes.ContentState(targets: targets, accounts: rows, updatedAt: now)
        let data = try JSONEncoder().encode(state)
        XCTAssertLessThan(data.count, 4_096)
        XCTAssertEqual(state.accounts.map(\.resetCardCount), [1, 1, 1, 0])
    }

    func testBankedResetTargetUsesTheResetCardName() {
        AppLanguage.choose(.chineseSimplified)
        let target = UsageActivityTarget(
            id: "banked",
            kind: .bankedReset,
            accountName: "Work",
            accountSymbolName: nil,
            providerID: .chatGPT,
            title: "Reset cards",
            resetCount: 1,
            expiresAt: now.addingTimeInterval(3_600)
        )
        XCTAssertEqual(target.displayTitle, "重置卡")
        XCTAssertFalse(target.displayTitle.contains("已存储"))
    }
#endif

    private func make(
        count: Int,
        credits: [ResetCredit],
        name: String = "Account"
    ) -> UsageSnapshot {
        UsageSnapshot(
            accountID: UUID(),
            providerName: "ChatGPT",
            accountName: name,
            accountProviderID: .chatGPT,
            plan: "Plus",
            primary: UsageWindow(
                title: "5h limit",
                usedPercent: 20,
                resetsAt: now.addingTimeInterval(8 * 3_600),
                windowMinutes: 300,
                kind: .fiveHour,
                identifier: "five"
            ),
            secondary: nil,
            availableResetCount: count,
            resetCredits: credits,
            fetchedAt: now
        )
    }

    private func credit(_ id: String, hours: Double) -> ResetCredit {
        ResetCredit(
            id: id,
            expiresAt: now.addingTimeInterval(hours * 3_600),
            status: "available"
        )
    }
}
