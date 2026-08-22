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

    static func detachingMissingRemoteSource(
        in settings: AccountMonitorSettings,
        hasLocalCredentials: Bool
    ) -> AccountMonitorSettings? {
        guard settings.monitorOnSelfHostedServer,
              settings.remoteWorkerAccountID != nil,
              hasLocalCredentials else { return nil }
        var result = settings
        result.remoteWorkerAccountID = nil
        result.workerAccountReference = nil
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
    let title: String
    let message: String
    let failedAt: Date

    var requiresRelink: Bool { kind == .authentication }
    var systemImageName: String { requiresRelink ? "person.crop.circle.badge.exclamationmark" : "exclamationmark.triangle.fill" }

    init(error: Error, failedAt: Date = .now) {
        kind = Self.requiresReauthentication(for: error) ? .authentication : .update
        self.failedAt = failedAt
        if let pushError = error as? PushServerError,
           pushError.workerErrorCode == .unauthorized {
            title = "Worker pairing expired"
            message = "This device is no longer registered with the Worker. Pair it again in Cloud Worker settings."
        } else if let pushError = error as? PushServerError,
                  pushError.workerErrorCode == .providerRequestForbidden {
            title = "ChatGPT blocked the Worker check"
            message = "Your ChatGPT sign-in completed, but ChatGPT rejected the quota check from this Cloudflare Worker. The new sign-in was not activated on the Worker. Try again later, or monitor this account on this device instead."
        } else if kind == .authentication {
            title = "Sign-in failed"
            message = "Your sign-in expired or was revoked. Sign in again to resume updates."
        } else {
            title = "Update failed"
            message = Self.updateMessage(for: error)
        }
    }

    init(workerSessionStatus: WorkerSessionStatus, checkedAt: Date? = nil) {
        failedAt = checkedAt ?? .now
        switch workerSessionStatus {
        case .expired:
            kind = .authentication
            title = "Sign-in failed"
            message = "The Worker reports that this sign-in expired or was revoked. Sign in again to replace its encrypted credential."
        case .error, .unchecked, .active:
            kind = .update
            title = "Update failed"
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
        if let value = error as? PushServerError { return value.httpStatus }
        if let value = error as? ProviderError, case let .server(code, _) = value { return code }
        if let value = error as? KimiProviderError, case let .server(code, _) = value { return code }
        if let value = error as? CopilotProviderError, case let .server(code, _) = value { return code }
        if let value = error as? ZAIProviderError, case let .server(code, _) = value { return code }
        if let value = error as? MiniMaxProviderError, case let .server(code, _) = value { return code }
        if let value = error as? AdditionalProviderError, case let .server(_, code) = value { return code }
        return nil
    }

    static func requiresReauthentication(for error: Error) -> Bool {
        if let pushError = error as? PushServerError {
            return pushError.workerErrorCode == .providerSessionExpired
        }
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

enum AccountRelinkFailurePolicy {
    static func clearsFailureAfterLocalCredentialSave(
        serverMonitoringEnabled: Bool
    ) -> Bool {
        !serverMonitoringEnabled
    }
}

enum LocalCLICredentialSource: String, CaseIterable, Identifiable, Sendable {
    case codex
    case claudeCode

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .codex: "Codex"
        case .claudeCode: "Claude Code"
        }
    }

    var providerID: ProviderID {
        switch self {
        case .codex: .chatGPT
        case .claudeCode: .claude
        }
    }
}

enum LocalCLICredentialUnavailableReason: Equatable, Sendable {
    case unsupportedPlatform
    case sandboxed
    case notFound
    case inaccessible
}

struct LocalCLICredentialCapability: Equatable, Sendable {
    let source: LocalCLICredentialSource
    let unavailableReason: LocalCLICredentialUnavailableReason?

    var isAvailable: Bool { unavailableReason == nil }

    var message: String {
        switch unavailableReason {
        case nil:
            "Import the existing \(source.displayName) sign-in on this Mac."
        case .unsupportedPlatform:
            "Local CLI credential import is available only on Mac."
        case .sandboxed:
            "Local CLI credential import is unavailable in this sandboxed build."
        case .notFound:
            "No accessible \(source.displayName) sign-in was found on this Mac."
        case .inaccessible:
            "This app cannot access the \(source.displayName) sign-in on this Mac."
        }
    }
}

enum LocalCLICredentialResourceAccess: Equatable, Sendable {
    case available
    case notFound
    case inaccessible
}

enum LocalCLICredentialCapabilityPolicy {
    static func capability(
        source: LocalCLICredentialSource,
        isMacOS: Bool,
        isSandboxed: Bool,
        resourceAccess: LocalCLICredentialResourceAccess
    ) -> LocalCLICredentialCapability {
        let reason: LocalCLICredentialUnavailableReason?
        if !isMacOS {
            reason = .unsupportedPlatform
        } else if isSandboxed {
            reason = .sandboxed
        } else {
            reason = switch resourceAccess {
            case .available: nil
            case .notFound: .notFound
            case .inaccessible: .inaccessible
            }
        }
        return LocalCLICredentialCapability(source: source, unavailableReason: reason)
    }
}

enum LocalCLICredentialImportPolicy {
    static func requiresWorkerCredentialReplacement(
        deduplicatedExistingAccount: Bool,
        existingAccountUsesWorkerMonitoring: Bool
    ) -> Bool {
        deduplicatedExistingAccount && existingAccountUsesWorkerMonitoring
    }
}

enum LocalCLICredentialImportError: LocalizedError, Equatable {
    case unavailable(LocalCLICredentialSource, LocalCLICredentialUnavailableReason)
    case invalidCredential(LocalCLICredentialSource)
    case identityUnavailable(LocalCLICredentialSource)

    var errorDescription: String? {
        switch self {
        case let .unavailable(source, reason):
            return LocalCLICredentialCapability(source: source, unavailableReason: reason).message
        case let .invalidCredential(source):
            return "The \(source.displayName) credential has an unsupported or incomplete format."
        case let .identityUnavailable(source):
            return "The \(source.displayName) account identity could not be verified."
        }
    }
}

struct ParsedCodexCLICredential: Sendable {
    let accountID: String
    let lastRefresh: Date
    let credentials: AccountCredentials
}

enum CodexCLICredentialParser {
    private struct Document: Decodable {
        struct Tokens: Decodable {
            let accessToken: String
            let accountID: String
            let idToken: String
            let refreshToken: String

            enum CodingKeys: String, CodingKey {
                case accessToken = "access_token"
                case accountID = "account_id"
                case idToken = "id_token"
                case refreshToken = "refresh_token"
            }
        }

        let authMode: String
        let lastRefresh: String
        let tokens: Tokens

        enum CodingKeys: String, CodingKey {
            case authMode = "auth_mode"
            case lastRefresh = "last_refresh"
            case tokens
        }
    }

    static func parse(_ data: Data) throws -> ParsedCodexCLICredential {
        do {
            let document = try JSONDecoder().decode(Document.self, from: data)
            guard document.authMode.trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased() == "chatgpt",
                  let lastRefresh = parseISO8601(document.lastRefresh),
                  let accessToken = nonEmpty(document.tokens.accessToken),
                  let accountID = nonEmpty(document.tokens.accountID),
                  let idToken = nonEmpty(document.tokens.idToken),
                  let refreshToken = nonEmpty(document.tokens.refreshToken) else {
                throw LocalCLICredentialImportError.invalidCredential(.codex)
            }
            return ParsedCodexCLICredential(
                accountID: accountID,
                lastRefresh: lastRefresh,
                credentials: AccountCredentials(
                    accessToken: accessToken,
                    refreshToken: refreshToken,
                    idToken: idToken
                )
            )
        } catch is LocalCLICredentialImportError {
            throw LocalCLICredentialImportError.invalidCredential(.codex)
        } catch {
            // Never surface decoder context containing data from a credential document.
            throw LocalCLICredentialImportError.invalidCredential(.codex)
        }
    }

    private static func parseISO8601(_ raw: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: raw) ?? ISO8601DateFormatter().date(from: raw)
    }

    private static func nonEmpty(_ raw: String?) -> String? {
        let value = raw?.trimmingCharacters(in: .whitespacesAndNewlines)
        return value?.isEmpty == false ? value : nil
    }
}

struct ParsedClaudeCodeCredential: Sendable {
    let subscriptionType: String?
    let rateLimitTier: String?
    let scopes: [String]
    let credentials: AccountCredentials

    var planHint: String? {
        let subscription = subscriptionType?.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let tier = rateLimitTier?.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        switch subscription {
        case "max", "claude_max":
            return tier?.contains("20x") == true ? "Claude Max 20x" : "Claude Max"
        case "pro", "claude_pro": return "Claude Pro"
        case "team", "claude_team": return "Claude Team"
        case "enterprise", "claude_enterprise": return "Claude Enterprise"
        case let value? where !value.isEmpty: return value
        default: return nil
        }
    }
}

enum ClaudeCodeCredentialParser {
    private struct Document: Decodable {
        struct OAuth: Decodable {
            let accessToken: String
            let refreshToken: String
            let expiresAt: Double
            let subscriptionType: String?
            let rateLimitTier: String?
            let scopes: [String]
        }

        let claudeAiOauth: OAuth
    }

    static func parse(_ data: Data) throws -> ParsedClaudeCodeCredential {
        do {
            let oauth = try JSONDecoder().decode(Document.self, from: data).claudeAiOauth
            guard let accessToken = nonEmpty(oauth.accessToken),
                  let refreshToken = nonEmpty(oauth.refreshToken),
                  oauth.expiresAt.isFinite,
                  oauth.expiresAt > 0 else {
                throw LocalCLICredentialImportError.invalidCredential(.claudeCode)
            }
            let seconds = oauth.expiresAt > 10_000_000_000
                ? oauth.expiresAt / 1_000 : oauth.expiresAt
            return ParsedClaudeCodeCredential(
                subscriptionType: nonEmpty(oauth.subscriptionType),
                rateLimitTier: nonEmpty(oauth.rateLimitTier),
                scopes: oauth.scopes.compactMap(nonEmpty),
                credentials: AccountCredentials(
                    accessToken: accessToken,
                    refreshToken: refreshToken,
                    idToken: "",
                    expiresAt: Date(timeIntervalSince1970: seconds)
                )
            )
        } catch is LocalCLICredentialImportError {
            throw LocalCLICredentialImportError.invalidCredential(.claudeCode)
        } catch {
            // Never surface decoder context containing data from a credential document.
            throw LocalCLICredentialImportError.invalidCredential(.claudeCode)
        }
    }

    private static func nonEmpty(_ raw: String?) -> String? {
        let value = raw?.trimmingCharacters(in: .whitespacesAndNewlines)
        return value?.isEmpty == false ? value : nil
    }
}

enum LocalCLICredentialRuntime {
    static let claudeCodeKeychainService = "Claude Code-credentials"

    static func capability(for source: LocalCLICredentialSource) -> LocalCLICredentialCapability {
#if os(macOS)
        let isSandboxed = currentProcessIsSandboxed
        let access = isSandboxed ? .inaccessible : resourceAccess(for: source)
        return LocalCLICredentialCapabilityPolicy.capability(
            source: source,
            isMacOS: true,
            isSandboxed: isSandboxed,
            resourceAccess: access
        )
#else
        return LocalCLICredentialCapabilityPolicy.capability(
            source: source,
            isMacOS: false,
            isSandboxed: true,
            resourceAccess: .inaccessible
        )
#endif
    }

    static func load(_ source: LocalCLICredentialSource) throws -> Data {
        let currentCapability = capability(for: source)
        guard currentCapability.isAvailable else {
            throw LocalCLICredentialImportError.unavailable(
                source,
                currentCapability.unavailableReason ?? .inaccessible
            )
        }
#if os(macOS)
        do {
            switch source {
            case .codex:
                return try Data(contentsOf: codexAuthURL, options: .mappedIfSafe)
            case .claudeCode:
                var query: [String: Any] = [
                    kSecClass as String: kSecClassGenericPassword,
                    kSecAttrService as String: claudeCodeKeychainService,
                    kSecReturnData as String: true,
                    kSecMatchLimit as String: kSecMatchLimitOne
                ]
                query[kSecAttrSynchronizable as String] = kSecAttrSynchronizableAny
                var result: CFTypeRef?
                let status = SecItemCopyMatching(query as CFDictionary, &result)
                guard status == errSecSuccess, let data = result as? Data else {
                    throw LocalCLICredentialImportError.unavailable(
                        source,
                        status == errSecItemNotFound ? .notFound : .inaccessible
                    )
                }
                return data
            }
        } catch let error as LocalCLICredentialImportError {
            throw error
        } catch {
            throw LocalCLICredentialImportError.unavailable(source, .inaccessible)
        }
#else
        throw LocalCLICredentialImportError.unavailable(source, .unsupportedPlatform)
#endif
    }

#if os(macOS)
    private static var currentProcessIsSandboxed: Bool {
        guard let task = SecTaskCreateFromSelf(nil),
              let entitlement = SecTaskCopyValueForEntitlement(
                task,
                "com.apple.security.app-sandbox" as CFString,
                nil
              ) else {
            return ProcessInfo.processInfo.environment["APP_SANDBOX_CONTAINER_ID"] != nil
        }
        return (entitlement as? Bool) == true
    }

    private static var codexAuthURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex", isDirectory: true)
            .appendingPathComponent("auth.json", isDirectory: false)
    }

    private static func resourceAccess(
        for source: LocalCLICredentialSource
    ) -> LocalCLICredentialResourceAccess {
        switch source {
        case .codex:
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(
                atPath: codexAuthURL.path,
                isDirectory: &isDirectory
            ), !isDirectory.boolValue else { return .notFound }
            return FileManager.default.isReadableFile(atPath: codexAuthURL.path)
                ? .available : .inaccessible
        case .claudeCode:
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: claudeCodeKeychainService,
                kSecReturnAttributes as String: true,
                kSecMatchLimit as String: kSecMatchLimitOne
            ]
            var result: CFTypeRef?
            switch SecItemCopyMatching(query as CFDictionary, &result) {
            case errSecSuccess: return .available
            case errSecItemNotFound: return .notFound
            default: return .inaccessible
            }
        }
    }
#endif
}

enum AccountLinkProgress: Equatable, Sendable {
    case idle
    case authorizing
    case verifyingWorker(accountID: UUID, canRetryWithoutAuthorization: Bool)
    case workerVerificationFailed(accountID: UUID, canRetryWithoutAuthorization: Bool)

    var isVerifyingWorker: Bool {
        if case .verifyingWorker = self { return true }
        return false
    }

    func applies(to accountID: UUID) -> Bool {
        switch self {
        case let .verifyingWorker(id, _), let .workerVerificationFailed(id, _):
            return id == accountID
        case .idle, .authorizing:
            return false
        }
    }

    var canRetryWithoutAuthorization: Bool {
        switch self {
        case let .verifyingWorker(_, canRetry),
             let .workerVerificationFailed(_, canRetry):
            return canRetry
        case .idle, .authorizing:
            return false
        }
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

    init(
        isDemo: Bool,
        serverMonitoringEnabled: Bool,
        remoteOnly: Bool = false,
        hasLocalCredentials: Bool = false,
        workerIsCredentialAuthority: Bool = false
    ) {
        if isDemo {
            self = .demo
        } else if remoteOnly
                    || (serverMonitoringEnabled
                        && (!hasLocalCredentials || workerIsCredentialAuthority)) {
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

    func startDate(now: Date, latestServerPoint: Date?, retentionInterval: TimeInterval) -> Date {
        let earliestRetainedDate = now.addingTimeInterval(-retentionInterval)
        switch self {
        case .retainedHistory:
            return earliestRetainedDate
        case .incremental:
            guard let latestServerPoint else { return earliestRetainedDate }
            return max(earliestRetainedDate, latestServerPoint.addingTimeInterval(-60))
        }
    }
}

enum RemoteWorkerImportError: LocalizedError, Equatable {
    case accountImportPartiallySucceeded(
        importedCount: Int,
        reason: String?,
        retainedHistoryReason: String?
    )
    case retainedHistoryDownloadFailed(importedCount: Int, reason: String?)

    var errorDescription: String? {
        switch self {
        case let .accountImportPartiallySucceeded(
            importedCount,
            reason,
            retainedHistoryReason
        ):
            let noun = importedCount == 1 ? "account was" : "accounts were"
            let detail = reason.map { " \($0)" } ?? ""
            let historyDetail = retainedHistoryReason.map {
                " Retained history for the added accounts also could not be downloaded. \($0)"
            } ?? ""
            return "\(importedCount) \(noun) added, but the remaining Worker accounts could not be added.\(detail)\(historyDetail) Try again to continue."
        case let .retainedHistoryDownloadFailed(importedCount, reason):
            let noun = importedCount == 1 ? "account was" : "accounts were"
            let detail = reason.map { " \($0)" } ?? ""
            return "\(importedCount) \(noun) added, but retained history could not be downloaded.\(detail) Retry from the account’s Usage History section."
        }
    }
}

struct DirectChatGPTDuplicateMergePlan: Equatable, Sendable {
    var canonicalAccountID: UUID
    var duplicateAccountIDs: [UUID]
    var allowedProtectedAccountIDs: Set<UUID> = []
}

enum DirectChatGPTDuplicateMergePolicy {
    static func protectsDeviceUsageSource(
        _ settings: AccountMonitorSettings?,
        hasPendingDeletion: Bool = false
    ) -> Bool {
        settings?.uploadsDeviceUsageToWorker == true
            || settings?.deviceUsageWorkerURL != nil
            || hasPendingDeletion
    }

    static func plans(
        accounts: [MonitoredAccount],
        workerProtectedAccountIDs: Set<UUID>
    ) -> [DirectChatGPTDuplicateMergePlan] {
        let eligible = accounts.filter { account in
            account.providerID == .chatGPT
                && !account.isDemo
                && !account.isRemoteOnly
                && !account.workspaceID.isEmpty
                && !account.workspaceID.hasPrefix(MonitoredAccount.remoteWorkspacePrefix)
        }
        let groups = Dictionary(grouping: eligible, by: \MonitoredAccount.workspaceID)
        return groups.values.compactMap { group in
            guard group.count > 1 else { return nil }
            let canonical = group.min(by: accountOrder)!
            let protected = group.filter { workerProtectedAccountIDs.contains($0.id) }
            // Merging two physical Worker sources requires a server-side subscription/history
            // migration. Canonical selection must also be identical on every device, so a
            // device-local Worker attachment may only confirm (never override) the deterministic
            // oldest-record/UUID choice.
            // Only the device that can prove the deterministic canonical owns the Worker
            // attachment may originate the merge. Other devices wait for its synchronized alias;
            // this prevents an attachment-blind device from deleting a newer Worker owner.
            // A group with no Worker state is safe to canonicalize on every device using the
            // deterministic account ordering below. If one account is protected, only the same
            // deterministic canonical may own that state. Multiple or non-canonical protected
            // rows require a server-side migration and remain untouched.
            guard protected.isEmpty
                    || (protected.count == 1 && protected[0].id == canonical.id) else {
                return nil
            }
            let duplicates = group.filter { $0.id != canonical.id }.sorted(by: accountOrder)
            return DirectChatGPTDuplicateMergePlan(
                canonicalAccountID: canonical.id,
                duplicateAccountIDs: duplicates.map(\.id),
                allowedProtectedAccountIDs: Set(protected.map(\.id))
            )
        }.sorted { $0.canonicalAccountID.uuidString < $1.canonicalAccountID.uuidString }
    }

    static func matches(_ duplicate: MonitoredAccount, canonical: MonitoredAccount) -> Bool {
        canonical.providerID == .chatGPT
            && duplicate.providerID == .chatGPT
            && !canonical.isDemo
            && !duplicate.isDemo
            && !canonical.isRemoteOnly
            && !duplicate.isRemoteOnly
            && !canonical.workspaceID.isEmpty
            && canonical.workspaceID == duplicate.workspaceID
    }

    static func protectionRemainsValid(
        _ plan: DirectChatGPTDuplicateMergePlan,
        protectedAccountIDs: Set<UUID>
    ) -> Bool {
        let planAccountIDs = Set([plan.canonicalAccountID] + plan.duplicateAccountIDs)
        return protectedAccountIDs.intersection(planAccountIDs)
            .isSubset(of: plan.allowedProtectedAccountIDs)
    }

    static func mergedAccount(
        canonical: MonitoredAccount,
        duplicate: MonitoredAccount
    ) -> MonitoredAccount {
        var result = canonical
        // Provider-reported names and email are presentation metadata, never merge evidence. Keep
        // the canonical presentation, but retain an explicit user customization if it only exists
        // on the duplicate.
        if result.customDisplayName == nil { result.customDisplayName = duplicate.customDisplayName }
        if result.customSymbolName == nil { result.customSymbolName = duplicate.customSymbolName }
        if result.plan == nil { result.plan = duplicate.plan }
        if (duplicate.planExpiresAt ?? .distantPast) > (result.planExpiresAt ?? .distantPast) {
            result.planExpiresAt = duplicate.planExpiresAt
        }
        if (duplicate.trialExpiresAt ?? .distantPast) > (result.trialExpiresAt ?? .distantPast) {
            result.trialExpiresAt = duplicate.trialExpiresAt
        }
        return result
    }

    static func mergedSettings(
        canonical: AccountMonitorSettings,
        duplicate: AccountMonitorSettings
    ) -> AccountMonitorSettings {
        var result = canonical
        // A merge must not silently opt a user back into notifications or visible metrics.
        result.notifyAboutResets = canonical.notifyAboutResets && duplicate.notifyAboutResets
        result.notifyAtScheduledReset = canonical.notifyAtScheduledReset
            && duplicate.notifyAtScheduledReset
        result.showBankedResets = canonical.showBankedResets && duplicate.showBankedResets
        result.hiddenMetricIDs.formUnion(duplicate.hiddenMetricIDs)
        result.showBankedResetsInLiveActivity = canonical.showBankedResetsInLiveActivity
            && duplicate.showBankedResetsInLiveActivity
        result.hiddenLiveActivityMetricIDs.formUnion(duplicate.hiddenLiveActivityMetricIDs)
        result.pinnedLiveActivityMetricIDs.formUnion(duplicate.pinnedLiveActivityMetricIDs)
        for (metricID, rule) in duplicate.liveActivityQuotaRules
            where result.liveActivityQuotaRules[metricID] == nil {
            result.liveActivityQuotaRules[metricID] = rule
        }
        for (metricID, behavior) in duplicate.missingQuotaHistoryBehaviors
            where result.missingQuotaHistoryBehaviors[metricID] == nil {
            result.missingQuotaHistoryBehaviors[metricID] = behavior
        }
        // Worker consent, opaque references, and the Worker-owned account route remain exactly the
        // canonical tuple. This local merge never deletes or rewrites a Worker source.
        return result
    }

    static func rekeyedSnapshot(
        _ snapshot: UsageSnapshot,
        for canonical: MonitoredAccount
    ) -> UsageSnapshot {
        var result = snapshot
        result.accountID = canonical.id
        result.providerName = canonical.providerDisplayName
        result.accountName = canonical.resolvedDisplayName
        result.accountProviderID = canonical.providerID
        result.accountSymbolName = canonical.customSymbolName
        return result
    }

    private static func accountOrder(_ lhs: MonitoredAccount, _ rhs: MonitoredAccount) -> Bool {
        if lhs.addedAt != rhs.addedAt { return lhs.addedAt < rhs.addedAt }
        return lhs.id.uuidString < rhs.id.uuidString
    }
}

struct ColdLaunchWorkerDeletionNeeds: Equatable, Sendable {
    var credentialRevisionFloor: Int64?
    var deviceUsageRevisionFloor: Int64?

    var isEmpty: Bool {
        credentialRevisionFloor == nil && deviceUsageRevisionFloor == nil
    }
}

enum ColdLaunchAccountCleanupPolicy {
    static func missingCachedAccounts(
        cachedAccounts: [MonitoredAccount],
        syncedAccounts: [MonitoredAccount]
    ) -> [MonitoredAccount] {
        let syncedIDs = Set(syncedAccounts.map(\.id))
        return KeychainStore.orderedAccounts(cachedAccounts.filter {
            !$0.isDemo && !syncedIDs.contains($0.id)
        })
    }

    static func workerDeletionNeeds(
        settings: AccountMonitorSettings?,
        workerURL: String,
        pendingCredentialRevision: Int64?,
        pendingDeviceUsageRevision: Int64?
    ) -> ColdLaunchWorkerDeletionNeeds {
        guard let settings else {
            return .init(
                credentialRevisionFloor: positive(pendingCredentialRevision),
                deviceUsageRevisionFloor: positive(pendingDeviceUsageRevision)
            )
        }
        let credentialRevision = settings.selfHostedServerConsentURL == workerURL
            ? positive(settings.selfHostedServerConsentRevision) : nil
        let deviceRevision = settings.deviceUsageWorkerURL == workerURL
            ? positive(settings.deviceUsageConsentRevision) : nil
        return .init(
            credentialRevisionFloor: maxOptional(
                credentialRevision,
                positive(pendingCredentialRevision)
            ),
            deviceUsageRevisionFloor: maxOptional(
                deviceRevision,
                positive(pendingDeviceUsageRevision)
            )
        )
    }

    static func isPotentialChatGPTMergeSource(
        _ account: MonitoredAccount,
        syncedAccounts: [MonitoredAccount]
    ) -> Bool {
        guard account.providerID == .chatGPT,
              !account.isDemo,
              !account.isRemoteOnly,
              !account.workspaceID.isEmpty else { return false }
        return syncedAccounts.contains {
            $0.id != account.id
                && DirectChatGPTDuplicateMergePolicy.matches(account, canonical: $0)
        }
    }

    static func clearingCredentialSource(
        in settings: AccountMonitorSettings,
        deletionRevision: Int64
    ) -> AccountMonitorSettings {
        var result = settings
        result.monitorOnSelfHostedServer = false
        result.selfHostedServerConsentURL = nil
        result.selfHostedServerConsentRevision = max(
            result.selfHostedServerConsentRevision,
            deletionRevision
        )
        result.remoteWorkerAccountID = nil
        result.workerAccountReference = nil
        return result
    }

    static func clearingDeviceUsageSource(
        in settings: AccountMonitorSettings,
        deletionRevision: Int64
    ) -> AccountMonitorSettings {
        var result = settings
        result.uploadsDeviceUsageToWorker = false
        result.deviceUsageWorkerURL = nil
        result.deviceUsageConsentRevision = max(
            result.deviceUsageConsentRevision,
            deletionRevision
        )
        result.deviceUsageNextSequence = 1
        result.deviceUsageLastUploadedAt = nil
        result.deviceUsageLastError = nil
        return result
    }

    private static func positive(_ value: Int64?) -> Int64? {
        guard let value, value > 0 else { return nil }
        return value
    }

    private static func maxOptional(_ lhs: Int64?, _ rhs: Int64?) -> Int64? {
        switch (lhs, rhs) {
        case let (lhs?, rhs?): max(lhs, rhs)
        case let (lhs?, nil): lhs
        case let (nil, rhs?): rhs
        case (nil, nil): nil
        }
    }
}

enum DeviceUsageEnableCompensation {
    /// Records the cleanup before any network work so a failed or interrupted DELETE remains
    /// retryable after an enable request races with account removal or Worker reconfiguration.
    @MainActor
    @discardableResult
    static func run(
        recordDeletionIntent: () -> Void,
        deleteSource: () async throws -> Void,
        clearDeletionIntent: () -> Void
    ) async -> Bool {
        recordDeletionIntent()
        do {
            try await deleteSource()
            clearDeletionIntent()
            return true
        } catch {
            return false
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
    private(set) var accountLinkProgress = AccountLinkProgress.idle
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
    private let openRouterProvider = OpenRouterProvider()
    private let fireworksAIProvider = FireworksAIProvider()
    private let deepSeekProvider = DeepSeekProvider()
    private let poeProvider = PoeProvider()
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
    private let pendingDeviceUsageDeletionsKey = "pendingDeviceUsageDeletions.v1"
    private let pendingDeviceUsageDeletionURLKey = "pendingDeviceUsageDeletionURL.v1"
    private let serverConsentHighWaterKey = "serverConsentHighWater.v1"
    private let appliedAccountMergeAliasesKey = "appliedAccountMergeAliases.v1"
    private let liveActivityStartedAtKey = "globalLiveActivityStartedAt.v1"
    private static let accountKeychainMigrationKey = "accounts.iCloudKeychainMigrated.v1"
    private let historyStore = UsageHistoryStore()
    private let serverAccountOperationGate = ServerAccountOperationGate()
    private let serverRegistrationOperationGate = ServerRegistrationOperationGate()
    private var hasStarted = false
    private var isStarting = false
    private var accountKeychainSyncTask: Task<Void, Never>?
    /// The Worker link transition is intentionally serialized with account refreshes. Without
    /// this, a just-completed provider sign-in can race the APNs/device registration and surface
    /// the misleading “register this device” error before the registration has been persisted.
    private var pushServerTransitionTask: Task<Void, Never>?
    private var liveActivityStartedAt: Date?
    private var pendingPushServerEnrollment: PushServerEnrollment?
    private var pendingPushServerCleanupSettings: PushServerSettings?
    private var pendingServerAccountDeletions: [UUID: Int64] = [:]
    private var pendingServerAccountDeletionURL: String?
    private var pendingDeviceUsageDeletions: [UUID: Int64] = [:]
    private var pendingDeviceUsageDeletionURL: String?
    private var serverConsentHighWater: [UUID: Int64] = [:]
    private var appliedAccountMergeAliases: [UUID: UUID] = [:]
    private static let maximumServerConsentRevision = ServerConsentRevisionPolicy.maximum
    private static let globalActivityID = UUID(uuidString: "00000000-0000-4000-8000-000000000001")!

    var canAccessRemoteWorkerAccounts: Bool {
        PushServerClient.hasStoredRegistration(settings: pushServerSettings)
    }

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
            if saved.mode == .disabled {
                pushServerStatus = .disabled
            } else {
                pushServerStatus = PushServerClient.hasStoredRegistration(settings: saved)
                    ? .registered : .waitingForDeviceToken
            }
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
        if let data = UserDefaults.standard.data(forKey: pendingDeviceUsageDeletionsKey),
           let saved = try? JSONDecoder().decode([UUID: Int64].self, from: data) {
            pendingDeviceUsageDeletions = saved
        }
        pendingDeviceUsageDeletionURL = UserDefaults.standard.string(
            forKey: pendingDeviceUsageDeletionURLKey
        )
        if let data = UserDefaults.standard.data(forKey: serverConsentHighWaterKey),
           let saved = try? JSONDecoder().decode([UUID: Int64].self, from: data) {
            serverConsentHighWater = saved
        }
        if let data = UserDefaults.standard.data(forKey: appliedAccountMergeAliasesKey),
           let saved = try? JSONDecoder().decode([UUID: UUID].self, from: data) {
            appliedAccountMergeAliases = saved
        }
        if let pendingPushServerCleanupSettings {
            let host = (try? pendingPushServerCleanupSettings.resolvedServerURL())?.host
                ?? "the previous Worker"
            pushServerStatus = .failed("Couldn’t confirm removal from \(host). Retry cleanup.")
        }
        normalizeServerConsentRevisions()
        reconcilePendingServerAccountDeletionConsents()
        // Do not overwrite the cache before synchronized removals have been compared with their
        // retained settings. That comparison synthesizes durable Worker DELETE intents during
        // the first Keychain synchronization, including when the device is offline.
        cacheAccounts()
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
        guard !hasStarted, !isStarting else { return }
        isStarting = true
        defer { isStarting = false }
        // Canonicalize synchronized ChatGPT duplicates before launch refresh captures the account
        // list. This also serializes the scene-phase sync that may start at the same time.
        await synchronizeAccountsFromICloudKeychain()
        hasStarted = true
        if let cleanup = pendingPushServerCleanupSettings {
            let target = preparePushServerCleanupTarget(cleanup)
            await transitionPushServer(from: cleanup, to: target)
        } else {
            RemotePushCoordinator.shared.requestRegistrationIfNeeded()
            await retryPendingDeviceUsageDeletions(settings: pushServerSettings)
        }
        var pendingNotifications: [UsageNotificationEvent] = []
        do {
            try await historyStore.setRetentionInterval(
                pushServerSettings.historyRetention.timeInterval
            )
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
        if let accountKeychainSyncTask {
            await accountKeychainSyncTask.value
            return
        }
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.performAccountKeychainSynchronization()
        }
        accountKeychainSyncTask = task
        await task.value
        accountKeychainSyncTask = nil
    }

    private func performAccountKeychainSynchronization() async {
        // Scene activation and iOS background launch can enter this path before start(). Apply the
        // configured retention first so an identity-only re-key can never fall back to 35 days.
        do {
            try await historyStore.setRetentionInterval(
                pushServerSettings.historyRetention.timeInterval
            )
            historyStorageError = nil
        } catch {
            historyStorageError = error.localizedDescription
            return
        }
        guard UserDefaults.standard.bool(forKey: Self.accountKeychainMigrationKey),
              let syncedAccounts = try? KeychainStore.loadAccounts() else { return }
        let cachedAccounts = accounts
        var updatedAccounts = Self.mergeSyncedAccounts(syncedAccounts, localAccounts: accounts)
        let missingCachedAccounts = ColdLaunchAccountCleanupPolicy.missingCachedAccounts(
            cachedAccounts: cachedAccounts,
            syncedAccounts: syncedAccounts
        )
        let missingCachedAccountIDs = Set(missingCachedAccounts.map(\.id))
        let currentPushSettings = pushServerSettings
        let currentServerURL = (try? currentPushSettings.resolvedServerURL())?.absoluteString
        var serverDeletions: [(accountID: UUID, consentRevision: Int64)] = []
        var deviceUsageDeletions: [(accountID: UUID, consentRevision: Int64)] = []

        // iCloud can deliver the losing row's deletion before its merge alias. Retain that exact
        // ChatGPT row locally for this pass so a later alias can migrate UUID-keyed state. Other
        // synchronized removals are dropped only after their Worker source cleanup is journaled.
        for account in missingCachedAccounts where
            ColdLaunchAccountCleanupPolicy.isPotentialChatGPTMergeSource(
                account,
                syncedAccounts: syncedAccounts
            ) {
            if !updatedAccounts.contains(where: { $0.id == account.id }) {
                updatedAccounts.append(account)
            }
        }
        updatedAccounts = KeychainStore.orderedAccounts(updatedAccounts)

        if let currentServerURL {
            for account in missingCachedAccounts {
                let pendingCredential = pendingServerAccountDeletionURL == currentServerURL
                    ? pendingServerAccountDeletions[account.id] : nil
                let pendingUsage = pendingDeviceUsageDeletionURL == currentServerURL
                    ? pendingDeviceUsageDeletions[account.id] : nil
                let needs = ColdLaunchAccountCleanupPolicy.workerDeletionNeeds(
                    settings: monitorSettings[account.id],
                    workerURL: currentServerURL,
                    pendingCredentialRevision: pendingCredential,
                    pendingDeviceUsageRevision: pendingUsage
                )
                if let revisionFloor = needs.credentialRevisionFloor {
                    let revision = nextServerConsentRevision(
                        for: account.id,
                        after: revisionFloor
                    )
                    recordServerAccountDeletionIntent(
                        accountID: account.id,
                        consentRevision: revision,
                        serverSettings: currentPushSettings
                    )
                    serverDeletions.append((account.id, revision))
                }
                if let revisionFloor = needs.deviceUsageRevisionFloor {
                    let revision = nextDeviceUsageConsentRevision(after: revisionFloor)
                    if revision > revisionFloor {
                        recordDeviceUsageDeletionIntent(
                            accountID: account.id,
                            consentRevision: revision,
                            serverSettings: currentPushSettings
                        )
                        deviceUsageDeletions.append((account.id, revision))
                    }
                }
            }
        }
        var mergedDuplicateIDs = Set<UUID>()

        // A synchronized alias survives deletion of its losing account row. Apply it first so a
        // device that received the deletion before seeing both records can still migrate all of
        // its UUID-keyed local state.
        let aliases = (try? KeychainStore.loadAccountMergeAliases()) ?? []
        for alias in aliases {
            guard let canonical = updatedAccounts.first(where: {
                $0.id == alias.canonicalAccountID
                    && $0.providerID == .chatGPT
                    && !$0.isDemo
                    && !$0.isRemoteOnly
                    && $0.workspaceID == alias.workspaceID
            }) else { continue }
            if let source = updatedAccounts.first(where: { $0.id == alias.sourceAccountID }) {
                guard DirectChatGPTDuplicateMergePolicy.matches(source, canonical: canonical),
                      await mergeDirectChatGPTDuplicates(
                        .init(
                            canonicalAccountID: canonical.id,
                            duplicateAccountIDs: [source.id],
                            allowedProtectedAccountIDs: activeWorkerProtection(for: canonical)
                                ? [canonical.id] : []
                        ),
                        in: &updatedAccounts
                      ) else { continue }
            } else {
                guard appliedAccountMergeAliases[alias.sourceAccountID]
                        != alias.canonicalAccountID,
                      await reconcileDirectChatGPTMergeAlias(
                        alias,
                        canonical: canonical,
                        in: &updatedAccounts
                      ) else { continue }
            }
            mergedDuplicateIDs.insert(alias.sourceAccountID)
        }

        let duplicateMergePlans = directChatGPTDuplicateMergePlans(in: updatedAccounts)
        for plan in duplicateMergePlans {
            guard await mergeDirectChatGPTDuplicates(plan, in: &updatedAccounts) else { continue }
            mergedDuplicateIDs.formUnion(plan.duplicateAccountIDs)
        }
        let hasColdLaunchCleanup = !serverDeletions.isEmpty || !deviceUsageDeletions.isEmpty
        guard updatedAccounts != accounts || !mergedDuplicateIDs.isEmpty || hasColdLaunchCleanup
        else { return }

        let previousByID = Dictionary(uniqueKeysWithValues: accounts.map { ($0.id, $0) })
        let updatedIDs = Set(updatedAccounts.map(\.id))
        let removedIDs = Set(previousByID.keys).subtracting(updatedIDs)
            .subtracting(mergedDuplicateIDs)
        let accountsToRefresh = updatedAccounts.filter { account in
            !account.isDemo && previousByID[account.id] != account
        }

        if currentServerURL != nil {
            for id in removedIDs {
                // Missing cached rows were journaled above while their complete retained settings
                // were still available. Do not advance the same tombstone a second time.
                if missingCachedAccountIDs.contains(id) { continue }
                guard let removedAccount = previousByID[id] else { continue }
                let accountSettings = settings(for: removedAccount)
                let pendingRevision = pendingServerAccountDeletionURL == currentServerURL
                    ? pendingServerAccountDeletions[id] : nil
                if hasServerConsent(accountSettings, account: removedAccount)
                    || pendingRevision != nil {
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
                    if !serverDeletions.contains(where: { $0.accountID == id }) {
                        serverDeletions.append((id, revision))
                    }
                }
                let pendingUsageRevision = pendingDeviceUsageDeletionURL == currentServerURL
                    ? pendingDeviceUsageDeletions[id] : nil
                if (accountSettings.uploadsDeviceUsageToWorker
                        && accountSettings.deviceUsageWorkerURL == currentServerURL)
                    || pendingUsageRevision != nil {
                    let revision = nextDeviceUsageConsentRevision(
                        after: max(
                            accountSettings.deviceUsageConsentRevision,
                            pendingUsageRevision ?? 0
                        )
                    )
                    recordDeviceUsageDeletionIntent(
                        accountID: id,
                        consentRevision: revision,
                        serverSettings: currentPushSettings
                    )
                    if !deviceUsageDeletions.contains(where: { $0.accountID == id }) {
                        deviceUsageDeletions.append((id, revision))
                    }
                }
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

        var completedColdLaunchCleanup = false
        for deletion in deviceUsageDeletions {
            do {
                try await deleteDeviceUsageSource(
                    settings: currentPushSettings,
                    accountID: deletion.accountID,
                    consentRevision: deletion.consentRevision
                )
                clearDeviceUsageDeletionIntent(
                    accountID: deletion.accountID,
                    through: deletion.consentRevision,
                    serverSettings: currentPushSettings
                )
                if missingCachedAccountIDs.contains(deletion.accountID),
                   let retainedSettings = monitorSettings[deletion.accountID] {
                    monitorSettings[deletion.accountID] = ColdLaunchAccountCleanupPolicy
                        .clearingDeviceUsageSource(
                            in: retainedSettings,
                            deletionRevision: deletion.consentRevision
                        )
                    persistMonitorSettings()
                    completedColdLaunchCleanup = true
                }
            } catch {
                guard pendingDeviceUsageDeletionURL == currentServerURL else { continue }
                errorMessage = "The account was removed from this device, but its device-usage copy is still awaiting removal from the Worker."
            }
        }

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
                if missingCachedAccountIDs.contains(deletion.accountID),
                   let retainedSettings = monitorSettings[deletion.accountID] {
                    monitorSettings[deletion.accountID] = ColdLaunchAccountCleanupPolicy
                        .clearingCredentialSource(
                            in: retainedSettings,
                            deletionRevision: deletion.consentRevision
                        )
                    persistMonitorSettings()
                    completedColdLaunchCleanup = true
                }
            } catch {
                guard pendingServerAccountDeletionURL == currentServerURL else { continue }
                errorMessage = "The account was removed from this device, but its Worker copy is still awaiting deletion: \(error.localizedDescription)"
            }
        }

        if completedColdLaunchCleanup {
            // Re-evaluate aliases and zero-protected exact-workspace plans immediately. The
            // recursive pass has no cleanup work for successfully tombstoned sources, while a
            // source whose DELETE failed remains protected by its durable pending intent.
            await performAccountKeychainSynchronization()
            return
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

#if os(macOS)
    func localCLICredentialCapability(
        for source: LocalCLICredentialSource
    ) -> LocalCLICredentialCapability {
        LocalCLICredentialRuntime.capability(for: source)
    }

    @discardableResult
    func importLocalCLICredential(from source: LocalCLICredentialSource) async -> Bool {
        guard !isLinking else { return false }
        isLinking = true
        errorMessage = nil
        defer { isLinking = false }
        do {
            let identity = try await localCLIIdentity(
                source: source,
                data: LocalCLICredentialRuntime.load(source)
            )
            let existingAccount = accounts.first {
                $0.providerID == source.providerID && $0.workspaceID == identity.workspaceID
            }
            let requiresWorkerReplacement = LocalCLICredentialImportPolicy
                .requiresWorkerCredentialReplacement(
                    deduplicatedExistingAccount: existingAccount != nil,
                    existingAccountUsesWorkerMonitoring: existingAccount.map {
                        isServerMonitoringEnabled(for: $0)
                    } ?? false
                )
            let account = try saveLinkedAccount(identity, providerID: source.providerID)
            let refreshed = await refresh(account, source: .accountLink)
            return requiresWorkerReplacement ? refreshed : true
        } catch is CancellationError {
            return false
        } catch let error as LocalCLICredentialImportError {
            errorMessage = error.localizedDescription
            return false
        } catch {
            // Never surface an underlying decoder, file, Keychain, or provider payload.
            errorMessage = LocalCLICredentialImportError.invalidCredential(source)
                .localizedDescription
            return false
        }
    }

    private func localCLIIdentity(
        source: LocalCLICredentialSource,
        data: Data
    ) async throws -> LinkedIdentity {
        switch source {
        case .codex:
            let parsed = try CodexCLICredentialParser.parse(data)
            do {
                let identity = try provider.linkedIdentity(
                    accessToken: parsed.credentials.accessToken,
                    refreshToken: parsed.credentials.refreshToken,
                    idToken: parsed.credentials.idToken
                )
                guard identity.workspaceID == parsed.accountID else {
                    throw LocalCLICredentialImportError.identityUnavailable(source)
                }
                return identity
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                throw LocalCLICredentialImportError.identityUnavailable(source)
            }
        case .claudeCode:
            return try await claudeCLIIdentity(
                from: ClaudeCodeCredentialParser.parse(data),
                source: source
            )
        }
    }

    private func claudeCLIIdentity(
        from parsed: ParsedClaudeCodeCredential,
        source: LocalCLICredentialSource
    ) async throws -> LinkedIdentity {
        do {
            var request = URLRequest(
                url: URL(string: "https://api.anthropic.com/api/oauth/profile")!,
                cachePolicy: .reloadIgnoringLocalCacheData,
                timeoutInterval: 10
            )
            request.setValue(
                "Bearer \(parsed.credentials.accessToken)",
                forHTTPHeaderField: "Authorization"
            )
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
            let (data, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard (200..<300).contains(status),
                  let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let account = root["account"] as? [String: Any],
                  let workspaceID = nonEmptyLocalCLIString(account["uuid"] as? String) else {
                throw LocalCLICredentialImportError.identityUnavailable(source)
            }
            let details = try ClaudeProvider.parseAccountDetails(profileData: data)
            return LinkedIdentity(
                workspaceID: workspaceID,
                displayName: details.displayName ?? details.email ?? "Claude account",
                profileName: details.profileName,
                email: details.email,
                plan: details.plan ?? parsed.planHint,
                planExpiresAt: details.planExpiresAt,
                trialExpiresAt: details.trialExpiresAt,
                credentials: parsed.credentials
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw LocalCLICredentialImportError.identityUnavailable(source)
        }
    }

    private func nonEmptyLocalCLIString(_ raw: String?) -> String? {
        let value = raw?.trimmingCharacters(in: .whitespacesAndNewlines)
        return value?.isEmpty == false ? value : nil
    }
#endif

    func availableRemoteWorkerAccounts() async throws -> [RemoteWorkerAccountCandidate] {
        let candidates = try await PushServerClient.remoteAccounts(settings: pushServerSettings)
        guard let serverURL = (try? pushServerSettings.resolvedServerURL())?.absoluteString else {
            throw PushServerError.accountMonitoringUnavailable
        }
        return candidates.filter { candidate in
            !RemoteWorkerAccountMatcher.isAlreadyAttached(
                candidate,
                accounts: accounts,
                serverURL: serverURL,
                settingsForAccount: settings(for:)
            )
        }
    }

    func remoteWorkerAccountsMissingLocally() async throws -> [RemoteWorkerAccountCandidate] {
        let candidates = try await availableRemoteWorkerAccounts()
        return candidates.filter { candidate in
            !accounts.contains { account in
                !account.isRemoteOnly
                    && RemoteWorkerAccountMatcher.matches(
                        candidate,
                        account: account,
                        settings: settings(for: account)
                    )
            }
        }
    }

    @discardableResult
    func reconcileRemoteWorkerAccounts() async throws -> [MonitoredAccount] {
        let candidates = try await PushServerClient.remoteAccounts(settings: pushServerSettings)
        guard let serverURL = (try? pushServerSettings.resolvedServerURL())?.absoluteString else {
            throw PushServerError.accountMonitoringUnavailable
        }
        let matchingCandidates = candidates.filter { candidate in
            !RemoteWorkerAccountMatcher.isAlreadyAttached(
                candidate,
                accounts: accounts,
                serverURL: serverURL,
                settingsForAccount: settings(for:)
            ) && accounts.contains { account in
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
        var importFailure: Error?
        for candidate in candidates {
            let matchingLocalAccount = accounts.first { account in
                !account.isRemoteOnly
                    && RemoteWorkerAccountMatcher.matches(
                        candidate,
                        account: account,
                        settings: settings(for: account)
                    )
            }
            let alreadyImported = RemoteWorkerAccountMatcher.isAlreadyAttached(
                candidate,
                accounts: accounts,
                serverURL: serverURL.absoluteString,
                settingsForAccount: settings(for:)
            )
            guard !alreadyImported else { continue }
            let localAccountID = matchingLocalAccount?.id ?? UUID()
            let importResult: RemoteWorkerAccountImportResult
            do {
                importResult = try await PushServerClient.importRemoteAccount(
                    settings: pushServerSettings,
                    candidate: candidate,
                    localAccountID: localAccountID
                )
            } catch {
                importFailure = error
                break
            }
            let remoteAccount = importResult.account
            let consentRevision = importResult.consentRevision
            let account: MonitoredAccount
            if let matchingLocalAccount {
                account = matchingLocalAccount
                var accountSettings = settings(for: matchingLocalAccount)
                accountSettings.monitorOnSelfHostedServer = true
                accountSettings.selfHostedServerConsentURL = serverURL.absoluteString
                accountSettings.selfHostedServerConsentRevision = consentRevision
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
                    selfHostedServerConsentRevision: consentRevision,
                    remoteWorkerAccountID: remoteAccount.remoteAccountID,
                    workerAccountReference: remoteAccount.workerAccountReference
                )
            }
            recordServerConsentHighWater(
                accountID: localAccountID,
                revision: consentRevision
            )
            imported.append(account)
            // Each successful Worker attachment must survive a later import or history failure.
            persistAccounts()
            persistMonitorSettings()
        }
        guard !imported.isEmpty else {
            if let importFailure { throw importFailure }
            return []
        }
        var historyFailures: [String] = []
        for account in imported {
            let succeeded = await fetchRetainedWorkerHistory(for: account)
            if !succeeded || historyStorageError != nil {
                historyFailures.append(
                    errorMessage ?? historyStorageError ?? "The Worker history request failed."
                )
            }
        }
        publishSnapshots()
        await reconcileScheduledResetNotifications()
        await updateLiveActivity()
        await reconcileLiveActivity()
        if let importFailure {
            errorMessage = nil
            throw RemoteWorkerImportError.accountImportPartiallySucceeded(
                importedCount: imported.count,
                reason: importFailure.localizedDescription,
                retainedHistoryReason: historyFailures.first
            )
        }
        if !historyFailures.isEmpty {
            errorMessage = nil
            throw RemoteWorkerImportError.retainedHistoryDownloadFailed(
                importedCount: imported.count,
                reason: historyFailures.first
            )
        }
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
        isLinking = true
        accountLinkProgress = .authorizing
        errorMessage = nil
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
                 .antigravity, .compatibleAPI, .openAIAPI, .anthropicAPI, .newAPI,
                 .openRouter, .fireworksAI, .deepSeek, .poe:
                throw ProviderError.server(400, "This provider does not use device linking.")
            }
        } catch {
            errorMessage = error.localizedDescription
            clearPendingLinks()
            isLinking = false
            accountLinkProgress = .idle
        }
    }

    @discardableResult
    func completeDeviceLink(replacing relinkingAccount: MonitoredAccount? = nil) async -> Bool {
        guard let deviceLink else { return false }
        isLinking = true
        accountLinkProgress = .authorizing
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
                 .antigravity, .compatibleAPI, .openAIAPI, .anthropicAPI, .newAPI,
                 .openRouter, .fireworksAI, .deepSeek, .poe:
                throw ProviderError.invalidResponse
            }
            if let relinkingAccount, relinkingAccount.isRemoteOnly {
                clearPendingLinks()
                accountLinkProgress = .verifyingWorker(
                    accountID: relinkingAccount.id,
                    canRetryWithoutAuthorization: false
                )
                try await replaceRemoteWorkerCredential(
                    for: relinkingAccount,
                    identity: identity,
                    providerID: deviceLink.providerID
                )
                isLinking = false
                accountLinkProgress = .idle
                return true
            }
            let account = try saveLinkedAccount(identity, providerID: deviceLink.providerID,
                                                replacing: relinkingAccount)
            await clearHistoryIfIdentityChanged(from: relinkingAccount, to: account)
            let requiresWorkerReplacement = isServerMonitoringEnabled(for: account)
            if requiresWorkerReplacement {
                clearPendingLinks()
                accountLinkProgress = .verifyingWorker(
                    accountID: account.id,
                    canRetryWithoutAuthorization: true
                )
            }
            let succeeded = await finishAccountLinkRefresh(account)
            isLinking = false
            if requiresWorkerReplacement && !succeeded {
                accountLinkProgress = .workerVerificationFailed(
                    accountID: account.id,
                    canRetryWithoutAuthorization: true
                )
                return false
            }
            clearPendingLinks()
            accountLinkProgress = .idle
            return succeeded
        } catch is CancellationError {
            // Preserve the still-valid device code so the UI can resume polling or explicitly
            // start over. Closing the linking view calls cancelLink(), which clears it.
            isLinking = false
            return false
        } catch {
            if case let .verifyingWorker(accountID, canRetry) = accountLinkProgress {
                let failure = AccountRefreshFailure(error: error)
                errorMessage = failure.message
                refreshFailures[accountID] = failure
                accountLinkProgress = .workerVerificationFailed(
                    accountID: accountID,
                    canRetryWithoutAuthorization: canRetry
                )
            } else {
                errorMessage = error.localizedDescription
                clearPendingLinks()
                accountLinkProgress = .idle
            }
            isLinking = false
            return false
        }
    }

    @discardableResult
    func retryWorkerCredentialReplacement(for accountID: UUID) async -> Bool {
        guard let account = accounts.first(where: { $0.id == accountID }),
              !account.isRemoteOnly,
              isServerMonitoringEnabled(for: account),
              (try? KeychainStore.load(for: accountID)) != nil else {
            errorMessage = "The replacement credential is no longer available on this Mac. Sign in again to continue."
            accountLinkProgress = .workerVerificationFailed(
                accountID: accountID,
                canRetryWithoutAuthorization: false
            )
            return false
        }
        isLinking = true
        errorMessage = nil
        accountLinkProgress = .verifyingWorker(
            accountID: accountID,
            canRetryWithoutAuthorization: true
        )
        let succeeded = await uploadServerAccount(
            account,
            presentErrors: true,
            replacingRemoteCredential: true
        )
        isLinking = false
        accountLinkProgress = succeeded
            ? .idle
            : .workerVerificationFailed(
                accountID: accountID,
                canRetryWithoutAuthorization: true
            )
        return succeeded
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
        // Keep the Worker's existing account scope. Stable-identity providers verify the new
        // credential against the prior opaque account reference; providers without a stable
        // identity can rotate keys without turning a key fingerprint into a workspace change.
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
        guard await consumeServerResult(
            result,
            for: account,
            consentRevision: 1,
            deliverNotifications: true,
            presentErrors: true
        ) else {
            throw PushServerError.accountConsentChanged
        }
        guard WorkerCredentialReplacementPolicy.isConfirmed(
            sessionStatus: result.sessionStatus
        ) else {
            throw PushServerError.credentialReplacementUnconfirmed
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
            if let relinkingAccount, relinkingAccount.isRemoteOnly {
                try await replaceRemoteWorkerCredential(
                    for: relinkingAccount,
                    identity: identity,
                    providerID: .claude
                )
                self.claudeLink = nil; isLinking = false
                return true
            }
            let account = try saveLinkedAccount(identity, providerID: .claude, replacing: relinkingAccount)
            await clearHistoryIfIdentityChanged(from: relinkingAccount, to: account)
            self.claudeLink = nil; isLinking = false
            return await finishAccountLinkRefresh(account)
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
            if let relinkingAccount, relinkingAccount.isRemoteOnly {
                try await replaceRemoteWorkerCredential(
                    for: relinkingAccount,
                    identity: identity,
                    providerID: .zai
                )
                isLinking = false
                return true
            }
            let account = try saveLinkedAccount(identity, providerID: .zai, replacing: relinkingAccount)
            await clearHistoryIfIdentityChanged(from: relinkingAccount, to: account)
            isLinking = false
            return await finishAccountLinkRefresh(account)
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
            if let relinkingAccount, relinkingAccount.isRemoteOnly {
                try await replaceRemoteWorkerCredential(
                    for: relinkingAccount,
                    identity: identity,
                    providerID: .miniMax
                )
                isLinking = false
                return true
            }
            let account = try saveLinkedAccount(identity, providerID: .miniMax, replacing: relinkingAccount)
            await clearHistoryIfIdentityChanged(from: relinkingAccount, to: account)
            isLinking = false
            return await finishAccountLinkRefresh(account)
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
            return await finishAccountLinkRefresh(account)
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

    @discardableResult
    func addOpenRouterAccount(
        apiKey: String,
        replacing relinkingAccount: MonitoredAccount? = nil
    ) async -> Bool {
        await addLinkedIdentity(providerID: .openRouter, replacing: relinkingAccount) {
            try await self.openRouterProvider.link(apiKey: apiKey)
        }
    }

    @discardableResult
    func addFireworksAIAccount(
        apiKey: String,
        accountID: String?,
        replacing relinkingAccount: MonitoredAccount? = nil
    ) async -> Bool {
        await addLinkedIdentity(providerID: .fireworksAI, replacing: relinkingAccount) {
            try await self.fireworksAIProvider.link(apiKey: apiKey, accountID: accountID)
        }
    }

    @discardableResult
    func addDeepSeekAccount(
        apiKey: String,
        replacing relinkingAccount: MonitoredAccount? = nil
    ) async -> Bool {
        await addLinkedIdentity(providerID: .deepSeek, replacing: relinkingAccount) {
            try await self.deepSeekProvider.link(apiKey: apiKey)
        }
    }

    @discardableResult
    func addPoeAccount(
        apiKey: String,
        replacing relinkingAccount: MonitoredAccount? = nil
    ) async -> Bool {
        await addLinkedIdentity(providerID: .poe, replacing: relinkingAccount) {
            try await self.poeProvider.link(apiKey: apiKey)
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
            if let relinkingAccount, relinkingAccount.isRemoteOnly {
                try await replaceRemoteWorkerCredential(
                    for: relinkingAccount,
                    identity: identity,
                    providerID: providerID
                )
                isLinking = false
                return true
            }
            let account = try saveLinkedAccount(
                identity,
                providerID: providerID,
                replacing: relinkingAccount
            )
            await clearHistoryIfIdentityChanged(from: relinkingAccount, to: account)
            isLinking = false
            return await finishAccountLinkRefresh(account)
        } catch {
            errorMessage = error.localizedDescription
            isLinking = false
            return false
        }
    }

    private func finishAccountLinkRefresh(_ account: MonitoredAccount) async -> Bool {
        let requiresWorkerReplacement = isServerMonitoringEnabled(for: account)
        if requiresWorkerReplacement {
            await waitForPushServerTransition()
            // A link can finish before APNs delivers its device token. Treat that as a pending
            // Worker registration rather than as a failed provider sign-in; performPushRegistration
            // will upload the opted-in account as soon as the device registration is accepted.
            if !PushServerClient.hasStoredRegistration(settings: pushServerSettings),
               pendingPushServerEnrollment != nil {
                RemotePushCoordinator.shared.requestRegistrationIfNeeded()
                return true
            }
        }
        let refreshed = await refresh(account, source: .accountLink)
        return requiresWorkerReplacement ? refreshed : true
    }

    func cancelLink() {
        clearPendingLinks()
        isLinking = false
        accountLinkProgress = .idle
    }

    @discardableResult
    func refreshAll(source: UsageRefreshSource = .manual) async -> Bool {
        guard !isRefreshing else { return false }
        await waitForPushServerTransition()
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
            remoteOnly: account.isRemoteOnly,
            hasLocalCredentials: hasLocalCredentials(for: account),
            workerIsCredentialAuthority: account.usesWorkerAsCredentialAuthority
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
                    presentErrors: source.presentsFetchFailureAlerts,
                    replacingRemoteCredential: true
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
            case .openRouter:
                snapshot = try await openRouterProvider.fetchUsage(
                    account: effectiveAccount,
                    credentials: credentials
                )
            case .fireworksAI:
                snapshot = try await fireworksAIProvider.fetchUsage(
                    account: effectiveAccount,
                    credentials: credentials
                )
            case .deepSeek:
                snapshot = try await deepSeekProvider.fetchUsage(
                    account: effectiveAccount,
                    credentials: credentials
                )
            case .poe:
                snapshot = try await poeProvider.fetchUsage(
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
            var workerCredentialReplacementSucceeded = true
            if source == .accountLink, isServerMonitoringEnabled(for: account) {
                workerCredentialReplacementSucceeded = await uploadServerAccount(
                    effectiveAccount,
                    presentErrors: source.presentsFetchFailureAlerts,
                    replacingRemoteCredential: true
                )
            }
            _ = await uploadDeviceUsageAfterLocalRefresh(
                snapshot,
                for: effectiveAccount
            )
            if publishChanges {
                publishSnapshots()
                await reconcileScheduledResetNotifications()
                await updateLiveActivity()
                await reconcileLiveActivity()
            }
            return workerCredentialReplacementSucceeded
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
            // A Worker-monitored account keeps its existing logical scope while a replacement
            // credential is verified. This is essential for rotated keys whose providers expose
            // no stable account identifier.
            if !isServerMonitoringEnabled(for: account) {
                account.workspaceID = identity.workspaceID
            }
            account.mergeProviderDetails(identity.accountDetails)
            accounts[index] = account
            if AccountRelinkFailurePolicy.clearsFailureAfterLocalCredentialSave(
                serverMonitoringEnabled: isServerMonitoringEnabled(for: account)
            ) {
                refreshFailures.removeValue(forKey: account.id)
            }
            persistAccounts()
            return account
        }

        if let index = accounts.firstIndex(where: {
            $0.providerID == providerID && $0.workspaceID == identity.workspaceID
        }) {
            var account = accounts[index]
            try KeychainStore.save(identity.credentials, for: account.id)
            account.mergeProviderDetails(identity.accountDetails)
            accounts[index] = account
            if AccountRelinkFailurePolicy.clearsFailureAfterLocalCredentialSave(
                serverMonitoringEnabled: isServerMonitoringEnabled(for: account)
            ) {
                refreshFailures.removeValue(forKey: account.id)
            }
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
        let pendingUsageRevision = pendingDeviceUsageDeletionURL == serverURL
            ? pendingDeviceUsageDeletions[account.id] : nil
        let shouldDeleteDeviceUsage = serverURL != nil
            && ((accountSettings.uploadsDeviceUsageToWorker
                    && accountSettings.deviceUsageWorkerURL == serverURL)
                || pendingUsageRevision != nil)
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
        let deviceUsageDeletionRevision = nextDeviceUsageConsentRevision(
            after: max(
                accountSettings.deviceUsageConsentRevision,
                pendingUsageRevision ?? 0
            )
        )
        if shouldDeleteDeviceUsage {
            recordDeviceUsageDeletionIntent(
                accountID: account.id,
                consentRevision: deviceUsageDeletionRevision,
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
            if shouldDeleteDeviceUsage {
                do {
                    try await deleteDeviceUsageSource(
                        settings: currentPushSettings,
                        accountID: account.id,
                        consentRevision: deviceUsageDeletionRevision
                    )
                    clearDeviceUsageDeletionIntent(
                        accountID: account.id,
                        through: deviceUsageDeletionRevision,
                        serverSettings: currentPushSettings
                    )
                } catch {
                    let currentURL = (try? pushServerSettings.resolvedServerURL())?.absoluteString
                    if serverURL == currentURL {
                        let message = "The account was removed locally, but its device-usage copy is still awaiting removal from the Worker."
                        errorMessage = message
                        pushServerStatus = .failed(message)
                    }
                }
            }
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
            await updateDeviceUsageSourcePolicy(for: account)
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

    func hasLocalCredentials(for account: MonitoredAccount) -> Bool {
        (try? KeychainStore.load(for: account.id)) != nil
    }

    func isDeviceUsageUploadEnabled(for account: MonitoredAccount) -> Bool {
        guard let serverURL = try? pushServerSettings.resolvedServerURL() else { return false }
        let accountSettings = settings(for: account)
        return accountSettings.uploadsDeviceUsageToWorker
            && accountSettings.deviceUsageWorkerURL == serverURL.absoluteString
            && accountSettings.deviceUsageConsentRevision > 0
    }

    func canConfigureDeviceUsageUpload(for account: MonitoredAccount) -> Bool {
        guard !account.isDemo,
              !account.isRemoteOnly,
              !account.usesWorkerAsCredentialAuthority,
              hasLocalCredentials(for: account),
              pendingPushServerCleanupSettings == nil,
              pendingDeviceUsageDeletions[account.id] == nil,
              PushServerClient.hasStoredRegistration(settings: pushServerSettings) else {
            return false
        }
        let accountSettings = settings(for: account)
        return accountSettings.remoteWorkerAccountID == nil
    }

    @discardableResult
    func enableDeviceUsageUpload(for account: MonitoredAccount) async -> Bool {
        errorMessage = nil
        guard let currentAccount = accounts.first(where: { $0.id == account.id }),
              canConfigureDeviceUsageUpload(for: currentAccount),
              let serverURL = try? pushServerSettings.resolvedServerURL() else {
            errorMessage = "This account needs a local Keychain sign-in and a paired Worker before usage can be uploaded."
            return false
        }
        let previous = settings(for: currentAccount)
        let revision = nextDeviceUsageConsentRevision(after: previous.deviceUsageConsentRevision)
        guard revision > previous.deviceUsageConsentRevision else {
            errorMessage = "Usage sharing cannot be enabled because its revision limit was reached."
            return false
        }
        let serverSettings = pushServerSettings
        await serverAccountOperationGate.acquire(accountID: currentAccount.id)
        do {
            let response = try await PushServerClient.enableDeviceUsageUploads(
                settings: serverSettings,
                account: currentAccount,
                consentRevision: revision,
                refreshInterval: refreshSettings.inAppInterval
            )
            await serverAccountOperationGate.release(accountID: currentAccount.id)
            guard accounts.contains(where: { $0.id == currentAccount.id }),
                  pushServerSettings == serverSettings,
                  (try? pushServerSettings.resolvedServerURL()) == serverURL,
                  hasLocalCredentials(for: currentAccount) else {
                // The explicit local prerequisite changed during the request. Revoke the source
                // instead of leaving an opt-in that this device can no longer honor. Persist the
                // intent before DELETE so a network failure, lost response, or app termination is
                // retried after launch or registration.
                let revokedRevision = nextDeviceUsageConsentRevision(
                    after: response.consentRevision
                )
                if revokedRevision > response.consentRevision {
                    await DeviceUsageEnableCompensation.run(
                        recordDeletionIntent: {
                            recordDeviceUsageDeletionIntent(
                                accountID: currentAccount.id,
                                consentRevision: revokedRevision,
                                serverSettings: serverSettings
                            )
                        },
                        deleteSource: {
                            try await deleteDeviceUsageSource(
                                settings: serverSettings,
                                accountID: currentAccount.id,
                                consentRevision: revokedRevision
                            )
                        },
                        clearDeletionIntent: {
                            clearDeviceUsageDeletionIntent(
                                accountID: currentAccount.id,
                                through: revokedRevision,
                                serverSettings: serverSettings
                            )
                        }
                    )
                }
                return false
            }
            var updated = settings(for: currentAccount)
            updated.uploadsDeviceUsageToWorker = true
            updated.deviceUsageWorkerURL = serverURL.absoluteString
            updated.deviceUsageConsentRevision = response.consentRevision
            updated.deviceUsageNextSequence = response.nextSequence
            updated.deviceUsageLastUploadedAt = nil
            updated.deviceUsageLastError = nil
            monitorSettings[currentAccount.id] = updated
            persistMonitorSettings()
            return true
        } catch {
            await serverAccountOperationGate.release(accountID: currentAccount.id)
            recordDeviceUsageUploadError(error, for: currentAccount.id, presentAlert: true)
            return false
        }
    }

    @discardableResult
    func disableDeviceUsageUpload(for account: MonitoredAccount) async -> Bool {
        errorMessage = nil
        guard let currentAccount = accounts.first(where: { $0.id == account.id }),
              isDeviceUsageUploadEnabled(for: currentAccount) else { return true }
        let previous = settings(for: currentAccount)
        let revision = nextDeviceUsageConsentRevision(after: previous.deviceUsageConsentRevision)
        guard revision > previous.deviceUsageConsentRevision else {
            errorMessage = "Usage sharing cannot be disabled because its revision limit was reached."
            return false
        }
        let serverSettings = pushServerSettings
        await serverAccountOperationGate.acquire(accountID: currentAccount.id)
        do {
            try await PushServerClient.disableDeviceUsageUploads(
                settings: serverSettings,
                accountID: currentAccount.id,
                consentRevision: revision
            )
            await serverAccountOperationGate.release(accountID: currentAccount.id)
            guard accounts.contains(where: { $0.id == currentAccount.id }),
                  pushServerSettings == serverSettings else { return false }
            var updated = settings(for: currentAccount)
            updated.uploadsDeviceUsageToWorker = false
            updated.deviceUsageWorkerURL = nil
            updated.deviceUsageConsentRevision = revision
            updated.deviceUsageNextSequence = 1
            updated.deviceUsageLastUploadedAt = nil
            updated.deviceUsageLastError = nil
            monitorSettings[currentAccount.id] = updated
            persistMonitorSettings()
            return true
        } catch {
            await serverAccountOperationGate.release(accountID: currentAccount.id)
            recordDeviceUsageUploadError(error, for: currentAccount.id, presentAlert: true)
            return false
        }
    }

    @discardableResult
    private func uploadDeviceUsageAfterLocalRefresh(
        _ snapshot: UsageSnapshot,
        for account: MonitoredAccount
    ) async -> Bool {
        guard isDeviceUsageUploadEnabled(for: account),
              canConfigureDeviceUsageUpload(for: account),
              let serverURL = try? pushServerSettings.resolvedServerURL() else { return false }
        let serverSettings = pushServerSettings
        let initialSettings = settings(for: account)
        let revision = initialSettings.deviceUsageConsentRevision
        var sequence = initialSettings.deviceUsageNextSequence
        await serverAccountOperationGate.acquire(accountID: account.id)
        do {
            do {
                sequence = try await PushServerClient.uploadDeviceUsageSnapshot(
                    settings: serverSettings,
                    account: account,
                    snapshot: snapshot,
                    consentRevision: revision,
                    sequence: sequence
                )
            } catch let error as PushServerError where error.workerErrorCode == .snapshotReplay {
                // A successful POST response may have been lost. Same-revision PUT is idempotent
                // and returns the authoritative next sequence without changing consent.
                let recovered = try await PushServerClient.enableDeviceUsageUploads(
                    settings: serverSettings,
                    account: account,
                    consentRevision: revision,
                    refreshInterval: refreshSettings.inAppInterval
                )
                sequence = try await PushServerClient.uploadDeviceUsageSnapshot(
                    settings: serverSettings,
                    account: account,
                    snapshot: snapshot,
                    consentRevision: revision,
                    sequence: recovered.nextSequence
                )
            }
            await serverAccountOperationGate.release(accountID: account.id)
            guard accounts.contains(where: { $0.id == account.id }),
                  pushServerSettings == serverSettings,
                  (try? pushServerSettings.resolvedServerURL()) == serverURL else { return false }
            var current = settings(for: account)
            guard current.uploadsDeviceUsageToWorker,
                  current.deviceUsageWorkerURL == serverURL.absoluteString,
                  current.deviceUsageConsentRevision == revision else { return false }
            current.deviceUsageNextSequence = sequence
            current.deviceUsageLastUploadedAt = .now
            current.deviceUsageLastError = nil
            monitorSettings[account.id] = current
            persistMonitorSettings()
            return true
        } catch {
            await serverAccountOperationGate.release(accountID: account.id)
            recordDeviceUsageUploadError(error, for: account.id, presentAlert: false)
            return false
        }
    }

    private func nextDeviceUsageConsentRevision(after revision: Int64) -> Int64 {
        guard revision < Self.maximumServerConsentRevision else { return revision }
        return max(0, revision) + 1
    }

    private func recordDeviceUsageUploadError(
        _ error: Error,
        for accountID: UUID,
        presentAlert: Bool
    ) {
        let message: String
        if let error = error as? PushServerError {
            message = error.localizedDescription
        } else if error is URLError {
            message = "The Worker could not be reached. Usage will be retried after the next successful local refresh."
        } else {
            message = "The sanitized usage update could not be uploaded."
        }
        if var updated = monitorSettings[accountID] {
            updated.deviceUsageLastError = message
            monitorSettings[accountID] = updated
            persistMonitorSettings()
        }
        if presentAlert { errorMessage = message }
    }

    func setWorkerAsCredentialAuthority(_ enabled: Bool, for account: MonitoredAccount) {
        guard !account.isDemo,
              !account.isRemoteOnly,
              let index = accounts.firstIndex(where: { $0.id == account.id }) else { return }
        if enabled {
            guard isServerMonitoringEnabled(for: accounts[index]) else { return }
            guard !isDeviceUsageUploadEnabled(for: accounts[index]) else {
                errorMessage = "Stop uploading device usage before keeping this account's sign-in only on the Worker."
                return
            }
            accounts[index].storesCredentialsOnWorkerOnly = true
            persistAccounts()
            KeychainStore.delete(for: account.id)
        } else {
            accounts[index].storesCredentialsOnWorkerOnly = false
            persistAccounts()
        }
    }

    @discardableResult
    func uploadLocalHistoryToWorker(for account: MonitoredAccount) async -> Bool {
        errorMessage = nil
        return await uploadLocalHistoryToServer(for: account, presentErrors: true)
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
            settings.selfHostedServerConsentRevision = ServerConsentRevisionPolicy
                .recoveredRevision(
                    isRemoteOnly: true,
                    proposedRevision: settings.selfHostedServerConsentRevision,
                    previousRevision: existingSettings.selfHostedServerConsentRevision,
                    highWaterRevision: serverConsentHighWater[account.id] ?? 0
                )
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
            settings.selfHostedServerConsentRevision = ServerConsentRevisionPolicy
                .recoveredRevision(
                    isRemoteOnly: false,
                    proposedRevision: settings.selfHostedServerConsentRevision,
                    previousRevision: previousSettings.selfHostedServerConsentRevision,
                    highWaterRevision: serverConsentHighWater[account.id] ?? 0
                )
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
        Task {
            await updateDeviceUsageSourcePolicies()
            await updateLiveActivity()
        }
    }

    func confirmPushServerLink(
        _ draft: WorkerLinkDraft,
        monitoringAccountIDs: Set<UUID>,
        interval: RefreshInterval,
        historyRetention: CloudHistoryRetention,
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
                accountSettings.selfHostedServerConsentRevision = ServerConsentRevisionPolicy
                    .recoveredRevision(
                        isRemoteOnly: false,
                        proposedRevision: accountSettings.selfHostedServerConsentRevision,
                        previousRevision: accountSettings.selfHostedServerConsentRevision,
                        highWaterRevision: serverConsentHighWater[account.id] ?? 0
                    )
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
            serverMonitoringInterval: interval,
            historyRetention: historyRetention
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
        Task {
            try? await historyStore.setRetentionInterval(historyRetention.timeInterval)
        }
        let transitionTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.transitionPushServer(from: previousSettings, to: settings)
        }
        pushServerTransitionTask = transitionTask
    }

    private func waitForPushServerTransition() async {
        guard let transitionTask = pushServerTransitionTask else { return }
        await transitionTask.value
    }

    func updatePushServerPolicy(
        interval: RefreshInterval,
        historyRetention: CloudHistoryRetention
    ) {
        guard pushServerSettings.mode != .disabled else { return }
        pushServerSettings.serverMonitoringInterval = interval
        pushServerSettings.historyRetention = historyRetention
        UserDefaults.standard.set(
            try? JSONEncoder().encode(pushServerSettings),
            forKey: pushServerSettingsKey
        )
        Task {
            try? await historyStore.setRetentionInterval(historyRetention.timeInterval)
            await updateDeviceUsageSourcePolicies()
            for account in accounts
                where isServerMonitoringEnabled(for: account)
                    && !account.isRemoteOnly
                    && remoteWorkerAccountID(for: account, settings: settings(for: account)) == nil {
                do {
                    let result = try await PushServerClient.updateAccountPolicy(
                        settings: pushServerSettings,
                        account: account
                    )
                    await consumeServerResult(
                        result,
                        for: account,
                        consentRevision: settings(for: account).selfHostedServerConsentRevision,
                        deliverNotifications: false,
                        presentErrors: true
                    )
                } catch {
                    errorMessage = error.localizedDescription
                }
            }
        }
    }

    private func updateDeviceUsageSourcePolicies() async {
        for account in accounts where isDeviceUsageUploadEnabled(for: account) {
            await updateDeviceUsageSourcePolicy(for: account)
        }
    }

    private func updateDeviceUsageSourcePolicy(for account: MonitoredAccount) async {
        guard let currentAccount = accounts.first(where: { $0.id == account.id }),
              isDeviceUsageUploadEnabled(for: currentAccount),
              let serverURL = try? pushServerSettings.resolvedServerURL() else { return }
        let serverSettings = pushServerSettings
        let initial = settings(for: currentAccount)
        await serverAccountOperationGate.acquire(accountID: currentAccount.id)
        do {
            let response = try await PushServerClient.enableDeviceUsageUploads(
                settings: serverSettings,
                account: currentAccount,
                consentRevision: initial.deviceUsageConsentRevision,
                refreshInterval: refreshSettings.inAppInterval
            )
            await serverAccountOperationGate.release(accountID: currentAccount.id)
            guard accounts.contains(where: { $0.id == currentAccount.id }),
                  pushServerSettings == serverSettings else { return }
            var current = settings(for: currentAccount)
            guard current.uploadsDeviceUsageToWorker,
                  current.deviceUsageWorkerURL == serverURL.absoluteString,
                  current.deviceUsageConsentRevision == response.consentRevision else { return }
            current.deviceUsageNextSequence = response.nextSequence
            current.deviceUsageLastError = nil
            monitorSettings[currentAccount.id] = current
            persistMonitorSettings()
        } catch {
            await serverAccountOperationGate.release(accountID: currentAccount.id)
            recordDeviceUsageUploadError(error, for: currentAccount.id, presentAlert: false)
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
            if accountSettings.deviceUsageWorkerURL
                == (try? cleanupSettings.resolvedServerURL())?.absoluteString {
                accountSettings.uploadsDeviceUsageToWorker = false
                accountSettings.deviceUsageWorkerURL = nil
                accountSettings.deviceUsageNextSequence = 1
                accountSettings.deviceUsageLastUploadedAt = nil
                accountSettings.deviceUsageLastError = nil
            }
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
        pushServerStatus = PushServerClient.hasStoredRegistration(settings: pushServerSettings)
            ? .registered : .waitingForDeviceToken
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
                    } catch let error as PushServerError where error.httpStatus == 409 {
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
                        cleanupFailure = error
                    } catch {
                        cleanupFailure = error
                    }
                }
            }
            if pendingServerAccountDeletions.isEmpty {
                pendingServerAccountDeletionURL = nil
            }
            await retryPendingDeviceUsageDeletions(settings: settings)
            if !pendingDeviceUsageDeletions.isEmpty,
               pendingDeviceUsageDeletionURL == origin {
                cleanupFailure = PushServerError.serverCleanupRequired
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
        let isMissingEntitlement = RemotePushRegistrationFailurePolicy
            .isMissingAPNSEntitlement(error)
        let notificationsAreNotAllowed = RemotePushRegistrationFailurePolicy
            .notificationsAreNotAllowed(error)
        if isMissingEntitlement || notificationsAreNotAllowed,
           let serverURL = try? pushServerSettings.resolvedServerURL(),
           (try? KeychainStore.loadPushRegistration(for: serverURL)) != nil {
            pushServerStatus = .registered
            return
        }
        if isMissingEntitlement {
            pushServerStatus = .waitingForDeviceToken
            return
        }
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
                if pendingDeviceUsageDeletionURL == previousURL?.absoluteString {
                    pendingDeviceUsageDeletions = [:]
                    pendingDeviceUsageDeletionURL = nil
                }
                if let previousURL {
                    clearDeviceUsageConfiguration(for: previousURL.absoluteString)
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
            if accountSettings.deviceUsageWorkerURL
                == (try? cleanup.resolvedServerURL())?.absoluteString {
                accountSettings.uploadsDeviceUsageToWorker = false
                accountSettings.deviceUsageWorkerURL = nil
                accountSettings.deviceUsageNextSequence = 1
                accountSettings.deviceUsageLastUploadedAt = nil
                accountSettings.deviceUsageLastError = nil
            }
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

    private func clearDeviceUsageConfiguration(for workerURL: String) {
        var changed = false
        for accountID in Array(monitorSettings.keys) {
            guard var accountSettings = monitorSettings[accountID],
                  accountSettings.deviceUsageWorkerURL == workerURL else { continue }
            accountSettings.uploadsDeviceUsageToWorker = false
            accountSettings.deviceUsageWorkerURL = nil
            accountSettings.deviceUsageNextSequence = 1
            accountSettings.deviceUsageLastUploadedAt = nil
            accountSettings.deviceUsageLastError = nil
            monitorSettings[accountID] = accountSettings
            changed = true
        }
        if changed { persistMonitorSettings() }
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
        if pendingDeviceUsageDeletions.isEmpty {
            UserDefaults.standard.removeObject(forKey: pendingDeviceUsageDeletionsKey)
        } else {
            UserDefaults.standard.set(
                try? JSONEncoder().encode(pendingDeviceUsageDeletions),
                forKey: pendingDeviceUsageDeletionsKey
            )
        }
        if let pendingDeviceUsageDeletionURL {
            UserDefaults.standard.set(
                pendingDeviceUsageDeletionURL,
                forKey: pendingDeviceUsageDeletionURLKey
            )
        } else {
            UserDefaults.standard.removeObject(forKey: pendingDeviceUsageDeletionURLKey)
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

    private func recordDeviceUsageDeletionIntent(
        accountID: UUID,
        consentRevision: Int64,
        serverSettings: PushServerSettings
    ) {
        guard consentRevision > 0,
              let serverURL = try? serverSettings.resolvedServerURL() else { return }
        let normalizedURL = serverURL.absoluteString
        guard pendingDeviceUsageDeletions.isEmpty
                || pendingDeviceUsageDeletionURL == normalizedURL else { return }
        pendingDeviceUsageDeletions[accountID] = max(
            pendingDeviceUsageDeletions[accountID] ?? 0,
            consentRevision
        )
        pendingDeviceUsageDeletionURL = normalizedURL
        persistPendingServerCleanup()
    }

    private func clearDeviceUsageDeletionIntent(
        accountID: UUID,
        through consentRevision: Int64,
        serverSettings: PushServerSettings
    ) {
        guard let serverURL = try? serverSettings.resolvedServerURL(),
              pendingDeviceUsageDeletionURL == serverURL.absoluteString,
              (pendingDeviceUsageDeletions[accountID] ?? .max) <= consentRevision else {
            return
        }
        pendingDeviceUsageDeletions.removeValue(forKey: accountID)
        if pendingDeviceUsageDeletions.isEmpty { pendingDeviceUsageDeletionURL = nil }
        persistPendingServerCleanup()
    }

    private func deleteDeviceUsageSource(
        settings: PushServerSettings,
        accountID: UUID,
        consentRevision: Int64
    ) async throws {
        await serverAccountOperationGate.acquire(accountID: accountID)
        do {
            try await PushServerClient.disableDeviceUsageUploads(
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

    private func retryPendingDeviceUsageDeletions(settings: PushServerSettings) async {
        guard let serverURL = try? settings.resolvedServerURL(),
              pendingDeviceUsageDeletionURL == serverURL.absoluteString else { return }
        for (accountID, revision) in Array(pendingDeviceUsageDeletions) {
            do {
                try await deleteDeviceUsageSource(
                    settings: settings,
                    accountID: accountID,
                    consentRevision: revision
                )
                clearDeviceUsageDeletionIntent(
                    accountID: accountID,
                    through: revision,
                    serverSettings: settings
                )
            } catch {
                // Keep the durable tombstone intent. A later launch or registration retries it.
            }
        }
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
        cacheAccounts(accounts)
    }

    private func cacheAccounts(_ accounts: [MonitoredAccount]) {
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
            let syncedAccounts = try KeychainStore.loadAccounts()
            // Keep non-demo cached rows until the async synchronization pass can compare them
            // against iCloud and durably journal deletion of any Worker-owned sources. This is
            // especially important when iCloud delivered a merge deletion before its alias.
            let initial = syncedAccounts + cachedAccounts.filter { cached in
                cached.isDemo || !syncedAccounts.contains(where: { $0.id == cached.id })
            }
            let accountsByID = Dictionary(
                initial.map { ($0.id, $0) },
                uniquingKeysWith: { cached, synced in synced.isDemo ? cached : synced }
            )
            return normalizeDemoPresentation(
                KeychainStore.orderedAccounts(Array(accountsByID.values))
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

    private func directChatGPTDuplicateMergePlans(in candidates: [MonitoredAccount])
        -> [DirectChatGPTDuplicateMergePlan] {
        let workerProtectedAccountIDs = Set(candidates.compactMap { account -> UUID? in
            activeWorkerProtection(for: account) ? account.id : nil
        })
        return DirectChatGPTDuplicateMergePolicy.plans(
            accounts: candidates,
            workerProtectedAccountIDs: workerProtectedAccountIDs
        )
    }

    private func mergeDirectChatGPTDuplicates(
        _ plan: DirectChatGPTDuplicateMergePlan,
        in candidates: inout [MonitoredAccount]
    ) async -> Bool {
        guard let initialCanonical = candidates.first(where: {
            $0.id == plan.canonicalAccountID
        }) else { return false }
        let duplicates = plan.duplicateAccountIDs.compactMap { duplicateID in
            candidates.first(where: { $0.id == duplicateID })
        }
        guard duplicates.count == plan.duplicateAccountIDs.count,
              duplicates.allSatisfy({
                  DirectChatGPTDuplicateMergePolicy.matches(
                      $0,
                      canonical: initialCanonical
                  )
              }),
              plan.duplicateAccountIDs.allSatisfy({ duplicateID in
                  guard let duplicate = candidates.first(where: { $0.id == duplicateID }) else {
                      return false
                  }
                  return !activeWorkerProtection(for: duplicate)
              }) else { return false }

        // Prepare the surviving credential before mutating any account state. Invalid or
        // mismatched token claims abort the merge without exposing their contents.
        do {
            guard try KeychainStore.prepareChatGPTDuplicateCredential(
                canonical: initialCanonical,
                duplicateIDs: plan.duplicateAccountIDs
            ) else { return false }
        } catch {
            return false
        }

        // The plan was computed from a snapshot of local state. Recheck every row after the
        // Keychain read and immediately before durable merge writes so a newly arrived Worker
        // attachment or pending deletion cannot be collapsed by a stale plan.
        let protectedAfterCredentialPreparation = Set(
            ([initialCanonical.id] + plan.duplicateAccountIDs).filter { accountID in
                activeWorkerProtection(accountID: accountID)
                    || candidates.first(where: { $0.id == accountID })?
                        .storesCredentialsOnWorkerOnly == true
            }
        )
        guard DirectChatGPTDuplicateMergePolicy.protectionRemainsValid(
            plan,
            protectedAccountIDs: protectedAfterCredentialPreparation
        ) else { return false }

        var canonical = initialCanonical
        var mergedSettings = monitorSettings[canonical.id] ?? .init()
        var newestSnapshot = snapshots[canonical.id]
        for duplicate in duplicates {
            canonical = DirectChatGPTDuplicateMergePolicy.mergedAccount(
                canonical: canonical,
                duplicate: duplicate
            )
            mergedSettings = DirectChatGPTDuplicateMergePolicy.mergedSettings(
                canonical: mergedSettings,
                duplicate: monitorSettings[duplicate.id] ?? .init()
            )
            if let duplicateSnapshot = snapshots[duplicate.id],
               duplicateSnapshot.fetchedAt > (newestSnapshot?.fetchedAt ?? .distantPast) {
                newestSnapshot = duplicateSnapshot
            }
        }

        // History merge is idempotent: a retry finds no remaining source points and preserves the
        // canonical detector state. Do this before deleting the losing Keychain records so any
        // later Keychain failure can be retried without orphaning history.
        do {
            for duplicateID in plan.duplicateAccountIDs {
                usageHistory = try await historyStore.mergeAccount(
                    sourceID: duplicateID,
                    into: canonical.id
                )
            }
            historyStorageError = nil
        } catch {
            historyStorageError = error.localizedDescription
            return false
        }


        // History I/O yielded the main actor. Treat a protection change as authoritative even
        // though history merge is idempotent; no account/settings/alias deletion has occurred.
        let protectedAfterHistoryMerge = Set(
            ([initialCanonical.id] + plan.duplicateAccountIDs).filter { accountID in
                activeWorkerProtection(accountID: accountID)
                    || candidates.first(where: { $0.id == accountID })?
                        .storesCredentialsOnWorkerOnly == true
            }
        )
        guard DirectChatGPTDuplicateMergePolicy.protectionRemainsValid(
            plan,
            protectedAccountIDs: protectedAfterHistoryMerge
        ) else { return false }

        // Save both the canonical row and credential-free redirects before deleting anything.
        // The redirects let another device migrate UUID-keyed local state even if iCloud delivers
        // the losing-row deletion first.
        do {
            try KeychainStore.saveAccount(canonical)
            for duplicateID in plan.duplicateAccountIDs {
                try KeychainStore.saveAccountMergeAlias(.init(
                    sourceAccountID: duplicateID,
                    canonicalAccountID: canonical.id,
                    workspaceID: canonical.workspaceID,
                    createdAt: .now
                ))
            }
        } catch {
            return false
        }

        if let index = candidates.firstIndex(where: { $0.id == canonical.id }) {
            candidates[index] = canonical
        }
        let duplicateIDs = Set(plan.duplicateAccountIDs)
        candidates.removeAll { duplicateIDs.contains($0.id) }
        candidates = KeychainStore.orderedAccounts(candidates)
        persistDirectChatGPTMergeState(
            canonical: canonical,
            mergedSettings: mergedSettings,
            newestSnapshot: newestSnapshot,
            sourceIDs: plan.duplicateAccountIDs,
            candidates: candidates
        )

        // Irreversible synchronizable deletion is deliberately last. A partial failure leaves a
        // duplicate row that a later sync retries; all history/settings/snapshot state is already
        // durable under the canonical UUID, so retrying is lossless and idempotent.
        for duplicateID in plan.duplicateAccountIDs {
            try? KeychainStore.deleteDuplicateAccountAndCredential(for: duplicateID)
        }
        return true
    }

    private func activeWorkerProtection(for account: MonitoredAccount) -> Bool {
        activeWorkerProtection(accountID: account.id)
            || account.storesCredentialsOnWorkerOnly == true
    }

    private func activeWorkerProtection(accountID: UUID) -> Bool {
        let accountSettings = monitorSettings[accountID]
        return accountSettings?.monitorOnSelfHostedServer == true
            || accountSettings?.selfHostedServerConsentURL != nil
            || accountSettings?.remoteWorkerAccountID != nil
            || accountSettings?.workerAccountReference != nil
            || DirectChatGPTDuplicateMergePolicy.protectsDeviceUsageSource(
                accountSettings,
                hasPendingDeletion: pendingDeviceUsageDeletions[accountID] != nil
            )
            || pendingServerAccountDeletions[accountID] != nil
    }

    private func reconcileDirectChatGPTMergeAlias(
        _ alias: DirectChatGPTAccountMergeAlias,
        canonical: MonitoredAccount,
        in candidates: inout [MonitoredAccount]
    ) async -> Bool {
        guard alias.isValid,
              alias.canonicalAccountID == canonical.id,
              alias.workspaceID == canonical.workspaceID,
              !activeWorkerProtection(accountID: alias.sourceAccountID),
              candidates.first(where: { $0.id == alias.sourceAccountID })?
                  .storesCredentialsOnWorkerOnly != true else { return false }

        var mergedSettings = monitorSettings[canonical.id] ?? .init()
        if let duplicateSettings = monitorSettings[alias.sourceAccountID] {
            mergedSettings = DirectChatGPTDuplicateMergePolicy.mergedSettings(
                canonical: mergedSettings,
                duplicate: duplicateSettings
            )
        }
        var newestSnapshot = snapshots[canonical.id]
        let sourceSnapshot = snapshots[alias.sourceAccountID]
            ?? SharedSnapshotStore.load()
                .filter { $0.accountID == alias.sourceAccountID }
                .max { $0.fetchedAt < $1.fetchedAt }
        if let sourceSnapshot,
           sourceSnapshot.fetchedAt > (newestSnapshot?.fetchedAt ?? .distantPast) {
            newestSnapshot = sourceSnapshot
        }

        do {
            usageHistory = try await historyStore.mergeAccount(
                sourceID: alias.sourceAccountID,
                into: canonical.id
            )
            historyStorageError = nil
        } catch {
            historyStorageError = error.localizedDescription
            return false
        }

        persistDirectChatGPTMergeState(
            canonical: canonical,
            mergedSettings: mergedSettings,
            newestSnapshot: newestSnapshot,
            sourceIDs: [alias.sourceAccountID],
            candidates: candidates
        )
        return true
    }

    private func persistDirectChatGPTMergeState(
        canonical: MonitoredAccount,
        mergedSettings: AccountMonitorSettings,
        newestSnapshot: UsageSnapshot?,
        sourceIDs: [UUID],
        candidates: [MonitoredAccount]
    ) {
        monitorSettings[canonical.id] = mergedSettings
        for sourceID in sourceIDs {
            monitorSettings.removeValue(forKey: sourceID)
            snapshots.removeValue(forKey: sourceID)
            refreshFailures.removeValue(forKey: sourceID)
        }
        if let newestSnapshot {
            snapshots[canonical.id] = DirectChatGPTDuplicateMergePolicy.rekeyedSnapshot(
                newestSnapshot,
                for: canonical
            )
        }
        cacheAccounts(candidates)
        persistMonitorSettings()
        persistSharedSnapshots(for: candidates)
        for sourceID in sourceIDs {
            appliedAccountMergeAliases[sourceID] = canonical.id
        }
        UserDefaults.standard.set(
            try? JSONEncoder().encode(appliedAccountMergeAliases),
            forKey: appliedAccountMergeAliasesKey
        )
        // Force the local crash-recovery journal out before removing synchronized source rows.
        _ = UserDefaults.standard.synchronize()
        _ = UserDefaults(suiteName: SharedSnapshotStore.suiteName)?.synchronize()
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
                                     presentErrors: Bool = true,
                                     replacingRemoteCredential: Bool = false) async -> Bool {
        await serverAccountOperationGate.acquire(accountID: account.id)
        let succeeded = await performServerAccountUpload(
            account,
            presentErrors: presentErrors,
            replacingRemoteCredential: replacingRemoteCredential
        )
        await serverAccountOperationGate.release(accountID: account.id)
        return succeeded
    }

    @discardableResult
    private func performServerAccountUpload(_ account: MonitoredAccount,
                                            presentErrors: Bool,
                                            replacingRemoteCredential: Bool = false) async -> Bool {
        var accountSettings = settings(for: account)
        let remoteAccountID = remoteWorkerAccountID(for: account, settings: accountSettings)
        guard ServerAccountUploadPolicy.permitsUpload(
                isDemo: account.isDemo,
                isRemoteOnly: account.isRemoteOnly,
                hasRemoteWorkerAccountID: remoteAccountID != nil,
                replacingRemoteCredential: replacingRemoteCredential
              ),
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
                consentRevision: consentRevision,
                replacingRemoteCredential: replacingRemoteCredential
            )
            guard await consumeServerResult(
                result,
                for: currentAccount,
                consentRevision: consentRevision,
                deliverNotifications: false,
                presentErrors: presentErrors
            ) else { return false }
            if replacingRemoteCredential,
               !WorkerCredentialReplacementPolicy.isConfirmed(
                    sessionStatus: result.sessionStatus
               ) {
                if presentErrors {
                    errorMessage = PushServerError.credentialReplacementUnconfirmed
                        .localizedDescription
                }
                return false
            }
            _ = await uploadLocalHistoryToServer(
                for: currentAccount,
                presentErrors: false
            )
            if currentAccount.usesWorkerAsCredentialAuthority {
                KeychainStore.delete(for: currentAccount.id)
            }
            return true
        } catch let error as PushServerError
            where replacingRemoteCredential && error.httpStatus == 404 {
            if let recoveredSettings = ServerMonitoringRecovery.detachingMissingRemoteSource(
                in: settings(for: account),
                hasLocalCredentials: hasLocalCredentials(for: account)
            ) {
                monitorSettings[account.id] = recoveredSettings
                persistMonitorSettings()
                return await performServerAccountUpload(
                    account,
                    presentErrors: presentErrors
                )
            }
            if presentErrors {
                errorMessage = PushServerError.remoteAccountUnavailable.localizedDescription
            }
            return false
        } catch {
            guard let currentAccount = accounts.first(where: { $0.id == account.id }) else { return false }
            let currentSettings = settings(for: currentAccount)
            guard serverMonitoringEnabled(currentSettings, account: currentAccount),
                  currentSettings.selfHostedServerConsentRevision == consentRevision else { return false }
            let failure = AccountRefreshFailure(error: error)
            refreshFailures[account.id] = failure
            if presentErrors {
                errorMessage = failure.message
            }
            return false
        }
    }

    private func uploadLocalHistoryToServer(
        for account: MonitoredAccount,
        presentErrors: Bool
    ) async -> Bool {
        guard !account.isDemo,
              !account.isRemoteOnly,
              isServerMonitoringEnabled(for: account),
              pushServerSettings.mode != .disabled else { return false }
        let cutoff = Date.now.addingTimeInterval(
            -pushServerSettings.historyRetention.timeInterval
        )
        let localPoints = usageHistory
            .filter {
                $0.accountID == account.id
                    && $0.source != .server
                    && $0.recordedAt >= cutoff
            }
            .reduce(into: [String: UsageHistoryPoint]()) { result, point in
                result[point.deduplicationKey] = point
            }
            .values
            .sorted {
                if $0.recordedAt != $1.recordedAt { return $0.recordedAt < $1.recordedAt }
                return $0.metricID < $1.metricID
            }
        guard !localPoints.isEmpty else { return true }
        do {
            _ = try await PushServerClient.uploadHistory(
                settings: pushServerSettings,
                account: account,
                points: localPoints
            )
            return true
        } catch {
            if presentErrors { errorMessage = error.localizedDescription }
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
            latestServerPoint: latestServerPoint,
            retentionInterval: pushServerSettings.historyRetention.timeInterval
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
                ), hasLocalCredentials(for: metadataSource) {
                    let uploaded = await performServerAccountUpload(
                        metadataSource,
                        presentErrors: false
                    )
                    result.accountDetails = uploaded
                        ? WorkerMetadataPolicy.authoritativeDetails(from: metadataSource)
                        : nil
                }
            }
            return await consumeServerResult(
                result,
                for: currentAccount,
                consentRevision: consentRevision,
                deliverNotifications: publishChanges,
                presentErrors: presentErrors
            )
        } catch let error as PushServerError where error.httpStatus == 404 {
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
                    return await consumeServerResult(
                        result,
                        for: restoredAccount,
                        consentRevision: consentRevision,
                        deliverNotifications: publishChanges,
                        presentErrors: presentErrors
                    )
                } catch let error as PushServerError where error.httpStatus == 404 {
                    if let recoveredSettings = ServerMonitoringRecovery
                        .detachingMissingRemoteSource(
                            in: settings(for: account),
                            hasLocalCredentials: hasLocalCredentials(for: account)
                        ) {
                        monitorSettings[account.id] = recoveredSettings
                        persistMonitorSettings()
                        return await performServerAccountUpload(
                            account,
                            presentErrors: presentErrors
                        )
                    }
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
        let failure = AccountRefreshFailure(error: error)
        refreshFailures[account.id] = failure
        if presentErrors {
            errorMessage = failure.message
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

    @discardableResult
    private func consumeServerResult(_ result: ServerAccountSyncResult,
                                     for account: MonitoredAccount,
                                     consentRevision: Int64,
                                     deliverNotifications: Bool,
                                     presentErrors: Bool) async -> Bool {
        guard var currentAccount = accounts.first(where: { $0.id == account.id }) else {
            return false
        }
        var currentSettings = settings(for: currentAccount)
        guard serverMonitoringEnabled(currentSettings, account: currentAccount),
              currentSettings.selfHostedServerConsentRevision == consentRevision else {
            if presentErrors {
                errorMessage = PushServerError.accountConsentChanged.localizedDescription
            }
            return false
        }
        let currentServerURL = (try? pushServerSettings.resolvedServerURL())?.absoluteString
        let pendingDeletionRevision = pendingServerAccountDeletionURL == currentServerURL
            ? pendingServerAccountDeletions[account.id] : nil
        do {
            let authoritativeRevision = try ServerConsentRevisionPolicy.synchronizedRevision(
                currentRevision: consentRevision,
                serverRevision: result.consentRevision,
                highWaterRevision: serverConsentHighWater[account.id] ?? 0,
                pendingDeletionRevision: pendingDeletionRevision
            )
            if authoritativeRevision != currentSettings.selfHostedServerConsentRevision {
                currentSettings.selfHostedServerConsentRevision = authoritativeRevision
                monitorSettings[account.id] = currentSettings
                persistMonitorSettings()
            }
            recordServerConsentHighWater(
                accountID: account.id,
                revision: authoritativeRevision
            )
            if pendingDeletionRevision != nil {
                clearServerAccountDeletionIntent(
                    accountID: account.id,
                    through: authoritativeRevision,
                    serverSettings: pushServerSettings
                )
            }
        } catch {
            refreshFailures[account.id] = AccountRefreshFailure(error: error)
            if presentErrors { errorMessage = error.localizedDescription }
            return false
        }
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
            // Only an explicitly active Worker session proves that a reconnect succeeded. Keep
            // any prior expired-session prompt visible while status is inconclusive.
            break
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
        return true
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
        persistSharedSnapshots(for: accounts)
        WidgetCenter.shared.reloadAllTimelines()
    }

    private func persistSharedSnapshots(for accounts: [MonitoredAccount]) {
        SharedSnapshotStore.save(accounts.compactMap { account in
            snapshots[account.id].map {
                presentedSnapshot($0, for: account).filtered(using: settings(for: account))
            }
        })
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
