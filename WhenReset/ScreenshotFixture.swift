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
            (.chatGPT, "Kong Yi", "Pro", 15, 25, true),
            (.chatGPT, "Work", "Plus", 10, 55, true),
            (.grok, "Grok", "Heavy", 78, 42, false),
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
            if sample.5 {
                credits = [
                    ResetCredit(
                        id: "banked-\(index)",
                        expiresAt: now.addingTimeInterval(5 * 3_600),
                        status: "available",
                        grantedAt: now.addingTimeInterval(-86_400)
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
            rows.append(UsageActivityAccountRow(
                id: account.id.uuidString,
                accountName: account.resolvedDisplayName,
                providerID: account.providerID,
                symbolName: nil,
                headlineTitle: headline.displayTitle,
                headlineRemainingPercent: headline.remainingPercent,
                secondaryTitle: secondary?.displayTitle,
                secondaryRemainingPercent: secondary?.remainingPercent,
                headlineResetsAt: reset
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
