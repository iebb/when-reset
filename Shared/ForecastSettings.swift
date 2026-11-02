import Foundation
import Observation

/// The forecast switches. Off-by-default only for the predicted reminder,
/// matching Blinky Mac: the exhaustion line and the public Codex forecast
/// start visible, and the reminder waits until it is asked for.
struct ForecastSettings: Codable, Equatable, Sendable {
    var showsForecast: Bool = true
    var exhaustionCardHours: Int = 6
    var exhaustionSoftHint: Bool = true
    var exhaustionBeforeReset: Bool = true
    var allAccounts: Bool = true
    var accountIDs: [UUID] = []
    /// Public Codex Resets block on ChatGPT cards.
    var showsPredictedReset: Bool = true
    var remindsBeforePredictedReset: Bool = false
    var predictedResetLeadHours: Int = ResetLead.default.rawValue

    private enum CodingKeys: String, CodingKey {
        case showsForecast
        case exhaustionCardHours
        case exhaustionSoftHint
        case exhaustionBeforeReset
        case allAccounts
        case accountIDs
        case showsPredictedReset
        case remindsBeforePredictedReset
        case predictedResetLeadHours
    }

    var horizon: TimeInterval {
        TimeInterval(ExhaustionHoursControl.applied(exhaustionCardHours)) * 3_600
    }

    var predictedLead: TimeInterval {
        TimeInterval(ResetLead.resolved(predictedResetLeadHours).rawValue) * 3_600
    }

    func includes(_ accountID: UUID) -> Bool {
        allAccounts || accountIDs.contains(accountID)
    }

    func normalized() -> ForecastSettings {
        var copy = self
        copy.exhaustionCardHours = ExhaustionHoursControl.applied(exhaustionCardHours)
        copy.predictedResetLeadHours = ResetLead.resolved(predictedResetLeadHours).rawValue
        return copy
    }

    init(
        showsForecast: Bool = true,
        exhaustionCardHours: Int = 6,
        exhaustionSoftHint: Bool = true,
        exhaustionBeforeReset: Bool = true,
        allAccounts: Bool = true,
        accountIDs: [UUID] = [],
        showsPredictedReset: Bool = true,
        remindsBeforePredictedReset: Bool = false,
        predictedResetLeadHours: Int = ResetLead.default.rawValue
    ) {
        self.showsForecast = showsForecast
        self.exhaustionCardHours = exhaustionCardHours
        self.exhaustionSoftHint = exhaustionSoftHint
        self.exhaustionBeforeReset = exhaustionBeforeReset
        self.allAccounts = allAccounts
        self.accountIDs = accountIDs
        self.showsPredictedReset = showsPredictedReset
        self.remindsBeforePredictedReset = remindsBeforePredictedReset
        self.predictedResetLeadHours = predictedResetLeadHours
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        showsForecast = try values.decodeIfPresent(Bool.self, forKey: .showsForecast) ?? true
        exhaustionCardHours = ExhaustionHoursControl.applied(
            try values.decodeIfPresent(Int.self, forKey: .exhaustionCardHours) ?? 6
        )
        exhaustionSoftHint = try values.decodeIfPresent(Bool.self, forKey: .exhaustionSoftHint) ?? true
        exhaustionBeforeReset = try values.decodeIfPresent(Bool.self, forKey: .exhaustionBeforeReset) ?? true
        allAccounts = try values.decodeIfPresent(Bool.self, forKey: .allAccounts) ?? true
        accountIDs = try values.decodeIfPresent([UUID].self, forKey: .accountIDs) ?? []
        showsPredictedReset = try values.decodeIfPresent(Bool.self, forKey: .showsPredictedReset) ?? true
        remindsBeforePredictedReset = try values.decodeIfPresent(
            Bool.self, forKey: .remindsBeforePredictedReset
        ) ?? false
        predictedResetLeadHours = ResetLead.resolved(
            try values.decodeIfPresent(Int.self, forKey: .predictedResetLeadHours) ?? ResetLead.default.rawValue
        ).rawValue
    }

    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(showsForecast, forKey: .showsForecast)
        try values.encode(exhaustionCardHours, forKey: .exhaustionCardHours)
        try values.encode(exhaustionSoftHint, forKey: .exhaustionSoftHint)
        try values.encode(exhaustionBeforeReset, forKey: .exhaustionBeforeReset)
        try values.encode(allAccounts, forKey: .allAccounts)
        try values.encode(accountIDs, forKey: .accountIDs)
        try values.encode(showsPredictedReset, forKey: .showsPredictedReset)
        try values.encode(remindsBeforePredictedReset, forKey: .remindsBeforePredictedReset)
        try values.encode(predictedResetLeadHours, forKey: .predictedResetLeadHours)
    }
}

enum ForecastSettingsDisk {
    static let key = "forecasts.settings.v1"

    static func load(from defaults: UserDefaults = .standard) -> ForecastSettings {
        guard let data = defaults.data(forKey: key),
              let settings = try? JSONDecoder().decode(ForecastSettings.self, from: data) else {
            return ForecastSettings()
        }
        return settings.normalized()
    }

    static func save(_ settings: ForecastSettings, to defaults: UserDefaults = .standard) {
        defaults.set(try? JSONEncoder().encode(settings.normalized()), forKey: key)
    }
}

@MainActor
@Observable
final class ForecastSettingsStore {
    static let shared = ForecastSettingsStore()

    var settings: ForecastSettings {
        didSet {
            let normalized = settings.normalized()
            if normalized != settings {
                settings = normalized
                return
            }
            ForecastSettingsDisk.save(settings)
        }
    }

    private init() {
        settings = ForecastSettingsDisk.load()
    }
}

/// The exhaustion lines for one account, already filtered by the switches.
enum ForecastCardModel {
    struct Row: Identifiable, Equatable, Sendable {
        var id: String
        var line: BurnRate.CardLine
    }

    static func rows(
        windows: [ForecastWindow],
        settings: ForecastSettings,
        accountID: UUID,
        now: Date
    ) -> [Row] {
        guard settings.showsForecast, settings.includes(accountID) else { return [] }
        return windows.compactMap { window in
            guard let line = BurnRate.forecastLine(
                for: window,
                among: windows,
                showsForecast: true,
                horizon: settings.horizon,
                softHint: settings.exhaustionSoftHint,
                beforeReset: settings.exhaustionBeforeReset,
                now: now
            ) else { return nil }
            return Row(id: window.id, line: line)
        }
    }
}
