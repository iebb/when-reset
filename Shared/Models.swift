import Foundation

enum ProviderID: String, Codable, CaseIterable, Sendable {
    case chatGPT = "chatgpt"
    case claude = "claude"

    var displayName: String {
        switch self { case .chatGPT: "ChatGPT"; case .claude: "Claude" }
    }

    var supportsBankedResets: Bool { self == .chatGPT }
}

enum LiveActivityMode: String, Codable, CaseIterable, Sendable {
    case manual, always, nearReset
    var title: String {
        switch self { case .manual: "Manual"; case .always: "Always"; case .nearReset: "Near reset" }
    }
}

struct AccountMonitorSettings: Codable, Hashable, Sendable {
    var liveActivityMode: LiveActivityMode = .manual
    var nearResetMinutes: Int = 120
    var showBankedResets = true
    var hiddenMetricIDs: Set<String> = []
    var showBankedResetsInLiveActivity = true
    var hiddenLiveActivityMetricIDs: Set<String> = []

    init(liveActivityMode: LiveActivityMode = .manual, nearResetMinutes: Int = 120,
         showBankedResets: Bool = true, hiddenMetricIDs: Set<String> = [],
         showBankedResetsInLiveActivity: Bool = true, hiddenLiveActivityMetricIDs: Set<String> = []) {
        self.liveActivityMode = liveActivityMode
        self.nearResetMinutes = nearResetMinutes
        self.showBankedResets = showBankedResets
        self.hiddenMetricIDs = hiddenMetricIDs
        self.showBankedResetsInLiveActivity = showBankedResetsInLiveActivity
        self.hiddenLiveActivityMetricIDs = hiddenLiveActivityMetricIDs
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        liveActivityMode = try values.decodeIfPresent(LiveActivityMode.self, forKey: .liveActivityMode) ?? .manual
        nearResetMinutes = try values.decodeIfPresent(Int.self, forKey: .nearResetMinutes) ?? 120
        showBankedResets = try values.decodeIfPresent(Bool.self, forKey: .showBankedResets) ?? true
        hiddenMetricIDs = try values.decodeIfPresent(Set<String>.self, forKey: .hiddenMetricIDs) ?? []
        showBankedResetsInLiveActivity = try values.decodeIfPresent(Bool.self, forKey: .showBankedResetsInLiveActivity) ?? true
        hiddenLiveActivityMetricIDs = try values.decodeIfPresent(Set<String>.self, forKey: .hiddenLiveActivityMetricIDs) ?? []
    }

    func shows(_ window: UsageWindow) -> Bool { !hiddenMetricIDs.contains(window.metricID) }
    func showsInLiveActivity(_ window: UsageWindow) -> Bool { !hiddenLiveActivityMetricIDs.contains(window.metricID) }
}

struct GlobalLiveActivitySettings: Codable, Hashable, Sendable {
    var mode: LiveActivityMode = .manual
    var nearResetMinutes: Int = 120
}

struct MonitoredAccount: Identifiable, Codable, Hashable, Sendable {
    var id: UUID
    var providerID: ProviderID
    var displayName: String
    var workspaceID: String
    var plan: String?
    var addedAt: Date
}

enum UsageWindowKind: String, Codable, Hashable, Sendable {
    case fiveHour, weekly, additional
}

struct UsageWindow: Codable, Hashable, Sendable {
    var title: String
    var usedPercent: Double
    var resetsAt: Date
    var windowMinutes: Int?
    var kind: UsageWindowKind? = nil
    var identifier: String? = nil

    var remainingPercent: Double { max(0, min(100, 100 - usedPercent)) }

    var displayTitle: String {
        if kind == .additional { return title }
        return switch windowMinutes {
        case 300: "5h limit"
        case 10_080: "Weekly limit"
        default: title
        }
    }

    var displayOrder: Int {
        if kind == .additional { return 2 }
        return switch windowMinutes {
        case 300: 0
        case 10_080: 1
        default: 2
        }
    }

    var metricID: String {
        if let identifier { return identifier }
        switch kind {
        case .fiveHour: return "five_hour"
        case .weekly: return "weekly"
        case .additional: return "additional:\(title)"
        case nil:
            switch windowMinutes {
            case 300: return "five_hour"
            case 10_080: return "weekly"
            default: return "limit:\(title)"
            }
        }
    }
}

struct ResetCredit: Identifiable, Codable, Hashable, Sendable {
    var id: String
    var expiresAt: Date?
    var status: String?
    var grantedAt: Date? = nil

    var isAvailable: Bool {
        status == nil || status?.localizedCaseInsensitiveCompare("available") == .orderedSame
    }

    func remainingLifetimeFraction(at date: Date = .now) -> Double? {
        guard let grantedAt, let expiresAt, expiresAt > grantedAt else { return nil }
        return max(0, min(1, expiresAt.timeIntervalSince(date) / expiresAt.timeIntervalSince(grantedAt)))
    }
}

enum CountdownDisplay {
    static func string(until expiry: Date, from date: Date = .now) -> String {
        let remaining = max(0, Int(expiry.timeIntervalSince(date).rounded(.down)))
        let days = remaining / 86_400
        let hours = (remaining % 86_400) / 3_600
        let minutes = (remaining % 3_600) / 60
        let seconds = remaining % 60
        let clock = String(format: "%02d:%02d:%02d", hours, minutes, seconds)
        return days > 0 ? "\(days) day\(days == 1 ? "" : "s"), \(clock)" : clock
    }

    /// A readable countdown for usage-limit rows. Long windows are intentionally
    /// reduced to whole days so a weekly reset does not dominate compact layouts.
    static func usageString(until expiry: Date, from date: Date = .now) -> String {
        let remaining = max(0, Int(expiry.timeIntervalSince(date).rounded(.down)))
        if remaining > 48 * 3_600 {
            let days = remaining / 86_400
            return "\(days) day\(days == 1 ? "" : "s")"
        }
        return string(until: expiry, from: date)
    }

    static func compactString(until expiry: Date, from date: Date = .now) -> String {
        let remainingSeconds = max(0, Int(expiry.timeIntervalSince(date).rounded(.down)))
        if remainingSeconds > 48 * 3_600 { return "\(remainingSeconds / 86_400)d" }
        let remainingMinutes = remainingSeconds / 60
        if remainingMinutes < 100 { return "\(remainingMinutes)m" }
        return "\(remainingMinutes / 60)h"
    }
}

struct UsageSnapshot: Codable, Hashable, Sendable {
    var accountID: UUID
    var providerName: String
    var accountName: String
    var plan: String?
    var primary: UsageWindow?
    var secondary: UsageWindow?
    var availableResetCount: Int
    var resetCredits: [ResetCredit]
    var fetchedAt: Date
    var extraWindows: [UsageWindow]? = nil

    var availableResetCredits: [ResetCredit] {
        resetCredits
            .filter(\.isAvailable)
            .sorted { ($0.expiresAt ?? .distantFuture) < ($1.expiresAt ?? .distantFuture) }
    }

    var usageWindows: [UsageWindow] {
        ([primary, secondary].compactMap { $0 } + (extraWindows ?? []))
            .sorted {
                if $0.displayOrder != $1.displayOrder { return $0.displayOrder < $1.displayOrder }
                if ($0.windowMinutes ?? .max) != ($1.windowMinutes ?? .max) {
                    return ($0.windowMinutes ?? .max) < ($1.windowMinutes ?? .max)
                }
                return $0.displayTitle.localizedCaseInsensitiveCompare($1.displayTitle) == .orderedAscending
            }
    }

    func filtered(using settings: AccountMonitorSettings) -> UsageSnapshot {
        var result = self
        if let primary, !settings.shows(primary) { result.primary = nil }
        if let secondary, !settings.shows(secondary) { result.secondary = nil }
        result.extraWindows = extraWindows?.filter(settings.shows)
        if !settings.showBankedResets {
            result.availableResetCount = 0
            result.resetCredits = []
        }
        return result
    }

    func filteredForLiveActivity(using settings: AccountMonitorSettings) -> UsageSnapshot {
        var result = self
        if let primary, !settings.showsInLiveActivity(primary) { result.primary = nil }
        if let secondary, !settings.showsInLiveActivity(secondary) { result.secondary = nil }
        result.extraWindows = extraWindows?.filter(settings.showsInLiveActivity)
        if !settings.showBankedResetsInLiveActivity {
            result.availableResetCount = 0
            result.resetCredits = []
        }
        return result
    }

    func nextBankedResetExpiry(after date: Date = .now) -> Date? {
        nextBankedResetCredit(after: date)?.expiresAt
    }

    func nextBankedResetCredit(after date: Date = .now) -> ResetCredit? {
        availableResetCredits.first { ($0.expiresAt ?? .distantPast) > date }
    }

    static func nearestBankedResetExpiry(in snapshots: [UsageSnapshot], after date: Date = .now) -> Date? {
        snapshots.compactMap { $0.nextBankedResetExpiry(after: date) }.min()
    }

    static let preview = UsageSnapshot(
        accountID: UUID(), providerName: "ChatGPT", accountName: "Personal", plan: "Pro",
        primary: UsageWindow(title: "5 hour", usedPercent: 37, resetsAt: .now.addingTimeInterval(5_400), windowMinutes: 300),
        secondary: UsageWindow(title: "Weekly", usedPercent: 68, resetsAt: .now.addingTimeInterval(180_000), windowMinutes: 10_080),
        availableResetCount: 2,
        resetCredits: [
            ResetCredit(id: "preview-1", expiresAt: .now.addingTimeInterval(21_600), status: "available",
                        grantedAt: .now.addingTimeInterval(-8_400)),
            ResetCredit(id: "preview-2", expiresAt: .now.addingTimeInterval(86_400), status: "available",
                        grantedAt: .now.addingTimeInterval(-3_600))
        ],
        fetchedAt: .now
    )
}
