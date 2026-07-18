import Foundation

enum ProviderID: String, Codable, CaseIterable, Sendable {
    case chatGPT = "chatgpt"
    case claude = "claude"
    case kimi = "kimi"
    case githubCopilot = "github_copilot"
    case zai = "zai"
    case miniMax = "minimax"

    var displayName: String {
        switch self {
        case .chatGPT: "ChatGPT"
        case .claude: "Claude"
        case .kimi: "Kimi Code"
        case .githubCopilot: "GitHub Copilot"
        case .zai: "Z.AI Coding Plan"
        case .miniMax: "MiniMax Token Plan"
        }
    }

    var supportsBankedResets: Bool { self == .chatGPT }

    func sectionTitle(plan: String?) -> String {
        guard let plan = planDisplayName(plan) else { return displayName }
        if plan.localizedCaseInsensitiveCompare(displayName) == .orderedSame
            || plan.lowercased().hasPrefix("\(displayName.lowercased()) ") {
            return plan
        }
        return "\(displayName) \(plan)"
    }

    func planDisplayName(_ plan: String?) -> String? {
        guard let plan else { return nil }
        let trimmed = plan.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let readable = trimmed.replacingOccurrences(of: "_", with: " ")
        guard readable == readable.lowercased() else { return readable }
        return readable.split(separator: " ").map { word in
            let normalized = word.lowercased()
            if normalized.last == "x", normalized.dropLast().allSatisfy(\.isNumber) {
                return normalized
            }
            return String(word).capitalized
        }.joined(separator: " ")
    }

    var accountDescription: String {
        switch self {
        case .chatGPT: "Usage limits and banked resets"
        case .claude: "Session and weekly reset times"
        case .kimi: "5-hour and weekly coding limits"
        case .githubCopilot: "Chat and premium request quotas"
        case .zai: "5-hour, weekly, and monthly limits"
        case .miniMax: "5-hour and weekly coding limits"
        }
    }

    var logoAssetName: String? {
        switch self {
        case .chatGPT: "ChatGPTLogo"
        case .claude: "ClaudeLogo"
        case .kimi: "KimiLogo"
        case .githubCopilot: "CopilotLogo"
        case .zai: "ZAILogo"
        case .miniMax: "MiniMaxLogo"
        }
    }

    var systemImageName: String {
        switch self {
        case .chatGPT, .claude: "circle.fill"
        case .kimi: "moon.stars.fill"
        case .githubCopilot: "chevron.left.forwardslash.chevron.right"
        case .zai: "z.square.fill"
        case .miniMax: "waveform"
        }
    }
}

enum LiveActivityMode: String, Codable, CaseIterable, Sendable {
    case automatic, always, disabled

    var title: String {
        switch self {
        case .automatic: "Automatic"
        case .always: "Always"
        case .disabled: "Do not show Live Activity"
        }
    }

    init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer().decode(String.self)
        self = switch value {
        case "automatic", "nearReset": .automatic
        case "always": .always
        case "disabled", "manual": .disabled
        default: .automatic
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

enum LiveActivityTrigger: String, Codable, CaseIterable, Sendable {
    case remainingPercent
    case remainingHours
    case exhausted
    case never

    var title: String {
        switch self {
        case .remainingPercent: "Percentage remaining"
        case .remainingHours: "Hours remaining"
        case .exhausted: "When exhausted"
        case .never: "Never"
        }
    }
}

struct LiveActivityQuotaRule: Codable, Hashable, Sendable {
    var trigger: LiveActivityTrigger = .remainingHours
    var remainingPercent: Int = 20
    var remainingHours: Double = 4

    init(trigger: LiveActivityTrigger = .remainingHours, remainingPercent: Int = 20,
         remainingHours: Double = 4) {
        self.trigger = trigger
        self.remainingPercent = min(100, max(0, remainingPercent))
        self.remainingHours = max(0, remainingHours)
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        trigger = try values.decodeIfPresent(LiveActivityTrigger.self, forKey: .trigger) ?? .remainingHours
        remainingPercent = min(100, max(0,
            try values.decodeIfPresent(Int.self, forKey: .remainingPercent) ?? 20
        ))
        remainingHours = max(0,
            try values.decodeIfPresent(Double.self, forKey: .remainingHours) ?? 4
        )
    }

    func matches(_ window: UsageWindow, at date: Date = .now) -> Bool {
        guard window.resetsAt > date else { return false }
        return switch trigger {
        case .remainingPercent: window.remainingPercent <= Double(remainingPercent)
        case .remainingHours: window.resetsAt.timeIntervalSince(date) <= remainingHours * 3_600
        case .exhausted: window.remainingPercent <= 0
        case .never: false
        }
    }

    func matches(expiry: Date, at date: Date = .now) -> Bool {
        guard expiry > date else { return false }
        return switch trigger {
        case .remainingHours: expiry.timeIntervalSince(date) <= remainingHours * 3_600
        case .remainingPercent, .exhausted, .never: false
        }
    }
}

struct AccountMonitorSettings: Codable, Hashable, Sendable {
    static let bankedResetMetricID = "banked-resets"

    var showBankedResets = true
    var hiddenMetricIDs: Set<String> = []
    var showBankedResetsInLiveActivity = true
    var hiddenLiveActivityMetricIDs: Set<String> = []
    var pinnedLiveActivityMetricIDs: Set<String> = []
    var defaultLiveActivityRule = LiveActivityQuotaRule()
    var liveActivityQuotaRules: [String: LiveActivityQuotaRule] = [:]
    var bankedResetLiveActivityRule = LiveActivityQuotaRule()

    init(showBankedResets: Bool = true, hiddenMetricIDs: Set<String> = [],
         showBankedResetsInLiveActivity: Bool = true, hiddenLiveActivityMetricIDs: Set<String> = [],
         pinnedLiveActivityMetricIDs: Set<String> = [],
         defaultLiveActivityRule: LiveActivityQuotaRule = .init(),
         liveActivityQuotaRules: [String: LiveActivityQuotaRule] = [:],
         bankedResetLiveActivityRule: LiveActivityQuotaRule = .init()) {
        self.showBankedResets = showBankedResets
        self.hiddenMetricIDs = hiddenMetricIDs
        self.showBankedResetsInLiveActivity = showBankedResetsInLiveActivity
        self.hiddenLiveActivityMetricIDs = hiddenLiveActivityMetricIDs
        self.pinnedLiveActivityMetricIDs = pinnedLiveActivityMetricIDs
        self.defaultLiveActivityRule = defaultLiveActivityRule
        self.liveActivityQuotaRules = liveActivityQuotaRules
        self.bankedResetLiveActivityRule = bankedResetLiveActivityRule
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        showBankedResets = try values.decodeIfPresent(Bool.self, forKey: .showBankedResets) ?? true
        hiddenMetricIDs = try values.decodeIfPresent(Set<String>.self, forKey: .hiddenMetricIDs) ?? []
        showBankedResetsInLiveActivity = try values.decodeIfPresent(Bool.self, forKey: .showBankedResetsInLiveActivity) ?? true
        hiddenLiveActivityMetricIDs = try values.decodeIfPresent(Set<String>.self, forKey: .hiddenLiveActivityMetricIDs) ?? []
        pinnedLiveActivityMetricIDs = try values.decodeIfPresent(
            Set<String>.self, forKey: .pinnedLiveActivityMetricIDs
        ) ?? []
        defaultLiveActivityRule = try values.decodeIfPresent(LiveActivityQuotaRule.self, forKey: .defaultLiveActivityRule) ?? .init()
        liveActivityQuotaRules = try values.decodeIfPresent([String: LiveActivityQuotaRule].self,
                                                            forKey: .liveActivityQuotaRules) ?? [:]
        bankedResetLiveActivityRule = try values.decodeIfPresent(LiveActivityQuotaRule.self,
                                                                 forKey: .bankedResetLiveActivityRule) ?? .init()
    }

    func shows(_ window: UsageWindow) -> Bool { !hiddenMetricIDs.contains(window.metricID) }
    func showsInLiveActivity(_ window: UsageWindow) -> Bool { !hiddenLiveActivityMetricIDs.contains(window.metricID) }
    func isPinnedInLiveActivity(_ window: UsageWindow) -> Bool {
        pinnedLiveActivityMetricIDs.contains(window.metricID)
    }
    var isBankedResetPinnedInLiveActivity: Bool {
        pinnedLiveActivityMetricIDs.contains(Self.bankedResetMetricID)
    }
    func liveActivityRule(for window: UsageWindow) -> LiveActivityQuotaRule {
        liveActivityQuotaRules[window.metricID] ?? defaultLiveActivityRule
    }

    private enum CodingKeys: String, CodingKey {
        case showBankedResets, hiddenMetricIDs, showBankedResetsInLiveActivity, hiddenLiveActivityMetricIDs
        case pinnedLiveActivityMetricIDs
        case defaultLiveActivityRule, liveActivityQuotaRules, bankedResetLiveActivityRule
    }
}

struct GlobalLiveActivitySettings: Codable, Hashable, Sendable {
    var mode: LiveActivityMode = .automatic
    var showRemainingPercentage = true
    var showBankedResets = true

    init(mode: LiveActivityMode = .automatic, showRemainingPercentage: Bool = true,
         showBankedResets: Bool = true) {
        self.mode = mode
        self.showRemainingPercentage = showRemainingPercentage
        self.showBankedResets = showBankedResets
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        mode = try values.decodeIfPresent(LiveActivityMode.self, forKey: .mode) ?? .automatic
        showRemainingPercentage = try values.decodeIfPresent(Bool.self,
                                                             forKey: .showRemainingPercentage) ?? true
        showBankedResets = try values.decodeIfPresent(Bool.self, forKey: .showBankedResets) ?? true
    }
}

struct ProviderAccountDetails: Equatable, Sendable {
    var profileName: String? = nil
    var displayName: String? = nil
    var email: String? = nil
    var plan: String? = nil
    var planExpiresAt: Date? = nil
    var trialExpiresAt: Date? = nil
    var replacesMissingFields = false
}

struct MonitoredAccount: Identifiable, Codable, Hashable, Sendable {
    static let demoWorkspaceID = "when-reset.demo.chatgpt"

    var id: UUID
    var providerID: ProviderID
    var displayName: String
    var workspaceID: String
    var plan: String?
    var addedAt: Date
    var customDisplayName: String? = nil
    var customSymbolName: String? = nil
    var profileName: String? = nil
    var email: String? = nil
    var planExpiresAt: Date? = nil
    var trialExpiresAt: Date? = nil

    var isDemo: Bool {
        providerID == .chatGPT && workspaceID == Self.demoWorkspaceID
    }

    var resolvedDisplayName: String {
        let custom = customDisplayName?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let custom, !custom.isEmpty { return custom }
        let remote = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        return remote.isEmpty ? providerID.displayName : remote
    }

    mutating func mergeProviderDetails(_ details: ProviderAccountDetails) {
        if details.replacesMissingFields {
            profileName = Self.nonEmpty(details.profileName).map { String($0.prefix(128)) }
            email = Self.nonEmpty(details.email)
            plan = Self.nonEmpty(details.plan)
            planExpiresAt = details.planExpiresAt
            trialExpiresAt = details.trialExpiresAt
        } else {
            if let reportedName = Self.nonEmpty(details.profileName) {
                profileName = String(reportedName.prefix(128))
            }
            if let reportedEmail = Self.nonEmpty(details.email) { email = reportedEmail }
            if let reportedPlan = Self.nonEmpty(details.plan) { plan = reportedPlan }
            if let reportedExpiry = details.planExpiresAt { planExpiresAt = reportedExpiry }
            if let reportedTrialExpiry = details.trialExpiresAt { trialExpiresAt = reportedTrialExpiry }
        }
        if let name = Self.nonEmpty(details.displayName) { displayName = String(name.prefix(64)) }
    }

    private static func nonEmpty(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed?.isEmpty == false ? trimmed : nil
    }
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

enum LiveActivityCountdownValue: Equatable, Sendable {
    case days(days: Int, hours: Int)
    case hours(hours: Int, minutes: Int)
    case timer
    case expired
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

    static func usageString(until expiry: Date, from date: Date = .now) -> String {
        string(until: expiry, from: date)
    }

    static func compactString(until expiry: Date, from date: Date = .now) -> String {
        let remainingSeconds = max(0, Int(expiry.timeIntervalSince(date).rounded(.down)))
        if remainingSeconds > 48 * 3_600 { return "\(remainingSeconds / 86_400)d" }
        let remainingMinutes = remainingSeconds / 60
        if remainingMinutes < 100 { return "\(remainingMinutes)m" }
        return "\(remainingMinutes / 60)h"
    }

    static func liveActivityValue(until expiry: Date, from date: Date = .now) -> LiveActivityCountdownValue {
        let remaining = expiry.timeIntervalSince(date)
        guard remaining > 0 else { return .expired }
        if remaining >= 86_400 {
            let totalHours = Int(remaining / 3_600)
            return .days(days: totalHours / 24, hours: totalHours % 24)
        }
        if remaining >= 7_200 {
            let totalMinutes = Int(remaining / 60)
            return .hours(hours: totalMinutes / 60, minutes: totalMinutes % 60)
        }
        return .timer
    }

    static func widgetString(until expiry: Date, from date: Date = .now) -> String {
        let remaining = max(0, Int(expiry.timeIntervalSince(date).rounded(.down)))
        if remaining >= 86_400 {
            let days = remaining / 86_400
            let hours = (remaining % 86_400) / 3_600
            return String(format: "%dd %02dh", days, hours)
        }
        return string(until: expiry, from: date)
    }
}

struct UsageSnapshot: Codable, Hashable, Sendable {
    var accountID: UUID
    var providerName: String
    var accountName: String
    var accountProviderID: ProviderID? = nil
    var accountSymbolName: String? = nil
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

    var resolvedAccountName: String {
        let name = accountName.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? providerName : name
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
        accountID: UUID(), providerName: "ChatGPT", accountName: "Personal",
        accountProviderID: .chatGPT, plan: "Pro",
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
