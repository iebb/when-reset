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
        case speed
        case cache
        case input
        case output

        var id: String { rawValue }

        var title: String {
            switch self {
            case .speed: String.localized("tok/s")
            case .cache: String.localized("Cache")
            case .input: String.localized("Input")
            case .output: String.localized("Output")
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
        case .speed: tokensPerSecond
        case .cache: cache.map(Double.init)
        case .input: input.map(Double.init)
        case .output: output.map(Double.init)
        }
    }
}
