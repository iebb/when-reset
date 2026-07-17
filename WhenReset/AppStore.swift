@preconcurrency import ActivityKit
import Foundation
import Observation
import WidgetKit

@MainActor @Observable
final class AppStore {
    private(set) var accounts: [MonitoredAccount] = []
    private(set) var snapshots: [UUID: UsageSnapshot] = [:]
    var isRefreshing = false
    var errorMessage: String?
    var link: DeviceLink?
    var claudeLink: ClaudeOAuthLink?
    var isLinking = false
    var monitorSettings: [UUID: AccountMonitorSettings] = [:]
    var liveActivitySettings = GlobalLiveActivitySettings()
    private(set) var hasLiveActivity = false

    private let accountsKey = "accounts.v1"
    private let provider = ChatGPTProvider()
    private let claudeProvider = ClaudeProvider()
    private let settingsKey = "monitorSettings.v1"
    private let liveActivitySettingsKey = "globalLiveActivitySettings.v1"
    private static let globalActivityID = UUID(uuidString: "00000000-0000-4000-8000-000000000001")!

    init() {
        if let data = UserDefaults.standard.data(forKey: accountsKey),
           let saved = try? JSONDecoder().decode([MonitoredAccount].self, from: data) { accounts = saved }
        snapshots = Dictionary(uniqueKeysWithValues: SharedSnapshotStore.load().map { ($0.accountID, $0) })
        if let data = UserDefaults.standard.data(forKey: settingsKey),
           let saved = try? JSONDecoder().decode([UUID: AccountMonitorSettings].self, from: data) { monitorSettings = saved }
        if let data = UserDefaults.standard.data(forKey: liveActivitySettingsKey),
           let saved = try? JSONDecoder().decode(GlobalLiveActivitySettings.self, from: data) {
            liveActivitySettings = saved
        } else if let previous = monitorSettings.values.first {
            liveActivitySettings = .init(mode: previous.liveActivityMode, nearResetMinutes: previous.nearResetMinutes)
        }
        hasLiveActivity = !Activity<UsageActivityAttributes>.activities.isEmpty
    }

    func start() async {
        guard !accounts.isEmpty else { return }
        await refreshAll()
    }

    func beginLink() async {
        isLinking = true; errorMessage = nil
        do { link = try await provider.beginLink() }
        catch { errorMessage = error.localizedDescription; isLinking = false }
    }

    @discardableResult
    func completeLink() async -> Bool {
        guard let link else { return false }
        do {
            let identity = try await provider.finishLink(link)
            let account = MonitoredAccount(id: UUID(), providerID: .chatGPT, displayName: identity.displayName,
                                           workspaceID: identity.workspaceID, plan: identity.plan, addedAt: .now)
            try KeychainStore.save(identity.credentials, for: account.id)
            accounts.append(account); persistAccounts()
            self.link = nil; isLinking = false
            await refresh(account)
            return true
        } catch is CancellationError {
            self.link = nil; isLinking = false
            return false
        } catch {
            errorMessage = error.localizedDescription; self.link = nil; isLinking = false
            return false
        }
    }

    func beginClaudeLink() {
        isLinking = true; errorMessage = nil
        do { claudeLink = try claudeProvider.beginLink(); isLinking = false }
        catch { errorMessage = error.localizedDescription; isLinking = false }
    }

    @discardableResult
    func completeClaudeLink(code: String) async -> Bool {
        guard let claudeLink else { return false }
        isLinking = true; errorMessage = nil
        do {
            let identity = try await claudeProvider.finishLink(claudeLink, pastedCode: code)
            let account = MonitoredAccount(id: UUID(), providerID: .claude, displayName: identity.displayName,
                                           workspaceID: identity.workspaceID, plan: identity.plan, addedAt: .now)
            try KeychainStore.save(identity.credentials, for: account.id)
            accounts.append(account); persistAccounts()
            self.claudeLink = nil; isLinking = false
            await refresh(account)
            return true
        } catch {
            errorMessage = error.localizedDescription; isLinking = false
            return false
        }
    }

    func cancelLink() { link = nil; claudeLink = nil; isLinking = false }

    func refreshAll() async {
        guard !isRefreshing else { return }
        isRefreshing = true; errorMessage = nil
        for account in accounts { await refresh(account) }
        isRefreshing = false
    }

    func refresh(_ account: MonitoredAccount) async {
        do {
            var credentials = try KeychainStore.load(for: account.id)
            let snapshot: UsageSnapshot
            switch account.providerID {
            case .chatGPT:
                let refreshed = try await provider.refreshedIfNeeded(credentials)
                if refreshed.accessToken != credentials.accessToken {
                    try KeychainStore.save(refreshed, for: account.id)
                    credentials = refreshed
                }
                snapshot = try await provider.fetchUsage(account: account, credentials: credentials)
            case .claude:
                let refreshed = try await claudeProvider.refreshedIfNeeded(credentials)
                if refreshed.accessToken != credentials.accessToken
                    || refreshed.refreshToken != credentials.refreshToken
                    || refreshed.expiresAt != credentials.expiresAt {
                    try KeychainStore.save(refreshed, for: account.id)
                    credentials = refreshed
                }
                snapshot = try await claudeProvider.fetchUsage(account: account, credentials: credentials)
            }
            snapshots[account.id] = snapshot
            publishSnapshots()
            await updateLiveActivity()
            await applyLiveActivityRule()
        } catch { errorMessage = "\(account.displayName): \(error.localizedDescription)" }
    }

    func remove(_ account: MonitoredAccount) {
        accounts.removeAll { $0.id == account.id }
        snapshots.removeValue(forKey: account.id)
        monitorSettings.removeValue(forKey: account.id)
        KeychainStore.delete(for: account.id)
        persistAccounts(); publishSnapshots()
        Task { await updateLiveActivity(); await applyLiveActivityRule() }
    }

    func toggleLiveActivity() async {
        let existing = Activity<UsageActivityAttributes>.activities
        if !existing.isEmpty {
            let finalContent = ActivityContent(state: activityState(), staleDate: nil)
            for activity in existing {
                await activity.end(finalContent, dismissalPolicy: .immediate)
            }
            hasLiveActivity = false
            return
        }
        await startGlobalLiveActivity()
    }

    private func startGlobalLiveActivity() async {
        guard ActivityAuthorizationInfo().areActivitiesEnabled, !snapshots.isEmpty else { return }
        let attributes = UsageActivityAttributes(accountID: Self.globalActivityID,
                                                  accountName: "All accounts", providerName: "When Reset")
        let state = activityState()
        do {
            _ = try Activity.request(attributes: attributes,
                                     content: ActivityContent(state: state, staleDate: .now.addingTimeInterval(900)))
            hasLiveActivity = true
        } catch {
            errorMessage = error.localizedDescription
            hasLiveActivity = false
        }
    }

    func settings(for account: MonitoredAccount) -> AccountMonitorSettings { monitorSettings[account.id] ?? .init() }

    func setSettings(_ settings: AccountMonitorSettings, for account: MonitoredAccount) {
        monitorSettings[account.id] = settings
        UserDefaults.standard.set(try? JSONEncoder().encode(monitorSettings), forKey: settingsKey)
        publishSnapshots()
        Task { await updateLiveActivity(); await applyLiveActivityRule() }
    }

    func setLiveActivitySettings(_ settings: GlobalLiveActivitySettings) {
        liveActivitySettings = settings
        UserDefaults.standard.set(try? JSONEncoder().encode(settings), forKey: liveActivitySettingsKey)
        Task { await applyLiveActivityRule() }
    }

    private func applyLiveActivityRule() async {
        guard liveActivitySettings.mode != .manual else { return }
        let running = hasLiveActivity
        let shouldRun: Bool
        switch liveActivitySettings.mode {
        case .manual: shouldRun = running
        case .always: shouldRun = true
        case .nearReset:
            let limitTimes = visibleActivityMetrics.map { $0.window.resetsAt.timeIntervalSinceNow }
            let bankedTimes = visibleLiveActivitySnapshots.compactMap {
                $0.snapshot.nextBankedResetExpiry()?.timeIntervalSinceNow
            }
            let remaining = (limitTimes + bankedTimes)
                .filter { $0 > 0 }
                .min() ?? .infinity
            shouldRun = remaining <= Double(liveActivitySettings.nearResetMinutes * 60)
        }
        if shouldRun != running { await toggleLiveActivity() }
    }

    private struct ActivityMetric {
        var account: MonitoredAccount
        var window: UsageWindow
    }

    private var visibleLiveActivitySnapshots: [(account: MonitoredAccount, snapshot: UsageSnapshot)] {
        accounts.compactMap { account in
            snapshots[account.id].map {
                (account, $0.filteredForLiveActivity(using: settings(for: account)))
            }
        }
    }

    private var visibleActivityMetrics: [ActivityMetric] {
        visibleLiveActivitySnapshots.flatMap { item in
            item.snapshot.usageWindows.map {
                ActivityMetric(account: item.account, window: $0)
            }
        }
        .sorted {
            if $0.window.remainingPercent != $1.window.remainingPercent {
                return $0.window.remainingPercent < $1.window.remainingPercent
            }
            return $0.window.resetsAt < $1.window.resetsAt
        }
    }

    private func activityState() -> UsageActivityAttributes.ContentState {
        let metrics = visibleActivityMetrics
        let primary = metrics.first
        let secondary = metrics.dropFirst().first
        let visibleSnapshots = visibleLiveActivitySnapshots.map(\.snapshot)
        // The API does not guarantee credit or account ordering. Always surface
        // the earliest future banked expiry across every opted-in account.
        let nextBankedExpiry = UsageSnapshot.nearestBankedResetExpiry(in: visibleSnapshots)
        let remaining = primary?.window.resetsAt.timeIntervalSinceNow ?? .infinity
        let title: (ActivityMetric) -> String = { metric in
            self.accounts.count > 1 ? "\(metric.account.providerID.displayName) · \(metric.window.displayTitle)" : metric.window.displayTitle
        }
        return .init(
            primaryTitle: primary.map(title),
            primaryProviderID: primary?.account.providerID,
            primaryUsedPercent: primary?.window.usedPercent,
            primaryResetsAt: primary?.window.resetsAt,
            secondaryTitle: secondary.map(title),
            secondaryUsedPercent: secondary?.window.usedPercent,
            secondaryResetsAt: secondary?.window.resetsAt,
            availableResets: visibleSnapshots.reduce(0) { $0 + $1.availableResetCount },
            nextBankedResetExpiresAt: nextBankedExpiry,
            showResetCountdown: primary?.account.providerID == .chatGPT
                && remaining > 0
                && remaining <= Double(liveActivitySettings.nearResetMinutes * 60),
            updatedAt: visibleSnapshots.map(\.fetchedAt).max() ?? .now
        )
    }

    private func updateLiveActivity() async {
        let state = activityState()
        let activities = Activity<UsageActivityAttributes>.activities
        let legacyActivities = activities.filter { $0.attributes.accountID != Self.globalActivityID }
        for activity in legacyActivities {
            await activity.end(ActivityContent(state: state, staleDate: nil), dismissalPolicy: .immediate)
        }
        var globalActivities = Activity<UsageActivityAttributes>.activities.filter {
            $0.attributes.accountID == Self.globalActivityID
        }
        if !legacyActivities.isEmpty, globalActivities.isEmpty {
            await startGlobalLiveActivity()
            globalActivities = Activity<UsageActivityAttributes>.activities.filter {
                $0.attributes.accountID == Self.globalActivityID
            }
        }
        for activity in globalActivities {
            await activity.update(ActivityContent(state: state, staleDate: .now.addingTimeInterval(900)))
        }
        hasLiveActivity = !Activity<UsageActivityAttributes>.activities.isEmpty
    }

    private func persistAccounts() { UserDefaults.standard.set(try? JSONEncoder().encode(accounts), forKey: accountsKey) }
    private func publishSnapshots() {
        SharedSnapshotStore.save(accounts.compactMap { account in
            snapshots[account.id]?.filtered(using: settings(for: account))
        })
        WidgetCenter.shared.reloadAllTimelines()
    }
}
