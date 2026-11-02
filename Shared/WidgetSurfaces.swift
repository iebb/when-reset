import Foundation

/// Home Screen, Lock Screen, and Live Activity metric selection shared with the widget extension.
///
/// ChatGPT, Kimi Code, 智谱 GLM, and Grok all publish quota windows on `UsageSnapshot`.
/// The widget extension does not special-case those providers; it renders whatever
/// `metrics(for:)` returns, together with `ProviderID.logoAssetName`.
enum WidgetSurface {
    static let codingPlanProviders: [ProviderID] = [.chatGPT, .kimi, .zai, .zhipu, .grok]
    static let homeFamilies = ["systemSmall", "systemMedium", "systemLarge"]
    static let lockFamilies = ["accessoryCircular", "accessoryRectangular", "accessoryInline"]

    struct Metric: Hashable, Sendable {
        enum Kind: Hashable, Sendable {
            case quota, bankedReset, apiBalance, unavailable
        }

        var kind: Kind
        var metricID: String
        var title: String
        var expiresAt: Date?
        var remainingPercent: Double?
        var resetCount: Int?
        var grantedAt: Date?
        var apiBalance: APIBalance?
    }

    static func metrics(for snapshot: UsageSnapshot, after date: Date = .distantPast) -> [Metric] {
        var metricIDs = Set<String>()
        var result = snapshot.usageWindows.filter {
            $0.resetsAt > date && metricIDs.insert($0.metricID).inserted
        }.map {
            Metric(kind: .quota, metricID: $0.metricID, title: $0.displayTitle,
                   expiresAt: $0.resetsAt, remainingPercent: $0.remainingPercent,
                   resetCount: nil, grantedAt: nil, apiBalance: nil)
        }
        if let credit = snapshot.nextBankedResetCredit(after: date), let expiry = credit.expiresAt {
            let activeCreditCount = snapshot.availableResetCredits.filter { credit in
                credit.expiresAt.map { $0 > date } ?? true
            }.count
            result.append(Metric(kind: .bankedReset, metricID: "banked-resets", title: "Banked resets",
                                 expiresAt: expiry, remainingPercent: nil,
                                 resetCount: max(snapshot.availableResetCount, activeCreditCount),
                                 grantedAt: credit.grantedAt, apiBalance: nil))
        }
        if let balance = snapshot.apiBalance {
            result.append(Metric(
                kind: .apiBalance,
                metricID: "api-balance",
                title: balance.title,
                expiresAt: balance.periodEnd,
                remainingPercent: balance.fractionRemaining.map { $0 * 100 },
                resetCount: nil,
                grantedAt: balance.periodStart,
                apiBalance: balance
            ))
        }
        return result.sorted {
            let lhsDate = $0.expiresAt ?? .distantFuture
            let rhsDate = $1.expiresAt ?? .distantFuture
            if lhsDate != rhsDate { return lhsDate < rhsDate }
            return $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
        }
    }

    static func supportsHomeLockScreenAndLiveActivity(_ provider: ProviderID, snapshot: UsageSnapshot) -> Bool {
        guard codingPlanProviders.contains(provider), provider.logoAssetName != nil else { return false }
        guard snapshot.accountProviderID == provider || snapshot.accountProviderID == nil else { return false }
        let quota = metrics(for: snapshot).filter { $0.kind == .quota && $0.expiresAt != nil }
        return !quota.isEmpty && !homeFamilies.isEmpty && !lockFamilies.isEmpty
    }
}
