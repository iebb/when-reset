import CryptoKit
import Foundation
import Security
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

enum PushServerMode: String, Codable, CaseIterable, Hashable, Sendable {
    case disabled
    case custom

    var title: String {
        switch self {
        case .disabled: "Off"
        case .custom: "Self-hosted server"
        }
    }
}

enum CloudHistoryRetention: Int, Codable, CaseIterable, Hashable, Sendable {
    case sevenDays = 7
    case thirtyFiveDays = 35
    case ninetyDays = 90
    case oneHundredEightyDays = 180
    case oneYear = 365
    case twoYears = 730

    var title: String {
        switch self {
        case .sevenDays: "7 days"
        case .thirtyFiveDays: "35 days"
        case .ninetyDays: "90 days"
        case .oneHundredEightyDays: "180 days"
        case .oneYear: "1 year"
        case .twoYears: "2 years"
        }
    }

    var timeInterval: TimeInterval { TimeInterval(rawValue) * 24 * 60 * 60 }
}

struct PushServerSettings: Codable, Hashable, Sendable {
    var mode: PushServerMode = .disabled
    var customServerURL = ""
    var serverMonitoringInterval: RefreshInterval = .tenMinutes
    var historyRetention: CloudHistoryRetention = .thirtyFiveDays

    init(mode: PushServerMode = .disabled, customServerURL: String = "",
         serverMonitoringInterval: RefreshInterval = .tenMinutes,
         historyRetention: CloudHistoryRetention = .thirtyFiveDays) {
        self.mode = mode
        self.customServerURL = customServerURL
        self.serverMonitoringInterval = serverMonitoringInterval
        self.historyRetention = historyRetention
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        mode = try values.decodeIfPresent(PushServerMode.self, forKey: .mode) ?? .disabled
        customServerURL = try values.decodeIfPresent(String.self, forKey: .customServerURL) ?? ""
        serverMonitoringInterval = try values.decodeIfPresent(
            RefreshInterval.self,
            forKey: .serverMonitoringInterval
        ) ?? .tenMinutes
        historyRetention = try values.decodeIfPresent(
            CloudHistoryRetention.self,
            forKey: .historyRetention
        ) ?? .thirtyFiveDays
    }

    func resolvedServerURL() throws -> URL? {
        switch mode {
        case .disabled:
            return nil
        case .custom:
            return try PushServerConfiguration.normalizedServerURL(customServerURL)
        }
    }
}

enum PushServerStatus: Equatable, Sendable {
    case disabled
    case waitingForDeviceToken
    case registering
    case disconnecting
    case registered
    case failed(String)

    var title: String {
        switch self {
        case .disabled: "Off"
        case .waitingForDeviceToken: "Waiting for APNs"
        case .registering: "Registering…"
        case .disconnecting: "Removing old Worker data…"
        case .registered: "Registered"
        case let .failed(message): message
        }
    }
}

enum WorkerErrorCode: String, Decodable, Equatable, Sendable {
    case unauthorized
    case providerSessionExpired = "provider_session_expired"
    case providerRequestForbidden = "provider_request_forbidden"
    case providerCheckFailed = "provider_check_failed"
    case invalidSnapshotSource = "invalid_snapshot_source"
    case consentRevisionConflict = "consent_revision_conflict"
    case localAccountConflict = "local_account_conflict"
    case invalidDeviceSnapshot = "invalid_device_snapshot"
    case snapshotOutsideTimeWindow = "snapshot_outside_time_window"
    case snapshotReplay = "snapshot_replay"
    case snapshotStale = "snapshot_stale"
    case accountNotFound = "account_not_found"
}

enum PushServerError: LocalizedError {
    case invalidServerURL
    case invalidWorkerLink
    case expiredWorkerLink
    case workerIdentityMismatch
    case invalidResponse
    case responseTooLarge
    case serverRejected(Int, WorkerErrorCode? = nil)
    case userConfirmationRequired
    case serverCleanupRequired
    case missingRegistration
    case missingServerAccessKey
    case randomGenerationFailed(OSStatus)
    case accountMonitoringUnavailable
    case remoteAccountUnavailable
    case consentRevisionConflict
    case accountConsentChanged
    case credentialReplacementUnconfirmed

    var errorDescription: String? {
        switch self {
        case .invalidServerURL: "Enter a valid HTTPS server URL."
        case .invalidWorkerLink: "This isn’t a valid When Reset Worker link."
        case .expiredWorkerLink: "This Worker link has expired. Generate a new QR code."
        case .workerIdentityMismatch: "The Worker identity does not match this link."
        case .invalidResponse: "The push server returned an invalid response."
        case .responseTooLarge: "The push server returned too much data."
        case let .serverRejected(code, workerCode):
            switch workerCode {
            case .unauthorized:
                "This device is no longer registered with the Worker. Pair it again in Cloud Worker settings."
            case .providerSessionExpired:
                "The Worker reports that this provider sign-in expired or was revoked."
            case .providerRequestForbidden:
                "ChatGPT rejected the quota check from this Cloudflare Worker. Try again later, or monitor this account on this device instead."
            case .invalidSnapshotSource, .invalidDeviceSnapshot:
                "The Worker rejected this sanitized usage snapshot."
            case .consentRevisionConflict:
                "Usage-sharing settings changed on another device. Try again."
            case .localAccountConflict:
                "This local account identifier is already attached to a different Worker account."
            case .snapshotOutsideTimeWindow:
                "The Worker rejected this snapshot because its collection time is outside the allowed window."
            case .snapshotReplay:
                "The Worker has already received this usage update."
            case .snapshotStale:
                "The Worker already has a newer usage snapshot for this account."
            case .accountNotFound:
                "Device usage sharing is no longer enabled for this account."
            case .providerCheckFailed, nil:
                "The push server returned HTTP \(code)."
            }
        case .userConfirmationRequired: "Confirm the Worker link before continuing."
        case .serverCleanupRequired:
            "Finish removing the previous Worker before linking another one. Retry cleanup first."
        case .missingRegistration: "The Worker registration is not ready on this device. Finish pairing, then try the refresh again."
        case .missingServerAccessKey: "Enter the access key for this self-hosted server."
        case let .randomGenerationFailed(status): "Couldn’t create the device secret (\(status))."
        case .accountMonitoringUnavailable:
            "The Worker registration is not ready on this device. Finish pairing before enabling server monitoring."
        case .remoteAccountUnavailable:
            "This account is no longer available on the self-hosted Worker."
        case .consentRevisionConflict:
            "The Worker account authorization conflicts with a pending removal. Finish Worker cleanup or reconnect the account."
        case .accountConsentChanged:
            "The Worker account settings changed during this update. Try refreshing again."
        case .credentialReplacementUnconfirmed:
            "The Worker did not confirm the new sign-in. Sign in again to resume updates."
        }
    }

    var httpStatus: Int? {
        guard case let .serverRejected(status, _) = self else { return nil }
        return status
    }

    var workerErrorCode: WorkerErrorCode? {
        guard case let .serverRejected(_, code) = self else { return nil }
        return code
    }
}

enum PushServerConfiguration {
    static func normalizedServerURL(_ value: String) throws -> URL {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var components = URLComponents(string: trimmed),
              components.scheme?.lowercased() == "https",
              let host = components.host, !host.isEmpty,
              components.user == nil, components.password == nil else {
            throw PushServerError.invalidServerURL
        }
        components.scheme = "https"
        components.host = host.lowercased()
        components.query = nil
        components.fragment = nil
        let trimmedPath = components.path.replacingOccurrences(
            of: #"/+$"#,
            with: "",
            options: .regularExpression
        )
        components.path = trimmedPath
        guard let url = components.url else { throw PushServerError.invalidServerURL }
        return url
    }

    static func normalizedServerOrigin(_ value: String) throws -> URL {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var components = URLComponents(string: trimmed),
              components.scheme?.lowercased() == "https",
              let host = components.host, !host.isEmpty,
              components.user == nil, components.password == nil,
              components.query == nil, components.fragment == nil,
              components.path.isEmpty || components.path == "/" else {
            throw PushServerError.invalidServerURL
        }
        components.scheme = "https"
        components.host = host.lowercased()
        components.path = ""
        guard let url = components.url else { throw PushServerError.invalidServerURL }
        return url
    }
}

struct WorkerLinkPayload: Identifiable, Hashable, Sendable {
    static let scheme = "whenreset"
    static let host = "link-worker"
    static let maximumURLBytes = 2_048

    var id: UUID { sessionID }
    let serverURL: URL
    let sessionID: UUID
    let token: String
    let expiresAt: Date

    static func parse(_ value: String, now: Date = .now) throws -> WorkerLinkPayload {
        guard value.utf8.count <= maximumURLBytes,
              let url = URL(string: value.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            throw PushServerError.invalidWorkerLink
        }
        return try parse(url, now: now)
    }

    static func parse(_ url: URL, now: Date = .now) throws -> WorkerLinkPayload {
        guard url.absoluteString.utf8.count <= maximumURLBytes,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme?.lowercased() == scheme,
              components.host?.lowercased() == host,
              components.user == nil, components.password == nil,
              components.port == nil,
              components.path.isEmpty || components.path == "/",
              components.fragment == nil else {
            throw PushServerError.invalidWorkerLink
        }

        let items = components.queryItems ?? []
        let expectedNames: Set<String> = ["v", "server", "session", "token", "expires"]
        guard items.count == expectedNames.count,
              Set(items.map(\.name)) == expectedNames else {
            throw PushServerError.invalidWorkerLink
        }
        let values = Dictionary(uniqueKeysWithValues: items.compactMap { item in
            item.value.map { (item.name, $0) }
        })
        guard values.count == expectedNames.count,
              values["v"] == "1",
              let server = values["server"],
              let session = values["session"],
              let token = values["token"],
              let expires = values["expires"],
              let sessionID = UUID(uuidString: session),
              session == sessionID.uuidString.lowercased(),
              token.range(of: #"^[A-Za-z0-9_-]{43}$"#, options: .regularExpression) != nil,
              let expirationSeconds = Int64(expires),
              String(expirationSeconds) == expires else {
            throw PushServerError.invalidWorkerLink
        }
        let expiresAt = Date(timeIntervalSince1970: TimeInterval(expirationSeconds))
        guard expiresAt > now else { throw PushServerError.expiredWorkerLink }
        guard expiresAt.timeIntervalSince(now) <= 10 * 60 else {
            throw PushServerError.invalidWorkerLink
        }
        let serverURL: URL
        do {
            serverURL = try PushServerConfiguration.normalizedServerOrigin(server)
        } catch {
            throw PushServerError.invalidWorkerLink
        }
        return WorkerLinkPayload(
            serverURL: serverURL,
            sessionID: sessionID,
            token: token,
            expiresAt: expiresAt
        )
    }

    func validateNotExpired(at date: Date = .now) throws {
        guard expiresAt > date else { throw PushServerError.expiredWorkerLink }
    }
}

enum WorkerLinkDraft: Identifiable, Hashable, Sendable {
    case pairing(WorkerLinkPayload)
    case manual(id: UUID, serverURL: URL, accessKey: String)

    var id: UUID {
        switch self {
        case let .pairing(payload): payload.id
        case let .manual(id, _, _): id
        }
    }

    var serverURL: URL {
        switch self {
        case let .pairing(payload): payload.serverURL
        case let .manual(_, serverURL, _): serverURL
        }
    }
}

struct WorkerLinkMetadata: Equatable, Sendable {
    var displayName: String
    var serverURL: URL
    var expiresAt: Date?
}

enum PushServerEnrollment: Hashable, Sendable {
    case pairing(WorkerLinkPayload)
    case accessKey(String)
}

struct PushRegistrationCredentials: Codable, Equatable, Sendable {
    var deviceID: UUID
    var deviceSecret: String
    var serverURL: URL
}

struct ServerAccountSyncResult: Sendable {
    var consentRevision: Int64
    var accountDetails: ProviderAccountDetails?
    var snapshot: UsageSnapshot?
    var history: [UsageHistoryPoint]
    var workerAccountReference: String? = nil
    var lastSuccessAt: Date?
    var lastError: String?
    var sessionStatus: WorkerSessionStatus? = nil
    var sessionCheckedAt: Date? = nil
    var historyRetentionDays: Int? = nil
}

enum WorkerSessionStatus: String, Decodable, Hashable, Sendable {
    case active, expired, error, unchecked

    var label: String {
        switch self {
        case .active: "Session active"
        case .expired: "Sign-in expired"
        case .error: "Session check failed"
        case .unchecked: "Session not checked"
        }
    }

    var systemImageName: String {
        switch self {
        case .active: "checkmark.shield.fill"
        case .expired: "person.crop.circle.badge.exclamationmark"
        case .error: "exclamationmark.triangle.fill"
        case .unchecked: "questionmark.circle"
        }
    }
}

struct WorkerAccountMetadata: Codable, Equatable, Hashable, Sendable {
    var name: String?
    var email: String?
    var plan: String?
    var planExpiresTimestamp: TimeInterval?
    var trialExpiresTimestamp: TimeInterval?

    var accountDetails: ProviderAccountDetails {
        ProviderAccountDetails(
            profileName: name,
            email: email,
            plan: plan,
            planExpiresAt: planExpiresTimestamp.map(Date.init(timeIntervalSince1970:)),
            trialExpiresAt: trialExpiresTimestamp.map(Date.init(timeIntervalSince1970:)),
            replacesMissingFields: true
        )
    }

    init(name: String?, email: String?, plan: String?,
         planExpiresAt: Date?, trialExpiresAt: Date?) {
        self.name = name
        self.email = email
        self.plan = plan
        planExpiresTimestamp = planExpiresAt?.timeIntervalSince1970
        trialExpiresTimestamp = trialExpiresAt?.timeIntervalSince1970
    }

    enum CodingKeys: String, CodingKey {
        case name, email, plan
        case planExpiresTimestamp = "plan_expires_at"
        case trialExpiresTimestamp = "trial_expires_at"
    }
}

struct ServerMissingQuotaDescriptor: Sendable {
    var metricID: String
    var title: String
    var kind: UsageWindowKind?
    var windowMinutes: Int?
    var resetsAt: Date?
}

struct RemoteWorkerAccountCandidate: Identifiable, Decodable, Hashable, Sendable {
    var remoteAccountID: String
    var syncedAccountReference: String? = nil
    var workerAccountReference: String? = nil
    var providerID: ProviderID
    var displayName: String
    var plan: String?
    var metadata: WorkerAccountMetadata?
    var lastSuccessTimestamp: TimeInterval?
    var sessionStatus: WorkerSessionStatus? = nil
    var sessionCheckedTimestamp: TimeInterval? = nil

    var id: String { remoteAccountID }
    var lastSuccessAt: Date? {
        lastSuccessTimestamp.map(Date.init(timeIntervalSince1970:))
    }
    var sessionCheckedAt: Date? {
        sessionCheckedTimestamp.map(Date.init(timeIntervalSince1970:))
    }

    enum CodingKeys: String, CodingKey {
        case remoteAccountID = "remote_account_id"
        case syncedAccountReference = "synced_account_reference"
        case workerAccountReference = "account_reference"
        case providerID = "provider_id"
        case displayName = "display_name"
        case plan
        case metadata
        case lastSuccessTimestamp = "last_success_at"
        case sessionStatus = "session_status"
        case sessionCheckedTimestamp = "session_checked_at"
    }
}

struct RemoteWorkerAccountImportResult: Equatable, Sendable {
    var account: RemoteWorkerAccountCandidate
    var consentRevision: Int64
}

enum ServerConsentRevisionPolicy {
    static let maximum: Int64 = 9_007_199_254_740_991

    static func importedRevision(_ revision: Int64?) throws -> Int64 {
        let resolvedRevision = revision ?? 1
        guard (1...maximum).contains(resolvedRevision) else {
            throw PushServerError.invalidResponse
        }
        return resolvedRevision
    }

    static func recoveredRevision(
        isRemoteOnly: Bool,
        proposedRevision: Int64,
        previousRevision: Int64,
        highWaterRevision: Int64
    ) -> Int64 {
        guard !isRemoteOnly else { return 1 }
        // A recovered direct attachment's stored revision came from the Worker. UI state and
        // a monotonic high-water mark can both be stale relative to a newly imported source.
        _ = proposedRevision
        _ = highWaterRevision
        return max(1, min(previousRevision, maximum))
    }

    static func synchronizedRevision(
        currentRevision: Int64,
        serverRevision: Int64,
        highWaterRevision: Int64,
        pendingDeletionRevision: Int64?
    ) throws -> Int64 {
        guard (1...maximum).contains(serverRevision) else {
            throw PushServerError.invalidResponse
        }
        if let pendingDeletionRevision,
           serverRevision <= pendingDeletionRevision {
            throw PushServerError.consentRevisionConflict
        }
        // An authenticated sync response is authoritative for the resolved Worker source. This
        // permits recovery to a newer direct-source revision and rebases an imported subscription
        // to its independent revision 1 instead of projecting stale local state onto it.
        _ = currentRevision
        _ = highWaterRevision
        return serverRevision
    }
}

enum ServerAccountUploadPolicy {
    static func permitsUpload(
        isDemo: Bool,
        isRemoteOnly: Bool,
        hasRemoteWorkerAccountID: Bool,
        replacingRemoteCredential: Bool
    ) -> Bool {
        !isDemo
            && !isRemoteOnly
            && (!hasRemoteWorkerAccountID || replacingRemoteCredential)
    }
}

enum WorkerCredentialReplacementPolicy {
    static func isConfirmed(sessionStatus: WorkerSessionStatus?) -> Bool {
        sessionStatus == .active
    }
}

enum DeviceUsageSequencePolicy {
    static func isValid(_ sequence: Int64) -> Bool {
        sequence > 0 && sequence < ServerConsentRevisionPolicy.maximum
    }

    static func next(after sequence: Int64) -> Int64? {
        guard isValid(sequence) else { return nil }
        let (next, overflow) = sequence.addingReportingOverflow(1)
        guard !overflow, isValid(next) else { return nil }
        return next
    }
}

enum RemoteWorkerAccountMatcher {
    static func reference(for accountID: UUID) -> String {
        let canonical = "when-reset:synced-account:v1:\(accountID.uuidString.lowercased())"
        return Data(SHA256.hash(data: Data(canonical.utf8)))
            .base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    static func matches(_ candidate: RemoteWorkerAccountCandidate,
                        account: MonitoredAccount,
                        settings: AccountMonitorSettings) -> Bool {
        guard !account.isDemo, candidate.providerID == account.providerID else {
            return false
        }
        if let candidateReference = candidate.workerAccountReference,
           let localReference = settings.workerAccountReference {
            return candidateReference == localReference
        }
        guard let syncedAccountReference = candidate.syncedAccountReference else { return false }
        return syncedAccountReference == reference(for: account.id)
    }

    static func isAlreadyAttached(
        _ candidate: RemoteWorkerAccountCandidate,
        accounts: [MonitoredAccount],
        serverURL: String,
        settingsForAccount: (MonitoredAccount) -> AccountMonitorSettings
    ) -> Bool {
        accounts.contains { account in
            let settings = settingsForAccount(account)
            let usesWorker = account.remoteWorkerServerURL == serverURL
                || settings.selfHostedServerConsentURL == serverURL
            guard usesWorker else { return false }

            if account.remoteWorkerAccountID == candidate.remoteAccountID
                || settings.remoteWorkerAccountID == candidate.remoteAccountID {
                return true
            }

            guard let candidateReference = candidate.workerAccountReference,
                  settings.workerAccountReference == candidateReference else {
                return false
            }

            // A matching direct account that has only learned the Worker's stable reference
            // still needs the import call to attach its remote account ID. Remote-only accounts,
            // and direct accounts with an existing remote ID, are already attached.
            return account.isRemoteOnly
                || account.remoteWorkerAccountID != nil
                || settings.remoteWorkerAccountID != nil
        }
    }
}

enum PushServerClient {
    private static let smallResponseLimit = 16 * 1_024
    private static let accountResponseLimit = 1_048_576
    private static let errorResponseLimit = 4 * 1_024
    private static var apnsEnvironment: String {
        #if DEBUG
        "development"
        #else
        "production"
        #endif
    }

    private struct RegistrationRequest: Encodable {
        var deviceID: String
        var deviceSecret: String
        var apnsToken: String
        var apnsEnvironment: String

        enum CodingKeys: String, CodingKey {
            case deviceID = "device_id"
            case deviceSecret = "device_secret"
            case apnsToken = "apns_token"
            case apnsEnvironment = "apns_environment"
        }
    }

    private struct TokenRotationRequest: Encodable {
        var apnsToken: String
        var apnsEnvironment: String

        enum CodingKeys: String, CodingKey {
            case apnsToken = "apns_token"
            case apnsEnvironment = "apns_environment"
        }
    }

    private struct LinkMetadataResponse: Decodable {
        var version: Int
        var mode: String
        var topic: String
        var serverOrigin: String
        var displayName: String
        var expiresAt: TimeInterval

        enum CodingKeys: String, CodingKey {
            case version, mode, topic
            case serverOrigin = "server_origin"
            case displayName = "display_name"
            case expiresAt = "expires_at"
        }
    }

    private struct HealthResponse: Decodable {
        var ok: Bool
        var mode: String
        var topic: String
    }

    private struct AcknowledgementResponse: Decodable {
        var ok: Bool
    }

    private struct RemoteAccountsResponse: Decodable {
        var accounts: [RemoteWorkerAccountCandidate]
    }

    private struct RemoteAccountImportRequest: Encodable {
        var remoteAccountID: String
        var localAccountID: UUID

        enum CodingKeys: String, CodingKey {
            case remoteAccountID = "remote_account_id"
            case localAccountID = "local_account_id"
        }
    }

    private struct ImportedRemoteAccount: Decodable {
        var remoteAccountID: String
        var syncedAccountReference: String?
        var workerAccountReference: String?
        var localAccountID: UUID
        var providerID: ProviderID
        var displayName: String
        var plan: String?
        var metadata: WorkerAccountMetadata?
        var lastSuccessTimestamp: TimeInterval?
        var sessionStatus: WorkerSessionStatus?
        var sessionCheckedTimestamp: TimeInterval?
        var consentRevision: Int64?

        enum CodingKeys: String, CodingKey {
            case remoteAccountID = "remote_account_id"
            case syncedAccountReference = "synced_account_reference"
            case workerAccountReference = "account_reference"
            case localAccountID = "local_account_id"
            case providerID = "provider_id"
            case displayName = "display_name"
            case plan
            case metadata
            case lastSuccessTimestamp = "last_success_at"
            case sessionStatus = "session_status"
            case sessionCheckedTimestamp = "session_checked_at"
            case consentRevision = "consent_revision"
        }
    }

    private struct RemoteAccountImportResponse: Decodable {
        var account: ImportedRemoteAccount
    }

    private struct CredentialPayload: Encodable {
        var accessToken: String
        var refreshToken: String
        var idToken: String
        var expiresAt: TimeInterval?
        var monthlyBudget: Double?
        var currencyCode: String?

        enum CodingKeys: String, CodingKey {
            case accessToken = "access_token"
            case refreshToken = "refresh_token"
            case idToken = "id_token"
            case expiresAt = "expires_at"
            case monthlyBudget = "monthly_budget"
            case currencyCode = "currency_code"
        }

        init(_ credentials: AccountCredentials) {
            accessToken = credentials.accessToken
            refreshToken = credentials.refreshToken
            idToken = credentials.idToken
            expiresAt = credentials.expiresAt?.timeIntervalSince1970
            monthlyBudget = credentials.monthlyBudget
            currencyCode = credentials.currencyCode
        }

    }

    private struct AccountUploadRequest: Encodable {
        var providerID: String
        var workspaceID: String
        var displayName: String
        var plan: String?
        var metadata: WorkerAccountMetadata
        var refreshIntervalSeconds: Int
        var consentRevision: Int64
        var historyRetentionDays: Int
        var credentials: CredentialPayload
        var missingQuotas: [MissingQuotaPayload]

        enum CodingKeys: String, CodingKey {
            case providerID = "provider_id"
            case workspaceID = "workspace_id"
            case displayName = "display_name"
            case plan
            case metadata
            case refreshIntervalSeconds = "refresh_interval_seconds"
            case consentRevision = "consent_revision"
            case historyRetentionDays = "history_retention_days"
            case credentials
            case missingQuotas = "missing_quotas"
        }
    }

    private struct HistoryUploadRequest: Encodable {
        var history: [HistoryUploadPoint]
    }

    private struct AccountPolicyUpdateRequest: Encodable {
        var refreshIntervalSeconds: Int
        var historyRetentionDays: Int

        enum CodingKeys: String, CodingKey {
            case refreshIntervalSeconds = "refresh_interval_seconds"
            case historyRetentionDays = "history_retention_days"
        }
    }

    private struct HistoryUploadPoint: Encodable {
        var rowTag: String
        var providerID: ProviderID
        var metricID: String
        var metricTitle: String
        var kind: UsageWindowKind?
        var windowMinutes: Int?
        var remainingPercent: Double
        var recordedAt: TimeInterval
        var resetsAt: TimeInterval
        var secondsUntilReset: TimeInterval
        var plan: String?

        enum CodingKeys: String, CodingKey {
            case rowTag = "row_tag"
            case providerID = "provider_id"
            case metricID = "metric_id"
            case metricTitle = "metric_title"
            case kind
            case windowMinutes = "window_minutes"
            case remainingPercent = "remaining_percent"
            case recordedAt = "recorded_at"
            case resetsAt = "resets_at"
            case secondsUntilReset = "seconds_until_reset"
            case plan
        }

        init(_ point: UsageHistoryPoint) {
            rowTag = point.resolvedRowTag
            providerID = point.providerID
            metricID = point.metricID
            metricTitle = point.metricTitle
            kind = point.kind
            windowMinutes = point.windowMinutes
            remainingPercent = point.remainingPercent
            recordedAt = point.recordedAt.timeIntervalSince1970
            resetsAt = point.resetsAt.timeIntervalSince1970
            secondsUntilReset = point.secondsUntilReset
            plan = point.plan
        }
    }

    private struct HistoryUploadResponse: Decodable {
        var accepted: Int
        var deduplicated: Int
    }

    struct DeviceUsageSourceResponse: Decodable, Equatable, Sendable {
        var ok: Bool
        var consentRevision: Int64
        var nextSequence: Int64

        enum CodingKeys: String, CodingKey {
            case ok
            case consentRevision = "consent_revision"
            case nextSequence = "next_sequence"
        }
    }

    private struct DeviceUsageSourceRequest: Encodable {
        var providerID: ProviderID
        var displayName: String
        var refreshIntervalSeconds: Int
        var historyRetentionDays: Int
        var consentRevision: Int64

        enum CodingKeys: String, CodingKey {
            case providerID = "provider_id"
            case displayName = "display_name"
            case refreshIntervalSeconds = "refresh_interval_seconds"
            case historyRetentionDays = "history_retention_days"
            case consentRevision = "consent_revision"
        }
    }

    private struct DeviceUsageUploadResponse: Decodable {
        var accepted: Bool
        var sequence: Int64
    }

    private struct DeviceUsageUploadRequest: Encodable {
        var consentRevision: Int64
        var sequence: Int64
        var observedAt: TimeInterval
        var snapshot: DeviceUsageSnapshotPayload

        enum CodingKeys: String, CodingKey {
            case consentRevision = "consent_revision"
            case sequence
            case observedAt = "observed_at"
            case snapshot
        }
    }

    /// A credential-free allowlist. Never encode `UsageSnapshot` directly: it includes local
    /// account identifiers and presentation metadata that the Worker does not need.
    private struct DeviceUsageSnapshotPayload: Encodable {
        var providerID: ProviderID
        var plan: String?
        private var windows: [DeviceUsageWindow]
        var availableResetCount: Int
        private var resetCredits: [DeviceUsageResetCredit]
        var resetCreditsAuthoritative = true
        private var apiBalance: DeviceUsageAPIBalance?

        enum CodingKeys: String, CodingKey {
            case providerID = "provider_id"
            case plan, windows
            case availableResetCount = "available_reset_count"
            case resetCredits = "reset_credits"
            case resetCreditsAuthoritative = "reset_credits_authoritative"
            case apiBalance = "api_balance"
        }

        init(snapshot: UsageSnapshot, providerID: ProviderID) throws {
            let currentWindows = snapshot.usageWindows.filter {
                $0.resetsAt.timeIntervalSince(snapshot.fetchedAt) >= -5 * 60
            }
            guard snapshot.accountProviderID == nil || snapshot.accountProviderID == providerID,
                  currentWindows.count <= 32,
                  snapshot.resetCredits.count <= 32 else {
                throw PushServerError.invalidResponse
            }
            self.providerID = providerID
            plan = Self.bounded(snapshot.plan, maximum: 200)
            windows = currentWindows.enumerated().map {
                DeviceUsageWindow(offset: $0.offset, element: $0.element)
            }
            availableResetCount = max(0, min(1_000, snapshot.availableResetCount))
            resetCredits = snapshot.resetCredits.map(DeviceUsageResetCredit.init)
            apiBalance = try snapshot.apiBalance.map { try DeviceUsageAPIBalance($0) }
        }

        func encode(to encoder: Encoder) throws {
            var values = encoder.container(keyedBy: CodingKeys.self)
            try values.encode(providerID, forKey: .providerID)
            if let plan { try values.encode(plan, forKey: .plan) }
            else { try values.encodeNil(forKey: .plan) }
            try values.encode(windows, forKey: .windows)
            try values.encode(availableResetCount, forKey: .availableResetCount)
            try values.encode(resetCredits, forKey: .resetCredits)
            try values.encode(resetCreditsAuthoritative, forKey: .resetCreditsAuthoritative)
            try values.encodeIfPresent(apiBalance, forKey: .apiBalance)
        }

        private static func bounded(_ value: String?, maximum: Int) -> String? {
            guard let value else { return nil }
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : String(trimmed.prefix(maximum))
        }

        private struct DeviceUsageWindow: Encodable {
            var position: Int
            var metricID: String
            var title: String
            var kind: UsageWindowKind?
            var windowMinutes: Int?
            var remainingPercent: Double
            var resetsAt: TimeInterval

            enum CodingKeys: String, CodingKey {
                case position
                case metricID = "metric_id"
                case title, kind
                case windowMinutes = "window_minutes"
                case remainingPercent = "remaining_percent"
                case resetsAt = "resets_at"
            }

            init(offset: Int, element window: UsageWindow) {
                position = offset
                metricID = String(window.metricID.prefix(128))
                title = String(window.displayTitle.prefix(128))
                kind = window.kind
                windowMinutes = window.windowMinutes
                remainingPercent = max(0, min(100, window.remainingPercent))
                resetsAt = window.resetsAt.timeIntervalSince1970
            }

            func encode(to encoder: Encoder) throws {
                var values = encoder.container(keyedBy: CodingKeys.self)
                try values.encode(position, forKey: .position)
                try values.encode(metricID, forKey: .metricID)
                try values.encode(title, forKey: .title)
                if let kind { try values.encode(kind, forKey: .kind) }
                else { try values.encodeNil(forKey: .kind) }
                if let windowMinutes { try values.encode(windowMinutes, forKey: .windowMinutes) }
                else { try values.encodeNil(forKey: .windowMinutes) }
                try values.encode(remainingPercent, forKey: .remainingPercent)
                try values.encode(resetsAt, forKey: .resetsAt)
            }
        }

        private struct DeviceUsageResetCredit: Encodable {
            var expiresAt: TimeInterval?
            var status: String?
            var grantedAt: TimeInterval?

            enum CodingKeys: String, CodingKey {
                case status
                case expiresAt = "expires_at"
                case grantedAt = "granted_at"
            }

            init(_ credit: ResetCredit) {
                expiresAt = credit.expiresAt?.timeIntervalSince1970
                status = DeviceUsageSnapshotPayload.bounded(credit.status, maximum: 64)
                grantedAt = credit.grantedAt?.timeIntervalSince1970
            }

            func encode(to encoder: Encoder) throws {
                var values = encoder.container(keyedBy: CodingKeys.self)
                if let expiresAt { try values.encode(expiresAt, forKey: .expiresAt) }
                else { try values.encodeNil(forKey: .expiresAt) }
                if let status { try values.encode(status, forKey: .status) }
                else { try values.encodeNil(forKey: .status) }
                if let grantedAt { try values.encode(grantedAt, forKey: .grantedAt) }
                else { try values.encodeNil(forKey: .grantedAt) }
            }
        }

        private struct DeviceUsageAPIBalance: Encodable {
            var title: String
            var currencyCode: String
            var spent: Double
            var limit: Double?
            var remaining: Double?
            var periodStart: TimeInterval?
            var periodEnd: TimeInterval?
            var accessExpiresAt: TimeInterval?
            var isUnlimited: Bool
            var kind: APIBalanceKind?
            var unitLabel: String?

            enum CodingKeys: String, CodingKey {
                case title, spent, limit, remaining, kind
                case currencyCode = "currency_code"
                case periodStart = "period_start"
                case periodEnd = "period_end"
                case accessExpiresAt = "access_expires_at"
                case isUnlimited = "is_unlimited"
                case unitLabel = "unit_label"
            }

            init(_ balance: APIBalance) throws {
                let currency = balance.currencyCode
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .uppercased()
                guard currency.range(
                    of: #"^[A-Z]{3,8}$"#,
                    options: .regularExpression
                ) != nil,
                      balance.spent.isFinite,
                      balance.limit?.isFinite != false,
                      balance.remaining?.isFinite != false else {
                    throw PushServerError.invalidResponse
                }
                title = String(balance.title.prefix(128))
                currencyCode = currency
                spent = balance.spent
                limit = balance.limit
                remaining = balance.remaining
                periodStart = balance.periodStart?.timeIntervalSince1970
                periodEnd = balance.periodEnd?.timeIntervalSince1970
                accessExpiresAt = balance.accessExpiresAt?.timeIntervalSince1970
                isUnlimited = balance.isUnlimited
                kind = balance.kind
                unitLabel = balance.unitLabel.map { String($0.prefix(64)) }
            }
        }
    }

    private struct MissingQuotaPayload: Encodable {
        var metricID: String
        var title: String
        var kind: UsageWindowKind?
        var windowMinutes: Int?
        var resetsAt: TimeInterval?

        enum CodingKeys: String, CodingKey {
            case metricID = "metric_id"
            case title, kind
            case windowMinutes = "window_minutes"
            case resetsAt = "resets_at"
        }

        init(_ descriptor: ServerMissingQuotaDescriptor) {
            metricID = descriptor.metricID
            title = descriptor.title
            kind = descriptor.kind
            windowMinutes = descriptor.windowMinutes
            resetsAt = descriptor.resetsAt?.timeIntervalSince1970
        }
    }

    private struct RemoteWindow: Decodable {
        var position: Int
        var metricID: String
        var title: String
        var kind: UsageWindowKind?
        var windowMinutes: Int?
        var remainingPercent: Double
        var resetsAt: TimeInterval

        enum CodingKeys: String, CodingKey {
            case position
            case metricID = "metric_id"
            case title, kind
            case windowMinutes = "window_minutes"
            case remainingPercent = "remaining_percent"
            case resetsAt = "resets_at"
        }

        var usageWindow: UsageWindow {
            UsageWindow(
                title: title,
                usedPercent: 100 - max(0, min(100, remainingPercent)),
                resetsAt: Date(timeIntervalSince1970: resetsAt),
                windowMinutes: windowMinutes,
                kind: kind,
                identifier: metricID
            )
        }
    }

    private struct RemoteResetCredit: Decodable {
        var id: String
        var expiresAt: TimeInterval?
        var status: String?
        var grantedAt: TimeInterval?

        enum CodingKeys: String, CodingKey {
            case id, status
            case expiresAt = "expires_at"
            case grantedAt = "granted_at"
        }

        var resetCredit: ResetCredit {
            ResetCredit(
                id: id,
                expiresAt: expiresAt.map(Date.init(timeIntervalSince1970:)),
                status: status,
                grantedAt: grantedAt.map(Date.init(timeIntervalSince1970:))
            )
        }
    }

    private struct RemoteSnapshot: Decodable {
        var providerID: ProviderID
        var plan: String?
        var fetchedAt: TimeInterval
        var windows: [RemoteWindow]
        var availableResetCount: Int
        var resetCredits: [RemoteResetCredit]
        var apiBalance: RemoteAPIBalance?

        enum CodingKeys: String, CodingKey {
            case providerID = "provider_id"
            case plan
            case fetchedAt = "fetched_at"
            case windows
            case availableResetCount = "available_reset_count"
            case resetCredits = "reset_credits"
            case apiBalance = "api_balance"
        }

        func usageSnapshot(account: MonitoredAccount) -> UsageSnapshot? {
            guard providerID == account.providerID else { return nil }
            let sorted = windows.sorted { $0.position < $1.position }
            let converted = sorted.map(\.usageWindow)
            return UsageSnapshot(
                accountID: account.id,
                providerName: account.providerID.displayName,
                accountName: account.resolvedDisplayName,
                accountProviderID: account.providerID,
                accountSymbolName: account.customSymbolName,
                plan: plan ?? account.plan,
                primary: converted.first,
                secondary: converted.dropFirst().first,
                availableResetCount: availableResetCount,
                resetCredits: resetCredits.map(\.resetCredit),
                fetchedAt: Date(timeIntervalSince1970: fetchedAt),
                extraWindows: converted.count > 2 ? Array(converted.dropFirst(2)) : nil,
                apiBalance: apiBalance?.apiBalance
            )
        }
    }

    private struct RemoteAPIBalance: Decodable {
        var title: String
        var currencyCode: String
        var spent: Double
        var limit: Double?
        var remaining: Double?
        var periodStart: TimeInterval?
        var periodEnd: TimeInterval?
        var accessExpiresAt: TimeInterval?
        var isUnlimited: Bool
        var kind: APIBalanceKind?
        var unitLabel: String?

        enum CodingKeys: String, CodingKey {
            case title, spent, limit, remaining
            case currencyCode = "currency_code"
            case periodStart = "period_start"
            case periodEnd = "period_end"
            case accessExpiresAt = "access_expires_at"
            case isUnlimited = "is_unlimited"
            case kind
            case unitLabel = "unit_label"
        }

        var apiBalance: APIBalance {
            APIBalance(
                title: title,
                currencyCode: currencyCode,
                spent: spent,
                limit: limit,
                remaining: remaining,
                periodStart: periodStart.map(Date.init(timeIntervalSince1970:)),
                periodEnd: periodEnd.map(Date.init(timeIntervalSince1970:)),
                accessExpiresAt: accessExpiresAt.map(Date.init(timeIntervalSince1970:)),
                isUnlimited: isUnlimited,
                kind: kind,
                unitLabel: unitLabel
            )
        }
    }

    private struct RemoteHistoryPoint: Decodable {
        var rowTag: String?
        var providerID: ProviderID
        var metricID: String
        var metricTitle: String
        var kind: UsageWindowKind?
        var windowMinutes: Int?
        var remainingPercent: Double
        var recordedAt: TimeInterval
        var resetsAt: TimeInterval
        var secondsUntilReset: TimeInterval
        var plan: String?
        var historySource: String?

        enum CodingKeys: String, CodingKey {
            case rowTag = "row_tag"
            case providerID = "provider_id"
            case metricID = "metric_id"
            case metricTitle = "metric_title"
            case kind
            case windowMinutes = "window_minutes"
            case remainingPercent = "remaining_percent"
            case recordedAt = "recorded_at"
            case resetsAt = "resets_at"
            case secondsUntilReset = "seconds_until_reset"
            case plan
            case historySource = "history_source"
        }

        func historyPoint(accountID: UUID) -> UsageHistoryPoint {
            UsageHistoryPoint(
                accountID: accountID,
                providerID: providerID,
                metricID: metricID,
                metricTitle: metricTitle,
                kind: kind,
                windowMinutes: windowMinutes,
                remainingPercent: remainingPercent,
                recordedAt: Date(timeIntervalSince1970: recordedAt),
                resetsAt: Date(timeIntervalSince1970: resetsAt),
                secondsUntilReset: secondsUntilReset,
                source: .server,
                plan: plan,
                rowTag: rowTag
            )
        }
    }

    private struct AccountSyncPage: Decodable {
        var consentRevision: Int64
        var snapshot: RemoteSnapshot?
        var metadata: WorkerAccountMetadata?
        var history: [RemoteHistoryPoint]
        var nextCursor: String?
        var workerAccountReference: String?
        var lastSuccessAt: TimeInterval?
        var lastError: String?
        var sessionStatus: WorkerSessionStatus?
        var sessionCheckedAt: TimeInterval?
        var historyRetentionDays: Int?

        enum CodingKeys: String, CodingKey {
            case snapshot, metadata, history
            case consentRevision = "consent_revision"
            case nextCursor = "next_cursor"
            case workerAccountReference = "account_reference"
            case lastSuccessAt = "last_success_at"
            case lastError = "last_error"
            case sessionStatus = "session_status"
            case sessionCheckedAt = "session_checked_at"
            case historyRetentionDays = "history_retention_days"
        }
    }

    static func validate(_ draft: WorkerLinkDraft, now: Date = .now) async throws
        -> WorkerLinkMetadata {
        switch draft {
        case let .pairing(payload):
            try payload.validateNotExpired(at: now)
            var request = URLRequest(
                url: payload.serverURL.appending(
                    path: "v1/link-sessions/\(payload.sessionID.uuidString.lowercased())"
                )
            )
            request.timeoutInterval = 15
            request.setValue("Bearer \(payload.token)", forHTTPHeaderField: "Authorization")
            request.setValue("no-store", forHTTPHeaderField: "Cache-Control")
            let (data, response) = try await send(
                request,
                maximumResponseBytes: smallResponseLimit,
                acceptedStatusCodes: [200]
            )
            guard response.url == request.url,
                  response.value(forHTTPHeaderField: "Cache-Control")?
                    .lowercased().contains("no-store") == true,
                  let metadata = try? JSONDecoder().decode(LinkMetadataResponse.self, from: data),
                  metadata.version == 1,
                  metadata.mode == "self_hosted",
                  metadata.topic == "ad.neko.when",
                  metadata.displayName.utf8.count <= 128,
                  !metadata.displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  metadata.expiresAt.isFinite else {
                throw PushServerError.invalidResponse
            }
            let reportedOrigin = try PushServerConfiguration.normalizedServerOrigin(
                metadata.serverOrigin
            )
            let reportedExpiry = Date(timeIntervalSince1970: metadata.expiresAt)
            guard reportedOrigin == payload.serverURL,
                  metadata.expiresAt == payload.expiresAt.timeIntervalSince1970 else {
                throw PushServerError.workerIdentityMismatch
            }
            guard reportedExpiry > now else { throw PushServerError.expiredWorkerLink }
            return WorkerLinkMetadata(
                displayName: metadata.displayName,
                serverURL: reportedOrigin,
                expiresAt: reportedExpiry
            )

        case let .manual(_, serverURL, accessKey):
            guard accessKey.trimmingCharacters(in: .whitespacesAndNewlines).count >= 32 else {
                throw PushServerError.missingServerAccessKey
            }
            var request = URLRequest(url: serverURL.appending(path: "healthz"))
            request.timeoutInterval = 15
            request.setValue("no-store", forHTTPHeaderField: "Cache-Control")
            let (data, response) = try await send(
                request,
                maximumResponseBytes: smallResponseLimit,
                acceptedStatusCodes: [200]
            )
            guard response.url == request.url,
                  let health = try? JSONDecoder().decode(HealthResponse.self, from: data),
                  health.ok,
                  health.mode == "self_hosted",
                  health.topic == "ad.neko.when" else {
                throw PushServerError.workerIdentityMismatch
            }
            return WorkerLinkMetadata(
                displayName: serverURL.host ?? serverURL.absoluteString,
                serverURL: serverURL,
                expiresAt: nil
            )
        }
    }

    static func register(settings: PushServerSettings, deviceToken: Data,
                         enrollment: PushServerEnrollment? = nil) async throws {
        guard let serverURL = try settings.resolvedServerURL() else { return }
        let existing = try? KeychainStore.loadPushRegistration(for: serverURL)
        if case let .pairing(payload) = enrollment {
            guard payload.serverURL == serverURL else {
                throw PushServerError.workerIdentityMismatch
            }
            let credentials: PushRegistrationCredentials
            if let existing {
                credentials = existing
            } else {
                credentials = try registrationCredentials(for: serverURL)
            }
            do {
                try await claim(payload, credentials: credentials, deviceToken: deviceToken)
            } catch let error as PushServerError where error.httpStatus == 409 {
                // A lost 201 response leaves the one-time session consumed. Prove that this
                // device owns the resulting registration before treating the retry as success.
                try await rotateDeviceToken(
                    serverURL: serverURL,
                    credentials: credentials,
                    deviceToken: deviceToken
                )
            }
            return
        }
        if let existing {
            do {
                try await rotateDeviceToken(
                    serverURL: serverURL,
                    credentials: existing,
                    deviceToken: deviceToken
                )
                return
            } catch let error as PushServerError
                where (error.httpStatus == 401 || error.httpStatus == 404) && enrollment != nil {
                // The app may have created its local registration before the Worker accepted it.
                // Continue with the explicitly confirmed enrollment method below.
            }
        }

        let credentials: PushRegistrationCredentials
        if let existing {
            credentials = existing
        } else {
            credentials = try registrationCredentials(for: serverURL)
        }
        let resolvedEnrollment: PushServerEnrollment?
        if let enrollment {
            resolvedEnrollment = enrollment
        } else if let key = try? KeychainStore.loadPushServerAccessKey(for: serverURL) {
            resolvedEnrollment = .accessKey(key)
        } else {
            resolvedEnrollment = nil
        }

        switch resolvedEnrollment {
        case .pairing:
            throw PushServerError.invalidWorkerLink
        case let .accessKey(key):
            try await registerWithAccessKey(
                key,
                serverURL: serverURL,
                credentials: credentials,
                deviceToken: deviceToken
            )
        case nil:
            throw PushServerError.missingServerAccessKey
        }
    }

    static func claim(_ payload: WorkerLinkPayload, credentials: PushRegistrationCredentials,
                      deviceToken: Data, now: Date = .now) async throws {
        try payload.validateNotExpired(at: now)
        guard credentials.serverURL == payload.serverURL else {
            throw PushServerError.workerIdentityMismatch
        }
        var request = URLRequest(
            url: payload.serverURL.appending(
                path: "v1/link-sessions/\(payload.sessionID.uuidString.lowercased())/claim"
            )
        )
        request.httpMethod = "POST"
        request.timeoutInterval = 15
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(payload.token)", forHTTPHeaderField: "Authorization")
        request.setValue("no-store", forHTTPHeaderField: "Cache-Control")
        request.httpBody = try JSONEncoder().encode(RegistrationRequest(
            deviceID: credentials.deviceID.uuidString.lowercased(),
            deviceSecret: credentials.deviceSecret,
            apnsToken: deviceToken.hexadecimalString,
            apnsEnvironment: apnsEnvironment
        ))
        let (data, _) = try await send(
            request,
            maximumResponseBytes: smallResponseLimit,
            acceptedStatusCodes: [201]
        )
        guard (try? JSONDecoder().decode(AcknowledgementResponse.self, from: data))?.ok == true else {
            throw PushServerError.invalidResponse
        }
    }

    private static func registerWithAccessKey(
        _ key: String,
        serverURL: URL,
        credentials: PushRegistrationCredentials,
        deviceToken: Data
    ) async throws {
        let normalizedKey = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalizedKey.count >= 32 else { throw PushServerError.missingServerAccessKey }
        var request = URLRequest(url: serverURL.appending(path: "v1/devices"))
        request.httpMethod = "POST"
        request.timeoutInterval = 15
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(normalizedKey, forHTTPHeaderField: "X-When-Reset-Server-Key")
        request.setValue("no-store", forHTTPHeaderField: "Cache-Control")
        request.httpBody = try JSONEncoder().encode(RegistrationRequest(
            deviceID: credentials.deviceID.uuidString.lowercased(),
            deviceSecret: credentials.deviceSecret,
            apnsToken: deviceToken.hexadecimalString,
            apnsEnvironment: apnsEnvironment
        ))
        let (data, _) = try await send(
            request,
            maximumResponseBytes: smallResponseLimit,
            acceptedStatusCodes: [200, 201]
        )
        guard data.isEmpty
                || (try? JSONDecoder().decode(AcknowledgementResponse.self, from: data))?.ok == true else {
            throw PushServerError.invalidResponse
        }
    }

    private static func rotateDeviceToken(
        serverURL: URL,
        credentials: PushRegistrationCredentials,
        deviceToken: Data
    ) async throws {
        var request = URLRequest(
            url: serverURL.appending(
                path: "v1/devices/\(credentials.deviceID.uuidString.lowercased())"
            )
        )
        request.httpMethod = "PUT"
        request.timeoutInterval = 15
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(credentials.deviceSecret)", forHTTPHeaderField: "Authorization")
        request.setValue("no-store", forHTTPHeaderField: "Cache-Control")
        request.httpBody = try JSONEncoder().encode(TokenRotationRequest(
            apnsToken: deviceToken.hexadecimalString,
            apnsEnvironment: apnsEnvironment
        ))
        let (data, _) = try await send(
            request,
            maximumResponseBytes: smallResponseLimit,
            acceptedStatusCodes: [200]
        )
        guard (try? JSONDecoder().decode(AcknowledgementResponse.self, from: data))?.ok == true else {
            throw PushServerError.invalidResponse
        }
    }

    static func unregister(settings: PushServerSettings) async throws {
        guard let serverURL = try settings.resolvedServerURL() else { return }
        guard let credentials = try? KeychainStore.loadPushRegistration(for: serverURL) else {
            KeychainStore.deletePushServerAccessKey(for: serverURL)
            return
        }
        var request = URLRequest(
            url: serverURL.appending(path: "v1/devices/\(credentials.deviceID.uuidString.lowercased())")
        )
        request.httpMethod = "DELETE"
        request.timeoutInterval = 15
        request.setValue("Bearer \(credentials.deviceSecret)", forHTTPHeaderField: "Authorization")
        do {
            _ = try await send(request)
        } catch let error as PushServerError where error.httpStatus == 404 {
            // The Worker already removed this registration.
        }
        KeychainStore.deletePushRegistration(for: serverURL)
        KeychainStore.deletePushServerAccessKey(for: serverURL)
    }

    static func requestTestRefresh(settings: PushServerSettings) async throws {
        guard let serverURL = try settings.resolvedServerURL(),
              let credentials = try? KeychainStore.loadPushRegistration(for: serverURL) else {
            throw PushServerError.missingRegistration
        }
        var request = URLRequest(
            url: serverURL.appending(
                path: "v1/devices/\(credentials.deviceID.uuidString.lowercased())/refresh"
            )
        )
        request.httpMethod = "POST"
        request.timeoutInterval = 15
        request.setValue("Bearer \(credentials.deviceSecret)", forHTTPHeaderField: "Authorization")
        _ = try await send(request)
    }

    static func remoteAccounts(settings: PushServerSettings) async throws
        -> [RemoteWorkerAccountCandidate] {
        let (serverURL, registration) = try monitoringContext(settings: settings)
        var request = URLRequest(url: remoteAccountsURL(
            serverURL: serverURL,
            registration: registration
        ))
        request.timeoutInterval = 20
        request.setValue("Bearer \(registration.deviceSecret)",
                         forHTTPHeaderField: "Authorization")
        request.setValue("no-store", forHTTPHeaderField: "Cache-Control")
        let (data, _) = try await send(
            request,
            maximumResponseBytes: accountResponseLimit,
            acceptedStatusCodes: [200]
        )
        let response = try JSONDecoder().decode(RemoteAccountsResponse.self, from: data)
        guard response.accounts.count <= 50,
              Set(response.accounts.map(\.remoteAccountID)).count == response.accounts.count,
              response.accounts.allSatisfy({
                  $0.remoteAccountID.count == 43
                    && ($0.syncedAccountReference == nil
                        || $0.syncedAccountReference?.range(
                            of: #"^[A-Za-z0-9_-]{43}$"#,
                            options: .regularExpression
                        ) != nil)
                    && ($0.workerAccountReference == nil
                        || $0.workerAccountReference?.range(
                            of: #"^[A-Za-z0-9_-]{43}$"#,
                            options: .regularExpression
                        ) != nil)
                    && !$0.displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
              }) else {
            throw PushServerError.invalidResponse
        }
        return response.accounts
    }

    static func hasStoredRegistration(settings: PushServerSettings) -> Bool {
        guard settings.mode != .disabled,
              let serverURL = try? settings.resolvedServerURL(),
              let registration = try? KeychainStore.loadPushRegistration(for: serverURL) else {
            return false
        }
        return registration.serverURL == serverURL
    }

    static func importRemoteAccount(
        settings: PushServerSettings,
        candidate: RemoteWorkerAccountCandidate,
        localAccountID: UUID
    ) async throws -> RemoteWorkerAccountImportResult {
        let (serverURL, registration) = try monitoringContext(settings: settings)
        var request = URLRequest(url: remoteAccountsURL(
            serverURL: serverURL,
            registration: registration
        ))
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(registration.deviceSecret)",
                         forHTTPHeaderField: "Authorization")
        request.setValue("no-store", forHTTPHeaderField: "Cache-Control")
        request.httpBody = try JSONEncoder().encode(RemoteAccountImportRequest(
            remoteAccountID: candidate.remoteAccountID,
            localAccountID: localAccountID
        ))
        let (data, _) = try await send(
            request,
            maximumResponseBytes: smallResponseLimit,
            acceptedStatusCodes: [200, 201]
        )
        return try decodeRemoteAccountImportResponse(
            data,
            candidate: candidate,
            localAccountID: localAccountID
        )
    }

    static func decodeRemoteAccountImportResponse(
        _ data: Data,
        candidate: RemoteWorkerAccountCandidate,
        localAccountID: UUID
    ) throws -> RemoteWorkerAccountImportResult {
        let imported = try JSONDecoder().decode(
            RemoteAccountImportResponse.self,
            from: data
        ).account
        guard imported.remoteAccountID == candidate.remoteAccountID,
              imported.localAccountID == localAccountID,
              imported.providerID == candidate.providerID,
              (candidate.syncedAccountReference == nil
                || imported.syncedAccountReference == candidate.syncedAccountReference),
              (candidate.workerAccountReference == nil
                || imported.workerAccountReference == candidate.workerAccountReference) else {
            throw PushServerError.invalidResponse
        }
        let consentRevision = try ServerConsentRevisionPolicy.importedRevision(
            imported.consentRevision
        )
        let account = RemoteWorkerAccountCandidate(
            remoteAccountID: imported.remoteAccountID,
            syncedAccountReference: imported.syncedAccountReference,
            workerAccountReference: imported.workerAccountReference,
            providerID: imported.providerID,
            displayName: imported.displayName,
            plan: imported.plan,
            metadata: imported.metadata,
            lastSuccessTimestamp: imported.lastSuccessTimestamp,
            sessionStatus: imported.sessionStatus,
            sessionCheckedTimestamp: imported.sessionCheckedTimestamp
        )
        return RemoteWorkerAccountImportResult(
            account: account,
            consentRevision: consentRevision
        )
    }

    static func restoreRemoteAccount(
        settings: PushServerSettings,
        account: MonitoredAccount,
        remoteAccountID: String
    ) async throws {
        guard remoteAccountID.count == 43 else {
            throw PushServerError.remoteAccountUnavailable
        }
        _ = try await importRemoteAccount(
            settings: settings,
            candidate: RemoteWorkerAccountCandidate(
                remoteAccountID: remoteAccountID,
                providerID: account.providerID,
                displayName: account.displayName,
                plan: account.plan,
                metadata: WorkerAccountMetadata(
                    name: account.profileName,
                    email: account.email,
                    plan: account.plan,
                    planExpiresAt: account.planExpiresAt,
                    trialExpiresAt: account.trialExpiresAt
                ),
                lastSuccessTimestamp: nil
            ),
            localAccountID: account.id
        )
    }

    static func uploadAccount(settings: PushServerSettings, account: MonitoredAccount,
                              credentials: AccountCredentials,
                              missingQuotas: [ServerMissingQuotaDescriptor],
                              consentRevision: Int64,
                              replacingRemoteCredential: Bool = false) async throws
        -> ServerAccountSyncResult {
        guard consentRevision > 0 else { throw PushServerError.accountMonitoringUnavailable }
        let (serverURL, registration) = try monitoringContext(settings: settings)
        let interval = settings.serverMonitoringInterval.timeInterval
            ?? RefreshInterval.tenMinutes.timeInterval!
        var request = URLRequest(url: accountURL(serverURL: serverURL,
                                                 registration: registration,
                                                 accountID: account.id))
        request.httpMethod = "PUT"
        request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("no-store", forHTTPHeaderField: "Cache-Control")
        request.setValue("Bearer \(registration.deviceSecret)", forHTTPHeaderField: "Authorization")
        if replacingRemoteCredential {
            request.setValue(
                "replace-remote",
                forHTTPHeaderField: "X-When-Reset-Credential-Update"
            )
        }
        request.httpBody = try JSONEncoder().encode(AccountUploadRequest(
            providerID: account.providerID.rawValue,
            workspaceID: account.workspaceID,
            displayName: account.resolvedDisplayName,
            plan: account.plan,
            metadata: WorkerAccountMetadata(
                name: account.profileName,
                email: account.email,
                plan: account.plan,
                planExpiresAt: account.planExpiresAt,
                trialExpiresAt: account.trialExpiresAt
            ),
            refreshIntervalSeconds: Int(interval),
            consentRevision: consentRevision,
            historyRetentionDays: settings.historyRetention.rawValue,
            credentials: CredentialPayload(credentials),
            missingQuotas: missingQuotas.map(MissingQuotaPayload.init)
        ))
        let (data, _) = try await send(request)
        return try decodeAccountResponse(data, account: account)
    }

    static func uploadHistory(
        settings: PushServerSettings,
        account: MonitoredAccount,
        points: [UsageHistoryPoint]
    ) async throws -> Int {
        guard !points.isEmpty else { return 0 }
        let (serverURL, registration) = try monitoringContext(settings: settings)
        var uploaded = 0
        for offset in stride(from: 0, to: points.count, by: 250) {
            let end = min(offset + 250, points.count)
            var request = URLRequest(
                url: accountURL(
                    serverURL: serverURL,
                    registration: registration,
                    accountID: account.id
                ).appending(path: "history")
            )
            request.httpMethod = "POST"
            request.timeoutInterval = 30
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("no-store", forHTTPHeaderField: "Cache-Control")
            request.setValue(
                "Bearer \(registration.deviceSecret)",
                forHTTPHeaderField: "Authorization"
            )
            request.httpBody = try JSONEncoder().encode(HistoryUploadRequest(
                history: points[offset..<end].map(HistoryUploadPoint.init)
            ))
            let (data, _) = try await send(
                request,
                maximumResponseBytes: smallResponseLimit,
                acceptedStatusCodes: [200]
            )
            let response = try JSONDecoder().decode(HistoryUploadResponse.self, from: data)
            guard response.accepted >= 0,
                  response.deduplicated >= 0,
                  response.accepted + response.deduplicated == end - offset else {
                throw PushServerError.invalidResponse
            }
            uploaded += response.accepted
        }
        return uploaded
    }

    static func enableDeviceUsageUploads(
        settings: PushServerSettings,
        account: MonitoredAccount,
        consentRevision: Int64,
        refreshInterval: RefreshInterval
    ) async throws -> DeviceUsageSourceResponse {
        guard consentRevision > 0,
              !account.isDemo,
              !account.isRemoteOnly else {
            throw PushServerError.accountMonitoringUnavailable
        }
        let (serverURL, registration) = try monitoringContext(settings: settings)
        let interval = Int(refreshInterval.timeInterval ?? 0)
        var request = URLRequest(
            url: accountURL(
                serverURL: serverURL,
                registration: registration,
                accountID: account.id
            ).appending(path: "snapshots")
        )
        request.httpMethod = "PUT"
        request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("no-store", forHTTPHeaderField: "Cache-Control")
        request.setValue(
            "Bearer \(registration.deviceSecret)",
            forHTTPHeaderField: "Authorization"
        )
        request.httpBody = try JSONEncoder().encode(DeviceUsageSourceRequest(
            providerID: account.providerID,
            displayName: String(account.resolvedDisplayName.prefix(128)),
            refreshIntervalSeconds: interval,
            historyRetentionDays: settings.historyRetention.rawValue,
            consentRevision: consentRevision
        ))
        let (data, _) = try await send(
            request,
            maximumResponseBytes: smallResponseLimit,
            acceptedStatusCodes: [200, 201]
        )
        let response = try JSONDecoder().decode(DeviceUsageSourceResponse.self, from: data)
        guard response.ok,
              response.consentRevision == consentRevision,
              DeviceUsageSequencePolicy.isValid(response.nextSequence) else {
            throw PushServerError.invalidResponse
        }
        return response
    }

    static func uploadDeviceUsageSnapshot(
        settings: PushServerSettings,
        account: MonitoredAccount,
        snapshot: UsageSnapshot,
        consentRevision: Int64,
        sequence: Int64
    ) async throws -> Int64 {
        guard consentRevision > 0,
              DeviceUsageSequencePolicy.isValid(sequence),
              let nextSequence = DeviceUsageSequencePolicy.next(after: sequence),
              snapshot.accountID == account.id,
              !account.isDemo,
              !account.isRemoteOnly else {
            throw PushServerError.invalidResponse
        }
        let (serverURL, registration) = try monitoringContext(settings: settings)
        var request = URLRequest(
            url: accountURL(
                serverURL: serverURL,
                registration: registration,
                accountID: account.id
            ).appending(path: "snapshots")
        )
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("no-store", forHTTPHeaderField: "Cache-Control")
        request.setValue(
            "Bearer \(registration.deviceSecret)",
            forHTTPHeaderField: "Authorization"
        )
        request.httpBody = try deviceUsageSnapshotBody(
            account: account,
            snapshot: snapshot,
            consentRevision: consentRevision,
            sequence: sequence
        )
        let (data, _) = try await send(
            request,
            maximumResponseBytes: smallResponseLimit,
            acceptedStatusCodes: [200, 201]
        )
        let response = try JSONDecoder().decode(DeviceUsageUploadResponse.self, from: data)
        guard response.accepted, response.sequence == sequence else {
            throw PushServerError.invalidResponse
        }
        return nextSequence
    }

    static func disableDeviceUsageUploads(
        settings: PushServerSettings,
        accountID: UUID,
        consentRevision: Int64
    ) async throws {
        guard consentRevision > 0 else { throw PushServerError.invalidResponse }
        let (serverURL, registration) = try monitoringContext(settings: settings)
        var components = URLComponents(
            url: accountURL(
                serverURL: serverURL,
                registration: registration,
                accountID: accountID
            ).appending(path: "snapshots"),
            resolvingAgainstBaseURL: false
        )!
        components.queryItems = [
            URLQueryItem(name: "consent_revision", value: String(consentRevision))
        ]
        guard let url = components.url else { throw PushServerError.invalidServerURL }
        var request = URLRequest(url: url)
        request.httpMethod = "DELETE"
        request.timeoutInterval = 20
        request.setValue("no-store", forHTTPHeaderField: "Cache-Control")
        request.setValue(
            "Bearer \(registration.deviceSecret)",
            forHTTPHeaderField: "Authorization"
        )
        _ = try await send(
            request,
            maximumResponseBytes: smallResponseLimit,
            acceptedStatusCodes: [204]
        )
    }

    static func deviceUsageSnapshotBody(
        account: MonitoredAccount,
        snapshot: UsageSnapshot,
        consentRevision: Int64,
        sequence: Int64
    ) throws -> Data {
        guard (1...ServerConsentRevisionPolicy.maximum).contains(consentRevision),
              DeviceUsageSequencePolicy.isValid(sequence) else {
            throw PushServerError.invalidResponse
        }
        let data = try JSONEncoder().encode(DeviceUsageUploadRequest(
            consentRevision: consentRevision,
            sequence: sequence,
            observedAt: snapshot.fetchedAt.timeIntervalSince1970,
            snapshot: try DeviceUsageSnapshotPayload(
                snapshot: snapshot,
                providerID: account.providerID
            )
        ))
        guard data.count <= 32 * 1_024 else { throw PushServerError.responseTooLarge }
        return data
    }

    static func deviceUsageSnapshotKeys(
        account: MonitoredAccount,
        snapshot: UsageSnapshot,
        consentRevision: Int64 = 1,
        sequence: Int64 = 1
    ) throws -> (root: Set<String>, snapshot: Set<String>, resetCredit: Set<String>?) {
        let data = try deviceUsageSnapshotBody(
            account: account,
            snapshot: snapshot,
            consentRevision: consentRevision,
            sequence: sequence
        )
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let projection = root["snapshot"] as? [String: Any] else {
            throw PushServerError.invalidResponse
        }
        let creditKeys = (projection["reset_credits"] as? [[String: Any]])?.first.map {
            Set($0.keys)
        }
        return (Set(root.keys), Set(projection.keys), creditKeys)
    }

    static func updateAccountPolicy(
        settings: PushServerSettings,
        account: MonitoredAccount
    ) async throws -> ServerAccountSyncResult {
        let (serverURL, registration) = try monitoringContext(settings: settings)
        let interval = settings.serverMonitoringInterval.timeInterval
            ?? RefreshInterval.tenMinutes.timeInterval!
        var request = URLRequest(
            url: accountURL(
                serverURL: serverURL,
                registration: registration,
                accountID: account.id
            ).appending(path: "settings")
        )
        request.httpMethod = "PATCH"
        request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("no-store", forHTTPHeaderField: "Cache-Control")
        request.setValue(
            "Bearer \(registration.deviceSecret)",
            forHTTPHeaderField: "Authorization"
        )
        request.httpBody = try JSONEncoder().encode(AccountPolicyUpdateRequest(
            refreshIntervalSeconds: Int(interval),
            historyRetentionDays: settings.historyRetention.rawValue
        ))
        let (data, _) = try await send(request)
        return try decodeAccountResponse(data, account: account)
    }

    static func syncAccount(settings: PushServerSettings, account: MonitoredAccount,
                            since: Date) async throws -> ServerAccountSyncResult {
        let (serverURL, registration) = try monitoringContext(settings: settings)
        var cursor: String?
        var seenCursors: Set<String> = []
        var pageCount = 0
        var points: [UsageHistoryPoint] = []
        var latestPage: AccountSyncPage?
        var responseConsentRevision: Int64?
        repeat {
            pageCount += 1
            guard pageCount <= 100 else { throw PushServerError.invalidResponse }
            var components = URLComponents(
                url: accountURL(serverURL: serverURL, registration: registration,
                                accountID: account.id).appending(path: "sync"),
                resolvingAgainstBaseURL: false
            )!
            components.queryItems = [
                URLQueryItem(name: "since", value: String(Int64(since.timeIntervalSince1970)))
            ]
            if let cursor { components.queryItems?.append(URLQueryItem(name: "cursor", value: cursor)) }
            guard let url = components.url else { throw PushServerError.invalidServerURL }
            var request = URLRequest(url: url)
            request.timeoutInterval = 20
            request.setValue("Bearer \(registration.deviceSecret)", forHTTPHeaderField: "Authorization")
            request.setValue("no-store", forHTTPHeaderField: "Cache-Control")
            let (data, _) = try await send(request)
            let page = try JSONDecoder().decode(AccountSyncPage.self, from: data)
            guard (1...ServerConsentRevisionPolicy.maximum).contains(page.consentRevision),
                  page.history.count <= 1_000,
                  responseConsentRevision == nil
                    || responseConsentRevision == page.consentRevision else {
                throw PushServerError.invalidResponse
            }
            responseConsentRevision = page.consentRevision
            points.append(contentsOf: page.history.map { $0.historyPoint(accountID: account.id) })
            if let nextCursor = page.nextCursor {
                guard nextCursor != cursor, seenCursors.insert(nextCursor).inserted else {
                    throw PushServerError.invalidResponse
                }
            }
            cursor = page.nextCursor
            latestPage = page
        } while cursor != nil

        guard var result = latestPage.map({ makeSyncResult(page: $0, account: account) }) else {
            throw PushServerError.invalidResponse
        }
        result.history = points
        return result
    }

    static func deleteAccount(settings: PushServerSettings, accountID: UUID,
                              consentRevision: Int64) async throws {
        guard consentRevision > 0 else { throw PushServerError.invalidResponse }
        let (serverURL, registration) = try monitoringContext(settings: settings)
        var components = URLComponents(
            url: accountURL(serverURL: serverURL,
                            registration: registration,
                            accountID: accountID),
            resolvingAgainstBaseURL: false
        )!
        components.queryItems = [
            URLQueryItem(name: "consent_revision", value: String(consentRevision))
        ]
        guard let url = components.url else { throw PushServerError.invalidServerURL }
        var request = URLRequest(url: url)
        request.httpMethod = "DELETE"
        request.timeoutInterval = 15
        request.setValue("Bearer \(registration.deviceSecret)", forHTTPHeaderField: "Authorization")
        _ = try await send(request)
    }

    private static func registrationCredentials(for serverURL: URL) throws
        -> PushRegistrationCredentials {
        if let existing = try? KeychainStore.loadPushRegistration(for: serverURL) {
            return existing
        }
        var bytes = [UInt8](repeating: 0, count: 32)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        guard status == errSecSuccess else { throw PushServerError.randomGenerationFailed(status) }
        let secret = Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        let credentials = PushRegistrationCredentials(
            deviceID: UUID(),
            deviceSecret: secret,
            serverURL: serverURL
        )
        try KeychainStore.savePushRegistration(credentials)
        return credentials
    }

    private static func monitoringContext(settings: PushServerSettings) throws
        -> (URL, PushRegistrationCredentials) {
        guard let serverURL = try settings.resolvedServerURL(),
              let registration = try? KeychainStore.loadPushRegistration(for: serverURL) else {
            throw PushServerError.accountMonitoringUnavailable
        }
        return (serverURL, registration)
    }

    private static func accountURL(serverURL: URL, registration: PushRegistrationCredentials,
                                   accountID: UUID) -> URL {
        serverURL.appending(
            path: "v1/devices/\(registration.deviceID.uuidString.lowercased())/accounts/\(accountID.uuidString.lowercased())"
        )
    }

    private static func remoteAccountsURL(
        serverURL: URL,
        registration: PushRegistrationCredentials
    ) -> URL {
        serverURL.appending(
            path: "v1/devices/\(registration.deviceID.uuidString.lowercased())/remote-accounts"
        )
    }

    static func decodeAccountResponse(_ data: Data,
                                      account: MonitoredAccount) throws -> ServerAccountSyncResult {
        let page = try JSONDecoder().decode(AccountSyncPage.self, from: data)
        guard (1...ServerConsentRevisionPolicy.maximum).contains(page.consentRevision) else {
            throw PushServerError.invalidResponse
        }
        return makeSyncResult(page: page, account: account)
    }

    private static func makeSyncResult(page: AccountSyncPage,
                                       account: MonitoredAccount) -> ServerAccountSyncResult {
        ServerAccountSyncResult(
            consentRevision: page.consentRevision,
            accountDetails: page.metadata?.accountDetails,
            snapshot: page.snapshot?.usageSnapshot(account: account),
            history: page.history.map { $0.historyPoint(accountID: account.id) },
            workerAccountReference: page.workerAccountReference,
            lastSuccessAt: page.lastSuccessAt.map(Date.init(timeIntervalSince1970:)),
            lastError: page.lastError,
            sessionStatus: page.sessionStatus,
            sessionCheckedAt: page.sessionCheckedAt.map(Date.init(timeIntervalSince1970:)),
            historyRetentionDays: page.historyRetentionDays
        )
    }

    private static func send(
        _ request: URLRequest,
        maximumResponseBytes: Int = accountResponseLimit,
        acceptedStatusCodes: Set<Int> = Set(200..<300)
    ) async throws -> (Data, HTTPURLResponse) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 20
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        let session = URLSession(
            configuration: configuration,
            delegate: NoRedirectSessionDelegate.shared,
            delegateQueue: nil
        )
        defer { session.invalidateAndCancel() }
        let (bytes, response) = try await session.bytes(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw PushServerError.invalidResponse
        }
        guard acceptedStatusCodes.contains(httpResponse.statusCode) else {
            var errorData = Data()
            var errorBodyExceededLimit = httpResponse.expectedContentLength
                > Int64(errorResponseLimit)
            if !errorBodyExceededLimit {
                if httpResponse.expectedContentLength > 0 {
                    errorData.reserveCapacity(
                        min(errorResponseLimit, Int(httpResponse.expectedContentLength))
                    )
                }
                for try await byte in bytes {
                    guard errorData.count < errorResponseLimit else {
                        errorBodyExceededLimit = true
                        break
                    }
                    errorData.append(byte)
                }
            }
            throw rejectedResponseError(
                statusCode: httpResponse.statusCode,
                body: errorBodyExceededLimit ? nil : errorData
            )
        }
        if httpResponse.expectedContentLength > Int64(maximumResponseBytes) {
            throw PushServerError.responseTooLarge
        }
        var data = Data()
        if httpResponse.expectedContentLength > 0 {
            data.reserveCapacity(min(maximumResponseBytes, Int(httpResponse.expectedContentLength)))
        }
        for try await byte in bytes {
            guard data.count < maximumResponseBytes else {
                throw PushServerError.responseTooLarge
            }
            data.append(byte)
        }
        return (data, httpResponse)
    }

    static func rejectedResponseError(statusCode: Int, body: Data?) -> PushServerError {
        struct ErrorEnvelope: Decodable {
            var error: WorkerErrorCode
        }

        guard let body,
              body.count <= errorResponseLimit,
              let envelope = try? JSONDecoder().decode(ErrorEnvelope.self, from: body) else {
            return .serverRejected(statusCode)
        }
        return .serverRejected(statusCode, envelope.error)
    }
}

private final class NoRedirectSessionDelegate: NSObject, URLSessionTaskDelegate,
    @unchecked Sendable {
    static let shared = NoRedirectSessionDelegate()

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}

enum RemotePushRegistrationFailurePolicy {
    static func isMissingAPNSEntitlement(_ error: Error) -> Bool {
        let message = message(for: error)
        return message.contains("aps-environment") && message.contains("entitlement")
    }

    static func notificationsAreNotAllowed(_ error: Error) -> Bool {
        message(for: error).contains("notifications are not allowed for this application")
    }

    private static func message(for error: Error) -> String {
        let error = error as NSError
        return [
            error.localizedDescription,
            error.localizedFailureReason,
            error.localizedRecoverySuggestion
        ]
        .compactMap { $0 }
        .joined(separator: " ")
        .lowercased()
    }
}

@MainActor
final class RemotePushCoordinator {
    static let shared = RemotePushCoordinator()

    private weak var store: AppStore?
    private var deviceToken: Data?

    private init() {}

    func configure(store: AppStore) {
        self.store = store
        if let deviceToken {
            Task { await store.updatePushRegistration(deviceToken: deviceToken) }
        }
    }

    func didRegister(deviceToken: Data) {
        self.deviceToken = deviceToken
        guard let store else { return }
        Task { await store.updatePushRegistration(deviceToken: deviceToken) }
    }

    func didFailToRegister(_ error: Error) {
        store?.pushRegistrationFailed(error)
    }

    func requestRegistrationIfNeeded() {
        guard let store, store.pushServerSettings.mode != .disabled else { return }
#if os(iOS)
        UIApplication.shared.registerForRemoteNotifications()
#elseif os(macOS)
        NSApplication.shared.registerForRemoteNotifications()
#endif
        if let deviceToken {
            Task { await store.updatePushRegistration(deviceToken: deviceToken) }
        }
    }

#if os(iOS)
    func handle(userInfo: [AnyHashable: Any]) async -> UIBackgroundFetchResult {
        guard let marker = userInfo["when_reset"] as? [String: Any],
              marker["action"] as? String == "refresh",
              let store,
              store.pushServerSettings.mode != .disabled else { return .noData }
        if store.isRefreshing { return .noData }
        return await store.refreshAll(source: .background) ? .newData : .failed
    }
#elseif os(macOS)
    func handle(userInfo: [AnyHashable: Any]) async -> Bool {
        guard let marker = userInfo["when_reset"] as? [String: Any],
              marker["action"] as? String == "refresh",
              let store,
              store.pushServerSettings.mode != .disabled,
              !store.isRefreshing else { return false }
        return await store.refreshAll(source: .background)
    }
#endif
}

private extension Data {
    var hexadecimalString: String {
        map { String(format: "%02x", $0) }.joined()
    }
}
