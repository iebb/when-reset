import Foundation

/// A limit reduced to the figures the exhaustion forecast can divide.
///
/// Mac keeps these on its own `UsageWindow`. iOS windows stay untouched: this
/// is the adapter the forecast reads, so the usage bars and their model can
/// keep moving on their own.
struct ForecastWindow: Equatable, Sendable, Identifiable {
    enum Kind: Equatable, Sendable {
        case fiveHour
        case weekly
        case spend
        case balance
        case daily
        case messages
        case monthly
        case topUp
        case other
    }

    var id: String
    var kind: Kind
    var scope: String?
    /// 0...1 under normal conditions. A provider may report past full.
    var usedFraction: Double
    var windowSeconds: Int
    var resetsAt: Date?
    /// False when `windowSeconds` only exists so the row sorts.
    var reportsLength: Bool
    /// Title for a limit that has none of the short forecast names.
    var label: String?

    init(
        id: String,
        kind: Kind,
        scope: String? = nil,
        usedFraction: Double,
        windowSeconds: Int,
        resetsAt: Date?,
        reportsLength: Bool = true,
        label: String? = nil
    ) {
        self.id = id
        self.kind = kind
        self.scope = scope
        self.usedFraction = usedFraction
        self.windowSeconds = windowSeconds
        self.resetsAt = resetsAt
        self.reportsLength = reportsLength
        self.label = label
    }

    /// How much of the window has gone by, or nil when the length was not stated.
    ///
    /// A sort key is also a positive number. Dividing by one would draw a
    /// fraction the provider never gave.
    func elapsedFraction(at now: Date = Date()) -> Double? {
        guard reportsLength, let resetsAt, windowSeconds > 0 else { return nil }
        let remaining = resetsAt.timeIntervalSince(now)
        return min(max(1 - remaining / Double(windowSeconds), 0), 1)
    }

    /// The short name the exhaustion line leads with: "5-hour", "Weekly".
    var forecastName: String {
        let base: String
        switch kind {
        case .fiveHour: base = ForecastCopy.text("Forecast: 5-hour")
        case .weekly: base = ForecastCopy.text("Forecast: weekly")
        case .daily: base = ForecastCopy.text("Forecast: daily")
        case .monthly: base = ForecastCopy.text("Forecast: monthly")
        default:
            if let label {
                let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { return trimmed }
            }
            return ForecastCopy.text("Limit")
        }
        guard let scope, !scope.isEmpty else { return base }
        return "\(base) · \(scope)"
    }
}

extension ForecastWindow {
    /// Maps an iOS usage window onto the forecast model.
    ///
    /// `usedPercent` is 0...100. A missing `windowMinutes` is an unstated
    /// length: weekly and five-hour rows still receive a sort-key duration,
    /// and `reportsLength` stays false so the pace is not divided by it.
    init(_ window: UsageWindow) {
        let minutes = window.windowMinutes
        let kind: Kind
        if window.kind == .fiveHour {
            kind = .fiveHour
        } else if window.kind == .weekly {
            kind = .weekly
        } else if minutes == 300 {
            kind = .fiveHour
        } else if minutes == 10_080 {
            kind = .weekly
        } else if minutes == 1_440 {
            kind = .daily
        } else if let minutes, (28 * 1_440)...(31 * 1_440) ~= minutes {
            kind = .monthly
        } else {
            kind = .other
        }

        let seconds: Int
        if let minutes {
            seconds = minutes * 60
        } else if kind == .weekly {
            seconds = 7 * 24 * 3_600
        } else if kind == .fiveHour {
            seconds = 5 * 3_600
        } else {
            seconds = 0
        }

        let title = window.title.trimmingCharacters(in: .whitespacesAndNewlines)
        self.init(
            id: window.metricID,
            kind: kind,
            scope: nil,
            usedFraction: window.usedPercent / 100,
            windowSeconds: seconds,
            resetsAt: window.reportsReset ? window.resetsAt : nil,
            reportsLength: minutes != nil,
            label: kind == .other && !title.isEmpty ? title : nil
        )
    }
}
