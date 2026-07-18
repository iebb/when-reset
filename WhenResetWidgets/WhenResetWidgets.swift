import ActivityKit
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

private struct UsageEntry: TimelineEntry {
    var date: Date
    var snapshot: UsageSnapshot
}

private struct UsageProvider: TimelineProvider {
    func placeholder(in context: Context) -> UsageEntry { .init(date: .now, snapshot: .preview) }
    func getSnapshot(in context: Context, completion: @escaping (UsageEntry) -> Void) {
        completion(.init(date: .now, snapshot: SharedSnapshotStore.load().first ?? .preview))
    }
    func getTimeline(in context: Context, completion: @escaping (Timeline<UsageEntry>) -> Void) {
        let snapshot = SharedSnapshotStore.load().first ?? .preview
        completion(Timeline(entries: [.init(date: .now, snapshot: snapshot)], policy: .after(.now.addingTimeInterval(15 * 60))))
    }
}

struct UsageWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "UsageWidget", provider: UsageProvider()) { entry in
            HomeWidgetView(snapshot: entry.snapshot).containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("Usage limits")
        .description("Usage, reset countdowns, and banked resets.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

private struct HomeWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let snapshot: UsageSnapshot
    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text(snapshot.accountName).font(.headline).lineLimit(1)
                Spacer()
                if snapshot.availableResetCount > 0 { ResetBadge(count: snapshot.availableResetCount) }
            }
            if let credit = snapshot.nextBankedResetCredit() {
                WidgetBankedLimit(count: snapshot.availableResetCount, credit: credit)
            }
            ForEach(Array(snapshot.usageWindows.prefix(family == .systemMedium ? 2 : 1).enumerated()), id: \.offset) { _, window in
                WidgetLimit(window: window)
            }
            Spacer(minLength: 0)
        }
    }
}

struct UsageLockScreenWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "UsageLockScreenWidget", provider: UsageProvider()) { entry in
            LockWidgetView(snapshot: entry.snapshot).containerBackground(.clear, for: .widget)
        }
        .configurationDisplayName("Usage countdown")
        .description("Keep the next usage reset on your Lock Screen.")
        .supportedFamilies([.accessoryCircular, .accessoryRectangular, .accessoryInline])
    }
}

private struct LockWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let snapshot: UsageSnapshot
    private var window: UsageWindow? { snapshot.usageWindows.first }

    var body: some View {
        switch family {
        case .accessoryCircular:
            if let expiry = snapshot.nextBankedResetExpiry() {
                VStack(spacing: 1) {
                    Image(systemName: "arrow.counterclockwise.circle")
                    BankedCountdown(expiry: expiry).font(.caption2).minimumScaleFactor(0.55)
                }
            } else {
                Gauge(value: window?.remainingPercent ?? 0, in: 0...100) {
                    Image(systemName: "gauge.with.dots.needle.33percent")
                } currentValueLabel: { Text("\(Int(window?.remainingPercent ?? 0))") }
                .gaugeStyle(.accessoryCircularCapacity)
            }
        case .accessoryInline:
            Label {
                HStack(spacing: 3) {
                    Text("\(Int(window?.remainingPercent ?? 0))%")
                    if snapshot.availableResetCount > 0 {
                        Text("· \(snapshot.availableResetCount) banked")
                    }
                    if snapshot.availableResetCount > 0, let expiry = snapshot.nextBankedResetExpiry() {
                        Text("·")
                        BankedCountdown(expiry: expiry)
                    }
                }
            } icon: {
                Image(systemName: "clock.arrow.circlepath")
            }
        default:
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(snapshot.accountName).bold()
                    Spacer()
                    if snapshot.availableResetCount > 0 { Text("↺ \(snapshot.availableResetCount)") }
                }
                if let window {
                    HStack {
                        UsageCountdown(reset: window.resetsAt).font(.headline.monospacedDigit())
                        Spacer()
                        Text("\(Int(window.remainingPercent))% left").font(.caption)
                    }
                }
                if let expiry = snapshot.nextBankedResetExpiry() {
                    HStack {
                        Text("Banked expiry")
                        Spacer()
                        BankedCountdown(expiry: expiry)
                    }.font(.caption2)
                }
            }
        }
    }
}

private struct WidgetLimit: View {
    let window: UsageWindow
    private var tint: Color {
        switch window.windowMinutes {
        case 300: .blue
        case 10_080: .purple
        default: .indigo
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 5) {
                Text(window.displayTitle).font(.caption.bold())
                Spacer()
                Text("\(Int(window.remainingPercent))%")
                UsageCountdown(reset: window.resetsAt)
            }
            .font(.caption2.monospacedDigit())
            ProgressView(value: window.remainingPercent, total: 100).tint(tint)
        }
    }
}

private struct WidgetBankedLimit: View {
    let count: Int
    let credit: ResetCredit

    var body: some View {
        if let expiry = credit.expiresAt {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 5) {
                        Text("Banked reset").font(.caption.bold())
                        Spacer()
                        Text("\(count) · \(CountdownDisplay.string(until: expiry, from: context.date))")
                            .font(.caption2.monospacedDigit())
                            .lineLimit(1)
                            .minimumScaleFactor(0.72)
                    }
                    ProgressView(value: credit.remainingLifetimeFraction(at: context.date) ?? 0, total: 1)
                        .tint(.teal)
                }
            }
        }
    }
}

private struct ResetBadge: View {
    let count: Int
    var body: some View { Label("\(count)", systemImage: "arrow.counterclockwise").font(.caption.bold()).padding(.horizontal, 7).padding(.vertical, 4).background(.quaternary, in: .capsule) }
}

struct UsageLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: UsageActivityAttributes.self) { context in
            LiveLockView(attributes: context.attributes, state: context.state)
                .activityBackgroundTint(.black)
                .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    ProviderPercentStack(state: context.state, expanded: true)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    if let expiry = context.state.nextBankedResetExpiresAt {
                        VStack(spacing: 1) {
                            Text("Banked")
                            LiveActivityCountdown(expiry: expiry)
                        }
                        .font(.headline)
                        .foregroundStyle(.white)
                    }
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(spacing: 6) {
                        if let reset = context.state.primaryResetsAt {
                            HStack { Text(context.state.primaryTitle ?? "Usage reset"); Spacer(); LiveActivityCountdown(expiry: reset) }
                        }
                        if let reset = context.state.secondaryResetsAt {
                            HStack(spacing: 6) {
                                Text(context.state.secondaryTitle ?? "Usage reset")
                                Spacer()
                                if let used = context.state.secondaryUsedPercent {
                                    Text("\(Int(100 - used))%")
                                }
                                LiveActivityCountdown(expiry: reset)
                            }
                        }
                        if let expiry = context.state.nextBankedResetExpiresAt {
                            HStack { Text("Next banked expiry"); Spacer(); LiveActivityCountdown(expiry: expiry) }
                        }
                    }
                    .foregroundStyle(.white)
                }
            } compactLeading: {
                ProviderPercentStack(state: context.state)
            } compactTrailing: {
                CompactBankedStack(state: context.state)
            } minimal: {
                ProviderMark(providerID: context.state.primaryProviderID)
            }
        }
    }
}

private struct ProviderPercentStack: View {
    let state: UsageActivityAttributes.ContentState
    var expanded = false

    var body: some View {
        VStack(spacing: expanded ? 3 : 0) {
            ProviderMark(providerID: state.primaryProviderID)
                .frame(width: expanded ? 20 : 12, height: expanded ? 20 : 12)
            if let used = state.primaryUsedPercent {
                Text("\(Int(100 - used))%")
                    .font(expanded ? .headline : .system(size: 9, weight: .semibold))
                    .monospacedDigit()
            }
        }
        .foregroundStyle(.white)
    }
}

private struct ProviderMark: View {
    let providerID: ProviderID?

    var body: some View {
        if let providerID {
            ProviderIcon(providerID: providerID)
        } else {
            Image(systemName: "gauge.with.dots.needle.33percent")
                .resizable()
                .scaledToFit()
        }
    }
}

private struct CompactBankedStack: View {
    let state: UsageActivityAttributes.ContentState

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let expiry = state.nextBankedResetExpiresAt {
                Text("Banked")
                LiveActivityCountdown(expiry: expiry)
            } else if let reset = state.primaryResetsAt {
                Text("Reset")
                LiveActivityCountdown(expiry: reset)
            } else {
                Text("—")
            }
        }
        .font(.system(size: 9, weight: .semibold))
        .foregroundStyle(.white)
    }
}

private struct LiveActivityCountdown: View {
    let expiry: Date

    var body: some View {
        let now = Date.now
        Group {
            if expiry > now {
                Text(timerInterval: now...expiry, countsDown: true, showsHours: true)
            } else {
                Text("0:00")
            }
        }
        .monospacedDigit()
        .lineLimit(1)
        .minimumScaleFactor(0.6)
    }
}

private struct BankedCountdown: View {
    let expiry: Date

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            Text(CountdownDisplay.string(until: expiry, from: context.date))
                .monospacedDigit()
        }
    }
}

private struct UsageCountdown: View {
    let reset: Date

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            Text(CountdownDisplay.usageString(until: reset, from: context.date))
                .monospacedDigit()
        }
    }
}

private struct LiveLockView: View {
    let attributes: UsageActivityAttributes
    let state: UsageActivityAttributes.ContentState
    var body: some View {
        VStack(spacing: 12) {
            HStack {
                Text(attributes.accountName).font(.headline)
                Spacer()
                if state.availableResets > 0 { ResetBadge(count: state.availableResets) }
            }
            if let used = state.primaryUsedPercent, let reset = state.primaryResetsAt {
                HStack {
                    VStack(alignment: .leading) {
                        Text(state.primaryTitle ?? "Usage limit").font(.caption)
                        Text("\(Int(100 - used))% left").font(.title2.bold())
                    }
                    Spacer()
                    VStack(alignment: .trailing) { Text("Resets in").font(.caption); LiveActivityCountdown(expiry: reset) }
                }
                ProgressView(value: 100 - used, total: 100).tint(.blue)
            }
            if let used = state.secondaryUsedPercent, let reset = state.secondaryResetsAt {
                HStack(spacing: 8) {
                    Text(state.secondaryTitle ?? "Usage limit").lineLimit(1)
                    Spacer()
                    Text("\(Int(100 - used))%")
                    LiveActivityCountdown(expiry: reset)
                }
                .font(.caption)
                .foregroundStyle(.white.opacity(0.72))
            }
            if let expiry = state.nextBankedResetExpiresAt {
                HStack {
                    Label("Next banked expiry", systemImage: "arrow.counterclockwise.circle")
                    Spacer()
                    LiveActivityCountdown(expiry: expiry)
                }
                .font(.caption)
                .foregroundStyle(.white.opacity(0.72))
            }
        }
        .padding()
        .foregroundStyle(.white)
    }
}
