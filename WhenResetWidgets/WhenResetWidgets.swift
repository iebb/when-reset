#if os(iOS)
import ActivityKit
#endif
import AppIntents
import Charts
import SwiftUI
import WidgetKit

@main
struct WhenResetWidgetBundle: WidgetBundle {
    var body: some Widget {
        UsageWidget()
#if os(iOS)
        UsageLockScreenWidget()
        UsageLiveActivity()
#endif
    }
}

struct WidgetAccountEntity: AppEntity, Hashable, Sendable {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Account"
    static let defaultQuery = WidgetAccountQuery()

    var id: String
    var name: String
    var providerName: String

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)", subtitle: "\(providerName)")
    }
}

struct WidgetAccountQuery: EntityQuery {
    func entities(for identifiers: [WidgetAccountEntity.ID]) async throws -> [WidgetAccountEntity] {
        WidgetDataCatalog.accounts().filter { identifiers.contains($0.id) }
    }

    func suggestedEntities() async throws -> [WidgetAccountEntity] {
        WidgetDataCatalog.accounts()
    }
}

struct WidgetMetricEntity: AppEntity, Hashable, Sendable {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Metric"
    static let defaultQuery = WidgetMetricQuery()

    var id: String
    var accountID: String
    var metricID: String
    var name: String
    var accountName: String

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)", subtitle: "\(accountName)")
    }
}

struct WidgetMetricQuery: EntityQuery {
    func entities(for identifiers: [WidgetMetricEntity.ID]) async throws -> [WidgetMetricEntity] {
        WidgetDataCatalog.metrics().filter { identifiers.contains($0.id) }
    }

    func suggestedEntities() async throws -> [WidgetMetricEntity] {
        WidgetDataCatalog.metrics()
    }
}

struct UsageWidgetMetricOptionsProvider: DynamicOptionsProvider {
    @IntentParameterDependency<UsageWidgetConfigurationIntent>(\.$account) private var intent

    func results() async throws -> [WidgetMetricEntity] {
        WidgetDataCatalog.metrics(accountID: intent?.account.id)
    }
}

struct LockWidgetMetricOptionsProvider: DynamicOptionsProvider {
    @IntentParameterDependency<UsageLockScreenConfigurationIntent>(\.$account) private var intent

    func results() async throws -> [WidgetMetricEntity] {
        WidgetDataCatalog.metrics(accountID: intent?.account.id)
    }
}

struct UsageWidgetConfigurationIntent: WidgetConfigurationIntent {
    static let title: LocalizedStringResource = "Configure Usage Widget"
    static let description = IntentDescription("Choose the account, quota, and visual style to display.")

    @Parameter(title: "Account") var account: WidgetAccountEntity?
    @Parameter(title: "Metric", optionsProvider: UsageWidgetMetricOptionsProvider())
    var metric: WidgetMetricEntity?
    @Parameter(title: "Appearance", default: .automatic)
    var appearance: HomeWidgetDisplayStyle

    init() {}
}

enum HomeWidgetDisplayStyle: String, AppEnum, Sendable {
    case automatic
    case market
    case ring
    case board
    case gauge
    case heatmap

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Widget appearance"
    static let caseDisplayRepresentations: [HomeWidgetDisplayStyle: DisplayRepresentation] = [
        .automatic: "Automatic",
        .market: "Market chart",
        .ring: "Quota ring",
        .board: "Quota board",
        .gauge: "Quota gauge",
        .heatmap: "Quota heatmap"
    ]
}

enum LockScreenDisplayStyle: String, AppEnum, Sendable {
    case automatic
    case detailed
    case countdown
    case remaining
    case progress

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Display style"
    static let caseDisplayRepresentations: [LockScreenDisplayStyle: DisplayRepresentation] = [
        .automatic: "Automatic",
        .detailed: "Account and metric",
        .countdown: "Countdown",
        .remaining: "Remaining quota",
        .progress: "Progress"
    ]
}

struct UsageLockScreenConfigurationIntent: WidgetConfigurationIntent {
    static let title: LocalizedStringResource = "Configure Lock Screen Widget"
    static let description = IntentDescription("Choose an account, metric, and presentation style.")

    @Parameter(title: "Account") var account: WidgetAccountEntity?
    @Parameter(title: "Metric", optionsProvider: LockWidgetMetricOptionsProvider())
    var metric: WidgetMetricEntity?
    @Parameter(title: "Display style", default: .automatic)
    var displayStyle: LockScreenDisplayStyle

    init() {}
}

private enum WidgetDataCatalog {
    static func snapshots() -> [UsageSnapshot] { SharedSnapshotStore.load() }

    static func accounts() -> [WidgetAccountEntity] {
        snapshots().map {
            WidgetAccountEntity(id: $0.accountID.uuidString, name: $0.resolvedAccountName,
                                providerName: $0.providerName)
        }.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    static func metrics(accountID: String? = nil) -> [WidgetMetricEntity] {
        snapshots().filter { accountID == nil || $0.accountID.uuidString == accountID }
            .flatMap { snapshot -> [(entity: WidgetMetricEntity, date: Date)] in
                WidgetMetricTarget.targets(for: snapshot).map { target in
                    (
                        WidgetMetricEntity(
                            id: metricEntityID(accountID: snapshot.accountID, metricID: target.metricID),
                            accountID: snapshot.accountID.uuidString, metricID: target.metricID,
                            name: target.title, accountName: snapshot.resolvedAccountName
                        ),
                        target.expiresAt ?? .distantFuture
                    )
                }
            }
            .sorted {
                if $0.date != $1.date { return $0.date < $1.date }
                return $0.entity.name.localizedCaseInsensitiveCompare($1.entity.name) == .orderedAscending
            }
            .map { $0.entity }
    }

    static func metricEntityID(accountID: UUID, metricID: String) -> String {
        "\(accountID.uuidString)|\(metricID)"
    }

    static func history(accountID: UUID, metricID: String, now: Date) -> [UsageHistoryPoint] {
        SharedSnapshotStore.loadHistoryPoints(now: now).filter {
            $0.accountID == accountID && $0.metricID == metricID
        }
    }
}

private struct WidgetMetricTarget: Hashable, Sendable {
    enum Kind: Hashable, Sendable { case quota, bankedReset, apiBalance, unavailable }

    var kind: Kind
    var metricID: String
    var title: String
    var expiresAt: Date?
    var remainingPercent: Double?
    var resetCount: Int?
    var grantedAt: Date?
    var apiBalance: APIBalance?

    static func targets(for snapshot: UsageSnapshot, after date: Date = .distantPast) -> [WidgetMetricTarget] {
        var metricIDs = Set<String>()
        var result = snapshot.usageWindows.filter {
            $0.resetsAt > date && metricIDs.insert($0.metricID).inserted
        }.map {
            WidgetMetricTarget(kind: .quota, metricID: $0.metricID, title: $0.displayTitle,
                               expiresAt: $0.resetsAt, remainingPercent: $0.remainingPercent,
                               resetCount: nil, grantedAt: nil, apiBalance: nil)
        }
        if let credit = snapshot.nextBankedResetCredit(after: date), let expiry = credit.expiresAt {
            let activeCreditCount = snapshot.availableResetCredits.filter { credit in
                credit.expiresAt.map { $0 > date } ?? true
            }.count
            result.append(.init(kind: .bankedReset, metricID: "banked-resets", title: "Banked resets",
                                expiresAt: expiry, remainingPercent: nil,
                                resetCount: max(snapshot.availableResetCount,
                                                activeCreditCount),
                                grantedAt: credit.grantedAt, apiBalance: nil))
        }
        if let balance = snapshot.apiBalance {
            result.append(.init(
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

    func progress(at date: Date) -> Double? {
        if let remainingPercent { return min(1, max(0, remainingPercent / 100)) }
        guard kind == .bankedReset, let grantedAt, let expiresAt, expiresAt > grantedAt else { return nil }
        return max(0, min(1, expiresAt.timeIntervalSince(date) / expiresAt.timeIntervalSince(grantedAt)))
    }

    var valueLabel: String {
        switch kind {
        case .quota: "\(Int((remainingPercent ?? 0).rounded()))% left"
        case .bankedReset: resetCountLabel(resetCount ?? 0)
        case .apiBalance: apiBalance?.widgetValueLabel ?? "Balance unavailable"
        case .unavailable: "No data"
        }
    }

    var compactValueLabel: String {
        switch kind {
        case .quota: "\(Int((remainingPercent ?? 0).rounded()))%"
        case .bankedReset: "\(resetCount ?? 0)"
        case .apiBalance: apiBalance?.widgetPrimaryValue ?? "—"
        case .unavailable: "—"
        }
    }

    var valueCaption: String {
        switch kind {
        case .quota: "left"
        case .bankedReset: (resetCount ?? 0) == 1 ? "reset" : "resets"
        case .apiBalance: apiBalance?.widgetPrimaryLabel ?? "balance"
        case .unavailable: "unavailable"
        }
    }

    var condensedValueLabel: String {
        kind == .apiBalance ? compactValueLabel : valueLabel
    }

    var tint: Color {
        switch kind {
        case .quota: .blue
        case .bankedReset: .teal
        case .apiBalance: .indigo
        case .unavailable: .secondary
        }
    }

    var accessibilityValue: String {
        switch kind {
        case .quota:
            guard let expiresAt else { return valueLabel }
            return "\(valueLabel). Reset date \(expiresAt.formatted(date: .abbreviated, time: .shortened))."
        case .bankedReset:
            guard let expiresAt else { return valueLabel }
            return "\(valueLabel). Expiry date \(expiresAt.formatted(date: .abbreviated, time: .shortened))."
        case .apiBalance:
            guard let balance = apiBalance else { return "Balance unavailable. Open When Reset to refresh." }
            var result = balance.widgetValueLabel
            if let periodEnd = balance.periodEnd {
                result += ". Period ends \(periodEnd.formatted(date: .abbreviated, time: .shortened))"
            }
            if let accessExpiresAt = balance.accessExpiresAt {
                result += ". Access expires \(accessExpiresAt.formatted(date: .abbreviated, time: .shortened))"
            }
            return result
        case .unavailable:
            return "No balance or reset data. Open When Reset to refresh."
        }
    }

    static func unavailable(
        title: String = "No reset data",
        metricID: String = "unavailable",
        at date: Date
    ) -> Self {
        Self(kind: .unavailable, metricID: metricID, title: title,
             expiresAt: nil, remainingPercent: nil, resetCount: nil, grantedAt: nil,
             apiBalance: nil)
    }
}

private extension APIBalance {
    var widgetPrimaryValue: String {
        if isUnlimited { return "Unlimited" }
        return widgetFormatted(remaining ?? spent, compact: true)
    }

    var widgetPrimaryLabel: String {
        if isUnlimited { return "allowance" }
        let qualifier = remaining == nil ? "spent" : "left"
        guard let widgetUnitLabel else { return qualifier }
        return "\(widgetUnitLabel) \(qualifier)"
    }

    var widgetValueLabel: String {
        if isUnlimited { return "Unlimited allowance" }
        return "\(widgetFormatted(remaining ?? spent, compact: false)) \(widgetPrimaryLabel)"
    }

    private var widgetUnitLabel: String? {
        if let unitLabel = unitLabel?.trimmingCharacters(in: .whitespacesAndNewlines),
           !unitLabel.isEmpty {
            return unitLabel
        }
        let code = currencyCode.uppercased()
        return code == "PTS" || code == "POINTS" ? "points" : nil
    }

    private func widgetFormatted(_ amount: Double, compact: Bool) -> String {
        let compactScale: (divisor: Double, suffix: String)? = if compact && abs(amount) >= 1_000_000_000 {
            (1_000_000_000, "B")
        } else if compact && abs(amount) >= 1_000_000 {
            (1_000_000, "M")
        } else {
            nil
        }
        if widgetUnitLabel != nil {
            if let compactScale {
                let number = (amount / compactScale.divisor).formatted(
                    .number.precision(.fractionLength(0...1))
                )
                return "\(number)\(compactScale.suffix)"
            }
            return amount.formatted(
                .number.precision(.fractionLength(amount.rounded() == amount ? 0 : 2))
            )
        }
        if let compactScale {
            let value = (amount / compactScale.divisor).formatted(
                .currency(code: currencyCode.uppercased())
                    .precision(.fractionLength(0...1))
            )
            return "\(value)\(compactScale.suffix)"
        }
        return amount.formatted(.currency(code: currencyCode.uppercased()))
    }
}

private struct UsageEntry: TimelineEntry {
    var date: Date
    var snapshot: UsageSnapshot
    var target: WidgetMetricTarget
    var homeStyle: HomeWidgetDisplayStyle
    var displayStyle: LockScreenDisplayStyle
    var history: [UsageHistoryPoint]
}

private enum WidgetEntryResolver {
    static func resolve(account: WidgetAccountEntity?, metric: WidgetMetricEntity?,
                        homeStyle: HomeWidgetDisplayStyle = .automatic,
                        displayStyle: LockScreenDisplayStyle = .automatic,
                        usesPreviewData: Bool = false,
                        now: Date = .now) -> UsageEntry {
        if usesPreviewData {
            let snapshot = UsageSnapshot.preview
            let target = WidgetMetricTarget.targets(for: snapshot, after: now).first
                ?? .unavailable(at: now)
            return UsageEntry(date: now, snapshot: snapshot, target: target,
                              homeStyle: homeStyle,
                              displayStyle: displayStyle,
                              history: previewHistory(snapshot: snapshot, target: target, now: now))
        }

        let stored = SharedSnapshotStore.load()
        let requestedAccountID = account?.id ?? metric?.accountID
        guard !stored.isEmpty else {
            return unavailableEntry(
                accountID: requestedAccountID,
                accountName: account?.name ?? metric?.accountName ?? "When Reset",
                providerName: account?.providerName ?? "Add an account",
                metric: metric,
                homeStyle: homeStyle,
                displayStyle: displayStyle,
                now: now
            )
        }

        let snapshot: UsageSnapshot
        if let requestedAccountID {
            guard let requestedSnapshot = stored.first(where: {
                $0.accountID.uuidString == requestedAccountID
            }) else {
                return unavailableEntry(
                    accountID: requestedAccountID,
                    accountName: account?.name ?? metric?.accountName ?? "Account unavailable",
                    providerName: account?.providerName ?? "Open When Reset",
                    metric: metric,
                    homeStyle: homeStyle,
                    displayStyle: displayStyle,
                    now: now
                )
            }
            snapshot = requestedSnapshot
        } else {
            snapshot = stored.min {
                nearestDate(in: $0, after: now) < nearestDate(in: $1, after: now)
            } ?? stored[0]
        }

        let futureTargets = WidgetMetricTarget.targets(for: snapshot, after: now)
        let allTargets = WidgetMetricTarget.targets(for: snapshot)
        let selectedMetricID = metric?.accountID == snapshot.accountID.uuidString ? metric?.metricID : nil
        let target: WidgetMetricTarget
        if let selectedMetricID {
            target = futureTargets.first { $0.metricID == selectedMetricID }
                ?? .unavailable(
                    title: allTargets.first { $0.metricID == selectedMetricID }?.title
                        ?? metric?.name
                        ?? "No reset data",
                    metricID: selectedMetricID,
                    at: now
                )
        } else {
            target = futureTargets.first
                ?? .unavailable(at: now)
        }
        let history = WidgetDataCatalog.history(
            accountID: snapshot.accountID,
            metricID: target.metricID,
            now: now
        )
        return UsageEntry(date: now, snapshot: snapshot, target: target,
                          homeStyle: homeStyle,
                          displayStyle: displayStyle, history: history)
    }

    private static func unavailableEntry(
        accountID: String?,
        accountName: String,
        providerName: String,
        metric: WidgetMetricEntity?,
        homeStyle: HomeWidgetDisplayStyle,
        displayStyle: LockScreenDisplayStyle,
        now: Date
    ) -> UsageEntry {
        let fallbackID = UUID(uuidString: "00000000-0000-4000-8000-000000000000") ?? UUID()
        let snapshot = UsageSnapshot(
            accountID: accountID.flatMap { UUID(uuidString: $0) } ?? fallbackID,
            providerName: providerName,
            accountName: accountName,
            accountProviderID: nil,
            accountSymbolName: "clock.arrow.circlepath",
            plan: nil,
            primary: nil,
            secondary: nil,
            availableResetCount: 0,
            resetCredits: [],
            fetchedAt: now,
            extraWindows: []
        )
        let target = WidgetMetricTarget.unavailable(
            title: metric?.name ?? "No reset data",
            metricID: metric?.metricID ?? "unavailable",
            at: now
        )
        return UsageEntry(date: now, snapshot: snapshot, target: target,
                          homeStyle: homeStyle,
                          displayStyle: displayStyle, history: [])
    }

    private static func nearestDate(in snapshot: UsageSnapshot, after date: Date) -> Date {
        WidgetMetricTarget.targets(for: snapshot, after: date).compactMap(\.expiresAt).min() ?? .distantFuture
    }

    private static func previewHistory(
        snapshot: UsageSnapshot,
        target: WidgetMetricTarget,
        now: Date
    ) -> [UsageHistoryPoint] {
        guard target.kind == .quota,
              let providerID = snapshot.accountProviderID,
              let remainingPercent = target.remainingPercent,
              let expiresAt = target.expiresAt else { return [] }
        let values = [
            min(100, remainingPercent + 28),
            min(100, remainingPercent + 24),
            min(100, remainingPercent + 17),
            min(100, remainingPercent + 13),
            min(100, remainingPercent + 5),
            remainingPercent
        ]
        return values.enumerated().map { index, value in
            let recordedAt = now.addingTimeInterval(TimeInterval(index - values.count + 1) * 45 * 60)
            return UsageHistoryPoint(
                accountID: snapshot.accountID,
                providerID: providerID,
                metricID: target.metricID,
                metricTitle: target.title,
                kind: nil,
                windowMinutes: nil,
                remainingPercent: value,
                recordedAt: recordedAt,
                resetsAt: expiresAt,
                secondsUntilReset: max(0, expiresAt.timeIntervalSince(recordedAt)),
                source: .demo,
                plan: snapshot.plan
            )
        }
    }
}

private struct UsageWidgetProvider: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> UsageEntry {
        WidgetEntryResolver.resolve(account: nil, metric: nil, usesPreviewData: true)
    }

    func snapshot(for configuration: UsageWidgetConfigurationIntent, in context: Context) async -> UsageEntry {
        WidgetEntryResolver.resolve(account: configuration.account, metric: configuration.metric,
                                    homeStyle: configuration.appearance,
                                    usesPreviewData: context.isPreview)
    }

    func timeline(for configuration: UsageWidgetConfigurationIntent, in context: Context) async -> Timeline<UsageEntry> {
        let entry = WidgetEntryResolver.resolve(account: configuration.account, metric: configuration.metric,
                                                homeStyle: configuration.appearance)
        return Timeline(entries: [entry], policy: .after(WidgetTimelinePolicy.reloadDate(for: entry)))
    }
}

#if os(iOS)
private struct UsageLockScreenWidgetProvider: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> UsageEntry {
        WidgetEntryResolver.resolve(account: nil, metric: nil, displayStyle: .detailed,
                                    usesPreviewData: true)
    }

    func snapshot(for configuration: UsageLockScreenConfigurationIntent, in context: Context) async -> UsageEntry {
        WidgetEntryResolver.resolve(account: configuration.account, metric: configuration.metric,
                                    displayStyle: configuration.displayStyle,
                                    usesPreviewData: context.isPreview)
    }

    func timeline(for configuration: UsageLockScreenConfigurationIntent,
                  in context: Context) async -> Timeline<UsageEntry> {
        let entry = WidgetEntryResolver.resolve(account: configuration.account, metric: configuration.metric,
                                                displayStyle: configuration.displayStyle)
        return Timeline(entries: [entry], policy: .after(WidgetTimelinePolicy.reloadDate(for: entry)))
    }
}
#endif

private enum WidgetTimelinePolicy {
    static func reloadDate(for entry: UsageEntry, now: Date = .now) -> Date {
        let regularReload = now.addingTimeInterval(15 * 60)
        guard let expiresAt = entry.target.expiresAt, expiresAt > now else { return regularReload }
        return min(regularReload, expiresAt.addingTimeInterval(1))
    }
}

struct UsageWidget: Widget {
    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: "UsageWidget", intent: UsageWidgetConfigurationIntent.self,
                               provider: UsageWidgetProvider()) { entry in
            HomeWidgetView(entry: entry).containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("Usage limits")
        .description("Choose an account, quota, and market-inspired presentation.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}

private struct HomeWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: UsageEntry

    private var resolvedStyle: HomeWidgetDisplayStyle {
        guard entry.homeStyle == .automatic else { return entry.homeStyle }
        return family == .systemLarge ? .board : .market
    }

    @ViewBuilder
    var body: some View {
        switch resolvedStyle {
        case .market:
            if family == .systemSmall {
                SmallHomeWidgetView(entry: entry)
            } else {
                MarketHomeWidgetView(entry: entry, family: family)
            }
        case .ring:
            RingHomeWidgetView(entry: entry, family: family)
        case .board:
            BoardHomeWidgetView(entry: entry, family: family)
        case .gauge:
            GaugeHomeWidgetView(entry: entry, family: family)
        case .heatmap:
            HeatmapHomeWidgetView(entry: entry, family: family)
        case .automatic:
            EmptyView()
        }
    }
}

private extension UsageEntry {
    var widgetValueText: String {
        target.compactValueLabel
    }

    var widgetAccent: Color {
        guard let remaining = target.remainingPercent else { return target.tint }
        if remaining <= 20 { return .red }
        if remaining <= 50 { return .orange }
        return .green
    }

    var widgetHistoryChange: (label: String, color: Color)? {
        let visibleHistory = history.widgetSevenDayPoints
        guard target.kind == .quota,
              let first = visibleHistory.first,
              let last = visibleHistory.last,
              first.id != last.id else { return nil }
        let change = last.remainingPercent - first.remainingPercent
        let rounded = Int(change.rounded())
        let sign = rounded > 0 ? "+" : ""
        return ("7D \(sign)\(rounded) pts", rounded >= 0 ? .green : .red)
    }

    var hasWidgetHistory: Bool {
        history.widgetSevenDayPoints.count >= 2
    }

    var widgetTargets: [WidgetMetricTarget] {
        let available = WidgetMetricTarget.targets(for: snapshot, after: date)
        if available.isEmpty { return [target] }
        var ordered = [target]
        ordered.append(contentsOf: available.filter { $0.metricID != target.metricID })
        return ordered
    }
}

private extension WidgetMetricTarget {
    var widgetAccent: Color {
        guard let remainingPercent else { return tint }
        if remainingPercent <= 20 { return .red }
        if remainingPercent <= 50 { return .orange }
        return .green
    }
}

private struct MarketHomeWidgetView: View {
    let entry: UsageEntry
    let family: WidgetFamily

    var body: some View {
        VStack(alignment: .leading, spacing: family == .systemLarge ? 12 : 6) {
            HStack(alignment: .top, spacing: 8) {
                SnapshotAccountIcon(snapshot: entry.snapshot)
                    .frame(width: 22, height: 22)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 1) {
                    Text(entry.snapshot.resolvedAccountName)
                        .font(.headline)
                        .lineLimit(1)
                    Text(entry.target.title)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 6)
                VStack(alignment: .trailing, spacing: 1) {
                    if let change = entry.widgetHistoryChange {
                        Text(change.label)
                            .font(.caption2.bold().monospacedDigit())
                            .foregroundStyle(change.color)
                    }
                    if let expiresAt = entry.target.expiresAt {
                        WidgetCountdown(expiry: expiresAt)
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.secondary)
                    } else if entry.target.kind == .unavailable {
                        Text("Refresh")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                }
            }

            HStack(alignment: .lastTextBaseline, spacing: 8) {
                Text(entry.widgetValueText)
                    .font(.system(size: family == .systemLarge ? 52 : 34,
                                  weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .minimumScaleFactor(0.55)
                    .lineLimit(1)
                if entry.target.kind != .unavailable {
                    Text(entry.target.valueCaption.uppercased())
                        .font(.caption2.bold())
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                if family == .systemLarge, let plan = entry.snapshot.plan, !plan.isEmpty {
                    Text(plan.replacingOccurrences(of: "_", with: " "))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(entry.target.title)
            .accessibilityValue(entry.target.accessibilityValue)

            if entry.hasWidgetHistory {
                WidgetQuotaSparkline(points: entry.history, color: entry.widgetAccent, fillsArea: true)
                    .frame(height: family == .systemLarge ? 108 : 44)
            }

            if family == .systemLarge {
                HStack(spacing: 8) {
                    ForEach(entry.widgetTargets.prefix(3), id: \.metricID) { target in
                        MarketTargetChip(target: target, date: entry.date)
                    }
                }
            }
        }
    }
}

private struct MarketTargetChip: View {
    let target: WidgetMetricTarget
    let date: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(target.title)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(target.kind == .unavailable ? "Refresh" : target.condensedValueLabel)
                    .font(.caption.bold().monospacedDigit())
                    .foregroundStyle(target.kind == .unavailable ? .secondary : .primary)
                    .lineLimit(1)
                Spacer(minLength: 0)
                if let expiresAt = target.expiresAt {
                    WidgetCountdown(expiry: expiresAt)
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            if target.kind == .unavailable {
                Capsule()
                    .fill(.secondary.opacity(0.16))
                    .frame(height: 4)
            } else if let progress = target.progress(at: date) {
                ProgressView(value: progress, total: 1)
                    .tint(target.tint)
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.45), in: .rect(cornerRadius: 10))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(target.title)
        .accessibilityValue(target.accessibilityValue)
    }
}

private struct RingHomeWidgetView: View {
    let entry: UsageEntry
    let family: WidgetFamily

    var body: some View {
        Group {
            if family == .systemSmall {
                VStack(spacing: 7) {
                    compactHeader
                    WidgetQuotaRing(
                        progress: entry.target.progress(at: entry.date),
                        value: entry.widgetValueText,
                        color: entry.widgetAccent,
                        lineWidth: 9
                    )
                    .frame(width: 68, height: 68)
                    if entry.target.kind == .unavailable {
                        Text("Open app to refresh")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    } else if let expiresAt = entry.target.expiresAt {
                        WidgetCountdown(expiry: expiresAt)
                            .font(.caption.bold().monospacedDigit())
                            .foregroundStyle(.secondary)
                    } else {
                        Text(entry.target.valueCaption.capitalized)
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                }
            } else {
                VStack(alignment: .leading, spacing: family == .systemLarge ? 10 : 8) {
                    accountHeader
                    HStack(spacing: family == .systemLarge ? 18 : 12) {
                        WidgetQuotaRing(
                            progress: entry.target.progress(at: entry.date),
                            value: entry.widgetValueText,
                            color: entry.widgetAccent,
                            lineWidth: family == .systemLarge ? 12 : 10
                        )
                        .frame(width: family == .systemLarge ? 132 : 78,
                               height: family == .systemLarge ? 132 : 78)

                        VStack(alignment: .leading, spacing: family == .systemLarge ? 8 : 6) {
                            Text(entry.target.title)
                                .font(.headline)
                                .lineLimit(1)
                            Group {
                                if entry.target.kind == .unavailable {
                                    Label("Open app to refresh", systemImage: "arrow.clockwise")
                                } else if let expiresAt = entry.target.expiresAt {
                                    Label {
                                        WidgetCountdown(expiry: expiresAt)
                                            .monospacedDigit()
                                    } icon: {
                                        Image(systemName: "clock")
                                    }
                                } else {
                                    Label(entry.target.valueCaption.capitalized, systemImage: "creditcard")
                                }
                            }
                            .font(.caption)
                            .foregroundStyle(.secondary)

                            if family == .systemLarge, entry.hasWidgetHistory {
                                WidgetQuotaSparkline(
                                    points: entry.history,
                                    color: entry.widgetAccent,
                                    fillsArea: true
                                )
                                .frame(height: 76)
                            } else {
                                ForEach(entry.widgetTargets.dropFirst().prefix(1), id: \.metricID) { target in
                                    RingSecondaryRow(target: target, date: entry.date)
                                }
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    if family == .systemLarge {
                        HStack(spacing: 8) {
                            ForEach(entry.widgetTargets.dropFirst().prefix(3), id: \.metricID) { target in
                                RingSecondaryRow(target: target, date: entry.date)
                            }
                        }
                    }
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(entry.snapshot.resolvedAccountName), \(entry.target.title)")
        .accessibilityValue(entry.target.accessibilityValue)
    }

    private var compactHeader: some View {
        HStack(spacing: 6) {
            SnapshotAccountIcon(snapshot: entry.snapshot)
                .frame(width: 17, height: 17)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 0) {
                Text(entry.snapshot.resolvedAccountName)
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                Text(entry.target.title)
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
    }

    private var accountHeader: some View {
        HStack(spacing: 8) {
            SnapshotAccountIcon(snapshot: entry.snapshot)
                .frame(width: 22, height: 22)
                .accessibilityHidden(true)
            Text(entry.snapshot.resolvedAccountName)
                .font(.headline)
                .lineLimit(1)
            Spacer(minLength: 0)
            Text(entry.snapshot.providerName)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }
}

private struct WidgetQuotaRing: View {
    let progress: Double?
    let value: String
    let color: Color
    let lineWidth: CGFloat

    var body: some View {
        ZStack {
            if let progress {
                Circle()
                    .stroke(.secondary.opacity(0.16), lineWidth: lineWidth)
                Circle()
                    .trim(from: 0, to: min(1, max(0, progress)))
                    .stroke(color.gradient, style: StrokeStyle(
                        lineWidth: lineWidth,
                        lineCap: .round
                    ))
                    .rotationEffect(.degrees(-90))
            } else {
                Circle()
                    .fill(.secondary.opacity(0.1))
                Image(systemName: "creditcard")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(color)
                    .offset(y: -24)
            }
            Text(value)
                .font(.system(size: 27, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .minimumScaleFactor(0.5)
                .lineLimit(1)
                .padding(12)
        }
        .accessibilityHidden(true)
    }
}

private struct RingSecondaryRow: View {
    let target: WidgetMetricTarget
    let date: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 4) {
                Text(target.title)
                    .font(.caption2.weight(.semibold))
                    .lineLimit(1)
                Spacer(minLength: 0)
                Text(target.kind == .unavailable ? "Refresh" : target.condensedValueLabel)
                    .font(.caption2.bold().monospacedDigit())
                    .foregroundStyle(target.kind == .unavailable ? .secondary : .primary)
                    .lineLimit(1)
            }
            if target.kind == .unavailable {
                Capsule()
                    .fill(.secondary.opacity(0.16))
                    .frame(height: 4)
            } else if let progress = target.progress(at: date) {
                ProgressView(value: progress, total: 1)
                    .tint(target.tint)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(target.title)
        .accessibilityValue(target.accessibilityValue)
    }
}

private struct GaugeHomeWidgetView: View {
    let entry: UsageEntry
    let family: WidgetFamily

    var body: some View {
        Group {
            if family == .systemSmall {
                compactContent
            } else if family == .systemMedium {
                mediumContent
            } else {
                largeContent
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(entry.snapshot.resolvedAccountName), \(entry.target.title)")
        .accessibilityValue(entry.target.accessibilityValue)
    }

    private var compactContent: some View {
        VStack(spacing: 4) {
            GaugeAccountHeader(entry: entry, compact: true)

            WidgetQuotaDial(
                progress: entry.target.progress(at: entry.date),
                value: entry.widgetValueText,
                color: entry.widgetAccent,
                caption: entry.target.valueCaption.uppercased()
            )
            .aspectRatio(1, contentMode: .fit)
            .frame(maxHeight: 88)

            gaugeFooter
        }
    }

    private var mediumContent: some View {
        HStack(spacing: 14) {
            VStack(spacing: 3) {
                GaugeAccountHeader(entry: entry, compact: true)
                WidgetQuotaDial(
                    progress: entry.target.progress(at: entry.date),
                    value: entry.widgetValueText,
                    color: entry.widgetAccent,
                    caption: entry.target.valueCaption.uppercased()
                )
                .aspectRatio(1, contentMode: .fit)
            }
            .frame(maxWidth: .infinity)

            VStack(alignment: .leading, spacing: 7) {
                Text(entry.target.title)
                    .font(.headline)
                    .lineLimit(1)
                gaugeFooter
                if entry.hasWidgetHistory {
                    WidgetQuotaSparkline(points: entry.history, color: entry.widgetAccent, fillsArea: true)
                        .frame(maxHeight: 42)
                }
                ForEach(entry.widgetTargets.dropFirst().prefix(1), id: \.metricID) { target in
                    GaugeTargetSummary(target: target, date: entry.date)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        }
    }

    private var largeContent: some View {
        VStack(alignment: .leading, spacing: 10) {
            GaugeAccountHeader(entry: entry, compact: false)

            HStack(spacing: 18) {
                WidgetQuotaDial(
                    progress: entry.target.progress(at: entry.date),
                    value: entry.widgetValueText,
                    color: entry.widgetAccent,
                    caption: entry.target.valueCaption.uppercased()
                )
                .aspectRatio(1, contentMode: .fit)
                .frame(maxWidth: 150)

                VStack(alignment: .leading, spacing: 8) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(entry.target.title)
                            .font(.title3.bold())
                            .lineLimit(1)
                        Spacer(minLength: 6)
                        if let change = entry.widgetHistoryChange {
                            Text(change.label)
                                .font(.caption.bold().monospacedDigit())
                                .foregroundStyle(change.color)
                        }
                    }
                    gaugeFooter
                    if entry.hasWidgetHistory {
                        WidgetQuotaSparkline(points: entry.history, color: entry.widgetAccent, fillsArea: true)
                            .frame(maxHeight: 78)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            }

            HStack(spacing: 8) {
                ForEach(entry.widgetTargets.dropFirst().prefix(3), id: \.metricID) { target in
                    GaugeTargetSummary(target: target, date: entry.date)
                }
            }
        }
    }

    @ViewBuilder
    private var gaugeFooter: some View {
        if entry.target.kind == .unavailable {
            Label("Open app to refresh", systemImage: "arrow.clockwise")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        } else if let expiresAt = entry.target.expiresAt {
            Label {
                WidgetCountdown(expiry: expiresAt)
                    .monospacedDigit()
            } icon: {
                Image(systemName: "clock")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
        } else {
            Label {
                HStack(spacing: 3) {
                    Text("Updated")
                    Text(entry.snapshot.fetchedAt, style: .relative)
                }
            } icon: {
                Image(systemName: "clock.arrow.circlepath")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }
    }
}

private struct GaugeAccountHeader: View {
    let entry: UsageEntry
    let compact: Bool

    var body: some View {
        HStack(spacing: compact ? 6 : 8) {
            SnapshotAccountIcon(snapshot: entry.snapshot)
                .frame(width: compact ? 18 : 22, height: compact ? 18 : 22)
                .accessibilityHidden(true)
            Text(entry.snapshot.resolvedAccountName)
                .font(compact ? .caption.weight(.semibold) : .headline)
                .lineLimit(1)
            Spacer(minLength: 0)
            if !compact {
                Text(entry.snapshot.providerName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }
}

private struct WidgetQuotaDial: View {
    let progress: Double?
    let value: String
    let color: Color
    let caption: String

    var body: some View {
        GeometryReader { proxy in
            let side = min(proxy.size.width, proxy.size.height)
            let strokeWidth = max(6, side * 0.075)

            ZStack {
                if let progress {
                    Circle()
                        .trim(from: 0.125, to: 0.875)
                        .stroke(.secondary.opacity(0.16), style: StrokeStyle(
                            lineWidth: strokeWidth,
                            lineCap: .round
                        ))
                        .rotationEffect(.degrees(90))
                    Circle()
                        .trim(from: 0.125, to: 0.125 + (0.75 * min(1, max(0, progress))))
                        .stroke(color.gradient, style: StrokeStyle(
                            lineWidth: strokeWidth,
                            lineCap: .round
                        ))
                        .rotationEffect(.degrees(90))
                } else {
                    RoundedRectangle(cornerRadius: side * 0.2)
                        .fill(color.opacity(0.1))
                    Image(systemName: "creditcard.fill")
                        .font(.system(size: side * 0.1, weight: .semibold))
                        .foregroundStyle(color)
                        .offset(y: -side * 0.25)
                }

                VStack(spacing: 0) {
                    Text(value)
                        .font(.system(size: side * 0.25, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .minimumScaleFactor(0.45)
                        .lineLimit(1)
                    Text(caption)
                        .font(.system(size: max(7, side * 0.07), weight: .bold))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                }
                .offset(y: side * 0.045)
                .padding(.horizontal, side * 0.18)
            }
            .frame(width: side, height: side)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .accessibilityHidden(true)
    }
}

private struct GaugeTargetSummary: View {
    let target: WidgetMetricTarget
    let date: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(target.title)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer(minLength: 2)
                Text(target.kind == .unavailable ? "Refresh" : target.condensedValueLabel)
                    .font(.caption.bold().monospacedDigit())
                    .lineLimit(1)
            }
            if target.kind == .unavailable {
                Capsule()
                    .fill(.secondary.opacity(0.16))
                    .frame(height: 4)
            } else if let progress = target.progress(at: date) {
                ProgressView(value: progress, total: 1)
                    .tint(target.widgetAccent)
            }
        }
        .padding(7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.42), in: .rect(cornerRadius: 9))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(target.title)
        .accessibilityValue(target.accessibilityValue)
    }
}

private struct HeatmapHomeWidgetView: View {
    let entry: UsageEntry
    let family: WidgetFamily

    private var tileLimit: Int {
        if family == .systemSmall { return 1 }
        if family == .systemLarge { return 4 }
        return 3
    }

    private var columns: [GridItem] {
        if family == .systemLarge {
            return [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)]
        }
        return Array(repeating: GridItem(.flexible(), spacing: 7), count: family == .systemSmall ? 1 : 3)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: family == .systemLarge ? 9 : 7) {
            HStack(spacing: 7) {
                SnapshotAccountIcon(snapshot: entry.snapshot)
                    .frame(width: family == .systemSmall ? 18 : 22,
                           height: family == .systemSmall ? 18 : 22)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 0) {
                    Text(entry.snapshot.resolvedAccountName)
                        .font(family == .systemSmall ? .subheadline.bold() : .headline)
                        .lineLimit(1)
                    if family != .systemSmall {
                        Text(entry.snapshot.providerName)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
                if family == .systemSmall {
                    Image(systemName: "square.grid.2x2.fill")
                        .font(.caption2.bold())
                        .foregroundStyle(.secondary)
                        .accessibilityLabel("Usage map")
                } else {
                    Label("Usage map", systemImage: "square.grid.2x2.fill")
                        .font(.caption2.bold())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            LazyVGrid(columns: columns, spacing: 7) {
                ForEach(entry.widgetTargets.prefix(tileLimit), id: \.metricID) { target in
                    HeatmapQuotaTile(
                        target: target,
                        date: entry.date,
                        featured: family == .systemSmall
                    )
                }
            }
            .frame(maxHeight: .infinity)

            if family == .systemLarge,
               entry.hasWidgetHistory || entry.target.expiresAt != nil {
                HStack(spacing: 8) {
                    if let change = entry.widgetHistoryChange {
                        Text(change.label)
                            .font(.caption.bold().monospacedDigit())
                            .foregroundStyle(change.color)
                    }
                    if entry.hasWidgetHistory {
                        WidgetQuotaSparkline(points: entry.history, color: entry.widgetAccent, fillsArea: false)
                            .frame(maxWidth: .infinity, maxHeight: 36)
                    }
                    if let expiresAt = entry.target.expiresAt {
                        WidgetCountdown(expiry: expiresAt)
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(entry.snapshot.resolvedAccountName) usage heatmap")
    }
}

private struct HeatmapQuotaTile: View {
    let target: WidgetMetricTarget
    let date: Date
    let featured: Bool

    private var accent: Color { target.widgetAccent }

    var body: some View {
        VStack(alignment: .leading, spacing: featured ? 6 : 4) {
            HStack(spacing: 4) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(accent)
                    .frame(width: 5, height: featured ? 18 : 14)
                    .accessibilityHidden(true)
                Text(target.title)
                    .font(featured ? .caption.weight(.semibold) : .caption2.weight(.semibold))
                    .lineLimit(featured ? 2 : 1)
                Spacer(minLength: 0)
            }

            Text(target.kind == .unavailable ? "—" : target.condensedValueLabel)
                .font(.system(size: featured ? 30 : 18, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .minimumScaleFactor(0.55)
                .lineLimit(1)

            Spacer(minLength: 0)

            if target.kind == .unavailable {
                Label("Refresh", systemImage: "arrow.clockwise")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            } else if let expiresAt = target.expiresAt {
                HStack(spacing: 3) {
                    Image(systemName: "clock")
                        .accessibilityHidden(true)
                    WidgetCountdown(expiry: expiresAt)
                        .monospacedDigit()
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }
        }
        .padding(featured ? 10 : 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .background(
            LinearGradient(
                colors: [accent.opacity(0.2), accent.opacity(0.07)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            ),
            in: .rect(cornerRadius: 11)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 11)
                .stroke(accent.opacity(0.24), lineWidth: 1)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(target.title)
        .accessibilityValue(target.accessibilityValue)
    }
}

private struct BoardHomeWidgetView: View {
    let entry: UsageEntry
    let family: WidgetFamily

    private var rowLimit: Int {
        if family == .systemSmall { return 2 }
        if family == .systemLarge { return 3 }
        return 3
    }

    var body: some View {
        VStack(alignment: .leading, spacing: family == .systemLarge ? 9 : 7) {
            HStack(spacing: 7) {
                SnapshotAccountIcon(snapshot: entry.snapshot)
                    .frame(width: family == .systemSmall ? 18 : 22,
                           height: family == .systemSmall ? 18 : 22)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 0) {
                    Text(entry.snapshot.resolvedAccountName)
                        .font(family == .systemSmall ? .subheadline.bold() : .headline)
                        .lineLimit(1)
                    if family != .systemSmall {
                        Text(entry.snapshot.providerName)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
                Text("USAGE")
                    .font(.caption2.bold())
                    .foregroundStyle(.secondary)
            }

            if family == .systemMedium {
                HStack(spacing: 8) {
                    ForEach(entry.widgetTargets.prefix(rowLimit), id: \.metricID) { target in
                        BoardTargetRow(target: target, date: entry.date, compact: true)
                            .frame(maxWidth: .infinity)
                    }
                }
            } else {
                ForEach(entry.widgetTargets.prefix(rowLimit), id: \.metricID) { target in
                    BoardTargetRow(
                        target: target,
                        date: entry.date,
                        compact: family == .systemSmall
                    )
                }
            }

            if family != .systemSmall, entry.hasWidgetHistory {
                WidgetQuotaSparkline(
                    points: entry.history,
                    color: entry.widgetAccent,
                    fillsArea: false
                )
                .frame(height: family == .systemLarge ? 64 : 34)
            }
            Spacer(minLength: 0)
        }
    }
}

private struct BoardTargetRow: View {
    let target: WidgetMetricTarget
    let date: Date
    let compact: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 3 : 4) {
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                Text(target.title)
                    .font(compact ? .caption2.weight(.semibold) : .caption.weight(.semibold))
                    .lineLimit(1)
                Spacer(minLength: 2)
                if target.kind == .unavailable {
                    Text("Refresh")
                        .font(compact ? .caption2.weight(.semibold) : .caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                } else {
                    Text(target.condensedValueLabel)
                        .font(compact ? .caption2.bold().monospacedDigit() : .caption.bold().monospacedDigit())
                        .lineLimit(1)
                }
                if !compact, let expiresAt = target.expiresAt {
                    WidgetCountdown(expiry: expiresAt)
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(minWidth: 54, alignment: .trailing)
                }
            }
            if target.kind == .unavailable {
                Capsule()
                    .fill(.secondary.opacity(0.16))
                    .frame(height: 4)
            } else if let progress = target.progress(at: date) {
                ProgressView(value: progress, total: 1)
                    .tint(target.tint)
            }
        }
        .padding(compact ? 6 : 8)
        .background(.quaternary.opacity(0.42), in: .rect(cornerRadius: 8))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(target.title)
        .accessibilityValue(target.accessibilityValue)
    }
}

private struct SmallHomeWidgetView: View {
    let entry: UsageEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 7) {
                SnapshotAccountIcon(snapshot: entry.snapshot)
                    .frame(width: 18, height: 18)
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 1) {
                    Text(entry.snapshot.resolvedAccountName)
                        .font(.headline)
                        .lineLimit(1)
                    Text(entry.target.title)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 4)

                if entry.target.kind == .unavailable {
                    Image(systemName: "arrow.clockwise")
                        .font(.caption.bold())
                        .foregroundStyle(.secondary)
                } else if let expiresAt = entry.target.expiresAt {
                    VStack(alignment: .trailing, spacing: 1) {
                        WidgetCountdown(expiry: expiresAt)
                            .font(.caption.bold().monospacedDigit())
                            .foregroundStyle(entry.widgetAccent)
                            .minimumScaleFactor(0.65)
                        Text(entry.target.kind == .bankedReset ? "EXPIRY" : "RESET")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundStyle(.secondary)
                    }
                } else if entry.target.kind == .apiBalance {
                    Image(systemName: "creditcard")
                        .font(.caption.bold())
                        .foregroundStyle(entry.widgetAccent)
                }
            }

            Spacer(minLength: 5)

            if entry.hasWidgetHistory {
                WidgetQuotaSparkline(
                    points: entry.history,
                    color: entry.widgetAccent,
                    fillsArea: true
                )
                    .frame(height: 38)
            }

            Spacer(minLength: 2)

            HStack(alignment: .lastTextBaseline, spacing: 4) {
                Spacer(minLength: 0)
                Text(entry.widgetValueText)
                    .font(.system(size: 42, weight: .medium, design: .rounded))
                    .monospacedDigit()
                    .minimumScaleFactor(0.6)
                    .lineLimit(1)
                if entry.target.kind == .bankedReset || entry.target.kind == .apiBalance {
                    Text(entry.target.valueCaption.uppercased())
                        .font(.caption2.bold())
                        .foregroundStyle(.secondary)
                }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(entry.snapshot.resolvedAccountName), \(entry.target.title)")
        .accessibilityValue(entry.target.accessibilityValue)
    }
}

private struct WidgetQuotaSparkline: View {
    let points: [UsageHistoryPoint]
    let color: Color
    var fillsArea = false

    private var visiblePoints: [UsageHistoryPoint] {
        points.widgetSevenDayPoints
    }

    private var chartPoints: [UsageHistoryLineChartPoint] {
        UsageHistoryLineSegmentation.downsampledChartPoints(
            from: points.widgetSevenDaySourcePoints,
            seriesID: "widget",
            maximumSolidPoints: 80
        )
    }

    var body: some View {
        if visiblePoints.count >= 2 {
            Chart(chartPoints) { chartPoint in
                let point = chartPoint.point
                if fillsArea && !chartPoint.isGapConnector {
                    AreaMark(
                        x: .value("Recorded", point.recordedAt),
                        yStart: .value("Baseline", 0),
                        yEnd: .value("Percent remaining", point.remainingPercent),
                        series: .value("Area segment", chartPoint.segmentID)
                    )
                    .interpolationMethod(.monotone)
                    .foregroundStyle(LinearGradient(
                        colors: [color.opacity(0.34), color.opacity(0.03)],
                        startPoint: .top,
                        endPoint: .bottom
                    ))
                }
                LineMark(
                    x: .value("Recorded", point.recordedAt),
                    y: .value("Percent remaining", point.remainingPercent),
                    series: .value("Line segment", chartPoint.segmentID)
                )
                .interpolationMethod(.monotone)
                .foregroundStyle(color)
                .lineStyle(StrokeStyle(
                    lineWidth: 2.25,
                    lineCap: .round,
                    lineJoin: .round,
                    dash: chartPoint.isGapConnector ? [6, 4] : []
                ))
            }
            .chartYScale(domain: 0...100)
            .chartXAxis(.hidden)
            .chartYAxis(.hidden)
            .chartLegend(.hidden)
            .accessibilityHidden(true)
        } else {
            Capsule()
                .fill(color.opacity(points.isEmpty ? 0.18 : 0.65))
                .frame(height: 2)
                .padding(.horizontal, 2)
                .accessibilityHidden(true)
        }
    }
}

private extension Array where Element == UsageHistoryPoint {
    var widgetSevenDaySourcePoints: [UsageHistoryPoint] {
        let sorted = sorted { $0.recordedAt < $1.recordedAt }
        guard let latest = sorted.last else { return [] }
        let cutoff = latest.recordedAt.addingTimeInterval(-7 * 24 * 60 * 60)
        return sorted.filter { $0.recordedAt >= cutoff }
    }

    var widgetSevenDayPoints: [UsageHistoryPoint] {
        let filtered = widgetSevenDaySourcePoints
        let maximumCount = 80
        guard filtered.count > maximumCount else { return filtered }

        let finalIndex = filtered.count - 1
        return (0..<maximumCount).map { sampleIndex in
            let fraction = Double(sampleIndex) / Double(maximumCount - 1)
            let sourceIndex = Int((fraction * Double(finalIndex)).rounded())
            return filtered[sourceIndex]
        }
    }
}

#if os(iOS)
struct UsageLockScreenWidget: Widget {
    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: "UsageLockScreenWidget",
                               intent: UsageLockScreenConfigurationIntent.self,
                               provider: UsageLockScreenWidgetProvider()) { entry in
            LockWidgetView(entry: entry).containerBackground(.clear, for: .widget)
        }
        .configurationDisplayName("Usage countdown")
        .description("Choose the account, quota, and Lock Screen style.")
        .supportedFamilies([.accessoryCircular, .accessoryRectangular, .accessoryInline])
    }
}

private struct LockWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: UsageEntry

    var body: some View {
        Group {
            switch family {
            case .accessoryCircular:
                LockCircularView(entry: entry)
            case .accessoryInline:
                LockInlineView(entry: entry)
            default:
                LockRectangularView(entry: entry)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(entry.snapshot.resolvedAccountName), \(entry.target.title)")
        .accessibilityValue(entry.target.accessibilityValue)
    }
}

private struct LockCircularView: View {
    let entry: UsageEntry
    private var style: LockScreenDisplayStyle {
        guard entry.displayStyle == .automatic else { return entry.displayStyle }
        if entry.target.progress(at: entry.date) != nil { return .progress }
        return entry.target.expiresAt == nil ? .remaining : .countdown
    }

    var body: some View {
        switch style {
        case .progress:
            if let progress = entry.target.progress(at: entry.date) {
                Gauge(value: progress, in: 0...1) {
                    Image(systemName: entry.snapshot.accountSymbolName
                          ?? entry.snapshot.accountProviderID?.systemImageName ?? "gauge.with.dots.needle.33percent")
                } currentValueLabel: {
                    Text(entry.target.compactValueLabel)
                }
                .gaugeStyle(.accessoryCircularCapacity)
            } else {
                compactValue
            }
        case .remaining:
            compactValue
        case .countdown, .detailed, .automatic:
            if let expiresAt = entry.target.expiresAt {
                VStack(spacing: 1) {
                    Image(systemName: "clock")
                    WidgetCountdown(expiry: expiresAt)
                        .font(.caption2.bold()).minimumScaleFactor(0.5)
                }
            } else {
                compactValue
            }
        }
    }

    private var compactValue: some View {
        VStack(spacing: 1) {
            Image(systemName: entry.snapshot.accountSymbolName
                  ?? entry.snapshot.accountProviderID?.systemImageName ?? "clock.arrow.circlepath")
            Text(entry.target.compactValueLabel)
                .font(.caption.bold()).minimumScaleFactor(0.45)
        }
    }
}

private struct LockInlineView: View {
    let entry: UsageEntry

    var body: some View {
        Label {
            HStack(spacing: 3) {
                switch entry.displayStyle {
                case .remaining:
                    Text(entry.snapshot.resolvedAccountName)
                    Text("· \(entry.target.condensedValueLabel)")
                case .progress:
                    Text(entry.target.title)
                    Text("· \(entry.target.condensedValueLabel)")
                case .countdown:
                    Text(entry.target.title)
                    if let expiresAt = entry.target.expiresAt {
                        Text("·")
                        WidgetCountdown(expiry: expiresAt)
                    } else {
                        Text("· \(entry.target.condensedValueLabel)")
                    }
                case .automatic, .detailed:
                    Text(entry.snapshot.resolvedAccountName)
                    Text("· \(entry.target.title)")
                    if let expiresAt = entry.target.expiresAt {
                        Text("·")
                        WidgetCountdown(expiry: expiresAt)
                    } else {
                        Text("· \(entry.target.condensedValueLabel)")
                    }
                }
            }
        } icon: {
            Image(systemName: entry.snapshot.accountSymbolName
                  ?? entry.snapshot.accountProviderID?.systemImageName ?? "clock.arrow.circlepath")
        }
    }
}

private struct LockRectangularView: View {
    let entry: UsageEntry
    private var style: LockScreenDisplayStyle {
        entry.displayStyle == .automatic ? .detailed : entry.displayStyle
    }

    var body: some View {
        switch style {
        case .countdown:
            VStack(alignment: .leading, spacing: 2) {
                LockAccountHeader(snapshot: entry.snapshot)
                Text(entry.target.title).font(.caption2).lineLimit(1)
                if let expiresAt = entry.target.expiresAt {
                    WidgetCountdown(expiry: expiresAt)
                        .font(.headline.monospacedDigit()).minimumScaleFactor(0.65)
                } else {
                    Text(entry.target.condensedValueLabel).font(.headline).lineLimit(1)
                }
            }
        case .remaining:
            VStack(alignment: .leading, spacing: 2) {
                LockAccountHeader(snapshot: entry.snapshot)
                Text(entry.target.title).font(.caption2).lineLimit(1)
                Text(entry.target.condensedValueLabel).font(.headline).lineLimit(1)
            }
        case .progress:
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(entry.target.title).font(.caption).lineLimit(1)
                    Spacer()
                    Text(entry.target.condensedValueLabel).font(.caption.bold())
                }
                if let progress = entry.target.progress(at: entry.date) {
                    ProgressView(value: progress, total: 1)
                }
                if let expiresAt = entry.target.expiresAt {
                    WidgetCountdown(expiry: expiresAt)
                        .font(.caption2.monospacedDigit()).frame(maxWidth: .infinity, alignment: .trailing)
                }
            }
        case .automatic, .detailed:
            VStack(alignment: .leading, spacing: 2) {
                LockAccountHeader(snapshot: entry.snapshot)
                HStack {
                    Text(entry.target.title).font(.caption).lineLimit(1)
                    Spacer()
                    Text(entry.target.condensedValueLabel).font(.caption.bold()).lineLimit(1)
                }
                if let expiresAt = entry.target.expiresAt {
                    WidgetCountdown(expiry: expiresAt)
                        .font(.headline.monospacedDigit()).minimumScaleFactor(0.65)
                } else {
                    Text(entry.target.condensedValueLabel)
                        .font(.caption.monospacedDigit()).lineLimit(1).minimumScaleFactor(0.65)
                }
            }
        }
    }
}

private struct LockAccountHeader: View {
    let snapshot: UsageSnapshot

    var body: some View {
        HStack(spacing: 5) {
            SnapshotAccountIcon(snapshot: snapshot).frame(width: 14, height: 14)
            Text(snapshot.resolvedAccountName).font(.caption.bold()).lineLimit(1)
        }
    }
}
#endif

#if os(iOS)
struct UsageLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: UsageActivityAttributes.self) { context in
            LiveLockView(state: context.state)
                .activityBackgroundTint(.black)
                .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    if let target = context.state.targets.first { LiveProviderStack(target: target, expanded: true) }
                }
                DynamicIslandExpandedRegion(.trailing) {
                    if let target = context.state.targets.first {
                        LiveActivityCountdown(expiry: target.expiresAt)
                            .font(.headline).foregroundStyle(.white)
                    }
                }
                DynamicIslandExpandedRegion(.bottom) {
                    if let target = context.state.targets.first {
                        VStack(alignment: .leading, spacing: 7) {
                            LivePrimaryIslandDetail(target: target)
                            let secondary = Array(context.state.targets.dropFirst().prefix(3))
                            if !secondary.isEmpty {
                                HStack(spacing: 7) {
                                    ForEach(secondary) { LiveIslandMiniTarget(target: $0) }
                                }
                            }
                        }
                    }
                }
            } compactLeading: {
                if let target = context.state.targets.first { LiveProviderStack(target: target) }
            } compactTrailing: {
                if let target = context.state.targets.first {
                    LiveActivityCountdown(expiry: target.expiresAt)
                        .font(.system(size: 8, weight: .semibold, design: .rounded))
                        .frame(width: 46, alignment: .trailing).foregroundStyle(.white)
                }
            } minimal: {
                if let target = context.state.targets.first {
                    ProviderMark(providerID: target.providerID, symbolName: target.accountSymbolName)
                }
            }
        }
    }
}

private struct LiveProviderStack: View {
    let target: UsageActivityTarget
    var expanded = false

    var body: some View {
        VStack(spacing: expanded ? 3 : 0) {
            ProviderMark(providerID: target.providerID, symbolName: target.accountSymbolName)
                .frame(width: expanded ? 20 : 12, height: expanded ? 20 : 12)
            if expanded {
                Text(target.accountName).font(.caption2.weight(.semibold)).lineLimit(1)
            } else if let value = target.compactValueLabel {
                Text(value)
                    .font(.system(size: 9, weight: .semibold)).monospacedDigit()
            }
        }
        .foregroundStyle(.white)
    }
}

private struct LivePrimaryIslandDetail: View {
    let target: UsageActivityTarget

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 5) {
                if target.isPinned { LiveActivityPinnedMarker() }
                Text(target.title).lineLimit(1)
                Spacer()
                if let value = target.valueLabel {
                    Text(value).monospacedDigit().lineLimit(1)
                }
            }
            if let progress = target.progressFraction {
                ProgressView(value: progress, total: 1)
                    .tint(target.kind == .bankedReset ? .teal : .blue)
            }
        }
        .foregroundStyle(.white)
    }
}

private struct LiveIslandMiniTarget: View {
    let target: UsageActivityTarget

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 4) {
                if target.isPinned { LiveActivityPinnedMarker() }
                Text(target.title).font(.caption2).lineLimit(1).foregroundStyle(.secondary)
                Spacer(minLength: 2)
                if let value = target.valueLabel {
                    Text(value).font(.caption2.bold()).lineLimit(1)
                }
            }
            if let progress = target.progressFraction {
                ProgressView(value: progress, total: 1)
                    .tint(target.kind == .bankedReset ? .teal : .blue)
            }
            HStack(spacing: 4) {
                ProviderMark(providerID: target.providerID, symbolName: target.accountSymbolName)
                    .frame(width: 12, height: 12)
                Text(target.accountName).font(.caption2.bold()).lineLimit(1)
                Spacer(minLength: 2)
                LiveActivityCountdown(expiry: target.expiresAt).font(.caption2.bold())
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct ProviderMark: View {
    let providerID: ProviderID
    let symbolName: String?

    var body: some View { ProviderIcon(providerID: providerID, symbolName: symbolName) }
}

private struct LiveActivityCountdown: View {
    enum Style {
        case standard
        case hero
    }

    let expiry: Date
    var style = Style.standard

    var body: some View {
        TimelineView(.periodic(from: .now, by: style == .hero ? 1 : 60)) { context in
            if style == .hero {
                countdownValue(at: context.date)
                    .font(CountdownDisplay.shouldEmphasizeLiveActivityCountdown(
                        until: expiry,
                        from: context.date
                    ) ? .title2.weight(.semibold) : .headline)
                    .fontDesign(.monospaced)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .multilineTextAlignment(.trailing)
            } else {
                countdownValue(at: context.date)
            }
        }
        .monospacedDigit().lineLimit(1).minimumScaleFactor(0.55)
    }

    @ViewBuilder
    private func countdownValue(at date: Date) -> some View {
        switch CountdownDisplay.liveActivityValue(until: expiry, from: date) {
        case let .days(days, hours):
            Text("\(days)d \(hours)h")
        case let .hours(hours, minutes):
            Text(String(format: "%dh %02dm", hours, minutes))
        case .timer:
            Text(timerInterval: expiry.addingTimeInterval(-7_200)...expiry,
                 countsDown: true, showsHours: true)
                .contentTransition(.numericText(countsDown: true))
        case .expired:
            Text("0:00")
        }
    }
}

private struct LiveLockView: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let state: UsageActivityAttributes.ContentState

    var body: some View {
        let ordered = UsageActivityTarget.ordered(state.targets)
        VStack(spacing: 8) {
            if let primary = ordered.first {
                LiveHeroTargetCard(target: primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                Text("No matching resets").frame(maxWidth: .infinity, alignment: .leading)
            }
            let secondaryLimit = dynamicTypeSize.isAccessibilitySize ? 1 : 3
            let secondary = Array(ordered.dropFirst().prefix(secondaryLimit))
            if !secondary.isEmpty {
                HStack(alignment: .top, spacing: 8) {
                    ForEach(secondary) { target in
                        LiveCompactTargetCard(target: target)
                            .frame(maxWidth: .infinity, minHeight: 54, alignment: .leading)
                    }
                }
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .foregroundStyle(.white)
    }
}

private struct LiveHeroTargetCard: View {
    let target: UsageActivityTarget

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 7) {
                ProviderMark(providerID: target.providerID, symbolName: target.accountSymbolName)
                    .frame(width: 19, height: 19)
                Text(target.accountName).font(.headline).lineLimit(1)
                Spacer(minLength: 8)
                LiveActivityCountdown(expiry: target.expiresAt, style: .hero)
                    .layoutPriority(1)
            }
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                if target.isPinned { LiveActivityPinnedMarker() }
                Text(target.title).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                Spacer(minLength: 4)
                if let value = target.valueLabel {
                    Text(value).font(.headline).lineLimit(1).layoutPriority(1)
                }
            }
            if let progress = target.progressFraction {
                ProgressView(value: progress, total: 1)
                    .tint(target.kind == .bankedReset ? .teal : .blue)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(8)
        .background(.white.opacity(0.08), in: .rect(cornerRadius: 12))
    }
}

private struct LiveCompactTargetCard: View {
    let target: UsageActivityTarget

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                if target.isPinned { LiveActivityPinnedMarker() }
                Text(target.title).font(.caption2).lineLimit(1)
                Spacer(minLength: 3)
                if let value = target.valueLabel {
                    Text(value).font(.caption2.bold()).lineLimit(1).layoutPriority(1)
                }
            }
            if let progress = target.progressFraction {
                ProgressView(value: progress, total: 1)
                    .tint(target.kind == .bankedReset ? .teal : .blue)
            }
            HStack(spacing: 4) {
                ProviderMark(providerID: target.providerID, symbolName: target.accountSymbolName)
                    .frame(width: 13, height: 13)
                Text(target.accountName).font(.caption2.bold()).lineLimit(1)
                Spacer(minLength: 3)
                LiveActivityCountdown(expiry: target.expiresAt)
                    .font(.caption2.bold()).layoutPriority(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(7)
        .background(.white.opacity(0.08), in: .rect(cornerRadius: 10))
    }
}

private struct LiveActivityPinnedMarker: View {
    var body: some View {
        Image(systemName: "star.fill")
            .font(.system(size: 8, weight: .semibold))
            .foregroundStyle(.yellow)
            .accessibilityLabel("Pinned")
    }
}
#endif

private struct WidgetCountdown: View {
    let expiry: Date

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            Text(CountdownDisplay.widgetString(until: expiry, from: context.date)).monospacedDigit()
        }
        .lineLimit(1)
    }
}

private struct SnapshotAccountIcon: View {
    let snapshot: UsageSnapshot

    var body: some View {
        if let providerID = snapshot.accountProviderID {
            ProviderIcon(providerID: providerID, symbolName: snapshot.accountSymbolName)
        } else {
            Image(systemName: snapshot.accountSymbolName ?? "clock.arrow.circlepath")
                .resizable().scaledToFit()
        }
    }
}

#if os(iOS)
private extension UsageActivityTarget {
    var valueLabel: String? {
        switch kind {
        case .quota: remainingPercent.map { "\(Int($0))% left" }
        case .bankedReset: resetCountLabel(resetCount ?? 0)
        }
    }

    var compactValueLabel: String? {
        switch kind {
        case .quota: remainingPercent.map { "\(Int($0))%" }
        case .bankedReset: resetCount.map(String.init)
        }
    }
}
#endif

private func resetCountLabel(_ count: Int) -> String {
    "\(count) reset\(count == 1 ? "" : "s")"
}
