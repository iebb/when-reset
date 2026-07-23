import Foundation
import Security

struct AccountCredentials: Codable, Equatable, Sendable {
    var accessToken: String
    var refreshToken: String
    var idToken: String
    var expiresAt: Date? = nil
}

enum KeychainStore {
    static let credentialsService = "ad.neko.when.credentials"
    static let accountsService = "ad.neko.when.accounts"

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

    private static func deleteData(service: String, account: String) {
        var query = baseQuery(service: service, account: account)
        query[kSecAttrSynchronizable as String] = kSecAttrSynchronizableAny
        SecItemDelete(query as CFDictionary)
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

    private static func keychainError(_ status: OSStatus) -> NSError {
        NSError(domain: NSOSStatusErrorDomain, code: Int(status))
    }
}
