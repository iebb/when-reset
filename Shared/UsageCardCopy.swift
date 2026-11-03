import Foundation

/// Copy for the usage card. The Mac popover is the field list. Rows with no
/// data are omitted by the caller. Estimated value is not a row: iOS has no
/// priced ledger, and the owner asked for no dollar amounts on the card.
enum QuotaResetClock {
    /// "Resets in 3h 29m · tomorrow 1:07 AM" / "3 小时 29 分后重置 · 明天 01:07".
    /// Same day is the time only. Tomorrow is named. Later dates include the day.
    static func subline(until reset: Date, from now: Date, calendar: Calendar = .current) -> String {
        let countdown = CountdownDisplay.resetsInPhrase(until: reset, from: now)
        let clock = absolute(reset, from: now, calendar: calendar)
        return ForecastCopy.format("%@ · %@", countdown, clock)
    }

    static func absolute(_ date: Date, from now: Date, calendar: Calendar = .current) -> String {
        var calendar = calendar
        calendar.locale = AppLanguage.current.locale
        if calendar.isDate(date, inSameDayAs: now) {
            return time(date, calendar: calendar)
        }
        if let tomorrow = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now)),
           calendar.isDate(date, inSameDayAs: tomorrow) {
            return ForecastCopy.format("tomorrow %@", time(date, calendar: calendar))
        }
        return dayAndTime(date, calendar: calendar)
    }

    private static func time(_ date: Date, calendar: Calendar) -> String {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = calendar.locale
        formatter.timeZone = calendar.timeZone
        if AppLanguage.current == .chineseSimplified {
            formatter.dateFormat = "HH:mm"
        } else {
            formatter.setLocalizedDateFormatFromTemplate("jmm")
        }
        return formatter.string(from: date)
    }

    private static func dayAndTime(_ date: Date, calendar: Calendar) -> String {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = calendar.locale
        formatter.timeZone = calendar.timeZone
        if AppLanguage.current == .chineseSimplified {
            formatter.dateFormat = "M月d日 HH:mm"
        } else {
            formatter.setLocalizedDateFormatFromTemplate("MMMdjmm")
        }
        return formatter.string(from: date)
    }

    static func clockTime(_ date: Date, calendar: Calendar = .current) -> String {
        var calendar = calendar
        calendar.locale = AppLanguage.current.locale
        return time(date, calendar: calendar)
    }
}

/// One exhaustion fact. The quota name lives in the value, never in the row label.
struct ExhaustionFact: Equatable, Identifiable, Sendable {
    var id: String
    var value: String
    /// Seconds until empty, when the reading has one. Sorts the urgent rows.
    var seconds: TimeInterval?
    var secondary: String?
    var critical: Bool
    var warning: Bool
}

enum ExhaustionCardCopy {
    static func facts(
        snapshot: UsageSnapshot,
        settings: ForecastSettings,
        now: Date
    ) -> [ExhaustionFact] {
        let windows = snapshot.usageWindows
        let rows = ForecastCardModel.rows(
            windows: windows.map(ForecastWindow.init),
            settings: settings,
            accountID: snapshot.accountID,
            now: now
        )
        let facts = rows.compactMap { row -> ExhaustionFact? in
            guard let window = windows.first(where: { $0.metricID == row.id }) else { return nil }
            return fact(window: window, line: row.line, now: now)
        }
        return facts.sorted { lhs, rhs in
            let left = rank(lhs)
            let right = rank(rhs)
            if left != right { return left < right }
            return (lhs.seconds ?? .infinity) < (rhs.seconds ?? .infinity)
        }
    }

    private static func rank(_ fact: ExhaustionFact) -> Int {
        if fact.critical { return 0 }
        if fact.warning { return 1 }
        return 2
    }

    private static func fact(window: UsageWindow, line: BurnRate.CardLine, now: Date) -> ExhaustionFact? {
        let name = window.displayTitle
        let reading = BurnRate.reading(for: ForecastWindow(window), now: now)
        let seconds = reading?.timeToExhaustion
        switch line.tone {
        case .beforeReset, .countdown:
            guard let seconds else { return nil }
            let critical = window.kind == .fiveHour || window.windowMinutes == 300 || window.remainingPercent < 10 || seconds <= 0
            if seconds <= 0 || window.remainingPercent <= 0 {
                return ExhaustionFact(
                    id: window.metricID,
                    value: ForecastCopy.format("%@ is used up", name),
                    seconds: 0,
                    secondary: nil,
                    critical: true,
                    warning: false
                )
            }
            let when = BurnRate.span(seconds)
            return ExhaustionFact(
                id: window.metricID,
                value: ForecastCopy.format("%@ runs out in ~%@", name, when),
                seconds: seconds,
                secondary: ForecastCopy.text("Before reset · current pace"),
                critical: critical,
                warning: !critical
            )
        case .hint:
            return ExhaustionFact(
                id: window.metricID,
                value: ForecastCopy.format("%@ · may run out before the reset", name),
                seconds: seconds,
                secondary: nil,
                critical: false,
                warning: true
            )
        case .lasts:
            return ExhaustionFact(
                id: window.metricID,
                value: ForecastCopy.format("%@ · %@", name, ForecastCopy.text("Expected to last the window")),
                seconds: nil,
                secondary: nil,
                critical: false,
                warning: false
            )
        }
    }
}

/// Reset-card wording. The count is "可用 N 张" / "N available" on the expanded
/// row, and the collapsed line is the only place that repeats it.
enum ResetCardCopy {
    struct Detail: Equatable, Sendable {
        var countText: String
        var lines: [String]
    }

    static func availableText(count: Int) -> String {
        if count == 1 { return ForecastCopy.text("1 available") }
        return ForecastCopy.format("%lld available", Int64(count))
    }

    /// Soonest expiry, then one line per further card, then a remainder.
    static func detail(snapshot: UsageSnapshot, now: Date, calendar: Calendar = .current) -> Detail? {
        let count = max(snapshot.availableResetCount, snapshot.availableResetCredits.count)
        guard count > 0 else { return nil }
        let credits = snapshot.availableResetCredits.filter { credit in
            guard let expires = credit.expiresAt else { return true }
            return expires > now
        }
        var lines: [String] = []
        let shown = Array(credits.prefix(3))
        for credit in shown {
            if let line = creditLine(credit, now: now, calendar: calendar) {
                lines.append(line)
            }
        }
        let hidden = max(count, credits.count) - shown.count
        if hidden > 0 {
            lines.append(ForecastCopy.format("%lld more", Int64(hidden)))
        }
        if lines.isEmpty, count > credits.count {
            lines.append(ForecastCopy.format("%lld more", Int64(count)))
        }
        return Detail(countText: availableText(count: count), lines: lines)
    }

    static func soonestExpiry(snapshot: UsageSnapshot, now: Date) -> TimeInterval? {
        guard let expires = snapshot.nextBankedResetCredit(after: now)?.expiresAt else { return nil }
        return expires.timeIntervalSince(now)
    }

    private static func creditLine(_ credit: ResetCredit, now: Date, calendar: Calendar) -> String? {
        let expiry = credit.expiresAt.flatMap { date -> String? in
            guard date > now else { return nil }
            return BankedResetCopy.expiresPhrase(until: date, from: now, soonestOfMany: false)
        }
        let deposited = credit.grantedAt.map { depositedPhrase($0, now: now, calendar: calendar) }
        switch (expiry, deposited) {
        case let (expiry?, deposited?):
            return ForecastCopy.format("%@ · %@", expiry, deposited)
        case let (expiry?, nil):
            return expiry
        case let (nil, deposited?):
            return deposited
        case (nil, nil):
            return nil
        }
    }

    private static func depositedPhrase(_ date: Date, now: Date, calendar: Calendar) -> String {
        var calendar = calendar
        calendar.locale = AppLanguage.current.locale
        let clock = QuotaResetClock.clockTime(date, calendar: calendar)
        if calendar.isDate(date, inSameDayAs: now) {
            return ForecastCopy.format("banked today %@", clock)
        }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: calendar.startOfDay(for: now)),
           calendar.isDate(date, inSameDayAs: yesterday) {
            return ForecastCopy.format("banked yesterday %@", clock)
        }
        return ForecastCopy.format("banked %@", QuotaResetClock.absolute(date, from: now, calendar: calendar))
    }
}

/// Short right-hand value for 预测重置. The confidence and bound stay on the line under it.
enum PredictedResetCopy {
    static func shortCountdown(status: CodexResetStatus?, now: Date) -> String? {
        guard let date = instant(status, now: now) else { return nil }
        let when = BurnRate.span(date.timeIntervalSince(now))
        guard !when.isEmpty else { return nil }
        return ForecastCopy.format("in ~%@", when)
    }

    private static func instant(_ status: CodexResetStatus?, now: Date) -> Date? {
        switch status?.card {
        case .scheduled(let date):
            return date > now ? date : nil
        case .watch(let watch):
            guard let ends = watch.windowEnds, ends > now else { return nil }
            return ends
        default:
            return nil
        }
    }
}

/// What the collapsed disclosure says on the left. Empty when nothing is worth a line.
struct CollapsedUsageSummary: Equatable, Sendable {
    enum Tone: Equatable, Sendable {
        case warning
        case critical
        case neutral
    }

    var primary: String?
    var tone: Tone
    var secondary: String?

    static func make(
        exhaustions: [ExhaustionFact],
        resetLine: String?,
        resetExpiresIn: TimeInterval?
    ) -> CollapsedUsageSummary {
        let critical = exhaustions.first { $0.critical }
        let warning = exhaustions.first { $0.warning }
        let calm = exhaustions.first { !$0.warning && !$0.critical }
        let cardSoon = (resetExpiresIn ?? .infinity) < 3_600
        if let critical {
            return CollapsedUsageSummary(primary: critical.value, tone: .critical, secondary: resetLine)
        }
        if cardSoon, let resetLine {
            let support = warning?.value ?? calm?.value
            return CollapsedUsageSummary(primary: resetLine, tone: .warning, secondary: support)
        }
        if let warning {
            return CollapsedUsageSummary(primary: warning.value, tone: .warning, secondary: resetLine)
        }
        if let resetLine {
            return CollapsedUsageSummary(primary: resetLine, tone: .neutral, secondary: calm?.value)
        }
        if let calm {
            return CollapsedUsageSummary(primary: calm.value, tone: .neutral, secondary: nil)
        }
        return CollapsedUsageSummary(primary: nil, tone: .neutral, secondary: nil)
    }
}
