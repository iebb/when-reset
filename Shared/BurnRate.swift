import Foundation

/// Looks up a catalog key and fills `%@` arguments.
///
/// The strings are the same keys Blinky Mac ships. Interpolation goes through
/// `String(format:)` so the catalog key is the literal, including `%@`.
enum ForecastCopy {
    static func text(_ key: String) -> String {
        String.localized(String.LocalizationValue(stringLiteral: key))
    }

    static func format(_ key: String, _ arguments: CVarArg...) -> String {
        String(format: text(key), locale: AppLanguage.current.locale, arguments: arguments)
    }
}

/// How a limit is being spent against its own window.
///
/// Everything here comes from one reading. How much is gone and how far
/// through the window the clock is are both in it already, so the pace is
/// the difference between two figures the provider reported. No history is
/// kept. A window that has turned over simply reports a small elapsed share
/// again.
///
/// Two statements, and they are not equally trustworthy:
///
/// 1. The verdict — "expected to last". A yes or a no.
/// 2. When — "in about an hour", or, on a weekly window, "in 1d 13h".
///    The card states a time only inside the reader's horizon.
enum BurnRate {
    /// Below this, a window that is still lightly used is not divided. Three
    /// percent of a week is about five hours. Little spent does not need that
    /// division to be called on course (`earlyQuietUsed`).
    ///
    /// Use already at that share is divided. A heavy week right after reset
    /// is when the estimate is wanted. The card keeps the ordinary wording
    /// and adds a quieter line that the early pace is only a guide.
    static let minimumElapsed = 0.03

    /// Used share below which a window still inside `minimumElapsed` is said
    /// to be on course, with no time. At or above it, a stated length is
    /// divided even inside the floor.
    static let earlyQuietUsed = 0.05

    /// Used share below which a window with no stated length, and a reset
    /// still ahead, is said to be on course. The sentence does not divide.
    /// At or above this share there is no pace to invent, so the line stays
    /// quiet. With no reset at all, only `earlyQuietUsed` is said to last.
    static let lightUnstatedUsed = 0.25

    struct Reading: Equatable, Sendable {
        /// Whether it is on course to run out before the window resets.
        let exhaustsBeforeReset: Bool
        /// How long until it runs out, when that is before the reset.
        /// Nil when the window lasts, or when nothing may be divided.
        let timeToExhaustion: TimeInterval?
        /// The window is still inside `minimumElapsed`, use is already at
        /// `earlyQuietUsed`, and a length was stated, so the figures above
        /// are the ordinary division.
        let earlyPace: Bool

        init(
            exhaustsBeforeReset: Bool,
            timeToExhaustion: TimeInterval?,
            earlyPace: Bool = false
        ) {
            self.exhaustsBeforeReset = exhaustsBeforeReset
            self.timeToExhaustion = timeToExhaustion
            self.earlyPace = earlyPace
        }
    }

    /// What may be said about a window, or nil when nothing may be.
    static func reading(for window: ForecastWindow, now: Date = Date()) -> Reading? {
        let used = min(max(window.usedFraction, 0), 1)
        guard let elapsed = window.elapsedFraction(at: now),
              let resetsAt = window.resetsAt
        else {
            return unpaced(used: used, resetsAt: window.resetsAt, now: now)
        }

        let untilReset = resetsAt.timeIntervalSince(now)
        guard untilReset > 0 else { return nil }

        if elapsed < minimumElapsed, used < earlyQuietUsed {
            return Reading(exhaustsBeforeReset: false, timeToExhaustion: nil)
        }
        let earlyPace = elapsed < minimumElapsed

        let elapsedSeconds = untilReset / (1 - elapsed) * elapsed
        guard elapsedSeconds > 0 else { return nil }

        let perHour = used / elapsedSeconds * 3600
        guard used < 1, perHour > 0 else {
            return Reading(
                exhaustsBeforeReset: used >= 1,
                timeToExhaustion: used >= 1 ? 0 : nil,
                earlyPace: earlyPace
            )
        }

        let untilEmpty = (1 - used) / perHour * 3600
        let first = untilEmpty < untilReset
        return Reading(
            exhaustsBeforeReset: first,
            timeToExhaustion: first ? untilEmpty : nil,
            earlyPace: earlyPace
        )
    }

    /// No elapsed share, so nothing may be divided. The length was a sort key,
    /// or the reset was never stated.
    private static func unpaced(used: Double, resetsAt: Date?, now: Date) -> Reading? {
        guard let resetsAt else {
            guard used < earlyQuietUsed else { return nil }
            return Reading(exhaustsBeforeReset: false, timeToExhaustion: nil)
        }
        guard resetsAt.timeIntervalSince(now) > 0, used < lightUnstatedUsed else { return nil }
        return Reading(exhaustsBeforeReset: false, timeToExhaustion: nil)
    }

    /// "about an hour", "about 40 minutes", "1d 13h" — rounded, because the
    /// precision is not real. Past a day the same idea is a count of days
    /// and hours. English drops the word "about" on day spans; the catalog
    /// does that, so this function does not special-case the language.
    static func approximate(_ seconds: TimeInterval) -> String {
        switch rounded(seconds) {
        case .underQuarter:
            return ForecastCopy.text("under 15 minutes")
        case .minutes(let minutes):
            return ForecastCopy.format("about %@ minutes", "\(minutes)")
        case .hour:
            return ForecastCopy.text("about an hour")
        case .hours(let text):
            return ForecastCopy.format("about %@ hours", text)
        case .days(let days, nil):
            return ForecastCopy.format("about %@d", "\(days)")
        case .days(let days, let hours?):
            return ForecastCopy.format("about %@d %@h", "\(days)", "\(hours)")
        }
    }

    /// The same rounding, without the word "about". The reset sentence
    /// already says "about".
    static func span(_ seconds: TimeInterval) -> String {
        switch rounded(seconds) {
        case .underQuarter:
            return ForecastCopy.format("%@ minutes", "15")
        case .minutes(let minutes):
            return ForecastCopy.format("%@ minutes", "\(minutes)")
        case .hour:
            return ForecastCopy.text("1 hour")
        case .hours(let text):
            return ForecastCopy.format("%@ hours", text)
        case .days(let days, nil):
            return ForecastCopy.format("%@d", "\(days)")
        case .days(let days, let hours?):
            return ForecastCopy.format("%@d %@h", "\(days)", "\(hours)")
        }
    }

    /// What the card draws under one limit, or nil when this setting leaves
    /// the row quiet.
    struct CardLine: Equatable, Sendable {
        enum Tone: Equatable, Sendable {
            /// Inside the reader's horizon: the window's name and a time.
            case countdown
            /// Further out, but before the reset, with the time said once.
            case beforeReset
            /// The same fact, without a time.
            case hint
            /// On course to last.
            case lasts
        }

        let text: String
        /// One short line for the collapsed card. `text` is the full sentence.
        let brief: String
        let tone: Tone
        /// A quieter line under `text`. Set only while `Reading.earlyPace`
        /// is true and the line is an exhaustion estimate, not the
        /// "expected to last" sentence.
        let note: String?

        /// The forecast, and the early-pace note when there is one.
        var spoken: String {
            guard let note, !note.isEmpty else { return text }
            return "\(text) \(note)"
        }
    }

    /// The line under a limit.
    ///
    /// A time only inside `horizon`. Past that, the reset sentence when they
    /// asked for it, otherwise the quieter hint, otherwise nothing about an
    /// exhaustion that is still only a verdict. A window that lasts still
    /// says so. A reading divided inside the early floor keeps that wording
    /// and adds the early-pace note.
    static func cardLine(
        for window: ForecastWindow,
        reading: Reading,
        horizon: TimeInterval,
        softHint: Bool,
        beforeReset: Bool
    ) -> CardLine? {
        if let seconds = reading.timeToExhaustion, seconds <= horizon {
            let name = window.forecastName
            let when = approximate(seconds)
            return stated(
                ForecastCopy.format("%@ · may run out in %@", name, when),
                tone: .countdown,
                reading: reading
            )
        }
        if reading.exhaustsBeforeReset, beforeReset, let seconds = reading.timeToExhaustion {
            // `seconds` is time from now until the quota hits zero, and only
            // when that moment is still before the reset. It is not the gap
            // between empty and the reset, and it is not time past the reset.
            let when = span(seconds)
            return stated(
                ForecastCopy.format("At the current pace, runs out in about %@.", when),
                brief: ForecastCopy.format("Runs out in ~%@", compactSpan(seconds)),
                tone: .beforeReset,
                reading: reading
            )
        }
        if reading.exhaustsBeforeReset, softHint {
            let name = window.forecastName
            return stated(
                ForecastCopy.format("%@ · may run out before the reset", name),
                tone: .hint,
                reading: reading
            )
        }
        if !reading.exhaustsBeforeReset {
            return stated(
                ForecastCopy.text("Expected to last the window"),
                brief: ForecastCopy.text("At this pace: lasts until reset"),
                tone: .lasts,
                reading: reading
            )
        }
        return nil
    }

    private static func stated(
        _ text: String,
        brief: String? = nil,
        tone: CardLine.Tone,
        reading: Reading
    ) -> CardLine {
        CardLine(
            text: text,
            brief: brief ?? text,
            tone: tone,
            note: reading.earlyPace && tone != .lasts
                ? ForecastCopy.text("A fast start. The estimate is only a guide.")
                : nil
        )
    }

    /// A short count for the collapsed card: "19.5h", "1d 13h".
    static func compactSpan(_ seconds: TimeInterval) -> String {
        switch rounded(seconds) {
        case .underQuarter:
            return ForecastCopy.text("<15m")
        case .minutes(let minutes):
            return ForecastCopy.format("%@m", "\(minutes)")
        case .hour:
            return ForecastCopy.text("1h")
        case .hours(let text):
            return ForecastCopy.format("%@h", text)
        case .days(let days, nil):
            return ForecastCopy.format("%@d", "\(days)")
        case .days(let days, let hours?):
            return ForecastCopy.format("%@d %@h", "\(days)", "\(hours)")
        }
    }

    /// The line the card draws under one window.
    ///
    /// The weekly limit may say it is expected to last, or when it runs out.
    /// With no weekly limit, the longest other stated limit may. A shorter
    /// window that states a length — the five-hour limit — may say when its
    /// own pace runs out before its reset. It does not say it will last.
    static func forecastLine(
        for window: ForecastWindow,
        among windows: [ForecastWindow],
        showsForecast: Bool,
        horizon: TimeInterval,
        softHint: Bool,
        beforeReset: Bool,
        now: Date = Date()
    ) -> CardLine? {
        guard showsForecast else { return nil }
        guard let reading = reading(for: window, now: now) else { return nil }
        if !ExhaustionEstimate.includes(window, among: windows),
           !statesOwnExhaustion(window, reading: reading) {
            return nil
        }
        return cardLine(
            for: window,
            reading: reading,
            horizon: horizon,
            softHint: softHint,
            beforeReset: beforeReset
        )
    }

    /// A window the weekly line leaves out, stating the time it runs out.
    ///
    /// The length has to be one the provider reported, and the pace has to
    /// run out before this window's own reset. Balance, a top-up, messages,
    /// and spend are not that line. A window that will last stays quiet.
    private static func statesOwnExhaustion(_ window: ForecastWindow, reading: Reading) -> Bool {
        guard window.reportsLength,
              reading.exhaustsBeforeReset,
              reading.timeToExhaustion != nil
        else { return false }
        switch window.kind {
        case .balance, .topUp, .messages, .spend:
            return false
        case .fiveHour, .weekly, .daily, .monthly, .other:
            return true
        }
    }

    private enum Rounded: Equatable {
        case underQuarter
        case minutes(Int)
        case hour
        case hours(String)
        case days(Int, Int?)
    }

    /// Under an hour in quarters; past that in halves of an hour, until a
    /// day, and then in whole hours beside whole days. The cut under an hour
    /// is at 68 rather than 75 because five quarters is an hour and a
    /// quarter — printing "about 75 minutes" between "about an hour" and
    /// "about 1.5 hours" reads as a different scale for one step.
    private static func rounded(_ seconds: TimeInterval) -> Rounded {
        let minutes = Int((max(seconds, 0) / 60).rounded())
        if minutes < 15 { return .underQuarter }
        if minutes < 68 {
            let quarters = max(Int((Double(minutes) / 15).rounded()), 1)
            return quarters >= 4 ? .hour : .minutes(quarters * 15)
        }
        let hours = (Double(minutes) / 60 * 2).rounded() / 2
        if hours < 24 {
            let text = hours.formatted(
                .number.precision(.fractionLength(0...1))
                    .locale(Locale(identifier: "en_US_POSIX"))
            )
            return .hours(text)
        }
        let whole = Int(hours.rounded())
        let days = whole / 24
        let rest = whole % 24
        return .days(max(days, 1), rest == 0 ? nil : rest)
    }
}

/// How the forecast line is inked.
///
/// Lasting is green. A pace that may not last the window is amber. Both sit
/// under full strength so the line stays quieter than the percentage beside it.
struct ForecastLineInk: Equatable, Sendable {
    enum Hue: Equatable, Sendable {
        case green
        case amber
    }

    enum Weight: Equatable, Sendable {
        case regular
        case medium
    }

    var hue: Hue
    var weight: Weight

    /// Held back from 1 so neither green nor amber reads as a second alarm.
    static let opacity = 0.66

    static func style(for tone: BurnRate.CardLine.Tone) -> ForecastLineInk {
        switch tone {
        case .lasts:
            ForecastLineInk(hue: .green, weight: .regular)
        case .countdown, .beforeReset, .hint:
            ForecastLineInk(hue: .amber, weight: .medium)
        }
    }
}

/// Whole hours still left. The card horizon and the Mac remaining-time
/// notices share this clamp: one hour through fourteen days.
struct ExhaustionStage: Equatable, Sendable {
    static let minimumHours = 1
    static let maximumHours = 24 * 14

    static func clamped(_ hours: Int) -> Int {
        min(max(hours, minimumHours), maximumHours)
    }
}

/// The hours the settings stepper shows, and the value it writes.
enum ExhaustionHoursControl {
    static func applied(_ hours: Int) -> Int {
        ExhaustionStage.clamped(hours)
    }

    static func digits(_ hours: Int) -> String {
        String(applied(hours))
    }
}
