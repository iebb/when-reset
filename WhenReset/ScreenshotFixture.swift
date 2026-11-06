#if DEBUG
import Foundation

enum ScreenshotLaunch {
    static var isActive: Bool {
        ProcessInfo.processInfo.arguments.contains("-BlinkyScreenshotFixture")
    }

    static var screen: String {
        argument(after: "-BlinkyScreenshotScreen") ?? "usage"
    }

    static func applyLanguage() {
        guard isActive else { return }
        switch argument(after: "-BlinkyScreenshotLanguage") {
        case "zh-Hans", "zh":
            AppLanguage.choose(.chineseSimplified)
        case "en":
            AppLanguage.choose(.english)
        default:
            break
        }
    }

    /// Forces a light or dark interface and the continuous bar so captures stay deterministic.
    /// A fixed Codex Resets reading so the expanded card can show the prediction
    /// and the last announcement without calling the network.
    @MainActor
    static func installCodexFixture(now: Date = .now) {
        guard isActive else { return }
        CodexResetStore.shared.useScreenshotFixture(CodexResetStatus(
            scheduled: nil,
            watch: CodexResetStatus.Watch(
                level: "elevated",
                chancePercent: 40,
                forecastWindow: "this week",
                windowEnds: now.addingTimeInterval(21 * 3_600),
                text: nil,
                resetType: "regular"
            ),
            latest: CodexResetStatus.Latest(
                id: "screenshot-latest",
                resetType: "regular",
                announcedAt: now.addingTimeInterval(-2 * 86_400),
                text: nil
            )
        ))
    }

    static func applyChrome() {
        guard isActive else { return }
        switch argument(after: "-BlinkyScreenshotAppearance") {
        case "dark":
            AppAppearance.choose(.dark)
        default:
            AppAppearance.choose(.light)
        }
        UsageBarStyle.choose(.continuous)
        UsageListSort.choose(.custom)
        switch argument(after: "-BlinkyScreenshotInterfaceStyle") {
        case "classic":
            InterfaceStyle.choose(.classic)
        case "screenTime":
            InterfaceStyle.choose(.screenTime)
        default:
            InterfaceStyle.choose(.liquidGlass)
        }
    }

    static var tokenChart: TokenActivityChart {
        switch screen {
        case "tokenActivityWeekly": .weekly
        case "tokenActivityCumulative": .cumulative
        default: .daily
        }
    }

    static var seedsTokenActivity: Bool {
        switch screen {
        case "tokenActivity", "tokenActivityWeekly", "tokenActivityCumulative", "tokenActivityExpanded": true
        default: false
        }
    }

    /// A year of days. Each day's cache, input, and output sum to that day's total.
    /// Only the screenshot launch uses this. A phone with no transcripts stays empty.
    static func tokenActivityRecords(now: Date = .now, calendar: Calendar = .current) -> [TokenDayUsage] {
        let today = calendar.startOfDay(for: now)
        var records: [TokenDayUsage] = []
        for offset in 0..<360 {
            guard let date = calendar.date(byAdding: .day, value: -offset, to: today) else { continue }
            let weekday = calendar.component(.weekday, from: date)
            let weekend = weekday == 1 || weekday == 7
            if offset % 13 == 0 { continue }
            let wave = (offset * 17) % 40
            var total = (weekend ? 12_000 : 48_000) + wave * 2_200
            if offset % 23 == 0 { total += 220_000 }
            let shares = split(total, weights: [50, 32, 18])
            records.append(TokenDayUsage(date: date, models: [
                model("gpt-5.4", total: shares[0], cache: 55, input: 32, output: 13, speed: 51.4),
                model("claude-sonnet", total: shares[1], cache: 45, input: 38, output: 17, speed: 38.2),
                model("grok-4", total: shares[2], cache: nil, input: 75, output: 25, speed: 62.0),
            ]))
        }
        return records
    }

    private static func model(
        _ name: String,
        total: Int,
        cache: Int?,
        input: Int,
        output: Int,
        speed: Double
    ) -> TokenModelUsage {
        if let cache {
            let parts = split(total, weights: [cache, input, output])
            return TokenModelUsage(name: name, cache: parts[0], input: parts[1], output: parts[2], tokensPerSecond: speed)
        }
        let parts = split(total, weights: [input, output])
        return TokenModelUsage(name: name, cache: nil, input: parts[0], output: parts[1], tokensPerSecond: speed)
    }

    /// Integer parts that sum to `total`. The last weight takes the remainder.
    private static func split(_ total: Int, weights: [Int]) -> [Int] {
        let sum = max(weights.reduce(0, +), 1)
        var assigned = 0
        return weights.enumerated().map { index, weight in
            if index == weights.count - 1 { return total - assigned }
            let part = total * weight / sum
            assigned += part
            return part
        }
    }

    private static func argument(after flag: String) -> String? {
        let args = ProcessInfo.processInfo.arguments
        guard let index = args.firstIndex(of: flag), args.indices.contains(index + 1) else { return nil }
        return args[index + 1]
    }
}

enum ScreenshotFixture {
    struct Seed {
        var accounts: [MonitoredAccount]
        var snapshots: [UUID: UsageSnapshot]
        var deviceLink: DeviceLinkPresentation?
    }

    static func seed(now: Date = .now) -> Seed {
        let samples: [(ProviderID, String, String, Double, Double, Bool)] = [
            // Remaining percents are intentionally not sorted. Widgets must
            // keep this custom order instead of lining up lowest-remaining first.
            // Three remaining tiers, in custom order: comfortable, warning (≤25%), exhausted.
            (.chatGPT, "Kong Yi", "Pro", 15, 25, true),
            (.chatGPT, "Work", "Plus", 80, 78, true),
            (.grok, "Grok", "Heavy", 100, 42, false),
            (.kimi, "Kimi Code", "Plus", 0, 8, false),
            (.zai, "z.ai", "Pro", 40, 33, false),
            (.zhipu, "智谱", "Max", 26, 41, false),
        ]
        var accounts: [MonitoredAccount] = []
        var snapshots: [UUID: UsageSnapshot] = [:]
        for (index, sample) in samples.enumerated() {
            let id = UUID(uuidString: String(format: "00000000-0000-4000-8000-%012d", index + 1))!
            let account = MonitoredAccount(
                id: id,
                providerID: sample.0,
                displayName: sample.1,
                workspaceID: "screenshot-\(sample.0.rawValue)-\(index)",
                plan: sample.2,
                addedAt: Date(timeIntervalSince1970: TimeInterval(1_000 + index))
            )
            accounts.append(account)
            let weeklyReportsReset = sample.0 != .zhipu
            var credits: [ResetCredit] = []
            if sample.0 == .zhipu {
                credits = [
                    ResetCredit(
                        id: "banked-\(index)-a",
                        expiresAt: now.addingTimeInterval(20 * 3_600),
                        status: "available",
                        grantedAt: now.addingTimeInterval(-3 * 3_600)
                    ),
                    ResetCredit(
                        id: "banked-\(index)-b",
                        expiresAt: now.addingTimeInterval(40 * 3_600),
                        status: "available",
                        grantedAt: now.addingTimeInterval(-2 * 3_600)
                    )
                ]
            } else if sample.5 {
                credits = [
                    ResetCredit(
                        id: "banked-\(index)",
                        expiresAt: now.addingTimeInterval(5 * 3_600),
                        status: "available",
                        grantedAt: now.addingTimeInterval(-3 * 3_600)
                    )
                ]
            }
            snapshots[id] = UsageSnapshot(
                accountID: id,
                providerName: sample.0.displayName,
                accountName: sample.1,
                accountProviderID: sample.0,
                plan: sample.2,
                primary: UsageWindow(
                    title: "5h limit",
                    usedPercent: sample.3,
                    resetsAt: now.addingTimeInterval(sample.0 == .grok ? 4 * 86_400 : (3 * 3_600 + 1_800)),
                    windowMinutes: sample.0 == .grok ? 10_080 : 300,
                    kind: sample.0 == .grok ? .weekly : .fiveHour,
                    identifier: sample.0 == .grok ? "weekly" : "five_hour"
                ),
                secondary: sample.0 == .grok ? nil : UsageWindow(
                    title: "Weekly limit",
                    usedPercent: sample.4,
                    resetsAt: now.addingTimeInterval(6 * 86_400),
                    windowMinutes: 10_080,
                    kind: .weekly,
                    identifier: "weekly",
                    reportsReset: weeklyReportsReset
                ),
                availableResetCount: credits.count,
                resetCredits: credits,
                fetchedAt: now
            )
        }
        let ordered = AccountOrdering.grouped(accounts)
        let link: DeviceLinkPresentation? = ScreenshotLaunch.screen == "deviceCode"
            ? DeviceLinkPresentation(
                providerID: .chatGPT,
                verificationURL: URL(string: "https://auth.openai.com/codex/device")!,
                userCode: "K3M9-PQ2R",
                expiresAt: now.addingTimeInterval(12 * 60)
            )
            : nil
        return Seed(accounts: ordered, snapshots: snapshots, deviceLink: link)
    }

    #if os(iOS)
    static func activityRows(now: Date = .now) -> [UsageActivityAccountRow] {
        let seeded = seed(now: now)
        var soonest: (String, Date)?
        var rows: [UsageActivityAccountRow] = []
        for account in seeded.accounts {
            guard let snapshot = seeded.snapshots[account.id],
                  let headline = snapshot.headlineWindow(pinnedMetricID: nil) else { continue }
            let secondary = snapshot.secondaryLimit(after: headline)
            let reset = headline.showsCountdown ? headline.resetsAt : nil
            if let reset, soonest == nil || reset < soonest!.1 {
                soonest = (account.id.uuidString, reset)
            }
            let cards = ResetCardSurface.fact(snapshot: snapshot, now: now)
            rows.append(UsageActivityAccountRow(
                id: account.id.uuidString,
                accountName: account.resolvedDisplayName,
                providerID: account.providerID,
                symbolName: nil,
                headlineTitle: headline.displayTitle,
                headlineRemainingPercent: headline.remainingPercent,
                secondaryTitle: secondary?.displayTitle,
                secondaryRemainingPercent: secondary?.remainingPercent,
                headlineResetsAt: reset,
                resetCardCount: cards?.count ?? 0,
                resetCardExpiresAt: cards?.expiresAt
            ))
        }
        return rows.map { row in
            var copy = row
            copy.isSoonestReset = row.id == soonest?.0
            return copy
        }
    }
    #endif
}
#endif
