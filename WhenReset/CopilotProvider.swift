import Foundation

struct CopilotDeviceLink: Sendable {
    let verificationURL: URL
    let userCode: String
    let deviceCode: String
    let interval: TimeInterval
    let expiresAt: Date
}

enum CopilotProviderError: LocalizedError {
    case invalidResponse(String)
    case authorizationDenied
    case authorizationExpired
    case deviceFlowUnavailable(String)
    case relinkRequired
    case copilotUnavailable
    case missingQuota
    case missingResetDate
    case server(Int, String)

    var errorDescription: String? {
        switch self {
        case let .invalidResponse(context):
            "GitHub returned an unreadable \(context) response."
        case .authorizationDenied:
            "GitHub sign-in was cancelled or denied."
        case .authorizationExpired:
            "The GitHub sign-in code expired. Start linking again."
        case let .deviceFlowUnavailable(message):
            "GitHub device sign-in is unavailable: \(message)"
        case .relinkRequired:
            "The GitHub authorization is no longer valid. Link the Copilot account again."
        case .copilotUnavailable:
            "GitHub did not provide Copilot usage for this account. Confirm that Copilot is active, then try again."
        case .missingQuota:
            "GitHub returned no usable Copilot quota. This plan may use unmetered or organization-managed billing."
        case .missingResetDate:
            "GitHub returned Copilot usage without a reset date, so When Reset cannot show a reliable countdown."
        case let .server(code, message):
            "GitHub request failed (HTTP \(code)): \(message)"
        }
    }
}

struct CopilotProvider {
    /// The public VS Code GitHub App client used by CodexBar's Copilot device flow.
    /// A separately registered When Reset client should replace this before distribution.
    static let clientID = "Iv1.b507a08c87ecfe98"

    private static let deviceCodeURL = URL(string: "https://github.com/login/device/code")!
    private static let accessTokenURL = URL(string: "https://github.com/login/oauth/access_token")!
    private static let profileURL = URL(string: "https://api.github.com/user")!
    private static let usageURL = URL(string: "https://api.github.com/copilot_internal/user")!
    private static let scope = "read:user"

    private let oauthClientID: String
    private let session: URLSession

    init(clientID: String = Self.clientID, session: URLSession = .shared) {
        self.oauthClientID = clientID
        self.session = session
    }

    func beginLink() async throws -> CopilotDeviceLink {
        var request = URLRequest(url: Self.deviceCodeURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("WhenReset/1.0", forHTTPHeaderField: "User-Agent")
        request.httpBody = Self.formEncoded([
            "client_id": oauthClientID,
            "scope": Self.scope
        ])

        let data = try await perform(request)
        let response: DeviceCodeResponse
        do {
            response = try JSONDecoder().decode(DeviceCodeResponse.self, from: data)
        } catch {
            throw CopilotProviderError.invalidResponse("device authorization")
        }
        guard !response.deviceCode.isEmpty, !response.userCode.isEmpty,
              let fallbackURL = URL(string: response.verificationURI) else {
            throw CopilotProviderError.invalidResponse("device authorization")
        }
        let verificationURL = response.verificationURIComplete.flatMap(URL.init(string:)) ?? fallbackURL
        let expiresIn = max(1, response.expiresIn)
        return CopilotDeviceLink(
            verificationURL: verificationURL,
            userCode: response.userCode,
            deviceCode: response.deviceCode,
            interval: TimeInterval(max(1, response.interval)),
            expiresAt: .now.addingTimeInterval(TimeInterval(expiresIn))
        )
    }

    func finishLink(_ link: CopilotDeviceLink) async throws -> LinkedIdentity {
        let token = try await pollForToken(link)
        async let profileRequest = fetchProfile(token: token.accessToken)
        async let usageRequest = fetchUsageResponse(token: token.accessToken)
        let (profile, usage) = try await (profileRequest, usageRequest)
        let credentials = AccountCredentials(
            accessToken: token.accessToken,
            refreshToken: token.refreshToken ?? "",
            idToken: "",
            expiresAt: token.expiresIn.flatMap { seconds in
                seconds > 0 ? Date.now.addingTimeInterval(seconds) : nil
            }
        )
        return LinkedIdentity(
            workspaceID: String(profile.id),
            displayName: profile.preferredName,
            profileName: Self.nonEmpty(profile.name),
            email: profile.email,
            plan: Self.displayPlan(usage.copilotPlan),
            credentials: credentials
        )
    }

    /// GitHub's public device flow used here issues a long-lived token and does not expose
    /// a client-secret-free refresh operation. If GitHub ever returns an expiring token,
    /// fail early and ask the user to relink instead of attempting an unsupported refresh.
    func refreshedIfNeeded(_ credentials: AccountCredentials) async throws -> AccountCredentials {
        guard let expiresAt = credentials.expiresAt else { return credentials }
        guard expiresAt.timeIntervalSinceNow >= 5 * 60 else {
            throw CopilotProviderError.relinkRequired
        }
        return credentials
    }

    func fetchAccountDetails(credentials: AccountCredentials) async throws -> ProviderAccountDetails {
        let profile = try await fetchProfile(token: credentials.accessToken)
        return ProviderAccountDetails(
            profileName: Self.nonEmpty(profile.name),
            displayName: profile.preferredName,
            email: profile.email,
            replacesMissingFields: true
        )
    }

    func fetchUsage(account: MonitoredAccount, credentials: AccountCredentials) async throws -> UsageSnapshot {
        let response = try await fetchUsageResponse(token: credentials.accessToken)
        return try Self.makeSnapshot(account: account, response: response)
    }

    static func parseUsage(account: MonitoredAccount, data: Data) throws -> UsageSnapshot {
        let response: UsageResponse
        do {
            response = try JSONDecoder().decode(UsageResponse.self, from: data)
        } catch {
            throw CopilotProviderError.invalidResponse("Copilot usage")
        }
        return try makeSnapshot(account: account, response: response)
    }

    static func parseQuotaResetDate(_ value: String?) -> Date? {
        guard let raw = value?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            return nil
        }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: raw) { return date }

        let internet = ISO8601DateFormatter()
        internet.formatOptions = [.withInternetDateTime]
        if let date = internet.date(from: raw) { return date }

        if let timestamp = TimeInterval(raw), timestamp > 0 {
            return Date(timeIntervalSince1970: timestamp > 10_000_000_000 ? timestamp / 1_000 : timestamp)
        }

        let dateOnly = DateFormatter()
        dateOnly.calendar = Calendar(identifier: .gregorian)
        dateOnly.isLenient = false
        dateOnly.locale = Locale(identifier: "en_US_POSIX")
        dateOnly.timeZone = TimeZone(secondsFromGMT: 0)
        dateOnly.dateFormat = "yyyy-MM-dd"
        return dateOnly.date(from: raw)
    }

    static func formEncoded(_ parameters: [String: String]) -> Data {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "+&=")
        let body = parameters.sorted { $0.key < $1.key }.map { key, value in
            let encodedKey = key.addingPercentEncoding(withAllowedCharacters: allowed) ?? key
            let encodedValue = value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
            return "\(encodedKey)=\(encodedValue)"
        }.joined(separator: "&")
        return Data(body.utf8)
    }

    private func pollForToken(_ link: CopilotDeviceLink) async throws -> TokenResponse {
        var interval = max(1, link.interval)
        while Date.now < link.expiresAt {
            try await Task.sleep(for: .seconds(interval))
            try Task.checkCancellation()

            var request = URLRequest(url: Self.accessTokenURL)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            request.setValue("WhenReset/1.0", forHTTPHeaderField: "User-Agent")
            request.httpBody = Self.formEncoded([
                "client_id": oauthClientID,
                "device_code": link.deviceCode,
                "grant_type": "urn:ietf:params:oauth:grant-type:device_code"
            ])

            let data: Data
            do {
                data = try await perform(request)
            } catch let error as URLError where Self.isTransient(error.code) {
                continue
            } catch CopilotProviderError.server(let code, _) where [500, 502, 503, 504].contains(code) {
                continue
            }

            if let failure = try? JSONDecoder().decode(OAuthErrorResponse.self, from: data),
               !failure.error.isEmpty {
                switch failure.error {
                case "authorization_pending":
                    continue
                case "slow_down":
                    interval += 5
                    continue
                case "access_denied":
                    throw CopilotProviderError.authorizationDenied
                case "expired_token":
                    throw CopilotProviderError.authorizationExpired
                case "device_flow_disabled", "unsupported_grant_type", "incorrect_client_credentials",
                     "incorrect_device_code":
                    throw CopilotProviderError.deviceFlowUnavailable(failure.safeDescription)
                default:
                    throw CopilotProviderError.deviceFlowUnavailable(failure.safeDescription)
                }
            }

            do {
                let response = try JSONDecoder().decode(TokenResponse.self, from: data)
                guard !response.accessToken.isEmpty else {
                    throw CopilotProviderError.invalidResponse("access token")
                }
                return response
            } catch let error as CopilotProviderError {
                throw error
            } catch {
                throw CopilotProviderError.invalidResponse("access token")
            }
        }
        throw CopilotProviderError.authorizationExpired
    }

    private func fetchProfile(token: String) async throws -> GitHubProfile {
        var request = URLRequest(url: Self.profileURL)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        request.setValue("WhenReset/1.0", forHTTPHeaderField: "User-Agent")
        let data = try await performAuthenticated(request)
        return try Self.parseProfile(data)
    }

    static func parseProfile(_ data: Data) throws -> GitHubProfile {
        do {
            let profile = try JSONDecoder().decode(GitHubProfile.self, from: data)
            guard profile.id > 0, !profile.login.isEmpty else {
                throw CopilotProviderError.invalidResponse("GitHub profile")
            }
            return profile
        } catch let error as CopilotProviderError {
            throw error
        } catch {
            throw CopilotProviderError.invalidResponse("GitHub profile")
        }
    }

    private func fetchUsageResponse(token: String) async throws -> UsageResponse {
        var request = URLRequest(url: Self.usageURL)
        request.setValue("token \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("vscode/1.96.2", forHTTPHeaderField: "Editor-Version")
        request.setValue("copilot-chat/0.26.7", forHTTPHeaderField: "Editor-Plugin-Version")
        request.setValue("GitHubCopilotChat/0.26.7", forHTTPHeaderField: "User-Agent")
        request.setValue("2025-04-01", forHTTPHeaderField: "X-Github-Api-Version")

        let data = try await performAuthenticated(request, copilotEndpoint: true)
        do {
            return try JSONDecoder().decode(UsageResponse.self, from: data)
        } catch {
            throw CopilotProviderError.invalidResponse("Copilot usage")
        }
    }

    private func performAuthenticated(_ request: URLRequest, copilotEndpoint: Bool = false) async throws -> Data {
        let (data, response) = try await session.data(for: request)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        switch code {
        case 200..<300:
            return data
        case 401:
            throw CopilotProviderError.relinkRequired
        case 403, 404:
            if copilotEndpoint { throw CopilotProviderError.copilotUnavailable }
            throw CopilotProviderError.server(code, Self.safeServerMessage(data))
        default:
            throw CopilotProviderError.server(code, Self.safeServerMessage(data))
        }
    }

    private func perform(_ request: URLRequest) async throws -> Data {
        let (data, response) = try await session.data(for: request)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(code) else {
            throw CopilotProviderError.server(code, Self.safeServerMessage(data))
        }
        return data
    }

    private static func makeSnapshot(account: MonitoredAccount, response: UsageResponse) throws -> UsageSnapshot {
        let premiumQuota = response.quotaSnapshots.premiumInteractions
        let chatQuota = response.quotaSnapshots.chat
        let hasMeteredQuota = premiumQuota?.isUsable == true || chatQuota?.isUsable == true
        let hasKnownUnmeteredQuota = premiumQuota?.unlimited == true || chatQuota?.unlimited == true

        if !hasMeteredQuota, !hasKnownUnmeteredQuota, !response.tokenBasedBilling {
            throw CopilotProviderError.missingQuota
        }

        let resetDate: Date?
        if hasMeteredQuota {
            guard let parsed = parseQuotaResetDate(response.quotaResetDate) else {
                throw CopilotProviderError.missingResetDate
            }
            resetDate = parsed
        } else {
            resetDate = nil
        }

        let plan = displayPlan(response.copilotPlan) ?? account.plan
        return UsageSnapshot(
            accountID: account.id,
            providerName: "GitHub Copilot",
            accountName: account.displayName,
            plan: plan,
            primary: makeWindow(premiumQuota, title: "Premium requests", id: "copilot:premium", reset: resetDate),
            secondary: makeWindow(chatQuota, title: "Chat", id: "copilot:chat", reset: resetDate),
            availableResetCount: 0,
            resetCredits: [],
            fetchedAt: .now
        )
    }

    private static func makeWindow(_ quota: QuotaSnapshot?, title: String, id: String,
                                   reset: Date?) -> UsageWindow? {
        guard let quota, quota.isUsable, let reset else { return nil }
        return UsageWindow(
            title: title,
            usedPercent: quota.usedPercent,
            resetsAt: reset,
            windowMinutes: nil,
            identifier: id
        )
    }

    private static func displayPlan(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty, value.lowercased() != "unknown" else { return nil }
        return value.replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")
            .capitalized
    }

    private static func nonEmpty(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed?.isEmpty == false ? trimmed : nil
    }

    private static func safeServerMessage(_ data: Data) -> String {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return "The server did not provide an error message."
        }
        let message = (object["error_description"] as? String)
            ?? (object["message"] as? String)
            ?? (object["error"] as? String)
            ?? "The request was rejected."
        let collapsed = message.split(whereSeparator: \Character.isWhitespace).joined(separator: " ")
        return String(collapsed.prefix(240))
    }

    private static func isTransient(_ code: URLError.Code) -> Bool {
        switch code {
        case .timedOut, .networkConnectionLost, .notConnectedToInternet,
             .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed,
             .internationalRoamingOff, .dataNotAllowed:
            true
        default:
            false
        }
    }
}

private struct DeviceCodeResponse: Decodable {
    let deviceCode: String
    let userCode: String
    let verificationURI: String
    let verificationURIComplete: String?
    let expiresIn: Int
    let interval: Int

    enum CodingKeys: String, CodingKey {
        case deviceCode = "device_code"
        case userCode = "user_code"
        case verificationURI = "verification_uri"
        case verificationURIComplete = "verification_uri_complete"
        case expiresIn = "expires_in"
        case interval
    }
}

private struct TokenResponse: Decodable {
    let accessToken: String
    let refreshToken: String?
    let expiresIn: TimeInterval?

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
        case expiresIn = "expires_in"
    }
}

private struct OAuthErrorResponse: Decodable {
    let error: String
    let errorDescription: String?

    enum CodingKeys: String, CodingKey {
        case error
        case errorDescription = "error_description"
    }

    var safeDescription: String {
        if let value = errorDescription?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty {
            return String(value.prefix(240))
        }
        return error.replacingOccurrences(of: "_", with: " ")
    }
}

struct GitHubProfile: Decodable {
    let id: Int64
    let login: String
    let name: String?
    let email: String?

    var preferredName: String {
        guard let name = name?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty else {
            return login
        }
        return name
    }
}

private struct UsageResponse: Decodable {
    let quotaSnapshots: QuotaSnapshots
    let copilotPlan: String?
    let tokenBasedBilling: Bool
    let quotaResetDate: String?

    enum CodingKeys: String, CodingKey {
        case quotaSnapshots = "quota_snapshots"
        case copilotPlan = "copilot_plan"
        case tokenBasedBilling = "token_based_billing"
        case quotaResetDate = "quota_reset_date"
        case monthlyQuotas = "monthly_quotas"
        case limitedUserQuotas = "limited_user_quotas"
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let direct = try values.decodeIfPresent(QuotaSnapshots.self, forKey: .quotaSnapshots)
        let monthly = try values.decodeIfPresent(QuotaCounts.self, forKey: .monthlyQuotas)
        let limited = try values.decodeIfPresent(QuotaCounts.self, forKey: .limitedUserQuotas)
        let fallback = QuotaSnapshots(monthly: monthly, limited: limited)
        quotaSnapshots = QuotaSnapshots(
            premiumInteractions: Self.preferred(direct?.premiumInteractions, fallback?.premiumInteractions),
            chat: Self.preferred(direct?.chat, fallback?.chat)
        )
        copilotPlan = try values.decodeIfPresent(String.self, forKey: .copilotPlan)
        tokenBasedBilling = try values.decodeIfPresent(Bool.self, forKey: .tokenBasedBilling) ?? false
        if let string = try? values.decodeIfPresent(String.self, forKey: .quotaResetDate) {
            quotaResetDate = string
        } else if let number = try? values.decodeIfPresent(Double.self, forKey: .quotaResetDate) {
            quotaResetDate = String(number)
        } else {
            quotaResetDate = nil
        }
    }

    private static func preferred(_ direct: QuotaSnapshot?, _ fallback: QuotaSnapshot?) -> QuotaSnapshot? {
        if direct?.unlimited == true, fallback?.isUsable == true { return fallback }
        if direct?.isUsable == true || direct?.unlimited == true { return direct }
        if fallback?.isUsable == true || fallback?.unlimited == true { return fallback }
        return direct ?? fallback
    }
}

private struct QuotaCounts: Decodable {
    let chat: Double?
    let completions: Double?

    enum CodingKeys: String, CodingKey { case chat, completions }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        chat = Self.number(values, .chat)
        completions = Self.number(values, .completions)
    }

    private static func number(_ values: KeyedDecodingContainer<CodingKeys>, _ key: CodingKeys) -> Double? {
        if let value = try? values.decodeIfPresent(Double.self, forKey: key) { return value }
        if let value = try? values.decodeIfPresent(String.self, forKey: key) { return Double(value) }
        return nil
    }
}

private struct QuotaSnapshots: Decodable {
    let premiumInteractions: QuotaSnapshot?
    let chat: QuotaSnapshot?

    enum CodingKeys: String, CodingKey {
        case premiumInteractions = "premium_interactions"
        case chat
    }

    init(premiumInteractions: QuotaSnapshot?, chat: QuotaSnapshot?) {
        self.premiumInteractions = premiumInteractions
        self.chat = chat
    }

    init?(monthly: QuotaCounts?, limited: QuotaCounts?) {
        let premium = QuotaSnapshot(entitlement: monthly?.completions, remaining: limited?.completions,
                                    quotaID: "completions")
        let chat = QuotaSnapshot(entitlement: monthly?.chat, remaining: limited?.chat, quotaID: "chat")
        guard premium != nil || chat != nil else { return nil }
        self.init(premiumInteractions: premium, chat: chat)
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        var premium = try values.decodeIfPresent(QuotaSnapshot.self, forKey: .premiumInteractions)
        var chat = try values.decodeIfPresent(QuotaSnapshot.self, forKey: .chat)

        if premium == nil || chat == nil {
            let dynamic = try decoder.container(keyedBy: AnyCodingKey.self)
            var firstUsable: QuotaSnapshot?
            for key in dynamic.allKeys {
                guard let quota = try? dynamic.decodeIfPresent(QuotaSnapshot.self, forKey: key),
                      quota.isUsable || quota.unlimited else { continue }
                if firstUsable == nil { firstUsable = quota }
                let name = key.stringValue.lowercased()
                if chat == nil, name.contains("chat") { chat = quota }
                if premium == nil, name.contains("premium") || name.contains("completion") || name.contains("code") {
                    premium = quota
                }
            }
            if premium == nil, chat == nil { chat = firstUsable }
        }
        self.init(premiumInteractions: premium, chat: chat)
    }
}

private struct QuotaSnapshot: Decodable {
    let entitlement: Double
    let remaining: Double
    let percentRemaining: Double
    let hasPercentRemaining: Bool
    let quotaID: String
    let unlimited: Bool
    private let decodedEntitlement: Bool
    private let decodedRemaining: Bool

    enum CodingKeys: String, CodingKey {
        case entitlement, remaining
        case percentRemaining = "percent_remaining"
        case quotaID = "quota_id"
        case unlimited
    }

    init?(entitlement: Double?, remaining: Double?, quotaID: String) {
        guard let entitlement, entitlement > 0, let remaining else { return nil }
        self.entitlement = entitlement
        self.remaining = max(0, remaining)
        percentRemaining = max(0, min(100, self.remaining / entitlement * 100))
        hasPercentRemaining = true
        self.quotaID = quotaID
        unlimited = false
        decodedEntitlement = true
        decodedRemaining = true
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let entitlement = Self.number(values, .entitlement)
        let remaining = Self.number(values, .remaining)
        let explicitPercent = Self.number(values, .percentRemaining)
        self.entitlement = entitlement ?? 0
        self.remaining = remaining ?? 0
        decodedEntitlement = entitlement != nil
        decodedRemaining = remaining != nil
        unlimited = try values.decodeIfPresent(Bool.self, forKey: .unlimited) ?? false
        quotaID = try values.decodeIfPresent(String.self, forKey: .quotaID) ?? ""
        if unlimited {
            percentRemaining = 100
            hasPercentRemaining = true
        } else if let explicitPercent {
            percentRemaining = explicitPercent
            hasPercentRemaining = true
        } else if let entitlement, entitlement > 0, let remaining {
            percentRemaining = remaining / entitlement * 100
            hasPercentRemaining = true
        } else {
            percentRemaining = 0
            hasPercentRemaining = false
        }
    }

    var isUsable: Bool {
        guard !unlimited, hasPercentRemaining else { return false }
        return !(decodedEntitlement && decodedRemaining && entitlement == 0 && remaining == 0)
    }

    var usedPercent: Double {
        max(0, 100 - percentRemaining)
    }

    private static func number(_ values: KeyedDecodingContainer<CodingKeys>, _ key: CodingKeys) -> Double? {
        if let value = try? values.decodeIfPresent(Double.self, forKey: key) { return value }
        if let value = try? values.decodeIfPresent(String.self, forKey: key) { return Double(value) }
        return nil
    }
}

private struct AnyCodingKey: CodingKey {
    let stringValue: String
    let intValue: Int?

    init?(stringValue: String) {
        self.stringValue = stringValue
        intValue = nil
    }

    init?(intValue: Int) {
        stringValue = String(intValue)
        self.intValue = intValue
    }
}
