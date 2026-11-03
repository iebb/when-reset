import Foundation

/// The last twelve months of token counts, one number per calendar day.
///
/// The window matches Blinky Mac: it starts at today minus one year plus one
/// day, pulled forward when that would need a 54th week column, and each
/// column starts on the calendar's first weekday. A day before the first
/// record is unrecorded. A day after the first record with no work is zero.
/// Days outside the window and after today are not drawn.
struct TokenActivity: Equatable, Sendable {
    struct Day: Equatable, Sendable {
        var date: Date
        var tokens: Int
    }

    struct Week: Equatable, Sendable, Identifiable {
        var start: Date
        /// Seven positions. Nil where nothing is drawn.
        var days: [Day?]
        /// True where a day is inside the window, not after today, and before
        /// the first record: a placeholder, never a count.
        var unrecorded: [Bool]

        var id: Date { start }
        var drawn: [Day] { days.compactMap { $0 } }
        var tokens: Int { drawn.reduce(0) { $0 + $1.tokens } }
    }

    struct Point: Equatable, Sendable {
        var date: Date
        var running: Int
        var position: Double
    }

    var weeks: [Week] = []
    var total = 0
    var activeDays = 0
    /// Quartile bounds of the busy days, so one huge day does not flatten the year.
    var cuts: [Int] = []
    var hasPartialCounts = false

    var isEmpty: Bool { weeks.isEmpty }
    var columnCount: Int { weeks.count }

    /// 0 for a quiet day, 1–4 for a day with work.
    func step(for tokens: Int) -> Int {
        guard tokens > 0 else { return 0 }
        return 1 + cuts.count { tokens > $0 }
    }

    var points: [Point] {
        var running = 0
        var result: [Point] = []
        for (column, week) in weeks.enumerated() {
            for (row, day) in week.days.enumerated() {
                guard let day else { continue }
                running += day.tokens
                result.append(Point(
                    date: day.date,
                    running: running,
                    position: Double(column) + (Double(row) + 0.5) / 7
                ))
            }
        }
        return result
    }

    static func window(today: Date, calendar: Calendar) -> (start: Date, gridStart: Date) {
        let weekStart = { (date: Date) in calendar.dateInterval(of: .weekOfYear, for: date)?.start ?? date }
        let year = calendar.date(byAdding: .year, value: -1, to: today) ?? today
        let candidate = calendar.startOfDay(for: calendar.date(byAdding: .day, value: 1, to: year) ?? year)
        let longest = calendar.date(byAdding: .weekOfYear, value: -52, to: weekStart(today)) ?? candidate
        let start = max(candidate, longest)
        return (start, weekStart(start))
    }

    /// The year to `now`, from one token count per day.
    ///
    /// Only days with work belong in `days`. A missing day after the first
    /// record is a quiet zero. Counts on or before the window start, and any
    /// day after today, are left out.
    static func of(
        days: [Date: Int],
        hasPartialCounts: Bool = false,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> TokenActivity {
        let today = calendar.startOfDay(for: now)
        let (start, gridStart) = window(today: today, calendar: calendar)

        var tokensByDay: [Date: Int] = [:]
        var first: Date?
        for (raw, tokens) in days where tokens > 0 {
            let date = calendar.startOfDay(for: raw)
            first = min(first ?? date, date)
            guard date >= start, date <= today else { continue }
            tokensByDay[date, default: 0] += tokens
        }
        guard let first, first <= today else { return TokenActivity() }
        let firstDrawn = max(first, start)

        var activity = TokenActivity()
        var cursor = gridStart
        while cursor <= today {
            var column: [Day?] = []
            var unrecorded: [Bool] = []
            var date = cursor
            for _ in 0..<7 {
                if date >= firstDrawn, date <= today {
                    column.append(Day(date: date, tokens: tokensByDay[date] ?? 0))
                } else {
                    column.append(nil)
                }
                unrecorded.append(date >= start && date < firstDrawn)
                guard let next = calendar.date(byAdding: .day, value: 1, to: date) else { break }
                date = calendar.startOfDay(for: next)
            }
            while column.count < 7 { column.append(nil) }
            while unrecorded.count < 7 { unrecorded.append(false) }
            activity.weeks.append(Week(start: cursor, days: column, unrecorded: unrecorded))
            cursor = date
        }

        let busy = activity.weeks.flatMap(\.drawn).map(\.tokens).filter { $0 > 0 }.sorted()
        activity.total = busy.reduce(0, +)
        activity.activeDays = busy.count
        if !busy.isEmpty {
            activity.cuts = (1...3).map { quarter in
                busy[min(busy.count - 1, max((busy.count * quarter + 3) / 4 - 1, 0))]
            }
        }
        activity.hasPartialCounts = hasPartialCounts && activity.total > 0
        return activity
    }
}

/// Which drawing of the year the Token activity section shows.
enum TokenActivityChart: String, CaseIterable, Identifiable, Sendable {
    case daily
    case weekly
    case cumulative

    static let `default` = TokenActivityChart.daily

    var id: String { rawValue }

    var title: String {
        switch self {
        case .daily: String.localized("Daily")
        case .weekly: String.localized("Weekly")
        case .cumulative: String.localized("Cumulative")
        }
    }
}

/// One model row in the Performance table under Token activity.
///
/// The speed column is tokens per second. The section is named Performance.
/// A figure nobody recorded is left off the table, not shown as zero.
struct TokenPerformanceRow: Equatable, Identifiable, Sendable {
    var name: String
    var cache: Int?
    var input: Int?
    var output: Int?
    var tokensPerSecond: Double?

    var id: String { name }
}

struct TokenPerformanceTable: Equatable, Sendable {
    enum Column: String, CaseIterable, Identifiable, Sendable {
        case cache
        case input
        case output
        case speed

        var id: String { rawValue }

        var title: String {
            switch self {
            case .cache: String.localized("Cache")
            case .input: String.localized("Input")
            case .output: String.localized("Output")
            case .speed: String.localized("Speed")
            }
        }
    }

    var rows: [TokenPerformanceRow]
    var columns: [Column]

    /// Performance sits under Token activity only when some row has a figure.
    static func make(_ rows: [TokenPerformanceRow]) -> TokenPerformanceTable? {
        let columns = Column.allCases.filter { column in
            rows.contains { $0.value(for: column) != nil }
        }
        guard !rows.isEmpty, !columns.isEmpty else { return nil }
        return TokenPerformanceTable(rows: rows, columns: columns)
    }
}

extension TokenPerformanceRow {
    func value(for column: TokenPerformanceTable.Column) -> Double? {
        switch column {
        case .cache: cache.map(Double.init)
        case .input: input.map(Double.init)
        case .output: output.map(Double.init)
        case .speed: tokensPerSecond
        }
    }
}

/// One model's tokens on one day. Cache, input, and output partition `total`.
/// A missing cache is unreported, not zero.
struct TokenModelUsage: Equatable, Sendable, Identifiable {
    var name: String
    var cache: Int?
    var input: Int
    var output: Int
    var tokensPerSecond: Double?

    var id: String { name }
    var total: Int { (cache ?? 0) + input + output }
}

struct TokenDayUsage: Equatable, Sendable {
    var date: Date
    var models: [TokenModelUsage]
    var total: Int { models.reduce(0) { $0 + $1.total } }
}

/// The performance block's window. Independent of how the year chart is drawn.
enum TokenPerformanceSpan: String, CaseIterable, Identifiable, Sendable {
    case sevenDays
    case thirtyDays
    case all

    static let `default` = TokenPerformanceSpan.thirtyDays

    var id: String { rawValue }

    var title: String {
        switch self {
        case .sevenDays: String.localized("7d")
        case .thirtyDays: String.localized("30d")
        case .all: String.localized("All")
        }
    }

    var caption: String {
        switch self {
        case .sevenDays: String.localized("Last 7 days")
        case .thirtyDays: String.localized("Last 30 days")
        case .all: String.localized("Last 12 months")
        }
    }

    /// Rolling length. Nil means the same twelve-month window as the chart.
    var dayCount: Int? {
        switch self {
        case .sevenDays: 7
        case .thirtyDays: 30
        case .all: nil
        }
    }
}

struct TokenSpanSummary: Equatable, Sendable {
    var total = 0
    /// Cache reads divided by cache reads plus fresh input. Nil when nobody reported cache.
    var cacheHit: Double?
    var averageSpeed: Double?
    var models: [TokenModelUsage] = []
}

enum TokenSpanMath {
    private struct Bucket {
        var cache: Int?
        var input = 0
        var output = 0
        var speedWeight = 0
        var speedSum = 0.0
    }

    static func summary(
        records: [TokenDayUsage],
        span: TokenPerformanceSpan,
        now: Date = .now,
        calendar: Calendar = .current
    ) -> TokenSpanSummary {
        let today = calendar.startOfDay(for: now)
        let filtered = records.filter { record in
            let day = calendar.startOfDay(for: record.date)
            guard day <= today else { return false }
            if let count = span.dayCount {
                let start = calendar.date(byAdding: .day, value: -(count - 1), to: today) ?? today
                return day >= calendar.startOfDay(for: start)
            }
            return day >= TokenActivity.window(today: today, calendar: calendar).start
        }

        var buckets: [String: Bucket] = [:]
        var order: [String] = []
        for record in filtered {
            for model in record.models {
                var bucket = buckets[model.name] ?? Bucket()
                if buckets[model.name] == nil { order.append(model.name) }
                bucket.input += model.input
                bucket.output += model.output
                if let cache = model.cache {
                    bucket.cache = (bucket.cache ?? 0) + cache
                }
                if let speed = model.tokensPerSecond, model.total > 0 {
                    bucket.speedWeight += model.total
                    bucket.speedSum += speed * Double(model.total)
                }
                buckets[model.name] = bucket
            }
        }

        var models: [TokenModelUsage] = order.compactMap { name in
            guard let bucket = buckets[name] else { return nil }
            return TokenModelUsage(
                name: name,
                cache: bucket.cache,
                input: bucket.input,
                output: bucket.output,
                tokensPerSecond: bucket.speedWeight > 0 ? bucket.speedSum / Double(bucket.speedWeight) : nil
            )
        }
        models.sort { $0.total > $1.total }
        let cache = models.reduce(0) { $0 + ($1.cache ?? 0) }
        let input = models.reduce(0) { $0 + $1.input }
        let speedWeight = models.reduce(0) { $0 + ($1.tokensPerSecond == nil ? 0 : $1.total) }
        let speedSum = models.reduce(0.0) { partial, model in
            guard let speed = model.tokensPerSecond else { return partial }
            return partial + speed * Double(model.total)
        }
        let hit: Double?
        if models.contains(where: { $0.cache != nil }), cache + input > 0 {
            hit = Double(cache) / Double(cache + input)
        } else {
            hit = nil
        }
        return TokenSpanSummary(
            total: models.reduce(0) { $0 + $1.total },
            cacheHit: hit,
            averageSpeed: speedWeight > 0 ? speedSum / Double(speedWeight) : nil,
            models: models
        )
    }
}
