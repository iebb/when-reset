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
    static let description = IntentDescription("Choose the account and quota to display.")

    @Parameter(title: "Account") var account: WidgetAccountEntity?
    @Parameter(title: "Metric", optionsProvider: UsageWidgetMetricOptionsProvider())
    var metric: WidgetMetricEntity?

    init() {}
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
                        target.expiresAt
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
    enum Kind: Hashable, Sendable { case quota, bankedReset, unavailable }

    var kind: Kind
    var metricID: String
    var title: String
    var expiresAt: Date
    var remainingPercent: Double?
    var resetCount: Int?
    var grantedAt: Date?

    static func targets(for snapshot: UsageSnapshot, after date: Date = .distantPast) -> [WidgetMetricTarget] {
        var metricIDs = Set<String>()
        var result = snapshot.usageWindows.filter {
            $0.resetsAt > date && metricIDs.insert($0.metricID).inserted
        }.map {
            WidgetMetricTarget(kind: .quota, metricID: $0.metricID, title: $0.displayTitle,
                               expiresAt: $0.resetsAt, remainingPercent: $0.remainingPercent,
                               resetCount: nil, grantedAt: nil)
        }
        if let credit = snapshot.nextBankedResetCredit(after: date), let expiry = credit.expiresAt {
            let activeCreditCount = snapshot.availableResetCredits.filter { credit in
                credit.expiresAt.map { $0 > date } ?? true
            }.count
            result.append(.init(kind: .bankedReset, metricID: "banked-resets", title: "Banked resets",
                                expiresAt: expiry, remainingPercent: nil,
                                resetCount: max(snapshot.availableResetCount,
                                                activeCreditCount),
                                grantedAt: credit.grantedAt))
        }
        return result.sorted {
            if $0.expiresAt != $1.expiresAt { return $0.expiresAt < $1.expiresAt }
            return $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
        }
    }

    func progress(at date: Date) -> Double {
        if let remainingPercent { return remainingPercent / 100 }
        if kind == .unavailable { return 0 }
        guard let grantedAt, expiresAt > grantedAt else { return 0 }
        return max(0, min(1, expiresAt.timeIntervalSince(date) / expiresAt.timeIntervalSince(grantedAt)))
    }

    var valueLabel: String {
        switch kind {
        case .quota: "\(Int((remainingPercent ?? 0).rounded()))% left"
        case .bankedReset: resetCountLabel(resetCount ?? 0)
        case .unavailable: "No data"
        }
    }

    var tint: Color {
        switch kind {
        case .quota: .blue
        case .bankedReset: .teal
        case .unavailable: .secondary
        }
    }

    var accessibilityValue: String {
        guard kind != .unavailable else { return "No reset data. Open When Reset to refresh." }
        return "\(valueLabel). Reset date \(expiresAt.formatted(date: .abbreviated, time: .shortened))."
    }

    static func unavailable(
        title: String = "No reset data",
        metricID: String = "unavailable",
        at date: Date
    ) -> Self {
        Self(kind: .unavailable, metricID: metricID, title: title,
             expiresAt: date, remainingPercent: nil, resetCount: nil, grantedAt: nil)
    }
}

private struct UsageEntry: TimelineEntry {
    var date: Date
    var snapshot: UsageSnapshot
    var target: WidgetMetricTarget
    var displayStyle: LockScreenDisplayStyle
    var history: [UsageHistoryPoint]
}

private enum WidgetEntryResolver {
    static func resolve(account: WidgetAccountEntity?, metric: WidgetMetricEntity?,
                        displayStyle: LockScreenDisplayStyle = .automatic,
                        usesPreviewData: Bool = false,
                        now: Date = .now) -> UsageEntry {
        if usesPreviewData {
            let snapshot = UsageSnapshot.preview
            let target = WidgetMetricTarget.targets(for: snapshot, after: now).first
                ?? .unavailable(at: now)
            return UsageEntry(date: now, snapshot: snapshot, target: target,
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
                          displayStyle: displayStyle, history: history)
    }

    private static func unavailableEntry(
        accountID: String?,
        accountName: String,
        providerName: String,
        metric: WidgetMetricEntity?,
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
                          displayStyle: displayStyle, history: [])
    }

    private static func nearestDate(in snapshot: UsageSnapshot, after date: Date) -> Date {
        WidgetMetricTarget.targets(for: snapshot, after: date).first?.expiresAt ?? .distantFuture
    }

    private static func previewHistory(
        snapshot: UsageSnapshot,
        target: WidgetMetricTarget,
        now: Date
    ) -> [UsageHistoryPoint] {
        guard target.kind == .quota,
              let providerID = snapshot.accountProviderID,
              let remainingPercent = target.remainingPercent else { return [] }
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
                resetsAt: target.expiresAt,
                secondsUntilReset: max(0, target.expiresAt.timeIntervalSince(recordedAt)),
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
                                    usesPreviewData: context.isPreview)
    }

    func timeline(for configuration: UsageWidgetConfigurationIntent, in context: Context) async -> Timeline<UsageEntry> {
        let entry = WidgetEntryResolver.resolve(account: configuration.account, metric: configuration.metric)
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
        guard entry.target.expiresAt > now else { return regularReload }
        return min(regularReload, entry.target.expiresAt.addingTimeInterval(1))
    }
}

struct UsageWidget: Widget {
    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: "UsageWidget", intent: UsageWidgetConfigurationIntent.self,
                               provider: UsageWidgetProvider()) { entry in
            HomeWidgetView(entry: entry).containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("Usage limits")
        .description("Choose an account and quota to monitor.")
#if os(macOS)
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
#else
        .supportedFamilies([.systemSmall, .systemMedium])
#endif
    }
}

private struct HomeWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: UsageEntry

    var body: some View {
        if family == .systemLarge {
            LargeHomeWidgetView(entry: entry)
        } else if family == .systemSmall {
            SmallHomeWidgetView(entry: entry)
        } else {
            compactContent
        }
    }

    private var compactContent: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 7) {
                SnapshotAccountIcon(snapshot: entry.snapshot)
                    .frame(width: 20, height: 20)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 0) {
                    Text(entry.snapshot.resolvedAccountName).font(.headline).lineLimit(1)
                    if family == .systemMedium {
                        Text(entry.snapshot.providerName).font(.caption2).foregroundStyle(.secondary)
                    }
                }
                Spacer()
            }
            Text(entry.target.title).font(.caption.weight(.semibold)).foregroundStyle(.secondary).lineLimit(1)
            HStack(alignment: .firstTextBaseline) {
                Text(entry.target.valueLabel).font(family == .systemMedium ? .title2.bold() : .headline)
                Spacer()
                if entry.target.kind == .unavailable {
                    Text("Open app to refresh")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                } else {
                    WidgetCountdown(expiry: entry.target.expiresAt)
                        .font(.caption.monospacedDigit()).minimumScaleFactor(0.65)
                }
            }
            ProgressView(value: entry.target.progress(at: entry.date), total: 1)
                .tint(entry.target.tint)
            if family == .systemMedium, let plan = entry.snapshot.plan, !plan.isEmpty {
                Text(plan.replacingOccurrences(of: "_", with: " "))
                    .font(.caption2).foregroundStyle(.tertiary).lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(entry.snapshot.resolvedAccountName), \(entry.target.title)")
        .accessibilityValue(entry.target.accessibilityValue)
    }
}

private struct SmallHomeWidgetView: View {
    let entry: UsageEntry

    private var valueText: String {
        switch entry.target.kind {
        case .quota:
            "\(Int((entry.target.remainingPercent ?? 0).rounded()))%"
        case .bankedReset:
            "\(entry.target.resetCount ?? 0)"
        case .unavailable:
            "—"
        }
    }

    private var accent: Color {
        guard entry.target.kind == .quota,
              let remaining = entry.target.remainingPercent else { return entry.target.tint }
        if remaining <= 20 { return .red }
        if remaining <= 50 { return .orange }
        return .green
    }

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
                } else {
                    VStack(alignment: .trailing, spacing: 1) {
                        WidgetCountdown(expiry: entry.target.expiresAt)
                            .font(.caption.bold().monospacedDigit())
                            .foregroundStyle(accent)
                            .minimumScaleFactor(0.65)
                        Text(entry.target.kind == .bankedReset ? "EXPIRY" : "RESET")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Spacer(minLength: 5)

            WidgetQuotaSparkline(points: entry.history, color: accent)
                .frame(height: 38)

            Spacer(minLength: 2)

            HStack(alignment: .lastTextBaseline, spacing: 4) {
                Spacer(minLength: 0)
                Text(valueText)
                    .font(.system(size: 42, weight: .medium, design: .rounded))
                    .monospacedDigit()
                    .minimumScaleFactor(0.6)
                    .lineLimit(1)
                if entry.target.kind == .bankedReset {
                    Text(entry.target.resetCount == 1 ? "RESET" : "RESETS")
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

    private var visiblePoints: [UsageHistoryPoint] {
        guard let latest = points.last else { return [] }
        let cutoff = latest.recordedAt.addingTimeInterval(-7 * 24 * 60 * 60)
        return Array(points.filter { $0.recordedAt >= cutoff }.suffix(80))
    }

    private var chartPoints: [UsageHistoryLineChartPoint] {
        UsageHistoryLineSegmentation.chartPoints(
            from: visiblePoints,
            seriesID: "widget"
        )
    }

    var body: some View {
        if visiblePoints.count >= 2 {
            Chart(chartPoints) { chartPoint in
                let point = chartPoint.point
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

private struct LargeHomeWidgetView: View {
    let entry: UsageEntry

    private var additionalTargets: [WidgetMetricTarget] {
        WidgetMetricTarget.targets(for: entry.snapshot, after: entry.date)
            .filter { $0.metricID != entry.target.metricID }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                SnapshotAccountIcon(snapshot: entry.snapshot)
                    .frame(width: 34, height: 34)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 1) {
                    Text(entry.snapshot.resolvedAccountName)
                        .font(.title3.bold())
                        .lineLimit(1)
                    Text(accountSubtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                Text("Updated \(entry.snapshot.fetchedAt, format: .relative(presentation: .named))")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline) {
                    Text(entry.target.title)
                        .font(.headline)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(entry.target.valueLabel)
                        .font(.title2.bold().monospacedDigit())
                }
                if entry.target.kind == .unavailable {
                    Text("Open When Reset to refresh this account.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                } else {
                    HStack(alignment: .firstTextBaseline) {
                        Text(entry.target.kind == .bankedReset ? "Next expiry" : "Resets")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        WidgetCountdown(expiry: entry.target.expiresAt)
                            .font(.headline.monospacedDigit())
                    }
                }
                ProgressView(value: entry.target.progress(at: entry.date), total: 1)
                    .tint(entry.target.tint)
            }
            .padding(12)
            .background(.quaternary.opacity(0.5), in: .rect(cornerRadius: 12))
            .accessibilityElement(children: .combine)
            .accessibilityLabel(entry.target.title)
            .accessibilityValue(entry.target.accessibilityValue)

            if !additionalTargets.isEmpty {
                Text("Other upcoming resets")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                VStack(spacing: 9) {
                    ForEach(additionalTargets.prefix(3), id: \.metricID) { target in
                        LargeWidgetTargetRow(target: target, date: entry.date)
                    }
                }
            }
            Spacer(minLength: 0)
        }
    }

    private var accountSubtitle: String {
        guard let plan = entry.snapshot.plan?.replacingOccurrences(of: "_", with: " "),
              !plan.isEmpty else { return entry.snapshot.providerName }
        return "\(entry.snapshot.providerName) · \(plan)"
    }
}

private struct LargeWidgetTargetRow: View {
    let target: WidgetMetricTarget
    let date: Date

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(target.title).font(.subheadline.weight(.semibold)).lineLimit(1)
                    Spacer()
                    Text(target.valueLabel).font(.caption.bold().monospacedDigit())
                }
                ProgressView(value: target.progress(at: date), total: 1)
                    .tint(target.tint)
            }
            WidgetCountdown(expiry: target.expiresAt)
                .font(.caption.monospacedDigit())
                .frame(width: 72, alignment: .trailing)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(target.title)
        .accessibilityValue(target.accessibilityValue)
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
        switch family {
        case .accessoryCircular:
            LockCircularView(entry: entry)
        case .accessoryInline:
            LockInlineView(entry: entry)
        default:
            LockRectangularView(entry: entry)
        }
    }
}

private struct LockCircularView: View {
    let entry: UsageEntry
    private var style: LockScreenDisplayStyle {
        entry.displayStyle == .automatic ? (entry.target.kind == .quota ? .progress : .countdown)
            : entry.displayStyle
    }

    var body: some View {
        switch style {
        case .progress:
            Gauge(value: entry.target.progress(at: entry.date), in: 0...1) {
                Image(systemName: entry.snapshot.accountSymbolName
                      ?? entry.snapshot.accountProviderID?.systemImageName ?? "gauge.with.dots.needle.33percent")
            } currentValueLabel: {
                Text(entry.target.kind == .quota ? "\(Int(entry.target.remainingPercent ?? 0))" : "\(entry.target.resetCount ?? 0)")
            }
            .gaugeStyle(.accessoryCircularCapacity)
        case .remaining:
            VStack(spacing: 1) {
                Image(systemName: entry.snapshot.accountSymbolName
                      ?? entry.snapshot.accountProviderID?.systemImageName ?? "clock.arrow.circlepath")
                Text(entry.target.kind == .quota ? "\(Int(entry.target.remainingPercent ?? 0))%"
                     : "\(entry.target.resetCount ?? 0)")
                    .font(.caption.bold()).minimumScaleFactor(0.65)
            }
        case .countdown, .detailed, .automatic:
            VStack(spacing: 1) {
                Image(systemName: "clock")
                WidgetCountdown(expiry: entry.target.expiresAt)
                    .font(.caption2.bold()).minimumScaleFactor(0.5)
            }
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
                    Text("· \(entry.target.valueLabel)")
                case .progress:
                    Text(entry.target.title)
                    Text("· \(entry.target.valueLabel)")
                case .countdown:
                    Text(entry.target.title)
                    Text("·")
                    WidgetCountdown(expiry: entry.target.expiresAt)
                case .automatic, .detailed:
                    Text(entry.snapshot.resolvedAccountName)
                    Text("· \(entry.target.title) ·")
                    WidgetCountdown(expiry: entry.target.expiresAt)
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
                WidgetCountdown(expiry: entry.target.expiresAt)
                    .font(.headline.monospacedDigit()).minimumScaleFactor(0.65)
            }
        case .remaining:
            VStack(alignment: .leading, spacing: 2) {
                LockAccountHeader(snapshot: entry.snapshot)
                Text(entry.target.title).font(.caption2).lineLimit(1)
                Text(entry.target.valueLabel).font(.headline).lineLimit(1)
            }
        case .progress:
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(entry.target.title).font(.caption).lineLimit(1)
                    Spacer()
                    Text(entry.target.valueLabel).font(.caption.bold())
                }
                ProgressView(value: entry.target.progress(at: entry.date), total: 1)
                WidgetCountdown(expiry: entry.target.expiresAt)
                    .font(.caption2.monospacedDigit()).frame(maxWidth: .infinity, alignment: .trailing)
            }
        case .automatic, .detailed:
            VStack(alignment: .leading, spacing: 2) {
                LockAccountHeader(snapshot: entry.snapshot)
                HStack {
                    Text(entry.target.title).font(.caption).lineLimit(1)
                    Spacer()
                    Text(entry.target.valueLabel).font(.caption.bold()).lineLimit(1)
                }
                WidgetCountdown(expiry: entry.target.expiresAt)
                    .font(.headline.monospacedDigit()).minimumScaleFactor(0.65)
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
