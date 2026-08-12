#if os(iOS)
@preconcurrency import ActivityKit
#endif
import Foundation
import Observation
import Security
@preconcurrency import UserNotifications
#if os(iOS)
import UIKit
#endif
import WidgetKit

struct DeviceLinkPresentation: Sendable {
    let providerID: ProviderID
    let verificationURL: URL
    let userCode: String
    let expiresAt: Date
}

actor ServerAccountOperationGate {
    private var activeAccountIDs: Set<UUID> = []
    private var waiters: [UUID: [CheckedContinuation<Void, Never>]] = [:]

    func acquire(accountID: UUID) async {
        guard !activeAccountIDs.contains(accountID) else {
            await withCheckedContinuation { continuation in
                waiters[accountID, default: []].append(continuation)
            }
            return
        }
        activeAccountIDs.insert(accountID)
    }

    func release(accountID: UUID) {
        guard var accountWaiters = waiters[accountID], !accountWaiters.isEmpty else {
            activeAccountIDs.remove(accountID)
            waiters.removeValue(forKey: accountID)
            return
        }
        let next = accountWaiters.removeFirst()
        if accountWaiters.isEmpty {
            waiters.removeValue(forKey: accountID)
        } else {
            waiters[accountID] = accountWaiters
        }
        next.resume()
    }
}

actor ServerRegistrationOperationGate {
    private var activeOrigins: Set<String> = []
    private var waiters: [String: [CheckedContinuation<Void, Never>]] = [:]

    func acquire(origin: String) async {
        guard !activeOrigins.contains(origin) else {
            await withCheckedContinuation { continuation in
                waiters[origin, default: []].append(continuation)
            }
            return
        }
        activeOrigins.insert(origin)
    }

    func release(origin: String) {
        guard var originWaiters = waiters[origin], !originWaiters.isEmpty else {
            activeOrigins.remove(origin)
            waiters.removeValue(forKey: origin)
            return
        }
        let next = originWaiters.removeFirst()
        if originWaiters.isEmpty {
            waiters.removeValue(forKey: origin)
        } else {
            waiters[origin] = originWaiters
        }
        next.resume()
    }
}

enum ServerMonitoringRecovery {
    static func cleanupMatchesCurrentWorker(
        cleanup: PushServerSettings,
        current: PushServerSettings
    ) -> Bool {
        let cleanupURL = try? cleanup.resolvedServerURL()
        let currentURL = try? current.resolvedServerURL()
        return (cleanupURL != nil && cleanupURL == currentURL) || cleanup == current
    }

    static func reconcilingPendingDeletion(
        in settings: AccountMonitorSettings,
        serverURL: String,
        pendingRevision: Int64
    ) -> AccountMonitorSettings {
        guard settings.monitorOnSelfHostedServer,
              settings.selfHostedServerConsentURL == serverURL,
              settings.selfHostedServerConsentRevision <= pendingRevision else {
            return settings
        }
        var result = settings
        result.monitorOnSelfHostedServer = false
        result.selfHostedServerConsentURL = nil
        result.selfHostedServerConsentRevision = pendingRevision
        return result
    }
}

#if os(iOS)
enum LiveActivityLifecyclePolicy {
    static let rotationInterval: TimeInterval = 7 * 60 * 60

    static func isRunning(_ state: ActivityState) -> Bool {
        if #available(iOS 26.0, *) {
            return switch state {
            case .pending, .active, .stale: true
            case .ended, .dismissed: false
            @unknown default: false
            }
        }
        return state == .active || state == .stale
    }

    static func shouldRotate(startedAt: Date?, at date: Date = .now) -> Bool {
        guard let startedAt else { return false }
        return date.timeIntervalSince(startedAt) >= rotationInterval
    }
}
#endif

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
            message = Self.updateMessage(for: error)
        }
    }

    init(workerSessionStatus: WorkerSessionStatus, checkedAt: Date? = nil) {
        failedAt = checkedAt ?? .now
        switch workerSessionStatus {
        case .expired:
            kind = .authentication
            message = "The Worker reports that this sign-in expired or was revoked. Sign in again to replace its encrypted credential."
        case .error, .unchecked, .active:
            kind = .update
            message = "The Worker could not verify this provider session. Saved usage remains available while it retries."
        }
    }

    private static func updateMessage(for error: Error) -> String {
        if let pushError = error as? PushServerError,
           case .remoteAccountUnavailable = pushError {
            return "This account is no longer available on the self-hosted Worker."
        }
        if httpStatus(for: error) == 429 {
            return "Updates are temporarily rate-limited. Showing the latest saved usage; When Reset will retry automatically."
        }
        if error is URLError {
            return "The provider couldn’t be reached. Showing the latest saved usage; When Reset will retry automatically."
        }
        return "The latest usage could not be loaded. Showing the latest saved usage; When Reset will retry automatically."
    }

    private static func httpStatus(for error: Error) -> Int? {
        if let value = error as? ProviderError, case let .server(code, _) = value { return code }
        if let value = error as? KimiProviderError, case let .server(code, _) = value { return code }
        if let value = error as? CopilotProviderError, case let .server(code, _) = value { return code }
        if let value = error as? ZAIProviderError, case let .server(code, _) = value { return code }
        if let value = error as? MiniMaxProviderError, case let .server(code, _) = value { return code }
        if let value = error as? AdditionalProviderError, case let .server(_, code) = value { return code }
        return nil
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
        if let additionalError = error as? AdditionalProviderError {
            return additionalError.requiresReauthentication
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

extension UsageRefreshSource {
    var presentsFetchFailureAlerts: Bool {
        self == .manual || self == .accountLink
    }
}

enum AccountRefreshRoute: Equatable, Sendable {
    case demo
    case server
    case provider

    init(isDemo: Bool, serverMonitoringEnabled: Bool, remoteOnly: Bool = false) {
        if isDemo {
            self = .demo
        } else if serverMonitoringEnabled || remoteOnly {
            self = .server
        } else {
            self = .provider
        }
    }
}

enum WorkerMetadataPolicy {
    static func shouldUpload(local account: MonitoredAccount,
                             remote details: ProviderAccountDetails?) -> Bool {
        guard let details else { return false }
        return differs(account.profileName, details.profileName)
            || differs(account.email, details.email)
            || differs(account.plan, details.plan)
            || differs(account.planExpiresAt, details.planExpiresAt)
            || differs(account.trialExpiresAt, details.trialExpiresAt)
    }

    static func authoritativeDetails(from account: MonitoredAccount) -> ProviderAccountDetails {
        ProviderAccountDetails(
            profileName: account.profileName,
            email: account.email,
            plan: account.plan,
            planExpiresAt: account.planExpiresAt,
            trialExpiresAt: account.trialExpiresAt,
            replacesMissingFields: true
        )
    }

    private static func differs<T: Equatable>(_ local: T?, _ remote: T?) -> Bool {
        guard local != nil else { return false }
        return local != remote
    }
}

enum WorkerHistoryFetchScope: Sendable {
    case incremental
    case retainedHistory

    func startDate(now: Date, latestServerPoint: Date?) -> Date {
        let earliestRetainedDate = now.addingTimeInterval(-UsageHistoryStore.retentionInterval)
        switch self {
        case .retainedHistory:
            return earliestRetainedDate
        case .incremental:
            guard let latestServerPoint else { return earliestRetainedDate }
            return max(earliestRetainedDate, latestServerPoint.addingTimeInterval(-60))
        }
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
    var antigravityLink: AntigravityOAuthLink?
    var isLinking = false
    var monitorSettings: [UUID: AccountMonitorSettings] = [:]
    var liveActivitySettings = GlobalLiveActivitySettings()
    var notificationSettings = GlobalNotificationSettings()
    var refreshSettings = GlobalRefreshSettings()
    var pushServerSettings = PushServerSettings()
    private(set) var hasLiveActivity = false
    private(set) var pushServerStatus = PushServerStatus.disabled
    private(set) var usageHistory: [UsageHistoryPoint] = []
    private(set) var historyStorageError: String?

    private let accountsKey = "accounts.v1"
    private let provider = ChatGPTProvider()
    private let claudeProvider = ClaudeProvider()
    private let grokProvider = GrokProvider()
    private let kimiProvider = KimiProvider()
    private let copilotProvider = CopilotProvider()
    private let zaiProvider = ZAIProvider()
    private let miniMaxProvider = MiniMaxProvider()
    private let syntheticProvider = SyntheticProvider()
    private let ollamaCloudProvider = OllamaCloudProvider()
    private let warpProvider = WarpProvider()
    private let antigravityProvider = AntigravityProvider()
    private let compatibleAPIProvider = CompatibleAPIProvider()
    private let openAIAPIProvider = OpenAIAPIProvider()
    private let anthropicAPIProvider = AnthropicAPIProvider()
    private let newAPIProvider = NewAPIProvider()
    private var chatGPTLink: DeviceLink?
    private var grokLink: GrokDeviceLink?
    private var kimiLink: KimiDeviceLink?
    private var copilotLink: CopilotDeviceLink?
    private let settingsKey = "monitorSettings.v1"
    private let liveActivitySettingsKey = "globalLiveActivitySettings.v1"
    private let notificationSettingsKey = "globalNotificationSettings.v1"
    private let refreshSettingsKey = "globalRefreshSettings.v1"
    private let pushServerSettingsKey = "pushServerSettings.v1"
    private let pendingPushServerCleanupKey = "pendingPushServerCleanup.v1"
    private let pendingServerAccountDeletionsKey = "pendingServerAccountDeletions.v1"
    private let pendingServerAccountDeletionURLKey = "pendingServerAccountDeletionURL.v1"
    private let serverConsentHighWaterKey = "serverConsentHighWater.v1"
    private let liveActivityStartedAtKey = "globalLiveActivityStartedAt.v1"
    private static let accountKeychainMigrationKey = "accounts.iCloudKeychainMigrated.v1"
    private let historyStore = UsageHistoryStore()
    private let serverAccountOperationGate = ServerAccountOperationGate()
    private let serverRegistrationOperationGate = ServerRegistrationOperationGate()
    private var hasStarted = false
    private var liveActivityStartedAt: Date?
    private var pendingPushServerEnrollment: PushServerEnrollment?
    private var pendingPushServerCleanupSettings: PushServerSettings?
    private var pendingServerAccountDeletions: [UUID: Int64] = [:]
    private var pendingServerAccountDeletionURL: String?
    private var serverConsentHighWater: [UUID: Int64] = [:]
    private static let maximumServerConsentRevision: Int64 = 9_007_199_254_740_991
    private static let globalActivityID = UUID(uuidString: "00000000-0000-4000-8000-000000000001")!

#if os(iOS)
    private static var runningGlobalActivities: [Activity<UsageActivityAttributes>] {
        Activity<UsageActivityAttributes>.activities.filter {
            $0.attributes.accountID == globalActivityID
                && LiveActivityLifecyclePolicy.isRunning($0.activityState)
        }
    }
#endif

    init() {
        let cachedAccounts = UserDefaults.standard.data(forKey: accountsKey)
            .flatMap { try? JSONDecoder().decode([MonitoredAccount].self, from: $0) } ?? []
        accounts = Self.loadInitialAccounts(cachedAccounts)
        cacheAccounts()
        let accountIDs = Set(accounts.map(\.id))
        snapshots = Dictionary(uniqueKeysWithValues: SharedSnapshotStore.load()
            .filter { accountIDs.contains($0.accountID) }
            .map { ($0.accountID, $0) })
        if let data = UserDefaults.standard.data(forKey: settingsKey),
           let saved = try? JSONDecoder().decode([UUID: AccountMonitorSettings].self, from: data) { monitorSettings = saved }
        if let data = UserDefaults.standard.data(forKey: liveActivitySettingsKey),
           let saved = try? JSONDecoder().decode(GlobalLiveActivitySettings.self, from: data) {
            liveActivitySettings = saved
        }
        if let data = UserDefaults.standard.data(forKey: notificationSettingsKey),
           let saved = try? JSONDecoder().decode(GlobalNotificationSettings.self, from: data) {
            notificationSettings = saved
        }
        if let data = UserDefaults.standard.data(forKey: refreshSettingsKey),
           let saved = try? JSONDecoder().decode(GlobalRefreshSettings.self, from: data) {
            refreshSettings = saved
        }
        if let data = UserDefaults.standard.data(forKey: pushServerSettingsKey),
           let saved = try? JSONDecoder().decode(PushServerSettings.self, from: data) {
            pushServerSettings = saved
            pushServerStatus = saved.mode == .disabled ? .disabled : .waitingForDeviceToken
        }
        if let data = UserDefaults.standard.data(forKey: pendingPushServerCleanupKey) {
            pendingPushServerCleanupSettings = try? JSONDecoder().decode(
                PushServerSettings.self,
                from: data
            )
        }
        if let data = UserDefaults.standard.data(forKey: pendingServerAccountDeletionsKey) {
            if let revisions = try? JSONDecoder().decode([UUID: Int64].self, from: data) {
                pendingServerAccountDeletions = revisions
            } else if let legacyIDs = try? JSONDecoder().decode(Set<UUID>.self, from: data) {
                pendingServerAccountDeletions = Dictionary(
                    uniqueKeysWithValues: legacyIDs.map { ($0, 1) }
                )
            }
        }
        pendingServerAccountDeletionURL = UserDefaults.standard.string(
            forKey: pendingServerAccountDeletionURLKey
        )
        if let data = UserDefaults.standard.data(forKey: serverConsentHighWaterKey),
           let saved = try? JSONDecoder().decode([UUID: Int64].self, from: data) {
            serverConsentHighWater = saved
        }
        if let pendingPushServerCleanupSettings {
            let host = (try? pendingPushServerCleanupSettings.resolvedServerURL())?.host
                ?? "the previous Worker"
            pushServerStatus = .failed("Couldn’t confirm removal from \(host). Retry cleanup.")
        }
        normalizeServerConsentRevisions()
        reconcilePendingServerAccountDeletionConsents()
#if os(iOS)
        let globalActivityIsRunning = !Self.runningGlobalActivities.isEmpty
        hasLiveActivity = globalActivityIsRunning
        if globalActivityIsRunning {
            liveActivityStartedAt = UserDefaults.standard.object(
                forKey: liveActivityStartedAtKey
            ) as? Date ?? .now
            persistLiveActivityStartedAt()
        } else {
            setLiveActivityStartedAt(nil)
        }
#else
        hasLiveActivity = false
        setLiveActivityStartedAt(nil)
#endif
    }

    func start() async {
        guard !hasStarted else { return }
        hasStarted = true
        if let cleanup = pendingPushServerCleanupSettings {
            let target = preparePushServerCleanupTarget(cleanup)
            await transitionPushServer(from: cleanup, to: target)
        } else {
            RemotePushCoordinator.shared.requestRegistrationIfNeeded()
        }
        var pendingNotifications: [UsageNotificationEvent] = []
        do {
            let loaded = try await historyStore.load()
            usageHistory = loaded.points
            pendingNotifications = loaded.pendingNotifications
            historyStorageError = nil
        } catch {
            historyStorageError = error.localizedDescription
        }
        if hasAnyEnabledNotification {
            await UsageNotificationService.prepareProvisionalAuthorization()
        }
        await deliverUsageNotifications(pendingNotifications)
        await reconcileScheduledResetNotifications()
        guard !accounts.isEmpty else { return }
        await refreshAll(source: .launch)
    }

    func synchronizeAccountsFromICloudKeychain() async {
        guard UserDefaults.standard.bool(forKey: Self.accountKeychainMigrationKey),
              let syncedAccounts = try? KeychainStore.loadAccounts() else { return }
        let updatedAccounts = Self.mergeSyncedAccounts(syncedAccounts, localAccounts: accounts)
        guard updatedAccounts != accounts else { return }

        let previousByID = Dictionary(uniqueKeysWithValues: accounts.map { ($0.id, $0) })
        let updatedIDs = Set(updatedAccounts.map(\.id))
        let removedIDs = Set(previousByID.keys).subtracting(updatedIDs)
        let accountsToRefresh = updatedAccounts.filter { account in
            !account.isDemo && previousByID[account.id] != account
        }

        let currentPushSettings = pushServerSettings
        let currentServerURL = (try? currentPushSettings.resolvedServerURL())?.absoluteString
        var serverDeletions: [(accountID: UUID, consentRevision: Int64)] = []
        if currentServerURL != nil {
            for id in removedIDs {
                guard let removedAccount = previousByID[id] else { continue }
                let accountSettings = settings(for: removedAccount)
                let pendingRevision = pendingServerAccountDeletionURL == currentServerURL
                    ? pendingServerAccountDeletions[id] : nil
                guard hasServerConsent(accountSettings, account: removedAccount)
                        || pendingRevision != nil else { continue }
                let revision = nextServerConsentRevision(
                    for: id,
                    after: max(
                        accountSettings.selfHostedServerConsentRevision,
                        pendingRevision ?? 0
                    )
                )
                recordServerAccountDeletionIntent(
                    accountID: id,
                    consentRevision: revision,
                    serverSettings: currentPushSettings
                )
                serverDeletions.append((id, revision))
            }
        }

        accounts = updatedAccounts
        cacheAccounts()
        for id in removedIDs {
            snapshots.removeValue(forKey: id)
            refreshFailures.removeValue(forKey: id)
            monitorSettings.removeValue(forKey: id)
            do {
                usageHistory = try await historyStore.remove(accountID: id)
                historyStorageError = nil
            } catch {
                historyStorageError = error.localizedDescription
            }
        }
        persistMonitorSettings()

        for deletion in serverDeletions {
            do {
                try await deleteServerAccount(
                    settings: currentPushSettings,
                    accountID: deletion.accountID,
                    consentRevision: deletion.consentRevision
                )
                clearServerAccountDeletionIntent(
                    accountID: deletion.accountID,
                    through: deletion.consentRevision,
                    serverSettings: currentPushSettings
                )
            } catch {
                guard pendingServerAccountDeletionURL == currentServerURL else { continue }
                errorMessage = "The account was removed from this device, but its Worker copy is still awaiting deletion: \(error.localizedDescription)"
            }
        }

        if hasStarted {
            if let serverURL = try? currentPushSettings.resolvedServerURL(),
               (try? KeychainStore.loadPushRegistration(for: serverURL)) != nil {
                _ = try? await reconcileRemoteWorkerAccounts()
            }
            for account in accountsToRefresh {
                _ = await refresh(account, source: .background, publishChanges: false)
            }
        }
        publishSnapshots()
        await reconcileScheduledResetNotifications()
        await updateLiveActivity()
        await reconcileLiveActivity()
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
            displayName: "Demo workspace",
            workspaceID: MonitoredAccount.demoWorkspaceID,
            plan: "Demo plan",
            addedAt: .now,
            customSymbolName: "timer.circle.fill"
        )
        accounts.append(account)
        persistAccounts()
        await seedDemoHistory(for: account)
        await refresh(account, source: .demo)
        return account
    }

    func availableRemoteWorkerAccounts() async throws -> [RemoteWorkerAccountCandidate] {
        let candidates = try await PushServerClient.remoteAccounts(settings: pushServerSettings)
        let serverURL = (try? pushServerSettings.resolvedServerURL())?.absoluteString
        let existing = Set(accounts.compactMap { account -> String? in
            if account.remoteWorkerServerURL == serverURL,
               let remoteAccountID = account.remoteWorkerAccountID {
                return remoteAccountID
            }
            let accountSettings = settings(for: account)
            guard accountSettings.selfHostedServerConsentURL == serverURL else { return nil }
            return accountSettings.remoteWorkerAccountID
        })
        let existingReferences = Set(accounts.compactMap { account -> String? in
            let accountSettings = settings(for: account)
            guard accountSettings.selfHostedServerConsentURL == serverURL
                    || account.remoteWorkerServerURL == serverURL else { return nil }
            return accountSettings.workerAccountReference
        })
        return candidates.filter { candidate in
            !existing.contains(candidate.remoteAccountID)
                && candidate.workerAccountReference.map {
                    !existingReferences.contains($0)
                } != false
        }
    }

    @discardableResult
    func reconcileRemoteWorkerAccounts() async throws -> [MonitoredAccount] {
        let candidates = try await availableRemoteWorkerAccounts()
        let matchingCandidates = candidates.filter { candidate in
            accounts.contains { account in
                !account.isRemoteOnly
                    && RemoteWorkerAccountMatcher.matches(
                        candidate,
                        account: account,
                        settings: settings(for: account)
                    )
            }
        }
        guard !matchingCandidates.isEmpty else { return [] }
        return try await importRemoteWorkerAccounts(matchingCandidates)
    }

    @discardableResult
    func importRemoteWorkerAccounts(_ candidates: [RemoteWorkerAccountCandidate]) async throws
        -> [MonitoredAccount] {
        guard let serverURL = try pushServerSettings.resolvedServerURL() else {
            throw PushServerError.accountMonitoringUnavailable
        }
        var imported: [MonitoredAccount] = []
        for candidate in candidates {
            let matchingLocalAccount = accounts.first { account in
                !account.isRemoteOnly
                    && RemoteWorkerAccountMatcher.matches(
                        candidate,
                        account: account,
                        settings: settings(for: account)
                    )
            }
            let alreadyImported = accounts.contains(where: {
                $0.remoteWorkerServerURL == serverURL.absoluteString
                    && $0.remoteWorkerAccountID == candidate.remoteAccountID
                    || (candidate.workerAccountReference != nil
                        && settings(for: $0).selfHostedServerConsentURL
                            == serverURL.absoluteString
                        && settings(for: $0).workerAccountReference
                            == candidate.workerAccountReference)
            }) || matchingLocalAccount.map { account in
                let accountSettings = settings(for: account)
                return accountSettings.selfHostedServerConsentURL == serverURL.absoluteString
                    && accountSettings.remoteWorkerAccountID == candidate.remoteAccountID
            } == true
            guard !alreadyImported else { continue }
            let localAccountID = matchingLocalAccount?.id ?? UUID()
            let remoteAccount = try await PushServerClient.importRemoteAccount(
                settings: pushServerSettings,
                candidate: candidate,
                localAccountID: localAccountID
            )
            let account: MonitoredAccount
            if let matchingLocalAccount {
                account = matchingLocalAccount
                var accountSettings = settings(for: matchingLocalAccount)
                accountSettings.monitorOnSelfHostedServer = true
                accountSettings.selfHostedServerConsentURL = serverURL.absoluteString
                accountSettings.selfHostedServerConsentRevision = 1
                accountSettings.remoteWorkerAccountID = remoteAccount.remoteAccountID
                accountSettings.workerAccountReference = remoteAccount.workerAccountReference
                monitorSettings[localAccountID] = accountSettings
            } else {
                let details = remoteAccount.metadata?.accountDetails
                account = MonitoredAccount(
                    id: localAccountID,
                    providerID: remoteAccount.providerID,
                    displayName: remoteAccount.displayName,
                    workspaceID: MonitoredAccount.remoteWorkspacePrefix
                        + remoteAccount.remoteAccountID,
                    plan: details?.plan ?? remoteAccount.plan,
                    addedAt: .now,
                    profileName: details?.profileName,
                    email: details?.email,
                    planExpiresAt: details?.planExpiresAt,
                    trialExpiresAt: details?.trialExpiresAt,
                    remoteWorkerAccountID: remoteAccount.remoteAccountID,
                    remoteWorkerServerURL: serverURL.absoluteString
                )
                KeychainStore.delete(for: localAccountID)
                accounts.append(account)
                monitorSettings[localAccountID] = AccountMonitorSettings(
                    monitorOnSelfHostedServer: true,
                    selfHostedServerConsentURL: serverURL.absoluteString,
                    selfHostedServerConsentRevision: 1,
                    remoteWorkerAccountID: remoteAccount.remoteAccountID,
                    workerAccountReference: remoteAccount.workerAccountReference
                )
            }
            recordServerConsentHighWater(accountID: localAccountID, revision: 1)
            imported.append(account)
        }
        guard !imported.isEmpty else { return [] }
        persistAccounts()
        persistMonitorSettings()
        for account in imported {
            _ = await fetchRetainedWorkerHistory(for: account)
        }
        publishSnapshots()
        await reconcileScheduledResetNotifications()
        await updateLiveActivity()
        await reconcileLiveActivity()
        return imported
    }

    private func seedDemoHistory(for account: MonitoredAccount, endingAt date: Date = .now) async {
        do {
            var latestResult: UsageHistoryRecordResult?
            for snapshot in DemoUsageFactory.historySnapshots(for: account, endingAt: date) {
                latestResult = try await historyStore.record(
                    snapshot: snapshot,
                    account: account,
                    source: .demo,
                    notificationsEnabled: false,
                    now: date
                )
            }
            if let latestResult {
                usageHistory = latestResult.points
                historyStorageError = nil
            }
        } catch {
            historyStorageError = error.localizedDescription
        }
    }

    func beginDeviceLink(for providerID: ProviderID,
                         replacing relinkingAccount: MonitoredAccount? = nil) async {
        guard ProviderAvailability.allowsLinkStart(
            providerID,
            locale: .autoupdatingCurrent,
            isRelinking: relinkingAccount != nil
        ) else {
            return
        }
        isLinking = true; errorMessage = nil
        do {
            switch providerID {
            case .chatGPT:
                let link = try await provider.beginLink()
                chatGPTLink = link
                deviceLink = .init(providerID: .chatGPT, verificationURL: link.verificationURL,
                                   userCode: link.userCode, expiresAt: .now.addingTimeInterval(15 * 60))
            case .grok:
                let link = try await grokProvider.beginLink()
                grokLink = link
                deviceLink = .init(providerID: .grok, verificationURL: link.verificationURL,
                                   userCode: link.userCode, expiresAt: link.expiresAt)
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
            case .claude, .zai, .miniMax, .synthetic, .ollamaCloud, .warp,
                 .antigravity, .compatibleAPI, .openAIAPI, .anthropicAPI, .newAPI:
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
        isLinking = true
        errorMessage = nil
        do {
            let identity: LinkedIdentity
            switch deviceLink.providerID {
            case .chatGPT:
                guard let chatGPTLink else { throw ProviderError.invalidResponse }
                identity = try await provider.finishLink(chatGPTLink)
            case .grok:
                guard let grokLink else { throw ProviderError.invalidResponse }
                identity = try await grokProvider.finishLink(grokLink)
            case .kimi:
                guard let kimiLink else { throw ProviderError.invalidResponse }
                identity = try await kimiProvider.finishLink(kimiLink)
            case .githubCopilot:
                guard let copilotLink else { throw ProviderError.invalidResponse }
                identity = try await copilotProvider.finishLink(copilotLink)
            case .claude, .zai, .miniMax, .synthetic, .ollamaCloud, .warp,
                 .antigravity, .compatibleAPI, .openAIAPI, .anthropicAPI, .newAPI:
                throw ProviderError.invalidResponse
            }
            if let relinkingAccount, relinkingAccount.isRemoteOnly {
                try await replaceRemoteWorkerCredential(
                    for: relinkingAccount,
                    identity: identity,
                    providerID: deviceLink.providerID
                )
                clearPendingLinks(); isLinking = false
                return true
            }
            let account = try saveLinkedAccount(identity, providerID: deviceLink.providerID,
                                                replacing: relinkingAccount)
            await clearHistoryIfIdentityChanged(from: relinkingAccount, to: account)
            clearPendingLinks(); isLinking = false
            await refresh(account, source: .accountLink)
            return true
        } catch is CancellationError {
            // Preserve the still-valid device code so the UI can resume polling or explicitly
            // start over. Closing the linking view calls cancelLink(), which clears it.
            isLinking = false
            return false
        } catch {
            errorMessage = error.localizedDescription; clearPendingLinks(); isLinking = false
            return false
        }
    }

    private func replaceRemoteWorkerCredential(
        for account: MonitoredAccount,
        identity: LinkedIdentity,
        providerID: ProviderID
    ) async throws {
        guard account.isRemoteOnly,
              account.providerID == providerID,
              accounts.contains(where: { $0.id == account.id }) else {
            throw ProviderError.server(400, "The remote Worker account is no longer available.")
        }
        var verifiedAccount = account
        verifiedAccount.workspaceID = identity.workspaceID
        verifiedAccount.displayName = identity.displayName
        verifiedAccount.mergeProviderDetails(identity.accountDetails)
        let result = try await PushServerClient.uploadAccount(
            settings: pushServerSettings,
            account: verifiedAccount,
            credentials: identity.credentials,
            missingQuotas: [],
            consentRevision: 1,
            replacingRemoteCredential: true
        )
        await consumeServerResult(
            result,
            for: account,
            consentRevision: 1,
            deliverNotifications: true,
            presentErrors: true
        )
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

    @discardableResult
    func addSyntheticAccount(apiKey: String, replacing relinkingAccount: MonitoredAccount? = nil) async -> Bool {
        await addLinkedIdentity(providerID: .synthetic, replacing: relinkingAccount) {
            try await self.syntheticProvider.link(apiKey: apiKey)
        }
    }

    @discardableResult
    func addOllamaCloudAccount(cookie: String, replacing relinkingAccount: MonitoredAccount? = nil) async -> Bool {
        await addLinkedIdentity(providerID: .ollamaCloud, replacing: relinkingAccount) {
            try await self.ollamaCloudProvider.link(cookie: cookie)
        }
    }

    @discardableResult
    func addWarpAccount(apiKey: String, replacing relinkingAccount: MonitoredAccount? = nil) async -> Bool {
        await addLinkedIdentity(providerID: .warp, replacing: relinkingAccount) {
            try await self.warpProvider.link(apiKey: apiKey)
        }
    }

    func beginAntigravityLink(clientID: String, clientSecret: String) {
        isLinking = true
        errorMessage = nil
        do {
            antigravityLink = try antigravityProvider.beginLink(
                clientID: clientID,
                clientSecret: clientSecret
            )
            isLinking = false
        } catch {
            errorMessage = error.localizedDescription
            isLinking = false
        }
    }

    @discardableResult
    func completeAntigravityLink(
        callback: String,
        replacing relinkingAccount: MonitoredAccount? = nil
    ) async -> Bool {
        guard let antigravityLink else { return false }
        isLinking = true
        errorMessage = nil
        do {
            let identity = try await antigravityProvider.finishLink(
                antigravityLink,
                callback: callback
            )
            let account = try saveLinkedAccount(
                identity,
                providerID: .antigravity,
                replacing: relinkingAccount
            )
            await clearHistoryIfIdentityChanged(from: relinkingAccount, to: account)
            self.antigravityLink = nil
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
    func addCompatibleAPIAccount(
        endpoint: String,
        apiKey: String,
        name: String,
        replacing relinkingAccount: MonitoredAccount? = nil
    ) async -> Bool {
        await addLinkedIdentity(providerID: .compatibleAPI, replacing: relinkingAccount) {
            try await self.compatibleAPIProvider.link(
                endpoint: endpoint,
                apiKey: apiKey,
                name: name
            )
        }
    }

    @discardableResult
    func addOpenAIAPIAccount(
        apiKey: String,
        monthlyBudget: Double?,
        replacing relinkingAccount: MonitoredAccount? = nil
    ) async -> Bool {
        await addLinkedIdentity(providerID: .openAIAPI, replacing: relinkingAccount) {
            try await self.openAIAPIProvider.link(
                apiKey: apiKey,
                monthlyBudget: monthlyBudget
            )
        }
    }

    @discardableResult
    func addAnthropicAPIAccount(
        apiKey: String,
        monthlyBudget: Double?,
        replacing relinkingAccount: MonitoredAccount? = nil
    ) async -> Bool {
        await addLinkedIdentity(providerID: .anthropicAPI, replacing: relinkingAccount) {
            try await self.anthropicAPIProvider.link(
                apiKey: apiKey,
                monthlyBudget: monthlyBudget
            )
        }
    }

    @discardableResult
    func addNewAPIAccount(
        baseURL: String,
        apiKey: String,
        name: String,
        replacing relinkingAccount: MonitoredAccount? = nil
    ) async -> Bool {
        await addLinkedIdentity(providerID: .newAPI, replacing: relinkingAccount) {
            try await self.newAPIProvider.link(
                baseURL: baseURL,
                apiKey: apiKey,
                name: name
            )
        }
    }

    private func addLinkedIdentity(
        providerID: ProviderID,
        replacing relinkingAccount: MonitoredAccount?,
        link: () async throws -> LinkedIdentity
    ) async -> Bool {
        isLinking = true
        errorMessage = nil
        do {
            let identity = try await link()
            let account = try saveLinkedAccount(
                identity,
                providerID: providerID,
                replacing: relinkingAccount
            )
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
        if source == .manual, hasAnyEnabledNotification {
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
        await reconcileScheduledResetNotifications()
        await updateLiveActivity()
        await reconcileLiveActivity()
        return succeeded
    }

    @discardableResult
    func refresh(_ account: MonitoredAccount,
                 source: UsageRefreshSource = .manual,
                 publishChanges: Bool = true) async -> Bool {
        switch AccountRefreshRoute(
            isDemo: account.isDemo,
            serverMonitoringEnabled: isServerMonitoringEnabled(for: account),
            remoteOnly: account.isRemoteOnly
        ) {
        case .demo:
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
                await reconcileScheduledResetNotifications()
                await updateLiveActivity()
                await reconcileLiveActivity()
            }
            return true
        case .server:
            // The Worker is the sole provider poller for an opted-in account. Periodic foreground,
            // background, manual, and silent-push refreshes only download its latest result.
            if source == .accountLink, !account.isRemoteOnly {
                // A relink replaces the Worker credential envelope, but still never contacts the
                // provider from this device.
                return await uploadServerAccount(
                    account,
                    presentErrors: source.presentsFetchFailureAlerts
                )
            }
            return await syncServerAccount(
                account,
                publishChanges: publishChanges,
                presentErrors: source.presentsFetchFailureAlerts
            )
        case .provider:
            break
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
            case .grok:
                let refreshed = try await grokProvider.refreshedIfNeeded(credentials)
                if refreshed != credentials {
                    try KeychainStore.save(refreshed, for: account.id)
                    credentials = refreshed
                }
                if let identity = try? GrokProvider.linkedIdentity(credentials: credentials),
                   let updated = mergeProviderDetails(identity.accountDetails, for: account.id) {
                    effectiveAccount = updated
                }
                snapshot = try await grokProvider.fetchUsage(
                    account: effectiveAccount,
                    credentials: credentials
                )
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
            case .synthetic:
                snapshot = try await syntheticProvider.fetchUsage(account: effectiveAccount, credentials: credentials)
            case .ollamaCloud:
                snapshot = try await ollamaCloudProvider.fetchUsage(account: effectiveAccount, credentials: credentials)
            case .warp:
                snapshot = try await warpProvider.fetchUsage(account: effectiveAccount, credentials: credentials)
            case .antigravity:
                let refreshed = try await antigravityProvider.refreshedIfNeeded(credentials)
                if refreshed != credentials {
                    try KeychainStore.save(refreshed, for: account.id)
                    credentials = refreshed
                }
                snapshot = try await antigravityProvider.fetchUsage(
                    account: effectiveAccount,
                    credentials: credentials
                )
            case .compatibleAPI:
                snapshot = try await compatibleAPIProvider.fetchUsage(
                    account: effectiveAccount,
                    credentials: credentials
                )
            case .openAIAPI:
                snapshot = try await openAIAPIProvider.fetchUsage(
                    account: effectiveAccount,
                    credentials: credentials
                )
            case .anthropicAPI:
                snapshot = try await anthropicAPIProvider.fetchUsage(
                    account: effectiveAccount,
                    credentials: credentials
                )
            case .newAPI:
                snapshot = try await newAPIProvider.fetchUsage(
                    account: effectiveAccount,
                    credentials: credentials
                )
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
            if isServerMonitoringEnabled(for: account) {
                await uploadServerAccount(
                    effectiveAccount,
                    presentErrors: source.presentsFetchFailureAlerts
                )
            }
            if publishChanges {
                publishSnapshots()
                await reconcileScheduledResetNotifications()
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
            if source.presentsFetchFailureAlerts {
                refreshFailures[account.id] = AccountRefreshFailure(error: error)
            }
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
            if isServerMonitoringEnabled(for: account) {
                var accountSettings = settings(for: account)
                accountSettings.selfHostedServerConsentRevision = nextServerConsentRevision(
                    for: account.id,
                    after: accountSettings.selfHostedServerConsentRevision
                )
                monitorSettings[account.id] = accountSettings
                persistMonitorSettings()
            }
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
        grokLink = nil
        kimiLink = nil
        copilotLink = nil
        claudeLink = nil
        antigravityLink = nil
    }

    func remove(_ account: MonitoredAccount) {
        let accountSettings = settings(for: account)
        let currentPushSettings = pushServerSettings
        let serverURL = (try? currentPushSettings.resolvedServerURL())?.absoluteString
        let pendingRevision = pendingServerAccountDeletionURL == serverURL
            ? pendingServerAccountDeletions[account.id] : nil
        let shouldDeleteServerCopy = serverURL != nil
            && (isServerMonitoringEnabled(for: account) || pendingRevision != nil)
        let deletionRevision = nextServerConsentRevision(
            for: account.id,
            after: max(
                accountSettings.selfHostedServerConsentRevision,
                pendingRevision ?? 0
            )
        )
        if shouldDeleteServerCopy {
            recordServerAccountDeletionIntent(
                accountID: account.id,
                consentRevision: deletionRevision,
                serverSettings: currentPushSettings
            )
        }
        accounts.removeAll { $0.id == account.id }
        snapshots.removeValue(forKey: account.id)
        refreshFailures.removeValue(forKey: account.id)
        monitorSettings.removeValue(forKey: account.id)
        if !account.isDemo {
            KeychainStore.delete(for: account.id)
            KeychainStore.deleteAccount(for: account.id)
        }
        persistAccounts(); persistMonitorSettings(); publishSnapshots()
        Task {
            if shouldDeleteServerCopy {
                do {
                    try await deleteServerAccount(
                        settings: currentPushSettings,
                        accountID: account.id,
                        consentRevision: deletionRevision
                    )
                    clearServerAccountDeletionIntent(
                        accountID: account.id,
                        through: deletionRevision,
                        serverSettings: currentPushSettings
                    )
                } catch {
                    let currentURL = (try? pushServerSettings.resolvedServerURL())?.absoluteString
                    if serverURL == currentURL {
                        let message = "The account was removed locally, but its Worker copy could not be removed: \(error.localizedDescription)"
                        errorMessage = message
                        pushServerStatus = .failed(message)
                    }
                }
            }
            do {
                usageHistory = try await historyStore.remove(accountID: account.id)
                historyStorageError = nil
            } catch {
                historyStorageError = error.localizedDescription
            }
            await reconcileScheduledResetNotifications()
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
        Task {
            if isServerMonitoringEnabled(for: account) {
                await uploadServerAccount(account)
            }
            await reconcileScheduledResetNotifications()
            await updateLiveActivity()
            await reconcileLiveActivity()
        }
    }

    private func endGlobalLiveActivity() async {
#if os(iOS)
        let finalContent = ActivityContent(state: activityState(), staleDate: nil)
        for activity in Activity<UsageActivityAttributes>.activities {
            await activity.end(finalContent, dismissalPolicy: .immediate)
        }
        hasLiveActivity = false
        setLiveActivityStartedAt(nil)
#else
        hasLiveActivity = false
#endif
    }

    private func startGlobalLiveActivity() async {
#if os(iOS)
        guard UIApplication.shared.applicationState == .active,
              ActivityAuthorizationInfo().areActivitiesEnabled,
              hasEligibleLiveActivityContent else { return }
        let attributes = UsageActivityAttributes(accountID: Self.globalActivityID,
                                                  accountName: "All accounts", providerName: "When Reset")
        let state = activityState()
        do {
            _ = try Activity.request(attributes: attributes,
                                     content: ActivityContent(state: state, staleDate: nil))
            hasLiveActivity = true
            setLiveActivityStartedAt(.now)
        } catch {
            errorMessage = error.localizedDescription
            hasLiveActivity = false
        }
#else
        hasLiveActivity = false
#endif
    }

    func settings(for account: MonitoredAccount) -> AccountMonitorSettings { monitorSettings[account.id] ?? .init() }

    func isServerMonitoringEnabled(for account: MonitoredAccount) -> Bool {
        serverMonitoringEnabled(settings(for: account), account: account)
    }

    @discardableResult
    func fetchRetainedWorkerHistory(for account: MonitoredAccount) async -> Bool {
        errorMessage = nil
        guard let currentAccount = accounts.first(where: { $0.id == account.id }),
              pushServerSettings.mode != .disabled,
              isServerMonitoringEnabled(for: currentAccount) else {
            errorMessage = "Connect this account to a Worker before fetching remote history."
            return false
        }
        return await syncServerAccount(
            currentAccount,
            publishChanges: true,
            presentErrors: true,
            historyFetchScope: .retainedHistory
        )
    }

    private func serverMonitoringEnabled(_ settings: AccountMonitorSettings,
                                         account: MonitoredAccount) -> Bool {
        pendingPushServerCleanupSettings == nil
            && hasServerConsent(settings, account: account)
    }

    private func hasServerConsent(_ settings: AccountMonitorSettings,
                                  account: MonitoredAccount) -> Bool {
        guard !account.isDemo,
              let serverURL = try? pushServerSettings.resolvedServerURL() else { return false }
        if account.isRemoteOnly {
            return account.remoteWorkerServerURL == serverURL.absoluteString
        }
        guard settings.monitorOnSelfHostedServer else { return false }
        if let remoteAccountID = settings.remoteWorkerAccountID {
            return remoteAccountID.count == 43
                && settings.selfHostedServerConsentURL == serverURL.absoluteString
        }
        guard account.providerID.supportsOffDeviceMonitoring else { return false }
        return settings.selfHostedServerConsentURL == serverURL.absoluteString
    }

    private func remoteWorkerAccountID(for account: MonitoredAccount,
                                       settings: AccountMonitorSettings) -> String? {
        if account.isRemoteOnly {
            return account.remoteWorkerAccountID
        }
        guard settings.monitorOnSelfHostedServer,
              settings.selfHostedServerConsentURL
                == (try? pushServerSettings.resolvedServerURL())?.absoluteString else {
            return nil
        }
        return settings.remoteWorkerAccountID
    }

    func setSettings(_ proposedSettings: AccountMonitorSettings, for account: MonitoredAccount) {
        if account.isRemoteOnly {
            var settings = proposedSettings
            let existingSettings = self.settings(for: account)
            settings.monitorOnSelfHostedServer = true
            settings.selfHostedServerConsentURL = account.remoteWorkerServerURL
            settings.selfHostedServerConsentRevision = 1
            settings.remoteWorkerAccountID = account.remoteWorkerAccountID
            settings.workerAccountReference = existingSettings.workerAccountReference
            monitorSettings[account.id] = settings
            persistMonitorSettings()
            publishSnapshots()
            return
        }
        let previousSettings = self.settings(for: account)
        var settings = proposedSettings
        if settings.remoteWorkerAccountID?.count != 43 {
            settings.remoteWorkerAccountID = nil
        }
        if settings.workerAccountReference?.range(
            of: #"^[A-Za-z0-9_-]{43}$"#,
            options: .regularExpression
        ) == nil {
            settings.workerAccountReference = nil
        }
        if settings.monitorOnSelfHostedServer,
           !hasServerConsent(settings, account: account) {
            settings.monitorOnSelfHostedServer = false
            settings.selfHostedServerConsentURL = nil
        }
        let wasServerMonitoring = hasServerConsent(previousSettings, account: account)
        let isServerMonitoring = hasServerConsent(settings, account: account)
        let isRemoteWorkerSource = remoteWorkerAccountID(
            for: account,
            settings: settings
        ) != nil
        if !isServerMonitoring {
            settings.remoteWorkerAccountID = nil
            settings.workerAccountReference = nil
        }
        if isRemoteWorkerSource {
            settings.selfHostedServerConsentRevision = 1
        } else if wasServerMonitoring != isServerMonitoring {
            settings.selfHostedServerConsentRevision = nextServerConsentRevision(
                for: account.id,
                after: previousSettings.selfHostedServerConsentRevision
            )
        } else if isServerMonitoring {
            settings.selfHostedServerConsentRevision = max(
                1,
                max(
                    previousSettings.selfHostedServerConsentRevision,
                    serverConsentHighWater[account.id] ?? 0
                )
            )
        } else {
            settings.selfHostedServerConsentRevision = max(
                settings.selfHostedServerConsentRevision,
                max(
                    previousSettings.selfHostedServerConsentRevision,
                    serverConsentHighWater[account.id] ?? 0
                )
            )
        }
        let consentRevision = settings.selfHostedServerConsentRevision
        recordServerConsentHighWater(accountID: account.id, revision: consentRevision)
        let serverSettingsAtChange = pushServerSettings
        let serverURLAtChange = (try? serverSettingsAtChange.resolvedServerURL())?.absoluteString
        if wasServerMonitoring, !isServerMonitoring {
            recordServerAccountDeletionIntent(
                accountID: account.id,
                consentRevision: consentRevision,
                serverSettings: serverSettingsAtChange
            )
        }
        monitorSettings[account.id] = settings
        persistMonitorSettings()
        publishSnapshots()
        Task {
            if wasServerMonitoring != isServerMonitoring {
                if isServerMonitoring {
                    await uploadServerAccount(account)
                } else if serverSettingsAtChange.mode != .disabled {
                    do {
                        try await deleteServerAccount(
                            settings: serverSettingsAtChange,
                            accountID: account.id,
                            consentRevision: consentRevision
                        )
                        clearServerAccountDeletionIntent(
                            accountID: account.id,
                            through: consentRevision,
                            serverSettings: serverSettingsAtChange
                        )
                    } catch {
                        guard let currentAccount = accounts.first(where: { $0.id == account.id })
                        else { return }
                        let currentSettings = self.settings(for: currentAccount)
                        let currentServerURL = (try? pushServerSettings.resolvedServerURL())?
                            .absoluteString
                        guard currentSettings.selfHostedServerConsentRevision == consentRevision,
                              !hasServerConsent(currentSettings, account: currentAccount),
                              currentServerURL == serverURLAtChange else { return }
                        let message = "Monitoring is off locally, but the Worker copy could not be removed: \(error.localizedDescription)"
                        errorMessage = message
                        pushServerStatus = .failed(message)
                    }
                }
            } else if isServerMonitoring,
                      previousSettings.missingQuotaHistoryBehaviors
                        != settings.missingQuotaHistoryBehaviors,
                      !isRemoteWorkerSource {
                await uploadServerAccount(account)
            }
            if previousSettings.notifyAboutResets != settings.notifyAboutResets {
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
            if previousSettings.notifyAtScheduledReset != settings.notifyAtScheduledReset {
                if settings.notifyAtScheduledReset,
                   notificationSettings.notifyAtScheduledReset,
                   !account.isDemo {
                    await UsageNotificationService.requestProminentAuthorization()
                }
                await reconcileScheduledResetNotifications()
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

    func setNotificationSettings(_ settings: GlobalNotificationSettings) {
        let previousSettings = notificationSettings
        notificationSettings = settings
        UserDefaults.standard.set(try? JSONEncoder().encode(settings), forKey: notificationSettingsKey)
        Task {
            if !previousSettings.notifyAtScheduledReset,
               settings.notifyAtScheduledReset,
               accounts.contains(where: { !$0.isDemo && self.settings(for: $0).notifyAtScheduledReset }) {
                await UsageNotificationService.requestProminentAuthorization()
            }
            await reconcileScheduledResetNotifications()
        }
    }

    func setRefreshSettings(_ settings: GlobalRefreshSettings) {
        refreshSettings = settings
        UserDefaults.standard.set(try? JSONEncoder().encode(settings), forKey: refreshSettingsKey)
        BackgroundRefreshScheduler.scheduleNext(after: settings.backgroundInterval)
        Task { await updateLiveActivity() }
    }

    func confirmPushServerLink(
        _ draft: WorkerLinkDraft,
        monitoringAccountIDs: Set<UUID>,
        interval: RefreshInterval,
        userConfirmedCredentialUpload: Bool
    ) throws {
        guard userConfirmedCredentialUpload else {
            throw PushServerError.userConfirmationRequired
        }
        guard pendingPushServerCleanupSettings == nil else {
            throw PushServerError.serverCleanupRequired
        }
        let serverURL = draft.serverURL
        if case let .pairing(payload) = draft {
            try payload.validateNotExpired()
        }

        let enrollment: PushServerEnrollment
        switch draft {
        case let .pairing(payload):
            enrollment = .pairing(payload)
        case let .manual(_, _, accessKey):
            let normalizedKey = accessKey.trimmingCharacters(in: .whitespacesAndNewlines)
            guard normalizedKey.count >= 32 else { throw PushServerError.missingServerAccessKey }
            try KeychainStore.savePushServerAccessKey(normalizedKey, for: serverURL)
            enrollment = .accessKey(normalizedKey)
        }

        let previousSettings = pushServerSettings
        let previousURL = try? previousSettings.resolvedServerURL()
        let previouslyEnabled = Set(
            accounts.filter { isServerMonitoringEnabled(for: $0) }.map(\.id)
        )
        let eligibleIDs = Set(accounts.compactMap { account -> UUID? in
            guard monitoringAccountIDs.contains(account.id),
                  !account.isDemo,
                  !account.isRemoteOnly,
                  account.providerID.supportsOffDeviceMonitoring else { return nil }
            return account.id
        })
        if previousSettings.mode != .disabled, previousURL != serverURL {
            pendingPushServerCleanupSettings = previousSettings
            persistPendingServerCleanup()
        }

        var newAccountDeletions: [UUID: Int64] = [:]
        for account in accounts {
            var accountSettings = settings(for: account)
            let enabled = eligibleIDs.contains(account.id)
            let hadConsentForThisServer = accountSettings.monitorOnSelfHostedServer
                && accountSettings.selfHostedServerConsentURL == serverURL.absoluteString
            let keepsRemoteWorkerSource = enabled
                && hadConsentForThisServer
                && accountSettings.remoteWorkerAccountID?.count == 43
            let previousRevision = max(
                accountSettings.selfHostedServerConsentRevision,
                serverConsentHighWater[account.id] ?? 0
            )
            if keepsRemoteWorkerSource {
                accountSettings.selfHostedServerConsentRevision = 1
            } else if enabled {
                accountSettings.selfHostedServerConsentRevision = hadConsentForThisServer
                    ? max(1, previousRevision)
                    : nextServerConsentRevision(
                        for: account.id,
                        after: previousRevision
                    )
            } else if accountSettings.monitorOnSelfHostedServer {
                accountSettings.selfHostedServerConsentRevision = nextServerConsentRevision(
                    for: account.id,
                    after: previousRevision
                )
            } else {
                accountSettings.selfHostedServerConsentRevision = previousRevision
            }
            recordServerConsentHighWater(
                accountID: account.id,
                revision: accountSettings.selfHostedServerConsentRevision
            )
            if previousURL == serverURL,
               previouslyEnabled.contains(account.id),
               !enabled {
                recordServerAccountDeletionIntent(
                    accountID: account.id,
                    consentRevision: accountSettings.selfHostedServerConsentRevision,
                    serverSettings: previousSettings
                )
            }
            accountSettings.monitorOnSelfHostedServer = enabled
            accountSettings.selfHostedServerConsentURL = enabled ? serverURL.absoluteString : nil
            if !keepsRemoteWorkerSource {
                accountSettings.remoteWorkerAccountID = nil
            }
            monitorSettings[account.id] = accountSettings
            if previousURL == serverURL,
               previouslyEnabled.contains(account.id),
               !enabled {
                newAccountDeletions[account.id] = accountSettings
                    .selfHostedServerConsentRevision
            }
        }
        persistMonitorSettings()
        publishSnapshots()

        let settings = PushServerSettings(
            mode: .custom,
            customServerURL: serverURL.absoluteString,
            serverMonitoringInterval: interval
        )
        pushServerSettings = settings
        UserDefaults.standard.set(
            try? JSONEncoder().encode(settings),
            forKey: pushServerSettingsKey
        )
        pendingPushServerEnrollment = enrollment
        var accountDeletions = newAccountDeletions
        if pendingServerAccountDeletionURL == serverURL.absoluteString {
            for (accountID, revision) in pendingServerAccountDeletions {
                accountDeletions[accountID] = max(
                    accountDeletions[accountID] ?? 0,
                    revision
                )
            }
        }
        pendingServerAccountDeletions = accountDeletions
        pendingServerAccountDeletionURL = pendingServerAccountDeletions.isEmpty
            ? nil : serverURL.absoluteString
        persistPendingServerCleanup()
        pushServerStatus = .waitingForDeviceToken
        Task { await transitionPushServer(from: previousSettings, to: settings) }
    }

    func updatePushServerMonitoringInterval(_ interval: RefreshInterval) {
        guard pushServerSettings.mode != .disabled else { return }
        pushServerSettings.serverMonitoringInterval = interval
        UserDefaults.standard.set(
            try? JSONEncoder().encode(pushServerSettings),
            forKey: pushServerSettingsKey
        )
        Task {
            for account in accounts
                where isServerMonitoringEnabled(for: account)
                    && !account.isRemoteOnly
                    && remoteWorkerAccountID(for: account, settings: settings(for: account)) == nil {
                await uploadServerAccount(account)
            }
        }
    }

    func disablePushServer() {
        let previousSettings = pushServerSettings
        let cleanupSettings = pendingPushServerCleanupSettings ?? previousSettings
        if cleanupSettings.mode != .disabled {
            pendingPushServerCleanupSettings = cleanupSettings
            persistPendingServerCleanup()
        }
        for account in accounts {
            var accountSettings = settings(for: account)
            if accountSettings.monitorOnSelfHostedServer {
                accountSettings.selfHostedServerConsentRevision = nextServerConsentRevision(
                    for: account.id,
                    after: accountSettings.selfHostedServerConsentRevision
                )
            }
            accountSettings.monitorOnSelfHostedServer = false
            accountSettings.selfHostedServerConsentURL = nil
            accountSettings.remoteWorkerAccountID = nil
            monitorSettings[account.id] = accountSettings
        }
        persistMonitorSettings()
        publishSnapshots()
        pendingPushServerEnrollment = nil
        pendingServerAccountDeletions = [:]
        pendingServerAccountDeletionURL = nil
        let disabledSettings = PushServerSettings()
        pushServerSettings = disabledSettings
        UserDefaults.standard.set(
            try? JSONEncoder().encode(pushServerSettings),
            forKey: pushServerSettingsKey
        )
        persistPendingServerCleanup()
        pushServerStatus = cleanupSettings.mode == .disabled ? .disabled : .disconnecting
        Task { await transitionPushServer(from: cleanupSettings, to: disabledSettings) }
    }

    func retryPushRegistration() {
        if let cleanup = pendingPushServerCleanupSettings {
            pushServerStatus = .disconnecting
            let target = preparePushServerCleanupTarget(cleanup)
            Task { await transitionPushServer(from: cleanup, to: target) }
            return
        }
        guard pushServerSettings.mode != .disabled else { return }
        pushServerStatus = .waitingForDeviceToken
        RemotePushCoordinator.shared.requestRegistrationIfNeeded()
    }

    func requestTestPushRefresh() async {
        let settings = pushServerSettings
        guard settings.mode != .disabled else { return }
        pushServerStatus = .registering
        do {
            try await PushServerClient.requestTestRefresh(settings: settings)
            guard pushServerSettings == settings else { return }
            pushServerStatus = .registered
        } catch {
            guard pushServerSettings == settings else { return }
            pushServerStatus = .failed(error.localizedDescription)
        }
    }

    func updatePushRegistration(deviceToken: Data) async {
        let settings = pushServerSettings
        guard settings.mode != .disabled else {
            pushServerStatus = .disabled
            return
        }
        guard let serverURL = try? settings.resolvedServerURL() else {
            pushServerStatus = .failed(PushServerError.invalidServerURL.localizedDescription)
            return
        }
        let origin = serverURL.absoluteString
        await serverRegistrationOperationGate.acquire(origin: origin)
        guard (try? pushServerSettings.resolvedServerURL()) == serverURL else {
            await serverRegistrationOperationGate.release(origin: origin)
            return
        }
        await performPushRegistration(
            deviceToken: deviceToken,
            settings: pushServerSettings,
            serverURL: serverURL,
            origin: origin
        )
        await serverRegistrationOperationGate.release(origin: origin)
    }

    private func performPushRegistration(
        deviceToken: Data,
        settings: PushServerSettings,
        serverURL: URL,
        origin: String
    ) async {
        let enrollment = pendingPushServerEnrollment
        pushServerStatus = .registering
        do {
            try await PushServerClient.register(
                settings: settings,
                deviceToken: deviceToken,
                enrollment: enrollment
            )
            guard (try? pushServerSettings.resolvedServerURL()) == serverURL else { return }
            if pendingPushServerEnrollment == enrollment {
                pendingPushServerEnrollment = nil
                KeychainStore.deletePushServerAccessKey(for: serverURL)
            }
            var cleanupFailure: Error?
            if pendingServerAccountDeletionURL == origin {
                for (accountID, consentRevision) in Array(pendingServerAccountDeletions) {
                    do {
                        try await deleteServerAccount(
                            settings: settings,
                            accountID: accountID,
                            consentRevision: consentRevision
                        )
                        clearServerAccountDeletionIntent(
                            accountID: accountID,
                            through: consentRevision,
                            serverSettings: settings
                        )
                    } catch let PushServerError.serverRejected(code) where code == 409 {
                        if let currentAccount = accounts.first(where: { $0.id == accountID }) {
                            let currentSettings = self.settings(for: currentAccount)
                            if hasServerConsent(currentSettings, account: currentAccount),
                               currentSettings.selfHostedServerConsentRevision
                                > consentRevision {
                                clearServerAccountDeletionIntent(
                                    accountID: accountID,
                                    through: consentRevision,
                                    serverSettings: settings
                                )
                                continue
                            }
                        }
                        cleanupFailure = PushServerError.serverRejected(code)
                    } catch {
                        cleanupFailure = error
                    }
                }
            }
            if pendingServerAccountDeletions.isEmpty {
                pendingServerAccountDeletionURL = nil
            }
            persistPendingServerCleanup()
            var remoteAttachmentFailure: Error?
            do {
                _ = try await reconcileRemoteWorkerAccounts()
            } catch {
                remoteAttachmentFailure = error
            }
            if enrollment != nil {
                for account in accounts
                    where isServerMonitoringEnabled(for: account)
                        && !account.isRemoteOnly
                        && remoteWorkerAccountID(
                            for: account,
                            settings: self.settings(for: account)
                        ) == nil {
                    await uploadServerAccount(account)
                }
            }
            guard (try? pushServerSettings.resolvedServerURL()) == serverURL else { return }
            if let cleanupFailure {
                let message = "Worker linked, but old account credentials could not be removed: \(cleanupFailure.localizedDescription)"
                errorMessage = message
                pushServerStatus = .failed(message)
            } else if let remoteAttachmentFailure {
                let message = "Worker linked, but remote history could not be attached: \(remoteAttachmentFailure.localizedDescription)"
                errorMessage = message
                pushServerStatus = .failed(message)
            } else {
                pushServerStatus = .registered
            }
        } catch {
            guard (try? pushServerSettings.resolvedServerURL()) == serverURL else { return }
            pushServerStatus = .failed(error.localizedDescription)
        }
    }

    func pushRegistrationFailed(_ error: Error) {
        guard pushServerSettings.mode != .disabled else { return }
        pushServerStatus = .failed(error.localizedDescription)
    }

    private func transitionPushServer(from previousSettings: PushServerSettings,
                                      to settings: PushServerSettings) async {
        let previousURL = try? previousSettings.resolvedServerURL()
        let newURL = try? settings.resolvedServerURL()
        if previousSettings.mode != .disabled,
           (settings.mode == .disabled || previousURL != newURL) {
            if pendingPushServerCleanupSettings == nil {
                pendingPushServerCleanupSettings = previousSettings
                persistPendingServerCleanup()
            }
            guard pendingPushServerCleanupSettings == previousSettings else { return }
            pushServerStatus = .disconnecting
            do {
                try await unregisterPushServer(settings: previousSettings)
                guard pendingPushServerCleanupSettings == previousSettings else { return }
                pendingPushServerCleanupSettings = nil
                if pendingServerAccountDeletionURL == previousURL?.absoluteString {
                    pendingServerAccountDeletions = [:]
                    pendingServerAccountDeletionURL = nil
                }
                persistPendingServerCleanup()
            } catch {
                guard pendingPushServerCleanupSettings == previousSettings else { return }
                let host = previousURL?.host ?? "the previous Worker"
                let message = "Couldn’t confirm removal from \(host): \(error.localizedDescription)"
                pushServerStatus = .failed(message)
                errorMessage = message
                return
            }
        }
        guard settings.mode != .disabled,
              (try? pushServerSettings.resolvedServerURL()) == newURL else {
            if pushServerSettings.mode == .disabled { pushServerStatus = .disabled }
            return
        }
        do {
            _ = try settings.resolvedServerURL()
            RemotePushCoordinator.shared.requestRegistrationIfNeeded()
        } catch {
            pushServerStatus = .failed(error.localizedDescription)
        }
    }

    private func preparePushServerCleanupTarget(
        _ cleanup: PushServerSettings
    ) -> PushServerSettings {
        guard ServerMonitoringRecovery.cleanupMatchesCurrentWorker(
            cleanup: cleanup,
            current: pushServerSettings
        ) else {
            return pushServerSettings
        }

        // A crash can occur after the old Worker cleanup receipt is persisted but before the
        // new target is. The intended target cannot be reconstructed safely, so fail closed:
        // unregister the known Worker and require the user to review the new link again.
        for account in accounts {
            var accountSettings = settings(for: account)
            accountSettings.monitorOnSelfHostedServer = false
            accountSettings.selfHostedServerConsentURL = nil
            monitorSettings[account.id] = accountSettings
        }
        persistMonitorSettings()
        publishSnapshots()
        pendingPushServerEnrollment = nil
        let disabledSettings = PushServerSettings()
        pushServerSettings = disabledSettings
        UserDefaults.standard.set(
            try? JSONEncoder().encode(disabledSettings),
            forKey: pushServerSettingsKey
        )
        pushServerStatus = .disconnecting
        return disabledSettings
    }

    private func unregisterPushServer(settings: PushServerSettings) async throws {
        guard let serverURL = try settings.resolvedServerURL() else {
            throw PushServerError.invalidServerURL
        }
        let origin = serverURL.absoluteString
        await serverRegistrationOperationGate.acquire(origin: origin)
        do {
            try await PushServerClient.unregister(settings: settings)
            await serverRegistrationOperationGate.release(origin: origin)
        } catch {
            await serverRegistrationOperationGate.release(origin: origin)
            throw error
        }
    }

    func reconcileLiveActivityAfterForegroundActivation() async {
        await updateLiveActivity()
        await reconcileLiveActivity()
    }

    private func reconcileLiveActivity(at date: Date = .now) async {
#if os(iOS)
        let running = !Self.runningGlobalActivities.isEmpty
        let shouldRun: Bool
        switch liveActivitySettings.mode {
        case .automatic: shouldRun = !activityEvents(at: date, matchingRules: true).isEmpty
        case .always: shouldRun = !activityEvents(at: date, matchingRules: false).isEmpty
        case .disabled: shouldRun = false
        }
        if shouldRun, !running, UIApplication.shared.applicationState == .active {
            await startGlobalLiveActivity()
        } else if !shouldRun, running {
            await endGlobalLiveActivity()
        } else if shouldRun, running,
                  UIApplication.shared.applicationState == .active,
                  LiveActivityLifecyclePolicy.shouldRotate(startedAt: liveActivityStartedAt,
                                                           at: date) {
            await endGlobalLiveActivity()
            await startGlobalLiveActivity()
        } else {
            hasLiveActivity = running
            if running, liveActivityStartedAt == nil {
                setLiveActivityStartedAt(date)
            } else if !running {
                setLiveActivityStartedAt(nil)
            }
        }
#else
        hasLiveActivity = false
#endif
    }

#if os(iOS)
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
#endif

    private func updateLiveActivity() async {
#if os(iOS)
        let state = activityState()
        let activities = Activity<UsageActivityAttributes>.activities
        let legacyActivities = activities.filter { $0.attributes.accountID != Self.globalActivityID }
        for activity in legacyActivities {
            await activity.end(ActivityContent(state: state, staleDate: nil), dismissalPolicy: .immediate)
        }
        let globalActivities = Self.runningGlobalActivities
        for activity in globalActivities {
            await activity.update(ActivityContent(state: state, staleDate: nil))
        }
        hasLiveActivity = !globalActivities.isEmpty
        if hasLiveActivity, liveActivityStartedAt == nil {
            setLiveActivityStartedAt(.now)
        } else if !hasLiveActivity {
            setLiveActivityStartedAt(nil)
        }
#else
        hasLiveActivity = false
#endif
    }

    private func setLiveActivityStartedAt(_ date: Date?) {
        liveActivityStartedAt = date
        persistLiveActivityStartedAt()
    }

    private func persistLiveActivityStartedAt() {
        if let liveActivityStartedAt {
            UserDefaults.standard.set(liveActivityStartedAt, forKey: liveActivityStartedAtKey)
        } else {
            UserDefaults.standard.removeObject(forKey: liveActivityStartedAtKey)
        }
    }

    private func persistPendingServerCleanup() {
        if let pendingPushServerCleanupSettings {
            UserDefaults.standard.set(
                try? JSONEncoder().encode(pendingPushServerCleanupSettings),
                forKey: pendingPushServerCleanupKey
            )
        } else {
            UserDefaults.standard.removeObject(forKey: pendingPushServerCleanupKey)
        }
        if pendingServerAccountDeletions.isEmpty {
            UserDefaults.standard.removeObject(forKey: pendingServerAccountDeletionsKey)
        } else {
            UserDefaults.standard.set(
                try? JSONEncoder().encode(pendingServerAccountDeletions),
                forKey: pendingServerAccountDeletionsKey
            )
        }
        if let pendingServerAccountDeletionURL {
            UserDefaults.standard.set(
                pendingServerAccountDeletionURL,
                forKey: pendingServerAccountDeletionURLKey
            )
        } else {
            UserDefaults.standard.removeObject(forKey: pendingServerAccountDeletionURLKey)
        }
    }

    private func recordServerAccountDeletionIntent(
        accountID: UUID,
        consentRevision: Int64,
        serverSettings: PushServerSettings
    ) {
        guard consentRevision > 0,
              let serverURL = try? serverSettings.resolvedServerURL() else { return }
        let normalizedURL = serverURL.absoluteString
        guard pendingServerAccountDeletions.isEmpty
                || pendingServerAccountDeletionURL == normalizedURL else {
            return
        }
        pendingServerAccountDeletions[accountID] = max(
            pendingServerAccountDeletions[accountID] ?? 0,
            consentRevision
        )
        recordServerConsentHighWater(accountID: accountID, revision: consentRevision)
        pendingServerAccountDeletionURL = normalizedURL
        persistPendingServerCleanup()
    }

    private func clearServerAccountDeletionIntent(
        accountID: UUID,
        through consentRevision: Int64,
        serverSettings: PushServerSettings
    ) {
        guard let serverURL = try? serverSettings.resolvedServerURL(),
              pendingServerAccountDeletionURL == serverURL.absoluteString,
              (pendingServerAccountDeletions[accountID] ?? .max)
                <= consentRevision else { return }
        pendingServerAccountDeletions.removeValue(forKey: accountID)
        if pendingServerAccountDeletions.isEmpty {
            pendingServerAccountDeletionURL = nil
        }
        persistPendingServerCleanup()
    }

    private func deleteServerAccount(
        settings: PushServerSettings,
        accountID: UUID,
        consentRevision: Int64
    ) async throws {
        await serverAccountOperationGate.acquire(accountID: accountID)
        do {
            try await PushServerClient.deleteAccount(
                settings: settings,
                accountID: accountID,
                consentRevision: consentRevision
            )
            await serverAccountOperationGate.release(accountID: accountID)
        } catch {
            await serverAccountOperationGate.release(accountID: accountID)
            throw error
        }
    }

    private func nextServerConsentRevision(for accountID: UUID, after revision: Int64) -> Int64 {
        let highWater = max(
            revision,
            max(
                serverConsentHighWater[accountID] ?? 0,
                pendingServerAccountDeletions[accountID] ?? 0
            )
        )
        let normalized = max(0, min(highWater, Self.maximumServerConsentRevision - 1))
        let next = normalized + 1
        recordServerConsentHighWater(accountID: accountID, revision: next)
        return next
    }

    private func recordServerConsentHighWater(accountID: UUID, revision: Int64) {
        guard revision > (serverConsentHighWater[accountID] ?? 0) else { return }
        serverConsentHighWater[accountID] = revision
        UserDefaults.standard.set(
            try? JSONEncoder().encode(serverConsentHighWater),
            forKey: serverConsentHighWaterKey
        )
    }

    private func normalizeServerConsentRevisions() {
        var changed = false
        for accountID in Array(monitorSettings.keys) {
            guard var settings = monitorSettings[accountID],
                  settings.monitorOnSelfHostedServer,
                  settings.selfHostedServerConsentRevision <= 0 else { continue }
            settings.selfHostedServerConsentRevision = 1
            monitorSettings[accountID] = settings
            recordServerConsentHighWater(accountID: accountID, revision: 1)
            changed = true
        }
        for (accountID, settings) in monitorSettings {
            recordServerConsentHighWater(
                accountID: accountID,
                revision: settings.selfHostedServerConsentRevision
            )
        }
        for (accountID, revision) in pendingServerAccountDeletions {
            recordServerConsentHighWater(accountID: accountID, revision: revision)
        }
        if changed { persistMonitorSettings() }
    }

    private func reconcilePendingServerAccountDeletionConsents() {
        guard let serverURL = try? pushServerSettings.resolvedServerURL(),
              pendingServerAccountDeletionURL == serverURL.absoluteString else { return }
        var changed = false
        for (accountID, pendingRevision) in pendingServerAccountDeletions {
            guard let settings = monitorSettings[accountID] else { continue }
            let reconciled = ServerMonitoringRecovery.reconcilingPendingDeletion(
                in: settings,
                serverURL: serverURL.absoluteString,
                pendingRevision: pendingRevision
            )
            guard reconciled != settings else { continue }
            monitorSettings[accountID] = reconciled
            recordServerConsentHighWater(accountID: accountID, revision: pendingRevision)
            changed = true
        }
        if changed { persistMonitorSettings() }
    }

    private func persistAccounts() {
        cacheAccounts()
        do {
            for account in accounts where !account.isDemo {
                try KeychainStore.saveAccount(account)
            }
            UserDefaults.standard.set(true, forKey: Self.accountKeychainMigrationKey)
        } catch {
            // The local cache remains available and the next write retries iCloud Keychain.
        }
    }

    private func cacheAccounts() {
        UserDefaults.standard.set(try? JSONEncoder().encode(accounts), forKey: accountsKey)
    }

    private static func loadInitialAccounts(_ cachedAccounts: [MonitoredAccount]) -> [MonitoredAccount] {
        do {
            if !UserDefaults.standard.bool(forKey: accountKeychainMigrationKey) {
                for account in cachedAccounts where !account.isDemo {
                    try KeychainStore.saveAccount(account)
                    _ = try? KeychainStore.load(for: account.id)
                }
                UserDefaults.standard.set(true, forKey: accountKeychainMigrationKey)
            }
            return normalizeDemoPresentation(
                mergeSyncedAccounts(try KeychainStore.loadAccounts(), localAccounts: cachedAccounts)
            )
        } catch {
            return normalizeDemoPresentation(KeychainStore.orderedAccounts(cachedAccounts))
        }
    }

    private static func normalizeDemoPresentation(_ accounts: [MonitoredAccount]) -> [MonitoredAccount] {
        accounts.map { value in
            guard value.isDemo else { return value }
            var account = value
            account.displayName = "Demo workspace"
            account.plan = "Demo plan"
            if account.customSymbolName == nil {
                account.customSymbolName = "timer.circle.fill"
            }
            return account
        }
    }

    private static func mergeSyncedAccounts(_ syncedAccounts: [MonitoredAccount],
                                            localAccounts: [MonitoredAccount]) -> [MonitoredAccount] {
        let accounts = syncedAccounts + localAccounts.filter(\.isDemo)
        let accountsByID = Dictionary(accounts.map { ($0.id, $0) },
                                      uniquingKeysWith: { _, synced in synced })
        return KeychainStore.orderedAccounts(Array(accountsByID.values))
    }

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

    private var hasAnyEnabledNotification: Bool {
        accounts.contains { account in
            guard !account.isDemo else { return false }
            let accountSettings = settings(for: account)
            return accountSettings.notifyAboutResets
                || (notificationSettings.notifyAtScheduledReset
                    && accountSettings.notifyAtScheduledReset)
        }
    }

    private func reconcileScheduledResetNotifications() async {
        let targets = ScheduledResetNotificationPlanner.targets(
            accounts: accounts,
            snapshots: snapshots,
            monitorSettings: monitorSettings,
            globalSettings: notificationSettings
        )
        await UsageNotificationService.reconcileScheduledResets(targets)
    }

    private func recordSuccessfulSnapshot(_ snapshot: UsageSnapshot, for account: MonitoredAccount,
                                          source: UsageRefreshSource,
                                          deliverNotifications: Bool) async {
        let accountSettings = settings(for: account)
        let notificationsEnabled = accountSettings.notifyAboutResets
        let scheduledNotificationsEnabled = notificationSettings.notifyAtScheduledReset
            && accountSettings.notifyAtScheduledReset
        if !account.isDemo, notificationsEnabled || scheduledNotificationsEnabled,
           source == .accountLink {
            await UsageNotificationService.requestProminentAuthorization()
        }
        do {
            let result = try await historyStore.record(
                snapshot: snapshot,
                account: account,
                source: source,
                notificationsEnabled: notificationsEnabled,
                accountSettings: accountSettings
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

    @discardableResult
    private func uploadServerAccount(_ account: MonitoredAccount,
                                     presentErrors: Bool = true) async -> Bool {
        await serverAccountOperationGate.acquire(accountID: account.id)
        let succeeded = await performServerAccountUpload(account, presentErrors: presentErrors)
        await serverAccountOperationGate.release(accountID: account.id)
        return succeeded
    }

    @discardableResult
    private func performServerAccountUpload(_ account: MonitoredAccount,
                                            presentErrors: Bool) async -> Bool {
        var accountSettings = settings(for: account)
        guard !account.isDemo,
              !account.isRemoteOnly,
              remoteWorkerAccountID(for: account, settings: accountSettings) == nil,
              serverMonitoringEnabled(accountSettings, account: account),
              pushServerSettings.mode != .disabled,
              let currentAccount = accounts.first(where: { $0.id == account.id }) else { return false }
        if accountSettings.selfHostedServerConsentRevision <= 0 {
            accountSettings.selfHostedServerConsentRevision = nextServerConsentRevision(
                for: account.id,
                after: accountSettings.selfHostedServerConsentRevision
            )
        }
        let consentRevision = accountSettings.selfHostedServerConsentRevision
        monitorSettings[account.id] = accountSettings
        persistMonitorSettings()
        let activeServerSettings = pushServerSettings
        do {
            let credentials = try KeychainStore.load(for: account.id)
            let result = try await PushServerClient.uploadAccount(
                settings: activeServerSettings,
                account: currentAccount,
                credentials: credentials,
                missingQuotas: serverMissingQuotaDescriptors(for: currentAccount),
                consentRevision: consentRevision
            )
            let currentServerURL = (try? activeServerSettings
                .resolvedServerURL())?.absoluteString
            if pendingServerAccountDeletionURL == currentServerURL,
               let pendingRevision = pendingServerAccountDeletions[account.id],
               pendingRevision < consentRevision {
                clearServerAccountDeletionIntent(
                    accountID: account.id,
                    through: pendingRevision,
                    serverSettings: activeServerSettings
                )
            }
            await consumeServerResult(
                result,
                for: currentAccount,
                consentRevision: consentRevision,
                deliverNotifications: false,
                presentErrors: presentErrors
            )
            return true
        } catch {
            guard let currentAccount = accounts.first(where: { $0.id == account.id }) else { return false }
            let currentSettings = settings(for: currentAccount)
            guard serverMonitoringEnabled(currentSettings, account: currentAccount),
                  currentSettings.selfHostedServerConsentRevision == consentRevision else { return false }
            if presentErrors {
                errorMessage = error.localizedDescription
            }
            return false
        }
    }

    private func syncServerAccount(_ account: MonitoredAccount,
                                   publishChanges: Bool,
                                   presentErrors: Bool,
                                   historyFetchScope: WorkerHistoryFetchScope = .incremental) async -> Bool {
        await serverAccountOperationGate.acquire(accountID: account.id)
        let succeeded = await performServerAccountSync(
            account,
            publishChanges: publishChanges,
            presentErrors: presentErrors,
            historyFetchScope: historyFetchScope
        )
        await serverAccountOperationGate.release(accountID: account.id)
        return succeeded
    }

    private func performServerAccountSync(_ account: MonitoredAccount,
                                          publishChanges: Bool,
                                          presentErrors: Bool,
                                          historyFetchScope: WorkerHistoryFetchScope) async -> Bool {
        let accountSettings = settings(for: account)
        guard !account.isDemo,
              serverMonitoringEnabled(accountSettings, account: account),
              pushServerSettings.mode != .disabled,
              accounts.contains(where: { $0.id == account.id }) else { return false }
        let consentRevision = accountSettings.selfHostedServerConsentRevision
        let remoteAccountID = remoteWorkerAccountID(
            for: account,
            settings: accountSettings
        )
        let latestServerPoint = usageHistory.lazy
            .filter { $0.accountID == account.id && $0.source == .server }
            .map(\.recordedAt)
            .max()
        let since = historyFetchScope.startDate(
            now: .now,
            latestServerPoint: latestServerPoint
        )
        do {
            let currentAccount = accounts.first(where: { $0.id == account.id }) ?? account
            var result = try await PushServerClient.syncAccount(
                settings: pushServerSettings,
                account: currentAccount,
                since: since
            )
            if remoteAccountID == nil {
                mergeLatestPlan(result.snapshot?.plan, for: currentAccount.id)
                let metadataSource = accounts.first(where: { $0.id == currentAccount.id })
                    ?? currentAccount
                if WorkerMetadataPolicy.shouldUpload(
                    local: metadataSource,
                    remote: result.accountDetails
                ) {
                    let uploaded = await performServerAccountUpload(
                        metadataSource,
                        presentErrors: false
                    )
                    result.accountDetails = uploaded
                        ? WorkerMetadataPolicy.authoritativeDetails(from: metadataSource)
                        : nil
                }
            }
            await consumeServerResult(
                result,
                for: currentAccount,
                consentRevision: consentRevision,
                deliverNotifications: publishChanges,
                presentErrors: presentErrors
            )
            return true
        } catch let PushServerError.serverRejected(code) where code == 404 {
            if let remoteAccountID {
                do {
                    try await PushServerClient.restoreRemoteAccount(
                        settings: pushServerSettings,
                        account: account,
                        remoteAccountID: remoteAccountID
                    )
                    let restoredAccount = accounts.first(where: { $0.id == account.id }) ?? account
                    let result = try await PushServerClient.syncAccount(
                        settings: pushServerSettings,
                        account: restoredAccount,
                        since: since
                    )
                    await consumeServerResult(
                        result,
                        for: restoredAccount,
                        consentRevision: consentRevision,
                        deliverNotifications: publishChanges,
                        presentErrors: presentErrors
                    )
                    return true
                } catch let PushServerError.serverRejected(retryCode) where retryCode == 404 {
                    return recordServerSyncFailure(
                        PushServerError.remoteAccountUnavailable,
                        for: account,
                        consentRevision: consentRevision,
                        presentErrors: presentErrors
                    )
                } catch {
                    return recordServerSyncFailure(
                        error,
                        for: account,
                        consentRevision: consentRevision,
                        presentErrors: presentErrors
                    )
                }
            }
            // Recreate a missing Worker record from the existing consented credentials without
            // falling through to a second provider request on this device.
            return await performServerAccountUpload(account, presentErrors: presentErrors)
        } catch {
            return recordServerSyncFailure(
                error,
                for: account,
                consentRevision: consentRevision,
                presentErrors: presentErrors
            )
        }
    }

    private func recordServerSyncFailure(
        _ error: Error,
        for account: MonitoredAccount,
        consentRevision: Int64,
        presentErrors: Bool
    ) -> Bool {
        guard let currentAccount = accounts.first(where: { $0.id == account.id }) else {
            return false
        }
        let currentSettings = settings(for: currentAccount)
        guard serverMonitoringEnabled(currentSettings, account: currentAccount),
              currentSettings.selfHostedServerConsentRevision == consentRevision else {
            return false
        }
        refreshFailures[account.id] = AccountRefreshFailure(error: error)
        if presentErrors {
            errorMessage = error.localizedDescription
        }
        return false
    }

    private func serverMissingQuotaDescriptors(for account: MonitoredAccount)
        -> [ServerMissingQuotaDescriptor] {
        let selectedIDs = settings(for: account).missingQuotaHistoryBehaviors
            .filter { $0.value == .recordAsFull }
            .map(\.key)
            .sorted()
        let windowsByID = Dictionary(
            uniqueKeysWithValues: (snapshots[account.id]?.usageWindows ?? []).map { ($0.metricID, $0) }
        )
        let latestHistoryByID = usageHistory
            .filter { $0.accountID == account.id }
            .reduce(into: [String: UsageHistoryPoint]()) { result, point in
                if (result[point.metricID]?.recordedAt ?? .distantPast) < point.recordedAt {
                    result[point.metricID] = point
                }
            }
        return selectedIDs.compactMap { metricID in
            if let window = windowsByID[metricID] {
                return ServerMissingQuotaDescriptor(
                    metricID: metricID,
                    title: window.displayTitle,
                    kind: window.kind,
                    windowMinutes: window.windowMinutes,
                    resetsAt: window.resetsAt
                )
            }
            guard let point = latestHistoryByID[metricID] else { return nil }
            return ServerMissingQuotaDescriptor(
                metricID: metricID,
                title: point.metricTitle,
                kind: point.kind,
                windowMinutes: point.windowMinutes,
                resetsAt: point.resetsAt
            )
        }
    }

    private func consumeServerResult(_ result: ServerAccountSyncResult,
                                     for account: MonitoredAccount,
                                     consentRevision: Int64,
                                     deliverNotifications: Bool,
                                     presentErrors: Bool) async {
        guard var currentAccount = accounts.first(where: { $0.id == account.id }) else { return }
        var currentSettings = settings(for: currentAccount)
        guard serverMonitoringEnabled(currentSettings, account: currentAccount),
              currentSettings.selfHostedServerConsentRevision == consentRevision,
              result.consentRevision == consentRevision else { return }
        if let reference = result.workerAccountReference,
           reference.range(of: #"^[A-Za-z0-9_-]{43}$"#, options: .regularExpression) != nil,
           currentSettings.workerAccountReference != reference {
            currentSettings.workerAccountReference = reference
            monitorSettings[account.id] = currentSettings
            persistMonitorSettings()
        }
        if let details = result.accountDetails,
           let updated = mergeProviderDetails(details, for: currentAccount.id) {
            currentAccount = updated
        }
        do {
            usageHistory = try await historyStore.mergeServerHistory(
                result.history,
                account: currentAccount
            )
            historyStorageError = nil
        } catch {
            historyStorageError = error.localizedDescription
        }

        switch result.sessionStatus {
        case .active:
            refreshFailures.removeValue(forKey: account.id)
        case .expired, .error:
            refreshFailures[account.id] = AccountRefreshFailure(
                workerSessionStatus: result.sessionStatus!,
                checkedAt: result.sessionCheckedAt
            )
        case .unchecked, nil:
            if result.lastError == nil { refreshFailures.removeValue(forKey: account.id) }
        }
        if let snapshot = result.snapshot,
           snapshot.fetchedAt > (snapshots[account.id]?.fetchedAt ?? .distantPast),
           accounts.contains(where: { $0.id == account.id }) {
            mergeLatestPlan(snapshot.plan, for: account.id)
            await recordSuccessfulSnapshot(
                snapshot,
                for: currentAccount,
                source: .server,
                deliverNotifications: deliverNotifications
            )
            snapshots[account.id] = snapshot
        }
        if let reference = currentSettings.workerAccountReference {
            await mergeRemoteWorkerDuplicates(
                accountReference: reference,
                preferredAccountID: account.id
            )
        }
        if deliverNotifications {
            publishSnapshots()
            await reconcileScheduledResetNotifications()
            await updateLiveActivity()
            await reconcileLiveActivity()
        }
    }

    private func mergeRemoteWorkerDuplicates(
        accountReference: String,
        preferredAccountID: UUID
    ) async {
        guard let serverURL = (try? pushServerSettings.resolvedServerURL())?.absoluteString else {
            return
        }
        let matchingAccounts = accounts.filter { account in
            let accountSettings = settings(for: account)
            let usesServer = account.remoteWorkerServerURL == serverURL
                || accountSettings.selfHostedServerConsentURL == serverURL
            return usesServer && accountSettings.workerAccountReference == accountReference
        }
        let directAccounts = matchingAccounts.filter { !$0.isRemoteOnly }
        guard let target = directAccounts.first(where: { $0.id == preferredAccountID })
                ?? directAccounts.first else { return }
        let duplicates = matchingAccounts.filter { $0.isRemoteOnly && $0.id != target.id }
        for duplicate in duplicates {
            do {
                usageHistory = try await historyStore.mergeAccount(
                    sourceID: duplicate.id,
                    into: target.id
                )
                historyStorageError = nil
            } catch {
                historyStorageError = error.localizedDescription
                continue
            }
            if let duplicateSnapshot = snapshots[duplicate.id],
               duplicateSnapshot.fetchedAt > (snapshots[target.id]?.fetchedAt ?? .distantPast) {
                var mergedSnapshot = duplicateSnapshot
                mergedSnapshot.accountID = target.id
                mergedSnapshot.accountName = target.resolvedDisplayName
                mergedSnapshot.accountSymbolName = target.customSymbolName
                snapshots[target.id] = mergedSnapshot
            }
            remove(duplicate)
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
            return !account.isDemo
                && settings(for: account).notifyAboutResets
                && notificationSettings.allows(event.kind)
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

struct ScheduledResetNotificationTarget: Equatable, Sendable {
    static let identifierPrefix = "when-reset.scheduled."

    var identifier: String
    var accountID: UUID
    var accountName: String
    var metricID: String
    var metricTitle: String
    var fireDate: Date

    static func identifier(accountID: UUID, metricID: String) -> String {
        let encodedMetricID = Data(metricID.utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
        return "\(identifierPrefix)\(accountID.uuidString).\(encodedMetricID)"
    }
}

enum ScheduledResetNotificationPlanner {
    static let maximumPendingNotifications = 60

    static func targets(accounts: [MonitoredAccount], snapshots: [UUID: UsageSnapshot],
                        monitorSettings: [UUID: AccountMonitorSettings],
                        globalSettings: GlobalNotificationSettings,
                        now: Date = .now) -> [ScheduledResetNotificationTarget] {
        guard globalSettings.notifyAtScheduledReset else { return [] }

        var targetsByIdentifier: [String: ScheduledResetNotificationTarget] = [:]
        for account in accounts where !account.isDemo {
            let accountSettings = monitorSettings[account.id] ?? .init()
            guard accountSettings.notifyAtScheduledReset,
                  let snapshot = snapshots[account.id] else { continue }

            for window in snapshot.usageWindows where window.resetsAt > now.addingTimeInterval(1) {
                let identifier = ScheduledResetNotificationTarget.identifier(
                    accountID: account.id,
                    metricID: window.metricID
                )
                let target = ScheduledResetNotificationTarget(
                    identifier: identifier,
                    accountID: account.id,
                    accountName: account.resolvedDisplayName,
                    metricID: window.metricID,
                    metricTitle: window.displayTitle,
                    fireDate: window.resetsAt
                )
                if let existing = targetsByIdentifier[identifier], existing.fireDate <= target.fireDate {
                    continue
                }
                targetsByIdentifier[identifier] = target
            }
        }

        return targetsByIdentifier.values.sorted {
            if $0.fireDate != $1.fireDate { return $0.fireDate < $1.fireDate }
            return $0.identifier < $1.identifier
        }
        .prefix(maximumPendingNotifications)
        .map { $0 }
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

    static func reconcileScheduledResets(_ targets: [ScheduledResetNotificationTarget]) async {
        let center = UNUserNotificationCenter.current()
        let pending = await center.pendingNotificationRequests()
        let existingIDs = Set(pending.lazy.map(\.identifier).filter {
            $0.hasPrefix(ScheduledResetNotificationTarget.identifierPrefix)
        })
        let desiredIDs = Set(targets.map(\.identifier))
        let staleIDs = existingIDs.subtracting(desiredIDs)
        if !staleIDs.isEmpty {
            center.removePendingNotificationRequests(withIdentifiers: Array(staleIDs))
        }

        guard !targets.isEmpty else { return }
        let settings = await center.notificationSettings()
        switch settings.authorizationStatus {
        case .authorized, .provisional, .ephemeral:
            break
        case .denied, .notDetermined:
            return
        @unknown default:
            return
        }

        for target in targets {
            let interval = target.fireDate.timeIntervalSinceNow
            guard interval > 1 else { continue }
            let content = UNMutableNotificationContent()
            content.title = "\(target.metricTitle) reset"
            content.body = "\(target.accountName)’s \(target.metricTitle) should now be available again."
            content.threadIdentifier = "usage-\(target.accountID.uuidString)"
            content.userInfo = [
                "accountID": target.accountID.uuidString,
                "metricID": target.metricID
            ]
            if settings.soundSetting == .enabled { content.sound = .default }
            let trigger = UNTimeIntervalNotificationTrigger(timeInterval: interval, repeats: false)
            let request = UNNotificationRequest(
                identifier: target.identifier,
                content: content,
                trigger: trigger
            )
            try? await center.add(request)
        }
    }
}
