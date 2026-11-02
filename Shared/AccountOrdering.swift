import Foundation

enum ZhipuAccountMigration {
    static let legacyTitle = "智谱 GLM"

    static func migrate(_ account: MonitoredAccount, region: String?, host: String?) -> MonitoredAccount {
        guard account.providerID == .zai else { return account }
        let host = host?.lowercased() ?? ""
        let mainland = region == "mainland" || host.contains("bigmodel.cn")
        guard mainland else {
            var global = account
            if global.displayName == legacyTitle { global.displayName = ProviderID.zai.displayName }
            return global
        }
        var mainlandAccount = account
        mainlandAccount.providerID = .zhipu
        if mainlandAccount.displayName == legacyTitle {
            mainlandAccount.displayName = ProviderID.zhipu.displayName
        }
        return mainlandAccount
    }
}

/// How the Usage list lines up.
///
/// Custom is the stored drag order. Lowest remaining and soonest reset change
/// only that list. Widgets and the compact multi-account island stay on the
/// stored order. The soonest-reset badge is not a sort.
enum UsageListSort: String, CaseIterable, Identifiable, Codable, Sendable {
    case custom
    case remaining
    case soonestReset

    var id: String { rawValue }

    static let storageKey = "settings.usageListSort"
    static let `default` = UsageListSort.custom

    var title: String {
        switch self {
        case .custom: String.localized("Custom order")
        case .remaining: String.localized("Lowest remaining")
        case .soonestReset: String.localized("Soonest reset")
        }
    }

    static var current: UsageListSort {
        let raw = UserDefaults.standard.string(forKey: storageKey)
        return UsageListSort(rawValue: raw ?? "") ?? .default
    }

    static func choose(_ sort: UsageListSort) {
        UserDefaults.standard.set(sort.rawValue, forKey: storageKey)
    }
}

enum AccountOrdering {
    /// Default order, before anyone drags.
    ///
    /// Accounts of one provider sit together. Groups follow the first account
    /// added for that provider. Inside a group, earlier adds come first.
    /// A saved drag order does not come through here: `apply` keeps those ids.
    static func grouped(_ accounts: [MonitoredAccount]) -> [MonitoredAccount] {
        var firstAdded: [ProviderID: (date: Date, id: String)] = [:]
        for account in accounts {
            let marker = (date: account.addedAt, id: account.id.uuidString)
            if let existing = firstAdded[account.providerID] {
                let earlier = marker.date < existing.date
                    || (marker.date == existing.date && marker.id < existing.id)
                if earlier { firstAdded[account.providerID] = marker }
            } else {
                firstAdded[account.providerID] = marker
            }
        }
        return accounts.sorted { lhs, rhs in
            let left = firstAdded[lhs.providerID] ?? (lhs.addedAt, lhs.id.uuidString)
            let right = firstAdded[rhs.providerID] ?? (rhs.addedAt, rhs.id.uuidString)
            if left.date != right.date { return left.date < right.date }
            if lhs.providerID != rhs.providerID, left.id != right.id {
                return left.id < right.id
            }
            if lhs.addedAt != rhs.addedAt { return lhs.addedAt < rhs.addedAt }
            return lhs.id.uuidString < rhs.id.uuidString
        }
    }

    static func apply(customIDs: [UUID]?, to accounts: [MonitoredAccount]) -> [MonitoredAccount] {
        guard let customIDs, !customIDs.isEmpty else { return grouped(accounts) }
        let byID = Dictionary(uniqueKeysWithValues: accounts.map { ($0.id, $0) })
        var ordered: [MonitoredAccount] = []
        var seen = Set<UUID>()
        for id in customIDs {
            guard let account = byID[id], seen.insert(id).inserted else { continue }
            ordered.append(account)
        }
        let missing = accounts.filter { !seen.contains($0.id) }.sorted {
            if $0.addedAt != $1.addedAt { return $0.addedAt < $1.addedAt }
            return $0.id.uuidString < $1.id.uuidString
        }
        for account in missing {
            ordered = inserting(account, into: ordered)
        }
        return ordered
    }

    static func inserting(_ account: MonitoredAccount, into accounts: [MonitoredAccount]) -> [MonitoredAccount] {
        var result = accounts.filter { $0.id != account.id }
        if let last = result.lastIndex(where: { $0.providerID == account.providerID }) {
            result.insert(account, at: last + 1)
        } else {
            result.append(account)
        }
        return result
    }

    /// Visible order. Custom keeps the stored order, including where a new account
    /// was inserted. The other modes only change what is on screen: they do not
    /// rewrite the stored order, and the soonest-reset badge never does either.
    static func displayed(
        _ accounts: [MonitoredAccount],
        sort: UsageListSort,
        snapshots: [UUID: UsageSnapshot],
        now: Date = .now
    ) -> [MonitoredAccount] {
        switch sort {
        case .custom:
            return accounts
        case .remaining:
            return stablySorted(accounts) { account in
                remaining(account, snapshots: snapshots).map { (0, $0) } ?? (1, 0)
            }
        case .soonestReset:
            return stablySorted(accounts) { account in
                if let reset = soonestReset(account, snapshots: snapshots, now: now) {
                    return (0, reset.timeIntervalSinceReferenceDate)
                }
                return (1, 0)
            }
        }
    }

    /// Lowest remaining limit on the account, matching the headline row.
    /// Missing usage sorts after every account that has a percent.
    private static func remaining(
        _ account: MonitoredAccount,
        snapshots: [UUID: UsageSnapshot]
    ) -> Double? {
        snapshots[account.id]?.headlineWindow(pinnedMetricID: nil)?.remainingPercent
    }

    /// The headline countdown, when it is still ahead. A past or unstated reset
    /// sorts after every account that has one.
    private static func soonestReset(
        _ account: MonitoredAccount,
        snapshots: [UUID: UsageSnapshot],
        now: Date
    ) -> Date? {
        guard let window = snapshots[account.id]?.headlineWindow(pinnedMetricID: nil),
              window.showsCountdown,
              window.resetsAt > now else { return nil }
        return window.resetsAt
    }

    private static func stablySorted(
        _ accounts: [MonitoredAccount],
        key: (MonitoredAccount) -> (Int, Double)
    ) -> [MonitoredAccount] {
        accounts.enumerated().sorted { lhs, rhs in
            let left = key(lhs.element)
            let right = key(rhs.element)
            if left.0 != right.0 { return left.0 < right.0 }
            if left.1 != right.1 { return left.1 < right.1 }
            return lhs.offset < rhs.offset
        }.map(\.element)
    }

    static func moving(_ ids: [UUID], from offsets: IndexSet, to destination: Int) -> [UUID] {
        var items = ids
        let moving = offsets.sorted().map { items[$0] }
        for index in offsets.sorted(by: >) { items.remove(at: index) }
        let insertAt = destination - offsets.filter { $0 < destination }.count
        items.insert(contentsOf: moving, at: min(max(0, insertAt), items.count))
        return items
    }
}
