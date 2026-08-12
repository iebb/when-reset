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

enum MacHistorySampleSource: String, Hashable, Sendable {
    case device
    case worker

    init(_ source: UsageRefreshSource) {
        self = source == .server ? .worker : .device
    }
}

struct MacHistoryChartPoint: Identifiable, Equatable, Sendable {
    let point: UsageHistoryPoint
    let sampleSource: MacHistorySampleSource
    let segmentID: String
    let isGapConnector: Bool

    let id: String
}

struct MacUsageHistorySeries: Identifiable, Equatable, Sendable {
    let metricID: String
    let title: String
    let points: [UsageHistoryPoint]

    var id: String { metricID }
    var latest: UsageHistoryPoint { points[points.count - 1] }
    var deviceSampleCount: Int { points.count { $0.source != .server } }
    var workerSampleCount: Int { points.count { $0.source == .server } }
    var includesDeviceSamples: Bool { deviceSampleCount > 0 }
    var includesWorkerSamples: Bool { workerSampleCount > 0 }

    var planSummary: String {
        var plans: [String] = []
        var previousKey: String?
        var hasPrevious = false
        for point in points {
            let key = canonicalPlan(point.plan)
            let display = point.providerID.planDisplayName(point.plan) ?? "Not recorded"
            if !hasPrevious || key != previousKey {
                plans.append(display)
            } else {
                plans[plans.count - 1] = display
            }
            previousKey = key
            hasPrevious = true
        }
        return plans.joined(separator: " → ")
    }

    var planChangePoints: [UsageHistoryPoint] {
        guard points.count > 1 else { return [] }
        var changes: [UsageHistoryPoint] = []
        var previousPlan = canonicalPlan(points[0].plan)
        for point in points.dropFirst() {
            let plan = canonicalPlan(point.plan)
            if plan != previousPlan { changes.append(point) }
            previousPlan = plan
        }
        return changes
    }

    var chartPoints: [MacHistoryChartPoint] {
        UsageHistoryLineSegmentation.chartPoints(from: points, seriesID: metricID).map { chartPoint in
            return MacHistoryChartPoint(
                point: chartPoint.point,
                sampleSource: MacHistorySampleSource(chartPoint.point.source),
                segmentID: chartPoint.segmentID,
                isGapConnector: chartPoint.isGapConnector,
                id: chartPoint.id
            )
        }
    }

    private func canonicalPlan(_ plan: String?) -> String? {
        guard let normalized = plan?.trimmingCharacters(in: .whitespacesAndNewlines),
              !normalized.isEmpty else { return nil }
        return normalized.folding(
            options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
            locale: Locale(identifier: "en_US_POSIX")
        )
    }
}

enum MacUsageHistoryPresentation {
    static let minimumSelectionDuration: TimeInterval = 5 * 60
    static let defaultSelectionDuration: TimeInterval = 7 * 24 * 60 * 60

    static func availableRange(
        points: [UsageHistoryPoint],
        accountID: UUID
    ) -> ClosedRange<Date>? {
        let dates = points.lazy
            .filter { $0.accountID == accountID }
            .map(\.recordedAt)
        guard let first = dates.min(), let last = dates.max() else { return nil }
        let lowerBound = min(first, last.addingTimeInterval(-minimumSelectionDuration))
        return lowerBound...last
    }

    static func defaultRange(within availableRange: ClosedRange<Date>) -> ClosedRange<Date> {
        normalizedRange(
            start: availableRange.upperBound.addingTimeInterval(-defaultSelectionDuration),
            end: availableRange.upperBound,
            within: availableRange
        )
    }

    static func normalizedRange(
        start: Date,
        end: Date,
        within availableRange: ClosedRange<Date>
    ) -> ClosedRange<Date> {
        let requestedStart = min(start, end)
        let requestedEnd = max(start, end)
        var lowerBound = min(max(requestedStart, availableRange.lowerBound), availableRange.upperBound)
        var upperBound = max(min(requestedEnd, availableRange.upperBound), availableRange.lowerBound)
        let availableDuration = availableRange.upperBound.timeIntervalSince(availableRange.lowerBound)
        let minimumDuration = min(minimumSelectionDuration, availableDuration)

        if upperBound.timeIntervalSince(lowerBound) < minimumDuration {
            upperBound = min(availableRange.upperBound, lowerBound.addingTimeInterval(minimumDuration))
            lowerBound = max(availableRange.lowerBound, upperBound.addingTimeInterval(-minimumDuration))
        }
        return lowerBound...upperBound
    }

    static func series(
        points: [UsageHistoryPoint],
        accountID: UUID,
        in selectedRange: ClosedRange<Date>
    ) -> [MacUsageHistorySeries] {
        let visiblePoints = points.filter {
            $0.accountID == accountID && selectedRange.contains($0.recordedAt)
        }
        return Dictionary(grouping: visiblePoints, by: \.metricID).map { metricID, values in
            let sorted = values.sorted { $0.recordedAt < $1.recordedAt }
            return MacUsageHistorySeries(
                metricID: metricID,
                title: sorted.last?.metricTitle ?? "Usage limit",
                points: sorted
            )
        }.sorted { lhs, rhs in
            let left = lhs.latest
            let right = rhs.latest
            let leftOrder = displayOrder(left)
            let rightOrder = displayOrder(right)
            if leftOrder != rightOrder { return leftOrder < rightOrder }
            return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
        }
    }

    private static func displayOrder(_ point: UsageHistoryPoint) -> Int {
        if point.kind == .additional { return 2 }
        return switch point.windowMinutes {
        case 300: 0
        case 10_080: 1
        default: 2
        }
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
