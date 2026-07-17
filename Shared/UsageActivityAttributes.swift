#if canImport(ActivityKit)
import ActivityKit
import Foundation

struct UsageActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        var primaryTitle: String?
        var primaryProviderID: ProviderID?
        var primaryUsedPercent: Double?
        var primaryResetsAt: Date?
        var secondaryTitle: String?
        var secondaryUsedPercent: Double?
        var secondaryResetsAt: Date?
        var availableResets: Int
        var nextBankedResetExpiresAt: Date?
        var showResetCountdown: Bool
        var updatedAt: Date
    }

    var accountID: UUID
    var accountName: String
    var providerName: String
}
#endif
