import CryptoKit
import Foundation
import Security

enum ZAIRegion: String, Codable, CaseIterable, Identifiable, Sendable {
    case automatic
    case global
    case mainland

    var id: String { rawValue }

    var title: String {
        switch self {
        case .automatic: "Automatic · 自动"
        case .global: "Global · Z.AI"
        case .mainland: "中国大陆 · 智谱 BigModel"
        }
    }

    var detail: String {
        switch self {
        case .automatic:
            "Try api.z.ai, then open.bigmodel.cn, and remember the host that accepts this key."
        case .global:
            "International Z.AI only (api.z.ai). A mainland 智谱 key is not sent to the other host."
        case .mainland:
            "中国大陆智谱 BigModel only (open.bigmodel.cn). An international key is not sent to the other host."
        }
    }
}

enum ZAIProviderError: LocalizedError {
    case invalidAPIKey
    case invalidResponse
    case noResettableQuota
    case authorizationFailed(String)
    case server(Int, String)

    var errorDescription: String? {
        switch self {
        case .invalidAPIKey:
            "Enter a valid 智谱 GLM / Z.AI Coding Plan API key."
        case .invalidResponse:
            "智谱 GLM returned unreadable Coding Plan quota data."
        case .noResettableQuota:
            String.localized("This key has no Coding Plan limits. Pay-as-you-go and general API keys are outside Blinky. Use a Coding Plan key, or sign in with the browser.")
        case let .authorizationFailed(host):
            Self.authorizationMessage(host: host)
        case let .server(code, message):
            "智谱 GLM request failed (HTTP \(code)): \(message)"
        }
    }

    private static func authorizationMessage(host: String) -> String {
        switch host {
        case ZAIProvider.mainlandHost:
            "智谱 BigModel (open.bigmodel.cn) rejected this key. If it is a Z.AI international key, choose Global or Automatic."
        case ZAIProvider.globalHost:
            "Z.AI (api.z.ai) rejected this key. If it is a 智谱 mainland key, choose 中国大陆 · BigModel or Automatic."
        default:
            "Neither api.z.ai nor open.bigmodel.cn accepted this Coding Plan key. Check that it belongs to an active 智谱 GLM / Z.AI Coding Plan."
        }
    }
}

struct ZAIUsageResult: Sendable {
    var snapshot: UsageSnapshot
    var credentials: AccountCredentials
}

struct ZAIProvider {
    static let providerTitle = "z.ai"
    static let mainlandTitle = "智谱"
    static let globalHost = "api.z.ai"
    static let mainlandHost = "open.bigmodel.cn"
    static let quotaPath = "/api/monitor/usage/quota/limit"
    static let globalQuotaURL = URL(string: "https://api.z.ai/api/monitor/usage/quota/limit")!
    static let mainlandQuotaURL = URL(string: "https://open.bigmodel.cn/api/monitor/usage/quota/limit")!

    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func link(apiKey rawAPIKey: String, provider: ProviderID = .zai,
              region: ZAIRegion = .automatic) async throws -> LinkedIdentity {
        let apiKey = try Self.normalizedKey(rawAPIKey)
        let storefront = ZAIStorefront(provider: provider, region: region)
        let account = MonitoredAccount(
            id: UUID(),
            providerID: storefront.providerID,
            displayName: storefront.title,
            workspaceID: "pending",
            plan: nil,
            addedAt: .now
        )
        let result = try await load(
            account: account,
            credentials: AccountCredentials(
                accessToken: apiKey,
                refreshToken: "",
                idToken: "",
                serviceRegion: region.rawValue
            )
        )
        let digest = SHA256.hash(data: Data(apiKey.utf8))
        let fingerprint = digest.prefix(8).map { String(format: "%02x", $0) }.joined()

        return LinkedIdentity(
            workspaceID: "zai-\(fingerprint)",
            displayName: Self.providerTitle,
            plan: result.snapshot.plan ?? "Coding Plan",
            credentials: result.credentials
        )
    }

    func fetchUsage(account: MonitoredAccount, credentials: AccountCredentials) async throws -> ZAIUsageResult {
        try await load(account: account, credentials: credentials)
    }

    static func candidateURLs(region: ZAIRegion, pinnedHost: String?) -> [URL] {
        candidateURLs(provider: region == .mainland ? .zhipu : .zai, region: region, pinnedHost: pinnedHost)
    }

    static func candidateURLs(provider: ProviderID, region: ZAIRegion, pinnedHost: String?) -> [URL] {
        let storefront = ZAIStorefront(provider: provider, region: region)
        if let pinned = quotaURL(forHost: pinnedHost), pinned.host == storefront.quotaURL.host {
            return [pinned]
        }
        return [storefront.quotaURL]
    }

    static func quotaURL(forHost host: String?) -> URL? {
        switch host?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case globalHost, globalQuotaURL.absoluteString: globalQuotaURL
        case mainlandHost, mainlandQuotaURL.absoluteString: mainlandQuotaURL
        default: nil
        }
    }

    static func region(from credentials: AccountCredentials) -> ZAIRegion {
        ZAIRegion(rawValue: credentials.serviceRegion ?? "") ?? .automatic
    }

    static func parseUsage(account: MonitoredAccount, data: Data, now: Date = .now) throws -> UsageSnapshot {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let code = integer(root["code"]),
              code == 200,
              (root["success"] as? Bool) != false,
              let payload = root["data"] as? [String: Any],
              let rawLimits = payload["limits"] as? [[String: Any]] else {
            throw ZAIProviderError.invalidResponse
        }

        var fiveHour: UsageWindow?
        var weekly: UsageWindow?
        var additional: [UsageWindow] = []

        for rawLimit in rawLimits {
            guard let window = usageWindow(rawLimit, now: now) else { continue }
            switch window.windowMinutes {
            case 300 where fiveHour == nil:
                fiveHour = window
            case 10_080 where weekly == nil:
                weekly = window
            default:
                additional.append(window)
            }
        }

        guard fiveHour != nil || weekly != nil || !additional.isEmpty else {
            throw ZAIProviderError.noResettableQuota
        }

        let plan = string(payload["planName"])
            ?? string(payload["plan"])
            ?? string(payload["plan_type"])
            ?? string(payload["packageName"])
            ?? string(payload["level"]).map { $0.capitalized }
            ?? account.plan

        return UsageSnapshot(
            accountID: account.id,
            providerName: ZAIStorefront(provider: account.providerID, region: .automatic).title,
            accountName: account.displayName,
            accountProviderID: account.providerID,
            accountSymbolName: account.customSymbolName,
            plan: plan,
            primary: fiveHour,
            secondary: weekly,
            availableResetCount: 0,
            resetCredits: [],
            fetchedAt: now,
            extraWindows: additional.isEmpty ? nil : additional
        )
    }

    private func load(account: MonitoredAccount, credentials: AccountCredentials) async throws -> ZAIUsageResult {
        let apiKey = try Self.normalizedKey(credentials.accessToken)
        let region = Self.region(from: credentials)
        let urls = Self.candidateURLs(provider: account.providerID, region: region, pinnedHost: credentials.serviceHost)
        var mostRecentRetryableError: Error?

        for url in urls {
            do {
                let data = try await quotaData(apiKey: apiKey, url: url)
                let snapshot = try Self.parseUsage(account: account, data: data)
                var pinned = credentials
                pinned.accessToken = apiKey
                pinned.serviceRegion = ZAIStorefront(provider: account.providerID, region: region).region.rawValue
                pinned.serviceHost = url.absoluteString
                return ZAIUsageResult(snapshot: snapshot, credentials: pinned)
            } catch let error as ZAIProviderError {
                switch error {
                case .authorizationFailed, .invalidResponse:
                    mostRecentRetryableError = error
                    if urls.count == 1 { throw error }
                case .invalidAPIKey, .noResettableQuota, .server:
                    throw error
                }
            }
        }

        throw mostRecentRetryableError ?? ZAIProviderError.authorizationFailed("both")
    }

    private func quotaData(apiKey: String, url: URL) async throws -> Data {
        var request = URLRequest(url: url)
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("WhenReset/1.0", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let host = url.host ?? "both"
        switch status {
        case 200..<300:
            if Self.envelopeAccepted(data) { return data }
            throw ZAIProviderError.authorizationFailed(host)
        case 401, 403:
            throw ZAIProviderError.authorizationFailed(host)
        case 404, 405:
            throw ZAIProviderError.authorizationFailed(host)
        default:
            throw ZAIProviderError.server(status, Self.safeServerMessage(data))
        }
    }

    private static func normalizedKey(_ rawAPIKey: String) throws -> String {
        let apiKey = rawAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard apiKey.count >= 12, !apiKey.contains(where: { $0.isWhitespace }) else {
            throw ZAIProviderError.invalidAPIKey
        }
        return apiKey
    }

    /// Zhipu and Z.AI answer with a `code` / `success` envelope even when HTTP is 200.
    /// A non-success envelope is a wrong-region or wrong-key reply, not quota data.
    static func envelopeAccepted(_ data: Data) -> Bool {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return false
        }
        if (root["success"] as? Bool) == false { return false }
        if let code = integer(root["code"]), code != 200 { return false }
        return root["data"] is [String: Any]
    }

    private static func usageWindow(_ raw: [String: Any], now: Date) -> UsageWindow? {
        guard let type = string(raw["type"])?.uppercased(),
              type == "TOKENS_LIMIT" || type == "CREDIT_LIMIT" || type == "TIME_LIMIT" else { return nil }
        let reportedReset = resetDate(raw["nextResetTime"] ?? raw["next_reset_time"])
        let reportsReset = reportedReset.map { $0 > now } ?? false
        let reset = reportedReset ?? now.addingTimeInterval(60)

        let unit = integer(raw["unit"])
        let number = integer(raw["number"]) ?? 0
        let minutes = windowMinutes(unit: unit, number: number)
        let usedPercent = percentage(raw)

        if type == "TIME_LIMIT" {
            return UsageWindow(
                title: "Monthly MCP limit",
                usedPercent: usedPercent,
                resetsAt: reset,
                windowMinutes: minutes,
                kind: .additional,
                identifier: "zai:mcp:\(unit ?? -1):\(number)",
                reportsReset: reportsReset
            )
        }

        switch minutes {
        case 300:
            return UsageWindow(title: "5h limit", usedPercent: usedPercent, resetsAt: reset,
                               windowMinutes: minutes, kind: .fiveHour, identifier: "zai:five_hour",
                               reportsReset: reportsReset)
        case 10_080:
            return UsageWindow(title: "Weekly limit", usedPercent: usedPercent, resetsAt: reset,
                               windowMinutes: minutes, kind: .weekly, identifier: "zai:weekly",
                               reportsReset: reportsReset)
        default:
            let title = windowTitle(unit: unit, number: number) ?? "Coding limit"
            return UsageWindow(title: title, usedPercent: usedPercent, resetsAt: reset,
                               windowMinutes: minutes, kind: .additional,
                               identifier: "zai:coding:\(unit ?? -1):\(number)",
                               reportsReset: reportsReset)
        }
    }

    private static func percentage(_ raw: [String: Any]) -> Double {
        if let allowance = number(raw["usage"]), allowance > 0 {
            let fromRemaining = number(raw["remaining"]).map { allowance - $0 }
            let current = number(raw["currentValue"] ?? raw["current_value"])
            let used = [fromRemaining, current].compactMap { $0 }.max()
            if let used {
                return min(100, max(0, used / allowance * 100))
            }
        }
        return min(100, max(0, number(raw["percentage"]) ?? 0))
    }

    private static func windowMinutes(unit: Int?, number: Int) -> Int? {
        guard number > 0 else { return nil }
        return switch unit {
        case 1: number * 24 * 60
        case 3: number * 60
        case 5: number
        case 6: number * 7 * 24 * 60
        default: nil
        }
    }

    private static func windowTitle(unit: Int?, number: Int) -> String? {
        guard number > 0 else { return nil }
        return switch unit {
        case 1: "\(number)-day limit"
        case 3: "\(number)h limit"
        case 5: "\(number)-minute limit"
        case 6: number == 1 ? "Weekly limit" : "\(number)-week limit"
        default: nil
        }
    }

    private static func resetDate(_ value: Any?) -> Date? {
        guard let timestamp = number(value), timestamp > 0 else { return nil }
        return Date(timeIntervalSince1970: timestamp > 10_000_000_000 ? timestamp / 1_000 : timestamp)
    }

    private static func integer(_ value: Any?) -> Int? {
        if let value = value as? NSNumber { return value.intValue }
        if let value = value as? String { return Int(value) }
        return nil
    }

    private static func number(_ value: Any?) -> Double? {
        if let value = value as? NSNumber { return value.doubleValue }
        if let value = value as? String { return Double(value) }
        return nil
    }

    private static func string(_ value: Any?) -> String? {
        guard let value = value as? String else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func safeServerMessage(_ data: Data) -> String {
        if let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let message = string(root["msg"] ?? root["message"]) {
            return String(message.prefix(180))
        }
        return "The quota service is unavailable."
    }
}

enum ZAIStorefront: Sendable {
    case mainland
    case global

    init(provider: ProviderID, region: ZAIRegion) {
        if provider == .zhipu || region == .mainland {
            self = .mainland
        } else {
            self = .global
        }
    }

    var providerID: ProviderID { self == .mainland ? .zhipu : .zai }
    var title: String { self == .mainland ? ZAIProvider.mainlandTitle : ZAIProvider.providerTitle }
    var region: ZAIRegion { self == .mainland ? .mainland : .global }
    var quotaURL: URL { self == .mainland ? ZAIProvider.mainlandQuotaURL : ZAIProvider.globalQuotaURL }
    var apiOrigin: String { self == .mainland ? "https://open.bigmodel.cn" : "https://api.z.ai" }
    var oauthProvider: String { self == .mainland ? "bigmodel" : "zai" }
}

struct ZAIWebLink: Sendable {
    var verificationURL: URL
    var flowID: String
    var pollToken: String
    var interval: TimeInterval
    var expiresAt: Date
    var storefront: ZAIStorefront
}

extension ZAIProvider {
    static let oauthInitURL = URL(string: "https://zcode.z.ai/api/v1/oauth/cli/init")!

    func beginWebLink(storefront: ZAIStorefront, now: Date = .now) async throws -> ZAIWebLink {
        let pollToken = Self.randomToken()
        var request = URLRequest(url: Self.oauthInitURL)
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        request.httpBody = try JSONSerialization.data(withJSONObject: ["provider": storefront.oauthProvider])
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(pollToken)", forHTTPHeaderField: "Authorization")
        request.setValue("WhenReset/1.0", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            throw ZAIProviderError.server(status, "Web sign-in could not start.")
        }
        return try Self.webLink(from: data, pollToken: pollToken, storefront: storefront, now: now)
    }

    func finishWebLink(_ link: ZAIWebLink) async throws -> LinkedIdentity {
        let ready = try await pollWebLink(link)
        let apiKey = try await codingPlanKey(storefront: link.storefront, session: ready)
        return try await self.link(apiKey: apiKey, provider: link.storefront.providerID, region: link.storefront.region)
    }

    static func webLink(from data: Data, pollToken: String, storefront: ZAIStorefront, now: Date = .now) throws -> ZAIWebLink {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              integer(root["code"]) == 0,
              let payload = root["data"] as? [String: Any],
              let flowID = string(payload["flow_id"]), !flowID.isEmpty,
              let rawURL = string(payload["authorize_url"]),
              let verificationURL = URL(string: rawURL),
              isAllowedAuthorizeURL(verificationURL, storefront: storefront) else {
            throw ZAIProviderError.invalidResponse
        }
        let expiresAt = number(payload["expires_at"]).map { value in
            Date(timeIntervalSince1970: value > 10_000_000_000 ? value / 1_000 : value)
        } ?? now.addingTimeInterval(10 * 60)
        let interval = max(1, number(payload["poll_interval_sec"]) ?? 2)
        return ZAIWebLink(verificationURL: verificationURL, flowID: flowID, pollToken: pollToken,
                          interval: interval, expiresAt: expiresAt, storefront: storefront)
    }

    static func isAllowedAuthorizeURL(_ url: URL, storefront: ZAIStorefront) -> Bool {
        guard url.scheme?.lowercased() == "https" else { return false }
        switch (storefront, url.host?.lowercased()) {
        case (.mainland, "bigmodel.cn"), (.mainland, "www.bigmodel.cn"):
            return url.path == "/login"
        case (.global, "chat.z.ai"):
            return url.path == "/api/oauth/authorize"
        default:
            return false
        }
    }

    private func pollWebLink(_ link: ZAIWebLink) async throws -> ZAIWebSession {
        guard let pollURL = URL(string: "https://zcode.z.ai/api/v1/oauth/cli/poll/\(link.flowID)") else {
            throw ZAIProviderError.invalidResponse
        }
        while Date.now < link.expiresAt {
            try Task.checkCancellation()
            try await Task.sleep(for: .seconds(link.interval))
            var request = URLRequest(url: pollURL)
            request.timeoutInterval = 20
            request.setValue("Bearer \(link.pollToken)", forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            request.setValue("WhenReset/1.0", forHTTPHeaderField: "User-Agent")
            let (data, response) = try await session.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard (200..<300).contains(status),
                  let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  Self.integer(root["code"]) == 0,
                  let payload = root["data"] as? [String: Any],
                  let state = Self.string(payload["status"]) else { continue }
            switch state {
            case "pending":
                continue
            case "failed":
                throw ZAIProviderError.authorizationFailed(link.storefront.quotaURL.host ?? "zcode.z.ai")
            case "ready":
                guard let session = Self.webSession(from: payload, storefront: link.storefront) else {
                    throw ZAIProviderError.invalidResponse
                }
                return session
            default:
                continue
            }
        }
        throw ZAIProviderError.server(408, "Web sign-in timed out.")
    }

    static func webSession(from payload: [String: Any], storefront: ZAIStorefront) -> ZAIWebSession? {
        let bucketKey = storefront == .mainland ? "bigmodel" : "zai"
        let bucket = payload[bucketKey] as? [String: Any] ?? [:]
        let access = string(bucket["access_token"]) ?? string(bucket["accessToken"]) ?? string(payload["token"])
        guard let access, !access.isEmpty else { return nil }
        let refresh = string(bucket["refresh_token"]) ?? string(bucket["refreshToken"]) ?? ""
        let user = payload["user"] as? [String: Any]
        return ZAIWebSession(accessToken: access, refreshToken: refresh,
                             name: string(user?["name"]), email: string(user?["email"]))
    }

    private func codingPlanKey(storefront: ZAIStorefront, session: ZAIWebSession) async throws -> String {
        if await quotaAccepts(session.accessToken, url: storefront.quotaURL) {
            return session.accessToken
        }
        let business = await businessToken(origin: storefront.apiOrigin, oauthToken: session.accessToken) ?? session.accessToken
        if await quotaAccepts(business, url: storefront.quotaURL) {
            return business
        }
        if let existing = await readableProjectKey(origin: storefront.apiOrigin, token: business) {
            return existing
        }
        if let created = await createProjectKey(origin: storefront.apiOrigin, token: business) {
            return created
        }
        throw ZAIProviderError.server(0, String.localized("Browser sign-in finished, but Blinky could not read or create a Coding Plan key."))
    }

    private func quotaAccepts(_ token: String, url: URL) async -> Bool {
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        guard let (data, response) = try? await session.data(for: request),
              let status = (response as? HTTPURLResponse)?.statusCode,
              (200..<300).contains(status) else { return false }
        return Self.envelopeAccepted(data)
    }

    private func businessToken(origin: String, oauthToken: String) async -> String? {
        guard let url = URL(string: origin + "/api/auth/z/login") else { return nil }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 15
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["token": oauthToken])
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        guard let (data, response) = try? await session.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let payload = root["data"] as? [String: Any] ?? root
        return Self.string(payload["access_token"]) ?? Self.string(payload["accessToken"])
    }

    private func readableProjectKey(origin: String, token: String) async -> String? {
        guard let context = await projectContext(origin: origin, token: token) else { return nil }
        return await copyKey(origin: origin, token: token, context: context, createIfMissing: false)
    }

    private func createProjectKey(origin: String, token: String) async -> String? {
        guard let context = await projectContext(origin: origin, token: token) else { return nil }
        return await copyKey(origin: origin, token: token, context: context, createIfMissing: true)
    }

    private func projectContext(origin: String, token: String) async -> (org: String, project: String)? {
        guard let url = URL(string: origin + "/api/biz/customer/getCustomerInfo") else { return nil }
        guard let root = await authorizedJSON(url, token: token) else { return nil }
        let data = (root["data"] as? [String: Any]) ?? root
        guard let orgs = data["organizations"] as? [[String: Any]],
              let org = orgs.first else { return nil }
        let orgID = Self.string(org["organizationId"]) ?? Self.string(org["id"])
        let projects = org["projects"] as? [[String: Any]]
        let project = projects?.first
        let projectID = Self.string(project?["projectId"]) ?? Self.string(project?["id"]) ?? "default"
        guard let orgID else { return nil }
        return (orgID, projectID)
    }

    private func copyKey(origin: String, token: String, context: (org: String, project: String),
                         createIfMissing: Bool) async -> String? {
        let keysURL = origin + "/api/biz/v1/organization/\(context.org)/projects/\(context.project)/api_keys"
        guard let url = URL(string: keysURL), let root = await authorizedJSON(url, token: token) else { return nil }
        var items = root["data"] as? [[String: Any]] ?? []
        if items.isEmpty, createIfMissing {
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.timeoutInterval = 15
            request.httpBody = try? JSONSerialization.data(withJSONObject: ["name": "blinky-usage"])
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            if let (data, response) = try? await session.data(for: request),
               (response as? HTTPURLResponse)?.statusCode == 200,
               let created = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let item = created["data"] as? [String: Any] {
                items = [item]
            }
        }
        let preferred = items.first { Self.string($0["name"]) == "blinky-usage" } ?? items.first
        guard let preferred else { return nil }
        if let secret = Self.unmaskedSecret(preferred), let id = Self.string(preferred["apiKey"] ?? preferred["id"]) {
            return secret.contains(".") ? secret : "\(id).\(secret)"
        }
        guard let id = Self.string(preferred["apiKey"] ?? preferred["id"]),
              let copyURL = URL(string: keysURL + "/copy/\(id)"),
              let copied = await authorizedJSON(copyURL, token: token) else { return nil }
        let payload = copied["data"] as? [String: Any] ?? copied
        guard let secret = Self.string(payload["secretKey"] ?? payload["secret"]), !secret.contains("*") else { return nil }
        return "\(id).\(secret)"
    }

    private func authorizedJSON(_ url: URL, token: String) async -> [String: Any]? {
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        guard let (data, response) = try? await session.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    private static func unmaskedSecret(_ item: [String: Any]) -> String? {
        guard let secret = string(item["secretKey"] ?? item["secret"]), !secret.contains("*"), secret.count >= 8 else {
            return nil
        }
        return secret
    }

    private static func randomToken() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return bytes.map { String(format: "%02x", $0) }.joined()
    }
}

struct ZAIWebSession: Sendable {
    var accessToken: String
    var refreshToken: String
    var name: String?
    var email: String?
}
