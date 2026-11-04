#if os(iOS)
import ActivityKit
import Foundation

struct UsageActivityTarget: Codable, Hashable, Identifiable, Sendable {
    enum Kind: String, Codable, Hashable, Sendable {
        case quota
        case bankedReset
    }

    var id: String
    var kind: Kind
    var accountName: String
    var accountSymbolName: String?
    var providerID: ProviderID
    var title: String
    var remainingPercent: Double?
    var progressFraction: Double?
    var resetCount: Int?
    var isPinned: Bool
    var expiresAt: Date

    init(id: String, kind: Kind, accountName: String, accountSymbolName: String?,
         providerID: ProviderID, title: String, remainingPercent: Double? = nil,
         progressFraction: Double? = nil, resetCount: Int? = nil, isPinned: Bool = false,
         expiresAt: Date) {
        self.id = String(id.prefix(160))
        self.kind = kind
        self.accountName = String(accountName.prefix(64))
        self.accountSymbolName = accountSymbolName.map { String($0.prefix(80)) }
        self.providerID = providerID
        self.title = String(title.prefix(80))
        self.remainingPercent = remainingPercent.map { min(100, max(0, $0)) }
        self.progressFraction = progressFraction.map { min(1, max(0, $0)) }
        self.resetCount = resetCount.map { max(0, $0) }
        self.isPinned = isPinned
        self.expiresAt = expiresAt
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try values.decode(String.self, forKey: .id),
            kind: try values.decode(Kind.self, forKey: .kind),
            accountName: try values.decode(String.self, forKey: .accountName),
            accountSymbolName: try values.decodeIfPresent(String.self, forKey: .accountSymbolName),
            providerID: try values.decode(ProviderID.self, forKey: .providerID),
            title: try values.decode(String.self, forKey: .title),
            remainingPercent: try values.decodeIfPresent(Double.self, forKey: .remainingPercent),
            progressFraction: try values.decodeIfPresent(Double.self, forKey: .progressFraction),
            resetCount: try values.decodeIfPresent(Int.self, forKey: .resetCount),
            isPinned: try values.decodeIfPresent(Bool.self, forKey: .isPinned) ?? false,
            expiresAt: try values.decode(Date.self, forKey: .expiresAt)
        )
    }

    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(id, forKey: .id)
        try values.encode(kind, forKey: .kind)
        try values.encode(accountName, forKey: .accountName)
        try values.encodeIfPresent(accountSymbolName, forKey: .accountSymbolName)
        try values.encode(providerID, forKey: .providerID)
        try values.encode(title, forKey: .title)
        try values.encodeIfPresent(remainingPercent, forKey: .remainingPercent)
        try values.encodeIfPresent(progressFraction, forKey: .progressFraction)
        try values.encodeIfPresent(resetCount, forKey: .resetCount)
        try values.encode(isPinned, forKey: .isPinned)
        try values.encode(expiresAt, forKey: .expiresAt)
    }

    /// Reset cards use the usage-card name. Quota titles are already localized.
    var displayTitle: String {
        kind == .bankedReset ? String.localized("Reset cards") : title
    }

    static func ordered(_ targets: [UsageActivityTarget], limit: Int = 4) -> [UsageActivityTarget] {
        Array(targets.sorted {
            if $0.isPinned != $1.isPinned { return $0.isPinned }
            if $0.expiresAt != $1.expiresAt { return $0.expiresAt < $1.expiresAt }
            let accountOrder = $0.accountName.localizedCaseInsensitiveCompare($1.accountName)
            if accountOrder != .orderedSame { return accountOrder == .orderedAscending }
            let titleOrder = $0.title.localizedCaseInsensitiveCompare($1.title)
            if titleOrder != .orderedSame { return titleOrder == .orderedAscending }
            return $0.id < $1.id
        }.prefix(max(0, limit)))
    }

    private enum CodingKeys: String, CodingKey {
        case id, kind, accountName, accountSymbolName, providerID, title
        case remainingPercent, progressFraction, resetCount, isPinned, expiresAt
    }
}

struct UsageActivityAccountRow: Codable, Hashable, Identifiable, Sendable {
    var id: String
    var accountName: String
    var providerID: ProviderID
    var symbolName: String?
    var headlineTitle: String
    var headlineRemainingPercent: Double
    var secondaryTitle: String?
    var secondaryRemainingPercent: Double?
    var headlineResetsAt: Date?
    var isSoonestReset: Bool
    /// Zero hides the reset-card row. The widget localizes the count itself.
    var resetCardCount: Int
    var resetCardExpiresAt: Date?

    init(id: String, accountName: String, providerID: ProviderID, symbolName: String?,
         headlineTitle: String, headlineRemainingPercent: Double,
         secondaryTitle: String? = nil, secondaryRemainingPercent: Double? = nil,
         headlineResetsAt: Date? = nil, isSoonestReset: Bool = false,
         resetCardCount: Int = 0, resetCardExpiresAt: Date? = nil) {
        self.id = id
        self.accountName = String(accountName.prefix(64))
        self.providerID = providerID
        self.symbolName = symbolName
        self.headlineTitle = String(headlineTitle.prefix(80))
        self.headlineRemainingPercent = min(100, max(0, headlineRemainingPercent))
        self.secondaryTitle = secondaryTitle.map { String($0.prefix(80)) }
        self.secondaryRemainingPercent = secondaryRemainingPercent.map { min(100, max(0, $0)) }
        self.headlineResetsAt = headlineResetsAt
        self.isSoonestReset = isSoonestReset
        self.resetCardCount = max(0, resetCardCount)
        self.resetCardExpiresAt = resetCardCount > 0 ? resetCardExpiresAt : nil
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let count = try values.decodeIfPresent(Int.self, forKey: .resetCardCount) ?? 0
        let id = try values.decode(String.self, forKey: .id)
        let accountName = try values.decode(String.self, forKey: .accountName)
        let providerID = try values.decode(ProviderID.self, forKey: .providerID)
        let symbolName = try values.decodeIfPresent(String.self, forKey: .symbolName)
        let headlineTitle = try values.decode(String.self, forKey: .headlineTitle)
        let headlineRemainingPercent = try values.decode(Double.self, forKey: .headlineRemainingPercent)
        let secondaryTitle = try values.decodeIfPresent(String.self, forKey: .secondaryTitle)
        let secondaryRemainingPercent = try values.decodeIfPresent(Double.self, forKey: .secondaryRemainingPercent)
        let headlineResetsAt = try values.decodeIfPresent(Date.self, forKey: .headlineResetsAt)
        let isSoonestReset = try values.decodeIfPresent(Bool.self, forKey: .isSoonestReset) ?? false
        let resetCardExpiresAt = try values.decodeIfPresent(Date.self, forKey: .resetCardExpiresAt)
        self.init(
            id: id,
            accountName: accountName,
            providerID: providerID,
            symbolName: symbolName,
            headlineTitle: headlineTitle,
            headlineRemainingPercent: headlineRemainingPercent,
            secondaryTitle: secondaryTitle,
            secondaryRemainingPercent: secondaryRemainingPercent,
            headlineResetsAt: headlineResetsAt,
            isSoonestReset: isSoonestReset,
            resetCardCount: count,
            resetCardExpiresAt: resetCardExpiresAt
        )
    }

    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(id, forKey: .id)
        try values.encode(accountName, forKey: .accountName)
        try values.encode(providerID, forKey: .providerID)
        try values.encodeIfPresent(symbolName, forKey: .symbolName)
        try values.encode(headlineTitle, forKey: .headlineTitle)
        try values.encode(headlineRemainingPercent, forKey: .headlineRemainingPercent)
        try values.encodeIfPresent(secondaryTitle, forKey: .secondaryTitle)
        try values.encodeIfPresent(secondaryRemainingPercent, forKey: .secondaryRemainingPercent)
        try values.encodeIfPresent(headlineResetsAt, forKey: .headlineResetsAt)
        try values.encode(isSoonestReset, forKey: .isSoonestReset)
        if resetCardCount > 0 {
            try values.encode(resetCardCount, forKey: .resetCardCount)
            try values.encodeIfPresent(resetCardExpiresAt, forKey: .resetCardExpiresAt)
        }
    }

    private enum CodingKeys: String, CodingKey {
        case id, accountName, providerID, symbolName, headlineTitle, headlineRemainingPercent
        case secondaryTitle, secondaryRemainingPercent, headlineResetsAt, isSoonestReset
        case resetCardCount, resetCardExpiresAt
    }
}

struct UsageActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        var targets: [UsageActivityTarget]
        var accounts: [UsageActivityAccountRow]
        var updatedAt: Date

        init(targets: [UsageActivityTarget], accounts: [UsageActivityAccountRow] = [], updatedAt: Date) {
            self.targets = UsageActivityTarget.ordered(targets)
            self.accounts = accounts
            self.updatedAt = updatedAt
        }

        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            let updatedAt = try values.decodeIfPresent(Date.self, forKey: .updatedAt) ?? .now
            let accounts = try values.decodeIfPresent([UsageActivityAccountRow].self, forKey: .accounts) ?? []
            if let targets = try values.decodeIfPresent([UsageActivityTarget].self, forKey: .targets) {
                self.init(targets: targets, accounts: accounts, updatedAt: updatedAt)
                return
            }

            var legacyTargets: [UsageActivityTarget] = []
            if let expiry = try values.decodeIfPresent(Date.self, forKey: .primaryResetsAt),
               let providerID = try values.decodeIfPresent(ProviderID.self, forKey: .primaryProviderID) {
                let used = try values.decodeIfPresent(Double.self, forKey: .primaryUsedPercent)
                legacyTargets.append(.init(
                    id: "legacy-primary", kind: .quota,
                    accountName: try values.decodeIfPresent(String.self, forKey: .primaryAccountName)
                        ?? providerID.displayName,
                    accountSymbolName: try values.decodeIfPresent(String.self, forKey: .primaryAccountSymbolName),
                    providerID: providerID,
                    title: try values.decodeIfPresent(String.self, forKey: .primaryTitle) ?? "Usage reset",
                    remainingPercent: used.map { 100 - $0 },
                    progressFraction: used.map { min(1, max(0, (100 - $0) / 100)) },
                    expiresAt: expiry
                ))
            }
            if let expiry = try values.decodeIfPresent(Date.self, forKey: .secondaryResetsAt),
               let providerID = try values.decodeIfPresent(ProviderID.self, forKey: .secondaryProviderID) {
                let used = try values.decodeIfPresent(Double.self, forKey: .secondaryUsedPercent)
                legacyTargets.append(.init(
                    id: "legacy-secondary", kind: .quota,
                    accountName: try values.decodeIfPresent(String.self, forKey: .secondaryAccountName)
                        ?? providerID.displayName,
                    accountSymbolName: try values.decodeIfPresent(String.self, forKey: .secondaryAccountSymbolName),
                    providerID: providerID,
                    title: try values.decodeIfPresent(String.self, forKey: .secondaryTitle) ?? "Usage reset",
                    remainingPercent: used.map { 100 - $0 },
                    progressFraction: used.map { min(1, max(0, (100 - $0) / 100)) },
                    expiresAt: expiry
                ))
            }
            if let expiry = try values.decodeIfPresent(Date.self, forKey: .nextBankedResetExpiresAt) {
                let providerID = try values.decodeIfPresent(ProviderID.self, forKey: .primaryProviderID) ?? .chatGPT
                let count = try values.decodeIfPresent(Int.self, forKey: .availableResets) ?? 0
                legacyTargets.append(.init(
                    id: "legacy-banked", kind: .bankedReset,
                    accountName: try values.decodeIfPresent(String.self, forKey: .primaryAccountName)
                        ?? providerID.displayName,
                    accountSymbolName: try values.decodeIfPresent(String.self, forKey: .primaryAccountSymbolName),
                    providerID: providerID, title: "Banked resets", resetCount: count, expiresAt: expiry
                ))
            }
            self.init(targets: legacyTargets, updatedAt: updatedAt)
        }

        func encode(to encoder: Encoder) throws {
            var values = encoder.container(keyedBy: CodingKeys.self)
            try values.encode(targets, forKey: .targets)
            try values.encode(accounts, forKey: .accounts)
            try values.encode(updatedAt, forKey: .updatedAt)
        }

        private enum CodingKeys: String, CodingKey {
            case targets, accounts, updatedAt
            case primaryTitle, primaryAccountName, primaryAccountSymbolName, primaryProviderID
            case primaryUsedPercent, primaryResetsAt
            case secondaryTitle, secondaryAccountName, secondaryAccountSymbolName, secondaryProviderID
            case secondaryUsedPercent, secondaryResetsAt
            case availableResets, nextBankedResetExpiresAt
        }
    }

    var accountID: UUID
    var accountName: String
    var providerName: String
}
#endif
