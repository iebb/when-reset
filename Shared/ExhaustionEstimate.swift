import Foundation

/// Which limit the remaining-time line may use, and which limit may say the
/// window is expected to last.
///
/// The weekly limit, when the reading has one. A five-hour window is never
/// one of them: it turns over several times a day, and a pace taken from it
/// is not what that sentence is for. A reading with no weekly limit uses its
/// longest other limit that states a length. A reading whose only limit is
/// five hours has nothing for that sentence to estimate.
///
/// The card is wider than this set. `BurnRate.forecastLine` still writes a
/// time under a length-stated window this set leaves out — the five-hour
/// limit — when that window's own pace runs out before its reset. That line
/// does not say the short window will last, and this set does not use it.
enum ExhaustionEstimate {
    /// Five hours, whether or not the provider's row was classified as that kind.
    static let fiveHourSeconds = 5 * 3_600

    static func windows(in windows: [ForecastWindow]) -> [ForecastWindow] {
        let periods = windows.filter(isTimeLimit)
        let weekly = periods.filter { $0.kind == .weekly }
        if !weekly.isEmpty { return weekly }
        let measurable = periods.filter(\.reportsLength)
        guard let longest = measurable.max(by: { prefersShorter($0, $1) }) else { return [] }
        return [longest]
    }

    static func includes(_ window: ForecastWindow, among windows: [ForecastWindow]) -> Bool {
        self.windows(in: windows).contains { $0.id == window.id }
    }

    private static func isTimeLimit(_ window: ForecastWindow) -> Bool {
        if isFiveHour(window) { return false }
        switch window.kind {
        case .balance, .topUp, .messages, .spend:
            return false
        case .fiveHour, .weekly, .daily, .monthly, .other:
            return true
        }
    }

    private static func isFiveHour(_ window: ForecastWindow) -> Bool {
        if case .fiveHour = window.kind { return true }
        return window.windowSeconds == fiveHourSeconds
    }

    /// Shorter first, so `max` keeps the longest. Equal lengths keep the
    /// earlier id, which is the order the card already drew.
    private static func prefersShorter(_ lhs: ForecastWindow, _ rhs: ForecastWindow) -> Bool {
        if lhs.windowSeconds != rhs.windowSeconds { return lhs.windowSeconds < rhs.windowSeconds }
        return lhs.id > rhs.id
    }
}
