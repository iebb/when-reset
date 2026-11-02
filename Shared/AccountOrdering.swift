import Foundation

enum ZhipuAccountMigration {
    static let legacyTitle = "智谱 GLM"

    static func migrate(_ account: MonitoredAccount, credentials: AccountCredentials?) -> MonitoredAccount {
        guard account.providerID == .zai else { return account }
        let region = credentials?.serviceRegion
        let host = credentials?.serviceHost?.lowercased() ?? ""
        let mainland = region == "mainland" || host.contains("bigmodel.cn")
        guard mainland else {
            var global = account
            if global.displayName == legacyTitle { global.displayName = ProviderID.zai.displayName }
            return global
        }
        var mainlandAccount = account
        mainlandAccount.providerID = .zhipu
        if mainlandAccount.displayName == legacyTitle {
            mainlandAccount.displayName = ProviderID.zhipu.displayName
        }
        return mainlandAccount
    }
}

enum AccountOrdering {
    static func grouped(_ accounts: [MonitoredAccount]) -> [MonitoredAccount] {
        let rank = Dictionary(uniqueKeysWithValues: ProviderID.allCases.enumerated().map { ($1, $0) })
        return accounts.sorted { lhs, rhs in
            let left = rank[lhs.providerID] ?? .max
            let right = rank[rhs.providerID] ?? .max
            if left != right { return left < right }
            if lhs.addedAt != rhs.addedAt { return lhs.addedAt < rhs.addedAt }
            return lhs.id.uuidString < rhs.id.uuidString
        }
    }

    static func apply(customIDs: [UUID]?, to accounts: [MonitoredAccount]) -> [MonitoredAccount] {
        guard let customIDs, !customIDs.isEmpty else { return grouped(accounts) }
        let byID = Dictionary(uniqueKeysWithValues: accounts.map { ($0.id, $0) })
        var ordered: [MonitoredAccount] = []
        var seen = Set<UUID>()
        for id in customIDs {
            guard let account = byID[id], seen.insert(id).inserted else { continue }
            ordered.append(account)
        }
        let missing = accounts.filter { !seen.contains($0.id) }.sorted {
            if $0.addedAt != $1.addedAt { return $0.addedAt < $1.addedAt }
            return $0.id.uuidString < $1.id.uuidString
        }
        for account in missing {
            ordered = inserting(account, into: ordered)
        }
        return ordered
    }

    static func inserting(_ account: MonitoredAccount, into accounts: [MonitoredAccount]) -> [MonitoredAccount] {
        var result = accounts.filter { $0.id != account.id }
        if let last = result.lastIndex(where: { $0.providerID == account.providerID }) {
            result.insert(account, at: last + 1)
        } else {
            result.append(account)
        }
        return result
    }

    static func moving(_ ids: [UUID], from offsets: IndexSet, to destination: Int) -> [UUID] {
        var items = ids
        let moving = offsets.sorted().map { items[$0] }
        for index in offsets.sorted(by: >) { items.remove(at: index) }
        let insertAt = destination - offsets.filter { $0 < destination }.count
        items.insert(contentsOf: moving, at: min(max(0, insertAt), items.count))
        return items
    }
}
