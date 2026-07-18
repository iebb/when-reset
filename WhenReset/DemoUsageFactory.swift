import Foundation

enum DemoUsageFactory {
    static func snapshot(for account: MonitoredAccount, at date: Date = .now) -> UsageSnapshot {
        var generator = SystemRandomNumberGenerator()
        return snapshot(for: account, at: date, using: &generator)
    }

    static func snapshot<R: RandomNumberGenerator>(
        for account: MonitoredAccount,
        at date: Date,
        using generator: inout R
    ) -> UsageSnapshot {
        let fiveHourUsed = Double(Int.random(in: 12...82, using: &generator))
        let weeklyUsed = Double(Int.random(in: 18...91, using: &generator))
        let sparkUsed = Double(Int.random(in: 2...64, using: &generator))
        let fiveHourResetMinutes = Int.random(in: 35...235, using: &generator)
        let weeklyResetHours = Int.random(in: 52...158, using: &generator)
        let creditCount = Int.random(in: 2...4, using: &generator)

        let credits = (0..<creditCount).map { index in
            let expiry: Date
            if index == 0 {
                expiry = date.addingTimeInterval(Double(Int.random(in: 70...230, using: &generator) * 60))
            } else {
                expiry = date.addingTimeInterval(Double(Int.random(in: (index + 2)...(index + 12), using: &generator) * 86_400))
            }
            return ResetCredit(
                id: "demo-reset-\(index)-\(UUID().uuidString)",
                expiresAt: expiry,
                status: "available",
                grantedAt: date.addingTimeInterval(-Double(Int.random(in: 1...20, using: &generator) * 86_400))
            )
        }

        return UsageSnapshot(
            accountID: account.id,
            providerName: ProviderID.chatGPT.displayName,
            accountName: account.resolvedDisplayName,
            accountProviderID: account.providerID,
            accountSymbolName: account.customSymbolName,
            plan: account.plan,
            primary: UsageWindow(
                title: "5 hour",
                usedPercent: fiveHourUsed,
                resetsAt: date.addingTimeInterval(Double(fiveHourResetMinutes * 60)),
                windowMinutes: 300,
                kind: .fiveHour,
                identifier: "five_hour"
            ),
            secondary: UsageWindow(
                title: "Weekly",
                usedPercent: weeklyUsed,
                resetsAt: date.addingTimeInterval(Double(weeklyResetHours * 3_600)),
                windowMinutes: 10_080,
                kind: .weekly,
                identifier: "weekly"
            ),
            availableResetCount: creditCount,
            resetCredits: credits,
            fetchedAt: date,
            extraWindows: [
                UsageWindow(
                    title: "GPT-5.3-Codex-Spark",
                    usedPercent: sparkUsed,
                    resetsAt: date.addingTimeInterval(Double((weeklyResetHours + 6) * 3_600)),
                    windowMinutes: 10_080,
                    kind: .additional,
                    identifier: "additional:codex_bengalfox:primary"
                )
            ]
        )
    }
}
