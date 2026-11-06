#if os(iOS)
import Observation
import SwiftUI
import UIKit

/// Token activity, then performance for a chosen span. With no local transcripts
/// the page explains that instead of drawing an empty chart. Screenshot launches
/// supply a sample year whose parts add up to each day's total.
struct TokenActivitySettingsView: View {
    @State private var chart: TokenActivityChart
    @State private var span: TokenPerformanceSpan

    init() {
        let initialChart: TokenActivityChart
        #if DEBUG
        initialChart = ScreenshotLaunch.isActive ? ScreenshotLaunch.tokenChart : .daily
        #else
        initialChart = .daily
        #endif
        _chart = State(initialValue: initialChart)
        _span = State(initialValue: .default)
    }

    private var records: [TokenDayUsage] { TokenRecordStore.shared.records }

    private var activity: TokenActivity {
        let days = Dictionary(records.map { ($0.date, $0.total) }, uniquingKeysWith: +)
        return TokenActivity.of(days: days, hasPartialCounts: TokenRecordStore.shared.hasPartialCounts)
    }

    private var summary: TokenSpanSummary {
        TokenSpanMath.summary(records: records, span: span)
    }

    var body: some View {
        Form {
            if records.isEmpty {
                EmptyView()
            } else {
                Section {
                    VStack(alignment: .leading, spacing: 12) {
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
                        .font(.footnote.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        TokenActivityPlot(activity: activity, chart: chart)
                        if activity.hasPartialCounts {
                            Text("Counts may be incomplete.")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .listRowInsets(EdgeInsets(top: 12, leading: 16, bottom: 12, trailing: 16))
                .listRowSeparator(.hidden)
                .blinkySettingsSection()

                Section {
                    TokenPerformanceCard(summary: summary, span: $span)
                } header: {
                    Text("Performance")
                }
                .listRowSeparator(.hidden)
                .blinkySettingsSection()
            }
        }
        .blinkySettingsCanvas()
        .navigationTitle("Token activity")
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// Day counts and per-model splits. Empty until a reader supplies them.
@MainActor
@Observable
final class TokenRecordStore {
    static let shared = TokenRecordStore()

    var records: [TokenDayUsage] = []
    var hasPartialCounts = false

    private init() {
        #if DEBUG
        guard ScreenshotLaunch.isActive, ScreenshotLaunch.seedsTokenActivity else { return }
        records = ScreenshotLaunch.tokenActivityRecords()
        #endif
    }
}

private enum TokenActivityText {
    static func count(_ value: Int) -> String {
        let locale = AppLanguage.current.locale
        let chinese = AppLanguage.current == .chineseSimplified
        if chinese {
            if value >= 100_000_000 {
                return number(Double(value) / 100_000_000, locale: locale) + "亿"
            }
            if value >= 10_000 {
                return number(Double(value) / 10_000, locale: locale) + "万"
            }
        } else if value >= 1_000_000_000 {
            return number(Double(value) / 1_000_000_000, locale: locale) + "B"
        } else if value >= 1_000_000 {
            return number(Double(value) / 1_000_000, locale: locale) + "M"
        } else if value >= 1_000 {
            return number(Double(value) / 1_000, locale: locale) + "K"
        }
        return value.formatted(.number.grouping(.automatic).locale(locale))
    }

    static func percent(_ value: Double) -> String {
        (value * 100).formatted(
            .number.precision(.fractionLength(0)).locale(AppLanguage.current.locale)
        ) + "%"
    }

    static func speed(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(0...1)).locale(AppLanguage.current.locale))
    }

    private static func number(_ value: Double, locale: Locale) -> String {
        value.formatted(
            .number.precision(.fractionLength(value < 10 ? 1 : 0)).grouping(.never).locale(locale)
        )
    }
}

private struct HeatmapHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 108
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

private struct HeatmapOffsetKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

private struct TokenActivityPlot: View {
    let activity: TokenActivity
    let chart: TokenActivityChart
    @Environment(\.interfaceStyle) private var interfaceStyle
    @Environment(\.locale) private var locale
    @State private var heatmapOffset: CGFloat = 0
    @State private var didMeasureHeatmap = false
    @State private var gridHeight: CGFloat = 108

    private let visibleColumns = 26
    private let gutter: CGFloat = 18
    private let gutterGap: CGFloat = 4

    private var cellRadius: CGFloat {
        interfaceStyle == .screenTime ? 1 : 2
    }

    var body: some View {
        Group {
            switch chart {
            case .daily:
                VStack(alignment: .leading, spacing: 14) {
                    daily
                    legend
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
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// The scroll view's ideal width is its content, which would collapse the
    /// grid. A clear row takes the card width, and the overlay reads that width.
    private var daily: some View {
        Color.clear
            .frame(maxWidth: .infinity)
            .frame(height: gridHeight)
            .overlay(alignment: .top) {
                GeometryReader { proxy in
                    let pitch = max((proxy.size.width - gutter - gutterGap) / CGFloat(visibleColumns), 1)
                    let columns = CGFloat(max(activity.weeks.count, 1))
                    let height = 14 + 2 + pitch * 7
                    HStack(alignment: .top, spacing: gutterGap) {
                        weekdayGutter(pitch: pitch)
                            .frame(width: gutter)
                        VStack(alignment: .leading, spacing: 2) {
                            monthLabelBar(
                                pitch: pitch,
                                contentWidth: pitch * columns,
                                viewportWidth: max(proxy.size.width - gutter - gutterGap, 1)
                            )
                            .frame(height: 14)
                            ScrollView(.horizontal, showsIndicators: false) {
                                dayCells(pitch: pitch)
                                    .frame(width: pitch * columns, height: pitch * 7)
                                    .background {
                                        GeometryReader { geo in
                                            Color.clear.preference(
                                                key: HeatmapOffsetKey.self,
                                                value: geo.frame(in: .named("tokenHeatmap")).minX
                                            )
                                        }
                                    }
                            }
                            .coordinateSpace(name: "tokenHeatmap")
                            .defaultScrollAnchor(.trailing)
                            .contentMargins(.horizontal, 0, for: .scrollContent)
                            .mask { heatmapMask }
                            .onPreferenceChange(HeatmapOffsetKey.self) { value in
                                heatmapOffset = value
                                if value != 0 { didMeasureHeatmap = true }
                            }
                        }
                    }
                    .preference(key: HeatmapHeightKey.self, value: height)
                }
            }
            .onPreferenceChange(HeatmapHeightKey.self) { gridHeight = $0 }
    }

    /// Older weeks sit off the left edge. A short fade says the row continues that way.
    private var heatmapMask: some View {
        let showOlder = !didMeasureHeatmap || heatmapOffset < -1
        return HStack(spacing: 0) {
            if showOlder {
                LinearGradient(
                    colors: [.clear, .black],
                    startPoint: .leading,
                    endPoint: .trailing
                )
                .frame(width: 18)
            }
            Rectangle().fill(.black)
        }
    }

    private func weekdayGutter(pitch: CGFloat) -> some View {
        let calendar = Calendar.current
        return VStack(alignment: .leading, spacing: 2) {
            Color.clear.frame(height: 14)
            VStack(spacing: 0) {
                ForEach(0..<7, id: \.self) { row in
                    Text(weekdayLabel(row: row, calendar: calendar))
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                        .frame(height: pitch, alignment: .leading)
                }
            }
        }
    }

    private func weekdayLabel(row: Int, calendar: Calendar) -> String {
        guard let start = activity.weeks.first?.start,
              let date = calendar.date(byAdding: .day, value: row, to: start) else { return "" }
        switch calendar.component(.weekday, from: date) {
        case 2: return chineseWeekdays ? "一" : "M"
        case 4: return chineseWeekdays ? "三" : "W"
        case 6: return chineseWeekdays ? "五" : "F"
        default: return ""
        }
    }

    /// `.weekday(.narrow)` is "1/3/5" in zh-Hans. These marks match M/W/F.
    private var chineseWeekdays: Bool {
        if AppLanguage.current == .chineseSimplified { return true }
        return locale.language.languageCode?.identifier.hasPrefix("zh") == true
    }

    private func monthLabelBar(pitch: CGFloat, contentWidth: CGFloat, viewportWidth: CGFloat) -> some View {
        let trailing = max(contentWidth - viewportWidth, 0)
        let visibleOrigin = didMeasureHeatmap
            ? min(max(-heatmapOffset, 0), trailing)
            : trailing
        let marks = placedMonthLabels(
            pitch: pitch,
            contentWidth: contentWidth,
            visibleOrigin: visibleOrigin,
            viewportWidth: viewportWidth
        )
        return ZStack(alignment: .topLeading) {
            ForEach(marks, id: \.index) { mark in
                Text(mark.title)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize()
                    .offset(x: mark.x)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .clipped()
    }

    /// Labels sit in the viewport, not in the scrolling cells, so a name is
    /// either fully inside the card or not drawn. The last name is pulled
    /// left rather than clipped to "Ma".
    private func placedMonthLabels(
        pitch: CGFloat,
        contentWidth: CGFloat,
        visibleOrigin: CGFloat,
        viewportWidth: CGFloat
    ) -> [(index: Int, title: String, x: CGFloat)] {
        let candidates = monthMarks(calendar: Calendar.current)
        var placed: [(index: Int, title: String, x: CGFloat)] = []
        for mark in candidates.reversed() {
            let width = monthLabelWidth(mark.title)
            let natural = pitch * CGFloat(mark.index)
            let contentX = min(natural, max(contentWidth - width, 0))
            var viewX = contentX - visibleOrigin
            if viewX + width > viewportWidth {
                viewX = viewportWidth - width
            }
            guard viewX >= 0, viewX + width <= viewportWidth + 0.5 else { continue }
            if let next = placed.last, viewX + width + 4 > next.x { continue }
            placed.append((mark.index, mark.title, viewX))
        }
        return Array(placed.reversed())
    }

    private func monthLabelWidth(_ title: String) -> CGFloat {
        let font = UIFont.systemFont(ofSize: 11)
        return ceil((title as NSString).size(withAttributes: [.font: font]).width) + 1
    }

    private func monthMarks(calendar: Calendar) -> [(index: Int, title: String)] {
        var candidates: [(index: Int, title: String)] = []
        var seen = Set<String>()
        for (index, week) in activity.weeks.enumerated() {
            let month = calendar.component(.month, from: week.start)
            let year = calendar.component(.year, from: week.start)
            guard seen.insert("\(year)-\(month)").inserted else { continue }
            let title = week.start.formatted(.dateTime.month(.abbreviated).locale(locale))
            candidates.append((index, title))
        }
        var kept: [(index: Int, title: String)] = []
        var lastIndex: Int?
        for mark in candidates.reversed() {
            if let lastIndex, lastIndex - mark.index < 4 { continue }
            kept.append(mark)
            lastIndex = mark.index
        }
        return Array(kept.reversed())
    }

    private func dayCells(pitch: CGFloat) -> some View {
        HStack(alignment: .top, spacing: 0) {
            ForEach(activity.weeks) { week in
                VStack(spacing: 0) {
                    ForEach(0..<7, id: \.self) { row in
                        RoundedRectangle(cornerRadius: cellRadius, style: .continuous)
                            .fill(fill(week: week, row: row))
                            .padding(1)
                            .frame(width: pitch, height: pitch)
                            .accessibilityHidden(true)
                    }
                }
            }
        }
    }

    private var legend: some View {
        HStack(spacing: 3) {
            Text("Less")
            ForEach(0..<5, id: \.self) { step in
                RoundedRectangle(cornerRadius: cellRadius, style: .continuous)
                    .fill(stepColor(step))
                    .frame(width: 9, height: 9)
            }
            Text("More")
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
        .accessibilityHidden(true)
    }

    private var weeklyBars: some View {
        let peak = max(activity.weeks.map(\.tokens).max() ?? 1, 1)
        return HStack(alignment: .bottom, spacing: 2) {
            ForEach(activity.weeks) { week in
                RoundedRectangle(cornerRadius: cellRadius, style: .continuous)
                    .fill(week.tokens > 0 ? Color.accentColor : Color.primary.opacity(0.12))
                    .frame(maxWidth: .infinity)
                    .frame(height: max(3, 72 * CGFloat(week.tokens) / CGFloat(peak)))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: 76)
    }

    private var cumulativeLine: some View {
        let points = activity.points
        let minPosition = points.first?.position ?? 0
        let maxPosition = points.last?.position ?? 1
        let span = max(maxPosition - minPosition, 0.001)
        return GeometryReader { proxy in
            let maxRunning = max(points.map(\.running).max() ?? 1, 1)
            Path { path in
                for (index, point) in points.enumerated() {
                    let x = proxy.size.width * CGFloat((point.position - minPosition) / span)
                    let y = proxy.size.height * (1 - CGFloat(point.running) / CGFloat(maxRunning))
                    if index == 0 { path.move(to: CGPoint(x: x, y: y)) }
                    else { path.addLine(to: CGPoint(x: x, y: y)) }
                }
            }
            .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
        }
        .frame(height: 76)
        .frame(maxWidth: .infinity)
    }

    private func fill(week: TokenActivity.Week, row: Int) -> Color {
        if row < week.unrecorded.count, week.unrecorded[row], week.days[row] == nil {
            return Color.primary.opacity(0.06)
        }
        guard let day = week.days[row] else { return .clear }
        return stepColor(activity.step(for: day.tokens))
    }

    private func stepColor(_ step: Int) -> Color {
        switch step {
        case 0: return Color.primary.opacity(0.12)
        case 1: return Color.accentColor.opacity(0.30)
        case 2: return Color.accentColor.opacity(0.52)
        case 3: return Color.accentColor.opacity(0.76)
        default: return Color.accentColor
        }
    }
}

private struct TokenPerformanceCard: View {
    let summary: TokenSpanSummary
    @Binding var span: TokenPerformanceSpan
    @State private var expanded: Set<String> = {
        #if DEBUG
        if ScreenshotLaunch.isActive, ScreenshotLaunch.screen == "tokenActivityExpanded" {
            return ["grok-4"]
        }
        #endif
        return []
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("Performance", selection: $span) {
                ForEach(TokenPerformanceSpan.allCases) { item in
                    Text(item.title).tag(item)
                }
            }
            .pickerStyle(.segmented)
            .accessibilityIdentifier("token-performance-span")
            Text(span.caption)
                .font(.caption)
                .foregroundStyle(.secondary)
            summaryRow
            splitLegend
            VStack(alignment: .leading, spacing: 10) {
                ForEach(summary.models) { model in
                    modelRow(model)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityIdentifier("token-performance")
    }

    private var summaryRow: some View {
        HStack(alignment: .top, spacing: 8) {
            figure(TokenActivityText.count(summary.total), caption: "Total tokens")
            figure(summary.cacheHit.map(TokenActivityText.percent) ?? "—", caption: "Cache hit")
            speedFigure(summary.averageSpeed)
        }
    }

    private func speedFigure(_ value: Double?) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            if let value {
                HStack(alignment: .firstTextBaseline, spacing: 3) {
                    Text(TokenActivityText.speed(value))
                        .font(.title3.weight(.semibold).monospacedDigit())
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                    Text("tok/s")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            } else {
                Text("—")
                    .font(.title3.weight(.semibold))
            }
            Text("Avg speed")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func figure(_ value: String, caption: LocalizedStringKey) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value)
                .font(.title3.weight(.semibold).monospacedDigit())
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(caption)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var splitLegend: some View {
        HStack(spacing: 10) {
            legendItem(Color.accentColor, "Cache")
            legendItem(Color.accentColor.opacity(0.55), "Input")
            legendItem(Color.accentColor.opacity(0.28), "Output")
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
        .accessibilityHidden(true)
    }

    private func legendItem(_ color: Color, _ title: LocalizedStringKey) -> some View {
        HStack(spacing: 4) {
            RoundedRectangle(cornerRadius: 1, style: .continuous)
                .fill(color)
                .frame(width: 10, height: 4)
            Text(title)
        }
    }

    private func modelRow(_ model: TokenModelUsage) -> some View {
        let open = expanded.contains(model.id)
        return Button {
            if open { expanded.remove(model.id) } else { expanded.insert(model.id) }
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(model.name)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                    Spacer(minLength: 8)
                    Text(TokenActivityText.count(model.total))
                        .font(.subheadline.monospacedDigit())
                    if let speed = model.tokensPerSecond {
                        Text("\(TokenActivityText.speed(speed)) \(String.localized("tok/s"))")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
                splitBar(model)
                if open {
                    detail("Cache", model.cache.map(TokenActivityText.count) ?? "—")
                    detail("Input", TokenActivityText.count(model.input))
                    detail("Output", TokenActivityText.count(model.output))
                }
            }
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("token-model-\(model.id)")
    }

    private func splitBar(_ model: TokenModelUsage) -> some View {
        let total = CGFloat(max(model.total, 1))
        let cache = CGFloat(model.cache ?? 0)
        let input = CGFloat(model.input)
        let output = CGFloat(model.output)
        return GeometryReader { proxy in
            HStack(spacing: 0) {
                if cache > 0 {
                    Color.accentColor.frame(width: proxy.size.width * cache / total)
                }
                if input > 0 {
                    Color.accentColor.opacity(0.55).frame(width: proxy.size.width * input / total)
                }
                if output > 0 {
                    Color.accentColor.opacity(0.28).frame(width: proxy.size.width * output / total)
                }
            }
        }
        .frame(height: 4)
        .frame(maxWidth: .infinity)
        .background(Color.primary.opacity(0.08), in: Capsule())
        .clipShape(Capsule())
    }

    private func detail(_ title: LocalizedStringKey, _ value: String) -> some View {
        HStack {
            Text(title)
                .foregroundStyle(.secondary)
            Spacer(minLength: 8)
            Text(value)
                .monospacedDigit()
                .foregroundStyle(value == "—" ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.primary))
        }
        .font(.caption)
    }
}
#endif
