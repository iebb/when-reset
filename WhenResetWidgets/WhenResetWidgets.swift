import ActivityKit
import AppIntents
import SwiftUI
import WidgetKit

@main
struct WhenResetWidgetBundle: WidgetBundle {
    var body: some Widget {
        UsageWidget()
        UsageLockScreenWidget()
        UsageLiveActivity()
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
}

private struct WidgetMetricTarget: Hashable, Sendable {
    enum Kind: Hashable, Sendable { case quota, bankedReset }

    var kind: Kind
    var metricID: String
    var title: String
    var expiresAt: Date
    var remainingPercent: Double?
    var resetCount: Int?
    var grantedAt: Date?

    static func targets(for snapshot: UsageSnapshot, after date: Date = .distantPast) -> [WidgetMetricTarget] {
        var result = snapshot.usageWindows.filter { $0.resetsAt > date }.map {
            WidgetMetricTarget(kind: .quota, metricID: $0.metricID, title: $0.displayTitle,
                               expiresAt: $0.resetsAt, remainingPercent: $0.remainingPercent,
                               resetCount: nil, grantedAt: nil)
        }
        if let credit = snapshot.nextBankedResetCredit(after: date), let expiry = credit.expiresAt {
            result.append(.init(kind: .bankedReset, metricID: "banked-resets", title: "Banked resets",
                                expiresAt: expiry, remainingPercent: nil,
                                resetCount: snapshot.availableResetCount, grantedAt: credit.grantedAt))
        }
        return result.sorted {
            if $0.expiresAt != $1.expiresAt { return $0.expiresAt < $1.expiresAt }
            return $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
        }
    }

    func progress(at date: Date) -> Double {
        if let remainingPercent { return remainingPercent / 100 }
        guard let grantedAt, expiresAt > grantedAt else { return 0 }
        return max(0, min(1, expiresAt.timeIntervalSince(date) / expiresAt.timeIntervalSince(grantedAt)))
    }

    var valueLabel: String {
        switch kind {
        case .quota: "\(Int(remainingPercent ?? 0))% left"
        case .bankedReset: resetCountLabel(resetCount ?? 0)
        }
    }
}

private struct UsageEntry: TimelineEntry {
    var date: Date
    var snapshot: UsageSnapshot
    var target: WidgetMetricTarget
    var displayStyle: LockScreenDisplayStyle
}

private enum WidgetEntryResolver {
    static func resolve(account: WidgetAccountEntity?, metric: WidgetMetricEntity?,
                        displayStyle: LockScreenDisplayStyle = .automatic,
                        now: Date = .now) -> UsageEntry {
        let stored = SharedSnapshotStore.load()
        let snapshots = stored.isEmpty ? [.preview] : stored
        let requestedAccountID = account?.id ?? metric?.accountID

        let snapshot = snapshots.first { $0.accountID.uuidString == requestedAccountID }
            ?? snapshots.min { nearestDate(in: $0, after: now) < nearestDate(in: $1, after: now) }
            ?? .preview
        let targets = WidgetMetricTarget.targets(for: snapshot, after: now)
        let selectedMetricID = metric?.accountID == snapshot.accountID.uuidString ? metric?.metricID : nil
        let target = targets.first { $0.metricID == selectedMetricID }
            ?? targets.first
            ?? WidgetMetricTarget.targets(for: .preview).first!
        return UsageEntry(date: now, snapshot: snapshot, target: target, displayStyle: displayStyle)
    }

    private static func nearestDate(in snapshot: UsageSnapshot, after date: Date) -> Date {
        WidgetMetricTarget.targets(for: snapshot, after: date).first?.expiresAt ?? .distantFuture
    }
}

private struct UsageWidgetProvider: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> UsageEntry {
        WidgetEntryResolver.resolve(account: nil, metric: nil)
    }

    func snapshot(for configuration: UsageWidgetConfigurationIntent, in context: Context) async -> UsageEntry {
        WidgetEntryResolver.resolve(account: configuration.account, metric: configuration.metric)
    }

    func timeline(for configuration: UsageWidgetConfigurationIntent, in context: Context) async -> Timeline<UsageEntry> {
        let entry = WidgetEntryResolver.resolve(account: configuration.account, metric: configuration.metric)
        return Timeline(entries: [entry], policy: .after(.now.addingTimeInterval(15 * 60)))
    }
}

private struct UsageLockScreenWidgetProvider: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> UsageEntry {
        WidgetEntryResolver.resolve(account: nil, metric: nil, displayStyle: .detailed)
    }

    func snapshot(for configuration: UsageLockScreenConfigurationIntent, in context: Context) async -> UsageEntry {
        WidgetEntryResolver.resolve(account: configuration.account, metric: configuration.metric,
                                    displayStyle: configuration.displayStyle)
    }

    func timeline(for configuration: UsageLockScreenConfigurationIntent,
                  in context: Context) async -> Timeline<UsageEntry> {
        let entry = WidgetEntryResolver.resolve(account: configuration.account, metric: configuration.metric,
                                                displayStyle: configuration.displayStyle)
        return Timeline(entries: [entry], policy: .after(.now.addingTimeInterval(15 * 60)))
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
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

private struct HomeWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: UsageEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 7) {
                SnapshotAccountIcon(snapshot: entry.snapshot).frame(width: 20, height: 20)
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
                WidgetCountdown(expiry: entry.target.expiresAt)
                    .font(.caption.monospacedDigit()).minimumScaleFactor(0.65)
            }
            ProgressView(value: entry.target.progress(at: entry.date), total: 1)
                .tint(entry.target.kind == .bankedReset ? .teal : .blue)
            if family == .systemMedium, let plan = entry.snapshot.plan, !plan.isEmpty {
                Text(plan.replacingOccurrences(of: "_", with: " "))
                    .font(.caption2).foregroundStyle(.tertiary).lineLimit(1)
            }
            Spacer(minLength: 0)
        }
    }
}

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
            HStack {
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
    let expiry: Date

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            switch CountdownDisplay.liveActivityValue(until: expiry, from: context.date) {
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
        .monospacedDigit().lineLimit(1).minimumScaleFactor(0.55)
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
                LiveActivityCountdown(expiry: target.expiresAt)
                    .font(.headline).layoutPriority(1)
            }
            HStack(alignment: .firstTextBaseline, spacing: 6) {
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

private func resetCountLabel(_ count: Int) -> String {
    "\(count) reset\(count == 1 ? "" : "s")"
}
