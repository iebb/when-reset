#if canImport(ActivityKit)
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
    var expiresAt: Date

    init(id: String, kind: Kind, accountName: String, accountSymbolName: String?,
         providerID: ProviderID, title: String, remainingPercent: Double? = nil,
         progressFraction: Double? = nil, resetCount: Int? = nil, expiresAt: Date) {
        self.id = String(id.prefix(160))
        self.kind = kind
        self.accountName = String(accountName.prefix(64))
        self.accountSymbolName = accountSymbolName.map { String($0.prefix(80)) }
        self.providerID = providerID
        self.title = String(title.prefix(80))
        self.remainingPercent = remainingPercent.map { min(100, max(0, $0)) }
        self.progressFraction = progressFraction.map { min(1, max(0, $0)) }
        self.resetCount = resetCount.map { max(0, $0) }
        self.expiresAt = expiresAt
    }

    static func ordered(_ targets: [UsageActivityTarget], limit: Int = 4) -> [UsageActivityTarget] {
        Array(targets.sorted {
            if $0.expiresAt != $1.expiresAt { return $0.expiresAt < $1.expiresAt }
            let accountOrder = $0.accountName.localizedCaseInsensitiveCompare($1.accountName)
            if accountOrder != .orderedSame { return accountOrder == .orderedAscending }
            let titleOrder = $0.title.localizedCaseInsensitiveCompare($1.title)
            if titleOrder != .orderedSame { return titleOrder == .orderedAscending }
            return $0.id < $1.id
        }.prefix(max(0, limit)))
    }
}

struct UsageActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        var targets: [UsageActivityTarget]
        var updatedAt: Date

        init(targets: [UsageActivityTarget], updatedAt: Date) {
            self.targets = UsageActivityTarget.ordered(targets)
            self.updatedAt = updatedAt
        }

        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            let updatedAt = try values.decodeIfPresent(Date.self, forKey: .updatedAt) ?? .now
            if let targets = try values.decodeIfPresent([UsageActivityTarget].self, forKey: .targets) {
                self.init(targets: targets, updatedAt: updatedAt)
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
            try values.encode(updatedAt, forKey: .updatedAt)
        }

        private enum CodingKeys: String, CodingKey {
            case targets, updatedAt
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
