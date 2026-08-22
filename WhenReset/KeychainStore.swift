import CryptoKit
import Foundation
import Security

struct AccountCredentials: Codable, Equatable, Sendable {
    var accessToken: String
    var refreshToken: String
    var idToken: String
    var expiresAt: Date? = nil
    var endpointURL: String? = nil
    var projectID: String? = nil
    var accountLabel: String? = nil
    var oauthClientID: String? = nil
    var oauthClientSecret: String? = nil
    var monthlyBudget: Double? = nil
    var currencyCode: String? = nil
}

struct ChatGPTDuplicateCredentialCandidate: Sendable {
    var accountID: UUID
    var credentials: AccountCredentials
}

/// A credential-free, synchronizable redirect retained after a duplicate account row is deleted.
/// Other devices use it to re-key device-local history, settings, and snapshots even when iCloud
/// delivers the account deletion before that device has observed both rows together.
struct DirectChatGPTAccountMergeAlias: Codable, Equatable, Sendable {
    var sourceAccountID: UUID
    var canonicalAccountID: UUID
    var workspaceID: String
    var createdAt: Date

    var isValid: Bool {
        sourceAccountID != canonicalAccountID
            && !workspaceID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

enum ChatGPTDuplicateCredentialPolicy {
    static func preferred(
        from candidates: [ChatGPTDuplicateCredentialCandidate],
        canonicalAccountID: UUID,
        workspaceID: String
    ) -> ChatGPTDuplicateCredentialCandidate? {
        guard !workspaceID.isEmpty else { return nil }
        let valid = candidates.filter {
            isValid($0.credentials, forWorkspaceID: workspaceID)
        }
        return valid.sorted { lhs, rhs in
            let lhsFreshness = freshness(of: lhs.credentials)
            let rhsFreshness = freshness(of: rhs.credentials)
            if lhsFreshness != rhsFreshness { return lhsFreshness > rhsFreshness }
            if (lhs.accountID == canonicalAccountID) != (rhs.accountID == canonicalAccountID) {
                return lhs.accountID == canonicalAccountID
            }
            return lhs.accountID.uuidString < rhs.accountID.uuidString
        }.first
    }

    static func isValid(_ credentials: AccountCredentials, forWorkspaceID workspaceID: String)
        -> Bool {
        guard !credentials.accessToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !credentials.refreshToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !credentials.idToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return false
        }
        return workspaceIDFromIDToken(credentials.idToken) == workspaceID
    }

    private static func freshness(of credentials: AccountCredentials) -> Date {
        credentials.expiresAt
            ?? expirationFromJWT(credentials.accessToken)
            ?? expirationFromJWT(credentials.idToken)
            ?? .distantPast
    }

    private static func workspaceIDFromIDToken(_ token: String) -> String? {
        guard let claims = jwtClaims(token) else { return nil }
        let auth = claims["https://api.openai.com/auth"] as? [String: Any]
        return nonEmpty(auth?["chatgpt_account_id"] as? String)
            ?? nonEmpty(claims["chatgpt_account_id"] as? String)
    }

    private static func expirationFromJWT(_ token: String) -> Date? {
        guard let raw = jwtClaims(token)?["exp"] else { return nil }
        let seconds: TimeInterval?
        switch raw {
        case let value as NSNumber: seconds = value.doubleValue
        case let value as String: seconds = TimeInterval(value)
        default: seconds = nil
        }
        guard let seconds, seconds.isFinite, seconds > 0 else { return nil }
        return Date(timeIntervalSince1970: seconds)
    }

    private static func jwtClaims(_ token: String) -> [String: Any]? {
        let components = token.split(separator: ".", omittingEmptySubsequences: false)
        guard components.count >= 2 else { return nil }
        var encoded = String(components[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        encoded += String(repeating: "=", count: (4 - encoded.count % 4) % 4)
        guard let data = Data(base64Encoded: encoded),
              let claims = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return claims
    }

    private static func nonEmpty(_ value: String?) -> String? {
        let normalized = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        return normalized?.isEmpty == false ? normalized : nil
    }
}

enum KeychainStore {
    static let credentialsService = "ad.neko.when.credentials"
    static let accountsService = "ad.neko.when.accounts"
    static let accountMergeAliasesService = "ad.neko.when.account-merge-aliases"
    static let pushRegistrationService = "ad.neko.when.push-registration"
    static let pushServerAccessService = "ad.neko.when.push-server-access"

    static func save(_ credentials: AccountCredentials, for id: UUID) throws {
        let data = try JSONEncoder().encode(credentials)
        try saveSynchronizable(data, service: credentialsService, account: id.uuidString)
    }

    static func load(for id: UUID) throws -> AccountCredentials {
        let data: Data
        do {
            data = try loadData(service: credentialsService, account: id.uuidString,
                                synchronizable: true)
        } catch let error as NSError where error.domain == NSOSStatusErrorDomain
            && error.code == Int(errSecItemNotFound) {
            let legacy = try loadData(service: credentialsService, account: id.uuidString,
                                      synchronizable: false)
            try saveSynchronizable(legacy, service: credentialsService, account: id.uuidString)
            data = legacy
        }
        return try JSONDecoder().decode(AccountCredentials.self, from: data)
    }

    static func delete(for id: UUID) {
        deleteData(service: credentialsService, account: id.uuidString)
    }

    static func saveAccount(_ account: MonitoredAccount) throws {
        guard !account.isDemo else { return }
        try saveSynchronizable(try JSONEncoder().encode(account),
                               service: accountsService,
                               account: account.id.uuidString)
    }

    static func loadAccounts() throws -> [MonitoredAccount] {
        var query = baseQuery(service: accountsService)
        query[kSecAttrSynchronizable as String] = true
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitAll

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return [] }
        guard status == errSecSuccess else { throw keychainError(status) }

        let dataItems: [Data]
        if let data = result as? Data {
            dataItems = [data]
        } else if let data = result as? [Data] {
            dataItems = data
        } else {
            throw keychainError(errSecDecode)
        }

        let decoded = try dataItems.map { try JSONDecoder().decode(MonitoredAccount.self, from: $0) }
            .filter { !$0.isDemo }
        let accountsByID = Dictionary(decoded.map { ($0.id, $0) }, uniquingKeysWith: { _, latest in latest })
        return accountsByID.values.sorted(by: accountOrder)
    }

    static func deleteAccount(for id: UUID) {
        deleteData(service: accountsService, account: id.uuidString)
    }

    static func saveAccountMergeAlias(_ alias: DirectChatGPTAccountMergeAlias) throws {
        guard alias.isValid else { throw keychainError(errSecParam) }
        try saveSynchronizable(
            try JSONEncoder().encode(alias),
            service: accountMergeAliasesService,
            account: alias.sourceAccountID.uuidString
        )
    }

    static func loadAccountMergeAliases() throws -> [DirectChatGPTAccountMergeAlias] {
        let decoded = try loadSynchronizableData(service: accountMergeAliasesService).compactMap {
            try? JSONDecoder().decode(DirectChatGPTAccountMergeAlias.self, from: $0)
        }.filter(\.isValid)
        let bySource = Dictionary(
            decoded.map { ($0.sourceAccountID, $0) },
            uniquingKeysWith: { existing, candidate in
                candidate.createdAt > existing.createdAt ? candidate : existing
            }
        )
        return bySource.values.sorted {
            $0.sourceAccountID.uuidString < $1.sourceAccountID.uuidString
        }
    }

    static func deleteAccountMergeAlias(for sourceID: UUID) {
        deleteData(service: accountMergeAliasesService, account: sourceID.uuidString)
    }

    static func prepareChatGPTDuplicateCredential(
        canonical: MonitoredAccount,
        duplicateIDs: [UUID]
    ) throws -> Bool {
        let ids = [canonical.id] + duplicateIDs
        var candidates: [ChatGPTDuplicateCredentialCandidate] = []
        for id in ids {
            do {
                candidates.append(.init(accountID: id, credentials: try load(for: id)))
            } catch let error as NSError where error.domain == NSOSStatusErrorDomain
                && error.code == Int(errSecItemNotFound) {
                continue
            }
        }
        if canonical.usesWorkerAsCredentialAuthority { return true }
        guard let preferred = ChatGPTDuplicateCredentialPolicy.preferred(
            from: candidates,
            canonicalAccountID: canonical.id,
            workspaceID: canonical.workspaceID
        ) else { return false }
        try save(preferred.credentials, for: canonical.id)
        return true
    }

    static func deleteDuplicateAccountAndCredential(for id: UUID) throws {
        // Delete the credential first. If that fails, retain the account record so a later sync can
        // retry without leaving an invisible credential orphaned in iCloud Keychain.
        try deleteDataIfPresent(service: credentialsService, account: id.uuidString)
        try deleteDataIfPresent(service: accountsService, account: id.uuidString)
    }

    static func savePushRegistration(_ credentials: PushRegistrationCredentials) throws {
        try saveDeviceLocal(
            try JSONEncoder().encode(credentials),
            service: pushRegistrationService,
            account: pushRegistrationAccount(for: credentials.serverURL)
        )
    }

    static func loadPushRegistration(for serverURL: URL) throws -> PushRegistrationCredentials {
        let data = try loadData(
            service: pushRegistrationService,
            account: pushRegistrationAccount(for: serverURL),
            synchronizable: false
        )
        return try JSONDecoder().decode(PushRegistrationCredentials.self, from: data)
    }

    static func deletePushRegistration(for serverURL: URL) {
        var query = baseQuery(
            service: pushRegistrationService,
            account: pushRegistrationAccount(for: serverURL)
        )
        query[kSecAttrSynchronizable as String] = false
        SecItemDelete(query as CFDictionary)
    }

    static func savePushServerAccessKey(_ key: String, for serverURL: URL) throws {
        try saveDeviceLocal(
            Data(key.utf8),
            service: pushServerAccessService,
            account: pushRegistrationAccount(for: serverURL)
        )
    }

    static func loadPushServerAccessKey(for serverURL: URL) throws -> String {
        let data = try loadData(
            service: pushServerAccessService,
            account: pushRegistrationAccount(for: serverURL),
            synchronizable: false
        )
        guard let key = String(data: data, encoding: .utf8), !key.isEmpty else {
            throw keychainError(errSecDecode)
        }
        return key
    }

    static func deletePushServerAccessKey(for serverURL: URL) {
        var query = baseQuery(
            service: pushServerAccessService,
            account: pushRegistrationAccount(for: serverURL)
        )
        query[kSecAttrSynchronizable as String] = false
        SecItemDelete(query as CFDictionary)
    }

    static func orderedAccounts(_ accounts: [MonitoredAccount]) -> [MonitoredAccount] {
        accounts.sorted(by: accountOrder)
    }

    private static func saveSynchronizable(_ data: Data, service: String, account: String) throws {
        var query = baseQuery(service: service, account: account)
        query[kSecAttrSynchronizable as String] = true
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock
        ]

        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var item = query
            attributes.forEach { item[$0.key] = $0.value }
            let addStatus = SecItemAdd(item as CFDictionary, nil)
            guard addStatus == errSecSuccess else { throw keychainError(addStatus) }
        } else if status != errSecSuccess {
            throw keychainError(status)
        }

        var legacyQuery = baseQuery(service: service, account: account)
        legacyQuery[kSecAttrSynchronizable as String] = false
        SecItemDelete(legacyQuery as CFDictionary)
    }

    private static func saveDeviceLocal(_ data: Data, service: String, account: String) throws {
        var query = baseQuery(service: service, account: account)
        query[kSecAttrSynchronizable as String] = false
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var item = query
            attributes.forEach { item[$0.key] = $0.value }
            let addStatus = SecItemAdd(item as CFDictionary, nil)
            guard addStatus == errSecSuccess else { throw keychainError(addStatus) }
        } else if status != errSecSuccess {
            throw keychainError(status)
        }
    }

    private static func loadData(service: String, account: String,
                                 synchronizable: Bool) throws -> Data {
        var query = baseQuery(service: service, account: account)
        query[kSecAttrSynchronizable as String] = synchronizable
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else {
            throw keychainError(status == errSecSuccess ? errSecDecode : status)
        }
        return data
    }

    private static func loadSynchronizableData(service: String) throws -> [Data] {
        var query = baseQuery(service: service)
        query[kSecAttrSynchronizable as String] = true
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitAll
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return [] }
        guard status == errSecSuccess else { throw keychainError(status) }
        if let data = result as? Data { return [data] }
        if let data = result as? [Data] { return data }
        throw keychainError(errSecDecode)
    }

    private static func deleteData(service: String, account: String) {
        var query = baseQuery(service: service, account: account)
        query[kSecAttrSynchronizable as String] = kSecAttrSynchronizableAny
        SecItemDelete(query as CFDictionary)
    }

    private static func deleteDataIfPresent(service: String, account: String) throws {
        var query = baseQuery(service: service, account: account)
        query[kSecAttrSynchronizable as String] = kSecAttrSynchronizableAny
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw keychainError(status)
        }
    }

    private static func baseQuery(service: String, account: String? = nil) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service
        ]
        if let account { query[kSecAttrAccount as String] = account }
        return query
    }

    private static func accountOrder(_ lhs: MonitoredAccount, _ rhs: MonitoredAccount) -> Bool {
        if lhs.addedAt != rhs.addedAt { return lhs.addedAt < rhs.addedAt }
        return lhs.id.uuidString < rhs.id.uuidString
    }

    private static func pushRegistrationAccount(for serverURL: URL) -> String {
        let digest = SHA256.hash(data: Data(serverURL.absoluteString.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private static func keychainError(_ status: OSStatus) -> NSError {
        NSError(domain: NSOSStatusErrorDomain, code: Int(status))
    }
}
