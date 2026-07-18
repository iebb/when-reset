@preconcurrency import ActivityKit
import Foundation
import Observation
import Security
import WidgetKit

struct DeviceLinkPresentation: Sendable {
    let providerID: ProviderID
    let verificationURL: URL
    let userCode: String
    let expiresAt: Date
}

struct AccountRefreshFailure: Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        case authentication
        case update
    }

    let kind: Kind
    let message: String
    let failedAt: Date

    var requiresRelink: Bool { kind == .authentication }
    var title: String { requiresRelink ? "Sign-in failed" : "Update failed" }
    var systemImageName: String { requiresRelink ? "person.crop.circle.badge.exclamationmark" : "exclamationmark.triangle.fill" }

    init(error: Error, failedAt: Date = .now) {
        kind = Self.requiresReauthentication(for: error) ? .authentication : .update
        self.failedAt = failedAt
        if kind == .authentication {
            message = "Your sign-in expired or was revoked. Sign in again to resume updates."
        } else {
            let description = error.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
            message = description.isEmpty ? "The latest usage could not be loaded." : description
        }
    }

    static func requiresReauthentication(for error: Error) -> Bool {
        if let providerError = error as? ProviderError {
            switch providerError {
            case .missingAccount:
                return true
            case let .server(code, message):
                return isAuthenticationStatus(code)
                    || (code == 400 && indicatesInvalidCredentials(message))
            case .invalidResponse:
                break
            }
        }
        if let claudeError = error as? ClaudeOAuthError {
            if case .missingRefreshToken = claudeError { return true }
        }
        if let kimiError = error as? KimiProviderError {
            switch kimiError {
            case .missingRefreshToken, .reauthenticationRequired:
                return true
            case let .server(code, _):
                return isAuthenticationStatus(code)
            default:
                break
            }
        }
        if let copilotError = error as? CopilotProviderError {
            switch copilotError {
            case .relinkRequired:
                return true
            case let .server(code, _):
                return isAuthenticationStatus(code)
            default:
                break
            }
        }
        if let zaiError = error as? ZAIProviderError {
            switch zaiError {
            case .invalidAPIKey, .authorizationFailed:
                return true
            case let .server(code, _):
                return isAuthenticationStatus(code)
            default:
                break
            }
        }
        if let miniMaxError = error as? MiniMaxProviderError {
            switch miniMaxError {
            case .invalidAPIKey, .authorizationFailed:
                return true
            case let .server(code, _):
                return isAuthenticationStatus(code)
            default:
                break
            }
        }

        let nsError = error as NSError
        if nsError.domain == NSOSStatusErrorDomain, nsError.code == Int(errSecItemNotFound) {
            return true
        }
        return (error as? URLError)?.code == .userAuthenticationRequired
    }

    private static func isAuthenticationStatus(_ code: Int) -> Bool {
        code == 401 || code == 403
    }

    private static func indicatesInvalidCredentials(_ message: String) -> Bool {
        let normalized = message.lowercased().replacingOccurrences(of: "_", with: " ")
        return ["invalid grant", "invalid token", "expired token", "refresh token", "unauthorized"]
            .contains { normalized.contains($0) }
    }
}

@MainActor @Observable
final class AppStore {
    private(set) var accounts: [MonitoredAccount] = []
    private(set) var snapshots: [UUID: UsageSnapshot] = [:]
    private(set) var refreshFailures: [UUID: AccountRefreshFailure] = [:]
    var isRefreshing = false
    var errorMessage: String?
    var deviceLink: DeviceLinkPresentation?
    var claudeLink: ClaudeOAuthLink?
    var isLinking = false
    var monitorSettings: [UUID: AccountMonitorSettings] = [:]
    var liveActivitySettings = GlobalLiveActivitySettings()
    private(set) var hasLiveActivity = false

    private let accountsKey = "accounts.v1"
    private let provider = ChatGPTProvider()
    private let claudeProvider = ClaudeProvider()
    private let kimiProvider = KimiProvider()
    private let copilotProvider = CopilotProvider()
    private let zaiProvider = ZAIProvider()
    private let miniMaxProvider = MiniMaxProvider()
    private var chatGPTLink: DeviceLink?
    private var kimiLink: KimiDeviceLink?
    private var copilotLink: CopilotDeviceLink?
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
        }
        hasLiveActivity = !Activity<UsageActivityAttributes>.activities.isEmpty
    }

    func start() async {
        guard !accounts.isEmpty else { return }
        await refreshAll()
    }

    @discardableResult
    func addDemoAccount() async -> MonitoredAccount {
        if let existing = accounts.first(where: \.isDemo) {
            await refresh(existing)
            return existing
        }
        let account = MonitoredAccount(
            id: UUID(),
            providerID: .chatGPT,
            displayName: "Demo account",
            workspaceID: MonitoredAccount.demoWorkspaceID,
            plan: "Pro · Demo",
            addedAt: .now
        )
        accounts.append(account)
        persistAccounts()
        await refresh(account)
        return account
    }

    func beginDeviceLink(for providerID: ProviderID) async {
        isLinking = true; errorMessage = nil
        do {
            switch providerID {
            case .chatGPT:
                let link = try await provider.beginLink()
                chatGPTLink = link
                deviceLink = .init(providerID: .chatGPT, verificationURL: link.verificationURL,
                                   userCode: link.userCode, expiresAt: .now.addingTimeInterval(15 * 60))
            case .kimi:
                let link = try await kimiProvider.beginLink()
                kimiLink = link
                deviceLink = .init(providerID: .kimi, verificationURL: link.verificationURL,
                                   userCode: link.userCode, expiresAt: link.expiresAt)
            case .githubCopilot:
                let link = try await copilotProvider.beginLink()
                copilotLink = link
                deviceLink = .init(providerID: .githubCopilot, verificationURL: link.verificationURL,
                                   userCode: link.userCode, expiresAt: link.expiresAt)
            case .claude, .zai, .miniMax:
                throw ProviderError.server(400, "This provider does not use device linking.")
            }
        } catch {
            errorMessage = error.localizedDescription
            clearPendingLinks()
            isLinking = false
        }
    }

    @discardableResult
    func completeDeviceLink(replacing relinkingAccount: MonitoredAccount? = nil) async -> Bool {
        guard let deviceLink else { return false }
        do {
            let identity: LinkedIdentity
            switch deviceLink.providerID {
            case .chatGPT:
                guard let chatGPTLink else { throw ProviderError.invalidResponse }
                identity = try await provider.finishLink(chatGPTLink)
            case .kimi:
                guard let kimiLink else { throw ProviderError.invalidResponse }
                identity = try await kimiProvider.finishLink(kimiLink)
            case .githubCopilot:
                guard let copilotLink else { throw ProviderError.invalidResponse }
                identity = try await copilotProvider.finishLink(copilotLink)
            case .claude, .zai, .miniMax:
                throw ProviderError.invalidResponse
            }
            let account = try saveLinkedAccount(identity, providerID: deviceLink.providerID,
                                                replacing: relinkingAccount)
            clearPendingLinks(); isLinking = false
            await refresh(account)
            return true
        } catch is CancellationError {
            clearPendingLinks(); isLinking = false
            return false
        } catch {
            errorMessage = error.localizedDescription; clearPendingLinks(); isLinking = false
            return false
        }
    }

    func beginClaudeLink() {
        isLinking = true; errorMessage = nil
        do { claudeLink = try claudeProvider.beginLink(); isLinking = false }
        catch { errorMessage = error.localizedDescription; isLinking = false }
    }

    @discardableResult
    func completeClaudeLink(code: String, replacing relinkingAccount: MonitoredAccount? = nil) async -> Bool {
        guard let claudeLink else { return false }
        isLinking = true; errorMessage = nil
        do {
            let identity = try await claudeProvider.finishLink(claudeLink, pastedCode: code)
            let account = try saveLinkedAccount(identity, providerID: .claude, replacing: relinkingAccount)
            self.claudeLink = nil; isLinking = false
            await refresh(account)
            return true
        } catch {
            errorMessage = error.localizedDescription; isLinking = false
            return false
        }
    }

    @discardableResult
    func addZAIAccount(apiKey: String, replacing relinkingAccount: MonitoredAccount? = nil) async -> Bool {
        isLinking = true; errorMessage = nil
        do {
            let identity = try await zaiProvider.link(apiKey: apiKey)
            let account = try saveLinkedAccount(identity, providerID: .zai, replacing: relinkingAccount)
            isLinking = false
            await refresh(account)
            return true
        } catch {
            errorMessage = error.localizedDescription
            isLinking = false
            return false
        }
    }

    @discardableResult
    func addMiniMaxAccount(apiKey: String, replacing relinkingAccount: MonitoredAccount? = nil) async -> Bool {
        isLinking = true; errorMessage = nil
        do {
            let identity = try await miniMaxProvider.link(apiKey: apiKey)
            let account = try saveLinkedAccount(identity, providerID: .miniMax, replacing: relinkingAccount)
            isLinking = false
            await refresh(account)
            return true
        } catch {
            errorMessage = error.localizedDescription
            isLinking = false
            return false
        }
    }

    func cancelLink() {
        clearPendingLinks()
        isLinking = false
    }

    func refreshAll() async {
        guard !isRefreshing else { return }
        isRefreshing = true; errorMessage = nil
        for account in accounts { await refresh(account) }
        isRefreshing = false
    }

    func refresh(_ account: MonitoredAccount) async {
        if account.isDemo {
            guard accounts.contains(where: { $0.id == account.id }) else { return }
            snapshots[account.id] = DemoUsageFactory.snapshot(for: account)
            refreshFailures.removeValue(forKey: account.id)
            publishSnapshots()
            await updateLiveActivity()
            await reconcileLiveActivity()
            return
        }
        do {
            var credentials = try KeychainStore.load(for: account.id)
            let snapshot: UsageSnapshot
            switch account.providerID {
            case .chatGPT:
                let refreshed = try await provider.refreshedIfNeeded(credentials)
                if refreshed != credentials {
                    try KeychainStore.save(refreshed, for: account.id)
                    credentials = refreshed
                }
                snapshot = try await provider.fetchUsage(account: account, credentials: credentials)
            case .claude:
                let refreshed = try await claudeProvider.refreshedIfNeeded(credentials)
                if refreshed != credentials {
                    try KeychainStore.save(refreshed, for: account.id)
                    credentials = refreshed
                }
                snapshot = try await claudeProvider.fetchUsage(account: account, credentials: credentials)
            case .kimi:
                let refreshed = try await kimiProvider.refreshedIfNeeded(credentials)
                if refreshed != credentials {
                    try KeychainStore.save(refreshed, for: account.id)
                    credentials = refreshed
                }
                snapshot = try await kimiProvider.fetchUsage(account: account, credentials: credentials)
            case .githubCopilot:
                let refreshed = try await copilotProvider.refreshedIfNeeded(credentials)
                if refreshed != credentials {
                    try KeychainStore.save(refreshed, for: account.id)
                    credentials = refreshed
                }
                snapshot = try await copilotProvider.fetchUsage(account: account, credentials: credentials)
            case .zai:
                snapshot = try await zaiProvider.fetchUsage(account: account, credentials: credentials)
            case .miniMax:
                snapshot = try await miniMaxProvider.fetchUsage(account: account, credentials: credentials)
            }
            guard accounts.contains(where: { $0.id == account.id }) else { return }
            snapshots[account.id] = snapshot
            refreshFailures.removeValue(forKey: account.id)
            publishSnapshots()
            await updateLiveActivity()
            await reconcileLiveActivity()
        } catch is CancellationError {
            return
        } catch {
            guard accounts.contains(where: { $0.id == account.id }) else { return }
            // Keep the most recent snapshot in memory and in SharedSnapshotStore.
            // The account-scoped failure lets the UI label that data as cached.
            refreshFailures[account.id] = AccountRefreshFailure(error: error)
        }
    }

    private func saveLinkedAccount(_ identity: LinkedIdentity, providerID: ProviderID,
                                   replacing relinkingAccount: MonitoredAccount? = nil) throws -> MonitoredAccount {
        if let relinkingAccount {
            guard relinkingAccount.providerID == providerID,
                  let index = accounts.firstIndex(where: { $0.id == relinkingAccount.id }) else {
                throw ProviderError.server(400, "The account being reconnected is no longer available.")
            }
            var account = accounts[index]
            try KeychainStore.save(identity.credentials, for: account.id)
            account.displayName = identity.displayName
            account.workspaceID = identity.workspaceID
            account.plan = identity.plan
            accounts[index] = account
            refreshFailures.removeValue(forKey: account.id)
            persistAccounts()
            return account
        }

        let account = MonitoredAccount(id: UUID(), providerID: providerID, displayName: identity.displayName,
                                       workspaceID: identity.workspaceID, plan: identity.plan, addedAt: .now)
        try KeychainStore.save(identity.credentials, for: account.id)
        accounts.append(account)
        persistAccounts()
        return account
    }

    private func clearPendingLinks() {
        deviceLink = nil
        chatGPTLink = nil
        kimiLink = nil
        copilotLink = nil
        claudeLink = nil
    }

    func remove(_ account: MonitoredAccount) {
        accounts.removeAll { $0.id == account.id }
        snapshots.removeValue(forKey: account.id)
        refreshFailures.removeValue(forKey: account.id)
        monitorSettings.removeValue(forKey: account.id)
        if !account.isDemo { KeychainStore.delete(for: account.id) }
        persistAccounts(); persistMonitorSettings(); publishSnapshots()
        Task { await updateLiveActivity(); await reconcileLiveActivity() }
    }

    func setAppearance(displayName: String, symbolName: String?, for account: MonitoredAccount) {
        guard let index = accounts.firstIndex(where: { $0.id == account.id }) else { return }
        let normalizedName = displayName
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        let limitedName = String(normalizedName.prefix(64))
        let normalizedSymbol = symbolName?.trimmingCharacters(in: .whitespacesAndNewlines)

        accounts[index].customDisplayName = limitedName.isEmpty || limitedName == accounts[index].displayName
            ? nil : limitedName
        accounts[index].customSymbolName = normalizedSymbol?.isEmpty == false ? normalizedSymbol : nil
        persistAccounts()
        publishSnapshots()
        Task { await updateLiveActivity(); await reconcileLiveActivity() }
    }

    private func endGlobalLiveActivity() async {
        let finalContent = ActivityContent(state: activityState(), staleDate: nil)
        for activity in Activity<UsageActivityAttributes>.activities {
            await activity.end(finalContent, dismissalPolicy: .immediate)
        }
        hasLiveActivity = false
    }

    private func startGlobalLiveActivity() async {
        guard ActivityAuthorizationInfo().areActivitiesEnabled, hasEligibleLiveActivityContent else { return }
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
        persistMonitorSettings()
        publishSnapshots()
        Task { await updateLiveActivity(); await reconcileLiveActivity() }
    }

    func setLiveActivitySettings(_ settings: GlobalLiveActivitySettings) {
        liveActivitySettings = settings
        UserDefaults.standard.set(try? JSONEncoder().encode(settings), forKey: liveActivitySettingsKey)
        Task { await updateLiveActivity(); await reconcileLiveActivity() }
    }

    private func reconcileLiveActivity(at date: Date = .now) async {
        let running = !Activity<UsageActivityAttributes>.activities.isEmpty
        let shouldRun: Bool
        switch liveActivitySettings.mode {
        case .automatic: shouldRun = !activityEvents(at: date, matchingRules: true).isEmpty
        case .always: shouldRun = !activityEvents(at: date, matchingRules: false).isEmpty
        case .disabled: shouldRun = false
        }
        if shouldRun, !running {
            await startGlobalLiveActivity()
        } else if !shouldRun, running {
            await endGlobalLiveActivity()
        } else {
            hasLiveActivity = running
        }
    }

    private var hasEligibleLiveActivityContent: Bool {
        switch liveActivitySettings.mode {
        case .automatic: !activityEvents(matchingRules: true).isEmpty
        case .always: !activityEvents(matchingRules: false).isEmpty
        case .disabled: false
        }
    }

    private struct ActivityEvent {
        var account: MonitoredAccount
        var kind: UsageActivityTarget.Kind
        var metricID: String
        var title: String
        var remainingPercent: Double?
        var resetCount: Int?
        var date: Date
        var fetchedAt: Date

        func target(showRemainingPercentage: Bool) -> UsageActivityTarget {
            UsageActivityTarget(
                id: "\(account.id.uuidString):\(metricID)", kind: kind,
                accountName: account.resolvedDisplayName, accountSymbolName: account.customSymbolName,
                providerID: account.providerID, title: title,
                remainingPercent: showRemainingPercentage ? remainingPercent : nil,
                resetCount: resetCount, expiresAt: date
            )
        }
    }

    private func activityEvents(at date: Date = .now, matchingRules: Bool) -> [ActivityEvent] {
        var events: [ActivityEvent] = []
        for account in accounts {
            guard let storedSnapshot = snapshots[account.id] else { continue }
            let snapshot = presentedSnapshot(storedSnapshot, for: account)
            let accountSettings = settings(for: account)

            for window in snapshot.usageWindows where window.resetsAt > date
                && accountSettings.showsInLiveActivity(window) {
                let rule = accountSettings.liveActivityRule(for: window)
                guard rule.trigger != .never, !matchingRules || rule.matches(window, at: date) else { continue }
                events.append(.init(
                    account: account, kind: .quota, metricID: window.metricID,
                    title: window.displayTitle, remainingPercent: window.remainingPercent,
                    resetCount: nil, date: window.resetsAt, fetchedAt: snapshot.fetchedAt
                ))
            }

            let bankedRule = accountSettings.bankedResetLiveActivityRule
            if liveActivitySettings.showBankedResets,
               accountSettings.showBankedResetsInLiveActivity,
               bankedRule.trigger != .never,
               let expiry = snapshot.nextBankedResetExpiry(after: date),
               !matchingRules || bankedRule.matches(expiry: expiry, at: date) {
                events.append(.init(
                    account: account, kind: .bankedReset, metricID: "banked-resets",
                    title: "Banked resets", remainingPercent: nil,
                    resetCount: snapshot.availableResetCount, date: expiry, fetchedAt: snapshot.fetchedAt
                ))
            }
        }
        return events.sorted {
            if $0.date != $1.date { return $0.date < $1.date }
            let accountOrder = $0.account.resolvedDisplayName.localizedCaseInsensitiveCompare(
                $1.account.resolvedDisplayName)
            if accountOrder != .orderedSame { return accountOrder == .orderedAscending }
            return $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
        }
    }

    private func activityState() -> UsageActivityAttributes.ContentState {
        let events: [ActivityEvent] = switch liveActivitySettings.mode {
        case .automatic: activityEvents(matchingRules: true)
        case .always: activityEvents(matchingRules: false)
        case .disabled: []
        }
        return .init(
            targets: events.map { $0.target(showRemainingPercentage: liveActivitySettings.showRemainingPercentage) },
            updatedAt: events.map(\.fetchedAt).max() ?? snapshots.values.map(\.fetchedAt).max() ?? .now
        )
    }

    private func updateLiveActivity() async {
        let state = activityState()
        let activities = Activity<UsageActivityAttributes>.activities
        let legacyActivities = activities.filter { $0.attributes.accountID != Self.globalActivityID }
        for activity in legacyActivities {
            await activity.end(ActivityContent(state: state, staleDate: nil), dismissalPolicy: .immediate)
        }
        let globalActivities = Activity<UsageActivityAttributes>.activities.filter {
            $0.attributes.accountID == Self.globalActivityID
        }
        for activity in globalActivities {
            await activity.update(ActivityContent(state: state, staleDate: .now.addingTimeInterval(900)))
        }
        hasLiveActivity = !Activity<UsageActivityAttributes>.activities.isEmpty
    }

    private func persistAccounts() { UserDefaults.standard.set(try? JSONEncoder().encode(accounts), forKey: accountsKey) }
    private func persistMonitorSettings() {
        UserDefaults.standard.set(try? JSONEncoder().encode(monitorSettings), forKey: settingsKey)
    }
    private func publishSnapshots() {
        SharedSnapshotStore.save(accounts.compactMap { account in
            snapshots[account.id].map {
                presentedSnapshot($0, for: account).filtered(using: settings(for: account))
            }
        })
        WidgetCenter.shared.reloadAllTimelines()
    }

    private func presentedSnapshot(_ snapshot: UsageSnapshot, for account: MonitoredAccount) -> UsageSnapshot {
        var result = snapshot
        result.accountName = account.resolvedDisplayName
        result.accountProviderID = account.providerID
        result.accountSymbolName = account.customSymbolName
        return result
    }
}
