import Foundation

struct PeriodicRefreshPolicy: Equatable, Sendable {
    private(set) var lastAttempt: Date

    init(startingAt date: Date) {
        lastAttempt = date
    }

    mutating func recordRefresh(at date: Date) {
        guard date > lastAttempt else { return }
        lastAttempt = date
    }

    mutating func shouldRefresh(at date: Date, interval: RefreshInterval) -> Bool {
        guard date >= lastAttempt else {
            lastAttempt = date
            return false
        }
        guard let delay = interval.timeInterval else {
            lastAttempt = date
            return false
        }
        guard date.timeIntervalSince(lastAttempt) >= delay else { return false }
        lastAttempt = date
        return true
    }
}

enum MacUsagePresentation {
    static func visibleWindows(
        in snapshot: UsageSnapshot,
        settings: AccountMonitorSettings
    ) -> [UsageWindow] {
        var metricIDs = Set<String>()
        return snapshot.usageWindows.filter { window in
            settings.shows(window) && metricIDs.insert(window.metricID).inserted
        }
    }

    static func availableResetCount(
        in snapshot: UsageSnapshot,
        after date: Date = .now
    ) -> Int {
        let activeCreditCount = snapshot.availableResetCredits.filter { credit in
            credit.expiresAt.map { $0 > date } ?? true
        }.count
        return max(0, max(snapshot.availableResetCount, activeCreditCount))
    }
}

struct MacStatusTarget: Identifiable, Equatable, Sendable {
    let id: String
    let accountName: String
    let providerID: ProviderID
    let symbolName: String?
    let title: String
    let valueLabel: String?
    let date: Date

    static func targets(
        accounts: [MonitoredAccount],
        snapshots: [UUID: UsageSnapshot],
        settings: [UUID: AccountMonitorSettings],
        now: Date = .now
    ) -> [Self] {
        accounts.flatMap { account -> [Self] in
            guard let snapshot = snapshots[account.id] else { return [] }
            let accountSettings = settings[account.id] ?? .init()
            var result = MacUsagePresentation.visibleWindows(
                in: snapshot,
                settings: accountSettings
            )
            .filter { $0.resetsAt > now }
            .map { window in
                Self(
                    id: "\(account.id.uuidString):\(window.metricID)",
                    accountName: account.resolvedDisplayName,
                    providerID: account.providerID,
                    symbolName: account.customSymbolName,
                    title: window.displayTitle,
                    valueLabel: "\(Int(window.remainingPercent.rounded()))% left",
                    date: window.resetsAt
                )
            }

            let availableResetCount = MacUsagePresentation.availableResetCount(
                in: snapshot,
                after: now
            )
            if accountSettings.showBankedResets,
               availableResetCount > 0,
               let expiry = snapshot.nextBankedResetExpiry(after: now) {
                result.append(Self(
                    id: "\(account.id.uuidString):banked-resets",
                    accountName: account.resolvedDisplayName,
                    providerID: account.providerID,
                    symbolName: account.customSymbolName,
                    title: "Banked resets",
                    valueLabel: "\(availableResetCount) available",
                    date: expiry
                ))
            }
            return result
        }
        .sorted {
            if $0.date != $1.date { return $0.date < $1.date }
            let accountOrder = $0.accountName.localizedCaseInsensitiveCompare($1.accountName)
            if accountOrder != .orderedSame { return accountOrder == .orderedAscending }
            let titleOrder = $0.title.localizedCaseInsensitiveCompare($1.title)
            if titleOrder != .orderedSame { return titleOrder == .orderedAscending }
            return $0.id < $1.id
        }
    }
}
