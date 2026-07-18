@preconcurrency import ActivityKit
import Foundation
import Observation
import Security
@preconcurrency import UserNotifications
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
    private(set) var usageHistory: [UsageHistoryPoint] = []
    private(set) var historyStorageError: String?

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
    private let historyStore = UsageHistoryStore()
    private var hasStarted = false
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
        guard !hasStarted else { return }
        hasStarted = true
        var pendingNotifications: [UsageNotificationEvent] = []
        do {
            let loaded = try await historyStore.load()
            usageHistory = loaded.points
            pendingNotifications = loaded.pendingNotifications
            historyStorageError = nil
        } catch {
            historyStorageError = error.localizedDescription
        }
        if accounts.contains(where: { !$0.isDemo && settings(for: $0).notifyAboutResets }) {
            await UsageNotificationService.prepareProvisionalAuthorization()
        }
        await deliverUsageNotifications(pendingNotifications)
        guard !accounts.isEmpty else { return }
        await refreshAll(source: .launch)
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
        await refresh(account, source: .demo)
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
            await clearHistoryIfIdentityChanged(from: relinkingAccount, to: account)
            clearPendingLinks(); isLinking = false
            await refresh(account, source: .accountLink)
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
            await clearHistoryIfIdentityChanged(from: relinkingAccount, to: account)
            self.claudeLink = nil; isLinking = false
            await refresh(account, source: .accountLink)
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
            await clearHistoryIfIdentityChanged(from: relinkingAccount, to: account)
            isLinking = false
            await refresh(account, source: .accountLink)
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
            await clearHistoryIfIdentityChanged(from: relinkingAccount, to: account)
            isLinking = false
            await refresh(account, source: .accountLink)
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

    @discardableResult
    func refreshAll(source: UsageRefreshSource = .manual) async -> Bool {
        guard !isRefreshing else { return false }
        isRefreshing = true; errorMessage = nil
        defer { isRefreshing = false }
        if source == .manual,
           accounts.contains(where: { !$0.isDemo && settings(for: $0).notifyAboutResets }) {
            await UsageNotificationService.prepareProvisionalAuthorization()
        }
        let refreshAccounts = accounts
        let tasks = refreshAccounts.map { account in
            Task { @MainActor in
                await self.refresh(account, source: source, publishChanges: false)
            }
        }
        let succeeded = await withTaskCancellationHandler {
            var allSucceeded = true
            for task in tasks {
                if !(await task.value) { allSucceeded = false }
            }
            return allSucceeded
        } onCancel: {
            for task in tasks { task.cancel() }
        }
        guard !Task.isCancelled else { return false }
        await deliverPendingUsageNotifications()
        publishSnapshots()
        await updateLiveActivity()
        await reconcileLiveActivity()
        return succeeded
    }

    @discardableResult
    func refresh(_ account: MonitoredAccount,
                 source: UsageRefreshSource = .manual,
                 publishChanges: Bool = true) async -> Bool {
        if account.isDemo {
            guard accounts.contains(where: { $0.id == account.id }) else { return false }
            let snapshot = DemoUsageFactory.snapshot(for: account)
            mergeLatestPlan(snapshot.plan, for: account.id)
            await recordSuccessfulSnapshot(
                snapshot,
                for: account,
                source: source,
                deliverNotifications: publishChanges
            )
            snapshots[account.id] = snapshot
            refreshFailures.removeValue(forKey: account.id)
            if publishChanges {
                publishSnapshots()
                await updateLiveActivity()
                await reconcileLiveActivity()
            }
            return true
        }
        do {
            var credentials = try KeychainStore.load(for: account.id)
            var effectiveAccount = accounts.first(where: { $0.id == account.id }) ?? account
            let snapshot: UsageSnapshot
            switch account.providerID {
            case .chatGPT:
                let refreshed = try await provider.refreshedIfNeeded(credentials)
                if refreshed != credentials {
                    try KeychainStore.save(refreshed, for: account.id)
                    credentials = refreshed
                }
                if let identity = try? provider.linkedIdentity(
                    accessToken: credentials.accessToken,
                    refreshToken: credentials.refreshToken,
                    idToken: credentials.idToken
                ), let updated = mergeProviderDetails(identity.accountDetails, for: account.id) {
                    effectiveAccount = updated
                }
                snapshot = try await provider.fetchUsage(account: effectiveAccount, credentials: credentials)
            case .claude:
                let refreshed = try await claudeProvider.refreshedAccountIfNeeded(credentials)
                if refreshed.credentials != credentials {
                    try KeychainStore.save(refreshed.credentials, for: account.id)
                    credentials = refreshed.credentials
                }
                if let details = refreshed.accountDetails,
                   let updated = mergeProviderDetails(details, for: account.id) {
                    effectiveAccount = updated
                }
                snapshot = try await claudeProvider.fetchUsage(account: effectiveAccount, credentials: credentials)
            case .kimi:
                let refreshed = try await kimiProvider.refreshedIfNeeded(credentials)
                if refreshed != credentials {
                    try KeychainStore.save(refreshed, for: account.id)
                    credentials = refreshed
                }
                let identity = KimiProvider.linkedIdentity(credentials: credentials)
                if let updated = mergeProviderDetails(identity.accountDetails, for: account.id) {
                    effectiveAccount = updated
                }
                snapshot = try await kimiProvider.fetchUsage(account: effectiveAccount, credentials: credentials)
            case .githubCopilot:
                let refreshed = try await copilotProvider.refreshedIfNeeded(credentials)
                if refreshed != credentials {
                    try KeychainStore.save(refreshed, for: account.id)
                    credentials = refreshed
                }
                if let details = try? await copilotProvider.fetchAccountDetails(credentials: credentials),
                   let updated = mergeProviderDetails(details, for: account.id) {
                    effectiveAccount = updated
                }
                snapshot = try await copilotProvider.fetchUsage(account: effectiveAccount, credentials: credentials)
            case .zai:
                snapshot = try await zaiProvider.fetchUsage(account: effectiveAccount, credentials: credentials)
            case .miniMax:
                snapshot = try await miniMaxProvider.fetchUsage(account: effectiveAccount, credentials: credentials)
            }
            guard accounts.contains(where: { $0.id == account.id }) else { return false }
            mergeLatestPlan(snapshot.plan, for: account.id)
            await recordSuccessfulSnapshot(
                snapshot,
                for: effectiveAccount,
                source: source,
                deliverNotifications: publishChanges
            )
            snapshots[account.id] = snapshot
            refreshFailures.removeValue(forKey: account.id)
            if publishChanges {
                publishSnapshots()
                await updateLiveActivity()
                await reconcileLiveActivity()
            }
            return true
        } catch is CancellationError {
            return false
        } catch {
            guard accounts.contains(where: { $0.id == account.id }) else { return false }
            // Keep the most recent snapshot in memory and in SharedSnapshotStore.
            // The account-scoped failure lets the UI label that data as cached.
            refreshFailures[account.id] = AccountRefreshFailure(error: error)
            return false
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
            account.workspaceID = identity.workspaceID
            account.mergeProviderDetails(identity.accountDetails)
            accounts[index] = account
            refreshFailures.removeValue(forKey: account.id)
            persistAccounts()
            return account
        }

        var account = MonitoredAccount(
            id: UUID(), providerID: providerID, displayName: identity.displayName,
            workspaceID: identity.workspaceID, plan: identity.plan, addedAt: .now
        )
        account.mergeProviderDetails(identity.accountDetails)
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
        Task {
            do {
                usageHistory = try await historyStore.remove(accountID: account.id)
                historyStorageError = nil
            } catch {
                historyStorageError = error.localizedDescription
            }
            await updateLiveActivity()
            await reconcileLiveActivity()
        }
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
        let previouslyEnabled = self.settings(for: account).notifyAboutResets
        monitorSettings[account.id] = settings
        persistMonitorSettings()
        publishSnapshots()
        Task {
            if previouslyEnabled != settings.notifyAboutResets {
                if settings.notifyAboutResets, !account.isDemo {
                    await UsageNotificationService.requestProminentAuthorization()
                } else {
                    do {
                        try await historyStore.discardPendingNotifications(accountID: account.id)
                        historyStorageError = nil
                    } catch {
                        historyStorageError = error.localizedDescription
                    }
                }
            }
            await updateLiveActivity()
            await reconcileLiveActivity()
        }
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
        var progressFraction: Double?
        var resetCount: Int?
        var isPinned: Bool
        var date: Date
        var fetchedAt: Date

        func target(showRemainingPercentage: Bool) -> UsageActivityTarget {
            UsageActivityTarget(
                id: "\(account.id.uuidString):\(metricID)", kind: kind,
                accountName: account.resolvedDisplayName, accountSymbolName: account.customSymbolName,
                providerID: account.providerID, title: title,
                remainingPercent: showRemainingPercentage ? remainingPercent : nil,
                progressFraction: progressFraction, resetCount: resetCount,
                isPinned: isPinned, expiresAt: date
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
                    progressFraction: window.remainingPercent / 100,
                    resetCount: nil, isPinned: accountSettings.isPinnedInLiveActivity(window),
                    date: window.resetsAt, fetchedAt: snapshot.fetchedAt
                ))
            }

            let bankedRule = accountSettings.bankedResetLiveActivityRule
            if liveActivitySettings.showBankedResets,
               accountSettings.showBankedResetsInLiveActivity,
               bankedRule.trigger != .never,
               let credit = snapshot.nextBankedResetCredit(after: date),
               let expiry = credit.expiresAt,
               !matchingRules || bankedRule.matches(expiry: expiry, at: date) {
                events.append(.init(
                    account: account, kind: .bankedReset,
                    metricID: AccountMonitorSettings.bankedResetMetricID,
                    title: "Banked resets", remainingPercent: nil,
                    progressFraction: credit.remainingLifetimeFraction(at: date),
                    resetCount: snapshot.availableResetCount,
                    isPinned: accountSettings.isBankedResetPinnedInLiveActivity,
                    date: expiry, fetchedAt: snapshot.fetchedAt
                ))
            }
        }
        return events.sorted {
            if $0.isPinned != $1.isPinned { return $0.isPinned && !$1.isPinned }
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

    private func mergeLatestPlan(_ plan: String?, for accountID: UUID) {
        guard let plan = plan?.trimmingCharacters(in: .whitespacesAndNewlines), !plan.isEmpty,
              let index = accounts.firstIndex(where: { $0.id == accountID }),
              accounts[index].plan != plan else { return }
        accounts[index].plan = plan
        persistAccounts()
    }

    @discardableResult
    private func mergeProviderDetails(_ details: ProviderAccountDetails,
                                      for accountID: UUID) -> MonitoredAccount? {
        guard let index = accounts.firstIndex(where: { $0.id == accountID }) else { return nil }
        let original = accounts[index]
        accounts[index].mergeProviderDetails(details)
        if accounts[index] != original { persistAccounts() }
        return accounts[index]
    }

    private func persistMonitorSettings() {
        UserDefaults.standard.set(try? JSONEncoder().encode(monitorSettings), forKey: settingsKey)
    }

    private func recordSuccessfulSnapshot(_ snapshot: UsageSnapshot, for account: MonitoredAccount,
                                          source: UsageRefreshSource,
                                          deliverNotifications: Bool) async {
        let notificationsEnabled = settings(for: account).notifyAboutResets
        if !account.isDemo, notificationsEnabled, source == .accountLink {
            await UsageNotificationService.requestProminentAuthorization()
        }
        do {
            let result = try await historyStore.record(
                snapshot: snapshot,
                account: account,
                source: source,
                notificationsEnabled: notificationsEnabled
            )
            usageHistory = result.points
            historyStorageError = nil
            if deliverNotifications {
                await deliverUsageNotifications(result.pendingNotifications)
            }
        } catch {
            // History is supplementary: a storage problem must not turn a successful provider
            // refresh into an authentication or update failure.
            historyStorageError = error.localizedDescription
        }
    }

    private func deliverPendingUsageNotifications() async {
        do {
            let loaded = try await historyStore.load()
            usageHistory = loaded.points
            historyStorageError = nil
            await deliverUsageNotifications(loaded.pendingNotifications)
        } catch {
            historyStorageError = error.localizedDescription
        }
    }

    private func deliverUsageNotifications(_ events: [UsageNotificationEvent]) async {
        let deliverable = events.filter { event in
            guard let account = accounts.first(where: { $0.id == event.accountID }) else { return false }
            return !account.isDemo && settings(for: account).notifyAboutResets
        }
        let deliverableIDs = Set(deliverable.map(\.id))
        let suppressed = Set(events.map(\.id)).subtracting(deliverableIDs)
        let delivered = await UsageNotificationService.deliver(deliverable)
        let handled = delivered.union(suppressed)
        guard !handled.isEmpty else { return }
        do {
            try await historyStore.markNotificationsDelivered(handled)
            historyStorageError = nil
        } catch {
            historyStorageError = error.localizedDescription
        }
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

    private func clearHistoryIfIdentityChanged(from previous: MonitoredAccount?,
                                               to current: MonitoredAccount) async {
        guard let previous, previous.workspaceID != current.workspaceID else { return }
        do {
            usageHistory = try await historyStore.remove(accountID: current.id)
            historyStorageError = nil
        } catch {
            historyStorageError = error.localizedDescription
        }
    }
}

@MainActor
private enum UsageNotificationService {
    static func prepareProvisionalAuthorization() async {
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        guard settings.authorizationStatus == .notDetermined else { return }
        _ = try? await center.requestAuthorization(options: [.alert, .sound, .provisional])
    }

    static func requestProminentAuthorization() async {
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        guard settings.authorizationStatus == .notDetermined
                || settings.authorizationStatus == .provisional else { return }
        _ = try? await center.requestAuthorization(options: [.alert, .sound])
    }

    static func deliver(_ events: [UsageNotificationEvent]) async -> Set<String> {
        guard !events.isEmpty else { return [] }
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        switch settings.authorizationStatus {
        case .authorized, .provisional, .ephemeral:
            break
        case .denied, .notDetermined:
            return []
        @unknown default:
            return []
        }

        var delivered: Set<String> = []
        for event in events.sorted(by: { $0.createdAt < $1.createdAt }) {
            let content = UNMutableNotificationContent()
            content.title = event.title
            content.body = event.body
            content.threadIdentifier = "usage-\(event.accountID.uuidString)"
            if settings.soundSetting == .enabled { content.sound = .default }
            let request = UNNotificationRequest(
                identifier: "when-reset.\(event.id)",
                content: content,
                trigger: nil
            )
            do {
                try await center.add(request)
                delivered.insert(event.id)
            } catch {
                continue
            }
        }
        return delivered
    }
}
