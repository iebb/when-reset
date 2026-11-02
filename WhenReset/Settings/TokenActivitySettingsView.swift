#if os(iOS)
import Observation
import SwiftUI

/// Token activity, then Performance when a span has a speed or a cache,
/// input, or output split. iOS does not scan local agent transcripts yet, so
/// the page is empty until a record source is connected.
struct TokenActivitySettingsView: View {
    @State private var chart = TokenActivityChart.default

    private var activity: TokenActivity {
        TokenActivity.of(days: TokenRecordStore.shared.days, hasPartialCounts: TokenRecordStore.shared.hasPartialCounts)
    }

    private var performance: TokenPerformanceTable? {
        TokenPerformanceTable.make(TokenRecordStore.shared.performance)
    }

    var body: some View {
        Form {
            Section {
                if activity.isEmpty {
                    Text("No token records on this iPhone yet.")
                        .foregroundStyle(.secondary)
                } else {
                    Picker("Token activity", selection: $chart) {
                        ForEach(TokenActivityChart.allCases) { mode in
                            Text(mode.title).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                    .accessibilityIdentifier("token-activity-chart")
                    Text(String(
                        format: String.localized("%@ tokens in the last 12 months"),
                        locale: AppLanguage.current.locale,
                        TokenActivityText.count(activity.total)
                    ))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    TokenActivityPlot(activity: activity, chart: chart)
                    if activity.hasPartialCounts {
                        Text("Counts may be incomplete.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text("Token activity")
            }

            if let performance {
                Section {
                    TokenPerformanceList(table: performance)
                } header: {
                    Text("Performance")
                }
            }
        }
        .navigationTitle("Token activity")
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// Day counts and performance rows. Empty until a reader supplies them.
@MainActor
@Observable
final class TokenRecordStore {
    static let shared = TokenRecordStore()

    var days: [Date: Int] = [:]
    var hasPartialCounts = false
    var performance: [TokenPerformanceRow] = []

    private init() {}
}

private enum TokenActivityText {
    static func count(_ value: Int) -> String {
        value.formatted(.number.grouping(.automatic))
    }
}

private struct TokenActivityPlot: View {
    let activity: TokenActivity
    let chart: TokenActivityChart

    var body: some View {
        switch chart {
        case .daily:
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 2) {
                    ForEach(activity.weeks) { week in
                        VStack(spacing: 2) {
                            ForEach(0..<7, id: \.self) { row in
                                RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                                    .fill(fill(week: week, row: row))
                                    .frame(width: 8, height: 8)
                            }
                        }
                    }
                }
                .padding(.vertical, 4)
            }
            .accessibilityIdentifier("token-activity-daily")
        case .weekly:
            weeklyBars
                .accessibilityIdentifier("token-activity-weekly")
        case .cumulative:
            cumulativeLine
                .accessibilityIdentifier("token-activity-cumulative")
        }
    }

    private var weeklyBars: some View {
        let peak = max(activity.weeks.map(\.tokens).max() ?? 1, 1)
        return HStack(alignment: .bottom, spacing: 3) {
            ForEach(activity.weeks) { week in
                Capsule()
                    .fill(week.tokens > 0 ? Color.accentColor : Color.primary.opacity(0.12))
                    .frame(width: 6, height: max(4, 72 * CGFloat(week.tokens) / CGFloat(peak)))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: 76)
    }

    private var cumulativeLine: some View {
        let points = activity.points
        return GeometryReader { proxy in
            let maxRunning = max(points.map(\.running).max() ?? 1, 1)
            let lastColumn = max(Double(activity.columnCount), 1)
            Path { path in
                for (index, point) in points.enumerated() {
                    let x = proxy.size.width * CGFloat(point.position / lastColumn)
                    let y = proxy.size.height * (1 - CGFloat(point.running) / CGFloat(maxRunning))
                    if index == 0 { path.move(to: CGPoint(x: x, y: y)) }
                    else { path.addLine(to: CGPoint(x: x, y: y)) }
                }
            }
            .stroke(Color.accentColor, lineWidth: 2)
        }
        .frame(height: 76)
    }

    private func fill(week: TokenActivity.Week, row: Int) -> Color {
        if row < week.unrecorded.count, week.unrecorded[row], week.days[row] == nil {
            return Color.primary.opacity(0.06)
        }
        guard let day = week.days[row] else { return .clear }
        switch activity.step(for: day.tokens) {
        case 0: return Color.primary.opacity(0.12)
        case 1: return Color.accentColor.opacity(0.30)
        case 2: return Color.accentColor.opacity(0.52)
        case 3: return Color.accentColor.opacity(0.76)
        default: return Color.accentColor
        }
    }
}

private struct TokenPerformanceList: View {
    let table: TokenPerformanceTable

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(" ")
                Spacer()
                ForEach(table.columns) { column in
                    Text(column.title)
                        .frame(width: 64, alignment: .trailing)
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            ForEach(table.rows) { row in
                HStack {
                    Text(row.name).lineLimit(1)
                    Spacer(minLength: 8)
                    ForEach(table.columns) { column in
                        Text(text(row.value(for: column), column: column))
                            .frame(width: 64, alignment: .trailing)
                            .foregroundStyle(row.value(for: column) == nil ? .tertiary : .primary)
                    }
                }
                .font(.subheadline.monospacedDigit())
            }
        }
        .accessibilityIdentifier("token-performance")
    }

    private func text(_ value: Double?, column: TokenPerformanceTable.Column) -> String {
        guard let value else { return "—" }
        switch column {
        case .speed:
            return value.formatted(.number.precision(.fractionLength(0...1)))
        case .cache, .input, .output:
            return Int(value).formatted(.number.grouping(.automatic))
        }
    }
}
#endif
